import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { forbiddenBranches, isBranchAllowed, readCommitPolicy } from "../lib/policy.ts";
import { cleanup, makePolicyRoot } from "./helpers.ts";

const PERSONAL_POLICY = {
  profile: "personal",
  commitBranches: { forbid: ["main", "master"], onForbidden: "switch-to-develop" },
  afterCommit: "promote",
};

test("an applied profile yields its policy", () => {
  const root = makePolicyRoot("personal", PERSONAL_POLICY);
  try {
    const { profile, policy, warning } = readCommitPolicy(root);
    assert.equal(profile, "personal");
    assert.equal(warning, undefined);
    assert.deepEqual(policy, PERSONAL_POLICY);
  } finally {
    cleanup(root);
  }
});

test("a forbidden branch is not allowed and any other branch is", () => {
  assert.equal(isBranchAllowed("master", PERSONAL_POLICY), false);
  assert.equal(isBranchAllowed("main", PERSONAL_POLICY), false);
  assert.equal(isBranchAllowed("develop", PERSONAL_POLICY), true);
  assert.equal(isBranchAllowed("feature/x", PERSONAL_POLICY), true);
});

test("a work policy forbids develop as well", () => {
  const workPolicy = { commitBranches: { forbid: ["main", "master", "develop"] } };
  assert.equal(isBranchAllowed("develop", workPolicy), false);
  assert.equal(isBranchAllowed("feature/x", workPolicy), true);
});

test("no policy still guards mainline and still allows ordinary branches", () => {
  assert.deepEqual(forbiddenBranches(undefined), ["main", "master"]);
  assert.equal(isBranchAllowed("master", undefined), false);
  assert.equal(isBranchAllowed("develop", undefined), true);
});

test("a policy whose forbid list is not a list falls back to guarding mainline", () => {
  assert.deepEqual(forbiddenBranches({ commitBranches: { forbid: "main" } }), ["main", "master"]);
});

test("a missing marker warns and reads no policy", () => {
  const root = makePolicyRoot("personal", PERSONAL_POLICY);
  try {
    fs.rmSync(path.join(root, ".machine-profile"));
    const { policy, warning } = readCommitPolicy(root);
    assert.equal(policy, undefined);
    assert.match(warning ?? "", /no machine profile marker/);
  } finally {
    cleanup(root);
  }
});

test("a marker that is not a plain profile name is refused before it reaches a path", () => {
  const root = makePolicyRoot("personal", PERSONAL_POLICY);
  try {
    fs.writeFileSync(path.join(root, ".machine-profile"), "../../etc\n", "utf8");
    const { profile, policy, warning } = readCommitPolicy(root);
    assert.equal(profile, undefined);
    assert.equal(policy, undefined);
    assert.match(warning ?? "", /names no usable profile/);
  } finally {
    cleanup(root);
  }
});

test("a policy file that does not parse warns instead of throwing", () => {
  const root = makePolicyRoot("personal", PERSONAL_POLICY);
  try {
    fs.writeFileSync(
      path.join(root, "profiles", "personal", "commit-policy.json"),
      "{ not json",
      "utf8",
    );
    const { policy, warning } = readCommitPolicy(root);
    assert.equal(policy, undefined);
    assert.match(warning ?? "", /could not parse/);
  } finally {
    cleanup(root);
  }
});

test("the profiles shipped in this repo all parse and name a forbid list", () => {
  const repoRoot = path.resolve(import.meta.dirname, "..", "..", "..");
  for (const profile of ["personal", "server", "work"]) {
    const policyPath = path.join(repoRoot, "profiles", profile, "commit-policy.json");
    const policy = JSON.parse(fs.readFileSync(policyPath, "utf8")) as Record<string, unknown>;
    assert.ok(forbiddenBranches(policy).includes("master"), `${profile} must guard master`);
    assert.ok(forbiddenBranches(policy).includes("main"), `${profile} must guard main`);
    assert.ok(
      ["promote", "pull-request"].includes(policy.afterCommit as string),
      `${profile} needs a known afterCommit`,
    );
  }
});
