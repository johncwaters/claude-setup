#!/usr/bin/env node
/**
 * Stop-hook ledger gate.
 *
 * Refuses to let the turn end while a requirements ledger still has open
 * `- [ ]` items, so decomposed work does not get silently abandoned. This is
 * the ENFORCEABLE half of the orchestration guards: the Claude Code docs list
 * `Stop` as able to block ("Prevents Claude from stopping, continues the
 * conversation"), unlike PreToolUse-vs-Task which cannot block (see the spawn
 * guard's note on issue #26923).
 *
 * Opt-in by existence: with NO ledger file present the gate does nothing, so it
 * never nags on ordinary turns. Create a ledger to arm it.
 *
 * Ledger location (first that exists): $OMC_LEDGER_PATH, then, relative to the
 * session cwd: .omc/LEDGER.md, .omc/state/LEDGER.md, .workflow/LEDGER.md,
 * LEDGER.md.
 *
 * Ledger line grammar:
 *   - [ ] open item         -> blocks the stop
 *   - [x] completed item    -> passes
 *   - [~] deferred: reason  -> passes (explicit, visible deferral)
 *
 * Loop safety: by default the gate blocks only when it is NOT already the reason
 * the turn is continuing (`stop_hook_active` false), giving exactly one forced
 * continuation per stop attempt so a stuck turn cannot loop forever. Set
 * OMC_LEDGER_GATE_STRICT=1 to block on every stop attempt regardless (stronger,
 * but a turn that can neither finish nor defer its items will loop until the
 * user interrupts).
 *
 * Kill switch: set OMC_SKIP_LEDGER_GATE (any value) to disable entirely.
 *
 * Fail-open by design: any error, unreadable ledger, or malformed input ->
 * allow the stop (exit 0, no output).
 */

import fs from "node:fs";
import path from "node:path";

function allow() {
  process.exit(0); // no output => stop proceeds
}

function block(reason) {
  process.stdout.write(JSON.stringify({ decision: "block", reason }));
  process.exit(0);
}

function findLedger(cwd) {
  const candidates = [
    process.env.OMC_LEDGER_PATH,
    path.join(cwd, ".omc", "LEDGER.md"),
    path.join(cwd, ".omc", "state", "LEDGER.md"),
    path.join(cwd, ".workflow", "LEDGER.md"),
    path.join(cwd, "LEDGER.md"),
  ].filter(Boolean);
  for (const p of candidates) {
    try {
      if (fs.existsSync(p) && fs.statSync(p).isFile()) return p;
    } catch {}
  }
  return null;
}

const OPEN_ITEM = /^\s*[-*]\s*\[ \]\s+(.+?)\s*$/;

function openItems(text) {
  const out = [];
  for (const line of text.split(/\r?\n/)) {
    const m = OPEN_ITEM.exec(line);
    if (m) out.push(m[1]);
  }
  return out;
}

let raw = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (d) => (raw += d));
process.stdin.on("end", () => {
  if (process.env.OMC_SKIP_LEDGER_GATE) return allow();

  let payload;
  try {
    payload = JSON.parse(raw);
  } catch {
    return allow();
  }

  const strict = !!process.env.OMC_LEDGER_GATE_STRICT;
  if (payload.stop_hook_active && !strict) return allow(); // one forced pass; avoid loops

  const cwd = payload.cwd || process.cwd();
  const ledger = findLedger(cwd);
  if (!ledger) return allow(); // opt-in: no ledger, no gate

  let open;
  try {
    open = openItems(fs.readFileSync(ledger, "utf8"));
  } catch {
    return allow();
  }
  if (open.length === 0) return allow();

  const shown = open.slice(0, 8).map((t) => `  - [ ] ${t}`);
  const more = open.length > shown.length ? `\n  ...and ${open.length - shown.length} more` : "";
  const reason = [
    `Ledger gate: ${open.length} open item(s) remain in ${path.relative(cwd, ledger) || ledger}.`,
    "Resolve each before ending the turn: finish it and mark `- [x]`, or if it is genuinely out of scope mark `- [~] deferred: <reason>`.",
    "Open items:",
    shown.join("\n") + more,
    "(Disable temporarily with OMC_SKIP_LEDGER_GATE=1.)",
  ].join("\n");
  block(reason);
});
