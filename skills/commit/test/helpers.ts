import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const SKILL_DIR = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

export function runGit(repo: string, args: string[]): { code: number; stdout: string } {
  const proc = spawnSync("git", args, { cwd: repo, encoding: "utf8" });
  const code = proc.status ?? 1;
  if (code !== 0) {
    throw new Error(`git ${args.join(" ")} failed: ${proc.stderr}`);
  }
  return { code, stdout: proc.stdout ?? "" };
}

export function tryGit(repo: string, args: string[]): number {
  return spawnSync("git", args, { cwd: repo, encoding: "utf8" }).status ?? 1;
}

export function gitOutput(repo: string, args: string[]): string {
  return runGit(repo, args).stdout.trim();
}

export function makeRepo(): string {
  const repo = fs.mkdtempSync(path.join(os.tmpdir(), "commit-skill-"));
  runGit(repo, ["init", "-q"]);
  runGit(repo, ["symbolic-ref", "HEAD", "refs/heads/main"]);
  runGit(repo, ["config", "user.name", "Test User"]);
  runGit(repo, ["config", "user.email", "test@example.com"]);
  runGit(repo, ["config", "commit.gpgsign", "false"]);
  return repo;
}

export function makeBareOrigin(): string {
  const origin = fs.mkdtempSync(path.join(os.tmpdir(), "commit-skill-origin-"));
  runGit(origin, ["init", "-q", "--bare"]);
  return origin;
}

export function cloneRepo(origin: string): string {
  const parent = fs.mkdtempSync(path.join(os.tmpdir(), "commit-skill-clone-"));
  const dest = path.join(parent, "repo");
  const proc = spawnSync("git", ["clone", "-q", origin, dest], { encoding: "utf8" });
  if ((proc.status ?? 1) !== 0) {
    throw new Error(`git clone failed: ${proc.stderr}`);
  }
  runGit(dest, ["config", "user.name", "Test User"]);
  runGit(dest, ["config", "user.email", "test@example.com"]);
  runGit(dest, ["config", "commit.gpgsign", "false"]);
  return dest;
}

export function writeFile(repo: string, filePath: string, content: string): string {
  const full = path.join(repo, filePath);
  fs.mkdirSync(path.dirname(full), { recursive: true });
  fs.writeFileSync(full, content, "utf8");
  return full;
}

export function commitFile(repo: string, filePath: string, content: string, message = "init"): void {
  writeFile(repo, filePath, content);
  runGit(repo, ["add", "--", filePath]);
  runGit(repo, ["commit", "-q", "-m", message]);
}

export function cleanup(...paths: string[]): void {
  for (const target of paths) {
    fs.rmSync(target, { recursive: true, force: true });
  }
}

export type RunResult = { code: number; result: Record<string, unknown>; stderr: string };

export function runSkillScript(
  script: "preflight.ts" | "land.ts",
  repo: string,
  args: string[],
  message = "",
  env: Record<string, string> = {},
): RunResult {
  const proc = spawnSync("node", [path.join(SKILL_DIR, script), ...args], {
    cwd: repo,
    input: message,
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
    env: { ...process.env, ...env },
  });
  const stdout = proc.stdout ?? "";
  const stderr = proc.stderr ?? "";
  const lastLine = stdout.trim().split("\n").pop() ?? "";
  const parsed = lastLine === "" ? {} : (JSON.parse(lastLine) as Record<string, unknown>);
  return { code: proc.status ?? 1, result: parsed, stderr };
}

export function land(repo: string, args: string[], message: string): RunResult {
  return runSkillScript("land.ts", repo, ["--push-retry-delay-ms", "0", ...args], message);
}

export function preflight(
  repo: string,
  args: string[] = [],
  env: Record<string, string> = {},
): RunResult {
  return runSkillScript("preflight.ts", repo, args, "", env);
}

export function makePolicyRoot(profile: string, policy: Record<string, unknown>): string {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "commit-skill-policy-"));
  fs.writeFileSync(path.join(root, ".machine-profile"), `${profile}\n`, "utf8");
  const profileDir = path.join(root, "profiles", profile);
  fs.mkdirSync(profileDir, { recursive: true });
  fs.writeFileSync(
    path.join(profileDir, "commit-policy.json"),
    `${JSON.stringify(policy, null, 2)}\n`,
    "utf8",
  );
  return root;
}

export const VALID_MESSAGE = ["feat: add a thing", "", "A body line.", "", "Confidence: high", "Scope-risk: narrow"].join(
  "\n",
);

export function writeCommitMsgRejectHook(repo: string): void {
  const hooksDir = path.join(repo, ".git", "hooks");
  fs.mkdirSync(hooksDir, { recursive: true });
  const hookPath = path.join(hooksDir, "commit-msg");
  fs.writeFileSync(
    hookPath,
    ["#!/bin/sh", 'grep -q "^Merge " "$1" || exit 0', 'echo "merge commits are not allowed here" >&2', "exit 1", ""].join(
      "\n",
    ),
    "utf8",
  );
  fs.chmodSync(hookPath, 0o755);
}
