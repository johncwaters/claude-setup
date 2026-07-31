<!--
Purpose: tag events/exceptions with app version via posthog-js super properties (register), and how that version property interacts with error tracking / filtering by release.
Sources: posthog.com/docs/libraries/js/usage.md, /docs/libraries/node.md, /docs/error-tracking/releases.md, /docs/feature-flags/creating-feature-flags.md, /docs/error-tracking/capture.md
Fetched: 2026-07-30
-->

# Tagging events with app version via super properties (posthog-js)

## register() is the mechanism

Super properties are attached to every event the client captures afterward, for the lifetime of that client instance:

```javascript
posthog.register({
  app_version: '1.2.0',
})
// every subsequent capture(), including auto-captured events and captureException(), now includes app_version
```

- Calling `register` again with the same key **overwrites** the value for all following events (use this on every app version bump/deploy).
- If an individual event's own `properties` sets the same key, **the event-level property wins** over the super property for that one event.
- `register_once({...})` sets a super property only if it isn't already set, not the right choice for a version tag you want to update on every release; use plain `register`.
- Super properties persist via a browser cookie (web SDK). `posthog.unregister('app_version')` removes the property and its cookie.
- posthog-node has the equivalent `client.register({...})` / `client.unregister('key')`, requiring `posthog-node >= 5.25.0`; the Node docs use `app_version` as the canonical example key:

```javascript
client.register({ app_version: '1.2.0', environment: 'production' })
client.capture({ distinctId: 'distinct_id', event: 'page_viewed' }) // includes app_version + environment
```

Node's super properties are global to the client instance, for a value that should apply only to one request/transaction rather than the whole process lifetime, the Node docs point to "contexts" instead of `register`:

```javascript
posthog.withContext(
  { distinctId: 'user-123', properties: { transactionId: 'abc123' } },
  () => {
    posthog.capture({ event: 'order_processed' }) // captured with the distinctId/properties above
  }
)
```

Contexts persist across function calls made inside the callback (a function called from within `withContext` and capturing an event still sees the context properties), requires `posthog-node >= 5.17.0`. Use `register`/`app_version` for "true for the whole process," use `withContext` for "true for this one request/transaction only."

The web `posthog-js` init snippet also exposes `register_for_session` and `unregister_for_session` alongside `register`/`unregister` (visible in the SDK's method list), a session-scoped variant; the fetched docs don't elaborate on its exact semantics beyond the name, so don't assume its persistence/precedence rules match plain `register` without checking further.

## Where to call register() in a web app

Call it once, as early as possible after `posthog.init()` and after you know the running app's version (e.g. injected at build time as an env var), before any other event capture happens, so no event is emitted without the tag:

```javascript
posthog.init('<ph_project_token>', { api_host: '...', defaults: '2026-05-30' })
posthog.register({ app_version: process.env.APP_VERSION })
```

## Interaction with error tracking

Exceptions captured via `posthog.captureException(error, properties)` are events like any other (`$exception`), so a super property registered beforehand is included automatically, no separate version-tagging step is needed for exceptions specifically. Event-level `properties` passed to `captureException` still take precedence over the registered super property if both set the same key.

**Do not confuse this with "Releases" in error tracking**, that is a different, unrelated PostHog feature: release records there are created by uploading sourcemaps via `posthog-cli sourcemap upload` (or a framework integration), which attaches release/Git metadata to *stack traces* for source linking, not a way to tag arbitrary events with a version property. The sourcemap-based release version and the `register`-based `app_version` super property are independent mechanisms that happen to describe the same concept; nothing in the fetched docs ties them together programmatically.

## Filtering by release / version afterward

Once `app_version` (or any custom key) is a property on events, it can be:
- Filtered directly in insights/dashboards as an event property (`properties.app_version`).
- Used as a **feature flag release condition** via semver operators: PostHog recognizes `$app_version`/`$lib_version`-style string properties for semver comparisons (`>=`, `<`, etc.) in flag targeting, labeled `(semver)` in the operator dropdown, useful for gating a fix to only versions below a threshold. Two-component versions like `3.10` are normalized to `3.10.0` for this matching; pre-release/build suffixes are preserved in the value.

## Doc gap note

The docs never show `$app_version` as a literal reserved/auto-captured property name for web `posthog-js` (only mobile SDKs are said to auto-include `$app_version`); for a JS/React web app, `app_version` (no `$` prefix) is a **custom** property you must `register` yourself, matching the pattern the posthog-node docs use verbatim. No fetched page shows a worked example combining `register()` output with a HogQL query, see `kp-release-impact` for the query side.
