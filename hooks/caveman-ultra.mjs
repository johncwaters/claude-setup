#!/usr/bin/env node
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

const message =
  "CAVEMAN ULTRA MODE ACTIVE. Overrides any caveman-full activation this session. Rules: all full caveman rules (drop articles/filler/pleasantries/hedging, fragments OK, short synonyms) plus ultra: abbreviate (DB/auth/config/req/res/fn/impl), strip conjunctions, arrows for causality (X -> Y), one word when one word enough. Code/commits/PRs/security warnings: write normal. User says 'normal' or 'stop caveman' to deactivate.";

process.stdout.write(message);

const cavemanFlagPath = join(homedir(), ".claude", ".caveman-active");
const pollIntervalMs = 100;
const pollDeadlineMs = 5000;

function flagContent() {
  try {
    return readFileSync(cavemanFlagPath, "utf8").trim();
  } catch {
    return null;
  }
}

function writeUltraFlag() {
  try {
    mkdirSync(dirname(cavemanFlagPath), { recursive: true });
    writeFileSync(cavemanFlagPath, "ultra");
  } catch (error) {
    process.stderr.write(`caveman-ultra: flag write failed: ${error.message}\n`);
  }
  process.exit(0);
}

// The caveman plugin's own SessionStart hook writes "full" to the flag file;
// hooks race, so wait until that write is observed (or the deadline passes)
// before overwriting with "ultra" so ultra wins regardless of hook order.
let elapsedMs = 0;
const poll = setInterval(() => {
  elapsedMs += pollIntervalMs;
  const isDeadlineReached = elapsedMs >= pollDeadlineMs;
  if (flagContent() !== "full" && !isDeadlineReached) return;
  clearInterval(poll);
  writeUltraFlag();
}, pollIntervalMs);
