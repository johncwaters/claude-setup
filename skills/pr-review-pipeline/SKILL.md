---
name: pr-review-pipeline
description: Take an open PR from review to merged. Pulls the PR into an isolated worktree (so other agents on other branches keep working), runs OMC code-review, plans upstream fixes (no bandaids), implements via ralph with architect verification + ai-slop-cleaner, commits, updates the PR description if scope changed, merges, and cleans up the worktree. Use when the user says "review and ship PR N", "harden PR N", "fix PR N upstream and merge", "ship PR N", "deslop PR N", "pr-review-pipeline N", "review pipeline for PR N", or any variant that implies the full review-to-merge loop. Not for read-only review (use the code-reviewer agent directly), and not for landing your own un-pushed work (use /commit).
---

# PR Review Pipeline: review, plan, implement, ship

Drives an open PR to merged on master with quality gates at every step, delegating each step to a purpose-built OMC skill or agent.

## When to use

The user names an open PR (number, branch, or just "the current PR") and expects you to drive it to merged, applying upstream fixes for review findings rather than patching symptoms. Implies authority to: create worktrees, run ralph, commit, push, update PR description, merge.

## When NOT to use

- **Read-only review.** User just wants findings, not implementation. Spawn `oh-my-claudecode:code-reviewer` directly.
- **Your own unpushed work.** User wants a commit on the current branch, no PR yet. Use `/commit`.
- **Multi-PR sweep.** User wants to triage all open PRs. Use `gh pr list` + per-PR judgment, not this skill (which is single-PR).
- **Hot fix on master.** No PR involved. Direct edit + `/commit`.

## Operating principles

- **Worktree isolation by default.** Another agent may be working in the main repo on a different branch; touching their checkout is destructive. Pull the target PR into a sibling worktree (`<repo>-pr<N>/`).
- **Upstream fixes, not bandaids.** Code review findings get traced to root cause: spec drift to align with spec; type silent default to make it required; duplicated logic to consolidate. Symptom patches are rejected at the planning stage, not after they ship.
- **One file or one feature per PR.** If the planning pass reveals scope sprawl, split into follow-up PRs and document in the plan's "out of scope" section. Do not bundle.
- **Reject phantom symmetry.** If a "stability" claim only matters within one user state and never across them, accept the categorical difference rather than engineering coverage for a comparison the user never makes.
- **Treat existing workaround comments as load-bearing.** When a comment in the code explains a non-obvious choice ("import.meta.url breaks under the Netlify adapter", "process.cwd() because X"), the constraint is real until proven otherwise. The "fix upstream" principle does not authorize dismissing existing context. Verify the workaround is unnecessary with a full build (`npm run build` or the project's smoke equivalent) **before** refactoring it away.

## Steps

### Step 1: Pull the PR into an isolated worktree

```bash
gh pr view <N> --json headRefName,baseRefName,title
git fetch origin <headRefName>
git worktree add ../<repo>-pr<N> <headRefName>
```

Then in the new worktree:
- Copy `.env.local` from main repo if it exists and isn't tracked (`cp <main>/.env.local <worktree>/.env.local`).
- `npm install` (or `pnpm`/`yarn` per project); `node_modules` is per-worktree.
- Verify with `git worktree list`; both worktrees should show different branches and HEADs.

**Do not** `cd` into the main repo's checkout from this point. All subsequent operations work in the worktree.

### Step 1.5: Scope audit and branch freshness

Before any review effort, run two checks against the freshly-pulled worktree:

```bash
git log master..HEAD --oneline                # commits this PR adds
git log HEAD..origin/master --oneline         # commits master added since branch point
```

For each commit in the first list, ask: does the subject match the PR title's stated scope? A `feat(billing)` commit on a `lint-cleanup` branch is scope sprawl, not a finding for the reviewer to argue against. Flag mismatches; decide before Step 2 whether to revert (preserve the SHA on a sibling branch or, preferably, a tag — see Step 11 — for a follow-up PR).

If the second list is non-empty, master has moved since branch point. Plan a `git merge origin/master` either now (cleaner) or before push (mandatory). Files the reviewer thinks were "deleted" by this PR may simply be files master added that haven't merged in yet.

### Step 2: Initial code review

Spawn `oh-my-claudecode:code-reviewer` (Sonnet) against the full PR diff:
```
git diff <baseRefName>..HEAD -- <changed paths>
```

Pass the diff plus the PR description's stated intent. Ask for severity-rated findings: blocker / high / medium / low / nit. Reviewer should explicitly cite file:line for each finding.

**Filter the diff before passing to reviewer.** If Step 1.5 flagged commits for revert, exclude their files from the diff:

```bash
git diff <baseRefName>..HEAD -- <changed paths> ':!<file-from-reverted-commit>'
```

### Step 3: Decide direct fix vs. plan

Heuristic:
- **0–2 minor findings, single file, no spec/contract changes** → propose direct fixes inline. Skip to Step 5 (implement directly via Edit calls).
- **Any HIGH finding, multiple files, spec/contract drift, or "fix upstream" request from user** → use `/oh-my-claudecode:plan` (direct mode). Save plan to `<worktree>/.omc/plans/pr<N>-<topic>.md`. **Carve-out:** if every HIGH finding is mechanical (rename, add file, change a constant or string, swap a cache header) AND the reviewer explicitly recommends direct fix, you can skip the plan stage and use the reviewer report itself as the implementation contract.
- **Architectural/multi-system change** → `/oh-my-claudecode:plan --consensus` (Planner → Architect → Critic loop).

Plan must include: scope (in/out), acceptance criteria with file/line refs, implementation steps, risks/mitigations, verification steps, alternatives-rejected.

**User-authored prose findings.** If review findings target prose the user wrote (blog posts, docs, marketing copy, design tokens chosen by hand), surface the disagreement before mass-replacing. The user may want to reword themselves, accept the issue as a one-off exception, or update the underlying convention.

### Step 4: UI shape pass (conditional)

If the change touches user-visible UI surfaces and the project has `PRODUCT.md` or `DESIGN.md`, run `/impeccable shape` and replace the relevant section of the existing plan with its output (don't append).

Skip if the change is backend, infra, or non-visible.

### Step 5: Implement via ralph

`/oh-my-claudecode:ralph` with the plan path as context. Ralph internally runs: PRD scaffold + refinement → story-by-story implementation → architect verification (Sonnet for small changes, Opus for security/architectural) → mandatory `ai-slop-cleaner` pass → post-deslop regression → cancel.

For single-file changes, skip ralph and implement directly via Edit, then run regression yourself; use ralph when you want the structured PRD trail and verification gates.

Always implement after planning unless the user paused you.

**Restoration check.** When the reviewer flags a deletion ("file X was removed under cover of refactor; restore it"), don't re-implement from scratch. First:

```bash
git show origin/master:src/path/to/file.ts | head -20
```

If master has the file, the upstream fix is `git merge origin/master`, not a hand-written restoration. The branch-point check from Step 1.5 should have caught this earlier; this is the safety net.

### Step 6: Verify regression honestly

After implementation:

```bash
npm run check  > check.out 2>&1; rc=$?; echo "exit=$rc" >> check.out
npm run test   > test.out  2>&1; rc=$?; echo "exit=$rc" >> test.out
```

**Two ways the exit code can lie:**

1. **`tail -N` mask.** Piping through `tail` makes the pipeline exit reflect `tail` (always 0), hiding real failures upstream. Don't pipe to tail in background tasks — write to a file and read it.
2. **Wrapper-script mask.** The pattern `cmd > out; echo "exit=$?" >> out` (and any variant where the *last* statement isn't `cmd`) makes the script's overall exit code the `echo`, not `cmd`. Background-task **completion notifications report the wrapper exit, not the inner command's** — so a notification saying "exit code 0" can coexist with `exit=1` written into the file. Always open the file.

To compare against the baseline (find pre-existing errors on the base branch):

```bash
git stash -u && npm run check > check.base.out 2>&1; rc=$?; echo "exit=$rc" >> check.base.out
git stash pop
# diff the error sets; the `-u` flag is required so untracked files added by
# the PR (new endpoints, new lib files) are stashed too. Without `-u` they
# stay on disk during the baseline run, contaminating the count and masking
# new errors as "pre-existing".
```

If delta = 0 new errors (all errors were already present in HEAD), document them as out-of-scope in the PRD and proceed. If delta > 0, fix and re-verify.

**Test runner silent-skip.** Vitest can report `Test Files 7 passed (7)` while a test file's forks worker failed to spawn (e.g., missing `@edge-runtime/vm` peer dep, missing test environment). The error appears as `Unhandled Errors` in the output above the green count, and the affected file's tests never ran. Always grep for it:

```bash
grep -E "Unhandled|forks-worker|ERR_MODULE" test.out
```

Green count + unhandled error = silently-skipped file. Treat as a real failure.

**Auto-fix tools are more aggressive than their check counterparts.** `biome check --write` runs assist actions (organizeImports), lint auto-fixes, AND formatter actions. File-level overrides (e.g., `formatter.enabled: false` for `**/*.astro`) don't always cover all three categories. Run `biome check` (no `--write`) first to see real findings; only `--write` after confirming the proposed fixes are wanted. Same caution applies to `eslint --fix`, `prettier --write`, and similar — `--write` may silently mutate files the project explicitly excluded from one category but not another.

### Step 7: Pre-commit review + commit

`/commit` spawns one more `code-reviewer` pass against the staged diff before committing. This is the third lens, distinct from the architect's PRD-checker and the initial code-reviewer's quality lens.

If the pre-commit reviewer flags a HIGH issue:
1. **Read the spec or convention being cited.** Don't accept the finding on authority.
2. **If reviewer is right.** Fix and re-stage.
3. **If reviewer is wrong.** Surface the disagreement to the user with the spec citation and your counter-argument. Let the user decide. Do not silently override.

Project commit conventions:
- Match the existing `git log --oneline` style for type prefix (`feat:`, `fix:`, `chore:`, `polish:`).
- Subject ≤ 60 chars; match the project's existing separator style.
- Body is prose, hard-wrapped ~72 chars.
- Trailers: `Constraint:`, `Confidence:`, `Scope-risk:`, `Not-tested:` are used in some commits; include when meaningful. Skip for trivial fixes.
- `Co-Authored-By: Claude <model> <noreply@anthropic.com>` (required).
- HEREDOC for multi-line messages (preserves formatting in shells with line-length quirks).

### Step 8: Push

`git push` (branch already tracks origin if it came from `gh pr checkout`-equivalent worktree create). If GitHub returns Dependabot warnings for the default branch, surface them but do not block on them; they're orthogonal to this PR.

**Force-push policy.** `--force-with-lease` is the default safe form for solo feature-branch surgery (amending, dropping commits, post-rebase). It aborts if the remote moved since your last fetch — protecting against overwriting a teammate's push. Use it without user re-confirmation when:
- The user already authorized the surgery (e.g., "drop that commit", "rebase onto master").
- The branch is solo (no co-authors pushing concurrently).
- The remote tip is your own.

Reserve `--force` (no `-with-lease`) and force-push to shared/protected branches for explicit user instruction.

### Step 9: Update PR description if scope changed

If your implementation rejected a stated intent (e.g., "stable navbar across auth states" → "stable across signed-in routes only, cross-auth difference accepted") or if the test plan changed:

```bash
gh pr edit <N> --body "$(cat <<'EOF'
... new description ...
EOF
)"
```

The PR description outlives the squash commit and is what reviewers (and you, six months later) read.

### Step 10: Merge

**Re-fetch master immediately before the merge button.** Another PR may have landed since you pushed:

```bash
git fetch origin master
[ -n "$(git log HEAD..origin/master --oneline)" ] && echo "master moved; merge again"
```

If non-empty, do a `git merge origin/master`, resolve, re-verify (Step 6), push, and only then proceed to the CI-wait poll. Skipping this step is the most common cause of "mergeable: CONFLICTING" surprises right at merge time.

First, wait for CI to finish. Don't poll ad-hoc — use a structured wait:

```bash
# Poll every 30s until no check is IN_PROGRESS / PENDING / QUEUED.
until ! gh pr view <N> --json statusCheckRollup \
        --jq '[.statusCheckRollup[] | (.status // .state // "")] | join(",")' \
        | grep -qE "IN_PROGRESS|PENDING|QUEUED"; do
  sleep 30
done

# Then verify final state.
gh pr view <N> --json mergeable,mergeStateStatus,statusCheckRollup
```

Verify CLEAN/MERGEABLE and CI checks pass. Skipped or NEUTRAL checks are fine when they're skip-by-design (e.g. Netlify "Pages changed" on a backend-only PR).

**Run `gh pr merge` from the main repo, not the worktree.** `gh` tries to `git checkout master` after a successful merge; the worktree's pwd has a non-master branch and master is checked out in the main repo, so the local checkout fails with a misleading `fatal: 'master' is already used by worktree at ...` even though the remote merge landed. Same root cause produces the Windows variant: `failed to delete local branch <head>: cannot delete branch '<head>' used by worktree`. If you see either, confirm with `gh pr view <N> --json state,mergeCommit` — `state: MERGED` means proceed to Step 11; local cleanup happens after the worktree is removed. `"Pull request was already merged"` on retry is the same giveaway.

```bash
cd <main-repo>
gh pr merge <N> --squash --delete-branch
```

`--squash` keeps master history flat (one commit per PR, with the PR description as context). `--delete-branch` removes the remote branch.

### Step 11: Cleanup

Order matters: worktree first (releases its grip on the branch), then local branch, then prune.

```bash
cd <main-repo>
git worktree remove ../<repo>-pr<N>           # may fail with "Directory not empty"
git worktree remove ../<repo>-pr<N> --force   # if untracked node_modules / .env.local / .omc artifacts exist
git branch -D <head>                           # finishes the local-branch cleanup that gh pr merge couldn't
git fetch --prune                              # drop stale remote-tracking ref
```

**Don't sweep preserve-branches.** If during the run you created sibling branches to preserve SHAs (e.g. `git branch billing-followup <reverted-commit>` for the work that got reverted), `git branch -D` should target ONLY the PR's `<head>` branch — not the preserve-branches. Muscle-memory `git branch -D <head> <topic>-followup` deletes both.

For pure SHA preservation, prefer **tags** over branches:

```bash
git tag preserved/<topic>-followup <reverted-sha>
```

Tags don't appear in `git branch` listings or `branch -D` autocompletion, and they survive `git branch` cleanup commands.

**OMC state-path divergence in worktrees.** If ralph ran in the worktree and `/oh-my-claudecode:cancel` reports success but the stop hook keeps firing `[RALPH LOOP - ITERATION N/100] Work is NOT done`, `state_clear` walked up to a parent `.omc/` and missed the worktree's session dir. Don't loop on `--force` cancel — clear the worktree path directly:

```bash
SID="<session-id-from-state-dir-name>"
rm -f <worktree>/.omc/state/sessions/$SID/ralph-state.json \
      <worktree>/.omc/state/sessions/$SID/ultrawork-state.json \
      <worktree>/.omc/state/sessions/$SID/skill-active-state.json
```

See `~/.claude/skills/omc-learned/omc-state-in-worktrees.md` for the underlying mechanism.

## Pre-flight checks

Before invoking this skill, confirm:

- [ ] User authorized merge (the skill ends with `gh pr merge`, which is destructive).
- [ ] No uncommitted work in the main repo's worktree that should be staged first (run `git status` in the main checkout).
- [ ] PR has no `Do Not Merge` label or draft status (`gh pr view <N> --json isDraft,labels`).
- [ ] Base branch is what you expect (some projects use `main`, others `master`).

## Example invocations

- `pr-review-pipeline 5` → run the full flow on PR #5.
- `review and ship PR 12` → same.
- `harden PR 7 and merge` → same.
- `pr-review-pipeline 3 --keep-worktree` → run flow but skip Step 11 (worktree stays for follow-up work).
- `pr-review-pipeline 8 --no-merge` → run through Step 9 (push + description update) but stop before merge. Useful when the user wants a final manual review on the GitHub UI.

## Output

Final report to the user, after Step 11:

```
PR #<N>: MERGED

Squash commit: <oid>
Diff: N files, +X -Y
Reviewers run: code-reviewer (initial), architect (acceptance), code-reviewer (pre-commit)
Out of scope (tracked separately): <list>
Worktree: removed
```
