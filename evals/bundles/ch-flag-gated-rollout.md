<!--
Purpose: implement PostHog feature flags in a JS/React app (posthog-js + @posthog/react) to gate a risky feature: create the flag, evaluate it client-side, handle offline/loading defaults, follow rollout best practices.
Sources: posthog.com/docs/feature-flags/installation/react.md, /docs/feature-flags/adding-feature-flag-code.md, /docs/feature-flags/creating-feature-flags.md, /docs/feature-flags/bootstrapping.md, /docs/feature-flags/canary-release.md, /docs/feature-flags.md
Fetched: 2026-07-30
-->

# PostHog feature flags: JS/React gated rollout

## Install and initialize

```bash
npm install posthog-js @posthog/react
```

```jsx
// main.tsx
import { PostHogProvider } from '@posthog/react'
const options = {
  api_host: import.meta.env.VITE_POSTHOG_HOST,
  defaults: '2026-05-30', // pins recommended SDK defaults for new projects
} as const
createRoot(document.getElementById('root')).render(
  <PostHogProvider apiKey={import.meta.env.VITE_POSTHOG_PROJECT_TOKEN} options={options}>
    <App />
  </PostHogProvider>
)
```

Access the instance with `usePostHog()` inside the provider, or `import posthog from 'posthog-js'` in non-React utility code.

## Creating the flag (PostHog UI, not code)

Flag has: a unique **key** used in code (e.g. `new-checkout`), a **type** (boolean release toggle, multivariate A/B, or remote config), optional **payload**, and **release conditions** (property/cohort/percentage targeting). Disabled flags evaluate to `undefined`/`null`. Multivariate flags return a variant key string, not a boolean. Semver targeting on `$app_version`/`$lib_version` is supported for version-gated rollouts.

## Evaluating client-side (React hooks)

```jsx
import { useFeatureFlagEnabled, useFeatureFlagPayload, useFeatureFlagVariantKey } from '@posthog/react'

function App() {
  // undefined while loading/absent unless a default is passed as 2nd arg
  const showNewCheckout = useFeatureFlagEnabled('new-checkout', false)
  const payload = useFeatureFlagPayload('new-checkout') // does NOT send $feature_flag_called; pair with the hook above

  return showNewCheckout ? <NewCheckout config={payload} /> : <OldCheckout />
}
```

Multivariate: `const variantKey = useFeatureFlagVariantKey('checkout-experiment')`, then branch on the string value (e.g. `'control'`, `'variant-a'`).

Declarative alternative: `<PostHogFeature flag='new-checkout' match={true} fallback={<OldCheckout/>}>...</PostHogFeature>` (children can be a function receiving `payload`).

Non-hook / plain JS: `posthog.getFeatureFlagResult('flag-key')` returns `{ enabled, variant, payload }` in one evaluation call, preferred over the deprecated `isFeatureEnabled`/`getFeatureFlag`/`getFeatureFlagPayload` trio for new code.

## Offline / not-yet-loaded / default behavior

On first load in a session, flags are fetched async and are `undefined` until that request resolves (subsequent pages/reloads use the cached, already-loaded value). Two ways to handle this gap:

1. **Pass a default** as the hook's second argument (shown above), simplest, avoids ternary-on-`undefined` bugs.
2. **Wait for the load event** with `onFeatureFlags`:

```javascript
posthog.onFeatureFlags(function (flags, flagVariants, { errorsLoading }) {
  // flags are guaranteed available here; errorsLoading is true on timeout/network error
  if (posthog.isFeatureEnabled('new-checkout')) { /* ... */ }
})
```

`errorsLoading` lets you distinguish "still loading" from "request failed" if you need stricter offline handling. Manually refetch with `posthog.reloadFeatureFlags()` (fire-and-forget).

### Bootstrapping (eliminate the loading gap entirely)

Precompute flag values server-side and seed them at init so there's no flicker/undefined window at all:

```javascript
posthog.init('<ph_project_token>', {
  api_host: 'https://us.i.posthog.com',
  defaults: '2026-05-30',
  bootstrap: {
    distinctID: 'distinct_id_used_on_the_server', // must match server-side evaluation ID
    isIdentifiedID: true,
    featureFlags: { 'new-checkout': true, 'checkout-variant': 'test' },
    featureFlagPayloads: { 'checkout-variant': { buttonText: 'Try new checkout' } },
  },
})
```

Gotchas: bootstrapped values are only a seed, the next full `/flags` response **replaces the entire set** (keys only present in bootstrap are dropped); a partial/errored response updates only what it computed and preserves the rest; `reset()` clears bootstrap values; bootstrapping only seeds *enabled* flags (`false`/empty values are dropped, so you can't force a flag off this way, use `overrideFeatureFlags` for persistent overrides instead of bootstrap).

## Best practices for gating a risky feature (canary rollout)

Recommended staged release using one flag's release conditions, tightening scope first then widening:

1. **Just yourself**: `email equals you@company.com`.
2. **Internal team**: `email contains @company.com`.
3. **Beta users/orgs**: early access management or a specific org/group property.
4. **Expanded beta**: percentage rollout or a broader property match; monitor insights/session replay for the cohort.
5. **Full release**: 100%, confirm metrics, then delete the flag.

Filter insights/dashboards and session recordings by the feature flag key to compare cohorts during rollout. Combine with funnels broken down by the flag to catch conversion regressions early, and jump from a funnel drop-off directly to the affected users' session replays.

**Stop evaluation at first matching condition set** (opt-in, off by default): normally all condition sets are evaluated and any pass wins, so a user excluded by one condition's rollout percent can still fall through and match a broader catch-all condition below it. Enabling this makes conditions evaluate in order and stop at the first match, useful when you need deterministic behavior for a risky flag with a narrow targeted condition plus a broad fallback.

## Evaluating flags on properties not yet ingested

If the release condition depends on a property that hasn't reached PostHog yet (or was set incorrectly earlier), set it directly for flag evaluation instead of waiting on ingestion:

```javascript
posthog.setPersonPropertiesForFlags({ betaTester: true, plan: 'pro' })
```

Setting these properties applies for the rest of the session, successive calls are additive (all properties combined), and by default triggers an immediate flag reload so the new value takes effect right away; pass `false` as the second argument to suppress the auto-reload if you're about to set several properties in a row and want a single reload at the end. Reset with `posthog.resetPersonPropertiesForFlags()`. The same pattern exists for group targeting: `posthog.setGroupPropertiesForFlags({'company': {plan: 'enterprise'}})` / `posthog.resetGroupPropertiesForFlags('company')` (or with no argument, resets all groups); group name isn't needed since properties attach to the group set via `posthog.group()`.

Automatic overrides you get for free: calling `posthog.identify()` with person properties, or `posthog.group()`, automatically feeds those properties into subsequent flag evaluation calls. GeoIP-derived properties (`$geoip_city_name` and related) are also auto-attached from the request IP by default.

## Scoping which flags load

`flag_keys` at init restricts evaluation and the `/flags` response to only the listed keys (plus any flags they depend on), reducing payload size and evaluation cost when a page only needs one or two flags:

```javascript
posthog.init('<ph_project_token>', {
  api_host: 'https://us.i.posthog.com',
  defaults: '2026-05-30',
  flag_keys: ['new-checkout'],
})
```

Leave `flag_keys` unset to evaluate every eligible flag for the user (the default, and what most apps want unless payload size is a measured problem).
