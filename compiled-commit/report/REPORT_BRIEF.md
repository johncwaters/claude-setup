# Report brief: compiled-commit

Build ONE self-contained HTML file at C:\Users\johnw\.claude\compiled-commit\report\report.html.
All numbers below are final and authoritative. Data files for per-scenario tables:
- ..\bench\scenarios.json (historical metrics + token accounting method)
- ..\bench\results\*.json (per-scenario new-side results, summary.json aggregate)
- ..\bench\results\judge.json (blind quality verdicts)
- C:\Users\johnw\AppData\Local\Temp\claude\C--Users-johnw-Projects\79e9be10-c432-48ac-8cf8-3848a42015e3\scratchpad\report_data.json (evidence coverage, candidate table, responsibility crosswalk)

Do not include any raw session content, prompts, private file contents, or commit diffs in the
report. Commit subjects (first lines) and finding summaries already present in the result files
are allowed.

## Verdict block (first screen)

- Workflow compiled: /commit (Claude Code slash command: sync, deslop, review, commit)
- Observed frequency: 72 runs in 5 days (2026-07-19 to 2026-07-24), 39 reached a commit
- Benchmark: 13 point-in-time replay scenarios (10 primary + 3 holdout), Method A
- Gross tokens: 78,169,107 old vs 2,324,443 new (-97.0%)
- Non-cached tokens: 4,485,306 old vs 1,104,553 new (-75.4%)
- Median latency: 473s old vs 89s new (-81%; totals 6,113s vs 1,122s, -81.7%)
- LLM invocations: median 53 old vs 3 new (totals 732 vs 43, -94.1%)
- Model-controlled tool calls: median 23 old vs 17 deterministic git ops new (totals 345 vs 223)
- Quality (blind judge, 11 scenarios): historical 8, compiled 3, tie 0. Compiled messages are
  accurate and convention-compliant; historical messages win on why-context the diff alone
  cannot supply.
- Replay functional parity: PASS with disclosure. 11/13 COMMITTED; 2 ended REVIEW_BLOCKED,
  a contract-conformant terminal state (both blocks cite concrete findings; the historical
  runs shipped those changes).
- Policy parity: PASS. No push path exists, no --no-verify, hooks honored, all writes confined
  to temp clones.
- Evidence level: PROVEN for economics (13 fair scenarios, provider-reported usage on both
  sides). Quality comparison: DIRECTIONAL (single LLM judge, 11 scenarios, user is final
  arbiter).

## Section: what the workflow does

Inputs: a dirty git worktree. Job: sync integration branch, clean AI slop, review the diff,
block on critical/high findings, generate a conventional commit message with trailers, stage,
commit. Output: a commit plus a report. Safety boundary: never push, never bypass hooks.
Repeated because every feature/fix across card-harbor, glissa, keeplings, milepost ends with
/commit.

## Section: before/after flowcharts

Old: 158-line skill prose -> general agent replans each run -> ad-hoc git exploration ->
ai-slop-cleaner skill (multi-turn edits) -> code-review skill spawning 1-3 subagents (sonnet/
opus) -> message drafting -> self-validation -> commit. Median 53 LLM calls, 5.3M gross tokens.

New: thin CLI (python runner.py) -> deterministic preflight/sync/scope/diff-bounding ->
LLM call 1 slop_review (typed findings + optional patch, gated by git apply --check) ->
LLM call 2 code_review (typed severity findings, deterministic blocking rule) ->
LLM call 3 commit_message (typed, validated against convention, bounded retries) ->
deterministic stage+commit -> typed result JSON. 3 LLM calls typical.

Use distinct visual treatment: deterministic code (one color), LLM calls (another), human
approval (another), side effects (border/icon). Mermaid or pure CSS boxes, self-contained.

## Section: crosswalk

Use the "contract" array in report_data.json verbatim (16 rows: responsibility, evidence,
old owner, new owner, why).

## Section: what was compiled

Moved to code: activation, preflight, sync logic and stops, scope discovery, diff bounding,
patch gating, blocking rules, message validation and rendering, staging, commit execution,
result reporting, usage accounting.
Still LLM: slop judgment, review judgment, message drafting (3 named bounded calls,
claude-sonnet-5 via claude -p, JSON-schema outputs, bounded retries).
Human approval: push/merge extras (historical args like "and push", "and merge") are refused
by the runner; installation itself.
Deliberately unchanged: commit message convention, blocking severity policy, no-verify ban.
Deferred with disclosure: post-merge quality gates (lint/typecheck/tests) not implemented;
historical runs applied them inconsistently.

## Section: benchmark

Per-scenario table from results files: id, repo (basename only), outcome, old/new gross,
old/new noncached, old/new llm calls, old/new duration, judge winner. Mark holdouts
(11767a1, c468d9f, b3c88bf). Show the two REVIEW_BLOCKED rows and both duration outliers in
the historical data (episodes b7403ba 24447s and fb6a080 24686s were excluded from scenario
selection as idle-inflated; scenarios chosen have active-session durations).
Token accounting method: copy the token_accounting object from scenarios.json. State:
provider usage events on both sides; reasoning tokens not separately exposed (included in
output tokens); old side includes subagent transcripts attributed by session+time window;
new side includes claude -p wrapper overhead of roughly 42k system-prompt tokens per call
(counted against the compiled side, honestly).
Failures during development disclosed: first run had 2 argv-limit crashes (WinError 206) and
4 empty reviews (max-turns tool cutoff, hook-induced nonzero exits); fixed in iteration 2 and
rerun. Iteration 1: utf-8 decoding + review severity rubric. Two iterations total, the cap.
Earlier failed attempts' tokens were partially overwritten by reruns: benchmark-side failed
usage is partially unmetered.

## Section: ONE-TIME COMPILATION COST

- Wall clock: about 2h 10m (session start 12:41Z to report generation ~14:50Z), includes
  waiting on background benchmark runs.
- Main orchestration session: 16,788,989 gross / 513,439 non-cached tokens (143 LLM events).
- Harness-builder subagent: 15,573,397 gross / 1,964,529 non-cached (109 events).
- Total measured compilation: 32,362,386 gross / 2,477,968 non-cached. Measured minimum:
  excludes this report-generation agent's own usage (not yet complete at measurement time).
- Benchmark replay usage (separate): 2,324,443 gross / 1,104,553 non-cached across 13 final
  scenario runs; failed earlier attempts partially unmetered (overwritten).
- Judge usage (separate): 11 calls, 476,742 gross / 73,350 non-cached.
- Human decisions required: none during compilation (one status query answered).
- Files created: harness (~15 files), fixtures (13 scenarios x 3 calls), results, report.
State verbatim: "Compilation cost is not amortized, allocated, or included in compiled
per-run runtime metrics."

## Section: use it now

DEMO IT (VERIFIED): from C:\Users\johnw\.claude\compiled-commit:
  python bench\run_bench.py --ids 1eb5432 --replay-llm --fixtures bench\fixtures --out %TEMP%\cc-demo
Zero LLM calls, zero cost, replays recorded fixtures against a temp clone, terminal state
COMMITTED inside the temp clone only. Verified: 0.76s.

USE IT (VERIFIED): from C:\Users\johnw\.claude\compiled-commit:
  python runner.py --repo <your-repo> --dry-run --no-sync --skip-deslop --json
Live sonnet review + message on the real dirty worktree, no writes of any kind (dry-run skips
commit; skip-deslop prevents patch application to your live tree). Verified today against
card-harbor with real uncommitted changes: DRY_RUN_OK, message generated after one validation
retry. Full pipeline including slop patching and actual commit: run without --dry-run
--skip-deslop; that path is exercised end to end only in temp-clone replay so label the full
live path NOT LIVE-VERIFIED.

INSTALL IT (NOT EXECUTED, REQUIRES APPROVAL): replace ~/.claude/commands/commit.md with a
thin activation instruction that runs
  python C:\Users\johnw\.claude\compiled-commit\runner.py --repo <cwd> --json
and relays the typed result without re-taking control of selection, validation, or side
effects. Keep flags mapping: --no-sync, --skip-deslop, --skip-review, message passthrough.
Nothing was installed, committed, pushed, or activated.

## Section: success standard

1 Responsibility contract: PASS (quality gates row DISCLOSED as deferred)
2 Model/code boundary: PASS
3 Replay functional and policy parity: PASS (functional with 2 REVIEW_BLOCKED disclosed)
4 Live-mode responsibilities: partially VERIFIED (review+message live on real repo);
  slop-patch and live commit on a user repo UNTESTED
5 Quality tolerance: DISCLOSED (accuracy/format/safety hold; why-context regression, judge
  8-3 historical; user is final arbiter)
6 Comparable metrics: PASS
7 Replay fidelity: DISCLOSED (sync skipped in replay; no quality gates; diff-only context)
8 Separate compilation cost: PASS
9 Demo and isolated-use commands: PASS (both verified)
10 No unauthorized activation: PASS

## Section: installation decision

Recommend: use as isolated prototype now (dry-run mode is immediately useful); promote to
default /commit only after (a) a few supervised live commits, (b) a decision on the message
why-context gap. Mitigation option for the gap: pass an optional --context "one line of
intent" argument into the commit_message call; costs nothing when omitted. Maintenance:
about 1,700 lines of stdlib Python, no dependencies; main risk is claude CLI flag drift.
Unverified: live slop patching, live sync against origin, hook-failure path on real hooks.
Approval needed: replacing commit.md (explicit user action).

## Style

Polished, readable, light/dark aware, no external assets, no emoji, no em or en dashes.
Big verdict numbers first screen. Tables scroll inside their own container. Charts optional;
if included, inline SVG bar comparisons only (old vs new for gross, noncached, latency, llm
calls). Title: "compiled-commit: /commit workflow compilation report".
