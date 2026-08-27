import { spawnSync } from "node:child_process";

export type GitResult = { code: number; stdout: string; stderr: string };

export type PushRefStatus = "ok" | "up_to_date" | "rejected" | "error" | "unknown";

export type PushRefResult = { status: PushRefStatus; summary: string };

export type PushResult = GitResult & { refs: Record<string, PushRefResult> };

function scoped(args: string[], paths: string[]): string[] {
  if (paths.length === 0) {
    return args;
  }
  return [...args, "--", ...paths];
}

function nonEmptyLines(text: string): string[] {
  return text.split("\n").filter((line) => line.trim() !== "");
}

export class Git {
  readonly repo: string;

  constructor(repo: string) {
    this.repo = repo;
  }

  run(args: string[], options: { cwd?: string; input?: string } = {}): GitResult {
    const proc = spawnSync("git", args, {
      cwd: options.cwd ?? this.repo,
      input: options.input,
      encoding: "utf8",
      maxBuffer: 64 * 1024 * 1024,
    });
    return {
      code: proc.status ?? 1,
      stdout: proc.stdout ?? "",
      stderr: proc.stderr ?? "",
    };
  }

  isInsideWorkTree(): boolean {
    const proc = this.run(["rev-parse", "--is-inside-work-tree"]);
    return proc.code === 0 && proc.stdout.trim() === "true";
  }

  currentBranch(): string {
    return this.run(["rev-parse", "--abbrev-ref", "HEAD"]).stdout.trim();
  }

  verifyRef(ref: string): boolean {
    return this.run(["rev-parse", "-q", "--verify", ref]).code === 0;
  }

  revParseRef(ref: string): string | null {
    const proc = this.run(["rev-parse", "-q", "--verify", ref]);
    if (proc.code !== 0) {
      return null;
    }
    return proc.stdout.trim();
  }

  revParseHead(): string {
    return this.run(["rev-parse", "HEAD"]).stdout.trim();
  }

  fetch(remote: string, branch: string): GitResult {
    return this.run(["fetch", remote, branch]);
  }

  fetchMany(remote: string, branches: string[]): GitResult {
    return this.run(["fetch", remote, ...branches]);
  }

  fetchUpdateLocalRef(remote: string, branch: string): GitResult {
    return this.run(["fetch", remote, `${branch}:${branch}`]);
  }

  fetchLocalFromTracking(branch: string): GitResult {
    return this.fetchLocalFf(`refs/remotes/origin/${branch}`, `refs/heads/${branch}`);
  }

  fetchLocalFf(src: string, dst: string): GitResult {
    return this.run(["fetch", ".", `${src}:${dst}`]);
  }

  worktreeListPorcelain(): GitResult {
    return this.run(["worktree", "list", "--porcelain"]);
  }

  checkout(ref: string): GitResult {
    return this.run(["checkout", ref]);
  }

  createBranchAt(name: string, startPoint: string): GitResult {
    return this.run(["branch", name, startPoint]);
  }

  mergeNoEdit(ref: string): GitResult {
    return this.run(["merge", "--no-edit", ref]);
  }

  mergeAbort(): GitResult {
    return this.run(["merge", "--abort"]);
  }

  mergeFfOnlyIn(worktreePath: string, ref: string): GitResult {
    return this.run(["merge", "--ff-only", ref], { cwd: worktreePath });
  }

  conflictingFiles(): string[] {
    return nonEmptyLines(this.run(["diff", "--name-only", "--diff-filter=U"]).stdout);
  }

  diffNameOnly(options: { cached?: boolean; paths?: string[] } = {}): string[] {
    const base = options.cached
      ? ["diff", "--cached", "--name-only"]
      : ["diff", "--name-only", "HEAD"];
    return nonEmptyLines(this.run(scoped(base, options.paths ?? [])).stdout);
  }

  // --untracked-files=all, because the default collapses a new directory into one
  // `?? dir/` line and the denylist would then never see the .env or log inside it.
  statusShort(paths: string[] = []): string[] {
    return nonEmptyLines(this.run(scoped(["status", "--short", "-uall"], paths)).stdout);
  }

  statusShortIn(worktreePath: string): string[] {
    return nonEmptyLines(this.run(["status", "--short"], { cwd: worktreePath }).stdout);
  }

  addUpdate(paths: string[] = []): GitResult {
    return this.run(scoped(["add", "-u"], paths));
  }

  addPath(path: string): GitResult {
    return this.run(["add", "--", path]);
  }

  commit(message: string): GitResult {
    return this.run(["commit", "-F", "-"], { input: message });
  }

  listRemotes(): string[] {
    return this.run(["remote"]).stdout.split("\n").map((line) => line.trim()).filter(Boolean);
  }

  hasUpstream(): boolean {
    return this.run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]).code === 0;
  }

  pushAtomic(remote: string, refspecs: string[], setUpstream: boolean): PushResult {
    const args = ["push", "--atomic", "--porcelain"];
    if (setUpstream) {
      args.push("-u");
    }
    const proc = this.run([...args, remote, ...refspecs]);
    return { ...proc, refs: parsePushPorcelain(proc.stdout) };
  }
}

function porcelainRefName(refspecText: string): string {
  const separator = refspecText.lastIndexOf(":");
  if (separator === -1) {
    return refspecText;
  }
  return refspecText.slice(separator + 1);
}

function porcelainStatus(flag: string): PushRefStatus {
  if (flag === "!") {
    return "rejected";
  }
  if (flag === "=") {
    return "up_to_date";
  }
  if (flag === " " || flag === "*") {
    return "ok";
  }
  return "error";
}

export function parsePushPorcelain(stdout: string): Record<string, PushRefResult> {
  const parsed: Record<string, PushRefResult> = {};
  for (const line of stdout.split("\n")) {
    if (line === "") {
      continue;
    }
    const flag = line.slice(0, 1);
    if (![" ", "*", "=", "!"].includes(flag)) {
      continue;
    }
    const parts = line.slice(1).split("\t").filter(Boolean);
    if (parts.length < 2) {
      continue;
    }
    const refName = porcelainRefName((parts[0] ?? "").trim());
    if (!refName) {
      continue;
    }
    parsed[refName] = {
      status: porcelainStatus(flag),
      summary: parts.slice(1).join("\t").trim(),
    };
  }
  return parsed;
}
