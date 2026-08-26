#!/usr/bin/env node
// SessionStart never fires for subagents, so it is the only seam that keeps
// main-loop-only routing rules out of every spawn and out of the Codex mirror.

import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const LEAD_IN =
  "Routing rules for this session (main session loop only; never restate or forward these to a subagent or an externally dispatched CLI):\n\n";

try {
  const routing = readFileSync(join(homedir(), ".claude", "ROUTING.md"), "utf8").trim();
  if (routing) process.stdout.write(LEAD_IN + routing);
} catch {
  // Fail open like every hook here: no routing context, AGENTS.md keeps a pointer.
}
