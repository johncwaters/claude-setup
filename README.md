# claude-setup

Portable Claude Code configuration, synced via git from `~/.claude`.

## What is tracked

- `CLAUDE.md`: global instructions (OMC orchestration, routing, style rules)
- `settings.json`: model, permissions, hooks, statusline, enabled plugins
- `skills/`: custom skills (impeccable, postiz, pr-review-pipeline, omc-learned, omc-reference)
- `commands/`: custom slash commands (commit, seo-audit)
- `hooks/`: OMC guard hooks (validate-file, spawn-contract-warn, ledger-stop-gate)
- `hud/`: OMC statusline script

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

Then launch Claude Code and run `setup omc` (or `/oh-my-claudecode:omc-setup`) to finish OMC wiring.

## Syncing

Pull latest: `git -C ~/.claude pull`
Push changes: `git -C ~/.claude add -A && git -C ~/.claude commit -m "update config" && git -C ~/.claude push`
