# claude-setup

Portable machine setup, synced via git from `~/.claude`. Covers Claude Code plus VSCodium, glissa, git, Windows Terminal, and npm global tools.

The interesting homegrown pieces:

- `compiled-commit/`: a deterministic commit workflow compiled from a prompt into a Python runner with typed outcomes, plus its own eval bench (`bench/`) with recorded fixtures, an LLM judge, and scored results comparing the compiled runner against historical prompt-driven commits
- `hooks/`: file-format guard and AGENTS.md sync hooks
- `hud/`: custom status line
- `skills/code-review`, `skills/release`: multi-lane review workflow and an evidence-gated release runner with a deterministic profile linter
- `setup/`: one-command idempotent machine bootstrap (see below)

Vendored third-party skills are listed in [NOTICE.md](NOTICE.md).

## What is tracked

- `CLAUDE.md`: global instructions (routing, delegation, style rules)
- `settings.json`: model, permissions, hooks, enabled plugins
- `skills/`: homegrown skills (code-review, release) plus vendored ones (impeccable, ai-slop-cleaner, posthog-querying, posthog-error-triage; see NOTICE.md); release ships a deterministic profile linter + template, and each project repo keeps its release knowledge in a tracked `.claude/release-profile.yml`
- `agents/`: custom subagents (code-reviewer, security-reviewer, structure-reviewer)
- `commands/`: custom slash commands (commit, seo-audit)
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

Everything else in `~/.claude` (credentials, history, sessions, caches, plugins) is ignored. Plugins reinstall automatically on first launch from `enabledPlugins` and `extraKnownMarketplaces` in `settings.json`.

## Setup on a new machine: one command

Paste into PowerShell (only prereq is winget, which ships with Windows 11). A browser window opens once for GitHub sign-in the first time git needs push access:

```powershell
winget install -e --id Git.Git --accept-source-agreements --accept-package-agreements; $env:Path=[Environment]::GetEnvironmentVariable('Path','Machine')+';'+[Environment]::GetEnvironmentVariable('Path','User')+';'+$env:Path; $d="$env:USERPROFILE\.claude"; New-Item -ItemType Directory -Force $d | Out-Null; git -C $d init -b master; git -C $d config remote.origin.url https://github.com/johncwaters/claude-setup.git; git -C $d config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'; git -C $d fetch origin; git -C $d checkout -f -B master origin/master; powershell -ExecutionPolicy Bypass -File "$d\setup\install.ps1"
```

That bootstraps git, clones this repo into `~/.claude`, and runs `setup/install.ps1`, which pulls latest and hands off to `setup/apply.ps1`: config copies, then installs anything missing (git, gh, node, Claude Code, VSCodium, CommitMono fonts, project repos from `repos.txt`, npm globals, VSCodium extensions). Extensions sync exactly to `extensions.txt`; project repos clone into `~/Projects`, fast-forward on reruns, and get their node deps installed. Everything is idempotent; rerun any time.

## Re-sync an existing machine

```powershell
powershell -File $env:USERPROFILE\.claude\setup\install.ps1
```

Pulls latest and applies. `-SkipInstalls` copies config only.

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

`powershell -File ~\.claude\setup\collect.ps1` grabs live VSCodium/glissa/git/terminal config into the repo, then add/commit/push from `~/.claude`. Claude Code files (CLAUDE.md, skills, etc.) live in the repo directly; no collect step needed for them.
