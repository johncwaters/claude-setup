#!/usr/bin/env node
/**
 * PreToolUse guard for subagent spawns (Agent / Task tool calls).
 *
 * Enforces the CLAUDE.md routing rule that every spawn pins `model`
 * explicitly. The session model is fable, so a spawn that omits `model`
 * silently inherits it and the choice of tier becomes an accident; prose
 * in CLAUDE.md cannot block that, this hook can (docs_must_be_enforceable).
 *
 * Denies when:
 *   - `model` is missing or empty (would inherit the session model)
 *
 * fable is a permitted spawn target: the routing table lists it as a
 * normal tier, so only the missing-pin case is a violation now.
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
  'Re-issue the call with an explicit model: "opus" (default coding tier), ' +
  '"fable" (top tier, for the highest-stakes judgment), "sonnet" (one-shot ' +
  'mechanical slices), or "haiku" (one-shot basics whose whole output is a ' +
  'short checkable answer).';

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
        "inherits the session model, so the tier becomes an accident " +
        "rather than a choice. " +
        PIN_HINT
    );

  allow();
}

try {
  main();
} catch {
  allow();
}
