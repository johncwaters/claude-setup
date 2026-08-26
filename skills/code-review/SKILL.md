---
name: code-review
description: Run a scoped, token-bounded review of the working diff or staged changes using the local code-reviewer agent, with dedicated security and organization lanes and an optional ChatGPT (Codex CLI) second opinion for contested or high-risk findings. Use when asked to review changes, a diff, or a branch, and as step 2 of /commit.
---

# Code Review

Lane-based review process. One scoped general reviewer by default; extra lanes and escalation are explicit, never automatic habit.

## Reviewer lanes

| Lane | Agent | Model | When it runs |
|---|---|---|---|
| General (default) | `code-reviewer` | sonnet | Every review. Logic defects, correctness, contracts |
| Security | `security-reviewer` | opus | Diff touches auth, input handling, crypto, payments, PII, secrets, infrastructure, or destructive operations; or the user asks |
| Organization | `structure-reviewer` | sonnet | Diff is a refactor, establishes a new module/boundary/layer, or moves responsibilities across existing ones; or the user asks. A commit merely containing new files does not trigger it |
| Second general opinion | ChatGPT via Codex CLI | external | Every review. Logic defects, correctness, contracts  |

The general lane always runs. Add a lane only when its trigger holds; do not run all lanes by habit. When multiple lanes trigger, spawn their agents **in parallel** (one message, multiple Agent calls) and merge findings afterward.

## Process

### 1. Collect scope

```
git status
git diff --cached --stat     # staged
git diff HEAD --stat         # all changes
```

Decide the review target: staged diff (commit flow) or full working diff (ad-hoc review). Note file count and rough diff size. From the touched files and change type, decide which lanes trigger, and say which you picked and why in one line.

### 2. Spawn the reviewer(s)

Spawn the lane agents (in parallel when more than one). Every prompt must carry, per the delegation contract in CLAUDE.md:

- The exact repo path and the git command that produces the diff under review
- What changed and why (2-4 sentences of context the agent cannot see)
- Facts already verified live, so the agent does not re-flag them
- The ask: blocking problems only, severity-tagged, one line per finding, skip nits
- Each agent's own output contract applies (it knows it; do not paste the diff itself when the agent can run git locally)

One pass per lane. Never auto-run multi-agent cloud review; anything beyond these lanes is user-triggered and billed. For very large diffs (>2000 changed lines), tell each agent to prioritize by risk instead of spawning more agents.

### 3. Triage the verdict

- **Reviewer death is blocking**: if any spawned agent errors, returns empty output, or produces no parseable verdict, treat it as a blocking failure. Stop and report; never fall through to "approved" on a dead review.
- **critical / high** (any lane): blocking. Stop, report to the user, fix upstream before commit. Fix the source, not the symptom; no ignore comments, no disabled rules, no swallowed errors to clear a flag.
- **medium / low**: non-blocking. Surface in the final output; fix now if trivial.
- Merge multi-lane findings into one list, most severe first, deduplicating overlaps (keep the more specific finding).
- LOW-CONFIDENCE findings: resolve with evidence already in hand when possible; otherwise verify or carry as an open question. Do not treat as blocking.

### 4. Report

Compact summary: files reviewed, lanes run and why, blocking count, findings one line each (merged, most severe first), second-opinion outcome if used, final recommendation.

## Token discipline

- Default cost is one sonnet agent pass on a scoped diff. Keep it there.
- Each extra lane costs one more agent pass (security = opus, pricier; reserve it for its real triggers).
- Never paste large diffs into agent prompts when the agent can run git itself.
