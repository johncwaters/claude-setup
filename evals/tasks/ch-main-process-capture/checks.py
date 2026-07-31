"""Programmatic checks for ch-main-process-capture.

Verifies main-process uncaughtException/unhandledRejection now reach PostHog even with
no renderer window open, that the renderer-only posthog-js/@posthog/react SDK was not
pulled into the main process, and that `npm run typecheck` still passes.

run_checks(workspace, task, config) -> dict with keys:
  passed: bool
  reason_code: one of "pass", "wrong-answer", "build-fail", "wrong-api", "missing-events", "check-infra"
  detail: str, human-readable explanation

Check order and reasoning: importing posthog-js/@posthog/react into src/main is the one
clearly wrong move the prompt explicitly rules out, so that scan runs first and returns
wrong-api on its own (a main-process-only capture path is either possible without those
packages or the task was not actually solved as asked). The build gate runs next. Static
acceptance runs last and, as in the other ch- tasks, reports "missing-events" when the
new capture path is absent or is still nested inside the per-window broadcast loop
(i.e. still dependent on a renderer window existing), since an unreachable capture path
never emits.
"""

import os
import re
import subprocess

RENDERER_SDK_IMPORT_RE = re.compile(r"from\s*['\"](posthog-js|@posthog/react)['\"]")
POSTHOG_NETWORK_TOKEN_RE = re.compile(
    r"posthog-node|posthog\.com|/i/v0/e/|/capture/|/batch/|new PostHog\(", re.IGNORECASE
)


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


def _changed_files(workspace, pinned_commit):
    # untracked new files never show up in a plain `git diff`; intent-to-add stages
    # them as empty blobs so they appear in the diff without actually adding content
    _run("git add -N -- src", workspace)
    proc = _run(f"git diff --name-only {pinned_commit} -- src", workspace)
    if proc.returncode != 0:
        return None
    return [line.strip() for line in proc.stdout.splitlines() if line.strip()]


def _main_process_files(changed_files):
    return [f for f in changed_files if f.startswith("src/main/")]


def _check_no_renderer_sdk_in_main(workspace, main_files):
    offenders = []
    for file_path in main_files:
        text = _read_text(os.path.join(workspace, file_path))
        if RENDERER_SDK_IMPORT_RE.search(text):
            offenders.append(file_path)
    return offenders


def _function_body_span(lines, func_name):
    """Line-index span [start, end] of a top-level `function <func_name>` definition.

    A brace-depth walk, not a real parser: good enough to bound one named function in
    files this small and TypeScript-formatted consistently (see crashHandlers.ts).
    """
    start = None
    for index, line in enumerate(lines):
        if re.search(rf"function\s+{re.escape(func_name)}\s*\(", line):
            start = index
            break
    if start is None:
        return None
    depth = 0
    opened = False
    for index in range(start, len(lines)):
        depth += lines[index].count("{") - lines[index].count("}")
        if "{" in lines[index]:
            opened = True
        if opened and depth <= 0:
            return (start, index)
    return (start, len(lines) - 1)


def _posthog_capture_reaches_beyond_windows(workspace, main_files):
    """True if a PostHog-network reference exists outside broadcastMainProcessError's body.

    Reading outside that function's body is the proxy for "does not depend on a
    renderer window existing", since broadcastMainProcessError is exactly the existing
    per-window IPC relay this task's prompt says must stay additive, not become the only
    path.
    """
    crash_handlers_path = next((f for f in main_files if f.endswith("crashHandlers.ts")), None)
    for file_path in main_files:
        text = _read_text(os.path.join(workspace, file_path))
        lines = text.splitlines()
        match_lines = [i for i, line in enumerate(lines) if POSTHOG_NETWORK_TOKEN_RE.search(line)]
        if not match_lines:
            continue
        if file_path != crash_handlers_path:
            return True  # a whole separate module doing this is unambiguously not the window loop
        broadcast_span = _function_body_span(lines, "broadcastMainProcessError")
        for line_index in match_lines:
            inside_broadcast = (
                broadcast_span is not None and broadcast_span[0] <= line_index <= broadcast_span[1]
            )
            if not inside_broadcast:
                return True
    return False


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

    main_files = _main_process_files(changed_files)

    renderer_sdk_offenders = _check_no_renderer_sdk_in_main(workspace, main_files)
    if renderer_sdk_offenders:
        return _fail(
            "wrong-api",
            "posthog-js/@posthog/react (renderer-only SDKs) imported into the main process: "
            + ", ".join(renderer_sdk_offenders),
        )

    if not _ensure_node_modules_linked(workspace, repo_root):
        return _infra("could not link node_modules into the worktree for typecheck")
    try:
        exit_code, tail = _run_typecheck(workspace)
    except subprocess.TimeoutExpired:
        return _infra("npm run typecheck timed out")
    if exit_code != 0:
        return _fail("build-fail", f"npm run typecheck failed (exit {exit_code}): {tail}")

    if not main_files:
        return _fail("missing-events", "no main-process files changed; nothing added a main-process capture path")

    if not _posthog_capture_reaches_beyond_windows(workspace, main_files):
        return _fail(
            "missing-events",
            "no PostHog capture path found in the main process outside broadcastMainProcessError's "
            "per-window loop; a crash with zero open windows still would not reach PostHog",
        )

    return _pass("typecheck clean, main-process capture path found outside the window-broadcast loop: "
                  "static acceptance surface passed")
