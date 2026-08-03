"""Programmatic checks for ch-flag-gated-rollout.

Verifies the unattended TCGplayer delist step (src/main/services/autoDelist.service.ts,
gated by src/main/services/autoSyncCycle.ts's isStepRunnable) is now also gated by a
PostHog feature flag, without a hallucinated posthog-js/@posthog/react call and without
regressing `npm run typecheck`.

run_checks(workspace, task, config) -> dict with keys:
  passed: bool
  reason_code: one of "pass", "wrong-answer", "build-fail", "wrong-api", "missing-events", "check-infra"
  detail: str, human-readable explanation

Order of checks, and why: the wrong-api scan runs first because a hallucinated SDK call
is a more specific, more actionable signal than a generic typecheck failure, and TS may
not even catch it (dynamic property access, `any`-typed values). The build gate runs
next since a task that doesn't compile can't have wired anything correctly. The static
acceptance scan runs last and is the only check with no dedicated reason code in the
harness vocabulary for "the acceptance surface is simply absent" (as opposed to
hallucinated or non-compiling); it is reported as "missing-events" on the theory that an
unwired flag never actually gates or emits anything.
"""

import os
import re
import subprocess

RELEVANT_MAIN_FILES = {
    "src/main/services/autoSyncCycle.ts",
    "src/main/services/autoDelist.service.ts",
    "src/main/services/autoSyncScheduler.ts",
    "src/main/services/settings.service.ts",
}

FLAG_TOKEN_RE = re.compile(
    r"isFeatureEnabled|getFeatureFlag|useFeatureFlagEnabled|useFeatureFlagVariantKey|"
    r"useFeatureFlagPayload|useFeatureFlagResult|onFeatureFlags|PostHogFeature|feature.?flag",
    re.IGNORECASE,
)

REACT_IMPORT_RE = re.compile(r"import\s+(?:type\s+)?\{([^}]+)\}\s*from\s*['\"]@posthog/react['\"]")
POSTHOG_CALL_RE = re.compile(r"\bposthog\??\.(\w+)\(")


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
        # `Foo as Bar` imports Foo under a local alias; the SDK identity is Foo.
        names.append(token.split(" as ")[0].strip())
    return names


def _collect_react_exports(repo_root):
    path = os.path.join(repo_root, "node_modules", "@posthog", "react", "dist", "types", "index.d.ts")
    text = _read_text(path)
    exports = set()
    for match in re.finditer(r"export\s*\{([^}]*)\}", text):
        exports.update(_split_import_names(match.group(1)))
    return exports


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
    react_exports = _collect_react_exports(repo_root)
    posthog_js_methods = _collect_posthog_js_methods(repo_root)
    offenders = []
    for file_path, text in added_lines_by_file.items():
        for match in REACT_IMPORT_RE.finditer(text):
            for name in _split_import_names(match.group(1)):
                if react_exports and name not in react_exports:
                    offenders.append(f"{file_path}: `{name}` is not exported by the installed @posthog/react")
        for match in POSTHOG_CALL_RE.finditer(text):
            name = match.group(1)
            if posthog_js_methods and name not in posthog_js_methods:
                offenders.append(f"{file_path}: `posthog.{name}(...)` is not a method on the installed posthog-js client")
    return offenders


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

    def is_gating_file(path):
        return path in RELEVANT_MAIN_FILES or (path.startswith("src/main/") and "delist" in path.lower())

    gating_files_touched = any(is_gating_file(f) for f in changed_files)
    flag_token_present = any(
        FLAG_TOKEN_RE.search(text) for path, text in added_lines_by_file.items() if is_gating_file(path)
    )
    if not (gating_files_touched and flag_token_present):
        return _fail(
            "missing-events",
            "no feature-flag evaluation found wired into the main-process delist gating path "
            f"(autoSyncCycle.ts / autoDelist.service.ts); changed files: {changed_files}",
        )

    return _pass("typecheck clean, delist gating path now references a feature-flag call")
