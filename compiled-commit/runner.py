"""CLI entry point for the compiled-commit pipeline (SPEC Runner)."""

import argparse
import os
import sys

from src.failures import EXIT_CODES
from src.llm import DEFAULT_MODEL, LlmClient
from src.pipeline import Pipeline, PipelineConfig


def build_arg_parser():
    parser = argparse.ArgumentParser(
        prog="runner.py",
        description="Compiled replacement for the /commit workflow: sync, deslop, review, "
        "message, commit, in a bounded number of LLM calls.",
    )
    parser.add_argument("--repo", default=None, help="Repo path (default: current directory)")
    parser.add_argument("--message", default=None, help="Skip the message stage, use this text")
    parser.add_argument(
        "--context",
        default=None,
        help="One line of author intent, passed to the message call to explain the why",
    )
    parser.add_argument(
        "--paths",
        nargs="+",
        default=None,
        help="Restrict scope, diff, and staging to these files/dirs (default: whole tree)",
    )
    parser.add_argument("--no-sync", action="store_true", help="Skip the sync stage")
    parser.add_argument("--skip-deslop", action="store_true", help="Skip the slop review stage")
    parser.add_argument("--skip-review", action="store_true", help="Skip the code review stage")
    parser.add_argument(
        "--replay-fixtures",
        default=None,
        help="Directory of recorded LLM fixtures; enables replay mode and implies no-sync",
    )
    parser.add_argument(
        "--record",
        default=None,
        help="Directory to record live LLM responses as fixtures (live mode only)",
    )
    parser.add_argument("--model", default=DEFAULT_MODEL, help=f"LLM model (default: {DEFAULT_MODEL})")
    parser.add_argument("--json", action="store_true", help="Print only the full result JSON")
    parser.add_argument(
        "--no-push",
        action="store_true",
        help="Skip the push stage after a successful commit (for automation and benchmarks)",
    )
    return parser


def _build_llm_client(args):
    if args.replay_fixtures:
        return LlmClient(mode="replay", model=args.model, fixtures_dir=args.replay_fixtures, cwd=args.repo)
    return LlmClient(
        mode="live",
        model=args.model,
        fixtures_dir=args.record,
        record=bool(args.record),
        cwd=args.repo,
    )


def _print_human(result):
    for stage in result.stages_run:
        print(f"[stage] {stage}")
    for warning in result.warnings:
        print(f"[warn] {warning}")
    print(f"outcome: {result.outcome.value}")
    if result.commit_hash:
        print(f"commit: {result.commit_hash}")
        print(f"pushed: {result.pushed}")
    if result.commit_message:
        print("message:")
        print(result.commit_message)


def main(argv=None):
    parser = build_arg_parser()
    args = parser.parse_args(argv)
    args.repo = args.repo or os.getcwd()

    llm_client = _build_llm_client(args)

    config = PipelineConfig(
        repo=args.repo,
        workspace=args.repo,
        message=args.message,
        no_sync=args.no_sync,
        skip_deslop=args.skip_deslop,
        skip_review=args.skip_review,
        no_push=args.no_push,
        llm_client=llm_client,
        context=args.context,
        paths=args.paths,
    )

    result = Pipeline(config).run()

    if args.json:
        print(result.to_json())
        return EXIT_CODES.get(result.outcome, 1)

    _print_human(result)
    return EXIT_CODES.get(result.outcome, 1)


if __name__ == "__main__":
    sys.exit(main())
