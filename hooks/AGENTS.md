# AGENTS.md — `~/.claude/hooks`

Instructions for any AI agent editing files in this directory. These are **live,
global Claude Code hooks** wired in `~/.claude/settings.json`; they run in every
session on this machine. A bug in any of them degrades every session. Treat all
of them as production and follow the shared rule below before editing any hook.

## Live hooks in this directory

| Script | Event | Can block? | Docs |
|--------|-------|-----------|------|
| `validate-file.mjs` | `PreToolUse` (Write/Edit/MultiEdit) | Yes, denies malformed writes | `README.md`, this file |
| `omc-ledger-stop-gate.mjs` | `Stop` | Yes, blocks turn end on open ledger items | `omc-orchestration-guards.md` |
| `omc-spawn-contract-warn.mjs` | `PreToolUse` (Task) | **No** — warn only (issue #26923) | `omc-orchestration-guards.md` |
| `omc-guards-uninstall.mjs` | (not a hook) | n/a — automated undo for the two guards | `omc-orchestration-guards.md` |

**Shared rule for every hook here: fail open.** Any error, malformed input, or
unreadable file MUST result in allow (exit 0, no blocking output). A guard bug
must never be able to wedge a session. Every `try/catch` that falls through to
allow is load-bearing.

The rest of this file is the deep dive on `validate-file.mjs` (the most
intricate hook). The orchestration guards are documented at the end and in
`omc-orchestration-guards.md`.

## What `validate-file.mjs` is

`validate-file.mjs` is a **live, global Claude Code PreToolUse hook** wired in
`~/.claude/settings.json`. It runs on every `Write`/`Edit`/`MultiEdit` in every
session and can **block the write**. A bug here degrades editing for the whole
machine. Treat it as production.

## Hard rules

1. **Preserve fail-open — but only for the DECISION engine.** If the hook can't
   decide (bad payload, unreadable content, missing/erroring engine), it MUST
   `allow()` — never block on its own failure. Every `try/catch` that falls
   through to `allow()` is load-bearing; do not "tighten" them into blocks.
   The exception: **message harvest is NOT covered by fail-open.** Once the
   stdin decision says deny, a harvest failure keeps the deny with a generic
   message — it must never flip the decision to allow. `harvestBiomeDiagnostic`
   returns `null` on any anomaly and the caller falls back to a generic reason.
2. **Keep the source pure ASCII; never put literal control or non-ASCII bytes in
   it.** The control-char detector uses numeric code points (`charCodeAt` +
   `0x..` literals) on purpose. Do NOT rewrite it as a regex with literal
   control chars or `\u` escapes — past attempts kept emitting real NUL/control
   bytes into the file, which the hook itself then rejected.
3. **The decision uses `biome format` / `ruff format` (syntax gates).** They exit
   non-zero ONLY on parse errors (not lint), so valid-but-unlinted code passes.
   Do NOT move `biome check` / `ruff check` into the DECISION path — they add
   lint rules that would block valid code (this was the original reason for
   `format`).
4. **`biome check` is allowed in `harvestBiomeDiagnostic` ONLY, for message
   extraction.** It is safe there precisely because harvest runs only after a
   parse failure, and a file that fails to parse cannot be linted — so `check`
   emits parse diagnostics only. The harvest is additionally gated to
   `category === "parse"` and discards everything else. Do NOT remove that
   filter (it stops lint text from leaking into the reason) and do NOT copy
   `check` into the decision path.
5. **The stdin filename must be the real basename.** Both the decision
   (`--stdin-file-path=${path.basename(filePath)}`) and the harvest temp file use
   the real basename so Biome's JSONC relaxation for well-known names
   (`tsconfig.json`, `.vscode/*.json`, `*.jsonc`) matches. Do NOT revert to a
   synthetic `f.json` — that makes Biome treat every `.json` as strict and
   false-positives on valid JSONC.
6. **Don't validate type errors.** Only format/syntax + invalid characters are
   gated. A TS type error must pass.
7. **Keep it dependency-free and synchronous.** Node built-ins only
   (`fs`, `os`, `path`, `child_process`). No npm deps, no async/Promises —
   everything is `spawnSync`.

## Always verify before declaring done

Behavior (valid passes silently, invalid prints a `deny` JSON):

```sh
H=C:/Users/johnw/.claude/hooks/validate-file.mjs
node --check "$H"
for c in \
 '{"tool_name":"Write","tool_input":{"file_path":"a.json","content":"{\"a\":1}"}}' \
 '{"tool_name":"Write","tool_input":{"file_path":"a.json","content":"{bad}"}}' \
 '{"tool_name":"Write","tool_input":{"file_path":"a.ts","content":"const x: number = 1;"}}' \
 '{"tool_name":"Write","tool_input":{"file_path":"a.ts","content":"const x: number = ;"}}' \
 '{"tool_name":"Write","tool_input":{"file_path":"a.py","content":"def f():\n    return 1\n"}}' \
 '{"tool_name":"Write","tool_input":{"file_path":"a.py","content":"def f(:\n"}}' ; do
  echo "$c" | node "$H"; echo " <-- ($c)";
done
```

Expected: rows 1/3/5 print nothing (allow); rows 2/4/6 print a `deny` JSON.

**Message quality** is the point of the deny path — also assert that a deny
reason contains a location and a specific cause, e.g. bad TS
(`const x: number = ;`) must yield `line 1, column 19` and `Expected an
expression`, and a `tsconfig.json` with `//` comments must ALLOW.

## Architecture facts (don't re-derive)

- **PreToolUse only.** PostToolUse can't block or undo a write (bytes already on
  disk). Don't "simplify" by moving to PostToolUse.
- **Two-path Biome design.** The stdin `biome format` call is the immutable
  allow/deny DECISION. On a deny, `harvestBiomeDiagnostic` writes the content to
  an isolated temp file and runs `biome check --reporter=json` to get the located
  parse diagnostic (Biome suppresses these on stdin but emits them for real
  files). Harvest is message-only and pure fail-soft.
- **Deny reasons are structured**: `deny(filePath, { where, why, fix })` renders
  `to <basename>` / `Where:` / `Why:` / `Fix:` / scope note. Validators return
  that object (or `null` to allow), not a bare string.
- **`reconstruct()` handles both Edit payload shapes** — an explicit `content`
  field and `old_string`/`new_string` replay. Deliberate (the exact Edit hook
  payload schema was never confirmed). Keep both paths.
- **Biome runs as the native exe via a constructed path**
  (`@biomejs/cli-<platform>-<arch>`), with a `node bin/biome` shim fallback.
  `biomeCmd()` returns `[bin, ...prefixArgs]`. No directory globbing — keep it.
- **Ruff is `python -m ruff`** — version-agnostic, no path discovery.
- **Dart/Flutter via `dart format` (`validateDart`).** `dart format --output=none`
  is the syntax gate (exit 65 = parse failure; located message in stderr). Only a
  clear parse failure denies; other non-zero exits fail open. NOTE: on Windows the
  `dart` on PATH is a `.bat` wrapper that `spawnSync` cannot run directly — `dartBin()`
  resolves the real `dart.exe` (standalone `<bin>/dart.exe` or Flutter
  `<bin>/cache/dart-sdk/bin/dart.exe`) by scanning PATH. Don't "simplify" it to
  spawning `dart` directly. It is the heaviest engine (~0.2s VM startup); override
  with `DART_BIN`.

## Changing scope

- New syntax-checked type: add the extension to `BIOME_EXTS` (Biome must support
  it). Add it to `TEXT_EXTS` too if you also want the control-char scan.
- New control-char-only type: add to `TEXT_EXTS`.
- Both sets are near the top of the file.

## Orchestration guards (`omc-ledger-stop-gate.mjs`, `omc-spawn-contract-warn.mjs`)

These back the `<opus_orchestration>` / `<subagent_prompt_contract>` guidance in
`~/.claude/CLAUDE.md` with enforcement. Full spec + kill switches + undo are in
`omc-orchestration-guards.md`; read it before editing either script.

Facts not to re-derive:

1. **Only the Stop gate can enforce; the spawn guard cannot.** `Stop` hooks can
   block ("prevents Claude from stopping"). `PreToolUse` on `Task` cannot —
   [issue #26923](https://github.com/anthropics/claude-code/issues/26923): the
   subagent launches despite a block. So `omc-spawn-contract-warn.mjs` emits
   `additionalContext` and always allows. Do NOT "upgrade" it to return a deny
   expecting it to stop a spawn until #26923 is fixed (that is its written
   removal trigger).
2. **The Stop gate is opt-in by existence.** No ledger file -> it does nothing.
   Never change it to demand a ledger or gate turns with no ledger present; that
   would block every turn on the machine.
3. **Respect `stop_hook_active`.** The default path blocks only when it is false
   (one forced continuation per stop), which is the loop-safety guarantee. Do not
   remove that check; `OMC_LEDGER_GATE_STRICT` is the opt-in to bypass it.
4. **Output shapes differ by event.** Stop uses top-level
   `{ "decision": "block", "reason": ... }`. PreToolUse uses
   `{ "hookSpecificOutput": { "hookEventName": "PreToolUse", "permissionDecision": ..., ... } }`.
   Do not cross them.
5. **Same fail-open contract as everything here.** Both allow on any error.
6. **`omc-guards-uninstall.mjs` removes ONLY these two entries** (matched by
   script basename) and backs up settings first. Keep it basename-scoped so it
   never touches `validate-file` or other hooks.

Verify before declaring done (ledger gate blocks on open items; spawn guard warns
on a thin prompt, silent on a rich one):

```sh
G=C:/Users/johnw/.claude/hooks
node --check "$G/omc-ledger-stop-gate.mjs" && node --check "$G/omc-spawn-contract-warn.mjs"

# Stop gate: pass a native (C:/...) cwd containing .omc/LEDGER.md with a `- [ ]` line
#   -> expect {"decision":"block",...}; all `- [x]`/`- [~]` or no file -> no output.
# Spawn guard:
echo '{"tool_input":{"prompt":"go fix it","subagent_type":"executor"}}' | node "$G/omc-spawn-contract-warn.mjs"   # -> warn JSON
node "$G/omc-guards-uninstall.mjs" --dry-run   # -> "would remove 2 guard hook entr(y/ies)"
```

Note the Stop-gate test needs a **native Windows cwd** (`C:/...`), not a git-bash
`/c/...` path — Windows Node cannot resolve the latter and the gate will fail
open (no block) as if no ledger existed.
