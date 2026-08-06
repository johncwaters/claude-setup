Card Harbor's auto-sync cycle has an unattended TCGplayer delist step (it lives in the
main process: `src/main/services/autoDelist.service.ts` does the actual work, and
`src/main/services/autoSyncCycle.ts` decides whether that step runs at all this cycle).
Today it's gated only by a local settings toggle the seller flips in the app.

Before I turn this on broadly I want to roll it out to a subset of users first and dial
it up gradually, so it needs to sit behind a PostHog feature flag I can control from the
PostHog dashboard, on top of the existing local toggle (not replacing it).

Requirements:
- If PostHog hasn't loaded a flag value yet, or the app is offline, the flag must
  resolve to OFF. This step edits a live storefront with nobody watching, so a slow or
  failed flag fetch must never be read as "enabled."
- Respect whatever consent/enablement gating already exists for the PostHog client in
  this app; don't bypass it to get the flag to evaluate.
- Don't touch any of the existing delist safety checks (capture freshness, re-send
  guards, the unit bound). This is one more gate stacked on top, not a rewrite.

Wire it up, keep `npm run typecheck` clean, and leave things in a state where I could
ship this today with the flag off everywhere and nothing would change for existing
users.
