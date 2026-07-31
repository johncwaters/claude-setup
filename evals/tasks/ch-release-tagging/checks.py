"""Programmatic checks for ch-release-tagging.

Verifies every PostHog event/exception is tagged with the app's real version/build as
super properties (posthog-js `register`), sourced from the packaged app rather than a
hardcoded string, without a hallucinated SDK call and without regressing typecheck.

run_checks(workspace, task, config) -> dict with keys:
  passed: bool
  reason_code: one of "pass", "wrong-answer", "build-fail", "wrong-api", "missing-events", "check-infra"
  detail: str, human-readable explanation

Check order: wrong-api (hallucinated posthog-js method) first, build gate second, static
acceptance last. As in the other two ch- tasks, "missing-events" covers every way the
static acceptance scan can come back unsatisfied: no `register` call for the release
properties at all, or one that exists but is fed a hardcoded semver literal instead of
the packaged app's real version (which fails the task's explicit "not a hardcoded
string" requirement just as surely as not registering anything).
"""

import json
import os
import re
import subprocess

REGISTER_CALL_RE = re.compile(r"\bregister\s*\(")
APP_VERSION_KEY_RE = re.compile(r"\$app_version|app_version", re.IGNORECASE)
APP_BUILD_KEY_RE = re.compile(r"\$app_build|app_build", re.IGNORECASE)
HARDCODED_SEMVER_RE = re.compile(r"""['"]\d+\.\d+\.\d+(?:\+\d+)?['"]""")
GET_VERSION_RE = re.compile(r"getVersion\s*\(|getAppVersion")

EVENT_POLL_TIMEOUT_SECS_DEFAULT = 300


def _fail(reason_code, detail):
    return {"passed": False, "reason_code": reason_code, "detail": detail}


def _pass(detail):
    return {"passed": True, "reason_code": "pass", "detail": detail}


def _infra(detail):
    return {"passed": False, "reason_code": "check-infra", "detail": detail}


def _run(cmd, cwd, timeout=180):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, shell=True)


def _read_text(path):
    if not os.path.isfile(path):
        return ""
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        return handle.read()


def _split_import_names(group_text):
    names = []
    for token in group_text.split(","):
        token = token.strip()
        if not token or token.startswith("type "):
            continue
        names.append(token.split(" as ")[0].strip())
    return names


def _collect_posthog_js_methods(repo_root):
    path = os.path.join(repo_root, "node_modules", "posthog-js", "dist", "module.d.ts")
    text = _read_text(path)
    methods = set()
    for match in re.finditer(r"^\s{4,8}(\w+)\(", text, re.MULTILINE):
        methods.add(match.group(1))
    return methods


def _changed_files(workspace, pinned_commit):
    # untracked new files never show up in a plain `git diff`; intent-to-add stages
    # them as empty blobs so they appear in the diff without actually adding content
    _run("git add -N -- src", workspace)
    proc = _run(f"git diff --name-only {pinned_commit} -- src", workspace)
    if proc.returncode != 0:
        return None
    return [line.strip() for line in proc.stdout.splitlines() if line.strip()]


def _added_lines_by_file(workspace, pinned_commit, files):
    added = {}
    for file_path in files:
        proc = _run(f'git diff {pinned_commit} -- "{file_path}"', workspace)
        if proc.returncode != 0:
            continue
        lines = [
            line[1:] for line in proc.stdout.splitlines()
            if line.startswith("+") and not line.startswith("+++")
        ]
        added[file_path] = "\n".join(lines)
    return added


def _check_wrong_api(repo_root, added_lines_by_file):
    posthog_js_methods = _collect_posthog_js_methods(repo_root)
    offenders = []
    call_re = re.compile(r"\bposthog\??\.(\w+)\(")
    for file_path, text in added_lines_by_file.items():
        for match in call_re.finditer(text):
            name = match.group(1)
            if posthog_js_methods and name not in posthog_js_methods:
                offenders.append(f"{file_path}: `posthog.{name}(...)` is not a method on the installed posthog-js client")
    return offenders


def _register_call_covers_release_properties(added_lines_by_file):
    for text in added_lines_by_file.values():
        if not REGISTER_CALL_RE.search(text):
            continue
        if APP_VERSION_KEY_RE.search(text) or APP_BUILD_KEY_RE.search(text):
            return True
    return False


def _version_source_is_dynamic(workspace, changed_files):
    """No hardcoded semver literal near a version property, and some real version lookup exists.

    Both checked across the full post-edit file contents (not just the diff) since the
    lookup and the register call may land in different files (main process reads
    app.getVersion(), bridges it over IPC, renderer registers it).
    """
    has_dynamic_lookup = False
    has_hardcoded_literal_near_version_key = False
    for file_path in changed_files:
        text = _read_text(os.path.join(workspace, file_path))
        if GET_VERSION_RE.search(text):
            has_dynamic_lookup = True
        for line in text.splitlines():
            if APP_VERSION_KEY_RE.search(line) and HARDCODED_SEMVER_RE.search(line):
                has_hardcoded_literal_near_version_key = True
    return has_dynamic_lookup and not has_hardcoded_literal_near_version_key


def _ensure_node_modules_linked(workspace, repo_root):
    target = os.path.normpath(os.path.join(workspace, "node_modules"))
    if os.path.isdir(target) or os.path.islink(target):
        return True
    source = os.path.normpath(os.path.join(repo_root, "node_modules"))
    if not os.path.isdir(source):
        return False
    try:
        os.symlink(source, target, target_is_directory=True)
        return True
    except OSError:
        pass
    # cmd.exe's mklink parses a forward-slash path as switches (e.g. "/Users" reads as a
    # switch), so both paths must be backslash-normalized before this call, not just the
    # os.symlink attempt above (which tolerates either separator).
    proc = subprocess.run(["cmd", "/c", "mklink", "/J", target, source], capture_output=True, text=True)
    return proc.returncode == 0


def _run_typecheck(workspace):
    proc = _run("npm run typecheck", workspace, timeout=180)
    return proc.returncode, (proc.stdout + "\n" + proc.stderr)[-4000:]


def _poll_scratch_project_for_event(config, event_name, timeout_secs):
    """Separated so it is trivially skippable when scratch-project credentials are absent."""
    import time
    import urllib.error
    import urllib.request

    posthog_config = config.get("posthog", {})
    personal_key = os.environ.get(posthog_config.get("personal_api_key_env", "EVALS_POSTHOG_PERSONAL_KEY"))
    project_id = os.environ.get(posthog_config.get("scratch_project_id_env", "EVALS_POSTHOG_SCRATCH_PROJECT_ID"))
    if not personal_key or not project_id:
        return None

    host = posthog_config.get("host", "https://us.i.posthog.com")
    query = {
        "query": {
            "kind": "HogQLQuery",
            "query": (
                f"SELECT count() FROM events WHERE event = '{event_name}' "
                "AND properties.$app_version IS NOT NULL "
                "AND timestamp > now() - INTERVAL 1 HOUR"
            ),
        }
    }
    deadline = time.monotonic() + timeout_secs
    while time.monotonic() < deadline:
        request = urllib.request.Request(
            f"{host}/api/projects/{project_id}/query/",
            data=json.dumps(query).encode("utf-8"),
            headers={"Content-Type": "application/json", "Authorization": f"Bearer {personal_key}"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                body = json.loads(response.read())
                count = (body.get("results") or [[0]])[0][0]
                if count and count > 0:
                    return True
        except (urllib.error.URLError, TimeoutError, ValueError, OSError):
            pass
        time.sleep(15)
    return False


def run_checks(workspace, task, config):
    pinned_commit = task.get("pinned_commit")
    repo_root = task.get("repo") or workspace
    if not pinned_commit:
        return _infra("task.yml has no pinned_commit; cannot diff against a baseline")

    changed_files = _changed_files(workspace, pinned_commit)
    if changed_files is None:
        return _infra("git diff against pinned_commit failed; workspace may not be a valid worktree")

    added_lines_by_file = _added_lines_by_file(workspace, pinned_commit, changed_files)

    wrong_api_offenders = _check_wrong_api(repo_root, added_lines_by_file)
    if wrong_api_offenders:
        return _fail("wrong-api", "hallucinated PostHog SDK usage: " + "; ".join(wrong_api_offenders))

    if not _ensure_node_modules_linked(workspace, repo_root):
        return _infra("could not link node_modules into the worktree for typecheck")
    try:
        exit_code, tail = _run_typecheck(workspace)
    except subprocess.TimeoutExpired:
        return _infra("npm run typecheck timed out")
    if exit_code != 0:
        return _fail("build-fail", f"npm run typecheck failed (exit {exit_code}): {tail}")

    if not _register_call_covers_release_properties(added_lines_by_file):
        return _fail(
            "missing-events",
            "no posthog `register(...)` call found tagging $app_version/$app_build super properties; "
            f"changed files: {changed_files}",
        )
    if not _version_source_is_dynamic(workspace, changed_files):
        return _fail(
            "missing-events",
            "version registered as a super property is either hardcoded or has no traceable "
            "app.getVersion()-style lookup; the task requires the real packaged version",
        )

    timeout_secs = config.get("event_poll_timeout_secs", EVENT_POLL_TIMEOUT_SECS_DEFAULT)
    poll_result = _poll_scratch_project_for_event(config, "app_launched", timeout_secs)
    if poll_result is None:
        return _pass("typecheck clean, release super properties registered from a dynamic version lookup; "
                      "PostHog scratch-project credentials absent, event poll skipped")
    if poll_result is False:
        return _fail("missing-events", "expected event with $app_version did not appear in the scratch project within the poll timeout")
    return _pass("typecheck clean, release tagging verified, event observed in scratch project with $app_version set")
