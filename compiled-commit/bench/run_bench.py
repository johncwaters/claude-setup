"""Replay benchmark: measures the compiled pipeline's economics against the historical
Claude Code sessions recorded in bench/scenarios.json (SPEC "Benchmark").

Each scenario's historical commit is replayed onto a disposable local clone: check out
the commit's parent, cherry-pick the commit without committing, then reset so the
worktree is dirty with exactly the historical change (new files stay untracked). The
compiled pipeline then runs in-process against that clone.
"""

import argparse
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time

_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)

from src.llm import DEFAULT_MODEL, LlmClient
from src.pipeline import Pipeline, PipelineConfig

SCENARIOS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "scenarios.json")


def load_scenarios(holdout):
    with open(SCENARIOS_PATH, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    key = "holdout" if holdout else "primary"
    return data[key]


def _run_git(cwd, args, check=True):
    proc = subprocess.run(["git"] + args, cwd=cwd, capture_output=True, text=True)
    if check and proc.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed in {cwd}: {proc.stderr}")
    return proc


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
    # Best effort only: this is scratch space under system TEMP, not load-bearing state.
    shutil.rmtree(path, ignore_errors=True)


def _prepare_worktree(scenario, tempdir):
    repo_dir = os.path.join(tempdir, "repo")
    _run_git(tempdir, ["clone", "-q", scenario["repo"], repo_dir])
    _run_git(repo_dir, ["config", "user.name", "Bench"])
    _run_git(repo_dir, ["config", "user.email", "bench@example.com"])
    _run_git(repo_dir, ["config", "commit.gpgsign", "false"])

    branch = f"replay/{scenario['id']}"
    checkout = _run_git(repo_dir, ["checkout", "-q", "-b", branch, scenario["parent"]], check=False)
    if checkout.returncode != 0:
        return None, f"checkout of parent {scenario['parent']} failed: {checkout.stderr.strip()}"

    cherry = _run_git(repo_dir, ["cherry-pick", "-n", scenario["commit"]], check=False)
    if cherry.returncode != 0:
        _run_git(repo_dir, ["cherry-pick", "--abort"], check=False)
        return None, f"cherry-pick of {scenario['commit']} failed: {cherry.stderr.strip()}"

    _run_git(repo_dir, ["reset"], check=False)
    return repo_dir, None


def _usage_totals(usage_list):
    gross = sum(
        u.input_tokens + u.cache_creation_input_tokens + u.cache_read_input_tokens + u.output_tokens
        for u in usage_list
    )
    noncached = sum(u.input_tokens + u.cache_creation_input_tokens + u.output_tokens for u in usage_list)
    output = sum(u.output_tokens for u in usage_list)
    return gross, noncached, output


def _pct_change(old, new):
    if old == 0:
        return None
    return (new - old) / old * 100.0


def _compare(historical, gross, noncached, output_tokens, llm_calls, tool_calls, duration):
    return {
        "gross_tokens": {
            "old": historical["gross_tokens"],
            "new": gross,
            "pct_change": _pct_change(historical["gross_tokens"], gross),
        },
        "noncached_tokens": {
            "old": historical["noncached_tokens"],
            "new": noncached,
            "pct_change": _pct_change(historical["noncached_tokens"], noncached),
        },
        "output_tokens": {
            "old": historical["output_tokens"],
            "new": output_tokens,
            "pct_change": _pct_change(historical["output_tokens"], output_tokens),
        },
        "llm_calls": {
            "old": historical["llm_calls"],
            "new": llm_calls,
            "pct_change": _pct_change(historical["llm_calls"], llm_calls),
        },
        "tool_calls": {
            "old": historical["tool_calls"],
            "new": tool_calls,
            "pct_change": _pct_change(historical["tool_calls"], tool_calls),
        },
        "duration_sec": {
            "old": historical["duration_sec"],
            "new": duration,
            "pct_change": _pct_change(historical["duration_sec"], duration),
        },
    }


def _write_scenario_result(out_dir, scenario_id, record):
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, f"{scenario_id}.json")
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(record, handle, indent=2)
    return path


def run_scenario(scenario, fixtures_dir, out_dir, replay_llm, model):
    tempdir = tempfile.mkdtemp(prefix=f"cc-bench-{scenario['id']}-")
    try:
        repo_dir, error = _prepare_worktree(scenario, tempdir)
        if error:
            record = {
                "id": scenario["id"],
                "repo": scenario["repo"],
                "source_commit": scenario["commit"],
                "outcome": "REPLAY_INFEASIBLE",
                "reason": error,
            }
            _write_scenario_result(out_dir, scenario["id"], record)
            return record

        fixture_marker = os.path.join(fixtures_dir or "", f"{scenario['id']}_commit_message.json")
        use_replay = replay_llm and fixtures_dir and os.path.isfile(fixture_marker)
        mode = "replay" if use_replay else "live"

        llm_client = LlmClient(
            mode=mode,
            model=model,
            fixtures_dir=fixtures_dir,
            record=(mode == "live" and bool(fixtures_dir)),
            cwd=repo_dir,
        )

        config = PipelineConfig(
            repo=repo_dir,
            workspace=tempdir,
            no_sync=True,
            # The replay clone's origin IS the user's real repository (we `git clone
            # <local-repo>` above), so a push from this disposable branch would write
            # into it. The benchmark must never push, no matter what.
            no_push=True,
            llm_client=llm_client,
            fixture_prefix=scenario["id"],
        )

        start = time.monotonic()
        result = Pipeline(config).run()
        wall_time = time.monotonic() - start

        gross, noncached, output_tokens = _usage_totals(result.llm_usage)
        historical = scenario["historical"]

        record = {
            "id": scenario["id"],
            "repo": scenario["repo"],
            "source_commit": scenario["commit"],
            "outcome": result.outcome.value,
            "commit_message": result.commit_message,
            "wall_time_sec": wall_time,
            "git_op_count": result.git_op_count,
            "llm_call_count": len(result.llm_usage),
            "gross_tokens": gross,
            "noncached_tokens": noncached,
            "output_tokens": output_tokens,
            "warnings": result.warnings,
            "findings": result.findings,
            "historical": historical,
            "comparison": _compare(
                historical, gross, noncached, output_tokens, len(result.llm_usage), result.git_op_count, wall_time
            ),
        }
        _write_scenario_result(out_dir, scenario["id"], record)
        return record
    finally:
        _rmtree_retry(tempdir)


def _aggregate(records, out_dir):
    feasible = [r for r in records if r.get("outcome") != "REPLAY_INFEASIBLE"]
    infeasible = [r for r in records if r.get("outcome") == "REPLAY_INFEASIBLE"]

    fields = ("gross_tokens", "noncached_tokens", "output_tokens", "llm_calls", "tool_calls", "duration_sec")
    totals_old = {field: 0 for field in fields}
    totals_new = {field: 0 for field in fields}

    for record in feasible:
        historical = record["historical"]
        totals_old["gross_tokens"] += historical["gross_tokens"]
        totals_old["noncached_tokens"] += historical["noncached_tokens"]
        totals_old["output_tokens"] += historical["output_tokens"]
        totals_old["llm_calls"] += historical["llm_calls"]
        totals_old["tool_calls"] += historical["tool_calls"]
        totals_old["duration_sec"] += historical["duration_sec"]

        totals_new["gross_tokens"] += record["gross_tokens"]
        totals_new["noncached_tokens"] += record["noncached_tokens"]
        totals_new["output_tokens"] += record["output_tokens"]
        totals_new["llm_calls"] += record["llm_call_count"]
        totals_new["tool_calls"] += record["git_op_count"]
        totals_new["duration_sec"] += record["wall_time_sec"]

    aggregate_comparison = {
        field: {
            "old": totals_old[field],
            "new": totals_new[field],
            "pct_change": _pct_change(totals_old[field], totals_new[field]),
        }
        for field in fields
    }

    summary = {
        "scenario_count": len(records),
        "feasible_count": len(feasible),
        "infeasible_count": len(infeasible),
        "infeasible_ids": [r["id"] for r in infeasible],
        "aggregate": aggregate_comparison,
        "per_scenario": records,
    }

    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "summary.json"), "w", encoding="utf-8") as handle:
        json.dump(summary, handle, indent=2)

    return summary


def build_arg_parser():
    parser = argparse.ArgumentParser(description="Replay historical commits through the compiled pipeline.")
    parser.add_argument("--ids", default=None, help="Comma separated scenario ids to run (default: all)")
    parser.add_argument("--holdout", action="store_true", help="Use the holdout set instead of primary")
    parser.add_argument("--out", default=os.path.join("bench", "results"))
    parser.add_argument("--fixtures", default=os.path.join("bench", "fixtures"))
    parser.add_argument(
        "--replay-llm",
        action="store_true",
        help="Use recorded fixtures instead of live LLM calls when a fixture exists for the scenario",
    )
    parser.add_argument("--model", default=DEFAULT_MODEL)
    return parser


def main(argv=None):
    parser = build_arg_parser()
    args = parser.parse_args(argv)

    scenarios = load_scenarios(args.holdout)
    if args.ids:
        wanted = set(args.ids.split(","))
        scenarios = [s for s in scenarios if s["id"] in wanted]

    records = []
    for scenario in scenarios:
        print(f"[bench] running {scenario['id']} ({scenario['repo']})")
        record = run_scenario(scenario, args.fixtures, args.out, args.replay_llm, args.model)
        records.append(record)
        print(f"[bench] {scenario['id']}: {record['outcome']}")

    summary = _aggregate(records, args.out)
    print(json.dumps(summary["aggregate"], indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
