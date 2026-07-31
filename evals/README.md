# evals

Agent-docs eval harness for PostHog: hands real tasks (sourced from actual work on
card-harbor and keeplings) to a headless Claude Code agent under controlled context
regimes, scores the outcome programmatically, and instruments every run with PostHog.
Full plan: `docs/evals-plan.html`.

## What this is

For each `(task, regime, trial)` cell, the runner:

1. resolves a throwaway workspace: a git worktree of the task's pinned commit when the
   task points at a repo, a plain temp dir for analysis-only tasks
2. assembles the context regime (`none`, `llms-txt`, `mcp`, or `bundle`)
3. invokes `claude -p --output-format json` with the task prompt plus any injected context
4. runs the task's `checks.py` in a sandboxed subprocess and normalizes any fault to the
   `check-infra` reason code
5. appends a journal entry and emits a `eval_run_completed` event to PostHog
6. always tears the workspace down, even on failure

No LLM judges anywhere in the pass/fail path: ground truth is API-verified state or a
human-verified answer over a pinned time window.

## Running

From inside `evals/`:

```
python -m runner.run                                  # full matrix from config.yml
python -m runner.run --tasks kp-release-impact         # one task, all configured regimes
python -m runner.run --regimes none,bundle --trials 2
python -m runner.run --dry-run                         # assemble everything, print the plan, invoke nothing
python -m runner.run --replay-dir path/to/fixtures      # replay canned claude responses instead of live calls
python -m runner.run --replay-dir path/to/fixtures --record   # live run, but also write fixtures for later replay
```

`--dry-run` never touches the journal or invokes claude; use it to check regime wiring
(context assembly, disallowed tools, bundle/snapshot hashes) for free.

Results land in `results/journal.jsonl` (append-only, one JSON object per line, resumable
by `(task, regime, trial)`) and `results/summary.json` (pass rate, mean cost, reason-code
histogram per `(task, regime)`, written after each batch).

## Env vars

| Var | Purpose |
|---|---|
| `EVALS_POSTHOG_PROJECT_KEY` | write key used to emit `eval_run_completed` events |
| `EVALS_POSTHOG_PERSONAL_KEY` | read access for dashboards; also the `mcp` regime's Authorization header |
| `EVALS_POSTHOG_SCRATCH_PROJECT_ID` | prospective-task and `mcp`-regime writes land only here, never in keeplings production |
| `EVALS_POSTHOG_KEEPLINGS_PROJECT_ID` | keeplings production project id the `kp-` tasks' reference HogQL queries run against |

Any run with the corresponding key absent is a no-op for that piece (PostHog capture
never crashes a run); the `mcp` regime writes an empty bearer token if its env var is unset.

## Adding a task

Prefer the capture command over hand-authoring:

```
python -m runner.capture --id kp-release-impact --class hogql-analysis --mode retrospective \
    --prompt-file /path/to/prompt.md
python -m runner.capture --id ch-renderer-capture --class install-instrumentation --mode prospective \
    --repo /path/to/card-harbor --prompt-file /path/to/prompt.md
```

This creates `tasks/<id>/` with `task.yml` (pinning the repo's current HEAD when `--repo`
is given), the prompt, a `checks.py` stub that raises `NotImplementedError` until filled
in, and a `reference.md` stub. It refuses to overwrite an existing task id.

`task.yml` fields: `id`, `class` (one of `install-instrumentation`, `hogql-analysis`,
`error-tracking`, `product-config`), `mode` (`prospective` | `retrospective`), `repo`,
`pinned_commit`, `prompt_file`, `time_window`, `bundle`, `captured`, `reference`.

`checks.py` must define `run_checks(workspace, task, config) -> dict` returning
`{"passed": bool, "reason_code": str, "detail": str}`. `reason_code` vocabulary: `pass`,
`wrong-answer`, `build-fail`, `wrong-api` (hallucinated SDK usage), `missing-events`,
`check-infra` (harness-side fault: poll timeout, API error, rate limit; excluded from
regime pass rates and always rerun).

## Regimes

- `none`: task prompt only.
- `llms-txt`: injects `bundles/snapshots/llms-txt.md`. A separate snapshot step downloads
  and freezes this file; the regime itself never fetches the web at run time and fails
  loudly with instructions if the snapshot is missing.
- `mcp`: writes a `.mcp.json` into the run workspace pointing at `https://mcp.posthog.com/mcp`,
  no doc injection.
- `bundle`: injects the task's hand-built context bundle from `bundles/<name>.md` (task.yml's
  `bundle` field); fails loudly if the task has no bundle configured or the file is missing.

`WebSearch`, `Task`, and `Agent` are always disallowed, in every regime, so every run stays
single-agent and never searches the open web. `WebFetch` is regime-dependent instead of a
blanket ban: posthog.com/llms.txt is a ~330 KB link index of doc URLs (`llms-full.txt` does
not exist), so its designed use is link-following, and blocking `WebFetch` in the `llms-txt`
regime would measure nothing. Only the `llms-txt` regime permits it, scoped via
`allowed_tools = ["WebFetch(domain:posthog.com)"]`; `none`, `mcp`, and `bundle` disallow it
outright so the regime stays the only context variable. Every piece of injected context is
sha256-hashed and recorded in the journal's `snapshot_hashes` (and `bundle_hash` for the
bundle regime specifically), so a docs change mid-experiment shows up as a hash mismatch,
not silent drift.

## Known context leakage

Every `ch-` task's worktree is a real checkout of card-harbor, so it carries
card-harbor's own `CLAUDE.md`/`AGENTS.md` into the agent's context in every regime,
including `none`. That leakage is constant across all four regimes, so regime
comparisons on `ch-` tasks still hold, but the `none` baseline is not a true
zero-context condition for those tasks.

## Replay and tests

`runner/claude_cli.py` supports replay (`--replay-dir DIR`, reads
`<DIR>/<task>_<regime>_<trial>.json` instead of invoking `claude`) and record
(`--record`, writes live responses to the same directory) so scored runs can be
reproduced offline. Fixture shape matches real `claude -p --output-format json` output
(see `compiled-commit/bench/fixtures/*_commit_message.json` for the precedent).

Tests use stdlib `unittest`, no pytest, and real temp git repos (no git mocking); only
external LLM and HTTP calls get canned. Run from inside `evals/`:

```
python -m unittest discover -s tests -v
```
