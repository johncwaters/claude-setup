# Reference for ch-main-process-capture

Prospective task: pinned to card-harbor `develop` at `08bfc39aa61af7eb96b112d9d01a725771a22af3`,
authored before the real implementation lands. No verified landed outcome yet; this
records the acceptance surface `checks.py` grades against.

## The actual gap

`src/main/crashHandlers.ts`'s `registerCrashHandlers` catches `uncaughtException` and
`unhandledRejection`, writes `crash-log.txt`, and calls `broadcastMainProcessError`,
which loops `BrowserWindow.getAllWindows()` and IPC-sends to each. That loop is the only
path anything main-process gets into PostHog through today (the renderer relays it
onward once received). Zero windows means zero relays means zero PostHog capture, and
that's true both at very early startup and after every window has closed while the
process itself is still alive (e.g. mid-background-job).

Card Harbor has no PostHog Node SDK dependency (`posthog-node` is absent from
`package.json`); the renderer's `posthog-js`/`@posthog/react` are explicitly the wrong
tool here since they're browser-oriented and the prompt rules out pulling them into main.
A correct solution adds its own capture path in main (a small `posthog-node` client, or a
direct HTTP POST to PostHog's capture endpoint via Node's `fetch`/`https`), reachable
directly from the two `process.on(...)` handlers, independent of `broadcastMainProcessError`.

## Acceptance surface `checks.py` actually grades

1. **wrong-api**: any `import ... from 'posthog-js'` or `'@posthog/react'` under
   `src/main/**` fails outright, regardless of what else changed.
2. **build-fail**: `npm run typecheck` must exit 0.
3. **missing-events** (static): a PostHog-network reference (`posthog-node`,
   `posthog.com`, `/i/v0/e/`, `/capture/`, `/batch/`, or `new PostHog(`) must appear in a
   changed `src/main/**` file, and if it's in `crashHandlers.ts` specifically, it must sit
   outside `broadcastMainProcessError`'s function body (a line-range brace-depth check,
   not a full parse) so it isn't just the existing per-window relay wearing a new name.
4. **missing-events** (live, skippable): polls the scratch project for a `$exception`
   event. **No live credentials in this environment**; every run so far has only
   exercised the credential-absent branch.

## Known blind spots

- Whether the new path preserves `main.tsx`'s path-scrubbing discipline is not checked
  programmatically; a main-process capture path has no access to that renderer-side
  `beforeSend`, so a correct solution needs its own equivalent scrub, and this is a
  manual review item until a landed reference makes it worth automating.
- The brace-depth span check on `broadcastMainProcessError` assumes the file keeps
  roughly its current shape; a heavy rewrite of `crashHandlers.ts` could confuse it in
  either direction.
