"""Runs a task's checks.py and normalizes every fault to the check-infra reason code.

checks.py contract: a module-level `run_checks(workspace, task, config) -> dict` returning
{"passed": bool, "reason_code": str, "detail": str}. reason_code vocabulary: "pass",
"wrong-answer", "build-fail", "wrong-api", "missing-events", "check-infra".

Checks run in a subprocess under a timeout so a hung or infinite-looping checks.py can
never hang the runner; any exception, timeout, or malformed result also normalizes to
check-infra rather than crashing the batch.
"""

import json
import subprocess
import sys

REASON_CODES = ("pass", "wrong-answer", "build-fail", "wrong-api", "missing-events", "check-infra")

DEFAULT_TIMEOUT_SECS = 600  # fallback only; config.yml's checks_timeout_secs is the real budget
                            # (typecheck capped at 180s + slack)

_SUBPROCESS_RUNNER = """
import importlib.util
import json
import sys

payload = json.loads(sys.stdin.read())

try:
    spec = importlib.util.spec_from_file_location("task_checks", payload["checks_path"])
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    result = module.run_checks(payload["workspace"], payload["task"], payload["config"])
except Exception as exc:
    result = {"passed": False, "reason_code": "check-infra", "detail": f"checks.py raised: {exc!r}"}

print(json.dumps(result))
"""


def _checks_path(task_dir):
    return f"{task_dir}/checks.py".replace("\\", "/")


def _infra_result(detail):
    return {"passed": False, "reason_code": "check-infra", "detail": detail}


def score_task(task_dir, workspace, task, config, timeout_secs=None):
    timeout_secs = timeout_secs or config.get("checks_timeout_secs", DEFAULT_TIMEOUT_SECS)
    payload = json.dumps({
        "workspace": workspace,
        "checks_path": _checks_path(task_dir),
        "task": task,
        "config": config,
    })

    try:
        proc = subprocess.run(
            [sys.executable, "-c", _SUBPROCESS_RUNNER],
            input=payload, capture_output=True, text=True,
            encoding="utf-8", errors="replace", timeout=timeout_secs,
        )
    except subprocess.TimeoutExpired:
        return _infra_result(f"checks.py timed out after {timeout_secs}s")

    stdout = proc.stdout.strip()
    if not stdout:
        return _infra_result(f"checks.py produced no output (exit {proc.returncode}): {proc.stderr[-500:]}")

    try:
        result = json.loads(stdout.splitlines()[-1])
    except json.JSONDecodeError:
        return _infra_result(f"checks.py output was not valid JSON: {stdout[-500:]}")

    if "passed" not in result or "reason_code" not in result:
        return _infra_result("checks.py result missing required 'passed' or 'reason_code' field")

    result.setdefault("detail", "")
    return result
