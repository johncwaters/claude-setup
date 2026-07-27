# claude-setup

Portable machine setup, synced via git from `~/.claude`. Covers Claude Code plus VSCodium, glissa, git, Windows Terminal, and npm global tools.

## What is tracked

- `profiles/`: per machine profile config. `personal/` and `work/` each hold a `CLAUDE.md`, a `commit.md`, a `settings.overlay.json`, and a `profile.json` that lists the setup steps that profile runs
- `settings.base.json`: the settings shared by every profile (model, hooks, status line, effort, and so on), with `{{HOME}}` tokens that apply fills in for the machine
- `skills/`: custom skills (impeccable, ai-slop-cleaner, code-review, release); release ships a deterministic profile linter + template, and each project repo keeps its release knowledge in a tracked `.claude/release-profile.yml`
- `agents/`: custom subagents (code-reviewer, security-reviewer, structure-reviewer)
- `commands/`: custom slash commands (seo-audit is tracked directly; commit is rendered per profile, see Machine profiles below)
- `hooks/`: file-format guard hook (validate-file)
- `setup/`: everything beyond Claude Code
  - `vscodium/`: settings, keybindings, mcp.json, extensions.txt
  - `glissa/`: glissa dashboard config
  - `git/`: .gitconfig
  - `terminal/`: Windows Terminal settings
  - `npm-globals.txt`: global npm tools (glissa, postiz, codex, grok, biome, typescript, ...); `@openai/codex` (Codex CLI) and `@xai-official/grok` (Grok Build CLI) are the external advisors CLAUDE.md routing dispatches directly
  - `npm-globals-remove.txt`: retired global npm tools; apply uninstalls any of these still present so machines converge (currently oh-my-claude-sisyphus and the community grok CLI)
  - `repos.txt`: project repos referenced by glissa sessions (milepost, glissa, keeplings, card-harbor); apply clones missing ones into `~/Projects`, fast-forwards existing ones, then installs each repo's node deps (npm/pnpm/yarn by lockfile) and heals a missing electron binary
  - `fonts/`: CommitMono (referenced by VSCodium settings)
  - `collect.ps1` / `apply.ps1`: sync scripts (see below)

`CLAUDE.md`, `settings.json`, and `commands/commit.md` at the repo root are no longer tracked. Apply renders them from the machine's profile (`settings.json` from `settings.base.json` plus the profile overlay, the two markdown files copied straight from the profile), so the live files exist on disk but git ignores them.

Everything else in `~/.claude` (credentials, history, sessions, caches, plugins) is ignored. Plugins reinstall automatically on first launch from the `enabledPlugins` and `extraKnownMarketplaces` that end up in the rendered `settings.json`.

## Machine profiles

Each machine adopts one profile, `personal` or `work`, and apply runs only that profile's steps.

- `personal` runs the full set: workflow config and settings render, VSCodium config, glissa, gitconfig, Codex AGENTS.md, Windows Terminal, software installs, fonts, project repos, npm globals, python tools, and VSCodium extensions.
- `work` runs a focused set: workflow config and settings render, VSCodium config, fonts, the biome hook dependency, python tools, and VSCodium extensions. It skips all software installs, project repos, npm globals sync, glissa, gitconfig, and Windows Terminal.

The work profile installs nothing beyond biome and the pip tools, so it assumes git, node, and python are already on the machine. When node is missing, apply warns instead of failing and `settings.json` gets rendered on the next run after node is installed.

The chosen profile lives in a `.machine-profile` marker file at the repo root (ignored by git, so it stays local to the machine). Set it once by passing `-Profile personal` or `-Profile work` to `install.ps1` or `apply.ps1`; the marker records the choice and later runs reuse it. With no marker and no flag, apply prompts for the profile on an interactive host. Each profile's exact step list is `profiles/<profile>/profile.json`.

## Setup on a new machine: one command

Paste into PowerShell (only prereq is winget, which ships with Windows 11). A browser window opens once for GitHub sign-in when git first touches the private repo:

```powershell
winget install -e --id Git.Git --accept-source-agreements --accept-package-agreements; $env:Path=[Environment]::GetEnvironmentVariable('Path','Machine')+';'+[Environment]::GetEnvironmentVariable('Path','User')+';'+$env:Path; $d="$env:USERPROFILE\.claude"; New-Item -ItemType Directory -Force $d | Out-Null; git -C $d init -b master; git -C $d config remote.origin.url https://github.com/johncwaters/claude-setup.git; git -C $d config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'; git -C $d fetch origin; git -C $d checkout -f -B master origin/master; powershell -ExecutionPolicy Bypass -File "$d\setup\install.ps1"
```

For a work machine, use the same one-liner with the profile flag on the final call:

```powershell
winget install -e --id Git.Git --accept-source-agreements --accept-package-agreements; $env:Path=[Environment]::GetEnvironmentVariable('Path','Machine')+';'+[Environment]::GetEnvironmentVariable('Path','User')+';'+$env:Path; $d="$env:USERPROFILE\.claude"; New-Item -ItemType Directory -Force $d | Out-Null; git -C $d init -b master; git -C $d config remote.origin.url https://github.com/johncwaters/claude-setup.git; git -C $d config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'; git -C $d fetch origin; git -C $d checkout -f -B master origin/master; powershell -ExecutionPolicy Bypass -File "$d\setup\install.ps1" -Profile work
```

That bootstraps git, clones this repo into `~/.claude`, and runs `setup/install.ps1`, which pulls latest and hands off to `setup/apply.ps1`: config copies, then installs anything missing (git, gh, node, Claude Code, VSCodium, CommitMono fonts, project repos from `repos.txt`, npm globals, VSCodium extensions). Extensions sync exactly to `extensions.txt`; project repos clone into `~/Projects`, fast-forward on reruns, and get their node deps installed. Everything is idempotent; rerun any time.

## Re-sync an existing machine

```powershell
powershell -File $env:USERPROFILE\.claude\setup\install.ps1
```

Pulls latest and applies. `-SkipInstalls` copies config only.

Sync through `install.ps1`, not a bare `git pull`. Because the rendered `CLAUDE.md`, `settings.json`, and `commands/commit.md` are no longer tracked, a plain `git pull` in `~/.claude` can drop those live files until apply regenerates them. `install.ps1` pulls and then reruns apply, which rerenders them from the machine's profile in the same pass.

## Auth checklist (manual, once per machine)

Nothing secret syncs through this repo, so log in fresh:

- [ ] `claude` (first launch prompts for Anthropic login)
- [ ] `gh auth login` (GitHub CLI; git pushes ride on this via https)
- [ ] `codex login` (Codex CLI; ChatGPT sign-in, needed for Codex routing)
- [ ] `grok login` (Grok Build CLI; grok.com sign-in, or set `XAI_API_KEY`, needed for Grok research routing)
- [ ] `claude mcp add --transport http posthog https://mcp.posthog.com/mcp -s user` (PostHog MCP; OAuth browser login on first use)
- [ ] VSCodium: re-auth MCP servers (PostHog) on first use
- [ ] Anything project-specific (.env files) stays per-repo, not here

## Publishing changes from a machine

`powershell -File ~\.claude\setup\collect.ps1` grabs live VSCodium/glissa/git/terminal config into the repo, then add/commit/push from `~/.claude`. On a work machine collect gathers only the VSCodium config; the rest is personal only. Claude Code files (skills, agents, and the profile workflow files under `profiles/`) live in the repo directly; no collect step is needed for them. Edit the workflow config in `profiles/<profile>/`, not the rendered root copies, since those are regenerated by apply.
