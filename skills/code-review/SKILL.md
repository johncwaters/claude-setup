---
name: code-review
description: Run a scoped, token-bounded review of the working diff or staged changes using the local code-reviewer agent, with an optional ChatGPT (Codex CLI) second opinion for contested or high-risk findings. Use when asked to review changes, a diff, or a branch, and as step 2 of /commit.
---

# Code Review

Single-reviewer, token-bounded review process. One scoped agent by default; escalation is explicit, never automatic.

## Process

### 1. Collect scope

```
git status
git diff --cached --stat     # staged
git diff HEAD --stat         # all changes
```

Decide the review target: staged diff (commit flow) or full working diff (ad-hoc review). Note file count and rough diff size.

### 2. Spawn the reviewer

Spawn the local `code-reviewer` agent (sonnet). The prompt must carry, per the delegation contract in CLAUDE.md:

- The exact repo path and the git command that produces the diff under review
- What changed and why (2-4 sentences of context the agent cannot see)
- Facts already verified live, so the agent does not re-flag them
- The ask: blocking problems only, severity-tagged, one line per finding, skip nits
- The output contract from the agent definition (it already knows it; do not paste the diff itself when the agent can run git locally)

One agent, one pass. Do not fan out multiple reviewers, and never auto-run multi-agent or cloud review (`/code-review ultra` is user-triggered and billed). For very large diffs (>2000 changed lines), tell the agent to prioritize by risk instead of spawning more agents.

### 3. Triage the verdict

- **critical / high**: blocking. Stop, report to the user, fix upstream before commit. Fix the source, not the symptom; no ignore comments, no disabled rules, no swallowed errors to clear a flag.
- **medium / low**: non-blocking. Surface in the final output; fix now if trivial.
- LOW-CONFIDENCE findings: resolve with evidence already in hand when possible; otherwise verify or carry as an open question. Do not treat as blocking.

### 4. Second opinion via ChatGPT (opt-in lane)

Get an independent Codex review when any of these hold:

- The user asks for a second opinion
- A critical/high finding is contested: the reviewer and your own read disagree, or the fix is expensive and the finding is uncertain
- The change is security-sensitive or risks data loss, and independent confirmation is cheap insurance

Dispatch (direct CLI, read-only sandbox, prompt via stdin to avoid Windows argv quoting):

```
# write the prompt to a temp file, then:
codex exec -s read-only < <promptfile>
```

The prompt file must contain: repo path, the diff itself (Codex sees nothing from this session), the specific contested question or "independent severity-tagged review, blocking issues only", and an instruction to report findings without modifying anything.

Reconcile:
- Both agree: act on the shared verdict.
- They disagree: present both verdicts to the user with your own recommendation. Do not silently pick one.

### 5. Report

Compact summary: files reviewed, blocking count, findings one line each, second-opinion outcome if used, final recommendation.

## Token discipline

- Default cost is one sonnet agent pass on a scoped diff. Keep it there.
- Never paste large diffs into agent prompts when the agent can run git itself.
- The Codex lane costs one extra dispatch; use it when the triggers above hold, not by habit.
