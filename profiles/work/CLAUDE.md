@AGENTS.md

<!-- OMC:START -->
<!-- OMC:VERSION:4.15.4 -->

# oh-my-claudecode - Intelligent Multi-Agent Orchestration

You are running with oh-my-claudecode (OMC), a multi-agent orchestration layer for Claude Code.
Coordinate specialized agents, tools, and skills so work is completed accurately and efficiently.

<operating_principles>
- Delegate specialized work to the most appropriate agent.
- Prefer evidence over assumptions: verify outcomes before final claims.
- Choose the lightest-weight path that preserves quality.
- Consult official docs before implementing with SDKs/frameworks/APIs.
</operating_principles>

<delegation_rules>
Delegate for: multi-file changes, refactors, debugging, reviews, planning, research, verification.
Work directly for: trivial ops, small clarifications, single commands.
Route code to `executor` (use `model=opus` for complex work). Uncertain SDK usage → `document-specialist` (repo docs first; Context Hub / `chub` when available, graceful web fallback otherwise).
</delegation_rules>

<model_routing>
`haiku` (quick lookups), `sonnet` (standard), `opus` (architecture, deep analysis).
Direct writes OK for: `~/.claude/**`, `.omc/**`, `.claude/**`, `CLAUDE.md`, `AGENTS.md`.
</model_routing>

<skills>
Invoke via `/oh-my-claudecode:<name>`. Trigger patterns auto-detect keywords.
Tier-0 workflows include `autopilot`, `ultrawork`, `ralph`, `team`, and `ralplan`.
Keyword triggers: `"autopilot"→autopilot`, `"ralph"→ralph`, `"ulw"→ultrawork`, `"ccg"→ccg`, `"ralplan"→ralplan`, `"deep interview"→deep-interview`, `"deslop"`/`"anti-slop"`→ai-slop-cleaner, `"deep-analyze"`→analysis mode, `"tdd"`→TDD mode, `"deepsearch"`→codebase search, `"ultrathink"`→deep reasoning, `"cancelomc"`→cancel.
Team orchestration is explicit via `/team`.
Detailed agent catalog, tools, team pipeline, commit protocol, and full skills registry live in the native `omc-reference` skill when skills are available, including reference for `explore`, `planner`, `architect`, `executor`, `designer`, and `writer`; this file remains sufficient without skill support.
</skills>

<verification>
Verify before claiming completion. Size appropriately: small→haiku, standard→sonnet, large/security→opus.
If verification fails, keep iterating.
</verification>

<failure_mode_guards>
User input: when clarification, preference, or approval is required and AskUserQuestion is available, use AskUserQuestion instead of ending with a prose question; ask one focused question with 2-4 options. Use prose only when AskUserQuestion is unavailable or a free-form value is required.
Session/worktree continuity: before editing after resume/compaction or inside a linked worktree, re-check `git status --short --branch`, current cwd, and relevant `.omc/state/` or `.omc/handoffs/` artifacts so work does not continue on the wrong branch or stale context.
No fake completion: TODO-style placeholder notes, `test.skip`/`.only`, stub tests, and unimplemented branches are blockers, not evidence. Before completion, inspect changed files for these patterns and either implement them or report the blocker explicitly.
</failure_mode_guards>

<execution_protocols>
Broad requests: explore first, then plan. 2+ independent tasks in parallel. `run_in_background` for builds/tests.
Keep authoring and review as separate passes: writer pass creates or revises content, reviewer/verifier pass evaluates it later in a separate lane.
Never self-approve in the same active context; use `code-reviewer` or `verifier` for the approval pass.
Before concluding: zero pending tasks, tests passing, verifier evidence collected.
</execution_protocols>

<hooks_and_context>
Hooks inject `<system-reminder>` tags. Key patterns: `hook success: Success` (proceed), `[MAGIC KEYWORD: ...]` (invoke skill), `The boulder never stops` (ralph/ultrawork active).
Persistence: `<remember>` (7 days), `<remember priority>` (permanent).
Kill switches: `DISABLE_OMC`, `OMC_SKIP_HOOKS` (comma-separated).
</hooks_and_context>

<cancellation>
`/oh-my-claudecode:cancel` ends execution modes. Cancel when done+verified or blocked. Don't cancel if work incomplete.
</cancellation>

<worktree_paths>
State root: `.omc/` by default, or `$OMC_STATE_DIR/{project-id}/` when `OMC_STATE_DIR` is set, or the parent `.omc/` when a `.omc-workspace` marker anchors a multi-repo workspace. Runtime state includes `.omc/state/`, `.omc/state/sessions/{sessionId}/`, `.omc/notepad.md`, `.omc/project-memory.json`, `.omc/plans/`, `.omc/research/`, `.omc/logs/`, `.omc/artifacts/`, `.omc/handoffs/`, and `.omc/ultragoal/`. These are ignored operational artifacts by default; `.omc/skills/**` is the intentional committable exception for project-scoped skills. In linked git worktrees, local `.omc/` state is removed with the worktree unless centralized via `OMC_STATE_DIR`.
</worktree_paths>

## Setup

Say "setup omc" or run `/oh-my-claudecode:omc-setup`.

<!-- OMC:END -->

# Personal Rules

<model_policy>
- Never use Haiku models. This overrides any routing guidance above (including the OMC model_routing and verification sections that mention `haiku`).
</model_policy>

<engineering>
- We own the stack. No bandaid fixes, no workarounds, no patching symptoms. Fix the root cause upstream.
- When verifying claims against code (RCA, PR review, postmortem checks), always `git fetch` and confirm findings on the freshly fetched remote mainline branch (the PR target, such as origin/develop or origin/master) before reporting. Local checkouts are often on stale feature branches. Use `git show 'origin/<branch>:<path>'` to inspect without switching branches. Some files may be UTF-16LE; pipe through `iconv -f UTF-16LE -t UTF-8` before grep.
</engineering>

<ado_workflow>
- Create Azure DevOps pull requests with the /elm-pull-request skill (elm-claude-plugin:elm-pull-request), not by calling repo_create_pull_request directly and not via raw git plus manual PR creation. The skill applies ELM PR standards: correct target branch, linked work items, and ELM-compliant title and description formatting. Pushing the branch with git first is fine; the PR itself goes through the skill.
- The same applies to the other ADO workflows when a matching elm-claude-plugin skill exists: /elm-user-story for epics and stories, /elm-bug for bugs, /elm-pr-review for reviewing PRs, /elm-release for releases. /elm-help lists them.
</ado_workflow>

<fable_orchestration>
When the session model is Fable (or Mythos), act as an orchestrator, not an implementer. Fable's context and reasoning are the expensive resource: spend them on decomposition, delegation, synthesis, and final judgment, and dispatch OMC agents on lower models for the hands-on work.

- Default routing: `explore`/lookups on sonnet, implementation via `executor` on sonnet, architecture/deep debugging/review via `architect`/`critic`/`code-reviewer` on opus. Pass an explicit `model` override on every dispatch; do not let agents inherit Fable.
- Fable works directly only for: trivial single-file edits, single commands, config/memory writes (`~/.claude/**`, `.omc/**`, `.claude/**`, `CLAUDE.md`, `AGENTS.md`), and composing the final answer.
- Anything multi-file, multi-step, or research-shaped gets delegated, even if Fable could do it faster inline. Launch independent agents in parallel.
- Fable still owns verification judgment: read agent results critically, cross-check claims, and never forward an agent's unverified assertion as fact.
</fable_orchestration>

<worktree>
- Prefer working in a dedicated git worktree. If the session did not start in one, move to a worktree before making changes rather than working directly in the main checkout.
- Once in a worktree, stay there: do not switch to another worktree or change the working directory out of it mid-task.
</worktree>
