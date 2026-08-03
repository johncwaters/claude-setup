@AGENTS.md

<routing>
Single source of truth for model selection, subagent delegation, and Codex offload. No other section in this file governs routing.

Models available, rated 1 (low) to 5 (high) on intelligence and speed, and 1 (cheap) to 5 (expensive) on cost:

| Model | Intelligence | Speed | Cost | Access | Use for |
|---|---|---|---|---|---|
| `opus` (claude-opus-5) | 5 | 2 | 5 | Agent `model=opus` | Reserved tier: debugging, architecture, security-sensitive code, cross-cutting refactors, planning/critique of large changes, final review of large or risky diffs, judgment calls that gate a completion claim, and reruns after a concrete `sonnet` failure |
| `sonnet` (claude-sonnet-5) | 4 | 3 | 3 | Agent `model=sonnet` (default coding tier) | Default for coding, single- or multi-file, when the task is well specified: implementation, boilerplate, tests, mechanical refactors, routine review. Tasks of uncertain complexity start here; rule 3 escalates |
| `fable` (claude-fable-5) | 4 | 4 | 2 | Session model only; never a spawn target | Main-loop orchestration when it is the active session model; its spawns still route to `sonnet`/`opus` per the decision order |
| `GPT-5.6` (Codex CLI, `@openai/codex`) | 4 | 3 | 1 | `codex exec --dangerously-bypass-approvals-and-sandbox -m gpt-5.6` (direct, prompt on stdin) | PC control (see step 0 below), mechanical/cheap work, independent second opinions, self-contained parallel slices needing no Claude tools |
| Grok (`grok-4.5`, default via grok.com login; run `grok models` for options) | 4 | 4 | 2 | `grok --prompt-file <file> --always-approve` (direct, prompt via file) | Default for research and current-information lookups; independent external opinion from a non-OpenAI, non-Anthropic model (family diversity for tie-breaks and consensus); real-time or X/Twitter knowledge; fast self-contained code slices needing no Claude tools. Requires `XAI_API_KEY` (or one-time `grok login`) |
| `haiku` | - | - | - | Banned | Never use, no exceptions, overrides every other rule in this file |

External dispatch mechanics (Codex and Grok share these): write the full prompt to a temp file. Codex: `codex exec --dangerously-bypass-approvals-and-sandbox -m gpt-5.6 < <file>`; if GPT-5.6 is unavailable or errors, retry once with `-m gpt-5.5` and say which model handled it. Grok: `grok --prompt-file <file> --always-approve` (default `grok-4.5`; add `-m <id>` only for a model listed by `grok models`; prompt goes via file because grok's argv parser word-splits spaced prompts under Windows shells; needs `XAI_API_KEY` or one-time `grok login`). Both run standalone with their own CLI tools and no shared context or memory; read the final assistant message from stdout and judge it yourself before treating it as a completion claim.

Decision order for any delegated task:
0. Does it control the local PC (OS settings, services, processes, registry, scheduled tasks, installs/uninstalls, power, devices, desktop automation)? If yes, route it to Codex on GPT-5.6; this is the only external path for PC control. Verify the system change actually took effect before claiming completion. Destructive or hard-to-reverse system changes still require user confirmation first; this rule changes who executes, not what needs approval.
1. Does it need Claude-side tools, subagents, or file edits? If no, and the task is cheap/mechanical or benefits from an independent perspective, send it to Codex. Codex is a bounded assistant, not a primary coding path: mechanical work, second opinions, and PC control only. Coding that warrants real judgment stays on Claude tiers even when self-contained.
1b. Research and current-information tasks default to Grok: any research question or current-events/real-time/X-Twitter lookup; an independent opinion from a non-OpenAI, non-Anthropic model (a tie-breaker in a multi-model consensus, or a third check when Codex and Claude already agree); or a second external executor on independent, self-contained slices.
2. Otherwise pick the Claude tier by coding complexity. `sonnet` is the default coding tier, including multi-file changes and any task of uncertain complexity. `opus` only for its reserved list in the table: debugging, architecture, security-sensitive code, cross-cutting refactors, planning/critique of large changes, final review of large/risky diffs, judgment calls that gate a completion claim. Never `haiku`.
3. If `sonnet` fails concretely, rerun the task on `opus` instead of iterating on `sonnet`. Never downroute below these floors to "balance" a distribution.
4. Agent type: read-only searches and codebase sweeps go to `Explore`, not `general-purpose`. Every spawn of every type (`Explore`, `Plan`, `general-purpose`, custom) pins `model` explicitly: `sonnet` unless the task hits the opus reserved list. Never `fable` for spawns; omitting `model` inherits the session model and counts as a violation.

Delegation prompt quality (every Agent/Task spawn and every direct Codex or Grok CLI dispatch, regardless of target model): the target does not see this conversation, so each prompt must carry an objective + definition of done, context it cannot see (paths, prior decisions, constraints, the "why"), an output contract sized to fit back into context (a summary, not a raw dump), tool/source guidance, and boundaries (scope limits, don't-touch zones, when to stop and report back instead of guessing). If you could not hand the prompt to a competent stranger with no other context and expect the right result, it is not ready to send. Standing style and workflow rules live in AGENTS.md and reach every tool on their own: Claude subagents inherit this file, Codex reads `~/.codex/AGENTS.md` globally plus repo AGENTS.md, and Grok reads repo AGENTS.md; do not restate those rules in dispatch prompts, only task-specific context.

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
