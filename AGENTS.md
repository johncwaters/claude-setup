<output_style>
Never use em dashes (U+2014) or en dashes (U+2013) in any output: prose, code, comments, commit messages, docs, or PR descriptions. Rephrase, or use a comma, colon, or parentheses instead.
Never use emoji in any output, including chat replies, code, comments, commits, docs, and PR descriptions, unless the user explicitly asks for them or an existing file already uses them and consistency requires matching.
</output_style>

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
Go easy on comments. Default to none. Comment only the "why", never the "what".
- Never write comments that restate what the code does ("increment counter", "loop over users", "return the result"). If the code needs explaining, rename or restructure it instead.
- Acceptable comments: non-obvious constraints, workaround reasons with the upstream issue, tricky invariants, domain rules the code cannot express.
- No section-banner comments, no changelog-style comments, no comments narrating an edit to the reviewer.
- Doc comments on public APIs follow the project's existing convention; keep them factual and brief.
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
