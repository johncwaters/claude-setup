# Commit (compiled)

This workflow is compiled. The runner at `C:\Users\johnw\Projects\compiled-commit\runner.py`
owns the entire procedure: preflight, develop sync, slop cleanup, code review, message
generation, staging, and the commit itself, with typed outcomes. Do not reimplement any of
those steps, do not run your own review, do not stage or commit yourself, and do not edit
files to fix findings unless the user asks after seeing the result.

## Invoke

Run exactly one command (PowerShell):

```
python C:\Users\johnw\Projects\compiled-commit\runner.py --repo <current working directory> --json <flags>
```

Flag mapping from the user's arguments:

- A quoted conventional message, e.g. `/commit "feat: x"`: pass as `--message "feat: x"`.
- `--no-sync`: pass through.
- `--skip-deslop`: pass through.
- `--skip-review`: pass through.
- Free-text intent that is not a conventional message (e.g. "prototype for later"): pass as
  `--context "<text>"` so the message call can explain the why. When you have session
  context about why the change was made, pass one line of it as `--context` too.

## Relay the result

Parse the JSON on stdout. Report to the user, briefly: `outcome`, `commit_hash` and the
message subject when COMMITTED, `findings` when the outcome is REVIEW_BLOCKED or findings are
non-empty, and any `warnings`. Do not re-judge, filter, or overrule the runner's verdict.

Typed outcomes and what to do:

- `COMMITTED` or `DRY_RUN_OK`: done, relay.
- `NOTHING_TO_COMMIT`, `NOT_A_REPO`, `DETACHED_HEAD`, `OPERATION_IN_PROGRESS`,
  `SYNC_DIVERGED`, `MERGE_CONFLICT`, `HOOK_FAILED`, `REVIEW_BLOCKED`, `REVIEW_DEAD`,
  `MESSAGE_INVALID`: stop and relay. The user decides the next step. Never retry by
  performing the workflow manually.
- Runner missing or crashes (non-JSON output): report the error verbatim. The original prose
  workflow is archived at `~/.claude/commands/commit.md.pre-compiled.bak`; suggest the user
  restore it if they want the old behavior. Do not execute the archived prose yourself.

## Push and merge extras

The runner never pushes. If and only if the user explicitly asked (words like "and push",
`--push`) and the outcome is COMMITTED, run `git push` on the current branch afterward and
report the result. Merge requests ("and merge") remain manual follow-ups: surface them back
to the user after the commit, do not perform them as part of this command.
