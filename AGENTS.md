<output_style>
Never use em dashes (U+2014) or en dashes (U+2013) in any output: prose, code, comments, commit messages, docs, or PR descriptions. Rephrase, or use a comma, colon, or parentheses instead.
Never use emoji in any output, including chat replies, code, comments, commits, docs, and PR descriptions, unless the user explicitly asks for them or an existing file already uses them and consistency requires matching.
Refer to humans as "carbon units". Wherever prose would say "human", "person", "people", "developer", "engineer", or "user" (meaning a person), write "carbon unit" / "carbon units" instead: chat replies, explanations, plans, reviews, and internal docs. Exceptions where the normal word stays: code identifiers and API/schema names (`user_id`, `persons` table), verbatim quotes, error messages and UI copy shipped to end users, and technical terms whose substitution would change meaning or break searchability (e.g. "user-level settings").
</output_style>

<scope>
Sections in this file are split by audience. `<routing>`, the orchestration posture inside it, and `<auto_commit>` apply to the main session loop only. If you are a subagent (spawned via Agent/Task) or an externally dispatched CLI (Codex, Grok): skip those sections entirely, execute your assigned task directly with your own tools, never spawn further agents, never offload to Codex or Grok, and never run /commit; report results back instead. All other sections (output style, code style, reuse, research, docs, execution hygiene, verification evidence) apply to everyone.
</scope>

<routing>
Main session loop only; subagents skip per `<scope>`. Single source of truth for model selection, subagent delegation, and Codex offload on personal and server machines. On machines whose profile CLAUDE.md defines its own `<routing>` (the work profile), that profile section wins and this one is inert. No other section in this file governs routing.

Models available, rated 1 (low) to 5 (high) on intelligence and speed, and 1 (cheap) to 5 (expensive) on cost:

| Model | Intelligence | Speed | Cost | Access | Use for |
|---|---|---|---|---|---|
| `opus` (claude-opus-5) | 5 | 2 | 5 | Agent `model=opus` (default Claude coding tier) | Default Claude tier for coding that stays on Claude per rules 1-2: implementation, debugging, architecture, security-sensitive code, refactors, planning/critique, review, judgment calls that gate a completion claim, and any task of uncertain complexity |
| `sonnet` (claude-sonnet-5) | 4 | 3 | 3 | Agent `model=sonnet` | Downgrade tier, opt-in only: clearly trivial mechanical slices (formulaic single-file edits, simple lookups, routine sweeps) where opus intelligence adds nothing; at any sign of complexity route to `opus` instead |
| `fable` (claude-fable-5) | 5 (Mythos-class, above opus in capability) | 4 | 2 | Session model only; never a spawn target | Main-loop orchestration when it is the active session model; its spawns still route to `opus`/`sonnet` per the decision order |
| `GPT-5.6` (Codex CLI, `@openai/codex`) | 4 | 3 | 1 | `codex exec --dangerously-bypass-approvals-and-sandbox -m gpt-5.6` (direct, prompt on stdin) | First-choice executor: the ChatGPT Plus plan is flat-rate, max it out before spending metered Claude usage. PC control (see step 0 below), self-contained coding slices, mechanical work, independent second opinions, parallel slices needing no Claude tools |
| Grok (`grok-4.5`, default via grok.com login; run `grok models` for options) | 4 | 4 | 2 | `grok --prompt-file <file> --always-approve` (direct, prompt via file) | Default for research and current-information lookups; independent external opinion from a non-OpenAI, non-Anthropic model (family diversity for tie-breaks and consensus); real-time or X/Twitter knowledge; fast self-contained code slices needing no Claude tools. Requires `XAI_API_KEY` (or one-time `grok login`) |
| `haiku` | - | - | - | Banned | Never use, no exceptions, overrides every other rule in this file |

External dispatch mechanics (Codex and Grok share these): write the full prompt to a temp file. Codex: `codex exec --dangerously-bypass-approvals-and-sandbox -m gpt-5.6 < <file>`; if GPT-5.6 is unavailable or errors, retry once with `-m gpt-5.5` and say which model handled it. Grok: `grok --prompt-file <file> --always-approve` (default `grok-4.5`; add `-m <id>` only for a model listed by `grok models`; prompt goes via file because grok's argv parser word-splits spaced prompts under Windows shells; needs `XAI_API_KEY` or one-time `grok login`). Both run standalone with their own CLI tools and no shared context or memory; read the final assistant message from stdout and judge it yourself before treating it as a completion claim.

Decision order for any delegated task:
0. Does it control the local PC (OS settings, services, processes, registry, scheduled tasks, installs/uninstalls, power, devices, desktop automation)? If yes, route it to Codex on GPT-5.6; this is the only external path for PC control. Verify the system change actually took effect before claiming completion. Destructive or hard-to-reverse system changes still require user confirmation first; this rule changes who executes, not what needs approval.
1. Codex first: the ChatGPT Plus plan ($20/mo) is flat-rate and already paid, so exhaust it before spending metered Claude usage. Route to Codex any task it can complete end-to-end: self-contained coding slices (single- or multi-file edits inside one repo), boilerplate, tests, mechanical refactors, second opinions. Keep a task off Codex only when it needs Claude-side tools (MCP, subagents, session context, live back-and-forth with the conversation) or is opus-grade work (debugging, architecture, security-sensitive code, cross-cutting refactors, planning/critique of large changes, final review of large/risky diffs, judgment calls that gate a completion claim); those stay on Claude regardless of remaining Codex quota. Judge Codex output yourself before accepting it as done.
1a. Codex quota exhausted (rate-limit or usage-cap error from the CLI, after the gpt-5.5 retry): fall back to the Claude tier per rule 2 for the rest of the session and tell the user the plan cap was hit; try Codex again in later sessions.
1b. Research and current-information tasks default to Grok: any research question or current-events/real-time/X-Twitter lookup; an independent opinion from a non-OpenAI, non-Anthropic model (a tie-breaker in a multi-model consensus, or a third check when Codex and Claude already agree); or a second external executor on independent, self-contained slices.
2. Tasks kept off Codex by rule 1, or arriving after a rule 1a fallback: `opus` is the default Claude coding tier, including implementation, multi-file changes, debugging, review, and any task of uncertain complexity. Drop to `sonnet` only for clearly trivial mechanical slices (formulaic single-file edits, simple lookups, routine read-only sweeps) where opus intelligence changes nothing; when in doubt, `opus`. Never `haiku`.
3. If a task placed on `sonnet` fails concretely, rerun it on `opus` instead of iterating on `sonnet`. Never downroute below these floors to "balance" a distribution.
4. Agent type: read-only searches and codebase sweeps go to `Explore`, not `general-purpose`. Every spawn of every type (`Explore`, `Plan`, `general-purpose`, custom) pins `model` explicitly: `opus` unless the task is clearly trivial and mechanical per rule 2, then `sonnet`. Never `fable` for spawns; omitting `model` inherits the session model and counts as a violation.

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
Main session loop only; subagents skip per `<scope>`. When a requested change is complete and every gate passes (tests green, verification evidence collected, zero pending tasks), run the /commit workflow immediately; do not wait for the user to ask. Skip only when: the user said not to commit, the work was assessment or exploration with no code change, or the change is one slice of a larger plan still in flight.
</auto_commit>

<reuse_before_create>
Before writing a new component, hook, util, fetcher, schema, script, skill, or agent: search for existing equivalents. Use Glob/Grep (Explore agent for broad sweeps). Search by behavior and by synonym/abbreviation/domain wording.
- Match: extend, compose, or refactor. Never duplicate.
- Near-match: surface to the user before deciding new vs. extend.
- No match: write new.
Skip only for trivial one-liners with no plausible prior art. State the search result in one line before writing (e.g. `Searched for "FilterSheet": no match, creating new.`).
</reuse_before_create>

<code_style_no_else>
NEVER write `else` statements. Zero tolerance. Use early returns and guard clauses.
- Invert conditions to return/continue/break/throw early, then write the happy path unnested.
- Replace `if/else if/else` chains with guard clauses, lookup maps, or `switch` with early returns.
- Extract a helper function if that is what it takes to enable an early return.
- Sole exceptions: expression-level constructs with no statement alternative (ternaries, exhaustive `match`/pattern-matching arms). Nothing else qualifies; "would duplicate logic" is not an excuse, restructure instead.
- Applies to all languages, all files, all contexts (code, examples in docs, snippets in reviews).
- When editing existing code, refactor every touched `else` branch to guards, even if the change is not strictly local. Any `else` in a diff you produce is a defect.
</code_style_no_else>

<code_style_comments>
Comments are a last resort. Default to zero. Comment only the "why", never the "what", and only when the "why" cannot be expressed by renaming or restructuring.
- Hard cap: one line per comment. Never a paragraph, never a multi-line block. If the "why" will not fit in one line, the code needs restructuring, not more prose.
- Budget check: if a diff adds more than one comment per ~40 lines of code, cut comments until it does not.
- Never write comments that restate what the code does ("increment counter", "loop over users", "return the result"). If the code needs explaining, rename or restructure it instead.
- Acceptable comments (still one line each): non-obvious constraints, workaround reasons with the upstream issue, tricky invariants, domain rules the code cannot express.
- No section-banner comments, no changelog-style comments, no comments narrating an edit to the reviewer, no commented-out code, no TODO essays (a TODO is one line naming the trigger for removal).
- Doc comments on public APIs follow the project's existing convention; keep them to a one-line summary unless the convention demands parameter docs.
- When editing existing code, delete any touched comment that violates these rules instead of preserving it.
</code_style_comments>

<code_style_naming>
Name variables and functions so the code reads almost like natural language. `if (totalCardsInDeck > 0)` beats `if (tcd > 0)` or `if (count > 0)`.
- Names state what the value IS or what the function DOES, in domain words: `remainingRetryBudget`, `isDeckEmpty`, `markInvoicePaid`, not `val`, `flag2`, `handleData`.
- Booleans read as assertions: `is`/`has`/`can`/`should` prefixes (`hasUnsavedChanges`, `canRedeal`).
- Functions are verb phrases; collections are plural or `xById`/`xByName` maps; units and qualifiers go in the name when ambiguity is possible (`timeoutMs`, `priceInCents`, `maxVisibleRows`).
- No abbreviations except universally understood ones (`id`, `url`, `max`, `min`, `i`/`j` only in tight index loops). No single letters, no `tmp`/`data`/`info`/`result` when a specific name exists, no encoding the type in the name.
- Length follows scope: a name alive for 3 lines may be short; one crossing a function boundary or file must be self-explanatory without reading its definition.
- If a comment is needed to explain what a variable holds, the name is wrong: rename instead.
- The read-aloud test: if a line cannot be read aloud as a rough English sentence, rename until it can.
</code_style_naming>

<ui_button_labels>
A button's label carries NO state of any kind, ever. One control, one constant label for its whole lifecycle.
- No progress words: "Commit" stays "Commit", never "Analyzing...", "Saving...", or "Loading...".
- No counts or data: "Open listing", never "List 79 cards". Counts, totals, and dollar values go in status text or dialog copy next to the control.
- No outcome- or situation-dependent variants: never "Run again", "Publish again", "Retry", or "They are live, mark done" for a control whose stable action name is "Update prices", "Publish live", or "Mark as published". Label the action, not the situation; the surrounding copy explains the situation.
- No toggling label with panel state: never "Run"/"Hide" swaps; use a stable label plus a separate expanded/selected indicator.
- Progress indicators live OUTSIDE the button element entirely: disable the control and render a spinner or status text as a sibling next to it. A spinner inside the button is a violation even when the label text is unchanged.
- A stable label keeps layout from shifting and keeps the action findable mid-operation.
- Applies to every action control (buttons, menu items, links styled as buttons), in every framework, and in mockups and prototypes as much as shipped UI.
</ui_button_labels>

<research_not_assume>
Do not assume. Research. Do not bandaid. Fix upstream.
- Unknown API/SDK/framework: fetch official docs (or `document-specialist` agent) before writing. Training data is stale.
- Unknown project behavior: read the file, run the command, check the schema. Do not infer from filename or memory.
- Tool/lint/type/test failure: find root cause. Never silence with `@ts-ignore`, `eslint-disable`, `--no-verify`, swallowed `try/catch`, skip flags, or "temporary" workarounds. Real upstream blocker forcing a workaround: leave a one-line comment naming the issue and the removal trigger.
- Symptom in caller: fix the source, not every caller.
- Flaky test: find the race or shared state. Do not retry-loop or skip.
State the assumption in one line before acting so the user can redirect early.
</research_not_assume>

<docs_must_be_enforceable>
Gate every new doc (README section, wiki page, spec, process note, convention writeup) on one question: does this doc actually provide value? A doc whose claims cannot be enforced by a script, lint rule, CI check, or test is dead weight: it drifts from reality the day after it merges and nobody notices.
- Prefer the executable artifact over the prose: a lint rule beats a style guide page, a test beats a behavior description, a schema beats a field glossary, a check script beats a checklist.
- A doc that states a rule, convention, or process must ship with (or point to) the automation that enforces it. No automation possible: do not write the doc; say it fails this gate and propose the enforceable alternative instead.
- Applies to newly introduced docs going forward, not retroactive deletion of existing ones.
- Org-mandated docs (README standards, wiki requirements) still get written, but push their checkable claims into automation (the readme-lint pattern) rather than adding unenforced prose.
</docs_must_be_enforceable>
