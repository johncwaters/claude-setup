# Commit (compiled)

This workflow is compiled. The runner at `$HOME\Projects\compiled-commit\runner.py` owns the
entire procedure: preflight, develop sync, slop cleanup, code review, message generation,
staging, and the commit itself, with typed outcomes. Do not reimplement any of those steps,
do not run your own review, do not stage or commit yourself, and do not edit files to fix
findings unless the user asks after seeing the result.

## Invoke

Run exactly one command (PowerShell; `$HOME` resolves the machine-specific user directory):

```
python "$HOME\Projects\compiled-commit\runner.py" --repo <current working directory> --json <flags>
```

Flag mapping from the user's arguments:

- A quoted conventional message, e.g. `/commit "feat: x"`: pass as `--message "feat: x"`.
- Free-text intent that is not a conventional message (e.g. "prototype for later"): pass as
  `--context "<text>"` so the message call can explain the why. When you have session
  context about why the change was made, pass one line of it as `--context` too.

The runner has additional flags for direct use (`--help`), but this command maps only the
two above. Do not pass skip flags unless the user explicitly names one.

## Relay the result

Parse the JSON on stdout. Report to the user, briefly: `outcome`, `commit_hash` and the
message subject when COMMITTED, `findings` when the outcome is REVIEW_BLOCKED or findings are
non-empty, and any `warnings`. Do not re-judge, filter, or overrule the runner's verdict.

Typed outcomes and what to do:

- `COMMITTED`: done; the runner has already pushed (the result's `pushed` field says
  whether a push happened; it is skipped with a warning when the repo has no origin).
  Relay, then handle the merge extra below if requested.
- `PUSH_FAILED`: the commit exists but the push did not land. Relay the commit hash and the
  push error. Do not retry the push yourself unless the user asks.
- `NOTHING_TO_COMMIT`, `NOT_A_REPO`, `DETACHED_HEAD`, `OPERATION_IN_PROGRESS`,
  `SYNC_DIVERGED`, `MERGE_CONFLICT`, `HOOK_FAILED`, `REVIEW_BLOCKED`, `REVIEW_DEAD`,
  `MESSAGE_INVALID`: stop and relay. The user decides the next step. Never retry by
  performing the workflow manually.
- Runner missing or crashes (non-JSON output): report the error verbatim. On the machine
  where this workflow was compiled, the original prose workflow is archived locally at
  `~/.claude/commands/commit.md.pre-compiled.bak` (not versioned in this repo, so it may not
  exist elsewhere). Do not execute the archived prose yourself.

## Merge extra

Pushing the current branch is the runner's job and happens by default. Merging is not:
perform it only when the user explicitly asked in this invocation (words like "and merge"),
and only after COMMITTED:

- Merge: resolve the integration branch (develop, falling back to main/master). Then:
  `git fetch origin <integration>`, `git checkout <integration>`,
  `git pull --ff-only origin <integration>`, `git merge --no-edit <feature-branch>`,
  `git push origin <integration>`, `git checkout <feature-branch>`.
  On any conflict or non-fast-forward pull: abort the merge, return to the feature branch,
  stop and report. Never force-push, never resolve conflicts silently.
- If the current branch already is the integration branch, merge is meaningless: nothing
  extra to do, the runner already pushed it.
