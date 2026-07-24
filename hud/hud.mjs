#!/usr/bin/env node
// Statusline HUD. Claude Code pipes a JSON payload on stdin; print one line.
// Payload fields used: model.{id,display_name}, context_window.{used_percentage,
// total_input_tokens,context_window_size}, rate_limits.{five_hour,seven_day}.
// Fail open: any error renders whatever is known, never crashes the statusline.

const RESET = "\x1b[0m";
const DIM = "\x1b[2m";
const CYAN = "\x1b[36m";
const GREEN = "\x1b[32m";
const YELLOW = "\x1b[33m";
const RED = "\x1b[31m";

function pctColor(pct) {
  if (pct >= 85) return RED;
  if (pct >= 60) return YELLOW;
  return GREEN;
}

function fmtPct(pct) {
  const rounded = Math.round(pct);
  return `${pctColor(rounded)}${rounded}%${RESET}`;
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

function fmtCountdown(date) {
  const ms = date.getTime() - Date.now();
  if (ms <= 0) return "now";
  const totalMin = Math.round(ms / 60000);
  const h = Math.floor(totalMin / 60);
  const m = totalMin % 60;
  if (h >= 48) return `${Math.round(h / 24)}d`;
  if (h > 0) return `${h}h${String(m).padStart(2, "0")}m`;
  return `${m}m`;
}

function fmtWeekday(date) {
  const days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  const now = new Date();
  const sameDay = date.toDateString() === now.toDateString();
  if (sameDay) return fmtCountdown(date);
  return `${days[date.getDay()]} ${date.getHours()}:${String(date.getMinutes()).padStart(2, "0")}`;
}

function limitSegment(label, limit, fmtReset) {
  if (!limit || typeof limit.used_percentage !== "number") return null;
  let seg = `${DIM}${label}${RESET} ${fmtPct(limit.used_percentage)}`;
  const resetDate = parseResetsAt(limit.resets_at);
  if (resetDate) seg += ` ${DIM}resets ${fmtReset(resetDate)}${RESET}`;
  return seg;
}

function fmtTokens(n) {
  if (typeof n !== "number") return null;
  if (n >= 1000000) return `${(n / 1000000).toFixed(n % 1000000 === 0 ? 0 : 1)}M`;
  if (n >= 1000) return `${Math.round(n / 1000)}k`;
  return String(n);
}

function render(payload) {
  const parts = [];

  const model = payload.model || {};
  const name = model.display_name || model.id;
  if (name) parts.push(`${CYAN}${name}${RESET}`);

  const cw = payload.context_window || {};
  if (typeof cw.used_percentage === "number") {
    let seg = `${DIM}ctx${RESET} ${fmtPct(cw.used_percentage)}`;
    const used = fmtTokens(cw.total_input_tokens);
    const size = fmtTokens(cw.context_window_size);
    if (used && size) seg += ` ${DIM}${used}/${size}${RESET}`;
    parts.push(seg);
  }

  const rl = payload.rate_limits || {};
  const fiveH = limitSegment("5h", rl.five_hour, fmtCountdown);
  if (fiveH) parts.push(fiveH);
  const week = limitSegment("wk", rl.seven_day, fmtWeekday);
  if (week) parts.push(week);

  return parts.join(` ${DIM}|${RESET} `);
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
