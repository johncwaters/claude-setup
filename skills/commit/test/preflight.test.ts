import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import {
  cleanup,
  commitFile,
  makePolicyRoot,
  makeRepo,
  preflight,
  runGit,
  runSkillScript,
  tryGit,
  VALID_MESSAGE,
  writeFile,
} from "./helpers.ts";

test("a directory that is not a repo is NOT_A_REPO", () => {
  const outside = fs.mkdtempSync(path.join(os.tmpdir(), "commit-skill-bare-"));
  try {
    const { code, result } = preflight(outside);
    assert.equal(result.outcome, "NOT_A_REPO");
    assert.equal(code, 10);
  } finally {
    cleanup(outside);
  }
});

test("a detached HEAD is DETACHED_HEAD", () => {
  const repo = makeRepo();
  try {
    commitFile(repo, "a.txt", "one\n");
    runGit(repo, ["checkout", "-q", "--detach", "HEAD"]);
    const { code, result } = preflight(repo);
    assert.equal(result.outcome, "DETACHED_HEAD");
    assert.equal(code, 11);
  } finally {
    cleanup(repo);
  }
});

test("a conflicted merge left in progress is OPERATION_IN_PROGRESS", () => {
  const repo = makeRepo();
  try {
    commitFile(repo, "a.txt", "one\n");
    runGit(repo, ["branch", "other"]);
    commitFile(repo, "a.txt", "main side\n", "main change");
    runGit(repo, ["checkout", "-q", "other"]);
    commitFile(repo, "a.txt", "other side\n", "other change");
    assert.notEqual(tryGit(repo, ["merge", "--no-edit", "main"]), 0);

    const { code, result } = preflight(repo);
    assert.equal(result.outcome, "OPERATION_IN_PROGRESS");
    assert.equal(result.operation, "MERGE_HEAD");
    assert.equal(code, 12);
  } finally {
    cleanup(repo);
  }
});

test("a clean tree is READY with an empty scope", () => {
  const repo = makeRepo();
  try {
    commitFile(repo, "a.txt", "one\n");
    const { code, result } = preflight(repo);
    assert.equal(result.outcome, "READY");
    assert.equal(code, 0);
    assert.deepEqual(result.changed, []);
    assert.deepEqual(result.untracked, []);
    assert.equal(result.branch, "main");
  } finally {
    cleanup(repo);
  }
});

test("modified and untracked files are reported, denylisted paths are not", () => {
  const repo = makeRepo();
  try {
    commitFile(repo, "a.txt", "one\n");
    writeFile(repo, "a.txt", "two\n");
    writeFile(repo, "new.txt", "new\n");
    writeFile(repo, "debug.log", "noise\n");
    writeFile(repo, "node_modules/pkg/index.js", "junk\n");
    writeFile(repo, ".env.local", "SECRET=1\n");
    const { result } = preflight(repo);
    assert.deepEqual(result.changed, ["a.txt"]);
    assert.deepEqual(result.untracked, ["new.txt"]);
  } finally {
    cleanup(repo);
  }
});

test("--paths restricts the reported scope", () => {
  const repo = makeRepo();
  try {
    commitFile(repo, "a.txt", "one\n");
    commitFile(repo, "b.txt", "one\n");
    writeFile(repo, "a.txt", "two\n");
    writeFile(repo, "b.txt", "two\n");
    const { result } = preflight(repo, ["--paths", "a.txt"]);
    assert.deepEqual(result.changed, ["a.txt"]);
  } finally {
    cleanup(repo);
  }
});

test("a branch the applied profile forbids reports branchAllowed false", () => {
  const repo = makeRepo();
  const policyRoot = makePolicyRoot("personal", {
    profile: "personal",
    commitBranches: { forbid: ["main", "master"], onForbidden: "switch-to-develop" },
    afterCommit: "promote",
  });
  try {
    commitFile(repo, "a.txt", "one\n");
    writeFile(repo, "a.txt", "two\n");

    const onMain = preflight(repo, [], { CLAUDE_COMMIT_POLICY_ROOT: policyRoot });
    assert.equal(onMain.result.branch, "main");
    assert.equal(onMain.result.branchAllowed, false);
    assert.equal(onMain.result.profile, "personal");
    assert.equal("warnings" in onMain.result, false);

    runGit(repo, ["checkout", "-q", "-b", "develop"]);
    const onDevelop = preflight(repo, [], { CLAUDE_COMMIT_POLICY_ROOT: policyRoot });
    assert.equal(onDevelop.result.branchAllowed, true);
  } finally {
    cleanup(repo, policyRoot);
  }
});

test("a machine with no applied profile still guards mainline", () => {
  const repo = makeRepo();
  const emptyRoot = fs.mkdtempSync(path.join(os.tmpdir(), "commit-skill-noprofile-"));
  try {
    commitFile(repo, "a.txt", "one\n");
    writeFile(repo, "a.txt", "two\n");

    const { result } = preflight(repo, [], { CLAUDE_COMMIT_POLICY_ROOT: emptyRoot });

    assert.equal(result.branchAllowed, false);
    assert.equal("policy" in result, false);
    assert.match((result.warnings as string[]).join("\n"), /no machine profile marker/);
  } finally {
    cleanup(repo, emptyRoot);
  }
});

test("--check-message accepts a valid message and rejects an invalid one", () => {
  const repo = makeRepo();
  try {
    const good = runSkillScript("preflight.ts", repo, ["--check-message"], VALID_MESSAGE);
    assert.equal(good.result.outcome, "READY");
    assert.equal(good.code, 0);

    const bad = runSkillScript("preflight.ts", repo, ["--check-message"], "not a conventional header");
    assert.equal(bad.result.outcome, "MESSAGE_INVALID");
    assert.equal(bad.code, 20);
    assert.ok((bad.result.errors as string[]).length > 0);
  } finally {
    cleanup(repo);
  }
});
