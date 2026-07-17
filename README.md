# claude-setup

Portable machine setup, synced via git from `~/.claude`. Covers Claude Code plus VSCodium, glissa, git, Windows Terminal, and npm global tools.

## What is tracked

- `CLAUDE.md`: global instructions (OMC orchestration, routing, style rules)
- `settings.json`: model, permissions, hooks, statusline, enabled plugins
- `skills/`: custom skills (impeccable, postiz, pr-review-pipeline, omc-learned, omc-reference)
- `commands/`: custom slash commands (commit, seo-audit)
- `hooks/`: OMC guard hooks (validate-file, spawn-contract-warn, ledger-stop-gate)
- `hud/`: OMC statusline script
- `setup/`: everything beyond Claude Code
  - `vscodium/`: settings, keybindings, mcp.json, extensions.txt
  - `glissa/`: glissa dashboard config
  - `git/`: .gitconfig
  - `terminal/`: Windows Terminal settings
  - `npm-globals.txt`: global npm tools (glissa, oh-my-claude-sisyphus, postiz, biome, typescript, ...)
  - `collect.ps1` / `apply.ps1`: sync scripts (see below)

Everything else in `~/.claude` (credentials, history, sessions, caches, plugins) is ignored. Plugins reinstall automatically on first launch from `enabledPlugins` and `extraKnownMarketplaces` in `settings.json`.

## Setup on a new machine

`~/.claude` already exists once Claude Code has run, so clone into it in place:

```sh
cd ~/.claude
git init
git remote add origin https://github.com/johncwaters/claude-setup.git
git fetch origin
git checkout -f master
```

Then:

1. `pwsh ~/.claude/setup/apply.ps1`: copies VSCodium/glissa/git/terminal config into place, installs missing npm globals and VSCodium extensions. Use `-SkipInstalls` to only copy config files.
2. Launch Claude Code and run `setup omc` (or `/oh-my-claudecode:omc-setup`) to finish OMC wiring.

Prereqs the script expects on PATH: node/npm, and VSCodium (`codium`) if you want extensions installed.

## Syncing

- Pull latest: `git -C ~/.claude pull`, then `pwsh ~/.claude/setup/apply.ps1` to push it into the live apps.
- Publish changes: `pwsh ~/.claude/setup/collect.ps1` (grabs live VSCodium/glissa/git/terminal config into the repo), then add/commit/push from `~/.claude`.
- Claude Code files (CLAUDE.md, skills, etc.) live in the repo directly; no collect/apply step needed for them.
