#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// Statusline HUD, OMC-style formatting. Claude Code pipes a JSON payload on
// stdin; print one line. Payload fields used: model.{id,display_name},
// context_window.{used_percentage,total_input_tokens,context_window_size},
// rate_limits.{five_hour,seven_day}.{used_percentage,resets_at}.
// Fail open: any error renders whatever is known, never crashes the statusline.

const RESET = "\x1b[0m";
const DIM = "\x1b[2m";
const CYAN = "\x1b[36m";
const GREEN = "\x1b[32m";
const YELLOW = "\x1b[33m";
const RED = "\x1b[31m";
const ORANGE = "\x1b[38;5;172m";

// OMC thresholds: rate limits warn at 70, critical at 90;
// context warns at 70, suggests compaction at 80, critical at 85.
function limitColor(pct) {
  if (pct >= 90) return RED;
  if (pct >= 70) return YELLOW;
  return GREEN;
}

function contextStyle(pct) {
  if (pct >= 85) return { color: RED, suffix: " CRITICAL" };
  if (pct >= 80) return { color: YELLOW, suffix: " COMPRESS?" };
  if (pct >= 70) return { color: YELLOW, suffix: "" };
  return { color: GREEN, suffix: "" };
}

function clampPct(pct) {
  return Math.min(100, Math.max(0, Math.round(pct)));
}

function parseResetsAt(raw) {
  if (raw === null || raw === undefined) return null;
  if (typeof raw === "number") {
    // epoch seconds vs milliseconds
    const ms = raw > 1e12 ? raw : raw * 1000;
    return new Date(ms);
  }
  const d = new Date(raw);
  return Number.isNaN(d.getTime()) ? null : d;
}

// OMC duration format: 2d5h above a day, else 3h42m.
function fmtReset(date) {
  const diffMs = date.getTime() - Date.now();
  if (diffMs <= 0) return null;
  const totalMin = Math.floor(diffMs / 60000);
  const totalH = Math.floor(totalMin / 60);
  const days = Math.floor(totalH / 24);
  if (days > 0) return `${days}d${totalH % 24}h`;
  return `${totalH}h${totalMin % 60}m`;
}

function limitPart(label, limit) {
  if (!limit || typeof limit.used_percentage !== "number") return null;
  const pct = clampPct(limit.used_percentage);
  let part = `${DIM}${label}:${RESET}${limitColor(pct)}${pct}%${RESET}`;
  const resetDate = parseResetsAt(limit.resets_at);
  const reset = resetDate ? fmtReset(resetDate) : null;
  if (reset) part += ` ${DIM}(${reset})${RESET}`;
  return part;
}

function fmtTokens(n) {
  if (typeof n !== "number") return null;
  if (n >= 1000000) return `${(n / 1000000).toFixed(n % 1000000 === 0 ? 0 : 1)}M`;
  if (n >= 1000) return `${Math.round(n / 1000)}k`;
  return String(n);
}

const KNOWN_CAVEMAN_MODES = new Set([
  "lite", "full", "ultra", "wenyan", "wenyan-lite", "wenyan-full", "wenyan-ultra",
  "commit", "review", "compress",
]);

function cavemanPart() {
  try {
    const mode = readFileSync(join(homedir(), ".claude", ".caveman-active"), "utf8").trim();
    if (mode === "full" || !KNOWN_CAVEMAN_MODES.has(mode)) return `${ORANGE}[CAVEMAN]${RESET}`;
    return `${ORANGE}[CAVEMAN:${mode.toUpperCase()}]${RESET}`;
  } catch {
    return null;
  }
}

function render(payload) {
  const parts = [];

  const model = payload.model || {};
  const name = model.display_name || model.id;
  if (name) {
    let seg = `${CYAN}Model: ${name}${RESET}`;
    const effort = payload.effort && payload.effort.level;
    if (effort) seg += ` ${DIM}(${effort})${RESET}`;
    parts.push(seg);
  }

  const rl = payload.rate_limits || {};
  const limits = [limitPart("5h", rl.five_hour), limitPart("wk", rl.seven_day)].filter(Boolean);
  if (limits.length > 0) parts.push(limits.join(" "));

  const cw = payload.context_window || {};
  if (typeof cw.used_percentage === "number") {
    const pct = clampPct(cw.used_percentage);
    const { color, suffix } = contextStyle(pct);
    let seg = `${DIM}ctx:${RESET}${color}${pct}%${suffix}${RESET}`;
    const used = fmtTokens(cw.total_input_tokens);
    const size = fmtTokens(cw.context_window_size);
    if (used && size) seg += ` ${DIM}(${used}/${size})${RESET}`;
    parts.push(seg);
  }

  const caveman = cavemanPart();
  if (caveman) parts.push(caveman);

  return parts.join(`${DIM} | ${RESET}`);
}

let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  input += chunk;
});
process.stdin.on("end", () => {
  try {
    process.stdout.write(render(JSON.parse(input)));
  } catch {
    process.stdout.write("");
  }
});
