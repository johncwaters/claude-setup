"""Blind quality judge: one bounded LLM call per scenario comparing the historical
commit message against the compiled one (SPEC "Judge"). Economics here are reported
separately from bench/run_bench.py and never merged into the benchmark totals.
"""

import argparse
import glob
import hashlib
import json
import os
import subprocess
import sys

_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)

from src.llm import DEFAULT_MODEL, LlmClient

JUDGE_SCHEMA = {
    "type": "object",
    "required": ["winner", "reason"],
    "properties": {
        "winner": {"type": "string", "enum": ["A", "B", "tie"]},
        "reason": {"type": "string"},
    },
}


def _load_scenario_records(results_dir):
    records = []
    for path in sorted(glob.glob(os.path.join(results_dir, "*.json"))):
        if os.path.basename(path) in ("summary.json", "judge.json"):
            continue
        with open(path, "r", encoding="utf-8") as handle:
            records.append(json.load(handle))
    return records


def _diffstat(repo, commit, max_lines=80):
    proc = subprocess.run(
        ["git", "show", "--stat", "--format=", commit],
        cwd=repo,
        capture_output=True,
        text=True,
    )
    lines = proc.stdout.splitlines()
    return "\n".join(lines[:max_lines])


def _historical_first(scenario_id):
    digest = hashlib.sha256(scenario_id.encode("utf-8")).hexdigest()
    return int(digest[:8], 16) % 2 == 0


def _map_winner(winner_slot, historical_first):
    if winner_slot == "tie":
        return "tie"
    winner_is_a = winner_slot == "A"
    return "historical" if (winner_is_a == historical_first) else "compiled"


def _build_prompt(diffstat, message_a, message_b):
    return "\n".join(
        [
            "Task: given a diffstat and two candidate commit messages (A and B), decide "
            "which better follows good commit message practice: accurate, right level of "
            "detail, no fluff, explains why not just what. Output tie only if truly "
            "indistinguishable in quality.",
            "",
            "diffstat:",
            diffstat,
            "",
            "Message A:",
            message_a,
            "",
            "Message B:",
            message_b,
        ]
    )


def judge_scenario(record, llm_client):
    if not record.get("commit_message"):
        return None

    historical_message = record["historical"]["message"]
    compiled_message = record["commit_message"]
    first = _historical_first(record["id"])
    message_a = historical_message if first else compiled_message
    message_b = compiled_message if first else historical_message

    diffstat = _diffstat(record["repo"], record["source_commit"])
    prompt = _build_prompt(diffstat, message_a, message_b)

    parsed, usage, errors = llm_client.call(
        name="judge",
        key=f"judge_{record['id']}",
        prompt_body=prompt,
        schema=JUDGE_SCHEMA,
        max_retries=1,
    )

    usage_dicts = [vars(u) for u in usage]
    if parsed is None:
        return {"id": record["id"], "winner": "JUDGE_FAILED", "errors": errors, "usage": usage_dicts}

    return {
        "id": record["id"],
        "winner": _map_winner(parsed["winner"], first),
        "reason": parsed["reason"],
        "order": "historical_first" if first else "compiled_first",
        "usage": usage_dicts,
    }


def build_arg_parser():
    parser = argparse.ArgumentParser(description="Blind A/B judge for compiled vs historical commit messages.")
    parser.add_argument("--results", default=os.path.join("bench", "results"))
    parser.add_argument("--out", default=None)
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--replay-fixtures", default=None)
    return parser


def main(argv=None):
    parser = build_arg_parser()
    args = parser.parse_args(argv)
    out_path = args.out or os.path.join(args.results, "judge.json")

    mode = "replay" if args.replay_fixtures else "live"
    llm_client = LlmClient(mode=mode, model=args.model, fixtures_dir=args.replay_fixtures)

    records = _load_scenario_records(args.results)
    verdicts = [v for v in (judge_scenario(record, llm_client) for record in records) if v is not None]

    totals = {"historical": 0, "compiled": 0, "tie": 0, "JUDGE_FAILED": 0}
    for verdict in verdicts:
        key = verdict.get("winner", "JUDGE_FAILED")
        if key not in totals:
            key = "JUDGE_FAILED"
        totals[key] += 1

    output = {"verdicts": verdicts, "totals": totals}
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as handle:
        json.dump(output, handle, indent=2)

    print(json.dumps(totals, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
