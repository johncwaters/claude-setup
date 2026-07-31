"""CLI: snapshot a just-completed real task into evals/tasks/<id>/ (`python -m runner.capture`).

Completing real PostHog work on card-harbor or keeplings grows the eval suite as a side
effect (see docs/evals-plan.html "Capture loop"): this command records the prompt as
actually given, the repo commit the work started from, and generated check/reference
stubs to fill in afterward.
"""

import argparse
import datetime
import os
import re
import shutil
import subprocess
import sys

import yaml

TASK_CLASSES = ("install-instrumentation", "hogql-analysis", "error-tracking", "product-config")
TASK_MODES = ("prospective", "retrospective")
TASK_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")

_CHECKS_STUB = '''"""Programmatic checks for task {task_id}.

run_checks(workspace, task, config) -> dict with keys:
  passed: bool
  reason_code: one of "pass", "wrong-answer", "build-fail", "wrong-api", "missing-events", "check-infra"
  detail: str, human-readable explanation
"""


def run_checks(workspace, task, config):
    raise NotImplementedError("fill in checks for {task_id} before scoring this task")
'''

_REFERENCE_STUB = "# Reference answer for {task_id}\n\nTODO: record the verified answer or landed implementation outcome.\n"


def _git_head(repo):
    proc = subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"git rev-parse HEAD failed in {repo}: {proc.stderr}")
    return proc.stdout.strip()


def _task_yml_text(task_id, task_class, mode, repo, pinned_commit):
    document = {
        "id": task_id,
        "class": task_class,
        "mode": mode,
        "repo": repo if repo else None,
        "pinned_commit": pinned_commit if pinned_commit else None,
        "prompt_file": "prompt.md",
        "time_window": None,
        "bundle": None,
        "captured": datetime.date.today().isoformat(),
        "reference": "reference.md",
    }
    return yaml.safe_dump(document, sort_keys=False, default_flow_style=False)


def capture_task(tasks_dir, task_id, task_class, mode, prompt_file, repo=None):
    if not TASK_ID_RE.match(task_id):
        raise ValueError(f"invalid task id {task_id!r}; must match {TASK_ID_RE.pattern}")
    if task_class not in TASK_CLASSES:
        raise ValueError(f"unknown task class {task_class!r}; expected one of {TASK_CLASSES}")
    if mode not in TASK_MODES:
        raise ValueError(f"unknown task mode {mode!r}; expected one of {TASK_MODES}")

    task_dir = os.path.join(tasks_dir, task_id)
    if os.path.exists(task_dir):
        raise FileExistsError(f"task {task_id!r} already exists at {task_dir}; refusing to overwrite")

    pinned_commit = _git_head(repo) if repo else None

    os.makedirs(task_dir)
    shutil.copyfile(prompt_file, os.path.join(task_dir, "prompt.md"))
    with open(os.path.join(task_dir, "task.yml"), "w", encoding="utf-8") as handle:
        handle.write(_task_yml_text(task_id, task_class, mode, repo, pinned_commit))
    with open(os.path.join(task_dir, "checks.py"), "w", encoding="utf-8") as handle:
        handle.write(_CHECKS_STUB.format(task_id=task_id))
    with open(os.path.join(task_dir, "reference.md"), "w", encoding="utf-8") as handle:
        handle.write(_REFERENCE_STUB.format(task_id=task_id))

    return task_dir


def build_arg_parser():
    default_tasks_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tasks")
    parser = argparse.ArgumentParser(description="Snapshot a real completed task into evals/tasks/.")
    parser.add_argument("--id", required=True, dest="task_id")
    parser.add_argument("--class", required=True, dest="task_class", choices=TASK_CLASSES)
    parser.add_argument("--mode", required=True, choices=TASK_MODES)
    parser.add_argument("--repo", default=None)
    parser.add_argument("--prompt-file", required=True)
    parser.add_argument("--tasks-dir", default=default_tasks_dir)
    return parser


def main(argv=None):
    parser = build_arg_parser()
    args = parser.parse_args(argv)
    task_dir = capture_task(args.tasks_dir, args.task_id, args.task_class, args.mode, args.prompt_file, args.repo)
    print(f"captured task at {task_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
