# File-format guard hook

A Claude Code **PreToolUse** hook that blocks Claude from saving malformed files.
It validates the *final* content of every `Write` / `Edit` / `MultiEdit` **before**
the bytes touch disk, and denies the tool call if the result wouldn't parse or
contains stray invalid characters. Built to stop things like a corrupted
`claude.json` or files saved with junk control characters.

When it denies, it returns **strong, located, actionable feedback** — the
basename, the line:column, the specific parser error, and a concrete fix hint —
so the agent can correct it immediately instead of guessing.

## Files

| File | Purpose |
|------|---------|
| `validate-file.mjs` | The validator. Reads the hook payload on stdin, reconstructs the resulting file content, validates it, prints a `deny` decision (or nothing = allow). |
| `enforce-spawn-model.mjs` | Spawn-model guard (separate hook, own header docs). Denies Agent/Task subagent spawns whose `model` is missing or fable, enforcing the CLAUDE.md routing rule that every spawn pins its tier explicitly. |
| `inject-routing.mjs` | Routing loader (separate hook, own header docs). On `SessionStart` it prints `~/.claude/ROUTING.md` into the session. SessionStart never fires for subagents, so main-loop-only routing rules stay out of every spawn and out of the Codex mirror. |
| `README.md` | This file. |
| `AGENTS.md` | Instructions for an AI agent editing anything in this directory. |

## How it's wired

The hooks block now lives in `settings.base.json` with `{{HOME}}` tokens, and
`setup/apply.ps1` (or `setup/apply.sh` on Linux) renders it into the machine's
`settings.json` (user-level = **global**, all projects), substituting the real
home path for each token:

```json
"hooks": {
  "PreToolUse": [
    {
      "matcher": "Write|Edit|MultiEdit",
      "hooks": [
        { "type": "command", "command": "node {{HOME}}/.claude/hooks/validate-file.mjs" }
      ]
    }
  ]
}
```

PreToolUse is the **only** hook that can block a write — PostToolUse fires after
the bytes are already on disk and cannot undo them.

## What it validates

| File type | Engine | Notes |
|-----------|--------|-------|
| `.json .jsonc` | Biome (`biome format`) + `JSON.parse` fallback | JSON is always guarded, even if Biome is missing. JSONC (comments/trailing commas) is allowed for well-known names like `tsconfig.json` and any `.jsonc`. |
| `.js .mjs .cjs .ts .mts .cts .tsx .jsx .css` | Biome (`biome format`) | Syntax/parse errors only — **type** errors are allowed through. |
| `.py` | `python -m ruff format` | Syntax/parse errors only — lint is ignored. |
| `.dart` | `dart format` (Flutter/Dart SDK) | Syntax/parse errors only. Heaviest engine (~0.2s, Dart VM startup). Fails open if no Dart/Flutter SDK is found. |
| any text file | inline scan | Rejects NUL, U+FFFD, and stray control chars (tab/LF/FF/CR are fine). |
| any text file | inline scan | Rejects a **newly introduced** em dash (U+2014), en dash (U+2013), or horizontal ellipsis (U+2026). Insertion-only scan (see `insertedTextError` in the source), so a file that already has one elsewhere stays editable. |
| any text file | inline scan | Rejects a **newly introduced** emoji: the astral emoji planes, Unicode's BMP `Emoji_Presentation=Yes` set, and U+FE0F. Symbols that default to text presentation (check marks, arrows, triangles) pass unless U+FE0F follows. Insertion-only, and skipped entirely when the file on disk already has an emoji, matching the AGENTS.md carve-out. |
| `AGENTS.md` `CLAUDE.md` `ROUTING.md` | inline size gate | Rejects a write that pushes an always-loaded instruction file past its `DOC_SIZE_CAPS` byte budget. Applies only at a repo root or in `~/.claude`, never to a nested directory-scoped copy. Only growth is denied: a write that shrinks the file always passes, so an oversized file can be edited back down. |

`biome format` / `ruff format` are used as pure syntax gates: they exit non-zero
only on parse errors, so style/lint noise never blocks a save.

## Feedback on rejection

Every deny carries a structured, agent-actionable reason:

```
File-format guard blocked this write to a.ts.
Where: line 1, column 19
Why: Expected an expression, or an assignment but instead found ';'.
Fix: Expected an expression, or an assignment here.
(Only syntax/format, invalid characters, and instruction-file size are gated here, not type or lint errors.)
```

Getting the location is a two-step trick: Biome **suppresses** located
diagnostics when fed by stdin (the fast decision pass only learns pass/fail), so
on a failure the hook writes the content to a throwaway temp file and runs
`biome check --reporter=json` on it to **harvest** the precise `line:col` +
message + fix hint. That temp-file step runs **only on the rare failure path**,
keeping the common (valid) save disk-free. Ruff already reports locations; the
control-char scan computes its own `line:col`. The harvest is message-only and
fail-soft: if it can't produce a located message it falls back to a generic one
but still denies — it can never flip a deny into an allow.

## Requirements (install once per machine)

```sh
npm install -g @biomejs/biome     # Biome (Rust). Tested with 2.5.1
pip install ruff                  # Ruff (Rust).  Tested with 0.15.20
```

Node is required (it ships with Claude Code). Tested with Node v26. Dart
validation is optional — it activates automatically if a Dart or Flutter SDK is
on `PATH` (tested with Dart 3.10 / Flutter), and fails open otherwise. Override
with the `DART_BIN` environment variable.

Biome is found by constructing the platform package path
(`@biomejs/cli-<platform>-<arch>`) under the npm-global install, so the native
exe runs directly with no directory scanning. Override with the `BIOME_BIN`
environment variable if your install lives elsewhere. Ruff is invoked as
`python -m ruff`, so it just needs to be importable by whatever `python` is on
PATH.

## Fail-open by design

If anything goes wrong — bad hook payload, can't read content, an engine is
missing or errors — the hook **allows** the write (exits 0, no output). It never
blocks you because of its own bug. The cost is that a missing engine silently
skips validation for those file types (except `.json`, which has the
`JSON.parse` fallback).

## Test it manually

```sh
# should print a deny JSON (bad JSON):
echo '{"tool_name":"Write","tool_input":{"file_path":"x.json","content":"{bad}"}}' \
  | node ~/.claude/hooks/validate-file.mjs

# should print nothing (valid):
echo '{"tool_name":"Write","tool_input":{"file_path":"x.json","content":"{\"a\":1}"}}' \
  | node ~/.claude/hooks/validate-file.mjs
```

## Common tasks

- **Disable it:** remove the `hooks` block from `~/.claude/settings.json`.
- **Add a file type to syntax-checking:** add the extension to `BIOME_EXTS`
  (if Biome supports it) — that's all.
- **Add a file type to the control-char scan only:** add it to `TEXT_EXTS`
  (this also gates the dash/ellipsis scan, since both share `TEXT_EXTS`).
- **Change a deny message:** see `deny()` and the `validate*` functions.

## Known limitations

- Does **not** protect `~/.claude.json`. Claude Code writes that file itself
  (not via the Write/Edit tools), so no tool hook can intercept it.
- Located diagnostics depend on Biome's `--reporter=json` shape (tested on Biome
  2.5.1). If a future Biome changes it, harvest fails soft to a generic deny
  message — the file is still correctly blocked, just with less detail.
- Plain `.json` (a name that isn't well-known) is checked as **strict** JSON, so
  comments/trailing commas in, say, `data.json` are rejected by design. Use a
  `.jsonc` extension or a well-known name for comment-bearing config.
- Global per OS user on this machine only, not synced across machines.
