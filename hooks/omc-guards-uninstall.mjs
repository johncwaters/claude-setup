#!/usr/bin/env node
/**
 * Uninstaller for the orchestration guards (ledger stop gate + spawn-contract
 * warn). Removes only the two hook entries this feature added from
 * ~/.claude/settings.json and leaves every other hook (e.g. validate-file)
 * untouched. Writes a timestamped backup next to settings.json first.
 *
 * Usage:  node C:/Users/johnw/.claude/hooks/omc-guards-uninstall.mjs
 *         node .../omc-guards-uninstall.mjs --dry-run   (show what would change)
 *
 * It does NOT delete the .mjs scripts or the docs; remove those by hand if you
 * want them gone. Re-enable later by restoring settings.json.bak-orchestration-guards
 * or re-adding the two hook entries (see omc-orchestration-guards.md).
 */

import fs from "node:fs";
import path from "node:path";
import os from "node:os";

const SETTINGS = path.join(os.homedir(), ".claude", "settings.json");
const MARKERS = ["omc-ledger-stop-gate.mjs", "omc-spawn-contract-warn.mjs"];
const dryRun = process.argv.includes("--dry-run");

function isGuardEntry(entry) {
  const hooks = (entry && entry.hooks) || [];
  return hooks.some((h) => typeof h.command === "string" && MARKERS.some((m) => h.command.includes(m)));
}

const raw = fs.readFileSync(SETTINGS, "utf8");
const cfg = JSON.parse(raw);
const hooks = cfg.hooks || {};

let removed = 0;
for (const event of Object.keys(hooks)) {
  const before = hooks[event].length;
  hooks[event] = hooks[event].filter((e) => !isGuardEntry(e));
  removed += before - hooks[event].length;
  if (hooks[event].length === 0) delete hooks[event];
}

if (removed === 0) {
  console.log("No orchestration-guard hook entries found. Nothing to do.");
  process.exit(0);
}

if (dryRun) {
  console.log(`[dry-run] would remove ${removed} guard hook entr(y/ies) from ${SETTINGS}`);
  process.exit(0);
}

const stamp = new Date().toISOString().replace(/[:.]/g, "-");
fs.writeFileSync(`${SETTINGS}.bak-${stamp}`, raw);
fs.writeFileSync(SETTINGS, JSON.stringify(cfg, null, 2) + "\n");
console.log(`Removed ${removed} guard hook entr(y/ies). Backup: ${SETTINGS}.bak-${stamp}`);
