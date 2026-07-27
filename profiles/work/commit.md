---
description: Work workflow. Compiled runner does slop cleanup, code review, conventional message, commit, push of the feature branch. Never merges; hands off to /elm-pull-request.
---

# Commit (compiled)

This workflow is compiled. The runner at `$HOME\.claude\compiled-commit\runner.py` owns the
entire procedure: preflight, develop sync, slop cleanup, code review, message generation,
staging, and the commit itself, with typed outcomes. Do not reimplement any of those steps,
do not run your own review, and do not stage or commit yourself. Findings are yours to fix:
apply them and re-run the runner as described under Fix findings below.

## Branch guard (work)

Before invoking the runner, check the current branch (`git branch --show-current`). If it is `develop`, `master`, or `main`: do not run the runner. Create a feature branch first (named for the work item or change), switch to it, then proceed. Work changes land through pull requests, never as direct commits to integration branches.

## Invoke

Run exactly one command (PowerShell; `$HOME` resolves the machine-specific user directory):

```
python "$HOME\.claude\compiled-commit\runner.py" --repo <current working directory> --json <flags>
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
  push happened; it is skipped with a warning when the repo has no origin). Fix findings
  per above, then report; then offer the PR handoff below.
- `REVIEW_BLOCKED`: no commit happened. Fix the findings per above and re-run; still
  blocked after two passes, stop and report.
- `PUSH_FAILED`: the commit exists but the push did not land. Relay the commit hash and the
  push error. Do not retry the push yourself unless the user asks.
- `NOTHING_TO_COMMIT`, `NOT_A_REPO`, `DETACHED_HEAD`, `OPERATION_IN_PROGRESS`,
  `SYNC_DIVERGED`, `MERGE_CONFLICT`, `HOOK_FAILED`, `REVIEW_DEAD`,
  `MESSAGE_INVALID`: stop and relay. The user decides the next step. Never retry by
  performing the workflow manually.
- Runner missing or crashes (non-JSON output): report the error verbatim. On the machine
  where this workflow was compiled, the original prose workflow is archived locally at
  `~/.claude/commands/commit.md.pre-compiled.bak` (not versioned in this repo, so it may not
  exist elsewhere). Do not execute the archived prose yourself.

## After COMMITTED: pull request, not merge

Never merge the feature branch into develop, master, or main yourself; that is what the PR flow is for. After a COMMITTED outcome (the runner has already pushed the branch), offer to open a pull request with the /elm-pull-request skill, which applies ELM PR standards: correct target branch, linked work items, and compliant title and description formatting. If the user declines, stop after reporting the commit.
