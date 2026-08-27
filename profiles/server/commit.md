---
description: Personal workflow. Reviews and fixes in a loop via /code-review, then the compiled runner does slop cleanup, conventional message, commit, push, then promotes through develop into main/master by default.
---

# Commit (compiled)

This workflow is compiled. The runner at `$HOME/.claude/compiled-commit/runner.py` owns the
entire procedure: preflight, develop sync, slop cleanup, code review, message generation,
staging, and the commit itself, with typed outcomes. Do not reimplement any of those steps
and do not stage or commit yourself. Review is the exception: it runs before the runner,
through `/code-review`, per the review loop below. Findings are yours to fix:
apply them and re-run the runner as described under Fix findings below.

## Branch guard (personal)

Before invoking the runner, check the current branch (`git branch --show-current`). If it
is `main` or `master`: do not commit there. Switch to `develop` first (create it from
main/master if it does not exist); uncommitted changes carry over with the checkout. Then
proceed. Committing on `develop` or a feature branch is fine. Nothing lands on main/master
directly; main/master only ever receives merges from develop.

## Review loop (before the runner)

The runner's own content stages are retired on this path, so nothing rewrites the code between the last review and the commit.

**Step 0, once.** Run the `ai-slop-cleaner` skill over the changed files. It goes first, not last, because the runner's slop stage rewrites code, and letting that run after the review would commit a tree no reviewer ever saw.

**Then loop.**

1. Invoke `/code-review` with target `working`, the repo path, and one or two sentences of what changed and why.

   Always `working`, never `staged`, even when only part of the tree is staged. The runner's staging step runs `add_update` plus the scoped untracked files, so it commits every tracked modification in scope, not only what happened to be staged when the review was pinned. Reviewing `staged` would approve a subset of what then gets committed. Restrict scope with `--paths` on the runner instead, and pass the same restriction to `/code-review`.
2. Read its first two lines, `VERDICT` and `ACTIONABLE`, and act:
   - `VERDICT: FAILED`: the review did not complete. Re-run it once. Failing twice, stop and report; never treat a failed review as a passed one.
   - Any `AMBIGUOUS` finding, at any verdict: stop the loop and put it to the user with both readings stated. Do not guess, and do not fall through to the runner. Their answer is not the end of it: carry the answer into the next `/code-review` call as a stated decision so the finding is re-dispositioned, `ACTIONABLE` when the answer says fix it, `NIT` when the answer says leave it. An `AMBIGUOUS` finding that stays `AMBIGUOUS` after an answer means the answer did not reach the next round, and the loop would ask forever.
   - `ACTIONABLE` greater than zero **and** rounds remaining: hand exactly those findings to the `finding-fixer` agent in a single spawn, then go back to step 1. `NIT` findings are never sent to it.
   - `ACTIONABLE` greater than zero **and** this was the last permitted round: stop without dispatching the writer. Fixing after the final review leaves an unverified edit in the tree, which is worse than leaving the finding.
   - `ACTIONABLE: 0` **and** a verdict of `APPROVE` or `APPROVE WITH NITS`: leave the loop and invoke the runner.
3. At most **three** rounds. Still not passing after the third: stop, report the surviving findings and the round count, and do not invoke the runner. Hitting the cap is its own outcome and is never reported as approval.

The loop exits on `ACTIONABLE: 0`, not on the verdict. A MEDIUM or LOW finding dispositioned `ACTIONABLE` is a verified defect with a bounded fix, and it maps to a passing verdict; exiting on the verdict alone would commit it unfixed.

Carry two separate lists into the next `/code-review` call, never merged: the findings settled as `NIT` or `AMBIGUOUS`, and the `finding-fixer` receipt for the findings it claims to have fixed. The first suppresses re-reporting; the second becomes a regression check. A `FIXED` receipt is a claim, and the next round is what verifies it.

A round where `finding-fixer` declines every finding it was handed is a stop, not a retry: nothing changed, so the next review returns the same block.

`/code-review` is the only review on this path. Do not spawn a reviewer agent yourself, and do not invoke `/qa-swarm` directly; `/code-review` owns which lanes run.

**A merge you resolve by hand invalidates the review of the branch it lands on.** A merge combines reviewed code with code this loop never saw, and a clean merge is not a safe merge: integration can change a helper in one file while the reviewed change adds its caller in another, conflict-free and broken. That is why `--no-sync` is passed: it moves every merge out of the runner's single-shot invocation and into a place where a review can still happen.

Where the recovery sections below say **re-review**, they mean steps 1 and 2 of this loop only: review, fix if needed, repeat to the cap. Stop at a passing verdict and continue the recovery procedure; do not invoke the runner at that point, because the recovery section says when to invoke it.

One carve-out, and only one: merging `origin/<branch>` into the same local branch needs no re-review. It reconciles a local ref with the remote copy of the same branch, and whatever is on the remote was reviewed by whoever landed it. Every other merge, including a feature branch into an integration branch, is a combination nothing has looked at.

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
  main/master. For PR-flow branches, pass `--promote --promote-to develop` so promotion
  stops at develop. Omit `--promote` only in the case listed under Promotion through
  develop below.

- Pass `--skip-review --skip-deslop --no-sync` on every invocation, and name the review that covered the tree in `--context`. These three are sanctioned without the user asking, because each one is a runner stage that would change the committed content after the last review saw it. `--skip-review` and `--skip-deslop` are covered ahead of the runner by the review loop. `--no-sync` has no replacement: an integration merge lands code nothing reviewed, and the runner performs it and commits in the same invocation, so there is no point at which the merged tree could be reviewed. Skipping it means a stale branch surfaces later as a push or promote failure instead, and those have recovery paths below that re-review before retrying.

The runner has additional flags for direct use (`--help`), but this command maps only the
flags above. Do not pass any other skip flag unless the user explicitly names one.

## Fix findings, then report

Parse the JSON on stdout. With `--skip-review --skip-deslop` the runner produces no findings
of its own; both stages ran ahead of it. A non-empty `findings` array therefore means a flag
was dropped, not that a new defect appeared: re-invoke with both flags rather than acting on
the findings, which duplicate what the review loop already handled. Do not re-judge, filter, or overrule
the runner's verdict; skip a finding only when it is factually wrong about the diff, and
say so.

Report in as few words as possible: one line with outcome, short hash, and message subject,
then one short line per finding fixed. No usage stats, no restating fixed findings, no
next-step suggestions. Expand only on failure outcomes.

Typed outcomes and what to do:

- `COMMITTED`: the runner has already pushed (the result's `pushed` field says whether a
  push happened; it is skipped with a warning when the repo has no origin). When
  `--promote` was passed, the result's `promoted` field lists the integration branches the
  runner carried the commit into. Then report.
- `REVIEW_BLOCKED` / `REVIEW_DEAD`: cannot occur with `--skip-review`, so seeing either means
  the flag was dropped and no commit happened. Re-invoke with the flag. Do not act on the
  findings; they duplicate what the review loop already handled.
- `PUSH_FAILED`: the commit exists but the push did not land after the runner's retries.
  Recover per Push and merge recovery below; do not stop here.
- `PROMOTE_CONFLICT`: the commit exists (`commit_hash` is populated) but with `--promote`
  the feature-branch push is deferred into promotion's single batched push, so the feature
  branch may not be pushed yet (`pushed` says); the runner aborted the conflicted promotion
  merge and left the tree clean. Resolve it per Conflict resolution below, then re-run the
  runner with `--promote` to finish the remaining hops and the batched push.
- `PROMOTE_FAILED`: the commit exists and `pushed` says whether the feature branch made it
  to origin (the batched push may have failed before or with the promoted refs); promotion stopped
  for a non-conflict reason and the `promoted` field says which branches did update. Fix
  the cause named in `warnings` per Push and merge recovery below, then re-run the runner
  with `--promote` to finish the remaining hops.
- `NOTHING_TO_COMMIT` with `--promote`: no commit was made, but the runner still ran
  promotion; report what the `promoted` field says instead of treating it as a failure.
- `MERGE_CONFLICT`: the sync merge conflicted; the runner aborted it and left the tree
  clean, with the conflicting files listed in `warnings`. Resolve it per Conflict
  resolution below, then re-run the runner with the same flags.
- `SYNC_DIVERGED`: the local integration branch has diverged from origin. Recover per
  Push and merge recovery below, then re-run the runner with the same flags.
- `NOTHING_TO_COMMIT` (without `--promote`), `NOT_A_REPO`, `DETACHED_HEAD`, `OPERATION_IN_PROGRESS`,
  `HOOK_FAILED`, `REVIEW_DEAD`,
  `MESSAGE_INVALID`: stop and relay. The user decides the next step. Never retry by
  performing the workflow manually.
- Runner missing or crashes (non-JSON output): report the error verbatim. On the machine
  where this workflow was compiled, the original prose workflow is archived locally at
  `~/.claude/commands/commit.md.pre-compiled.bak` (not versioned in this repo, so it may not
  exist elsewhere). Do not execute the archived prose yourself.

## Conflict resolution

When the runner reports `MERGE_CONFLICT` or `PROMOTE_CONFLICT`, resolving the conflict and
continuing is your job; do not dead-end on it. The runner has already aborted the merge, so
the tree is clean and the conflicting files are named in `warnings`.

1. Redo the merge the runner attempted:
   - `MERGE_CONFLICT` (sync stage): merge the branch named in the warning (the integration
     branch, or `origin/<branch>` when the warning says it merged origin directly) into the
     current branch.
   - `PROMOTE_CONFLICT`: note the current branch, check out the destination branch from the
     warning ("promoting <src> into <dst>"), and merge the source into it.
2. Resolve each conflicted file on its merits: read both sides, keep both intents where they
   are independent, and pick the semantically correct result where they collide. Never
   resolve by blanket `--ours`/`--theirs`, and never drop changes you cannot account for.
3. Stage the resolutions and complete the merge commit (default merge message is fine).
4. Re-review the merge result, on whichever branch you resolved it, before going any further.
   A hand resolution is code nothing has reviewed, and that is as true of an integration
   commit on develop as of one on the feature branch: promotion would otherwise carry an
   unreviewed merge straight into mainline. Target the merge commit itself (`BASE_SHA` is its
   first parent, `HEAD_SHA` is the merge), since the rest of the branch was already reviewed.
5. Return to the branch you started on (`PROMOTE_CONFLICT` case), then re-run the runner with
   the same flags (`--promote` included) so it finishes the remaining merges and pushes. A
   `NOTHING_TO_COMMIT` outcome here is expected and fine.

Stop and report instead when: the same hop conflicts again after two resolution attempts,
a conflict involves changes you cannot attribute or understand (another session's
work-in-progress, generated files with unclear provenance), or resolving would require
discarding one side wholesale. Merging by hand remains forbidden in every other situation;
this section is the only sanctioned manual merge, and only to unblock the runner.

## Push and merge recovery

`PUSH_FAILED`, `SYNC_DIVERGED`, and `PROMOTE_FAILED` are yours to resolve, the same way
conflicts are; do not dead-end on them. The runner's `warnings` name the root cause. Fix
it, then re-run the runner (keeping `--promote` when it was passed) so it finishes every
remaining merge and push; a `NOTHING_TO_COMMIT` outcome on the re-run is expected and
fine. The git commands in this section are sanctioned only to unblock the runner.

- Push rejected (non-fast-forward, "stale info", "fetch first"): the remote branch moved.
  Fetch, merge `origin/<branch>` into the local branch (conflicts per Conflict resolution),
  push that branch, then re-run the runner. This is the carve-out above: same branch, remote
  copy, already reviewed upstream. A conflict you resolve by hand is not covered by the
  carve-out, so re-review the merge commit before pushing.
- `SYNC_DIVERGED`: check out the integration branch, merge `origin/<branch>` into it
  (conflicts per Conflict resolution), push it, return to the branch you started on, then
  re-run the runner. Same branch, remote copy, so the carve-out applies and no re-review is
  needed for a clean merge. Resolve a conflict by hand and it stops being the carve-out:
  re-review that merge commit before pushing.
- Destination branch checked out in a dirty worktree: if the uncommitted changes are this
  session's, land them by running this whole workflow in that worktree, review loop included.
  Never commit them by hand to clear the way; that is exactly the unreviewed commit this
  procedure exists to prevent. Changes you cannot attribute are a stop case.
- Transient network or remote errors: re-run the runner once before treating the failure
  as real.

Stop and report only when: the failure is authentication, permissions, or branch
protection policy (nothing you can fix from the CLI); the same failure survives two
recovery passes; or fixing would require touching changes you cannot attribute. Everything
else gets resolved until the change is merged and pushed.

## Promotion through develop (default)

Promotion is the runner's job, not yours: with `--promote` it merges the feature branch
into develop, then develop into main/master by default, pushing each hop, and it creates
develop from main/master when the repo has none. The invariant it enforces: every change
goes through develop, and main/master only ever receives merges from develop. Never merge
branches yourself (sole exception: redoing a conflicted merge per Conflict resolution
above), and never merge anything other than develop into main/master, even when asked to
"just merge it quickly"; re-run the runner instead.

Use promotion flags this way:

- The user asked for commit-only (words like "commit only", "don't merge"): omit
  `--promote`.
- The branch is part of a PR flow that reviews before merge. Pass `--promote
  --promote-to develop` so promotion stops at develop and main/master stays untouched.
  Main/master then moves only from develop: either the PR itself is develop into
  main/master, or after a PR into develop merges, run the runner on develop with plain
  `--promote`. A PR from any other branch must never target main/master. A clean tree is
  fine: with `--promote` the runner still performs promotion on a NOTHING_TO_COMMIT
  outcome, so this doubles as the way to repair develop/main drift when the target is
  mainline.
