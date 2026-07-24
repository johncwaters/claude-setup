# SPEC: compiled-commit harness

Compiled replacement for the `/commit` Claude Code skill (`~/.claude/commands/commit.md`).
Historical workflow: sync develop, ai-slop-cleaner, code-review via subagents, generate commit
message per convention, stage, commit. Median historical run: 5.3M gross tokens, 56 LLM calls,
26 tool calls, ~8 minutes. The compiled version moves all stable procedure into Python and
retains exactly 3 bounded LLM calls.

## Constraints (hard)

- Python 3.13 stdlib only. No pip dependencies. Windows-first (paths, subprocess), but use
  portable code.
- No em dashes or en dashes anywhere (prose, code, comments). No emoji.
- Never write `else` statements. Use early returns and guard clauses. Ternaries allowed.
- Comments: minimal, why-only.
- No `--no-verify`. Push happens only in Stage 9 (default on, `--no-push` opts out; the
  benchmark always opts out). No other network operations except `git fetch` inside sync
  (live mode only) and the `claude` CLI subprocess.
- All replay writes confined to a caller-supplied workspace directory. Assert this.

## Directory layout (create under C:\Users\johnw\.claude\compiled-commit)

- `runner.py` (top level entry, argparse CLI)
- `src/pipeline.py` (state machine)
- `src/git_ops.py` (all git subprocess calls, with an op counter)
- `src/llm.py` (bounded LLM adapter: live via `claude -p`, replay via fixtures)
- `src/schemas.py` (JSON schema dicts + a small stdlib validator function)
- `src/validators.py` (commit message convention validation, diff bounding)
- `src/failures.py` (typed failure enum + result dataclasses)
- `tests/` (unittest, run via `python -m unittest discover -s tests`)
- `bench/scenarios.json` (already exists, do not modify)
- `bench/run_bench.py` (replay benchmark, see below)
- `bench/judge.py` (blind quality judge, separate from benchmark economics)

## Pipeline (src/pipeline.py)

Typed state machine. Each stage returns either next state or a typed terminal failure.
Terminal states (failures.py enum `Outcome`): COMMITTED, NOT_A_REPO, DETACHED_HEAD,
OPERATION_IN_PROGRESS, NOTHING_TO_COMMIT, SYNC_DIVERGED, MERGE_CONFLICT, GATE_FAILED,
REVIEW_DEAD, REVIEW_BLOCKED, SLOP_PATCH_INVALID (warning, non-terminal), MESSAGE_INVALID,
HOOK_FAILED, PUSH_FAILED.

Result object (dataclass, serialized to JSON on stdout at end): outcome, commit_hash,
commit_message, findings (slop + review), warnings, llm_usage (per call: name, model,
input_tokens, cache_creation_input_tokens, cache_read_input_tokens, output_tokens,
duration_ms, retries), git_op_count, wall_time_sec, stages_run.

### Stage 1 PREFLIGHT
`git rev-parse --is-inside-work-tree` -> NOT_A_REPO.
`git rev-parse --abbrev-ref HEAD` == "HEAD" -> DETACHED_HEAD.
Any of MERGE_HEAD / REBASE_HEAD / CHERRY_PICK_HEAD resolve (`git rev-parse -q --verify`) ->
OPERATION_IN_PROGRESS.

### Stage 2 SYNC (skipped when --no-sync or replay mode; record skip in stages_run)
Resolve integration branch: first existing of develop, main, master via
`git rev-parse -q --verify refs/heads/<b>` (fallback `refs/remotes/origin/<b>`). None -> skip
with warning.
Current branch equals integration branch: `git fetch origin <b>` then
`git merge --no-edit origin/<b>`.
Feature branch: `git fetch origin <b>`, `git fetch origin <b>:<b>` (non-fast-forward rejection
-> SYNC_DIVERGED stop; "checked out in another worktree" error -> merge origin/<b> directly
with warning), then `git merge --no-edit <b>`.
Merge conflict -> `git merge --abort`, MERGE_CONFLICT stop, list conflicting files.

### Stage 3 SCOPE
Changed = union of `git diff --name-only HEAD` and `git diff --cached --name-only`.
Untracked candidates = `git status --short` lines starting `??`. Include untracked files by
default (they are part of the change), but exclude obvious junk via denylist
(node_modules/, dist/, .env*, *.log, __pycache__/). Both empty -> NOTHING_TO_COMMIT.

### Stage 4 DIFF PACKET (src/validators.py build_diff_packet)
`git diff HEAD` for tracked; for each included untracked file under 20KB append a synthetic
`+++ b/<path>` section with its content. Deterministic truncation: per file max 400 diff
lines (append marker `[truncated N lines]`), total packet max 60000 chars (drop whole file
sections smallest-last, note dropped files). Packet also includes `git status --short` output
and current branch name.

### Stage 5 SLOP (LLM call name "slop_review", skipped when --skip-deslop)
Purpose: find AI slop (dead code, duplicated helpers, useless comments, over-abstraction) in
the diff and optionally propose a cleanup patch.
Input: diff packet. Output schema: `{"findings": [{"file": str, "issue": str, "category":
str}], "patch": str|null}`. patch is a unified diff touching only changed files.
Gate: if patch present, `git apply --check` it in the workspace; on failure retry the call
once with the apply error appended; on second failure record warning SLOP_PATCH_INVALID and
continue findings-only. On success: apply, then re-run SCOPE and rebuild the diff packet.

### Stage 6 REVIEW (LLM call name "code_review", skipped when --skip-review)
Purpose: severity-rated review of the final diff.
Output schema: `{"verdict": "approve"|"block", "findings": [{"severity":
"critical"|"high"|"medium"|"low", "file": str, "line": int|null, "issue": str, "fix": str}]}`.
Validation: severity enum; finding.file must be in changed set (drop others with warning).
Unparseable/invalid after 2 attempts -> REVIEW_DEAD (blocking stop, never fall through).
Any critical or high finding -> REVIEW_BLOCKED stop, findings in result.
verdict "block" with only medium/low is contradictory: downgrade to approve with warning.

### Stage 7 MESSAGE (LLM call name "commit_message", skipped when user passed a message)
Input: final diff packet, branch, last 10 commit subjects (`git log --format=%s -n 10`),
convention template below. Output schema: `{"type": str, "scope": str|null, "description":
str, "body": str, "trailers": {"constraint": str|null, "rejected": str|null, "directive":
str|null, "confidence": "high"|"medium"|"low", "scope_risk": "narrow"|"moderate"|"broad",
"not_tested": str|null}, "trivial": bool}`.
Deterministic validation (validators.py): type in {feat, fix, refactor, chore, docs, test,
style, perf, build, ci}; description non-empty, <= 72 chars, no trailing period; full
message contains no em dash, no en dash, no emoji (check emoji via unicode ranges); when
trivial is false, confidence and scope_risk trailers required. Retry <= 2 with validation
errors fed back -> MESSAGE_INVALID.
Render (validators.py render_message): `<type>(<scope>): <description>` or `<type>:
<description>`, blank line, body, blank line, trailer lines `Constraint:`, `Rejected:`,
`Directive:`, `Confidence:`, `Scope-risk:`, `Not-tested:` (only non-null ones; none when
trivial).

### Stage 8 COMMIT
`git add -u`, then `git add -- <path>` for each included untracked file.
`git diff --cached --name-only` empty -> NOTHING_TO_COMMIT.
Write message to temp file inside workspace, `git commit -F <file>`. Nonzero exit ->
HOOK_FAILED with stderr captured. Success: capture hash via `git rev-parse HEAD`.

### Stage 9 PUSH (runs after a successful COMMIT; skipped by --no-push, result field
`pushed` stays false)
No `origin` remote configured -> skip with a warning, outcome stays COMMITTED. Otherwise
`git push` when the current branch already has an upstream, `git push -u origin <branch>`
when it does not. Nonzero exit -> PUSH_FAILED with stderr captured; commit_hash from
Stage 8 is still populated in the result. Success: result field `pushed` set true.

## LLM adapter (src/llm.py)

`class LlmClient(mode, model, fixtures_dir, record)`.
Live call: subprocess `claude -p <prompt> --output-format json --model <model>
--max-turns 1` (prompt via stdin with `-p` reading positional arg; pass prompt as argument
list element, not shell string; set a 300s timeout). Parse stdout JSON: fields `result`
(text) and `usage` (or `modelUsage`); store raw response too. Extract first balanced JSON
object from `result` (strip markdown fences first).
Every call: bounded retries (max as per stage), each retry appends prior error. Records
usage per attempt.
Replay fixtures: when mode is replay, read `fixtures/<key>.json` (key passed by caller, e.g.
`<scenario>_<call>`); when record flag set in live mode, write the same file.
System-style preamble inside each prompt: "Respond with a single JSON object matching this
schema. No prose, no markdown, no tool use." plus the schema itself.
Default model: claude-sonnet-5. Never claude-haiku.

## Runner (runner.py)

```
python runner.py [--repo PATH] [--message "..."] [--no-sync] [--skip-deslop]
                 [--skip-review] [--replay-fixtures DIR] [--record DIR]
                 [--model ID] [--json] [--no-push]
```
--repo defaults to cwd. --replay-fixtures: LLM replay mode plus sync skip. --json: print
full result JSON only. Human output otherwise: terse stage lines then outcome.
Exit code 0 only for COMMITTED; distinct nonzero per failure class.
Pushing runs by default after a successful commit (Stage 9). --no-push skips it; the
benchmark always passes it since a replay clone's origin is the real source repository.

## Benchmark (bench/run_bench.py)

```
python bench/run_bench.py [--ids a,b,c] [--holdout] [--out bench/results]
                          [--fixtures bench/fixtures] [--replay-llm]
```
For each scenario in bench/scenarios.json (primary by default, holdout with --holdout):
1. `git clone <repo> <tempdir>/repo` (local clone; then `git -C repo checkout -b
   replay/<id> <parent>`).
2. `git cherry-pick -n <commit>` then `git reset` to leave a dirty worktree with the
   historical change (untracked new files included).
3. Run the pipeline in-process (import, not subprocess) with: workspace = tempdir, no-sync,
   live LLM (or replay when --replay-llm and fixtures exist), record fixtures to --fixtures.
4. Measure: wall time, per-call usage, git_op_count, outcome, rendered message.
5. Write per-scenario JSON to --out plus aggregate summary.json comparing to
   scenario["historical"]: gross tokens (sum all four usage fields), noncached (in + cache
   creation + out), output tokens, llm call count, tool calls (git_op_count vs historical
   tool_calls), duration. Include per-scenario and aggregate old vs new with percentages.
6. Cleanup tempdir (retry on Windows file locks; ignore failures, they are in TEMP).
Cherry-pick conflict on replay (parent mismatch) -> record scenario as REPLAY_INFEASIBLE,
skip, do not fake.

## Judge (bench/judge.py)

For each scenario result with a rendered message: one LLM call (claude-sonnet-5) comparing
historical vs compiled message blind (random A/B order, seed from scenario id hash so it is
reproducible without RNG state). Input: `git show --stat --format=` diffstat (max 80 lines)
plus both messages labeled A and B. Output schema `{"winner": "A"|"B"|"tie", "reason": str}`.
Map back to old/new, write bench/results/judge.json with per-scenario verdicts and totals.
Judge usage is reported in judge.json only, never merged into benchmark economics.

## Tests (tests/, unittest, no mocks of git)

Real temp git repos (tempfile.mkdtemp, `git init`, config user.name/email locally). Cover:
- preflight: non-repo dir -> NOT_A_REPO; detached HEAD -> DETACHED_HEAD; merge in progress
  (create conflict via two branches) -> OPERATION_IN_PROGRESS.
- scope: modified tracked + untracked file detected; junk untracked excluded; clean repo ->
  NOTHING_TO_COMMIT.
- diff packet: truncation at 400 lines per file, 60000 char cap, untracked content included.
- validators: em dash rejected, en dash rejected, emoji rejected, bad type rejected, long
  description rejected, valid message renders exactly per convention, trivial skips
  trailers.
- slop gate: syntactically invalid patch rejected by git apply --check path; valid patch
  applied and re-staged (verify file content on disk changed).
- commit stage: real commit created, hash resolvable, message file cleanup, staged-empty ->
  NOTHING_TO_COMMIT.
- sync: local bare repo as origin, feature branch behind develop merges cleanly; diverged
  local develop (amend a commit) -> SYNC_DIVERGED; conflicting change -> MERGE_CONFLICT and
  merge aborted (verify no MERGE_HEAD afterward).
- llm replay adapter: fixture file round-trip drives pipeline MESSAGE stage end to end to a
  real commit in a temp repo (this is the only permitted fixture-driven test; the git side
  stays real).
- workspace confinement: pipeline refuses to run when workspace assertion fails.

## README.md

Cover: what it does, the 3 retained LLM calls (name, purpose, model, typed schema, bounded
retries), required inputs, commands (run, replay, no-push, tests, benchmark, judge), typed
failure states table, side-effect boundary (commits only to --repo or replay tempdir,
pushes by default with --no-push as the opt-out, benchmark never pushes, never bypasses
hooks), what is verified vs not, and the installation status of the activation layer that
replaces ~/.claude/commands/commit.md with a thin instruction that invokes runner.py and
relays its typed result.

## Acceptance

- `python -m unittest discover -s tests` green.
- `python runner.py --help` works.
- `python bench/run_bench.py --ids <one> --replay-llm` runs with fixtures (if none exist,
  document that live run records them).
- No dashes/emoji/else violations.
