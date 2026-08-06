@AGENTS.md

<routing>
Single source of truth for model selection and subagent delegation. No other section in this file governs routing. This is a work machine: Claude models only. Never dispatch to external model CLIs (Codex, Grok, Gemini, or any non-Claude tool), even if guidance merged from another profile mentions them.

Models available, rated 1 (low) to 5 (high) on intelligence and speed, and 1 (cheap) to 5 (expensive) on cost:

| Model | Intelligence | Speed | Cost | Access | Use for |
|---|---|---|---|---|---|
| `opus` (claude-opus-5) | 5 | 2 | 5 | Agent `model=opus` (default coding tier) | Default tier for coding: implementation, debugging, architecture, security-sensitive code, refactors, planning/critique, review, judgment calls that gate a completion claim, and any task of uncertain complexity |
| `sonnet` (claude-sonnet-5) | 4 | 3 | 3 | Agent `model=sonnet` | Downgrade tier, opt-in only: clearly trivial mechanical slices (formulaic single-file edits, simple lookups, routine sweeps) where opus intelligence adds nothing; at any sign of complexity route to `opus` instead |
| `fable` (claude-fable-5) | 4 | 4 | 2 | Session model only; never a spawn target | Main-loop orchestration when it is the active session model; its spawns still route to `opus`/`sonnet` per the decision order |
| `haiku` | - | - | - | Banned | Never use, no exceptions, overrides every other rule in this file |

Decision order for any delegated task:
1. Pick the Claude tier by coding complexity. `opus` is the default coding tier, including implementation, multi-file changes, debugging, review, and any task of uncertain complexity. Drop to `sonnet` only for clearly trivial mechanical slices (formulaic single-file edits, simple lookups, routine read-only sweeps) where opus intelligence changes nothing; when in doubt, `opus`. Never `haiku`.
2. If a task placed on `sonnet` fails concretely, rerun it on `opus` instead of iterating on `sonnet`. Never downroute below these floors to "balance" a distribution.
3. Agent type: read-only searches and codebase sweeps go to `Explore`, not `general-purpose`. Every spawn of every type (`Explore`, `Plan`, `general-purpose`, custom) pins `model` explicitly: `opus` unless the task is clearly trivial and mechanical per rule 1, then `sonnet`. Never `fable` for spawns; omitting `model` inherits the session model and counts as a violation, and the enforce-spawn-model PreToolUse hook denies any spawn with a missing, fable, or haiku model.

Delegation prompt quality (every Agent/Task spawn, regardless of target model): the target does not see this conversation, so each prompt must carry an objective + definition of done, context it cannot see (paths, prior decisions, constraints, the "why"), an output contract sized to fit back into context (a summary, not a raw dump), tool/source guidance, and boundaries (scope limits, don't-touch zones, when to stop and report back instead of guessing). If you could not hand the prompt to a competent stranger with no other context and expect the right result, it is not ready to send. Standing style and workflow rules live in AGENTS.md and reach every subagent on their own; do not restate those rules in spawn prompts, only task-specific context.

Orchestration posture by active session model:
- Opus: organize the work yourself, deploy agents to execute it. Decompose into independent, well-bounded slices before spawning; deploy independent slices concurrently (multiple Agent calls in one message); scale the fleet to complexity (1 agent for a single lookup, 2-4 for a comparison, a larger fleet plus a synthesis pass for a broad audit/migration). Keep planning, synthesis, and final verification in the main loop; do not rubber-stamp agent output. Do not spawn an agent for a one-line edit, a single command, or work needing constant back-and-forth with live context.
- Fable: aggressive orchestrator, never worker. Treat main-loop tool calls as a scarce budget: any task expected to take more than ~3 tool calls, touch more than one file, or produce output the user will not read verbatim gets dispatched per the decision order above, not done inline. Dispatch independent slices concurrently in one message; when in doubt between doing and delegating, delegate. The main loop keeps only decomposition, judging returned results, and composing the final user-facing response. Direct work is limited to single-command ops, trivial one-file edits, and answers already derivable from conversation context.
- Any other session model (sonnet, etc.): apply the decision order above directly, no special posture.
</routing>

<execution>
Broad or vague requests: explore first, then plan, then implement. Run builds, test suites, and installs with run_in_background instead of blocking the loop on them.
Session hygiene: commit each completed slice as it lands rather than batching at session end. When a task finishes and the next is unrelated, suggest the user /clear (or /compact mid-task) instead of continuing to accumulate context; sessions past ~150k context are disproportionately expensive even fully cached. Long-running loops wake every 20-30 minutes minimum. Prefer queueing work over running 4+ parallel sessions; all sessions share one limit.
</execution>

<verification>
Before any completion claim or auto-commit: zero pending tasks, tests passing, and verification evidence collected by actually exercising the change, not just typechecking. Never self-approve in the same context. For simple, well-bounded changes the /commit runner's review is the single review gate; do not spawn a separate verifier agent first. Spawn a dedicated `opus` reviewer pass, in addition to the /commit gate, only for large, cross-cutting, or security-sensitive changes. If verification fails, keep iterating.
</verification>

<auto_commit>
When a requested change is complete and every gate passes (tests green, verification evidence collected, zero pending tasks), run the /commit workflow immediately; do not wait for the user to ask. Skip only when: the user said not to commit, the work was assessment or exploration with no code change, or the change is one slice of a larger plan still in flight.
</auto_commit>

# Personal Rules (work PC)

<model_policy>
- Never use Haiku models. No exceptions. Reinforces the `haiku` = Banned row in the routing table above; overrides any guidance to the contrary.
</model_policy>

<engineering>
- We own the stack. No bandaid fixes, no workarounds, no patching symptoms. Fix the root cause upstream.
- When verifying claims against code (RCA, PR review, postmortem checks), always `git fetch` and confirm findings on the freshly fetched remote mainline branch (the PR target, such as origin/develop or origin/master) before reporting. Local checkouts are often on stale feature branches. Use `git show 'origin/<branch>:<path>'` to inspect without switching branches. Some files may be UTF-16LE; pipe through `iconv -f UTF-16LE -t UTF-8` before grep.
</engineering>

<org_workflow>
The /org-* commands below are an example: they come from an org-internal Claude Code plugin
(the `example-org-plugin@example-org` entry in settings.overlay.json). Swap the plugin id and
the command names for your own org's, or drop this section if your org has no such plugin.

- Create pull requests with the /org-pull-request skill (example-org-plugin:org-pull-request), not by calling the tracker's create-pull-request tool directly and not via raw git plus manual PR creation. The skill applies the org's PR standards: correct target branch, linked work items, and compliant title and description formatting. Pushing the branch with git first is fine; the PR itself goes through the skill.
- The same applies to the other work-item-tracker workflows when a matching plugin skill exists: /org-user-story for epics and stories, /org-bug for bugs, /org-pr-review for reviewing PRs, /org-release for releases. /org-help lists them.
</org_workflow>

<worktree>
- Prefer working in a dedicated git worktree. If the session did not start in one, move to a worktree before making changes rather than working directly in the main checkout.
- Once in a worktree, stay there: do not switch to another worktree or change the working directory out of it mid-task.
</worktree>
