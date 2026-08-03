"""CLI: run the eval matrix over captured tasks (`python -m runner.run`).

Per cell (task, regime, trial): resolve a throwaway workspace (a git worktree of the
task's pinned commit when task.repo is set, a plain temp dir otherwise), assemble the
context regime, invoke claude, run the task's checks, append the journal, emit a
PostHog event, then always tear the workspace down. --dry-run assembles everything and
prints the plan without invoking claude, so regime wiring can be checked with no cost.
"""

import argparse
import dataclasses
import datetime
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from collections import Counter, defaultdict

import yaml

from runner import claude_cli, env_file, posthog_capture, regimes, scoring
from runner.journal import Journal, JournalEntry

EVALS_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _force_writable_and_retry(func, path, _exc_info):
    try:
        os.chmod(path, stat.S_IWRITE)
        func(path)
    except OSError:
        pass


def _rmtree_retry(path, attempts=5, delay=0.5):
    for _ in range(attempts):
        if not os.path.exists(path):
            return
        shutil.rmtree(path, onerror=_force_writable_and_retry)
        if not os.path.exists(path):
            return
        time.sleep(delay)
    shutil.rmtree(path, ignore_errors=True)


def load_task(task_dir):
    with open(os.path.join(task_dir, "task.yml"), "r", encoding="utf-8") as handle:
        task = yaml.safe_load(handle)
    task["_dir"] = os.path.abspath(task_dir)
    return task


def _build_prompt(task, assembly):
    prompt_path = os.path.join(task["_dir"], task.get("prompt_file", "prompt.md"))
    with open(prompt_path, "r", encoding="utf-8") as handle:
        task_prompt = handle.read()
    if not assembly.context_text:
        return task_prompt
    return f"```context\n{assembly.context_text}\n```\n\n{task_prompt}"


def _resolve_workspace(task):
    if not task.get("repo"):
        return tempfile.mkdtemp(prefix="evals-ws-"), None

    workspace = tempfile.mkdtemp(prefix="evals-ws-")
    _rmtree_retry(workspace)  # git worktree add requires the target dir not exist yet
    branch = f"evals/{task['id']}-{uuid.uuid4().hex[:8]}"
    subprocess.run(
        ["git", "worktree", "add", "-b", branch, workspace, task["pinned_commit"]],
        cwd=task["repo"], check=True, capture_output=True, text=True,
    )
    return workspace, (task["repo"], branch)


def _teardown_mcp_config(config_dir, config_path):
    """Delete the cell's MCP config, and blank the token first so a failed unlink is inert.

    _rmtree_retry falls back to ignore_errors, so a locked file would otherwise leave a
    readable bearer token behind with nothing said about it. Truncating first means the
    worst case is an empty file, and a surviving directory gets shouted about rather than
    passing silently.
    """
    if config_path:
        try:
            with open(config_path, "w", encoding="utf-8"):
                pass
        except OSError:
            pass
    _rmtree_retry(config_dir)
    if os.path.exists(config_dir):
        print(f"WARNING: could not remove MCP config dir {config_dir}; its .mcp.json has been "
              "emptied, but delete the directory by hand")
    regimes.discard_empty_config_root()


def _teardown_workspace(workspace, worktree_info):
    if worktree_info is None:
        _rmtree_retry(workspace)
        return
    repo, branch = worktree_info
    subprocess.run(["git", "worktree", "remove", "--force", workspace], cwd=repo, check=False, capture_output=True, text=True)
    subprocess.run(["git", "worktree", "prune"], cwd=repo, check=False, capture_output=True, text=True)
    subprocess.run(["git", "branch", "-D", branch], cwd=repo, check=False, capture_output=True, text=True)
    _rmtree_retry(workspace)


def _gross_tokens(usage):
    return usage["input_tokens"] + usage["cache_creation_input_tokens"] + usage["cache_read_input_tokens"] + usage["output_tokens"]


def _noncached_tokens(usage):
    return usage["input_tokens"] + usage["cache_creation_input_tokens"] + usage["output_tokens"]


def _infra_entry(task, regime, trial, wall_secs, model, detail):
    return JournalEntry(
        ts=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        task=task["id"], regime=regime, trial=trial, status="infra",
        passed=False, reason_code="check-infra", wall_secs=wall_secs, turns=None,
        usage={"gross": 0, "noncached": 0, "output": 0, "cache_read": 0, "cost_usd": 0.0},
        model=model, bundle_hash=None, snapshot_hashes={}, posthog_captured=False,
        detail=detail,
    )


def _print_plan(task, regime, trial, assembly, prompt):
    print(f"[dry-run] {task['id']} regime={regime} trial={trial}")
    print(f"  disallowed_tools={assembly.disallowed_tools}")
    print(f"  allowed_tools={assembly.allowed_tools}")
    print(f"  mcp_config_path={assembly.mcp_config_path}")
    if assembly.mcp_config_preview is not None:
        print(f"  mcp_config (not written in dry-run)={json.dumps(assembly.mcp_config_preview)}")
    print(f"  context_chars={len(assembly.context_text) if assembly.context_text else 0}")
    print(f"  snapshot_hashes={assembly.snapshot_hashes}")
    print(f"  prompt_chars={len(prompt)}")


def _make_entry(task, regime, trial, status, passed, reason_code, wall_secs, turns, usage, model,
                 bundle_hash, snapshot_hashes, detail):
    return JournalEntry(
        ts=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        task=task["id"], regime=regime, trial=trial, status=status,
        passed=passed, reason_code=reason_code, wall_secs=wall_secs, turns=turns, usage=usage,
        model=model, bundle_hash=bundle_hash, snapshot_hashes=snapshot_hashes, posthog_captured=False,
        detail=detail,
    )


def _token_budget_exceeded_entry(task, regime, trial, wall_secs, turns, usage, model, bundle_hash,
                                  snapshot_hashes, max_noncached_tokens):
    return _make_entry(
        task, regime, trial, status="infra", passed=False, reason_code="check-infra",
        wall_secs=wall_secs, turns=turns, usage=usage, model=model, bundle_hash=bundle_hash,
        snapshot_hashes=snapshot_hashes,
        detail=f"token-budget-exceeded: {usage['noncached']} > {max_noncached_tokens}",
    )


def _rate_limited_entry(task, regime, trial, wall_secs, turns, usage, model, bundle_hash, snapshot_hashes):
    # a zero-gross-token run means the CLI process never actually reached the model (a usage-limit
    # rejection is the observed cause); scoring an untouched workspace against checks.py would
    # misreport it as a genuine wrong-answer/build-fail, so it must never reach scoring at all
    return _make_entry(
        task, regime, trial, status="error", passed=None, reason_code="rate-limited",
        wall_secs=wall_secs, turns=turns, usage=usage, model=model, bundle_hash=bundle_hash,
        snapshot_hashes=snapshot_hashes,
        detail="claude invocation returned zero gross tokens (usage-limit or auth rejection); not scored",
    )


def run_cell(task, regime, trial, config, journal, replay_dir, record, dry_run, evals_root=None):
    cell_start = time.monotonic()
    workspace = None
    worktree_info = None
    assembly = None
    try:
        workspace, worktree_info = _resolve_workspace(task)
        assembly = regimes.assemble(regime, task, config, workspace, evals_root=evals_root,
                                    dry_run=dry_run)
        prompt = _build_prompt(task, assembly)

        if dry_run:
            _print_plan(task, regime, trial, assembly, prompt)
            return None

        start = time.monotonic()
        try:
            claude_result = claude_cli.run(
                prompt=prompt, model=config["model"], max_turns=config["max_turns"],
                cwd=workspace, disallowed_tools=assembly.disallowed_tools,
                task_id=task["id"], regime=regime, trial=trial,
                replay_dir=replay_dir, record=record, mcp_config_path=assembly.mcp_config_path,
                allowed_tools=assembly.allowed_tools,
                timeout_secs=config.get("run_timeout_secs", 1800),
            )
        except Exception as exc:
            entry = _infra_entry(task, regime, trial, time.monotonic() - start, config["model"],
                                  f"claude invocation failed: {exc!r}")
            journal.append(entry)
            return entry

        wall_secs = time.monotonic() - start
        usage = {
            "gross": _gross_tokens(claude_result.usage),
            "noncached": _noncached_tokens(claude_result.usage),
            "output": claude_result.usage["output_tokens"],
            "cache_read": claude_result.usage["cache_read_input_tokens"],
            "cost_usd": claude_result.total_cost_usd,
        }
        bundle_hash = assembly.snapshot_hashes.get("bundle")

        # reachable only after claude_cli.run() returns without raising, before checks.py runs,
        # so zero gross tokens here can only mean the subprocess/model call itself never landed
        # (rate limit, auth, network) -- never a downstream build/docs/checks failure
        if usage["gross"] == 0:
            entry = _rate_limited_entry(
                task, regime, trial, wall_secs, claude_result.num_turns, usage, config["model"],
                bundle_hash, assembly.snapshot_hashes,
            )
            journal.append(entry)
            return entry

        max_noncached_tokens = config.get("token_budget", {}).get("max_noncached_tokens_per_run")
        if max_noncached_tokens and usage["noncached"] > max_noncached_tokens:
            entry = _token_budget_exceeded_entry(
                task, regime, trial, wall_secs, claude_result.num_turns, usage, config["model"],
                bundle_hash, assembly.snapshot_hashes, max_noncached_tokens,
            )
            journal.append(entry)
            return entry

        check_result = scoring.score_task(
            task["_dir"], workspace, task, config,
            turns=claude_result.num_turns, max_turns=config.get("max_turns"),
        )

        status = "infra" if check_result["reason_code"] == "check-infra" else "completed"
        entry = JournalEntry(
            ts=datetime.datetime.now(datetime.timezone.utc).isoformat(),
            task=task["id"], regime=regime, trial=trial, status=status,
            passed=check_result["passed"], reason_code=check_result["reason_code"],
            wall_secs=wall_secs, turns=claude_result.num_turns, usage=usage,
            model=config["model"], bundle_hash=bundle_hash,
            snapshot_hashes=assembly.snapshot_hashes, posthog_captured=False,
            detail=check_result.get("detail", ""),
        )
        entry = dataclasses.replace(
            entry, posthog_captured=posthog_capture.capture_eval_run_completed(config, entry)
        )
        journal.append(entry)
        return entry
    except Exception as exc:
        if dry_run:
            raise
        entry = _infra_entry(task, regime, trial, time.monotonic() - cell_start, config["model"],
                              f"cell setup failed: {exc!r}")
        journal.append(entry)
        return entry
    finally:
        # the mcp config dir holds a live bearer token; it must not outlive the cell
        if assembly is not None and assembly.mcp_config_dir is not None:
            _teardown_mcp_config(assembly.mcp_config_dir, assembly.mcp_config_path)
        if workspace is not None:
            _teardown_workspace(workspace, worktree_info)


def iter_cells(tasks, regime_names, trials, model):
    for task in tasks:
        for regime in regime_names:
            for trial in range(1, trials + 1):
                yield task, regime, trial, model


def _summarize(journal, tasks, regime_names, trials, model):
    # scoped to the cells this invocation actually selected, so a summary.json from a
    # `--tasks`/`--regimes` subset run never picks up unrelated historical journal rows
    selected_cells = {
        (task["id"], regime, trial, model)
        for task, regime, trial, model in iter_cells(tasks, regime_names, trials, model)
    }

    cells = defaultdict(list)
    for key, row in journal.latest_by_cell().items():
        if key not in selected_cells:
            continue
        cells[(row["model"], row["task"], row["regime"])].append(row)

    summary_by_model = defaultdict(dict)
    for (row_model, task, regime), rows in cells.items():
        scored = [row for row in rows if row["status"] == "completed"]
        infra = [row for row in rows if row["status"] == "infra"]
        errored = [row for row in rows if row["status"] == "error"]
        pass_count = sum(1 for row in scored if row["passed"])
        summary_by_model[row_model][f"{task}::{regime}"] = {
            "task": task,
            "regime": regime,
            "model": row_model,
            "scored_trials": len(scored),
            "infra_trials": len(infra),
            "error_trials": len(errored),
            "total_trials": len(rows),
            "pass_rate": (pass_count / len(scored)) if scored else None,
            "mean_cost_usd": (sum(row["usage"]["cost_usd"] for row in scored) / len(scored)) if scored else None,
            "reason_code_histogram": dict(Counter(row["reason_code"] for row in rows)),
        }
    return dict(summary_by_model)


def build_arg_parser():
    parser = argparse.ArgumentParser(description="Run the eval matrix over captured tasks.")
    parser.add_argument("--tasks", default=None, help="comma separated task ids (default: all under tasks/)")
    parser.add_argument("--regimes", default=None, help="comma separated regime names (default: config regimes)")
    parser.add_argument("--headline", action="store_true",
                         help="run config's headline_regimes instead of the full regime set; "
                              "ignored if --regimes is also given")
    parser.add_argument("--trials", type=int, default=None)
    parser.add_argument("--model", default=None, help="overrides config's model for this invocation")
    parser.add_argument("--replay-dir", default=None)
    parser.add_argument("--record", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--tasks-dir", default=os.path.join(EVALS_ROOT, "tasks"))
    parser.add_argument("--results-dir", default=os.path.join(EVALS_ROOT, "results"))
    parser.add_argument("--config", default=os.path.join(EVALS_ROOT, "config.yml"))
    return parser


def main(argv=None):
    parser = build_arg_parser()
    args = parser.parse_args(argv)

    with open(args.config, "r", encoding="utf-8") as handle:
        config = yaml.safe_load(handle)

    all_task_ids = sorted(
        entry for entry in os.listdir(args.tasks_dir) if os.path.isdir(os.path.join(args.tasks_dir, entry))
    )
    wanted_ids = args.tasks.split(",") if args.tasks else all_task_ids
    tasks = [load_task(os.path.join(args.tasks_dir, task_id)) for task_id in wanted_ids]

    if args.regimes:
        regime_names = args.regimes.split(",")
    elif args.headline:
        regime_names = config["headline_regimes"]
    else:
        regime_names = config["regimes"]
    trials = args.trials or config["trials_per_cell"]
    if args.model:
        config["model"] = args.model
    model = config["model"]

    if args.record and not args.replay_dir:
        args.replay_dir = os.path.join(args.results_dir, "replays")

    evals_root = os.path.dirname(os.path.abspath(args.config))
    env_file.apply_env_file(os.path.join(evals_root, ".env"))
    journal = Journal(os.path.join(args.results_dir, "journal.jsonl"))
    # built once so the resume check below is O(1) per cell instead of re-reading the
    # whole journal on every iteration (O(n^2) over a large batch)
    latest_by_cell = journal.latest_by_cell() if not args.dry_run else {}

    invocation_count = 0
    batch_cap = config.get("runs_per_batch_cap")
    for task, regime, trial, cell_model in iter_cells(tasks, regime_names, trials, model):
        if not args.dry_run and journal.is_cell_completed(task["id"], regime, trial, cell_model, latest_by_cell):
            continue
        if not args.dry_run and batch_cap and invocation_count >= batch_cap:
            print(f"runs_per_batch_cap ({batch_cap}) reached; stopping batch early")
            break
        run_cell(task, regime, trial, config, journal, args.replay_dir, args.record, args.dry_run, evals_root)
        if not args.dry_run:
            invocation_count += 1

    if args.dry_run:
        print("dry run complete: no claude invocations made")
        return 0

    summary = _summarize(journal, tasks, regime_names, trials, model)
    os.makedirs(args.results_dir, exist_ok=True)
    with open(os.path.join(args.results_dir, "summary.json"), "w", encoding="utf-8") as handle:
        handle.write(json.dumps(summary, indent=2) + "\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())
