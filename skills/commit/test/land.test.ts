import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import {
  cleanup,
  cloneRepo,
  commitFile,
  gitOutput,
  land,
  makeBareOrigin,
  makeRepo,
  runGit,
  VALID_MESSAGE,
  writeFile,
} from "./helpers.ts";

function writeFailingHook(repo: string, name: string): void {
  const hooksDir = path.join(repo, ".git", "hooks");
  fs.mkdirSync(hooksDir, { recursive: true });
  const hookPath = path.join(hooksDir, name);
  fs.writeFileSync(hookPath, "#!/bin/sh\necho 'hook says no' >&2\nexit 1\n", "utf8");
  fs.chmodSync(hookPath, 0o755);
}

function writeFlakyHook(repo: string, name: string, failingAttempts: number): void {
  const hooksDir = path.join(repo, ".git", "hooks");
  fs.mkdirSync(hooksDir, { recursive: true });
  const hookPath = path.join(hooksDir, name);
  fs.writeFileSync(
    hookPath,
    [
      "#!/bin/sh",
      'count_file="$(git rev-parse --git-dir)/hook-attempts"',
      "count=0",
      '[ -f "$count_file" ] && count=$(cat "$count_file")',
      "count=$((count + 1))",
      'printf "%s" "$count" > "$count_file"',
      `if [ "$count" -le ${failingAttempts} ]; then`,
      '  echo "flaky attempt $count" >&2',
      "  exit 1",
      "fi",
      "exit 0",
      "",
    ].join("\n"),
    "utf8",
  );
  fs.chmodSync(hookPath, 0o755);
}

test("a real commit is created from the message on stdin", () => {
  const repo = makeRepo();
  try {
    commitFile(repo, "a.txt", "one\n");
    writeFile(repo, "a.txt", "two\n");
    writeFile(repo, "new.txt", "new\n");

    const { code, result } = land(repo, ["--no-push"], VALID_MESSAGE);

    assert.equal(result.outcome, "COMMITTED");
    assert.equal(code, 0);
    assert.equal(result.commit, gitOutput(repo, ["rev-parse", "HEAD"]));
    assert.equal(gitOutput(repo, ["log", "-1", "--format=%B"]).trim(), VALID_MESSAGE);
    assert.deepEqual(gitOutput(repo, ["status", "--short"]), "");
  } finally {
    cleanup(repo);
  }
});

test("a clean tree without promotion is NOTHING_TO_COMMIT", () => {
  const repo = makeRepo();
  try {
    commitFile(repo, "a.txt", "one\n");
    const { code, result } = land(repo, ["--no-push"], VALID_MESSAGE);
    assert.equal(result.outcome, "NOTHING_TO_COMMIT");
    assert.equal(code, 13);
  } finally {
    cleanup(repo);
  }
});

test("an invalid message is MESSAGE_INVALID and commits nothing", () => {
  const repo = makeRepo();
  try {
    commitFile(repo, "a.txt", "one\n");
    writeFile(repo, "a.txt", "two\n");
    const head = gitOutput(repo, ["rev-parse", "HEAD"]);

    const { code, result } = land(repo, ["--no-push"], "no conventional header here");

    assert.equal(result.outcome, "MESSAGE_INVALID");
    assert.equal(code, 20);
    assert.equal(gitOutput(repo, ["rev-parse", "HEAD"]), head);
  } finally {
    cleanup(repo);
  }
});

test("a rejecting commit hook is HOOK_FAILED and keeps the hook stderr", () => {
  const repo = makeRepo();
  try {
    commitFile(repo, "a.txt", "one\n");
    writeFile(repo, "a.txt", "two\n");
    writeFailingHook(repo, "pre-commit");

    const { code, result } = land(repo, ["--no-push"], VALID_MESSAGE);

    assert.equal(result.outcome, "HOOK_FAILED");
    assert.equal(code, 21);
    assert.match((result.warnings as string[]).join("\n"), /hook says no/);
  } finally {
    cleanup(repo);
  }
});

test("--paths leaves an out-of-scope change dirty", () => {
  const repo = makeRepo();
  try {
    commitFile(repo, "a.txt", "one\n");
    commitFile(repo, "b.txt", "one\n");
    writeFile(repo, "a.txt", "two\n");
    writeFile(repo, "b.txt", "two\n");

    const { result } = land(repo, ["--no-push", "--paths", "a.txt"], VALID_MESSAGE);

    assert.equal(result.outcome, "COMMITTED");
    assert.deepEqual(gitOutput(repo, ["show", "--name-only", "--format=", "HEAD"]).split("\n"), ["a.txt"]);
    assert.match(gitOutput(repo, ["status", "--short"]), /b\.txt/);
  } finally {
    cleanup(repo);
  }
});

test("--paths matching nothing dirty is NOTHING_TO_COMMIT", () => {
  const repo = makeRepo();
  try {
    commitFile(repo, "a.txt", "one\n");
    commitFile(repo, "b.txt", "one\n");
    writeFile(repo, "b.txt", "two\n");

    const { result } = land(repo, ["--no-push", "--paths", "a.txt"], VALID_MESSAGE);

    assert.equal(result.outcome, "NOTHING_TO_COMMIT");
  } finally {
    cleanup(repo);
  }
});

test("a push advances the origin ref and reports pushed", () => {
  const origin = makeBareOrigin();
  const repo = cloneRepo(origin);
  try {
    commitFile(repo, "a.txt", "one\n");
    runGit(repo, ["push", "-q", "-u", "origin", "HEAD"]);
    writeFile(repo, "a.txt", "two\n");

    const { result } = land(repo, [], VALID_MESSAGE);

    assert.equal(result.outcome, "COMMITTED");
    assert.equal(result.pushed, true);
    const branch = gitOutput(repo, ["rev-parse", "--abbrev-ref", "HEAD"]);
    assert.equal(gitOutput(origin, ["rev-parse", branch]), result.commit);
  } finally {
    cleanup(origin, repo);
  }
});

test("a repo with no origin commits and warns instead of pushing", () => {
  const repo = makeRepo();
  try {
    commitFile(repo, "a.txt", "one\n");
    writeFile(repo, "a.txt", "two\n");

    const { result } = land(repo, [], VALID_MESSAGE);

    assert.equal(result.outcome, "COMMITTED");
    assert.equal(result.pushed, false);
    assert.match((result.warnings as string[]).join("\n"), /no origin remote configured/);
  } finally {
    cleanup(repo);
  }
});

test("a rejected push is PUSH_FAILED with the commit already made", () => {
  const origin = makeBareOrigin();
  const repo = cloneRepo(origin);
  const other = cloneRepo(origin);
  try {
    commitFile(repo, "a.txt", "one\n");
    runGit(repo, ["push", "-q", "-u", "origin", "HEAD"]);
    const branch = gitOutput(repo, ["rev-parse", "--abbrev-ref", "HEAD"]);

    runGit(other, ["fetch", "-q", "origin"]);
    runGit(other, ["checkout", "-q", "-B", branch, `origin/${branch}`]);
    commitFile(other, "a.txt", "someone else\n", "other change");
    runGit(other, ["push", "-q", "origin", branch]);

    writeFile(repo, "a.txt", "two\n");
    const { code, result } = land(repo, [], VALID_MESSAGE);

    assert.equal(result.outcome, "PUSH_FAILED");
    assert.equal(code, 22);
    assert.equal(result.pushed, false);
    assert.equal(result.commit, gitOutput(repo, ["rev-parse", "HEAD"]));
  } finally {
    cleanup(origin, repo, other);
  }
});

test("a flaky pre-push hook is retried until it passes", () => {
  const origin = makeBareOrigin();
  const repo = cloneRepo(origin);
  try {
    commitFile(repo, "a.txt", "one\n");
    runGit(repo, ["push", "-q", "-u", "origin", "HEAD"]);
    writeFile(repo, "a.txt", "two\n");
    writeFlakyHook(repo, "pre-push", 2);

    const { result } = land(repo, [], VALID_MESSAGE);

    assert.equal(result.outcome, "COMMITTED");
    assert.equal(result.pushed, true);
    assert.match((result.warnings as string[]).join("\n"), /push attempt 1\/3 failed/);
  } finally {
    cleanup(origin, repo);
  }
});

test("a pre-push hook that never passes exhausts the retries", () => {
  const origin = makeBareOrigin();
  const repo = cloneRepo(origin);
  try {
    commitFile(repo, "a.txt", "one\n");
    runGit(repo, ["push", "-q", "-u", "origin", "HEAD"]);
    writeFile(repo, "a.txt", "two\n");
    writeFailingHook(repo, "pre-push");

    const { code, result } = land(repo, [], VALID_MESSAGE);

    assert.equal(result.outcome, "PUSH_FAILED");
    assert.equal(code, 22);
    assert.match((result.warnings as string[]).join("\n"), /push attempt 3\/3 failed/);
  } finally {
    cleanup(origin, repo);
  }
});
