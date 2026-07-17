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
  - `fonts/`: CommitMono (referenced by VSCodium settings)
  - `collect.ps1` / `apply.ps1`: sync scripts (see below)

Everything else in `~/.claude` (credentials, history, sessions, caches, plugins) is ignored. Plugins reinstall automatically on first launch from `enabledPlugins` and `extraKnownMarketplaces` in `settings.json`.

## Setup on a new machine: one command

Paste into PowerShell (only prereq is winget, which ships with Windows 11). A browser window opens once for GitHub sign-in when git first touches the private repo:

```powershell
winget install -e --id Git.Git --accept-source-agreements --accept-package-agreements; $env:Path=[Environment]::GetEnvironmentVariable('Path','Machine')+';'+[Environment]::GetEnvironmentVariable('Path','User')+';'+$env:Path; $d="$env:USERPROFILE\.claude"; New-Item -ItemType Directory -Force $d | Out-Null; git -C $d init -b master; git -C $d remote add origin https://github.com/johncwaters/claude-setup.git; git -C $d fetch origin; git -C $d checkout -f master; powershell -ExecutionPolicy Bypass -File "$d\setup\install.ps1"
```

That bootstraps git, clones this repo into `~/.claude`, and runs `setup/install.ps1`, which pulls latest and hands off to `setup/apply.ps1`: config copies, then installs anything missing (git, gh, node, Claude Code, VSCodium, CommitMono fonts, npm globals, VSCodium extensions). Everything is idempotent; rerun any time.

Afterwards launch Claude Code and run `setup omc` (or `/oh-my-claudecode:omc-setup`) to finish OMC wiring.

## Re-sync an existing machine

```powershell
powershell -File $env:USERPROFILE\.claude\setup\install.ps1
```

Pulls latest and applies. `-SkipInstalls` copies config only.

## Auth checklist (manual, once per machine)

Nothing secret syncs through this repo, so log in fresh:

- [ ] `claude` (first launch prompts for Anthropic login)
- [ ] `gh auth login` (GitHub CLI; git pushes ride on this via https)
- [ ] VSCodium: re-auth MCP servers (PostHog) on first use
- [ ] Anything project-specific (.env files) stays per-repo, not here

## Publishing changes from a machine

`powershell -File ~\.claude\setup\collect.ps1` grabs live VSCodium/glissa/git/terminal config into the repo, then add/commit/push from `~/.claude`. Claude Code files (CLAUDE.md, skills, etc.) live in the repo directly; no collect step needed for them.
