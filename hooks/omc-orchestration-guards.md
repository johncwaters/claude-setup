# Orchestration guards

Two hooks that back the orchestration guidance in `~/.claude/CLAUDE.md`
(`<opus_orchestration>` and `<subagent_prompt_contract>`) with mechanical
enforcement, so the guidance is not purely advisory.

They were added deliberately as a **matched pair with different strengths**,
because the platform only lets one of them truly enforce:

| Guard | Hook | Can it enforce? | Why |
|-------|------|-----------------|-----|
| Ledger stop gate | `Stop` | **Yes, hard block** | Docs: `Stop` can block ("prevents Claude from stopping, continues the conversation"). |
| Spawn-contract warn | `PreToolUse` on `Task` | **No, warn only** | PreToolUse blocking does not work for `Task` ([issue #26923](https://github.com/anthropics/claude-code/issues/26923)): the agent launches despite a block. So this only injects feedback. |

Do not mistake the spawn guard for a gate. It nudges; it cannot stop a thin
spawn. The removal trigger is written into the script: when #26923 is fixed it
can be upgraded to a real deny.

## 1. Ledger stop gate

`omc-ledger-stop-gate.mjs` (registered on `Stop`).

Refuses to end the turn while a requirements ledger still has open `- [ ]`
items. **Opt-in by existence** — with no ledger file present it does nothing, so
ordinary turns are never gated. Arm it by creating a ledger.

Ledger location, first that exists:
1. `$OMC_LEDGER_PATH`
2. `<cwd>/.omc/LEDGER.md`
3. `<cwd>/.omc/state/LEDGER.md`
4. `<cwd>/.workflow/LEDGER.md`
5. `<cwd>/LEDGER.md`

Line grammar:
- `- [ ] open item` blocks the stop
- `- [x] completed item` passes
- `- [~] deferred: reason` passes (explicit, visible deferral)

Loop safety: by default it blocks only when the turn is not already continuing
because of it (`stop_hook_active` false), i.e. exactly one forced continuation
per stop attempt, so a stuck turn cannot loop forever. Set
`OMC_LEDGER_GATE_STRICT=1` to block on every attempt (stronger; a turn that can
neither finish nor defer its items will loop until you interrupt).

## 2. Spawn-contract warn

`omc-spawn-contract-warn.mjs` (registered on `PreToolUse` matcher `Task`).

Inspects each subagent spawn and, if the prompt looks under-specified against
`<subagent_prompt_contract>`, injects a non-blocking reminder. Flags:
- prompt under 400 chars
- no explicit `model`
- no visible output contract (no "return / output / report / format ...")
- no visible boundaries (no "do not / only / scope / stop and report ...")

A well-formed spawn passes silently. **It never blocks** (see table above).

## Config / kill switches

Set these as env vars (e.g. in `settings.json` `"env"`, or your shell) to change
behavior without editing code:

| Env var | Effect |
|---------|--------|
| `OMC_SKIP_LEDGER_GATE` | Disable the ledger stop gate entirely. |
| `OMC_LEDGER_GATE_STRICT` | Ledger gate blocks on every stop attempt (loop risk). |
| `OMC_LEDGER_PATH` | Explicit ledger file path (overrides the search list). |
| `OMC_SKIP_SPAWN_GUARD` | Disable the spawn-contract warn. |

Both hooks are **fail-open**: any error, malformed input, or unreadable file
results in allow, so a bug in a guard can never wedge the session.

## Undo

Temporary (per session), no file changes — set the kill switches above, e.g. add
to `settings.json`:

```json
"env": { "OMC_SKIP_LEDGER_GATE": "1", "OMC_SKIP_SPAWN_GUARD": "1" }
```

Permanent, automated (removes only these two hook entries, backs up first):

```
node C:/Users/johnw/.claude/hooks/omc-guards-uninstall.mjs           # apply
node C:/Users/johnw/.claude/hooks/omc-guards-uninstall.mjs --dry-run # preview
```

Permanent, manual — either restore the pre-install backup:

```
cp C:/Users/johnw/.claude/settings.json.bak-orchestration-guards C:/Users/johnw/.claude/settings.json
```

or delete the two hook entries (`Task` matcher under `PreToolUse`, and the whole
`Stop` block) from `settings.json` by hand. The `.mjs` scripts and this doc can
be left in place (harmless once unregistered) or deleted.

## Files

- `omc-ledger-stop-gate.mjs` — the Stop gate
- `omc-spawn-contract-warn.mjs` — the spawn warn
- `omc-guards-uninstall.mjs` — automated undo
- `settings.json.bak-orchestration-guards` — pre-install settings backup
