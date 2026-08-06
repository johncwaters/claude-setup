<!--
Purpose: capture exceptions and events from a Node/Electron main process (no browser renderer, posthog-js does not apply) using posthog-node: setup, manual/automatic exception capture, batching and shutdown flushing.
Sources: posthog.com/docs/error-tracking/installation/node.md, /docs/error-tracking/capture.md, /docs/libraries/node.md, /docs/error-tracking/installation/manual.md
Fetched: 2026-07-30
-->

# PostHog error tracking in a Node.js main process (no browser renderer)

## Why posthog-node, not posthog-js

posthog-js instruments a browser/renderer context (`window.onerror`, DOM). An Electron **main process** is a plain Node.js process, so use `posthog-node` there directly, the same package used for any server-side Node service.

## Setup

```bash
npm install posthog-node
```

```javascript
import { PostHog } from 'posthog-node'
const client = new PostHog('<ph_project_token>', {
  host: 'https://us.i.posthog.com',
  enableExceptionAutocapture: true, // auto-captures uncaught exceptions and unhandled rejections
})
```

`isServer` option (default `true`) controls the `$is_server` event property; set it to `false` if you want this Node process attributed like a client/desktop app for device/OS purposes rather than a server.

Note: exception autocapture needs filesystem access to process stack traces, this works fine in a normal Electron main process, but would need workaround in restricted runtimes (e.g. Cloudflare Workers) that don't expose Node fs APIs.

Express-specific caveat (not applicable to a bare main process, but relevant if main process runs an embedded HTTP server): Express swallows uncaught exceptions internally, so autocapture needs `setupExpressErrorHandler(posthog, app)` explicitly, plain Node code does not need this.

## Manual exception capture

```javascript
posthog.captureException(e, 'user_distinct_id', {
  custom_property: 'custom_value',
  custom_list: ['custom_value_1', 'custom_value_2'],
})
```

Always use `captureException`, never hand-build a `$exception` event via `capture()`, it owns stack trace formatting and source map integration.

Identifying users is required for backend events: pass the same `distinct_id` the renderer/frontend uses via `identify()`, or backend-captured exceptions are orphaned and cannot be linked to frontend events, session replays, or other error tracking for the same user.

Breadcrumb-style context before a crash: `posthog.addExceptionStep('checkout_started', { cart_total: 12900 })`, buffered in memory, attached to the next captured exception as `$exception_steps`, not sent as a standalone event. Available in posthog-node.

## Regular event capture

```javascript
client.capture({
  distinctId: 'distinct_id_of_the_user',
  event: 'app_launched',
  properties: { property1: 'value' },
})
```

## Batching and shutdown flushing (the main-process-specific part)

The Node client queues events in memory and flushes them in batches, controlled by:

| Option | Default | Meaning |
| --- | --- | --- |
| `flushAt` | 20 | flush the queue after this many `capture` calls |
| `flushInterval` | 10000 (ms) | flush the queue after this much time |
| `requestTimeout` | 10000 (ms) | timeout for any HTTP call to PostHog |

An Electron main process is effectively a short-lived-per-launch process, similar to serverless: events queued but not yet flushed at process exit are lost. Treat it the same way the docs treat AWS Lambda/serverless:

```javascript
// On app quit / before-quit:
await client.shutdown() // stops pending pollers, flushes any remaining queued events in one batched API call
```

For crash-adjacent or exit-critical events, prefer immediate delivery over waiting on the batch:

- Set `flushAt: 1, flushInterval: 0` at client construction to flush on every single capture instead of batching, if you need every event delivered promptly rather than optimizing for fewer HTTP calls.
- Use `client.captureImmediate(...)` (documented for serverless) instead of `client.capture(...)` when a specific call must complete its HTTP request before the process is allowed to continue/exit.
- Always still call `await client.shutdown()` at process exit even with immediate capture, to guarantee anything still queued is sent.

Error handling: the SDK swallows background/network errors by design so they don't crash your app; hook in explicitly if you want visibility:

```javascript
client.on('error', (err) => console.error('PostHog had an error!', err))
```

Debug mode for troubleshooting missing events: `client.debug()` enables verbose internal logging.

## Exception event shape

An exception is a normal PostHog event under the hood, captured with automatically-attached properties used to group it into an issue:

| Property | Type | Meaning |
| --- | --- | --- |
| `$exception_list` | List | one entry per exception in a chain, each with `type`, `value` (message), `stacktrace`, `mechanism` (handled/synthetic) |
| `$exception_fingerprint` | String | fingerprint PostHog uses to group occurrences into the same issue |
| `$exception_level` | String | severity |
| `$exception_steps` | List | breadcrumbs recorded via `addExceptionStep` before the exception, each with `$message`, `$timestamp`, and any custom properties |

Since it's a normal event, anything registered as a super property (see `ch-release-tagging`) or passed as `properties` to `captureException` rides along on it and is filterable/breakable-down in insights the same as any other event property.

## Source maps

If the main process bundle is minified/compiled, stack traces are unreadable without uploading source maps for that build (`posthog-cli sourcemap upload`, documented separately per-language/framework); this is a one-time-per-release setup step, not part of the runtime `captureException` call shown above.

## Doc gap note

The docs describe serverless/Lambda short-lived-process handling in detail but never mention Electron or a "main process" by name, the batching/shutdown guidance above is inferred by treating an Electron main process as an instance of the documented "short-lived process" pattern, not from an Electron-specific doc page (none exists in the fetched docs).
