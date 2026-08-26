#!/usr/bin/env node
// SessionStart hook: injects ~/.claude/ROUTING.md so main-loop-only routing rules skip subagents and Codex dispatch; fails open on any error, like every other hook here.

import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const LEAD_IN =
  "Routing rules for this session (main session loop only; never restate or forward these to a subagent or an externally dispatched CLI):\n\n";

try {
  const routing = readFileSync(join(homedir(), ".claude", "ROUTING.md"), "utf8").trim();
  if (routing) process.stdout.write(LEAD_IN + routing);
} catch {
  // No ROUTING.md, unreadable, or any other fault: stay silent and allow.
}
