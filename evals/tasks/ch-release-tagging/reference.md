# Reference for ch-release-tagging

Prospective task: pinned to card-harbor `develop` at `08bfc39aa61af7eb96b112d9d01a725771a22af3`,
authored before the real implementation lands. No verified landed outcome yet; this
records the acceptance surface `checks.py` grades against.

## The actual gap

`src/renderer/src/main.tsx` configures `PostHogProvider` with `loaded: (posthog) =>
posthog.capture('app_launched')` but never calls `posthog.register(...)`. No event or
autocaptured exception carries `$app_version`/`$app_build` today. Card Harbor's real
version lives in `package.json` (currently `0.9.7`) and is only reliably readable at
runtime from the main process (Electron's `app.getVersion()`); the renderer has no
direct access to it, so a correct solution has to bridge that value across the existing
preload/IPC boundary (`src/preload/index.ts`, `src/shared/ipc/*`) rather than importing
`package.json` into renderer code or hardcoding the version string.

## Acceptance surface `checks.py` actually grades

1. **wrong-api**: any `posthog.<method>(...)` call in the diff whose method name isn't
   present in the installed `posthog-js` client (scraped live from `node_modules`).
2. **build-fail**: `npm run typecheck` must exit 0.
3. **missing-events** (static, two-part):
   - a `register(...)` call whose arguments reference `$app_version`/`app_version` or
     `$app_build`/`app_build` must appear in the diff;
   - across the full post-edit contents of every changed file, some `getVersion()`-style
     lookup must exist, and no line that also mentions an app-version key may contain a
     bare hardcoded semver literal (`"X.Y.Z"` or `"X.Y.Z+N"`), satisfying the prompt's
     explicit "not a string typed in by hand" requirement.
4. **missing-events** (live, skippable): polls the scratch project for an event carrying
   a non-null `$app_version`. **No live credentials in this environment**; every run so
   far has only exercised the credential-absent branch.

## Known blind spots

- "Shouldn't change anything for a build with no PostHog token configured" (the prompt's
  other constraint) is not checked programmatically; `main.tsx`'s existing
  `if (!posthogToken) return <App />` early return already structurally protects this as
  long as the new registration call stays inside the token-gated branch, which is a
  manual review item rather than an automated one.
- The hardcoded-literal scan is a same-line heuristic; a version literal assigned on one
  line and referenced by variable on the `register(...)` line would not be caught. This
  is a known false-negative risk documented here rather than silently assumed exact.
