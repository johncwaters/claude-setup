Card Harbor only gets errors into PostHog from the renderer process today. Main-process
crashes (see `src/main/crashHandlers.ts`) get written to `crash-log.txt` and broadcast
over IPC to any open renderer window, and it's that renderer relay that's the only thing
putting them in PostHog. If the main process throws before any renderer window exists,
or after every window has closed, that crash never reaches PostHog at all.

Close that gap: get `uncaughtException` and `unhandledRejection` in the main process
captured to PostHog directly, independent of whether a renderer window is open, without
pulling the renderer's posthog-js/@posthog/react setup into the main process.

Keep the existing crash-log.txt write and the IPC broadcast to open renderer windows
exactly as they are; this is additive, not a replacement. Also keep the same discipline
`main.tsx` already applies around not leaking local file paths (the "/Users/<name>/..."
pattern) in captured stack traces or messages.

Should typecheck clean (`npm run typecheck`).
