---
description: Personal workflow. Compiled runner does slop cleanup, code review, conventional message, commit, push, then promotes through develop into main/master by default.
---

# Commit (compiled)

This workflow is compiled. The runner at `$HOME/.claude/compiled-commit/runner.py` owns the
entire procedure: preflight, develop sync, slop cleanup, code review, message generation,
staging, and the commit itself, with typed outcomes. Do not reimplement any of those steps,
do not run your own review, and do not stage or commit yourself. Findings are yours to fix:
apply them and re-run the runner as described under Fix findings below.

## Branch guard (personal)

Before invoking the runner, check the current branch (`git branch --show-current`). If it
is `main` or `master`: do not commit there. Switch to `develop` first (create it from
main/master if it does not exist); uncommitted changes carry over with the checkout. Then
proceed. Committing on `develop` or a feature branch is fine. Nothing lands on main/master
directly; main/master only ever receives merges from develop.

## Invoke

Run exactly one command. `$HOME` resolves the machine-specific user directory in both
PowerShell and bash, and the forward slashes work in both; the interpreter is `python` on
Windows and `python3` on Linux:

```
python "$HOME/.claude/compiled-commit/runner.py" --repo <current working directory> --json <flags>
```

Flag mapping from the user's arguments:

- A quoted conventional message, e.g. `/commit "feat: x"`: pass as `--message "feat: x"`.
- Free-text intent that is not a conventional message (e.g. "prototype for later"): pass as
  `--context "<text>"` so the message call can explain the why. When you have session
  context about why the change was made, pass one line of it as `--context` too.
- When you know exactly which files or directories this session changed, pass them as
  `--paths <file-or-dir> ...` so scope, review, and staging are restricted to them. This
  keeps another session's work-in-progress in the same checkout out of your commit. Omit
  it only when the user asked to commit everything or you genuinely cannot enumerate what
  changed.
- Pass `--promote` by default so the runner carries the commit through develop into
  main/master. Omit it only in the two cases listed under Promotion through develop below.

The runner has additional flags for direct use (`--help`), but this command maps only the
flags above. Do not pass skip flags unless the user explicitly names one.

## Fix findings, then report

Parse the JSON on stdout. When the outcome is `COMMITTED` or `REVIEW_BLOCKED` and
`findings` is non-empty: fix each finding in the working tree (use its `fix` field when
present, otherwise the `issue` description), then re-invoke the runner with
`--context "address review findings: <one line>"`. At most two fix passes per invocation;
if findings remain after that, stop and report them. Do not re-judge, filter, or overrule
the runner's verdict; skip a finding only when it is factually wrong about the diff, and
say so.

Report in as few words as possible: one line with outcome, short hash, and message subject,
then one short line per finding fixed. No usage stats, no restating fixed findings, no
next-step suggestions. Expand only on failure outcomes.

Typed outcomes and what to do:

- `COMMITTED`: the runner has already pushed (the result's `pushed` field says whether a
  push happened; it is skipped with a warning when the repo has no origin). When
  `--promote` was passed, the result's `promoted` field lists the integration branches the
  runner carried the commit into. Fix findings per above, then report.
- `REVIEW_BLOCKED`: no commit happened. Fix the findings per above and re-run; still
  blocked after two passes, stop and report.
- `PUSH_FAILED`: the commit exists but the push did not land. Relay the commit hash and the
  push error. Do not retry the push yourself unless the user asks.
- `PROMOTE_CONFLICT`, `PROMOTE_FAILED`: the commit exists and the feature branch is pushed
  (`commit_hash` and `pushed` are populated); promotion did not complete, and the
  `promoted` field says which branches did update. Relay the warnings and stop. Never
  resolve conflicts or finish the promotion by hand.
- `NOTHING_TO_COMMIT` with `--promote`: no commit was made, but the runner still ran
  promotion; report what the `promoted` field says instead of treating it as a failure.
- `NOTHING_TO_COMMIT` (without `--promote`), `NOT_A_REPO`, `DETACHED_HEAD`, `OPERATION_IN_PROGRESS`,
  `SYNC_DIVERGED`, `MERGE_CONFLICT`, `HOOK_FAILED`, `REVIEW_DEAD`,
  `MESSAGE_INVALID`: stop and relay. The user decides the next step. Never retry by
  performing the workflow manually.
- Runner missing or crashes (non-JSON output): report the error verbatim. On the machine
  where this workflow was compiled, the original prose workflow is archived locally at
  `~/.claude/commands/commit.md.pre-compiled.bak` (not versioned in this repo, so it may not
  exist elsewhere). Do not execute the archived prose yourself.

## Promotion through develop (default)

Promotion is the runner's job, not yours: with `--promote` it merges the feature branch
into develop, then develop into main/master, pushing each hop, and it creates develop from
main/master when the repo has none. The invariant it enforces: every change goes through
develop, and main/master only ever receives merges from develop, so the two never drift.
Never merge branches yourself, and never merge anything other than develop into
main/master, even when asked to "just merge it quickly"; re-run the runner instead.

Omit `--promote` in exactly two cases:

- The user asked for commit-only (words like "commit only", "don't merge").
- The branch is part of a PR flow that reviews before merge. The PR must target develop,
  never main/master; after the PR merges, promote develop into main/master by running the
  runner on develop with `--promote`. A clean tree is fine: with `--promote` the runner
  still performs promotion on a NOTHING_TO_COMMIT outcome, so this doubles as the way to
  repair develop/main drift.
