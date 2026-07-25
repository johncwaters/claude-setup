#!/usr/bin/env node
/**
 * PreToolUse validator for Write / Edit / MultiEdit.
 *
 * Works out the FINAL content a tool call would write and DENIES the call
 * before anything touches disk when the result is malformed. Stops corrupted
 * JSON and files with stray invalid/control characters from ever being saved.
 * (PreToolUse is the only hook that can block a write -- PostToolUse fires
 * after the bytes already hit disk.)
 *
 * On rejection it emits strong, located, actionable feedback (what / where
 * line:col / why / how to fix). The allow/deny DECISION comes from a fast
 * stdin pass; on a Biome-type failure the precise message is HARVESTED from a
 * throwaway temp-file `biome check --reporter=json` run (Biome suppresses
 * located diagnostics on stdin but emits them for real files). Harvest is
 * message-only and pure fail-soft: it can never change the decision.
 *
 * Validation engines (`format` subcommands used as pure syntax gates):
 *   - Biome  -> JSON(C), JS, TS, JSX, CSS  (`biome format` decides; `biome check` explains)
 *   - Ruff   -> Python via `python -m ruff format`
 *   - Dart   -> Flutter/Dart via `dart format` (~0.2s; the heaviest engine -- Dart VM startup)
 *   - inline -> reject NUL, U+FFFD, stray control chars in any text file
 *   - inline -> reject a newly inserted em dash, en dash, or ellipsis
 *               (insertion-only scan; see dashCharError)
 *   - JSON   -> JSON.parse fallback when Biome can't be located
 *
 * Fail-open by design: if the hook errors, can't read the content, or an engine
 * is missing, it ALLOWS the write (exit 0, no output). Fail-open governs the
 * DECISION engine's availability -- NOT message harvest: once the decision is
 * deny, a harvest error keeps the deny with a generic message, never allow.
 * Point BIOME_BIN at a biome launcher to override discovery.
 */

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

const TEXT_EXTS = new Set([
  ".json", ".jsonc", ".js", ".mjs", ".cjs", ".ts", ".tsx", ".jsx", ".mts", ".cts",
  ".py", ".dart", ".md", ".txt", ".yml", ".yaml", ".toml", ".css", ".html",
  ".sh", ".env", ".xml", ".svg",
]);

// Extensions Biome can parse (matched against the stdin filename it expects).
const BIOME_EXTS = new Set([
  ".json", ".jsonc", ".js", ".mjs", ".cjs", ".ts", ".mts", ".cts", ".tsx", ".jsx", ".css",
]);

const FIX_CTRL =
  "Remove the character (it usually comes from a bad copy-paste or a non-UTF-8 source), re-type the affected text, and save as UTF-8.";

const DASH_CHAR_NAMES = {
  0x2014: "em dash (U+2014)",
  0x2013: "en dash (U+2013)",
  0x2026: "ellipsis (U+2026)",
};

const FIX_DASH =
  "Replace the em dash / en dash with an ASCII hyphen, or rephrase using a comma, colon, or parentheses.";
const FIX_ELLIPSIS = "Replace the ellipsis character with three ASCII dots (...).";

function allow() {
  process.exit(0); // no output => tool proceeds
}

// r: { where?: string, why: string, fix?: string }
function deny(filePath, r) {
  const reason = [
    `File-format guard blocked this write to ${path.basename(filePath)}.`,
    r.where ? `Where: ${r.where}` : null,
    `Why: ${r.why}`,
    r.fix ? `Fix: ${r.fix}` : null,
    "(Only syntax/format and invalid characters are gated here, not type or lint errors.)",
  ]
    .filter(Boolean)
    .join("\n");
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: reason,
      },
    })
  );
  process.exit(0);
}

function applyEdit(text, oldStr, newStr, replaceAll) {
  if (oldStr === undefined) return text;
  if (replaceAll) return text.split(oldStr).join(newStr ?? "");
  const i = text.indexOf(oldStr);
  if (i === -1) return text; // tool would fail anyway; don't second-guess
  return text.slice(0, i) + (newStr ?? "") + text.slice(i + oldStr.length);
}

// Final content a tool call would write, or undefined for tools we don't guard.
// Prefers an explicit `content` field (Write, and any payload that ships the
// resulting text); otherwise replays the edit(s) over the current file.
function reconstruct(ti, filePath) {
  if (typeof ti.content === "string") return ti.content;
  if (!ti.edits && ti.old_string === undefined) return undefined;
  const orig = fs.existsSync(filePath) ? fs.readFileSync(filePath, "utf8") : "";
  if (ti.edits) {
    return ti.edits.reduce((c, e) => applyEdit(c, e.old_string, e.new_string, e.replace_all), orig);
  }
  return applyEdit(orig, ti.old_string, ti.new_string, ti.replace_all);
}

// 1-based line/column for a string index.
function posOf(content, index) {
  let line = 1;
  let col = 1;
  const end = Math.min(index, content.length);
  for (let i = 0; i < end; i++) {
    if (content.charCodeAt(i) === 0x0a) {
      line++;
      col = 1;
      continue;
    }
    col++;
  }
  return { line, column: col };
}

// Canonical "line N, column M" phrase. Single source of truth -- the README and
// AGENTS.md assert this exact wording, so every locator formats through here.
function loc(line, column) {
  return `line ${line}, column ${column}`;
}

// Scans text char-by-char; classify(code) returns a { why, fix } descriptor
// for a banned code point or null. Locates the first hit as line:col relative
// to the start of `text`.
function charScanError(text, classify) {
  for (let i = 0; i < text.length; i++) {
    const hit = classify(text.charCodeAt(i));
    if (!hit) continue;
    const { line, column } = posOf(text, i);
    return { where: loc(line, column), ...hit };
  }
  return null;
}

function classifyControlChar(c) {
  // Allowed whitespace controls: tab(0x09) LF(0x0A) FF(0x0C) CR(0x0D).
  // Forbidden: other C0 (<=0x1F), DEL+C1 (0x7F-0x9F), and U+FFFD.
  if (c >= 0x20 && c < 0x7f) return null; // printable ASCII: never a control char
  const allowed = c === 0x09 || c === 0x0a || c === 0x0c || c === 0x0d;
  const bad = c === 0xfffd || (c <= 0x1f && !allowed) || (c >= 0x7f && c <= 0x9f);
  if (!bad) return null;
  if (c === 0x00) return { why: "contains a NUL byte (U+0000)", fix: FIX_CTRL };
  if (c === 0xfffd) {
    return {
      why: "contains the Unicode replacement character (U+FFFD), a sign of broken/mis-decoded encoding",
      fix: "The text was decoded with the wrong encoding. Re-read the source and re-type the affected text, then save as UTF-8.",
    };
  }
  const hex = c.toString(16).toUpperCase().padStart(4, "0");
  return { why: `contains a stray control character (U+${hex})`, fix: FIX_CTRL };
}

function classifyDashChar(c) {
  const name = DASH_CHAR_NAMES[c];
  if (!name) return null;
  const fix = c === 0x2026 ? FIX_ELLIPSIS : FIX_DASH;
  return { why: `introduces a banned ${name} character`, fix };
}

function controlCharError(content) {
  return charScanError(content, classifyControlChar);
}

function dashLiteralError(text) {
  return charScanError(text, classifyDashChar);
}

// Checks only the text a tool call would INSERT, never the reconstructed
// full file -- editing a file that already has a stray dash/ellipsis
// elsewhere must not be blocked, only a newly introduced one.
function dashCharError(ti) {
  if (!ti) return null;
  if (typeof ti.content === "string") return dashLiteralError(ti.content);
  if (Array.isArray(ti.edits)) {
    for (let idx = 0; idx < ti.edits.length; idx++) {
      const newStr = ti.edits[idx] && ti.edits[idx].new_string;
      if (typeof newStr !== "string") continue;
      const err = dashLiteralError(newStr);
      if (!err) continue;
      return { ...err, where: `edit ${idx + 1}, ${err.where}` };
    }
    return null;
  }
  if (typeof ti.new_string === "string") return dashLiteralError(ti.new_string);
  return null;
}

function exists(p) {
  try {
    return !!p && fs.existsSync(p);
  } catch {
    return false;
  }
}

// How to invoke biome, as [bin, ...prefixArgs]. Honors BIOME_BIN, else the
// npm-global install. Prefers the platform exe (run directly, fast) whose
// package name is deterministic -- `@biomejs/cli-<platform>-<arch>` matches
// Node's process.platform/arch -- so no directory globbing is needed. Falls
// back to the portable JS launcher (run via node) only if the exe is absent.
function biomeCmd() {
  if (exists(process.env.BIOME_BIN)) return [process.env.BIOME_BIN];
  const root = path.join(process.env.APPDATA || "", "npm", "node_modules", "@biomejs", "biome");
  const win = process.platform === "win32";
  const exe = path.join(
    root, "node_modules", "@biomejs",
    `cli-${process.platform}-${process.arch}`, win ? "biome.exe" : "biome"
  );
  if (exists(exe)) return [exe];
  const shim = path.join(root, "bin", "biome");
  return exists(shim) ? [process.execPath, shim] : null;
}

const SPAWN_OPTS = {
  encoding: "utf8",
  timeout: 10000,
  windowsHide: true,
  maxBuffer: 16 * 1024 * 1024,
};

function runStdin(bin, args, input) {
  return spawnSync(bin, args, { ...SPAWN_OPTS, input });
}

function validateJson(content) {
  try {
    JSON.parse(content);
    return null;
  } catch (e) {
    const m = /line (\d+) column (\d+)/.exec(e.message);
    return {
      where: m ? loc(m[1], m[2]) : null,
      why: "invalid JSON: " + e.message,
      fix: "Check for a trailing comma, an unquoted key, a missing or extra brace/bracket, or an unterminated string near the reported position.",
    };
  }
}

// Message-only. Writes the failing content to an isolated temp file (named with
// the real basename so Biome's parser/JSONC selection matches the decision
// path) and harvests the located parse diagnostic. Pure fail-soft: returns null
// on any anomaly (no parse diagnostic, parse success = decision divergence,
// throw, timeout, unreadable reporter output). Never surfaces a lint rule.
function harvestBiomeDiagnostic(content, filePath, cmd) {
  if (!cmd) return null;
  let dir = null;
  try {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), "ccfmt-"));
    const f = path.join(dir, path.basename(filePath));
    fs.writeFileSync(f, content);
    const [bin, ...pre] = cmd;
    const r = spawnSync(bin, [...pre, "check", "--reporter=json", "--max-diagnostics=10", f], SPAWN_OPTS);
    const out = String(r.stdout || "");
    const at = out.indexOf("{");
    if (at < 0) return null;
    const j = JSON.parse(out.slice(at));
    const d = (j.diagnostics || []).find((x) => x && x.category === "parse");
    if (!d) return null; // parsed OK (divergence) or lint-only -> no leak
    const start = d.location && d.location.start;
    const where = start ? loc(start.line, start.column) : null;
    const why = typeof d.message === "string" ? d.message : String(d.message || "parse error");
    let fix = null;
    for (const a of d.advices || []) {
      const t = a && typeof a.text === "string" ? a.text.trim() : null;
      if (t && t !== why) {
        fix = t;
        break;
      }
    }
    return { where, why: why.replace(/\s+$/, ""), fix };
  } catch {
    return null;
  } finally {
    if (dir) {
      try {
        fs.rmSync(dir, { recursive: true, force: true });
      } catch {}
    }
  }
}

function validateWithBiome(content, ext, filePath) {
  const cmd = biomeCmd();
  const jsonFallback = () => (ext === ".json" ? validateJson(content) : null);
  if (!cmd) return jsonFallback(); // fail open / json fallback
  const [bin, ...pre] = cmd;
  const r = runStdin(bin, [...pre, "format", `--stdin-file-path=${path.basename(filePath)}`], content);
  if (r.error) return jsonFallback(); // couldn't spawn
  if (r.status === 0) return null; // valid
  // A project biome.json can disable the formatter outright (formatter.enabled=false).
  // Biome then exits 1 ("formatter is currently disabled") WITHOUT parsing, which is
  // not a syntax verdict: fall back / fail open, never deny.
  const out = [r.stderr || "", r.stdout || ""].join(" ");
  if (out.includes("formatter is currently disabled")) return jsonFallback();
  const harvested = harvestBiomeDiagnostic(content, filePath, cmd);
  if (harvested) return harvested;
  const label = ext === ".json" || ext === ".jsonc" ? "JSON" : ext.slice(1).toUpperCase();
  return {
    where: null,
    why: `invalid ${label} syntax (the file would not parse)`,
    fix: "Check near your last edit for an unbalanced bracket, brace, parenthesis, quote, or a stray/missing comma.",
  };
}

function validatePython(content) {
  const r = runStdin("python", ["-m", "ruff", "format", "--stdin-filename", "f.py", "-"], content);
  if (r.error || r.status === 0) return null; // no python/ruff or valid -> allow
  const err = (r.stderr || r.stdout || "").trim();
  // python present but ruff not installed: engine absent, not a parse failure.
  // Fail open per the decision-engine contract (a missing engine must never deny).
  if (/No module named ['"]?ruff/.test(err)) return null;
  const m = /Failed to parse [^\s:]*:(\d+):(\d+):\s*(.*)/.exec(err);
  if (m) {
    return {
      where: loc(m[1], m[2]),
      why: "invalid Python: " + m[3].trim(),
      fix: "Check for a missing parenthesis, colon, or comma, or a bad indentation near the reported position.",
    };
  }
  return {
    where: null,
    why: "invalid Python: " + (err.split("\n").pop() || "parse error"),
    fix: "Check for a syntax error near your last edit.",
  };
}

// Resolve a directly-spawnable dart executable. Honors DART_BIN, else scans
// PATH for either a standalone Dart SDK (`dart.exe` in a bin dir) or a Flutter
// SDK (whose `dart` is a .bat wrapper; the real exe lives under
// `cache/dart-sdk/bin`). Returns null if none found (-> fail open for .dart).
function dartBin() {
  if (exists(process.env.DART_BIN)) return process.env.DART_BIN;
  const exe = process.platform === "win32" ? "dart.exe" : "dart";
  for (const dir of (process.env.PATH || "").split(path.delimiter)) {
    if (!dir) continue;
    const direct = path.join(dir, exe);
    if (exists(direct)) return direct;
    const flutter = path.join(dir, "cache", "dart-sdk", "bin", exe);
    if (exists(flutter)) return flutter;
  }
  return null;
}

function validateDart(content) {
  const bin = dartBin();
  if (!bin) return null; // no dart -> fail open
  const r = runStdin(bin, ["format", "--output=none", "--stdin-name=main.dart"], content);
  // dart format exits 65 specifically on a parse failure. Anything else (0 =
  // valid, spawn error, other non-zero tool error) -> allow / fail open.
  if (r.error || r.status !== 65) return null;
  const out = (r.stderr || r.stdout || "").trim();
  const m = /line (\d+), column (\d+) of [^:]*:\s*(.*)/.exec(out);
  if (m) {
    return {
      where: loc(m[1], m[2]),
      why: "invalid Dart: " + m[3].trim(),
      fix: "Check for a missing semicolon, brace, parenthesis, or bracket near the reported position.",
    };
  }
  return {
    where: null,
    why: "invalid Dart (the file would not parse)",
    fix: "Check near your last edit for an unbalanced brace, parenthesis, bracket, or a missing semicolon.",
  };
}

function validate(filePath, content, ti) {
  const ext = path.extname(filePath).toLowerCase();
  // Control-char scan runs before Biome/Ruff for text files, so a file with both
  // a control char and a syntax error reports the control char (deterministic).
  if (TEXT_EXTS.has(ext)) {
    const cc = controlCharError(content);
    if (cc) return cc;
    const dash = dashCharError(ti);
    if (dash) return dash;
  }
  if (ext === ".py") return validatePython(content);
  if (ext === ".dart") return validateDart(content);
  if (BIOME_EXTS.has(ext)) return validateWithBiome(content, ext, filePath);
  return null;
}

// ---------- entry ----------

let raw = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (d) => (raw += d));
process.stdin.on("end", () => {
  let payload;
  try {
    payload = JSON.parse(raw);
  } catch {
    return allow();
  }

  const ti = payload.tool_input || {};
  const filePath = ti.file_path || ti.filePath;
  if (!filePath) return allow();

  let content;
  try {
    content = reconstruct(ti, filePath);
  } catch {
    return allow(); // can't read content -> don't block
  }
  if (content === undefined) return allow(); // unguarded tool

  let error = null;
  try {
    error = validate(filePath, content, ti);
  } catch {
    return allow(); // validator crash -> don't block
  }

  if (error) return deny(filePath, error);
  allow();
});
