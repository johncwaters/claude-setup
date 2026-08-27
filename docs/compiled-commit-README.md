# compiled-commit

> Retired design record. The Python runner this describes was replaced by
> `skills/commit`, which inherits its stage decisions and its typed outcomes.
> Paths and commands below no longer exist.

A compiled, mostly-Python replacement for the `/commit` Claude Code skill. The historical
workflow (sync develop, ai-slop-cleaner subagent, code-review subagent, generate a commit
message, stage, commit) ran as a loose agentic loop: median 5.3M gross tokens, 56 LLM
calls, 26 tool calls, about 8 minutes, per historical session data in
private benchmark scenarios. This harness moves every stable, mechanical step (git
plumbing, diff scoping, message rendering, validation) into deterministic Python, and
keeps exactly three bounded LLM calls for the parts that genuinely need judgment.

## What it does

Runs a typed pipeline against a git repo: preflight checks, sync with the integration
branch, scope the change, build a bounded diff packet, run an AI-slop review (with an
optional auto-applied cleanup patch), run a severity-rated code review, generate a
conventional commit message, commit, push, and (with `--promote`) promote the change
outward. Every stage either advances the pipeline or returns a typed terminal outcome;
nothing falls through silently.

## Outward promotion (--promote)

`--promote` adds a final stage that moves the committed change outward along a fixed
chain by default: the feature branch into `develop`, then `develop` into the mainline
branch (`main`, falling back to `master`). `--promote-to develop` stops after updating
`develop` for PR flows where mainline is updated separately. It never skips `develop`:
mainline only ever receives merges from `develop`. `develop` is created off the mainline
tip (and pushed) when it does not exist. Each hop is a working-tree-free
fast-forward (`git fetch . <src>:<dst>`) whenever possible, so a dirty worktree does not
block promotion; when a hop cannot fast-forward, it falls back to a real merge that
requires a clean working tree and restores the original branch afterward. A commit made
directly on the mainline branch is left alone with a warning (promoting it would violate
the invariant). Promotion never force-pushes, never deletes branches, and never
auto-resolves conflicts. The branches it advanced are reported in the result's `promoted`
list.

## The three retained LLM calls

| Name | Purpose | Model | Schema | Bounded retries |
|---|---|---|---|---|
| `slop_review` | Find AI-authored slop (dead code, duplicated helpers, useless comments, over-abstraction) in the diff, optionally propose a cleanup patch | `claude-opus-5` (configurable via `--model`) | `src/schemas.py:SLOP_REVIEW_SCHEMA` | 2 retries on the findings call; the separate patch-apply-error retry is capped at exactly 1 extra attempt |
| `code_review` | Severity-rated review (critical/high/medium/low) of the final diff | `claude-opus-5` | `src/schemas.py:CODE_REVIEW_SCHEMA` | 1 retry; unparseable/invalid after 2 total attempts is a blocking `REVIEW_DEAD` |
| `commit_message` | Generate a conventional commit message from the final diff, branch, and recent commit subjects | `claude-opus-5` | `src/schemas.py:COMMIT_MESSAGE_SCHEMA` | 2 retries (3 total attempts); domain validation errors (banned characters, type enum, length, required trailers) are fed back into the retry the same way schema errors are; exhausted retries is `MESSAGE_INVALID` |

Every LLM call goes through `src/llm.py:LlmClient`, which enforces the
retry bound, records per-attempt token usage, and extracts the first balanced JSON object
from the response (stripping markdown fences first) regardless of live or replay mode.

## Required inputs

- Python 3.13, stdlib only, no pip dependencies.
- `git` on PATH.
- For live runs: the `claude` CLI on PATH, authenticated. The adapter invokes it as
  `claude -p --output-format json --model <model> --max-turns 2 --disallowedTools <all>`
  with the prompt on stdin (Windows argv length limits rule out passing it as an argument).
- A git repository to operate on (`--repo`, defaults to the current directory).

## Commands

Run against the current directory, live LLM calls:

```
python runner.py
```

Replay mode (LLM responses come from recorded fixtures, sync is implicitly skipped; no
fixtures ship in this repo, record them first with `--record`):

```
python runner.py --repo <path> --replay-fixtures bench/fixtures --json
```

Commit without pushing (automation, or any case where the caller wants the push done
separately):

```
python runner.py --repo <path> --no-push --message "chore: x"
```

Full CLI:

```
python runner.py [--repo PATH] [--message "..."] [--context "..."] [--no-sync]
                  [--skip-deslop] [--skip-review] [--replay-fixtures DIR] [--record DIR]
                  [--model ID] [--json] [--no-push] [--promote]
                  [--promote-to {develop,mainline}]
```

Run the tests (from this directory, so `src` resolves on `sys.path`):

```
python -m unittest discover -s tests -v
```

Run the benchmark after writing `bench/scenarios.json` for the target repo. Historical
scenario data, fixtures, and results were recorded against private repositories and are
not included:

```
python bench/run_bench.py [--ids a,b,c] [--holdout] [--out bench/results]
                           [--fixtures bench/fixtures] [--replay-llm]
```

`--replay-llm` uses a recorded fixture for a scenario only if one already exists at
`<fixtures>/<scenario-id>_commit_message.json`; otherwise it falls back to a live run and
records fixtures as it goes (when `--fixtures` is set). No fixtures are checked into this
repo, so the first `--replay-llm` invocation for a given scenario is effectively a live
run that seeds the fixture cache for subsequent ones.

Run the blind quality judge after the benchmark has produced results (one bounded LLM
call per scenario with a rendered message, comparing the historical message against the
compiled one in random, reproducible A/B order):

```
python bench/judge.py [--results bench/results] [--out bench/results/judge.json]
                       [--model ID] [--replay-fixtures DIR]
```

Judge token usage is written to `judge.json` only and is never merged into
`bench/results/summary.json`.

## Typed failure states

| Outcome | Exit code | Meaning |
|---|---|---|
| `COMMITTED` | 0 | Commit created successfully. Check the result's `pushed` field to see whether the push stage also succeeded; a skipped or unattempted push (no `origin` remote, or `--no-push`) still reports `COMMITTED` |
| `NOT_A_REPO` | 10 | `--repo` is not inside a git working tree |
| `DETACHED_HEAD` | 11 | HEAD is detached |
| `OPERATION_IN_PROGRESS` | 12 | A merge, rebase, or cherry-pick is already in progress |
| `NOTHING_TO_COMMIT` | 13 | No changed or (non-denylisted) untracked files, either at scope time or at commit time. With `--promote`, a clean tree at scope time does not stop the run: stages 4 through 9 are skipped and promotion runs anyway from the current branch (an idempotent carry of develop into mainline unless `--promote-to develop` stops at develop). The outcome stays `NOTHING_TO_COMMIT`, but `promoted` and any promote warnings are populated; a promotion failure on this path still surfaces as `PROMOTE_CONFLICT` or `PROMOTE_FAILED` |
| `SYNC_DIVERGED` | 14 | The local integration branch has diverged from `origin` (non-fast-forward) |
| `MERGE_CONFLICT` | 15 | Sync merge conflicted; merge was aborted, no `MERGE_HEAD` left behind |
| `GATE_FAILED` | 16 | The workspace confinement assertion failed (see below) |
| `REVIEW_DEAD` | 17 | The code review call produced no valid response after its bounded retries |
| `REVIEW_BLOCKED` | 18 | The code review found a critical or high severity issue |
| `SLOP_PATCH_INVALID` | 19 | Non-terminal warning: a proposed slop cleanup patch failed `git apply --check` twice; findings are kept, the patch is dropped, and the pipeline continues |
| `MESSAGE_INVALID` | 20 | The commit message failed schema or convention validation after its bounded retries |
| `HOOK_FAILED` | 21 | `git commit` exited nonzero (e.g. a pre-commit hook failed) |
| `PUSH_FAILED` | 22 | The commit succeeded but all 3 `git push` attempts (or `git push -u origin <branch>` attempts when there was no upstream) exited nonzero; `commit_hash` is still populated in the result, and each failed attempt's stderr is captured as a warning |
| `PROMOTE_CONFLICT` | 23 | A `--promote` hop could not fast-forward and the fallback merge conflicted; the merge was aborted and the original branch restored. `commit_hash`, `commit_message`, `pushed`, and `findings` stay populated; the conflicting files are captured as a warning |
| `PROMOTE_FAILED` | 24 | A `--promote` hop could not complete: local develop/mainline diverged from origin and the recovery merge could not be attempted or restored cleanly, the target's holding worktree was dirty or could not fast-forward, the fallback merge needed a clean working tree that was dirty, the merge target could not be checked out, the post-merge restore checkout failed (the merge landed locally but the push was skipped and the repo is left on the target branch), or all 3 promotion push attempts exited nonzero. Earlier-stage result fields stay populated and the stderr or reason is captured as a warning |

`SLOP_PATCH_INVALID` is listed as a warning code, not a terminal `outcome` value: it is
recorded as a warning string and the pipeline continues to the next stage, per SPEC.

## Side-effect boundary

- Writes only inside `--repo` (the git working tree being committed) or, in the
  benchmark, inside a `tempfile.mkdtemp()` directory. `Pipeline._workspace_confined()`
  asserts the repo path is the workspace or nested inside it before any other stage runs;
  a violation is `GATE_FAILED` before a single git command executes.
- Pushes by default after a successful commit: Stage 9 runs `git push` when the current
  branch already has an upstream, `git push -u origin <branch>` when it does not, and
  retries nonzero push exits up to 2 more times before returning `PUSH_FAILED`. `origin`
  not being configured is not an error; it is a skip, with a warning, and the outcome
  stays `COMMITTED`. `--no-push` opts out entirely (the stage still runs and is recorded
  in `stages_run` as `PUSH(skipped)`, it just never touches git). The benchmark
  (`bench/run_bench.py`) always passes `no_push=True` and never overrides it: a replay
  clone's `origin` is `git clone <local-repo>`, i.e. the real repository the scenario data
  came from, so a push from a disposable replay branch would write into it.
- Never passes `--no-verify` to git; commit hooks run normally and a nonzero exit from
  `git commit` is surfaced as `HOOK_FAILED` with the hook's stderr.
- The only network operations are `git fetch` during the sync stage (skipped by
  `--no-sync` or in replay mode), `git push` during the push stage (skipped by
  `--no-push`, no `origin`, or in the benchmark), and the `claude` CLI subprocess in live
  LLM mode.
- Temp files (slop patches, the commit message file) are written under
  `<workspace>/.compiled-commit-tmp/` and the commit message file is deleted immediately
  after the commit attempt, success or failure.

## Installed activation layer

Installed on 2026-07-24 with user approval: `~/.claude/commands/commit.md` now contains a
thin activation layer that invokes this runner and relays its typed result. The original
prose workflow is archived at `~/.claude/commands/commit.md.pre-compiled.bak`. The runner
accepts `--context "one line of intent"` so the calling agent can pass session knowledge of
why the change was made into the commit_message call.

## What is verified vs not

Verified by the test suite (`tests/`, all real temp git repos, no git mocking): preflight
outcomes, scope detection and the untracked denylist, diff packet truncation and the
60000-character budget with largest-section-first dropping, every commit message
convention rule (banned characters, type enum, length, trailing period, required
trailers, exact rendering), the slop patch apply gate (invalid patch rejected, valid
patch applied and re-staged), the commit stage (real commit, hash resolvable, message
file cleanup, staged-empty guard), the push stage (push from a feature branch with no
upstream configured advances a real bare-repo `origin` ref, a flaky pre-push hook is
retried successfully, an always-failing pre-push hook exhausts all 3 attempts as
`PUSH_FAILED`, a repo with no `origin` commits successfully with push skipped and a
warning present, a push to a since-deleted `origin` is `PUSH_FAILED` with `commit_hash`
still populated), sync (clean feature-branch
merge, diverged local branch, conflicting merge with a verified clean abort), the LLM
replay adapter end to end through a real commit, workspace confinement, and outward
promotion (`--promote`: the full feature/develop/mainline fast-forward chain with pushes,
develop-only promotion for PR flows, auto-creation of a missing develop, the
commit-on-develop and commit-on-mainline cases, a
non-fast-forward hop that conflicts with a verified clean abort and branch restore, a
non-fast-forward hop that merges cleanly, flaky promote-push retry, clean local mainline
divergence recovery from origin, conflicting local mainline divergence with a verified
clean abort and branch restore, local-only promotion with no origin, a dirty unrelated
file surviving fast-forward hops, and a master-only repo).

Verified after implementation, during the benchmark phase: `bench/run_bench.py` executed
end to end with live sonnet calls against all 13 private scenarios (11 COMMITTED,
2 REVIEW_BLOCKED; fixtures recorded privately and not included; the bench baseline
predates the move to `claude-opus-5`); `bench/judge.py`
executed against the 11 committed scenarios. The full results report is not included
(recorded before the push stage existed, so it predates `pushed` in the result JSON).

Not verified: live slop-patch application on a user repository (exercised only in temp-clone
replay), live sync or push against a real hosted origin remote such as GitHub (exercised
only against local bare-repo origins in tests), and hook-failure surfacing with real
pre-commit hooks.

## Proposed installation (NOT executed)

Installation was not performed. If adopted, `~/.claude/commands/commit.md` would be
replaced with a thin activation instruction along these lines:

```
Run `python ~/.claude/compiled-commit/runner.py --repo <cwd> --json` and
relay its typed result to the user: the outcome, the commit hash or rendered message,
any findings or warnings. Do not reimplement any of the pipeline's steps yourself. If the
outcome indicates a blocking failure (REVIEW_BLOCKED, REVIEW_DEAD, MESSAGE_INVALID,
MERGE_CONFLICT, SYNC_DIVERGED, HOOK_FAILED, GATE_FAILED), report it and stop; do not
retry with different flags without the user's direction.
```

This file was not written or installed anywhere under `~/.claude/`.

## Deviations from SPEC

SPEC left a few points under-specified; here is what was chosen and why, per the
"pick the simplest reading, note it here" instruction.

- **`GATE_FAILED`** is not described by any stage in SPEC's pipeline walkthrough beyond
  being listed in the terminal `Outcome` enum. It is used exclusively for the workspace
  confinement assertion failing before Stage 1 runs.
- **`git fetch` failure during sync** (e.g. no `origin` remote configured, which is the
  common case for a throwaway or purely local repo) is not addressed by SPEC's sync
  walkthrough. Treating a failed fetch as a hard `SYNC_DIVERGED` or `MERGE_CONFLICT` would
  be misleading (neither condition actually occurred), so a failed fetch is recorded as a
  warning and sync is skipped, exactly like the "no integration branch found" case.
- **`slop_review` call failure** (the LLM call itself never returns a valid response,
  independent of the separate patch-apply gate) has no named terminal outcome in SPEC.
  It is recorded as a warning and the pipeline continues with no slop findings, since
  slop review is advisory and SPEC only defines a hard stop for the *review* stage
  (`REVIEW_DEAD`), not the slop stage.
- **Retry counts** not pinned down by SPEC's exact wording were chosen per stage:
  `slop_review` findings call gets 2 retries (matching the general "bounded retries"
  framing); the slop patch-apply-error retry is exactly 1 extra attempt as SPEC states
  ("retry the call once"); `code_review` gets 1 retry (2 total attempts, matching SPEC's
  "after 2 attempts" wording); `commit_message` gets 2 retries (3 total attempts, matching
  SPEC's "Retry <= 2" wording).
- **Fixture key format** (`<scenario>_<call>`) is caller-supplied per SPEC. `runner.py`
  uses a fixture prefix of `"run"` for standalone CLI usage (no scenario concept exists
  outside the benchmark); `bench/run_bench.py` uses the scenario id as the prefix.
- **Diff packet char-budget dropping** ("drop whole file sections smallest-last") is read
  as: drop the largest section first, repeatedly, until under budget, so the smallest
  sections survive longest.
