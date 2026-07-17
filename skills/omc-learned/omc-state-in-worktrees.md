---
name: omc-state-in-worktrees
description: OMC state-path resolution diverges in git worktrees, breaking ralph cancel and the stop-hook loop. Recognize the symptom and clean both paths.
triggers:
  - ralph mode loop won't stop
  - "[RALPH LOOP - ITERATION N/100] Work is NOT done"
  - state_clear succeeded but stop hook keeps firing
  - cancel ran but ralph keeps re-engaging
  - worktree ralph stop hook
  - omc cancel from worktree
  - state_get_status shows path outside the worktree
---

# OMC state-path divergence in git worktrees

## The Insight

OMC's state tools (`state_clear`, `state_read`, `state_get_status`) resolve their state directory by walking **upward** from the working directory until they find an `.omc` folder. The persistent-mode **stop hook** does the same walk, but they don't always agree on which `.omc` to use.

When you run a ralph workflow inside a git worktree (`milepost-pr2/`), ralph's runtime writes its session state to the **worktree's** `.omc/state/sessions/{sid}/ralph-state.json`. But if a parent directory of the worktree also contains an `.omc/` (e.g. `Projects/.omc/` exists because that's the directory you launched Claude Code from), `state_clear` may operate on the **parent's** `.omc` path instead. The clear succeeds, the tool reports success, and the worktree's stale state files remain — so the stop hook keeps firing `[RALPH LOOP ...]` reinforcement messages forever.

## Why This Matters

Without this knowledge, you'll:
- Run `/oh-my-claudecode:cancel` and watch it succeed.
- Get hit with `[RALPH LOOP - ITERATION N/100] Work is NOT done` immediately after.
- Re-run cancel, see another success, get the same loop.
- Spiral into trying `--force`, retry, etc., all of which clear the wrong path.

The fix is one rm command, but it's invisible until you check both paths.

## Recognition Pattern

You're inside a worktree (CWD ends in `<repo>-<branch-suffix>/` and `git worktree list` shows multiple entries) AND:

1. `mcp__plugin_oh-my-claudecode_t__state_clear` returns `"Successfully cleared state for mode: ralph"` but stop-hook reinforcement continues.
2. `state_get_status` reports the state file path **outside** the worktree (e.g. `C:\Users\johnw\Projects\.omc\state\sessions\…` while you're in `C:\Users\johnw\Projects\milepost-pr2\`).
3. `ls <worktree>/.omc/state/sessions/<sid>/` still shows `ralph-state.json`, `ultrawork-state.json`, or `skill-active-state.json`.

That's the divergence. Confirms it instantly.

## The Approach

Treat OMC state cleanup as a **two-path operation** in worktrees:

1. Run the normal `state_clear` for `ralph`, `ultrawork`, and `skill-active` (covers the parent `.omc` path the tool prefers).
2. Then directly remove the same files from the worktree's session dir:
   ```bash
   rm -f <worktree>/.omc/state/sessions/<sessionId>/ralph-state.json \
         <worktree>/.omc/state/sessions/<sessionId>/ultrawork-state.json \
         <worktree>/.omc/state/sessions/<sessionId>/skill-active-state.json
   ```
3. Verify with `ls <worktree>/.omc/state/sessions/<sessionId>/` — should leave only `prd.json`, `progress.txt`, and `hud-state.json` (or be empty).

The session ID is the directory name under `.omc/state/sessions/`. If unsure, `ls` it — typically one UUID-shaped dir.

**Decision heuristic:** if the stop hook keeps firing within ~5 seconds after a clean `state_clear` success, you're hitting the divergence. Don't loop on `--force`; just remove the worktree-local state files directly.

## Worktree workflow for parallel PR review (supporting context)

The pattern that produces this divergence is also the right pattern for reviewing a PR while another agent works on a different PR:

1. From main repo: `git worktree add ../<repo>-pr<N> <branch>`
2. Copy `.env.local` (not tracked) from main repo to worktree.
3. `npm install` in the worktree (`node_modules` is per-worktree).
4. Work in the worktree — runs of `/ralph`, `/ultrawork`, `/team` all create state in **worktree-local** `.omc/`.
5. On completion: commit, push, merge, then **clean both state paths** before removing the worktree.
6. Worktree removal: `cd <main-repo> && git worktree remove ../<repo>-pr<N> --force` (force needed if `node_modules`/`.env.local`/`.omc` untracked files exist; verify nothing important is uncommitted first).

`gh pr merge --squash --delete-branch` from inside a worktree will retarget the worktree's HEAD to `master` automatically and delete the local feature branch — but **does not** remove the worktree directory.

## Adjacent gotcha (related but distinct)

When verifying regressions in background, **`npm run check 2>&1 | tail -15`** masks the real exit code: the pipeline exit reflects `tail` (always 0), not `astro check`. The completion notification will say "exit code 0" while the check actually failed. If you want a true regression signal from a piped command, read the file content, don't trust the exit code. Or drop the pipe and rely on Read on the output file.
