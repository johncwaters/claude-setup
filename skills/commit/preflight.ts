import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Git } from "./lib/git.ts";
import { validateMessage } from "./lib/message.ts";
import {
  detachedHead,
  emit,
  messageInvalid,
  notARepo,
  operationInProgress,
  ready,
  type Result,
} from "./lib/outcome.ts";
import { computeScope, guardBranches, readStdin } from "./lib/workspace.ts";

const IN_PROGRESS_MARKERS = ["MERGE_HEAD", "REBASE_HEAD", "CHERRY_PICK_HEAD"] as const;

type Arguments = { paths: string[]; checkMessage: boolean };

function parseArguments(argv: string[]): Arguments {
  const parsed: Arguments = { paths: [], checkMessage: false };
  let collectingPaths = false;
  for (const argument of argv) {
    if (argument === "--check-message") {
      parsed.checkMessage = true;
      collectingPaths = false;
      continue;
    }
    if (argument === "--paths") {
      collectingPaths = true;
      continue;
    }
    if (argument.startsWith("--")) {
      throw new Error(`unknown flag ${argument}`);
    }
    if (!collectingPaths) {
      throw new Error(`unexpected argument ${argument}`);
    }
    parsed.paths.push(argument);
  }
  return parsed;
}

function claudeRoot(): string {
  return path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
}

type ProfilePolicy = { profile?: string; policy?: Record<string, unknown>; warning?: string };

function readProfilePolicy(): ProfilePolicy {
  const root = claudeRoot();
  const markerPath = path.join(root, ".machine-profile");
  if (!fs.existsSync(markerPath)) {
    return { warning: `no machine profile marker at ${markerPath}; run setup/apply to write one` };
  }
  const profile = fs.readFileSync(markerPath, "utf8").trim().toLowerCase();
  const policyPath = path.join(root, "profiles", profile, "commit-policy.json");
  if (!fs.existsSync(policyPath)) {
    return { profile, warning: `no commit policy at ${policyPath}` };
  }
  try {
    const policy = JSON.parse(fs.readFileSync(policyPath, "utf8")) as Record<string, unknown>;
    return { profile, policy };
  } catch (error) {
    return { profile, warning: `could not parse ${policyPath}: ${String(error)}` };
  }
}

function checkMessageResult(message: string): Result {
  const errors = validateMessage(message);
  if (errors.length > 0) {
    return messageInvalid({ errors });
  }
  return ready({ branch: "", branchAllowed: true, changed: [], untracked: [] });
}

function preflightResult(paths: string[]): Result {
  const git = new Git(process.cwd());
  if (!git.isInsideWorkTree()) {
    return notARepo({});
  }
  const branch = git.currentBranch();
  if (branch === "HEAD") {
    return detachedHead({});
  }
  for (const marker of IN_PROGRESS_MARKERS) {
    if (git.verifyRef(marker)) {
      return operationInProgress({ operation: marker });
    }
  }

  const { changed, untracked } = computeScope(git, paths);
  const { profile, policy, warning } = readProfilePolicy();
  const warnings = warning ? [warning] : [];

  return ready({
    branch,
    branchAllowed: guardBranches(policy).every((forbidden) => forbidden !== branch),
    changed: [...changed].sort(),
    untracked,
    ...(profile ? { profile } : {}),
    ...(policy ? { policy } : {}),
    warnings,
  });
}

async function main(): Promise<never> {
  const parsed = parseArguments(process.argv.slice(2));
  if (parsed.checkMessage) {
    return emit(checkMessageResult(await readStdin()));
  }
  return emit(preflightResult(parsed.paths));
}

await main();
