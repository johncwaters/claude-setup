# claude-setup

Portable machine setup, synced via git from `~/.claude`. Covers Claude Code plus VSCodium, glissa, git, Windows Terminal (Windows-only; not applicable on Linux), and npm global tools.

The interesting homegrown pieces:

- `compiled-commit/`: a deterministic commit workflow compiled from a prompt into a Python runner with typed outcomes, plus its own eval bench (`bench/`) with an LLM judge for comparing the compiled runner against historical prompt-driven commits (the recorded scenario data, fixtures, and scored results came from private repositories and are not included)
- `hooks/`: file-format guard and AGENTS.md sync hooks
- `hud/`: custom status line
- `skills/code-review`, `skills/release`: multi-lane review workflow and an evidence-gated release runner with a deterministic profile linter
- `setup/`: one-command idempotent machine bootstrap (see below)

Vendored third-party skills are listed in [NOTICE.md](NOTICE.md).

## What is tracked

- `profiles/`: per machine profile config. `personal/` and `work/` each hold a `CLAUDE.md`, a `commit.md`, a `settings.overlay.json`, and a `profile.json` that lists the setup steps that profile runs
- `settings.base.json`: the settings shared by every profile (model, hooks, status line, effort, and so on), with `{{HOME}}` tokens that apply fills in for the machine
- `skills/`: homegrown skills (code-review, release) plus vendored ones (impeccable, ai-slop-cleaner, posthog-querying, posthog-error-triage; see NOTICE.md); release ships a deterministic profile linter + template, and each project repo keeps its release knowledge in a tracked `.claude/release-profile.yml`
- `agents/`: custom subagents (code-reviewer, security-reviewer, structure-reviewer)
- `commands/`: custom slash commands (seo-audit is tracked directly; commit is rendered per profile, see Machine profiles below)
- `hooks/`: file-format guard hook (validate-file)
- `setup/`: everything beyond Claude Code
  - `vscodium/`: settings, keybindings, mcp.json, extensions.txt
  - `glissa/`: glissa dashboard config
  - `git/`: .gitconfig
  - `terminal/`: Windows Terminal settings
  - `npm-globals.txt`: global npm tools (glissa, postiz, codex, grok, biome, typescript, ...); `@openai/codex` (Codex CLI) is the external advisor CLAUDE.md routing dispatches directly; `@xai-official/grok` (Grok Build CLI) stays installed for manual use only, outside routing
  - `npm-globals-remove.txt`: retired global npm tools; apply uninstalls any of these still present so machines converge (currently oh-my-claude-sisyphus and the community grok CLI)
  - `plugins-remove.txt`: retired Claude Code plugins; apply tears down any still present so machines converge (currently oh-my-claudecode). Each entry is a `<plugin>@<marketplace>` id plus optional `shims=` and `state=` fields, and everything else is derived from the id: the `enabledPlugins` key in the rendered `settings.json`, the `plugins/installed_plugins.json` entry, the plugin's cache and data dirs, and, once no remaining installed plugin still uses that marketplace, the `extraKnownMarketplaces` key, the `plugins/known_marketplaces.json` entry, and the marketplace's cache and checkout dirs
  - `repos.txt`: project repos referenced by glissa sessions (milepost, glissa, keeplings, card-harbor); apply clones missing ones into `~/Projects`, fast-forwards existing ones, then installs each repo's node deps (npm/pnpm/yarn by lockfile) and heals a missing electron binary
  - `fonts/`: CommitMono (referenced by VSCodium settings)
  - `collect.ps1` / `apply.ps1`: sync scripts (see below); `install.sh`, `apply.sh`, and `collect.sh` are the Linux ports, driven by the same profiles and the same tracked config
  - `test/`: acceptance suites for both ports, containerised on Linux and sandboxed on Windows (see Testing the setup scripts below)

`CLAUDE.md`, `settings.json`, and `commands/commit.md` at the repo root are no longer tracked. Apply renders them from the machine's profile (`settings.json` from `settings.base.json` plus the profile overlay, the two markdown files copied straight from the profile), so the live files exist on disk but git ignores them.

Everything else in `~/.claude` (credentials, history, sessions, caches, plugins) is ignored. Plugins reinstall automatically on first launch from the `enabledPlugins` and `extraKnownMarketplaces` that end up in the rendered `settings.json`.

## Machine profiles

Each machine adopts one profile, `personal`, `work`, or `server`, and apply runs only that profile's steps.

- `personal` runs the full set: retired plugin removal, workflow config and settings render, VSCodium config, glissa, gitconfig, Codex AGENTS.md, Windows Terminal (Windows-only; not applicable on Linux), software installs, fonts, project repos, npm globals, python tools, and VSCodium extensions.
- `work` runs a focused set: retired plugin removal, workflow config and settings render, VSCodium config, fonts, the biome hook dependency, python tools, and VSCodium extensions. It skips all software installs, project repos, npm globals sync, glissa, gitconfig, and Windows Terminal.
- `server` runs the headless Linux set: retired plugin removal, workflow config and settings render, gitconfig, Codex AGENTS.md, software installs, Tailscale, Glissa server provisioning (`glissa-server`, see Glissa server below), project repos, npm globals, and python tools. It skips desktop-only VSCodium, fonts, and terminal styling. It also skips the `glissa` config-copy step, which is personal only: on a server the config comes from `glissa-server`, which seeds `~/.glissa/config.json` itself and then keeps the runtime state that accumulates there.

Retired plugin removal runs ahead of the settings render, so a machine whose render is deferred (node not yet on PATH) still has the retired keys stripped, and the render then rewrites `settings.json` authoritatively. It also runs ahead of the installs, so a config-only (`-SkipInstalls` / `--skip-installs`) sync converges too.

The work profile installs nothing beyond biome and the pip tools, so it assumes git, node, and python are already on the machine. When node is missing, apply warns instead of failing and `settings.json` gets rendered on the next run after node is installed.

Extension sync direction is per profile (`vscodiumExtensionSync` in `profile.json`): `personal` syncs exactly to `extensions.txt`, uninstalling extras; `work` is additive, installing the tracked list but never uninstalling, so machine-specific extensions (sideloaded work tooling) survive.

The chosen profile lives in a `.machine-profile` marker file at the repo root (ignored by git, so it stays local to the machine). Set it once by passing `-Profile personal`, `-Profile work`, or `-Profile server` to `install.ps1` or `apply.ps1` (`--profile` on the Linux scripts); the marker records the choice and later runs reuse it. With no marker and no flag, apply prompts for the profile on an interactive host. Each profile's exact step list is `profiles/<profile>/profile.json`.

Glissa remote mode is provisioned by the `server` profile. The script-owned Tailscale serve command points at remote port `3001`; never serve local port `3000`, because that publishes the unauthenticated local dashboard across the tailnet.

## Setup on a new machine: one command (Windows)

Paste into PowerShell (only prereq is winget, which ships with Windows 11). A browser window opens once for GitHub sign-in the first time git needs push access:

```powershell
winget install -e --id Git.Git --accept-source-agreements --accept-package-agreements; $env:Path=[Environment]::GetEnvironmentVariable('Path','Machine')+';'+[Environment]::GetEnvironmentVariable('Path','User')+';'+$env:Path; $d="$env:USERPROFILE\.claude"; New-Item -ItemType Directory -Force $d | Out-Null; git -C $d init -b master; git -C $d config remote.origin.url https://github.com/johncwaters/claude-setup.git; git -C $d config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'; git -C $d fetch origin; git -C $d checkout -f -B master origin/master; powershell -ExecutionPolicy Bypass -File "$d\setup\install.ps1"
```

For a work machine, use the same one-liner with the profile flag on the final call:

```powershell
winget install -e --id Git.Git --accept-source-agreements --accept-package-agreements; $env:Path=[Environment]::GetEnvironmentVariable('Path','Machine')+';'+[Environment]::GetEnvironmentVariable('Path','User')+';'+$env:Path; $d="$env:USERPROFILE\.claude"; New-Item -ItemType Directory -Force $d | Out-Null; git -C $d init -b master; git -C $d config remote.origin.url https://github.com/johncwaters/claude-setup.git; git -C $d config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'; git -C $d fetch origin; git -C $d checkout -f -B master origin/master; powershell -ExecutionPolicy Bypass -File "$d\setup\install.ps1" -Profile work
```

That bootstraps git, clones this repo into `~/.claude`, and runs `setup/install.ps1`, which pulls latest and hands off to `setup/apply.ps1`: config copies, then installs anything missing (git, gh, node, Claude Code, VSCodium, CommitMono fonts, project repos from `repos.txt`, npm globals, VSCodium extensions). Extensions sync exactly to `extensions.txt`; project repos clone into `~/Projects`, fast-forward on reruns, and get their node deps installed. Everything is idempotent; rerun any time.

## Setup on a new machine: one command (Linux)

Paste into a terminal. Nothing has to be installed first: `setup/install.sh` installs `git` and `curl` itself through apt-get, dnf, pacman, or zypper (with sudo when not root), then clones and applies:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/johncwaters/claude-setup/master/setup/install.sh)
```

For a work or server machine, pass the profile flag through:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/johncwaters/claude-setup/master/setup/install.sh) --profile work
bash <(curl -fsSL https://raw.githubusercontent.com/johncwaters/claude-setup/master/setup/install.sh) --profile server
```

On a box with no `curl` yet, wget substitutes:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/johncwaters/claude-setup/master/setup/install.sh)
```

Process substitution keeps stdin on the terminal so the profile prompt still works. A plain pipe has to name the profile instead, because apply refuses to guess one without a tty:

```bash
curl -fsSL https://raw.githubusercontent.com/johncwaters/claude-setup/master/setup/install.sh | bash -s -- --profile personal
```

If `git` is already there and you would rather clone by hand, the long form still works and lands in the same place:

```bash
d="$HOME/.claude"; mkdir -p "$d"; git -C "$d" init -b master; git -C "$d" config remote.origin.url https://github.com/johncwaters/claude-setup.git; git -C "$d" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'; git -C "$d" fetch origin; git -C "$d" checkout -f -B master origin/master; bash "$d/setup/install.sh"
```

`setup/install.sh` and `setup/apply.sh` are the bash ports of the two PowerShell scripts and read the same `profiles/<profile>/profile.json` step lists and the same `.machine-profile` marker, so a Linux box adopts `personal`, `work`, or `server` exactly like a Windows one. Same flags, spelled long: `--skip-installs`, `--profile personal|work|server`, `--dry-run`. Linux paths: VSCodium config to `~/.config/VSCodium/User`, glissa to `~/.glissa/config.json`, gitconfig to `~/.gitconfig`, Codex AGENTS.md to `~/.codex/AGENTS.md`, fonts to `~/.local/share/fonts` (then `fc-cache -f`), and project repos under `$HOME` with the backslashes in `repos.txt` paths translated to `/`.

Differences from Windows: system packages come from apt-get, dnf, pacman, or zypper (with sudo when not root) instead of winget; Node comes from NodeSource on apt-get and dnf, because Debian bookworm's Node 18 is too old for the glissa build, and apt calls carry a dpkg lock timeout so a background packagekitd or unattended upgrade costs a wait instead of a failed install; Windows Terminal is reported as not applicable; VSCodium installs from the GitHub releases .deb on apt-get without adding third-party repos, while other managers warn and point at https://vscodium.com/#install, and `gh` installs from apt where available or warns toward https://cli.github.com; `python-tools` retries pip with `--user --break-system-packages` for PEP 668 distros; the personal profile installs Flameshot, wl-clipboard, the Flameshot autostart entry, and COSMIC screenshot shortcuts, forcing `XDG_CURRENT_DESKTOP=sway` so COSMIC Wayland capture routes through xdg-desktop-portal; it also installs ydotool dictation paste tooling with a user daemon because Ubuntu 24.04's ydotoold socket is not configurable; and `setup/collect.sh` is the Linux collector, skipping Windows Terminal while collecting the portable config.

## Glissa server

The `server` profile provisions the glissa dashboard as a systemd user service through its `glissa-server` step. The step clones `https://github.com/johncwaters/glissa.git` into `~/Projects/glissa`, or fast-forwards an existing clone with `git pull --ff-only` and warns without touching anything when that tree is dirty or diverged. It then runs `npm ci` and `npm run build`, and seeds `~/.glissa/config.json` from `setup/glissa/config.server.example.json` only when no config is there yet, so the runtime state a live server accumulates survives every rerun. The config directory is chmodded to 700 and the file to 600.

Remote access is configured in the same step. Apply auto-detects the machine's Tailscale hostname and offers it as `remote.publicHost`, filling the seeded `CHANGEME` placeholders; on later runs it repairs drift when the tailnet name changed, and declining leaves `remote.enabled` false with no serve proxy. It renders `setup/glissa/glissa.service` into `~/.config/systemd/user/`, runs `daemon-reload` and `enable --now`, restarts the unit when either the unit file or the remote config changed (glissa reads `config.remote` only at boot), and enables linger so the service survives logout. `tailscale serve --bg` is pointed at the remote port only; serving the local port would publish the unauthenticated dashboard across the tailnet. Health probes finish the step: local `200`, remote `401`, and HTTPS against the public host.

The `glissa` CLI is a separate install. The `npm-globals` step reads `glissa=github:johncwaters/glissa` from `setup/npm-globals.txt` and installs it through `npm pack` first, because a global install straight from a git spec runs glissa's node-pty postinstall in a directory npm has already moved and dies with an ENOENT `uv_cwd`.

Updating glissa on a server is just re-running apply, which reruns the whole step (pull, `npm ci`, build, restart). There is no separate updater:

```bash
bash "$HOME/.claude/setup/install.sh"
```

The manual equivalent, when you want those four things without the rest of apply:

```bash
cd ~/Projects/glissa && git pull --ff-only && npm ci && npm run build && systemctl --user restart glissa
```

The dashboard scans the projects listed in `~/.glissa/config.json`, so those paths have to match where the `repos` step puts its clones, which is `~/Projects/<name>` (an entry reads `Projects\glissa=<url>` and the backslashes are translated on Linux). The `repos` step runs on servers, but the list it really wants, `setup/repos.txt`, is gitignored because the clone urls are private, so a fresh box falls back to the tracked `setup/repos.example.txt` and clones glissa alone. Put your own `setup/repos.txt` on the server before expecting the other project repos to arrive; a missing list is a warning, never a failure.

Append ` nodeps` to a `repos.txt` entry (`Projects\card-harbor=<url> nodeps`) to clone and sync that repo without ever running its dependency install, which is how a headless box opts out of a native build it cannot use, such as an electron app's. The Linux script honors the flag; `apply.ps1` strips it and still installs deps. One repo failing at any stage (clone, pull, branch sync, deps) warns and the loop continues to the next, and `setup/test/suite.sh` pins that.

Apply never creates or pushes a `develop` branch in a repo you do not own. Ownership is the GitHub owner segment of this checkout's own origin (`johncwaters`), and an entry whose origin names anyone else is cloned, pulled, and dep-installed as usual but reports `develop sync skipped (not your repo)`. If that owner cannot be read, every repo is treated as someone else's rather than as yours.

To pair a phone, mint a single-use URL on the server with `node ~/Projects/glissa/bin/glissa.js pair` (apply offers this at the end of the step on an interactive run) and open it on the device over the tailnet HTTPS host. `glissa pair --list` and `glissa pair --revoke <id>` manage the paired devices from there.

All of the above is pinned by `setup/test/suite.sh`: the remote config fill, the drift repair, serve targeting the remote port, unit rendering and restart-on-change, the health probes, and the GitHub-source CLI install each have assertions there, so this section describes checked behavior rather than intent.

## Re-sync an existing machine

```powershell
powershell -File $env:USERPROFILE\.claude\setup\install.ps1
```

On Linux:

```bash
bash "$HOME/.claude/setup/install.sh"
```

Pulls latest and applies. `-SkipInstalls` (`--skip-installs` on Linux) copies config only.

Sync through the install script, not a bare `git pull`. Because the rendered `CLAUDE.md`, `settings.json`, and `commands/commit.md` are no longer tracked, a plain `git pull` in `~/.claude` can drop those live files until apply regenerates them. The install script pulls and then reruns apply, which rerenders them from the machine's profile in the same pass.

## Testing the setup scripts

Both ports have an executable acceptance suite, so their behavior is checked rather than described. Each runs against a snapshot of the current working tree (uncommitted edits included), served as a local git origin, so nothing touches GitHub or the live machine config. Every assertion prints what it checked, and the suite exits non-zero when any of them fails.

Linux, in a throwaway container:

```bash
bash setup/test/run-docker.sh                  # config, flags, idempotency, collect round trip
bash setup/test/run-docker.sh --full           # adds package installs, npm globals, repo clone, and a real hook run
bash setup/test/run-docker.sh --distro fedora  # same suite against the dnf branch
bash setup/test/run-docker.sh --distro arch    # same suite against the pacman branch
```

Windows, in a sandboxed profile on the host:

```powershell
powershell -File setup\test\run-windows.ps1                    # config-only, against a temp USERPROFILE
powershell -File setup\test\run-windows.ps1 -Mode container -Full  # needs a Windows-container host
```

The Windows runner redirects `USERPROFILE`, `APPDATA`, and `LOCALAPPDATA` at the child process, and `suite.ps1` refuses to start unless it is pointed at a sandbox under the temp directory, so a host run can never write to the real profile. Install steps are refused in host mode and only run in container mode.

Container mode needs Windows 10/11 Pro or Enterprise with Docker Desktop switched to Windows containers (the Home edition ships no Hyper-V and runs Linux containers only). The runner checks the daemon's OS type before doing any work and refuses with that explanation rather than failing later inside the `servercore` pull. Container mode is therefore the one path here that has never been executed: the Linux suites and the Windows host suite are all verified by real runs, `Dockerfile.windows` is reviewed but untested.

Every script takes `--help` (`-Help` on the PowerShell ports) and rejects an unknown flag with exit 2, which the suites assert.

Linux needs Docker plus Git Bash (on Windows) or any Linux shell.

## Auth checklist (manual, once per machine)

Nothing secret syncs through this repo, so log in fresh:

- [ ] `claude` (first launch prompts for Anthropic login)
- [ ] `gh auth login` (apply offers this interactively after installing GitHub CLI; non-interactive runs still warn)
- [ ] `codex login` (Codex CLI; ChatGPT sign-in, needed for Codex routing)
- [ ] `grok login` (Grok Build CLI; grok.com sign-in, or set `XAI_API_KEY`; manual use only, not in routing)
- [ ] `claude mcp add --transport http posthog https://mcp.posthog.com/mcp -s user` (PostHog MCP; OAuth browser login on first use)
- [ ] VSCodium: re-auth MCP servers (PostHog) on first use
- [ ] Anything project-specific (.env files) stays per-repo, not here

## Publishing changes from a machine

`powershell -File ~\.claude\setup\collect.ps1` (Linux: `bash ~/.claude/setup/collect.sh`) grabs live VSCodium/glissa/git/terminal config into the repo, then add/commit/push from `~/.claude`. On a work machine collect gathers only the VSCodium config; the rest is personal only. The Linux collector skips Windows Terminal, which has no equivalent, and writes `repos.txt` paths with forward slashes; both apply scripts read either separator. Claude Code files (skills, agents, and the profile workflow files under `profiles/`) live in the repo directly; no collect step is needed for them. Edit the workflow config in `profiles/<profile>/`, not the rendered root copies, since those are regenerated by apply.
