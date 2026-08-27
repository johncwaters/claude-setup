import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { findWorktreeForBranch } from "../lib/workspace.ts";
import {
  cleanup,
  cloneRepo,
  commitFile,
  gitOutput,
  land,
  makeBareOrigin,
  makeRepo,
  runGit,
  tryGit,
  VALID_MESSAGE,
  writeCommitMsgRejectHook,
  writeFile,
} from "./helpers.ts";

type PromotionSetup = { origin: string; seed: string; local: string };

function seedOriginWithBranches(branches: string[]): { origin: string; seed: string } {
  const origin = makeBareOrigin();
  const seed = makeRepo();
  runGit(seed, ["remote", "add", "origin", origin]);
  commitFile(seed, "base.txt", "base\n", "init");
  runGit(seed, ["push", "-q", "-u", "origin", "main"]);
  for (const branch of branches) {
    runGit(seed, ["checkout", "-q", "-b", branch]);
    runGit(seed, ["push", "-q", "-u", "origin", branch]);
  }
  return { origin, seed };
}

function makePromotionSetup(): PromotionSetup {
  const { origin, seed } = seedOriginWithBranches(["develop", "feature"]);
  const local = cloneRepo(origin);
  runGit(local, ["branch", "develop", "origin/develop"]);
  runGit(local, ["checkout", "-q", "-b", "feature", "origin/feature"]);
  return { origin, seed, local };
}

function writeOriginHook(origin: string, name: string, body: string): void {
  const hookPath = path.join(origin, "hooks", name);
  fs.writeFileSync(hookPath, body, "utf8");
  fs.chmodSync(hookPath, 0o755);
}

function driftingMainPreReceiveHook(): string {
  return [
    "#!/bin/sh",
    "while read old new ref_name; do",
    '  if [ "$ref_name" != "refs/heads/main" ]; then',
    "    continue",
    "  fi",
    '  count_file="hooks/main-drift-count"',
    "  count=0",
    '  [ -f "$count_file" ] && count=$(cat "$count_file")',
    "  count=$((count + 1))",
    '  printf "%s" "$count" > "$count_file"',
    '  if [ "$count" -gt 1 ]; then',
    "    continue",
    "  fi",
    '  tree=$(git rev-parse main^{tree})',
    '  new_commit=$(GIT_AUTHOR_NAME="Test User" GIT_AUTHOR_EMAIL="test@example.com" ' +
      'GIT_COMMITTER_NAME="Test User" GIT_COMMITTER_EMAIL="test@example.com" ' +
      'git commit-tree "$tree" -p "$(git rev-parse main)" -m "origin drift")',
    '  git update-ref refs/heads/main "$new_commit"',
    '  echo "rejected: retry after fetch" >&2',
    "  exit 1",
    "done",
    "exit 0",
    "",
  ].join("\n");
}

// An update hook, not pre-receive: it rejects develop alone, so mainline fails
// as atomic collateral rather than as a cause, which is the case the replay is for.
function driftDevelopOnceUpdateHook(driftSha: string): string {
  return [
    "#!/bin/sh",
    'ref_name="$1"',
    'if [ "$ref_name" != "refs/heads/develop" ]; then',
    "  exit 0",
    "fi",
    'count_file="hooks/develop-drift-count"',
    "count=0",
    '[ -f "$count_file" ] && count=$(cat "$count_file")',
    "count=$((count + 1))",
    'printf "%s" "$count" > "$count_file"',
    'if [ "$count" -gt 1 ]; then',
    "  exit 0",
    "fi",
    `env -u GIT_QUARANTINE_PATH git update-ref refs/heads/develop ${driftSha}`,
    'echo "rejected: retry after fetch" >&2',
    "exit 1",
    "",
  ].join("\n");
}

function oneTimeRejectUpdateHook(branch: string): string {
  return [
    "#!/bin/sh",
    'ref_name="$1"',
    `if [ "$ref_name" != "refs/heads/${branch}" ]; then`,
    "  exit 0",
    "fi",
    `count_file="hooks/${branch}-update-count"`,
    "count=0",
    '[ -f "$count_file" ] && count=$(cat "$count_file")',
    "count=$((count + 1))",
    'printf "%s" "$count" > "$count_file"',
    'if [ "$count" -le 1 ]; then',
    `  echo "rejecting ${branch} once" >&2`,
    "  exit 1",
    "fi",
    "exit 0",
    "",
  ].join("\n");
}

test("findWorktreeForBranch skips detached and bare blocks", () => {
  const porcelain = [
    "worktree /repo/main",
    "HEAD abc123",
    "branch refs/heads/develop",
    "",
    "worktree /repo/detached",
    "HEAD def456",
    "detached",
    "",
    "worktree /repo/bare",
    "bare",
    "",
  ].join("\n");
  assert.equal(findWorktreeForBranch(porcelain, "develop"), "/repo/main");
  assert.equal(findWorktreeForBranch(porcelain, "feature"), null);
});

test("the full chain carries a feature commit through develop into main", () => {
  const { origin, seed, local } = makePromotionSetup();
  try {
    const featureBefore = gitOutput(origin, ["rev-parse", "feature"]);
    writeFile(local, "base.txt", "base\nfeature change\n");

    const { result } = land(local, ["--promote"], VALID_MESSAGE);

    assert.equal(result.outcome, "COMMITTED");
    assert.deepEqual(result.promoted, ["develop", "main"]);
    assert.equal(result.pushed, false);
    assert.equal(gitOutput(local, ["rev-parse", "--abbrev-ref", "HEAD"]), "feature");
    assert.equal(gitOutput(origin, ["rev-parse", "develop"]), result.commit);
    assert.equal(gitOutput(origin, ["rev-parse", "main"]), result.commit);
    assert.equal(gitOutput(origin, ["rev-parse", "feature"]), featureBefore);
  } finally {
    cleanup(origin, seed, local);
  }
});

test("--promote-to develop stops before mainline", () => {
  const { origin, seed, local } = makePromotionSetup();
  try {
    writeFile(local, "base.txt", "base\nfeature change\n");
    const mainBefore = gitOutput(origin, ["rev-parse", "main"]);

    const { result } = land(local, ["--promote", "--promote-to", "develop"], VALID_MESSAGE);

    assert.equal(result.outcome, "COMMITTED");
    assert.deepEqual(result.promoted, ["develop"]);
    assert.equal(result.pushed, true);
    assert.equal(gitOutput(origin, ["rev-parse", "feature"]), result.commit);
    assert.equal(gitOutput(origin, ["rev-parse", "develop"]), result.commit);
    assert.equal(gitOutput(origin, ["rev-parse", "main"]), mainBefore);
  } finally {
    cleanup(origin, seed, local);
  }
});

test("a commit on develop promotes mainline only", () => {
  const { origin, seed, local } = makePromotionSetup();
  try {
    runGit(local, ["checkout", "-q", "develop"]);
    writeFile(local, "base.txt", "base\ndevelop change\n");

    const { result } = land(local, ["--promote"], VALID_MESSAGE);

    assert.equal(result.outcome, "COMMITTED");
    assert.deepEqual(result.promoted, ["main"]);
    assert.equal(gitOutput(origin, ["rev-parse", "main"]), result.commit);
  } finally {
    cleanup(origin, seed, local);
  }
});

test("a commit on mainline skips promotion with a warning", () => {
  const { origin, seed, local } = makePromotionSetup();
  try {
    runGit(local, ["checkout", "-q", "main"]);
    writeFile(local, "base.txt", "base\nmain change\n");

    const { result } = land(local, ["--promote"], VALID_MESSAGE);

    assert.equal(result.outcome, "COMMITTED");
    assert.deepEqual(result.promoted, []);
    assert.match((result.warnings as string[]).join("\n"), /commit landed directly on main/);
  } finally {
    cleanup(origin, seed, local);
  }
});

test("a missing develop branch is created and pushed", () => {
  const { origin, seed } = seedOriginWithBranches(["feature"]);
  const local = cloneRepo(origin);
  try {
    runGit(local, ["checkout", "-q", "-b", "feature", "origin/feature"]);
    writeFile(local, "base.txt", "base\nfeature change\n");

    const { result } = land(local, ["--promote"], VALID_MESSAGE);

    assert.equal(result.outcome, "COMMITTED");
    assert.deepEqual(result.promoted, ["develop", "main"]);
    assert.match((result.warnings as string[]).join("\n"), /develop branch did not exist/);
    assert.equal(gitOutput(origin, ["rev-parse", "develop"]), result.commit);
  } finally {
    cleanup(origin, seed, local);
  }
});

test("a master-only repo resolves mainline to master", () => {
  const repo = makeRepo();
  try {
    runGit(repo, ["symbolic-ref", "HEAD", "refs/heads/master"]);
    commitFile(repo, "base.txt", "base\n");
    runGit(repo, ["checkout", "-q", "-b", "feature"]);
    writeFile(repo, "base.txt", "base\nfeature change\n");

    const { result } = land(repo, ["--promote"], VALID_MESSAGE);

    assert.equal(result.outcome, "COMMITTED");
    assert.deepEqual(result.promoted, ["develop", "master"]);
    assert.equal(gitOutput(repo, ["rev-parse", "master"]), result.commit);
  } finally {
    cleanup(repo);
  }
});

test("a repo with no origin promotes locally and warns", () => {
  const repo = makeRepo();
  try {
    commitFile(repo, "base.txt", "base\n");
    runGit(repo, ["branch", "develop"]);
    runGit(repo, ["checkout", "-q", "-b", "feature"]);
    writeFile(repo, "base.txt", "base\nfeature change\n");

    const { result } = land(repo, ["--promote"], VALID_MESSAGE);

    assert.equal(result.outcome, "COMMITTED");
    assert.deepEqual(result.promoted, ["develop", "main"]);
    assert.equal(result.pushed, false);
    assert.match((result.warnings as string[]).join("\n"), /promoted branches updated locally only/);
    assert.equal(gitOutput(repo, ["rev-parse", "develop"]), result.commit);
    assert.equal(gitOutput(repo, ["rev-parse", "main"]), result.commit);
  } finally {
    cleanup(repo);
  }
});

test("a conflicting promotion merge aborts, restores the branch, and leaves a clean tree", () => {
  const repo = makeRepo();
  try {
    commitFile(repo, "shared.txt", "one\ntwo\nthree\n");
    runGit(repo, ["checkout", "-q", "-b", "develop"]);
    writeFile(repo, "shared.txt", "one\nDEVELOP\nthree\n");
    runGit(repo, ["commit", "-q", "-am", "develop change"]);
    runGit(repo, ["checkout", "-q", "main"]);
    runGit(repo, ["checkout", "-q", "-b", "feature"]);
    writeFile(repo, "shared.txt", "one\nFEATURE\nthree\n");

    const { code, result } = land(repo, ["--promote"], VALID_MESSAGE);

    assert.equal(result.outcome, "PROMOTE_CONFLICT");
    assert.equal(code, 23);
    assert.ok(result.commit);
    assert.deepEqual(result.conflicts, ["shared.txt"]);
    assert.equal(gitOutput(repo, ["rev-parse", "--abbrev-ref", "HEAD"]), "feature");
    assert.notEqual(tryGit(repo, ["rev-parse", "-q", "--verify", "MERGE_HEAD"]), 0);
    assert.equal(gitOutput(repo, ["status", "--short"]), "");
  } finally {
    cleanup(repo);
  }
});

test("a non-fast-forward promotion that merges cleanly creates a merge commit", () => {
  const { origin, seed } = seedOriginWithBranches(["feature"]);
  const local = cloneRepo(origin);
  try {
    runGit(local, ["checkout", "-q", "-b", "feature", "origin/feature"]);
    runGit(local, ["branch", "develop", "origin/main"]);
    runGit(local, ["checkout", "-q", "develop"]);
    commitFile(local, "other.txt", "other\n", "develop only");
    runGit(local, ["checkout", "-q", "feature"]);
    writeFile(local, "base.txt", "base\nfeature change\n");

    const { result } = land(local, ["--promote"], VALID_MESSAGE);

    assert.equal(result.outcome, "COMMITTED");
    assert.equal(gitOutput(local, ["rev-parse", "--abbrev-ref", "HEAD"]), "feature");
    assert.equal(tryGit(local, ["rev-parse", "-q", "--verify", "develop^2"]), 0);
    assert.deepEqual(result.promoted, ["develop", "main"]);
  } finally {
    cleanup(origin, seed, local);
  }
});

test("a checkout blocked by an untracked file stops promotion without advancing develop", () => {
  const repo = makeRepo();
  try {
    commitFile(repo, "base.txt", "base\n");
    runGit(repo, ["checkout", "-q", "-b", "develop"]);
    commitFile(repo, "blocker.txt", "develop version\n", "add blocker on develop");
    runGit(repo, ["checkout", "-q", "main"]);
    runGit(repo, ["checkout", "-q", "-b", "feature"]);
    writeFile(repo, "base.txt", "base\nfeature change\n");
    writeFile(repo, "blocker.txt", "feature version\n");
    const developBefore = gitOutput(repo, ["rev-parse", "develop"]);

    const { code, result } = land(repo, ["--promote", "--paths", "base.txt"], VALID_MESSAGE);

    assert.equal(result.outcome, "PROMOTE_FAILED");
    assert.equal(code, 24);
    assert.deepEqual(result.promoted, []);
    assert.equal(gitOutput(repo, ["rev-parse", "develop"]), developBefore);
    assert.equal(gitOutput(repo, ["rev-parse", "--abbrev-ref", "HEAD"]), "feature");
    assert.match((result.warnings as string[]).join("\n"), /could not check out develop for merge/);
  } finally {
    cleanup(repo);
  }
});

test("a destination checked out in a clean worktree is fast-forwarded there", () => {
  const { origin, seed } = seedOriginWithBranches(["develop", "feature"]);
  const holder = cloneRepo(origin);
  const session = path.join(path.dirname(holder), "session");
  try {
    runGit(holder, ["branch", "develop", "origin/develop"]);
    runGit(holder, ["checkout", "-q", "develop"]);
    runGit(holder, ["worktree", "add", "-b", "feature", session, "origin/feature"]);
    writeFile(session, "base.txt", "base\nfeature change\n");

    const { result } = land(session, ["--promote"], VALID_MESSAGE);

    assert.equal(result.outcome, "COMMITTED");
    assert.deepEqual(result.promoted, ["develop", "main"]);
    assert.equal(gitOutput(holder, ["rev-parse", "develop"]), result.commit);
    assert.equal(gitOutput(origin, ["rev-parse", "main"]), result.commit);
    assert.match((result.warnings as string[]).join("\n"), /fast-forwarded in its holding worktree/);
  } finally {
    cleanup(origin, seed, path.dirname(holder));
  }
});

test("a destination checked out in a dirty worktree stops promotion", () => {
  const { origin, seed } = seedOriginWithBranches(["develop", "feature"]);
  const holder = cloneRepo(origin);
  const session = path.join(path.dirname(holder), "session");
  try {
    runGit(holder, ["branch", "develop", "origin/develop"]);
    runGit(holder, ["checkout", "-q", "develop"]);
    runGit(holder, ["worktree", "add", "-b", "feature", session, "origin/feature"]);
    writeFile(session, "base.txt", "base\nfeature change\n");
    writeFile(holder, "base.txt", "base\nholder dirty\n");
    const developBefore = gitOutput(holder, ["rev-parse", "develop"]);

    const { result } = land(session, ["--promote"], VALID_MESSAGE);

    assert.equal(result.outcome, "PROMOTE_FAILED");
    assert.deepEqual(result.promoted, []);
    assert.equal(gitOutput(holder, ["rev-parse", "develop"]), developBefore);
    assert.match((result.warnings as string[]).join("\n"), /has uncommitted changes; promotion stopped/);
  } finally {
    cleanup(origin, seed, path.dirname(holder));
  }
});

test("a clean tree with promotion repairs develop into mainline without committing", () => {
  const origin = makeBareOrigin();
  const seed = makeRepo();
  runGit(seed, ["remote", "add", "origin", origin]);
  commitFile(seed, "base.txt", "base\n", "init");
  runGit(seed, ["push", "-q", "-u", "origin", "main"]);
  runGit(seed, ["checkout", "-q", "-b", "develop"]);
  commitFile(seed, "develop_only.txt", "develop advance\n", "develop advance");
  runGit(seed, ["push", "-q", "-u", "origin", "develop"]);
  const local = cloneRepo(origin);
  try {
    runGit(local, ["checkout", "-q", "-b", "develop", "origin/develop"]);

    const { code, result } = land(local, ["--promote"], VALID_MESSAGE);

    assert.equal(result.outcome, "NOTHING_TO_COMMIT");
    assert.equal(code, 13);
    assert.deepEqual(result.promoted, ["main"]);
    const developTip = gitOutput(local, ["rev-parse", "develop"]);
    assert.equal(gitOutput(local, ["rev-parse", "main"]), developTip);
    assert.equal(gitOutput(origin, ["rev-parse", "main"]), developTip);
  } finally {
    cleanup(origin, seed, local);
  }
});

test("an origin that drifts under the push is resynced and retried", () => {
  const { origin, seed, local } = makePromotionSetup();
  try {
    writeFile(local, "base.txt", "base\nfeature change\n");
    writeOriginHook(origin, "pre-receive", driftingMainPreReceiveHook());

    const { result } = land(local, ["--promote", "--no-push"], VALID_MESSAGE);

    assert.equal(result.outcome, "COMMITTED");
    assert.ok((result.promoted as string[]).includes("main"));
    assert.equal(gitOutput(origin, ["rev-parse", "main"]), gitOutput(local, ["rev-parse", "main"]));
    const warnings = (result.warnings as string[]).join("\n");
    assert.match(warnings, /promote push main attempt 1\/3 failed/);
    assert.match(warnings, /local main diverged from origin\/main/);
  } finally {
    cleanup(origin, seed, local);
  }
});

test("a promoted ref rejected once is resynced and the batch retried", () => {
  const { origin, seed, local } = makePromotionSetup();
  try {
    writeFile(local, "base.txt", "base\nfeature change\n");
    writeOriginHook(origin, "update", oneTimeRejectUpdateHook("main"));

    const { result } = land(local, ["--promote"], VALID_MESSAGE);

    assert.equal(result.outcome, "COMMITTED");
    assert.deepEqual(result.promoted, ["develop", "main"]);
    assert.equal(gitOutput(origin, ["rev-parse", "main"]), result.commit);
    assert.equal(gitOutput(origin, ["rev-parse", "develop"]), result.commit);
  } finally {
    cleanup(origin, seed, local);
  }
});

test("a rejected feature ref in a develop-target batch is PUSH_FAILED", () => {
  const { origin, seed, local } = makePromotionSetup();
  try {
    writeFile(local, "base.txt", "base\nfeature change\n");
    writeOriginHook(origin, "update", oneTimeRejectUpdateHook("feature"));

    const { code, result } = land(local, ["--promote", "--promote-to", "develop"], VALID_MESSAGE);

    assert.equal(result.outcome, "PUSH_FAILED");
    assert.equal(code, 22);
    assert.equal(result.pushed, false);
  } finally {
    cleanup(origin, seed, local);
  }
});

test("branches already level with origin still report as promoted", () => {
  const { origin, seed, local } = makePromotionSetup();
  try {
    writeFile(local, "base.txt", "base\nfeature change\n");
    const first = land(local, ["--promote"], VALID_MESSAGE);
    assert.equal(first.result.outcome, "COMMITTED");

    const second = land(local, ["--promote"], VALID_MESSAGE);

    assert.equal(second.result.outcome, "NOTHING_TO_COMMIT");
    assert.deepEqual(second.result.promoted, ["develop", "main"]);
    assert.equal(gitOutput(origin, ["rev-parse", "main"]), first.result.commit);
  } finally {
    cleanup(origin, seed, local);
  }
});

test("the temp directories used by these tests are removed", () => {
  const probe = fs.mkdtempSync(path.join(os.tmpdir(), "commit-skill-probe-"));
  cleanup(probe);
  assert.equal(fs.existsSync(probe), false);
});

test("a resynced develop is replayed into mainline before the retry push", () => {
  const { origin, seed, local } = makePromotionSetup();
  const other = cloneRepo(origin);
  try {
    runGit(other, ["checkout", "-q", "-b", "develop", "origin/develop"]);
    const developBeforeDrift = gitOutput(origin, ["rev-parse", "develop"]);
    commitFile(other, "drift.txt", "landed on develop by someone else\n", "origin develop drift");
    runGit(other, ["push", "-q", "origin", "develop"]);
    const driftSha = gitOutput(origin, ["rev-parse", "develop"]);
    runGit(origin, ["update-ref", "refs/heads/develop", developBeforeDrift]);

    writeFile(local, "base.txt", "base\nfeature change\n");
    writeOriginHook(origin, "update", driftDevelopOnceUpdateHook(driftSha));

    const { result } = land(local, ["--promote", "--no-push"], VALID_MESSAGE);

    assert.equal(result.outcome, "COMMITTED");
    assert.deepEqual(result.promoted, ["develop", "main"]);
    assert.equal(gitOutput(origin, ["rev-parse", "main"]), gitOutput(origin, ["rev-parse", "develop"]));
    assert.match(
      gitOutput(origin, ["log", "--format=%s", "main"]),
      /origin develop drift/,
      "mainline must carry the commit that landed on develop between the push attempts",
    );
  } finally {
    cleanup(origin, seed, local, other);
  }
});

test("a promotion merge that fails without conflicts is PROMOTE_FAILED", () => {
  const repo = makeRepo();
  try {
    commitFile(repo, "base.txt", "base\n");
    runGit(repo, ["checkout", "-q", "-b", "develop"]);
    commitFile(repo, "develop_only.txt", "develop\n", "develop only");
    runGit(repo, ["checkout", "-q", "main"]);
    runGit(repo, ["checkout", "-q", "-b", "feature"]);
    writeFile(repo, "base.txt", "base\nfeature change\n");
    writeCommitMsgRejectHook(repo);

    const { code, result } = land(repo, ["--promote", "--no-push"], VALID_MESSAGE);

    assert.equal(result.outcome, "PROMOTE_FAILED");
    assert.equal(code, 24);
    assert.equal("conflicts" in result, false);
    assert.equal(gitOutput(repo, ["rev-parse", "--abbrev-ref", "HEAD"]), "feature");
    assert.equal(tryGit(repo, ["rev-parse", "-q", "--verify", "MERGE_HEAD"]) === 0, false);
    assert.match((result.warnings as string[]).join("\n"), /failed without conflicts/);
  } finally {
    cleanup(repo);
  }
});

function rejectUpdateHook(branch: string): string {
  return [
    "#!/bin/sh",
    'ref_name="$1"',
    `if [ "$ref_name" != "refs/heads/${branch}" ]; then`,
    "  exit 0",
    "fi",
    `echo "rejecting ${branch}" >&2`,
    "exit 1",
    "",
  ].join("\n");
}

function rejectDeleteHook(branch: string): string {
  return [
    "#!/bin/sh",
    'ref_name="$1"',
    'new_sha="$3"',
    `if [ "$ref_name" != "refs/heads/${branch}" ]; then`,
    "  exit 0",
    "fi",
    'if [ "$new_sha" != "0000000000000000000000000000000000000000" ]; then',
    "  exit 0",
    "fi",
    `echo "rejecting deletion of ${branch}" >&2`,
    "exit 1",
    "",
  ].join("\n");
}

function makeGlissaPromotionSetup(featureBranch: string): PromotionSetup {
  const origin = makeBareOrigin();
  const seed = makeRepo();
  runGit(seed, ["remote", "add", "origin", origin]);
  commitFile(seed, "base.txt", "base\n", "init");
  runGit(seed, ["push", "-q", "-u", "origin", "main"]);
  runGit(seed, ["checkout", "-q", "-b", "develop"]);
  runGit(seed, ["push", "-q", "-u", "origin", "develop"]);
  runGit(seed, ["checkout", "-q", "-b", featureBranch]);
  runGit(seed, ["push", "-q", "-u", "origin", featureBranch]);
  const local = cloneRepo(origin);
  runGit(local, ["branch", "develop", "origin/develop"]);
  runGit(local, ["checkout", "-q", "-b", featureBranch, `origin/${featureBranch}`]);
  return { origin, seed, local };
}

test("mainline promotion deletes the merged glissa branch it left behind", () => {
  const featureBranch = "glissa/session/delete-after-mainline";
  const { origin, seed, local } = makeGlissaPromotionSetup(featureBranch);
  try {
    writeFile(local, "base.txt", "base\nfeature change\n");

    const { result } = land(local, ["--promote"], VALID_MESSAGE);

    assert.equal(result.outcome, "COMMITTED");
    assert.equal(result.pushed, false);
    assert.deepEqual(result.deletedRemoteBranches, [featureBranch]);
    assert.equal(tryGit(origin, ["rev-parse", "-q", "--verify", featureBranch]) === 0, false);
    assert.equal(gitOutput(origin, ["rev-parse", "main"]), result.commit);
  } finally {
    cleanup(origin, seed, local);
  }
});

test("a failed mainline promotion still pushes the feature branch as a safety net", () => {
  const featureBranch = "glissa/session/promotion-fallback";
  const { origin, seed, local } = makeGlissaPromotionSetup(featureBranch);
  try {
    writeFile(local, "base.txt", "base\nfeature change\n");
    writeOriginHook(origin, "update", rejectUpdateHook("main"));

    const { code, result } = land(local, ["--promote"], VALID_MESSAGE);

    assert.equal(result.outcome, "PROMOTE_FAILED");
    assert.equal(code, 24);
    assert.equal(result.pushed, true);
    assert.equal(gitOutput(origin, ["rev-parse", featureBranch]), result.commit);
    assert.equal("deletedRemoteBranches" in result, false);
  } finally {
    cleanup(origin, seed, local);
  }
});

test("a refused remote branch deletion is a warning, not an outcome change", () => {
  const featureBranch = "glissa/session/delete-rejected";
  const { origin, seed, local } = makeGlissaPromotionSetup(featureBranch);
  try {
    writeFile(local, "base.txt", "base\nfeature change\n");
    writeOriginHook(origin, "update", rejectDeleteHook(featureBranch));

    const { result } = land(local, ["--promote"], VALID_MESSAGE);

    assert.equal(result.outcome, "COMMITTED");
    assert.equal("deletedRemoteBranches" in result, false);
    assert.equal(tryGit(origin, ["rev-parse", "-q", "--verify", featureBranch]), 0);
    assert.match(
      (result.warnings as string[]).join("\n"),
      new RegExp(`could not delete merged remote branch ${featureBranch}`),
    );
  } finally {
    cleanup(origin, seed, local);
  }
});

test("a non-glissa feature branch is never deleted after promotion", () => {
  const { origin, seed, local } = makePromotionSetup();
  try {
    writeFile(local, "base.txt", "base\nfeature change\n");

    const { result } = land(local, ["--promote"], VALID_MESSAGE);

    assert.equal(result.outcome, "COMMITTED");
    assert.equal("deletedRemoteBranches" in result, false);
    assert.equal(tryGit(origin, ["rev-parse", "-q", "--verify", "feature"]), 0);
  } finally {
    cleanup(origin, seed, local);
  }
});
