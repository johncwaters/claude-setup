---
description: Work workflow. Compiled runner does slop cleanup, code review, conventional message, commit, push of the feature branch. Never merges; PRs target develop via /org-pull-request, master moves only via /org-release.
---

# Commit (compiled)

This workflow is compiled. The runner at `$HOME/.claude/compiled-commit/runner.py` owns the
entire procedure: preflight, develop sync, slop cleanup, code review, message generation,
staging, and the commit itself, with typed outcomes. Do not reimplement any of those steps,
do not run your own review, and do not stage or commit yourself. Findings are yours to fix:
apply them and re-run the runner as described under Fix findings below.

## Branch guard (work)

Before invoking the runner, check the current branch (`git branch --show-current`). If it is `develop`, `master`, or `main`: do not run the runner. Create a feature branch first (named for the work item or change), switch to it, then proceed. Work changes land through pull requests, never as direct commits to integration branches.

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
- `PUSH_FAILED`: the commit exists but the push did not land after the runner's retries.
  Fixing it is your job; do not stop here. Read the push error in `warnings`: rejected as
  non-fast-forward or "fetch first" means the remote branch moved, so fetch, merge
  `origin/<branch>` into the branch (resolve conflicts per the `MERGE_CONFLICT` rules),
  then re-run the runner. Transient network or remote errors: re-run the runner once.
  Stop and report only for authentication, permission, or branch protection failures, or
  when the same failure survives two recovery passes.
- `MERGE_CONFLICT`: the sync merge conflicted; the runner aborted it and left the tree
  clean, with the conflicting files listed in `warnings`. Redo that merge yourself (merge
  the branch named in the warning into the current branch), resolve each conflicted file
  on its merits (read both sides, keep both intents, never blanket `--ours`/`--theirs`),
  complete the merge commit, then re-run the runner with the same flags. Stop and report
  if the same merge conflicts again after two attempts or a conflict involves changes you
  cannot attribute. This is the only sanctioned manual merge; the PR-flow rules below are
  unaffected.
- `SYNC_DIVERGED`: the local integration branch has diverged from origin. Check out the
  integration branch, merge `origin/<branch>` into it (resolve conflicts per the
  `MERGE_CONFLICT` rules), push it, return to your feature branch, then re-run the runner
  with the same flags. Stop only if the same divergence survives two recovery passes.
- `NOTHING_TO_COMMIT`, `NOT_A_REPO`, `DETACHED_HEAD`, `OPERATION_IN_PROGRESS`,
  `HOOK_FAILED`, `REVIEW_DEAD`,
  `MESSAGE_INVALID`: stop and relay. The user decides the next step. Never retry by
  performing the workflow manually.
- Runner missing or crashes (non-JSON output): report the error verbatim. On the machine
  where this workflow was compiled, the original prose workflow is archived locally at
  `~/.claude/commands/commit.md.pre-compiled.bak` (not versioned in this repo, so it may not
  exist elsewhere). Do not execute the archived prose yourself.

## After COMMITTED: pull request, not merge

Never merge the feature branch into develop, master, or main yourself; that is what the PR flow is for. After a COMMITTED outcome (the runner has already pushed the branch), offer to open a pull request with the /org-pull-request skill (an example org-internal plugin command, see the org_workflow section of the work CLAUDE.md), which applies the org's PR standards: correct target branch, linked work items, and compliant title and description formatting. If the user declines, stop after reporting the commit.

The promotion chain is fixed: feature branch -> develop (via /org-pull-request) -> master/main (via /org-release), never skipping develop. A PR from a feature branch always targets develop, never master or main, even when asked to fast-track; master moves only through the release flow from develop. If asked to bypass this (direct merge, PR straight to master), decline and point at this chain.
