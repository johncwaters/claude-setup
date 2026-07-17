#!/usr/bin/env node
/**
 * PreToolUse spawn-contract warn guard (Task / subagent spawns).
 *
 * Nudges toward the <subagent_prompt_contract> in CLAUDE.md by flagging a spawn
 * whose prompt is thin (too short, no explicit model, or missing the tell-tale
 * signals of an objective / output contract / boundaries).
 *
 * IMPORTANT -- THIS CANNOT BLOCK. It is a best-effort WARN only. PreToolUse
 * blocking does not work for the Task tool: exit-code-2 (and, as of writing,
 * deny) let the subagent launch anyway. See open issue
 * https://github.com/anthropics/claude-code/issues/26923 (Task ran 19/19 times
 * despite a blocking hook). REMOVAL TRIGGER: once #26923 is fixed and Task
 * honors `permissionDecision:"deny"`, this can be upgraded from warn to a real
 * gate (switch WARN_ONLY off / return deny on a thin spawn).
 *
 * On a thin spawn it emits `additionalContext` feedback (the one channel that
 * still reaches the model for a Task PreToolUse) and always ALLOWS. A well-formed
 * spawn passes silently.
 *
 * Kill switch: set OMC_SKIP_SPAWN_GUARD (any value) to disable.
 * Fail-open by design: any error or malformed input -> allow (exit 0).
 */

const MIN_PROMPT_CHARS = 400;

function allow() {
  process.exit(0); // no output => tool proceeds
}

function warn(context) {
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "allow",
        additionalContext: context,
      },
    })
  );
  process.exit(0);
}

const HAS_OUTPUT = /\b(return|output|report back|respond with|deliver|format|summar)/i;
const HAS_BOUNDARY = /\b(do not|don't|only|scope|boundar|avoid|must not|stop and)/i;

let raw = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (d) => (raw += d));
process.stdin.on("end", () => {
  if (process.env.OMC_SKIP_SPAWN_GUARD) return allow();

  let payload;
  try {
    payload = JSON.parse(raw);
  } catch {
    return allow();
  }

  const ti = payload.tool_input || {};
  const prompt = typeof ti.prompt === "string" ? ti.prompt : "";
  const hasModel = typeof ti.model === "string" && ti.model.length > 0;

  const gaps = [];
  if (prompt.trim().length < MIN_PROMPT_CHARS) {
    gaps.push(`prompt is thin (${prompt.trim().length} chars < ${MIN_PROMPT_CHARS}); add objective + context the agent can't see`);
  }
  if (!hasModel) {
    gaps.push("no explicit `model` set; pick the cheapest tier that does the slice reliably (haiku/sonnet/opus)");
  }
  if (prompt && !HAS_OUTPUT.test(prompt)) {
    gaps.push("no visible output contract; state exactly what to return and in what shape");
  }
  if (prompt && !HAS_BOUNDARY.test(prompt)) {
    gaps.push("no visible boundaries; state scope limits / don't-touch zones / when to stop and report back");
  }

  if (gaps.length === 0) return allow();

  const label = ti.subagent_type ? ` (${ti.subagent_type})` : "";
  const context = [
    `Spawn-contract check${label}: this delegation may be under-specified against <subagent_prompt_contract>.`,
    ...gaps.map((g) => `  - ${g}`),
    "This is a non-blocking reminder; the agent will still run. Consider strengthening the prompt before relying on the result.",
  ].join("\n");
  warn(context);
});
