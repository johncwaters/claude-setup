# Reference for ch-flag-gated-rollout

Prospective task: this is pinned to card-harbor `develop` at `08bfc39aa61af7eb96b112d9d01a725771a22af3`,
authored before the real implementation lands. There is no verified landed outcome yet;
this records the acceptance surface `checks.py` grades against, and gets replaced with
the actual landed diff summary once I do this integration for real.

## Why this task is harder than "call isFeatureEnabled somewhere"

The unattended delist step is entirely main-process code
(`src/main/services/autoDelist.service.ts`, planned by
`src/main/services/autoSyncCycle.ts`'s `isStepRunnable`/`decideAutoSyncCycle`, run by
`src/main/services/autoSyncScheduler.ts`). PostHog feature flags in this app are only
evaluable through the renderer's posthog-js/@posthog/react client
(`src/renderer/src/main.tsx`'s `PostHogProvider`); there is no PostHog client in the main
process at all (see [[ch-main-process-capture]], same underlying gap). A correct
solution has to bridge a flag value from the renderer's evaluation into whatever the
main-process scheduler reads before it decides to run `tcgplayer_delist`, most likely by
persisting the flag's resolved value into the existing settings store
(`settings.service.ts`) the same way `delistEnabled` already works, refreshed whenever
the renderer re-evaluates flags, and defaulting to off until a renderer has evaluated at
least once.

## Acceptance surface `checks.py` actually grades

1. **wrong-api**: no import from `@posthog/react` or call on a `posthog` client using a
   name absent from the SDK actually installed in `node_modules` at check time
   (`posthog-js@1.405.3`, `@posthog/react@1.10.3` as of capture; re-scraped live, not
   hardcoded, so a version bump doesn't stale this out).
2. **build-fail**: `npm run typecheck` must exit 0 in the worktree (node_modules linked
   in from the pinned repo checkout, not reinstalled).
3. **missing-events** (static): at least one of `autoSyncCycle.ts`,
   `autoDelist.service.ts`, `autoSyncScheduler.ts`, `settings.service.ts`, or a new file
   under `src/main/services/` whose path mentions "delist", must be touched, AND its
   added lines must reference a real flag-evaluation identifier
   (`isFeatureEnabled`, `getFeatureFlag`, `useFeatureFlagEnabled`, etc.).
4. **missing-events** (live, skippable): with
   `EVALS_POSTHOG_PROJECT_KEY`/`EVALS_POSTHOG_SCRATCH_PROJECT_ID`/`EVALS_POSTHOG_PERSONAL_KEY`
   set, polls the scratch project for the `automation_started` event as a coarse signal
   the instrumented path still runs end to end. **No live credentials exist in this
   environment**, so this stage has never actually executed; it is exercised only via
   `poll_result is None` (credential-absent) in every run so far.

## Known blind spots (documented, not silently ignored)

- The static check cannot verify the "default OFF while offline/bootstrapping" and
  "respect existing consent gating" requirements from the prompt; those are read from
  the prompt text at review time, not graded programmatically. A future revision could
  grep for a `?? false` / `=== true` idiom near the flag call, but that's brittle enough
  across valid implementations that it's left as a manual review note for now rather
  than a false-failure risk.
- Grading is heuristic line/regex matching over `git diff`, not an AST walk; a
  sufficiently unusual but correct implementation could still slip past the "missing"
  bucket incorrectly, or vice versa. Flagged here rather than silently assumed exact.
