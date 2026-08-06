#!/usr/bin/env node
/**
 * PreToolUse guard for subagent spawns (Agent / Task tool calls).
 *
 * Enforces the CLAUDE.md routing rule that every spawn pins `model`
 * explicitly and never targets fable or haiku. The session model is
 * fable, so a spawn that omits `model` silently inherits it; prose in
 * CLAUDE.md cannot block that, this hook can (docs_must_be_enforceable).
 *
 * Denies when:
 *   - `model` is missing or empty (would inherit the fable session model)
 *   - `model` names a fable or haiku tier
 *
 * Allows everything else, including subagent_type "fork": the harness
 * ignores `model` for forks, so a deny would be unactionable there.
 *
 * Fail open (shared rule in AGENTS.md): any error, malformed payload, or
 * unexpected shape MUST result in allow (exit 0, no output). Every
 * try/catch that falls through to allow is load-bearing.
 *
 * Keep it dependency-free, synchronous, and pure ASCII.
 */

import fs from "node:fs";

const SPAWN_TOOLS = new Set(["Agent", "Task"]);

const PIN_HINT =
  'Re-issue the call with an explicit model: "opus" (default coding tier) ' +
  'or "sonnet" (clearly trivial mechanical slices only).';

function allow() {
  process.exit(0);
}

function deny(reason) {
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

function readPayload() {
  try {
    return JSON.parse(fs.readFileSync(0, "utf8"));
  } catch {
    return null;
  }
}

function main() {
  const payload = readPayload();
  if (!payload || typeof payload !== "object") allow();
  if (!SPAWN_TOOLS.has(payload.tool_name)) allow();

  const input = payload.tool_input;
  if (!input || typeof input !== "object") allow();
  if (input.subagent_type === "fork") allow();

  const model =
    typeof input.model === "string" ? input.model.trim().toLowerCase() : "";
  if (model === "")
    deny(
      "Subagent spawn without an explicit model pin: omitting `model` " +
        "inherits the fable session model, which is never a spawn target. " +
        PIN_HINT
    );
  if (model.includes("fable"))
    deny(
      "fable is the session/orchestrator model only and is never a spawn " +
        "target. " + PIN_HINT
    );
  if (model.includes("haiku"))
    deny("haiku is banned on this machine, no exceptions. " + PIN_HINT);

  allow();
}

try {
  main();
} catch {
  allow();
}
