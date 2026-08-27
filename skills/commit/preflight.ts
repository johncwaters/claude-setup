import { Git } from "./lib/git.ts";
import { repositoryGuard } from "./lib/guard.ts";
import { validateMessage } from "./lib/message.ts";
import { emit, messageInvalid, messageValid, ready, type Result } from "./lib/outcome.ts";
import { isBranchAllowed, readCommitPolicy } from "./lib/policy.ts";
import { readStdin } from "./lib/stdio.ts";
import { computeScope } from "./lib/workspace.ts";

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

function checkMessageResult(message: string): Result {
  const errors = validateMessage(message);
  if (errors.length > 0) {
    return messageInvalid({ errors });
  }
  return messageValid({});
}

function preflightResult(paths: string[]): Result {
  const git = new Git(process.cwd());
  const guard = repositoryGuard(git);
  if (guard) {
    return guard;
  }

  const branch = git.currentBranch();
  const { changed, untracked } = computeScope(git, paths);
  const { profile, policy, warning } = readCommitPolicy();

  return ready({
    branch,
    branchAllowed: isBranchAllowed(branch, policy),
    changed: [...changed].sort(),
    untracked,
    ...(profile ? { profile } : {}),
    ...(policy ? { policy } : {}),
    warnings: warning ? [warning] : [],
  });
}

const parsed = parseArguments(process.argv.slice(2));
if (parsed.checkMessage) {
  emit(checkMessageResult(await readStdin()));
}
emit(preflightResult(parsed.paths));
