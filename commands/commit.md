# Commit

Run a mandatory ai-slop-cleaner pass, then review staged changes with the OMC code-reviewer agent and create a commit following project conventions.

## Core Principle — No Bandaid Fixes, Fix Upstream

Every step in this workflow obeys the same rule: when something fails or is flagged, fix the root cause. Do not bandaid.

Banned across all steps:
- `@ts-ignore`, `// @ts-expect-error` with no removal trigger, `eslint-disable`, `# noqa`, `# type: ignore` to silence problems.
- `--no-verify`, skipping hooks, bypassing signing, or disabling pre-commit checks.
- Swallowed `try/catch` blocks that hide the failure instead of fixing it.
- `.skip` / `xfail` / commented-out tests to make a red suite green.
- Patching a symptom in a caller when the bug is in the source. Fix the source.
- "Temporary" workarounds without a one-line comment naming the upstream issue and removal trigger.

When a fix is genuinely blocked upstream (external SDK, vendor bug, locked dependency), leave a single-line comment naming the issue and the removal trigger, and surface it in the final report.

## Usage

```
/commit
/commit "feat: add user authentication"
```

If no commit message is provided, generate one from the diff.

## Workflow

### Step 0 — Sync with develop (mandatory, runs first)

Pull the latest `develop` into the current worktree/branch **before** cleanup and review, so the review runs against up-to-date code and merge conflicts surface here (small, local, fixable) instead of later at PR time.

**Preflight:** confirm a git repo with `git rev-parse --is-inside-work-tree`. If not, stop (the Step 1 preflight also covers this). Determine the current branch:

```
git rev-parse --abbrev-ref HEAD
```

If the current branch **is** `develop`, skip this step (nothing to pull into itself) and note it in the output.

Otherwise sync the integration branch into the current branch. Update the **local** `develop` from the remote first, then merge the local branch in, so both the local and remote states are in sync before review:

```
git fetch origin develop
git fetch origin develop:develop   # fast-forward local develop to origin/develop without checking it out
git merge --no-edit develop
```

Notes and root-cause rules:
- Keep local and remote `develop` in agreement. `git fetch origin develop:develop` fast-forwards the local `develop` ref to match `origin/develop` without switching branches. If that ref update is rejected because local `develop` has diverged (non-fast-forward), **stop and report** — do not force-update the local branch; the user needs to reconcile it. You may still proceed to merge `origin/develop` only if the user opts to, but flag the divergence.
- If `develop` is the branch currently checked out in **another worktree**, the ref-update fetch will refuse. In that case merge `origin/develop` directly and note that local `develop` lives in another worktree.
- Prefer `develop`. If the repo has no `develop` branch, fall back to its default integration branch (`main`/`master`) and say which one you used. If you cannot determine one, skip the sync and surface why — do not guess and merge the wrong branch.
- Uncommitted work is expected at commit time. If the merge fails because local changes would be overwritten, or the worktree is otherwise dirty in a way that blocks the merge, **stop and report** — do not stash-and-drop or force the merge in a way that could lose work. Let the user decide.
- On merge conflicts, **resolve them for real** at the source. Do not `git checkout --theirs/--ours` blindly, do not comment out conflicting code, and do not abort-and-skip to dodge the conflict. If resolution is genuinely blocked, `git merge --abort`, stop, and report the conflicting files so the user can decide.
- After a successful merge, re-run any relevant quality gates (build/typecheck/tests) before continuing — a clean textual merge can still break the build.
- This step is **not skippable** unless the user passes `--no-sync`.

### Step 1 — AI Slop Cleanup (mandatory, runs before review)

`ai-slop-cleaner` is a **skill**, not an agent. Invoke it via the `Skill` tool with `skill: "oh-my-claudecode:ai-slop-cleaner"` (slash form: `/oh-my-claudecode:ai-slop-cleaner`). Do **not** call the `Agent` tool with `subagent_type: "oh-my-claudecode:ai-slop-cleaner"` — that subagent does not exist and will error.

Run it in **writer mode** (not `--review`) scoped to the changed files in this commit:

```
git diff --name-only HEAD
git diff --cached --name-only
```

Pass that file list as the cleaner's `args`. The cleaner must fully run, including applying its fixes, before Step 2 begins. Follow the cleaner's full workflow: behavior lock, cleanup plan, smell-focused passes (dead code, duplication, naming/error-handling, test reinforcement), and quality gates.

**Preflight (run before the cleaner):** verify the working directory is a git repository with `git rev-parse --is-inside-work-tree`. If it is not, stop and tell the user the directory is not a git repo — do not invoke the cleaner, do not stage, do not commit.

Requirements:
- This pass is **not optional** and **not skippable** unless the user passes `--skip-deslop`.
- If the cleaner makes changes, re-stage them (`git add -u` for tracked files; stage new files explicitly) so the review and commit see the cleaned diff.
- If the cleaner's quality gates fail (lint, typecheck, tests), **fix the root cause upstream** — do not silence the failure with ignore comments, disabled rules, `.skip`/`xfail`, swallowed `try/catch`, or "temporary" workarounds. Do not proceed to review with a red build.
- If the cleaner reports unresolved risks, surface them before Step 2 and fix them at the source rather than masking the symptom in a caller.

### Step 2 — Code Review

Spawn the `oh-my-claudecode:code-reviewer` agent on the **post-cleanup** staged/unstaged changes:

```
git diff HEAD
git diff --cached
git status
```

Pass the full post-cleanup diff to the code-reviewer. If the reviewer returns **blocking issues** (severity: critical or high), stop and report them to the user. Do not proceed to commit until the user resolves the issues or explicitly overrides with `/commit --skip-review`.

When resolving reviewer findings, **fix upstream, not at the symptom**. If the bug is in a shared helper, fix the helper rather than patching every caller. If the type is wrong, fix the type rather than casting around it. Do not add ignore comments, disable lint rules, or wrap failing code in swallowed `try/catch` to clear a review flag.

If the reviewer returns only warnings or suggestions, proceed but surface them in the output.

### Step 3 — Commit

Follow the project commit convention from CLAUDE.md:

```
<type>: <short description>

<body>

Constraint: ...
Rejected: ...
Directive: ...
Confidence: high | medium | low
Scope-risk: narrow | moderate | broad
Not-tested: ...
```

- Use `git diff --cached` (staged) or `git diff HEAD` (all changes) to infer type and description if no message was supplied.
- Stage all modified/new tracked files with `git add -u` if nothing is staged yet.
- Include git trailers when the change is non-trivial (skip for typos, formatting, dependency bumps).
- Pass the commit message via HEREDOC to preserve formatting.
- **Never** commit with `--no-verify` or other hook-bypass flags unless the user explicitly requests it. If a pre-commit hook fails, fix the underlying issue upstream — do not bypass.
- If the commit includes a deliberate workaround for an upstream issue, name the issue and removal trigger in the body so it does not become permanent.

## Flags

- `--no-sync` — skip the Step 0 pull of `develop` into the current branch (default is to sync)
- `--skip-deslop` — skip the mandatory ai-slop-cleaner pass (escape hatch; default is to run it)
- `--skip-review` — skip the code-reviewer step and go straight to commit
- `--push` — commit and then push to the current tracking branch (or set upstream if none)

## Example Output

```
Syncing develop into feature/auth...
  ✓ Fetched origin/develop
  ✓ Merged origin/develop (no conflicts)

Running ai-slop-cleaner (writer mode)...
  ✓ Dead code removed: 2 files
  ✓ Duplicate helpers consolidated: 1
  ✓ Quality gates green
  Re-staged cleaned changes.

Running code review...
  ✓ No critical issues found
  ⚠ 2 suggestions (non-blocking)

Committing...
  [master a1b2c3d] feat: add user authentication
```
