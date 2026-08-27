---
description: Work workflow. Reviews and fixes in a loop via /code-review, then the compiled runner does slop cleanup, conventional message, commit, push of the feature branch. Never merges; PRs target develop via /org-pull-request, master moves only via /org-release.
---

# Commit (compiled)

This workflow is compiled. The runner at `$HOME/.claude/compiled-commit/runner.py` owns the
entire procedure: preflight, develop sync, slop cleanup, code review, message generation,
staging, and the commit itself, with typed outcomes. Do not reimplement any of those steps
and do not stage or commit yourself. Review is the exception: it runs before the runner,
through `/code-review`, per the review loop below. Findings are yours to fix:
apply them and re-run the runner as described under Fix findings below.

## Branch guard (work)

Before invoking the runner, check the current branch (`git branch --show-current`). If it is `develop`, `master`, or `main`: do not run the runner. Create a feature branch first (named for the work item or change), switch to it, then proceed. Work changes land through pull requests, never as direct commits to integration branches.

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

One carve-out, and only one: merging `origin/<branch>` into the same local branch needs no re-review. It reconciles a local ref with the remote copy of the same branch, and whatever is on the remote was reviewed by whoever landed it. Every other merge is a combination nothing has looked at.

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

- Pass `--skip-review --skip-deslop --no-sync` on every invocation, and name the review that covered the tree in `--context`. These three are sanctioned without the user asking, because each one is a runner stage that would change the committed content after the last review saw it. `--skip-review` and `--skip-deslop` are covered ahead of the runner by the review loop. `--no-sync` has no replacement: an integration merge lands code nothing reviewed, and the runner performs it and commits in the same invocation, so there is no point at which the merged tree could be reviewed. Skipping it means a stale branch surfaces later as a push or promote failure instead, and those have recovery paths below that re-review before retrying.

The runner has additional flags for direct use (`--help`), but this command maps only the
flags above. Do not pass any other skip flag unless the user explicitly names one.

## Report the outcome

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
  push happened; it is skipped with a warning when the repo has no origin). Report, then
  offer the PR handoff below.
- `REVIEW_BLOCKED` / `REVIEW_DEAD`: cannot occur with `--skip-review`, so seeing either means
  the flag was dropped and no commit happened. Re-invoke with the flag. Do not act on the
  findings; they duplicate what the review loop already handled.
- `PUSH_FAILED`: the commit exists but the push did not land after the runner's retries.
  Fixing it is your job; do not stop here. Read the push error in `warnings`: rejected as
  non-fast-forward or "fetch first" means the remote branch moved, so fetch, merge
  `origin/<branch>` into the branch (resolve conflicts per the `MERGE_CONFLICT` rules),
  then re-run the runner. This is the carve-out above: same branch, remote copy, already
  reviewed upstream. A conflict you resolve by hand is not covered, so re-review that merge
  commit first. Transient network or remote errors: re-run the runner once.
  Stop and report only for authentication, permission, or branch protection failures, or
  when the same failure survives two recovery passes.
- `MERGE_CONFLICT`: the sync merge conflicted; the runner aborted it and left the tree
  clean, with the conflicting files listed in `warnings`. Redo that merge yourself (merge
  the branch named in the warning into the current branch), resolve each conflicted file
  on its merits (read both sides, keep both intents, never blanket `--ours`/`--theirs`),
  complete the merge commit, then re-run the runner with the same flags. Stop and report
  if the same merge conflicts again after two attempts or a conflict involves changes you
  cannot attribute. Re-review the merge commit before re-running the runner. This is the only
  sanctioned manual merge; the PR-flow rules below are unaffected.
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

Reviewing a work pull request belongs to `/org-pr-review` whenever the org plugin provides it, per the org_workflow section of the work CLAUDE.md. That command applies the org's review requirements, and `/pr-review` does not know what those are. Do not offer `/pr-review` as an alternative to it.

`/pr-review` is available here only as a supplemental audit trail on a PR this flow just opened, and only when asked for by name: it posts the local review record (inline comments plus one sticky summary) and asks before posting anything. The review loop above already fixed everything actionable before the branch was pushed, so the record is rarely worth the noise.

The promotion chain is fixed: feature branch -> develop (via /org-pull-request) -> master/main (via /org-release), never skipping develop. A PR from a feature branch always targets develop, never master or main, even when asked to fast-track; master moves only through the release flow from develop. If asked to bypass this (direct merge, PR straight to master), decline and point at this chain.
