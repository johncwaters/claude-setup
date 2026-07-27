---
description: Personal workflow. Compiled runner does slop cleanup, code review, conventional message, commit, push, then merges into develop by default.
---

# Commit (compiled)

This workflow is compiled. The runner at `$HOME\.claude\compiled-commit\runner.py` owns the
entire procedure: preflight, develop sync, slop cleanup, code review, message generation,
staging, and the commit itself, with typed outcomes. Do not reimplement any of those steps,
do not run your own review, and do not stage or commit yourself. Findings are yours to fix:
apply them and re-run the runner as described under Fix findings below.

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
  per above, then report; handle the merge extra below if requested.
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

## Merge into develop (default)

Pushing the current branch is the runner's job and happens by default. After COMMITTED,
merging into the integration branch is also the default: resolve it (develop, falling back
to main/master), and if the current branch already is the integration branch there is
nothing extra to do, the runner already pushed it. Otherwise:

- `git fetch origin <integration>`, `git checkout <integration>`,
  `git pull --ff-only origin <integration>`, `git merge --no-edit <feature-branch>`,
  `git push origin <integration>`, `git checkout <feature-branch>`.
  On any conflict or non-fast-forward pull: abort the merge, return to the feature branch,
  stop and report. Never force-push, never resolve conflicts silently.
- Skip the merge only when the user asked for commit-only (words like "commit only",
  "don't merge") or the branch is part of a PR flow that reviews before merge.
