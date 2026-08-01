# Context Regimes and Coding-Agent Performance on Real PostHog Tasks

An eval harness that hands real product tasks to a headless coding agent under four
context conditions, on real PostHog data, and measures what changes.

## Abstract

I built a harness that runs a headless Claude Code agent (`claude -p`, model
`claude-sonnet-5`) against six real tasks drawn from two of my own shipping products,
under four context regimes: no context beyond the prompt, PostHog's public `llms.txt`
plus scoped web fetch, a live read-only PostHog MCP connection, and hand-authored
context bundles sourced from public PostHog docs. This writeup reports the first fully
valid batch: 48 trials (6 tasks x 4 regimes x 2 trials), zero infrastructure failures,
16 passes overall. Live data access through MCP was the only regime that ever solved
the two winnable analytics tasks (4/4 across both), and it is also the regime that
produced the sharpest documentation gap this eval surfaced: both MCP trials on a
funnel-conversion task independently computed the same wrong number by counting users
who did two events in any order instead of in the required sequence, a per-user
"did A then B" HogQL pattern that PostHog's docs do not show worked out anywhere I
could find. Hand-built bundles carried the hardest coding task and produced the only
pass on it in any regime. `llms-txt`, PostHog's own agent-facing doc index, underperformed
even the no-context baseline on raw pass count while costing roughly 2.8x more per run
than `none`. All of this is n=2 per cell: it powers floor-finding and directional sweeps, not
statistically significant regime comparisons, and a higher-n batch is running as this is
written.

## Why this eval

PostHog's Context Engineer role is about making the product legible to AI agents, not
just to humans reading docs. The credible way to test that legibility is to stop
asking "is the documentation good" and start asking "does an agent that only has
this documentation actually get the task right," scored by a program, not a read-through.
This harness does that: every task is something I actually needed done on my own
products (card-harbor, an Electron/TypeScript desktop app, and keeplings, a Flutter app
with PostHog live in production), every pass/fail is decided by a script comparing
against a pinned reference, and no LLM judge sits anywhere in the scoring path.

## Method

**Tasks.** Six tasks across two sources:

- Three `ch-` tasks are prospective coding tasks against card-harbor, pinned to commit
  `08bfc39aa61af7eb96b112d9d01a725771a22af3`, authored before the real feature landed:
  `ch-release-tagging` (tag events with app version/build as PostHog super properties,
  sourced from the packaged app rather than a hand-typed string), `ch-main-process-capture`
  (capture Electron main-process crashes to PostHog directly, since only the renderer
  process has a PostHog client today), and `ch-flag-gated-rollout` (gate an existing
  unattended automation step behind a PostHog feature flag, defaulting safely to off).
  Each is graded by `npm run typecheck` passing, a static diff scan for the right
  PostHog API calls in the right files, and a hallucinated-SDK-usage scan against the
  actually-installed `posthog-js`/`@posthog/react` versions. Live event-arrival
  validation for these three was originally part of scoring but could never pass
  during a trial (no task asks the agent to run the app, and the harness never executes
  it after scoring starts); it was removed from automated grading on 2026-07-31 and now
  happens manually once each feature actually lands.
- Three `kp-` tasks are retrospective analytics questions against keeplings production
  data, each with a HogQL reference query and a verified numeric answer: `kp-release-impact`
  (event volume and DAU, 7 days before vs. after release 1.0.0+16), `kp-reminder-funnel`
  (per-user conversion from `reminder_created` to a subsequent `habit_confirmed`), and
  `kp-store-engagement` (fraction of store visitors who also earned amber, and their
  median amber-earned count). The agent writes its answer plus the HogQL it ran to
  `answer.json`; `checks.py` compares against the reference within a stated tolerance.

**Regimes.** Four conditions, identical prompt otherwise:

| Regime | What the agent gets |
|---|---|
| `none` | Task prompt only. `WebSearch` and `WebFetch` both off. |
| `llms-txt` | A frozen snapshot of `posthog.com/llms.txt` (a ~330 KB link index of doc URLs; `llms-full.txt` 404s) injected into context, plus `WebFetch` scoped to `posthog.com`, since following the index's links is its designed use. |
| `mcp` | The live PostHog MCP server (`https://mcp.posthog.com/mcp`), bearer-authenticated with a read-only, project-pinned personal API key. No doc injection. |
| `bundle` | A hand-authored, task-scoped context bundle built only from public PostHog docs, content-hashed and frozen before its first scored run. |

`WebSearch`, `Task`, and `Agent` are disallowed in every regime so every run stays
single-agent and never touches the open web beyond the one scoped exception above. One
constant across all four regimes on `ch-` tasks: the worktree is a real card-harbor
checkout, so it carries the repo's own `CLAUDE.md`/`AGENTS.md` into context even in
`none`. That leakage is identical across regimes, so regime comparisons on `ch-` tasks
still hold, but `none` is a repo-context baseline, not a zero-context one, for those
three tasks.

**Scoring.** No LLM judge anywhere in the pass/fail path. `ch-` tasks are graded against
a static acceptance surface (typecheck, diff-scan for the right call, hallucinated-API
scan); `kp-` tasks are graded against a HogQL reference query run against real keeplings
data, with numeric tolerances stated per task. A `check-infra` reason code is reserved
for harness-side faults (timeouts, API errors) and is excluded from pass rates; this
batch recorded zero.

**n.** Two trials per `(task, regime)` cell, 48 trials total. This is enough to find
floors (a regime that never solves a task class) and run directional sweeps across all
four regimes at once; it is not enough to call a mid-range regime difference
statistically significant. A two-proportion test at alpha 0.05 and power 0.90 needs
roughly 100 trials per cell to distinguish a 90% pass rate from an 80% one, and
considerably more when both rates sit near 50%. A batch raising n to 4 is running now;
every table below is structured so re-running at higher n only changes cell values, not
shape.

## Results

This is the first batch with zero infrastructure failures: 48/48 trials scored, none
excluded, 196.9 minutes of total wall time, $85.92 in token cost at API-equivalent
pricing (these runs actually rode a Claude subscription, not metered API billing; cost
is reported for comparability, not as money spent). Two prior batches are excluded from
these findings: an earlier batch established baseline floors before regimes were fully
wired (`ch-` tasks exhausted the turn cap, and a `bundle` trial fabricated plausible-looking
`kp-` numbers that the reference check caught); a second batch ran with headless MCP not
actually connecting (a configuration gap since fixed) and, separately, let the agent
subprocess inherit live credential environment variables, which let one `bundle` trial
answer a `kp-` task with real production data it should never have had. Both gaps
(MCP wiring, credential isolation) were fixed before this batch; see "Methods hardening"
below.

**Pass/fail grid** (P = pass, f = fail, two trials per cell, in trial order):

| Task | none | llms-txt | mcp | bundle |
|---|---|---|---|---|
| ch-release-tagging | PP | PP | PP | PP |
| ch-main-process-capture | fP | ff | ff | PP |
| ch-flag-gated-rollout | ff | ff | ff | fP |
| kp-release-impact | ff | ff | PP | ff |
| kp-reminder-funnel | ff | ff | ff | ff |
| kp-store-engagement | ff | ff | PP | ff |
| **Passes / 12** | **3** | **2** | **6** | **5** |

**Cost per success by regime** (total regime cost divided by passes in that regime; a
regime with zero passes has no defined cost-per-success):

| Regime | Passes | Total cost | Mean cost/run | Cost per success |
|---|---|---|---|---|
| none | 3/12 | $14.42 | $1.20 | $4.81 |
| llms-txt | 2/12 | $40.93 | $3.41 | $20.46 |
| mcp | 6/12 | $15.53 | $1.29 | $2.59 |
| bundle | 5/12 | $15.04 | $1.25 | $3.01 |

`ch-` tasks (Electron/TypeScript) averaged 51.25 turns per run across all regimes
(23 of 24 runs finished at or above the 50-turn cap; the CLI's reported turn count runs
one past the configured cap), and accounted for $66.93 of the $85.92 total cost across 170 of
196.9 wall-minutes; `kp-` tasks (HogQL analysis) averaged 12.5 turns and resolved in
26.8 minutes total. The coding tasks are the expensive half of this suite regardless of
context regime.

## Findings

**1. Live data access is necessary and sufficient for the two winnable analytics tasks;
nothing else even gets close.** `kp-release-impact` and `kp-store-engagement` both went
2/2 under `mcp` and 0/2 under every other regime, no exceptions. Ground truth for
`kp-release-impact`: 809 events / 8.71 average DAU in the week before release 1.0.0+16,
520 events / 6.86 average DAU the week after. Ground truth for `kp-store-engagement`: of
users who opened the store in the two-week window, 100% (6 of 6) also earned amber, with
a median of 10.5 `amber_earned` events among them. Without a live connection to query
against, an agent has no way to produce these numbers regardless of how much PostHog
documentation it has memorized or been handed; all 12 non-`mcp` trials on these two tasks
failed at the `answer.json` shape gate (missing, invalid, or schema-mismatched), rather
than producing a well-formed wrong number.

**2. The sharpest finding in this batch is an MCP failure, not an MCP success.** On
`kp-reminder-funnel`, both `mcp` trials independently computed a conversion rate of 0.5,
against a true rate of 0.1667 (1 of 6 users). Both landed on the identical wrong number
by the identical wrong method: counting users who fired both `reminder_created` and
`habit_confirmed` anywhere in the window (3 of 6), instead of users whose first
`habit_confirmed` came at or after their first `reminder_created` (1 of 6) as the prompt
explicitly asked ("do this per-user, not per-event... ask whether they have a
`habit_confirmed` at or after that first creation"). This is a per-user event-sequencing
error: "did A and B" instead of "did A then B." I could not find a worked "sequential
funnel with correct event ordering" HogQL example on PostHog's public docs; two
independent trials converging on the same shortcut is a concrete signal that the
docs (or the MCP tool's own guidance) don't make the correct pattern obvious. This is
the doc gap most worth PostHog's attention: it reproduces reliably, and it is exactly
the kind of thing better agent-facing documentation would fix rather than a smarter
model.

**3. Hand-built bundles carried the hardest coding task, and produced the only pass on
it in any regime.** `ch-flag-gated-rollout` (bridge a PostHog feature flag, evaluated
only in the renderer, into a decision made entirely in Electron's main process, safely
defaulting to off) failed in all four regimes' first trial and in every `none`/`llms-txt`/`mcp`
trial; the single pass in the whole task came from `bundle`'s second trial. `bundle`
also went 2/2 on `ch-main-process-capture` (route Electron main-process crashes to
PostHog directly, again a main-process/renderer boundary problem), where every other
regime managed at most one pass. Public PostHog docs don't cover Electron main-process
integration patterns at all; the bundles for these two tasks had to synthesize a
solution by composing renderer-side flag/error APIs with an Electron
preload/IPC bridge, which is exactly the kind of task-specific composition that curated
context engineering, not a generic doc index, is suited to provide.

**4. Post-isolation, agents without data access decline `kp-` tasks honestly instead of
guessing.** Every `bundle` trial on all three `kp-` tasks in this batch either failed to
produce a valid `answer.json` or produced one flagged `wrong-answer`. Two earlier
failure modes are both gone. In the first batch, one `bundle` trial confidently
fabricated plausible-looking `kp-` numbers, and only the reference check against live
data caught it; nothing in the answer itself looked wrong. In the second batch, one
`bundle` trial passed a `kp-` task legitimately-looking-but-illegitimately: the agent
subprocess had inherited live credential environment variables and quietly queried real
production data from a regime that promises no data access. Both observations point the
same direction: context that describes the data without connecting to it is not neutral,
it is a fabrication risk, and a live reference check is the only guard in this harness
that catches either failure.

**5. `llms-txt`, PostHog's own agent-facing doc index, underperformed the no-context
baseline on raw passes while costing far more in tokens.** `llms-txt` passed 2/12
against `none`'s 3/12, and its mean cost per run ($3.41) was roughly 2.8x `none`'s
($1.20) and its cost per success ($20.46) was more than 4x any other regime's. The
snapshot is a ~330 KB flat link index of doc URLs, not indexed or summarized content;
an agent has to spend turns and tokens crawling it via `WebFetch` before it can act, and
in this batch that crawling overhead did not translate into task-relevant depth. This
reads as a design problem with the artifact, not with the model: a link index optimized
for a human skimming titles is a worse fit for an agent than either no context at all
or a small task-scoped bundle.

## Methods hardening

The parts of this harness that took the most iteration to get right, and why:

| Problem | Fix |
|---|---|
| Multi-turn runs re-read cached context every turn, so gross token counts inflate 20-50x over real spend (measured in this batch: 30.6x gross-to-noncached overall) | Budget guard caps *noncached* tokens per run (input + cache-creation + output), excluding cache reads, so the cap tracks real spend instead of turn count |
| Headless `claude -p` would silently skip connecting to the PostHog MCP server | Server entry must declare `"type": "http"`, and must be named something other than `posthog` (Claude Code caches a needs-auth verdict per server name, so colliding with a developer's own OAuth-based `posthog` server skips auth entirely); every run also passes `--strict-mcp-config` so no ambient user-scoped MCP server leaks into any regime |
| A `none`/`llms-txt`/`bundle` run must never be able to query live PostHog with harness credentials | All `EVALS_POSTHOG_*` environment variables are stripped from the agent subprocess's environment in every regime; the `mcp` regime's token instead travels through a generated config file written outside the workspace and deleted in the cell's teardown, never as an inherited env var |
| The `mcp` regime must not be able to touch keeplings production data destructively, or leak into the wrong project | Personal API key is scoped read-only; every task pins the MCP session to one project via header (`kp-` tasks pin to keeplings production for read-only queries, `ch-` tasks pin to a scratch project); a missing token or project-id env var fails the cell outright as `check-infra` rather than running unauthenticated or unpinned |

## Doc-gap recommendations for PostHog

1. **A worked "did A then B" sequential-funnel HogQL recipe.** Finding 2 above is the
   concrete case: counting users who did two events in the same window is a different
   query than counting users who did them in a required order, and the difference is
   easy to get wrong even with live schema access. A canonical example (ideally
   reachable from the MCP server's own tool descriptions, not just static docs) would
   likely have prevented both failing trials from converging on the same shortcut.
2. **Electron / desktop main-process integration guidance.** Card-harbor's tasks exposed
   a real gap: PostHog's JS SDK docs are written renderer/browser-first, and nothing
   public covers bridging flag evaluation or error capture across an Electron
   preload/IPC boundary into a Node-side main process. This is a broader gap than
   just card-harbor; any Electron app using PostHog hits the same renderer-only
   assumption.
3. **What `llms.txt` should become.** As a flat link index, `llms-txt` cost more tokens
   per run than any other regime and produced fewer passes than giving an agent nothing
   at all. A version with even lightweight per-page summaries, or task-class-scoped
   sub-indexes, would let an agent judge relevance before spending a `WebFetch` turn on
   each candidate page, which is the actual bottleneck this batch's cost data points at.

## Limitations

- **n=2 per cell.** This batch powers floor-finding (does a regime ever solve a task
  class) and directional sweeps across all four regimes; it does not power a
  statistically significant claim about a mid-range regime difference. A batch raising
  n to 4 is running as this is written, and the numbers above will be refreshed; the
  tables are structured so a higher-n rerun only changes cell values.
- **Single model.** Every trial ran `claude-sonnet-5`; nothing here is a claim about
  context regimes generalizing across models.
- **Six tasks.** Three coding tasks on one app, three analytics tasks on another. The
  suite is real work, not a stratified sample of PostHog use cases.
- **Static acceptance surface on `ch-` tasks.** Live event-arrival validation for the
  three coding tasks is a manual step once each feature actually lands, not part of
  automated trial scoring (see "Method" above for why the original live-poll checks
  were removed).
- **Cost is API-equivalent, not actual spend.** These runs used a Claude subscription;
  `cost_usd` figures are reported using API-equivalent per-token pricing for
  comparability across regimes, not as money that changed hands.

## Reproduction

Full harness: `evals/README.md`. Raw data behind every number in this writeup:
`evals/results/journal.jsonl` (append-only, one row per trial, trials 1-2 only used
here) and `evals/results/summary.json` (per-cell roll-up). Task definitions, prompts,
and references: `evals/tasks/*/`. Full design rationale and risk analysis:
`docs/evals-plan.html`.
