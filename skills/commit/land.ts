import { Git, type PushRefResult, type PushRefStatus, type PushResult } from "./lib/git.ts";
import { normalizeMessage, validateMessage } from "./lib/message.ts";
import {
  committed,
  detachedHead,
  emit,
  hookFailed,
  messageInvalid,
  notARepo,
  nothingToCommit,
  operationInProgress,
  promoteConflict,
  promoteFailed,
  pushFailed,
  type OutcomeName,
  type Result,
} from "./lib/outcome.ts";
import {
  computeScope,
  findWorktreeForBranch,
  isDirtyStatusLineInScope,
  MAINLINE_CANDIDATES,
  readStdin,
  resolveMainline,
} from "./lib/workspace.ts";

const IN_PROGRESS_MARKERS = ["MERGE_HEAD", "REBASE_HEAD", "CHERRY_PICK_HEAD"] as const;

const PUSH_ATTEMPTS = 3;

// Refs git could have pushed but did not because a sibling ref in the same
// --atomic batch was rejected; they name no failure of their own. Git says
// "atomic push failed" client-side and "atomic push failure" remote-side.
const ATOMIC_COLLATERAL_PATTERN = /atomic push fail/;

type PromoteTarget = "develop" | "mainline";

type PendingPushRef = { branch: string; kind: "feature" | "promote"; source?: string };

type Arguments = {
  paths: string[];
  promote: boolean;
  promoteTarget: PromoteTarget;
  noPush: boolean;
  pushRetryDelayMs: number;
};

function sleep(milliseconds: number): void {
  if (milliseconds <= 0) {
    return;
  }
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds);
}

export function parseArguments(argv: string[]): Arguments {
  const parsed: Arguments = {
    paths: [],
    promote: false,
    promoteTarget: "mainline",
    noPush: false,
    pushRetryDelayMs: 2000,
  };
  let collectingPaths = false;
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index] ?? "";
    if (argument === "--paths") {
      collectingPaths = true;
      continue;
    }
    if (argument === "--promote") {
      parsed.promote = true;
      collectingPaths = false;
      continue;
    }
    if (argument === "--no-push") {
      parsed.noPush = true;
      collectingPaths = false;
      continue;
    }
    if (argument === "--promote-to") {
      const value = argv[index + 1];
      if (value !== "develop" && value !== "mainline") {
        throw new Error("--promote-to takes develop or mainline");
      }
      parsed.promoteTarget = value;
      index += 1;
      collectingPaths = false;
      continue;
    }
    if (argument === "--push-retry-delay-ms") {
      const value = Number(argv[index + 1]);
      if (!Number.isFinite(value) || value < 0) {
        throw new Error("--push-retry-delay-ms takes a non-negative number");
      }
      parsed.pushRetryDelayMs = value;
      index += 1;
      collectingPaths = false;
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

export class Landing {
  private readonly git: Git;
  private readonly config: Arguments;
  private readonly warnings: string[] = [];
  private readonly promoted: string[] = [];
  private conflicts: string[] = [];
  private pushed = false;
  private commitHash: string | null = null;
  private deferredFeatureBranch: string | null = null;
  private noOriginPromoteWarned = false;

  constructor(repo: string, config: Arguments) {
    this.git = new Git(repo);
    this.config = config;
  }

  run(message: string): Result {
    const guard = this.guard();
    if (guard) {
      return guard;
    }

    const messageErrors = validateMessage(message);
    if (messageErrors.length > 0) {
      return messageInvalid({ errors: messageErrors });
    }

    const { changed, untracked } = computeScope(this.git, this.config.paths);
    if (changed.size === 0 && untracked.length === 0) {
      return this.landNothing();
    }

    const commitOutcome = this.commit(message, untracked);
    if (commitOutcome) {
      return this.failure(commitOutcome);
    }

    const pushOutcome = this.pushFeatureBranch();
    if (pushOutcome) {
      return this.failure(pushOutcome);
    }

    if (this.config.promote) {
      const promoteOutcome = this.promote();
      if (promoteOutcome) {
        return this.failure(promoteOutcome);
      }
    }

    return committed({
      commit: this.commitHash ?? "",
      pushed: this.pushed,
      promoted: this.promoted,
      warnings: this.warnings,
    });
  }

  private guard(): Result | null {
    if (!this.git.isInsideWorkTree()) {
      return notARepo({});
    }
    if (this.git.currentBranch() === "HEAD") {
      return detachedHead({});
    }
    for (const marker of IN_PROGRESS_MARKERS) {
      if (this.git.verifyRef(marker)) {
        return operationInProgress({ operation: marker });
      }
    }
    return null;
  }

  private landNothing(): Result {
    if (!this.config.promote) {
      return nothingToCommit({ warnings: this.warnings });
    }
    const promoteOutcome = this.promote();
    if (promoteOutcome) {
      return this.failure(promoteOutcome);
    }
    return nothingToCommit({
      pushed: this.pushed,
      promoted: this.promoted,
      warnings: this.warnings,
    });
  }

  private failure(outcome: OutcomeName): Result {
    const state = {
      ...(this.commitHash ? { commit: this.commitHash } : {}),
      pushed: this.pushed,
      promoted: this.promoted,
      warnings: this.warnings,
    };
    if (outcome === "PUSH_FAILED") {
      return pushFailed(state);
    }
    if (outcome === "PROMOTE_CONFLICT") {
      return promoteConflict({ ...state, conflicts: this.conflicts });
    }
    if (outcome === "PROMOTE_FAILED") {
      return promoteFailed(state);
    }
    if (outcome === "NOTHING_TO_COMMIT") {
      return nothingToCommit({ pushed: this.pushed, promoted: this.promoted, warnings: this.warnings });
    }
    return hookFailed({ warnings: this.warnings });
  }

  private commit(message: string, untracked: string[]): OutcomeName | null {
    this.git.addUpdate(this.config.paths);
    for (const filePath of untracked) {
      this.git.addPath(filePath);
    }

    if (this.git.diffNameOnly({ cached: true }).length === 0) {
      return "NOTHING_TO_COMMIT";
    }

    const proc = this.git.commit(normalizeMessage(message));
    if (proc.code !== 0) {
      this.warnings.push(proc.stderr.trim());
      return "HOOK_FAILED";
    }

    this.commitHash = this.git.revParseHead();
    return null;
  }

  private pushFeatureBranch(): OutcomeName | null {
    if (this.config.noPush) {
      return null;
    }
    if (!this.git.listRemotes().includes("origin")) {
      this.warnings.push("no origin remote configured; skipping push");
      return null;
    }

    const branch = this.git.currentBranch();
    if (this.config.promote) {
      this.deferredFeatureBranch = branch;
      return null;
    }

    const pending: PendingPushRef[] = [{ branch, kind: "feature" }];
    const { refsToPush, skippedRefs } = this.partitionUpToDateRefs(pending);
    if (skippedRefs.length > 0) {
      this.pushed = true;
      return null;
    }

    const outcome = this.pushPendingRefs(refsToPush, !this.git.hasUpstream(), "PUSH_FAILED");
    if (outcome) {
      return outcome;
    }

    this.pushed = true;
    return null;
  }

  private promote(): OutcomeName | null {
    const originExists = this.git.listRemotes().includes("origin");
    this.prefetchPromotionBranches(originExists);

    const mainline = resolveMainline(this.git);
    const developPresent =
      this.git.verifyRef("refs/heads/develop") || this.git.verifyRef("refs/remotes/origin/develop");

    if (!developPresent && mainline === null) {
      this.warnings.push("no develop or mainline branch; promotion skipped");
      return null;
    }

    const current = this.git.currentBranch();
    if (mainline !== null && current === mainline) {
      this.warnings.push(
        `commit landed directly on ${mainline}; promotion skipped, develop not updated`,
      );
      return null;
    }

    if (this.config.promoteTarget === "develop" && current === "develop") {
      this.warnings.push(
        "promote target is develop and current branch is develop; nothing to promote",
      );
      return null;
    }

    const hops = this.promotionHops(current, mainline);
    if (hops.length === 0) {
      this.warnings.push("current branch is develop and no mainline exists; nothing to promote");
      return null;
    }

    if (!developPresent && mainline !== null) {
      this.createDevelop(mainline, originExists);
    }

    const promotedBranches: string[] = [];
    for (const [source, destination] of hops) {
      const outcome = this.promoteHop(source, destination, originExists);
      if (outcome) {
        return outcome;
      }
      promotedBranches.push(destination);
    }

    if (!originExists) {
      return null;
    }

    const pendingRefs: PendingPushRef[] = [];
    if (this.deferredFeatureBranch) {
      pendingRefs.push({ branch: this.deferredFeatureBranch, kind: "feature" });
    }
    for (const [source, destination] of hops) {
      pendingRefs.push({ branch: destination, kind: "promote", source });
    }

    return this.pushPromotedBatch(pendingRefs, promotedBranches);
  }

  private promotionHops(current: string, mainline: string | null): Array<[string, string]> {
    if (this.config.promoteTarget === "develop") {
      return [[current, "develop"]];
    }
    if (current === "develop") {
      if (mainline === null) {
        return [];
      }
      return [["develop", mainline]];
    }
    const hops: Array<[string, string]> = [[current, "develop"]];
    if (mainline !== null) {
      hops.push(["develop", mainline]);
    }
    return hops;
  }

  private prefetchPromotionBranches(originExists: boolean): void {
    if (!originExists) {
      return;
    }
    const candidates = this.localPromotionCandidates();
    if (candidates.length === 0) {
      return;
    }
    const fetch = this.git.fetchMany("origin", candidates);
    if (fetch.code === 0) {
      return;
    }
    this.warnings.push(
      `combined promotion fetch failed; falling back to per-branch fetches: ${fetch.stderr.trim()}`,
    );
    for (const name of candidates) {
      this.git.fetch("origin", name);
    }
  }

  private localPromotionCandidates(): string[] {
    const candidates: string[] = [];
    for (const name of ["develop", ...MAINLINE_CANDIDATES]) {
      if (
        this.git.verifyRef(`refs/heads/${name}`) ||
        this.git.verifyRef(`refs/remotes/origin/${name}`)
      ) {
        candidates.push(name);
      }
    }
    return candidates;
  }

  private createDevelop(mainline: string, originExists: boolean): void {
    const startPoint =
      originExists && this.git.verifyRef(`refs/remotes/origin/${mainline}`)
        ? `origin/${mainline}`
        : mainline;
    this.git.createBranchAt("develop", startPoint);
    this.warnings.push(`develop branch did not exist; created it at ${startPoint}`);
  }

  private promoteHop(
    source: string,
    destination: string,
    originExists: boolean,
  ): OutcomeName | null {
    if (originExists) {
      const outcome = this.syncDestinationWithOrigin(destination);
      if (outcome) {
        return outcome;
      }
    }

    const fastForward = this.git.fetchLocalFf(source, destination);
    if (fastForward.code !== 0) {
      const outcome = this.handleFastForwardRefusal(source, destination, fastForward.stderr);
      if (outcome) {
        return outcome;
      }
    }

    if (originExists) {
      return null;
    }

    this.warnAboutMissingOrigin();
    this.promoted.push(destination);
    return null;
  }

  private warnAboutMissingOrigin(): void {
    if (this.noOriginPromoteWarned) {
      return;
    }
    this.warnings.push("no origin remote; promoted branches updated locally only");
    this.noOriginPromoteWarned = true;
  }

  private syncDestinationWithOrigin(destination: string, fetchRemote = false): OutcomeName | null {
    if (fetchRemote) {
      const fetch = this.git.fetch("origin", destination);
      if (fetch.code !== 0) {
        this.warnings.push(
          `could not fetch origin ${destination}; continuing with local state: ${fetch.stderr.trim()}`,
        );
      }
    }

    if (this.git.verifyRef(`refs/remotes/origin/${destination}`)) {
      return this.handleDestinationOriginUpdate(
        destination,
        this.git.fetchLocalFromTracking(destination),
      );
    }

    return this.handleDestinationOriginUpdate(
      destination,
      this.git.fetchUpdateLocalRef("origin", destination),
    );
  }

  private handleDestinationOriginUpdate(
    destination: string,
    update: { code: number; stderr: string },
  ): OutcomeName | null {
    if (update.code === 0) {
      return null;
    }

    const stderr = update.stderr;
    if (stderr.includes("checked out")) {
      return this.fastForwardInHoldingWorktree(`origin/${destination}`, destination);
    }

    if (stderr.includes("non-fast-forward") || stderr.includes("rejected")) {
      const outcome = this.mergeForPromotion(`origin/${destination}`, destination);
      if (outcome) {
        return outcome;
      }
      this.warnings.push(
        `local ${destination} diverged from origin/${destination}; merged origin/${destination} into ${destination} and continued promotion`,
      );
      return null;
    }

    this.warnings.push(
      `could not update local ${destination} from origin, continuing with local state: ${stderr.trim()}`,
    );
    return null;
  }

  private handleFastForwardRefusal(
    source: string,
    destination: string,
    stderr: string,
  ): OutcomeName | null {
    if (stderr.includes("checked out")) {
      return this.fastForwardInHoldingWorktree(source, destination);
    }
    if (!stderr.includes("non-fast-forward") && !stderr.includes("rejected")) {
      this.warnings.push(
        `could not fast-forward ${destination} from ${source}; promotion stopped: ${stderr.trim()}`,
      );
      return "PROMOTE_FAILED";
    }
    return this.mergeForPromotion(source, destination);
  }

  private fastForwardInHoldingWorktree(source: string, destination: string): OutcomeName | null {
    const worktrees = this.git.worktreeListPorcelain();
    const holder =
      worktrees.code === 0 ? findWorktreeForBranch(worktrees.stdout, destination) : null;

    if (holder === null) {
      this.warnings.push(
        `${destination} is checked out in another worktree but the holding worktree could not be found; promotion stopped`,
      );
      return "PROMOTE_FAILED";
    }

    const dirty = this.git.statusShortIn(holder).filter((line) => !line.startsWith("??"));
    if (dirty.length > 0) {
      this.warnings.push(
        `${destination} is checked out in ${holder} and has uncommitted changes; promotion stopped`,
      );
      return "PROMOTE_FAILED";
    }

    const merge = this.git.mergeFfOnlyIn(holder, source);
    if (merge.code !== 0) {
      this.warnings.push(
        `could not fast-forward ${destination} from ${source} in ${holder}; promotion stopped: ${merge.stderr.trim()}`,
      );
      return "PROMOTE_FAILED";
    }

    this.warnings.push(`${destination} was fast-forwarded in its holding worktree: ${holder}`);
    return null;
  }

  private mergeForPromotion(source: string, destination: string): OutcomeName | null {
    const dirty = this.git
      .statusShort()
      .filter((line) => !line.startsWith("??") && isDirtyStatusLineInScope(line));
    if (dirty.length > 0) {
      this.warnings.push(`working tree not clean; cannot merge ${source} into ${destination}`);
      return "PROMOTE_FAILED";
    }

    const original = this.git.currentBranch();
    const checkoutDestination = this.git.checkout(destination);
    if (checkoutDestination.code !== 0) {
      this.warnings.push(
        `could not check out ${destination} for merge; promotion stopped: ${checkoutDestination.stderr.trim()}`,
      );
      return "PROMOTE_FAILED";
    }

    const merge = this.git.mergeNoEdit(source);
    if (merge.code !== 0) {
      this.conflicts = this.git.conflictingFiles();
      this.git.mergeAbort();
      const restoreAfterConflict = this.git.checkout(original);
      if (restoreAfterConflict.code !== 0) {
        this.warnings.push(
          `aborted the conflicted merge of ${source} into ${destination} but could not return to ${original}; repository left on ${destination}: ${restoreAfterConflict.stderr.trim()}`,
        );
      }
      this.warnings.push(
        `merge conflict promoting ${source} into ${destination}: ${this.conflicts.join(", ")}`,
      );
      return "PROMOTE_CONFLICT";
    }

    const restore = this.git.checkout(original);
    if (restore.code !== 0) {
      this.warnings.push(
        `merged ${source} into ${destination} locally but could not return to ${original}; repository left on ${destination}, push of ${destination} skipped: ${restore.stderr.trim()}`,
      );
      return "PROMOTE_FAILED";
    }
    return null;
  }

  private resyncPromotedDestination(
    source: string | undefined,
    destination: string,
  ): OutcomeName | null {
    const outcome = this.syncDestinationWithOrigin(destination, true);
    if (outcome) {
      return outcome;
    }
    if (source === undefined) {
      return null;
    }
    const fastForward = this.git.fetchLocalFf(source, destination);
    if (fastForward.code === 0) {
      return null;
    }
    return this.handleFastForwardRefusal(source, destination, fastForward.stderr);
  }

  private partitionUpToDateRefs(pendingRefs: PendingPushRef[]): {
    refsToPush: PendingPushRef[];
    skippedRefs: PendingPushRef[];
  } {
    const refsToPush: PendingPushRef[] = [];
    const skippedRefs: PendingPushRef[] = [];
    for (const pendingRef of pendingRefs) {
      if (this.originRefIsUpToDate(pendingRef.branch)) {
        skippedRefs.push(pendingRef);
        continue;
      }
      refsToPush.push(pendingRef);
    }
    return { refsToPush, skippedRefs };
  }

  private originRefIsUpToDate(branch: string): boolean {
    const local = this.git.revParseRef(`refs/heads/${branch}`);
    if (local === null) {
      return false;
    }
    const remote = this.git.revParseRef(`refs/remotes/origin/${branch}`);
    if (remote === null) {
      return false;
    }
    return local === remote;
  }

  private pushPendingRefs(
    pendingRefs: PendingPushRef[],
    setUpstream: boolean,
    exhaustedOutcome: OutcomeName,
  ): OutcomeName | null {
    if (pendingRefs.length === 0) {
      return null;
    }

    const refspecs = pendingRefs.map((pendingRef) => branchRefspec(pendingRef.branch));
    for (let attempt = 1; attempt <= PUSH_ATTEMPTS; attempt += 1) {
      const push = this.git.pushAtomic("origin", refspecs, setUpstream);
      const statuses = statusByBranch(push, pendingRefs);
      if (allRefsPushed(statuses)) {
        return null;
      }
      if (hasCauseFailure(statuses)) {
        return exhaustedOutcome;
      }

      this.appendBatchTransportWarnings(pendingRefs, attempt, push.stderr.trim());
      if (attempt === PUSH_ATTEMPTS) {
        break;
      }
      sleep(this.config.pushRetryDelayMs);
    }
    return exhaustedOutcome;
  }

  private pushPromotedBatch(
    pendingRefs: PendingPushRef[],
    promotedBranches: string[],
  ): OutcomeName | null {
    const { refsToPush, skippedRefs } = this.partitionUpToDateRefs(pendingRefs);
    this.markSkippedPushRefs(skippedRefs, promotedBranches);
    if (refsToPush.length === 0) {
      return null;
    }

    const push = this.pushBatchUntilPerRefResult(refsToPush);
    if (push === null) {
      return "PROMOTE_FAILED";
    }

    const statuses = statusByBranch(push, refsToPush);
    if (refsToPush.some((ref) => ref.kind === "feature" && isCauseFailure(statuses[ref.branch]))) {
      return "PUSH_FAILED";
    }

    const errorRefs = refsToPush.filter(
      (ref) => ref.kind === "promote" && isCauseFailureOf(statuses[ref.branch], "error"),
    );
    if (errorRefs.length > 0) {
      this.appendPromoteFailureWarnings(errorRefs, push, 1);
      return "PROMOTE_FAILED";
    }

    const rejectedRefs = refsToPush.filter(
      (ref) => ref.kind === "promote" && isCauseFailureOf(statuses[ref.branch], "rejected"),
    );
    if (rejectedRefs.length > 0) {
      return this.resyncAndRetryRejectedPromotedRefs(
        refsToPush,
        rejectedRefs,
        promotedBranches,
        push,
      );
    }

    this.markSuccessfulPushRefs(refsToPush, promotedBranches);
    return null;
  }

  private pushBatchUntilPerRefResult(pendingRefs: PendingPushRef[]): PushResult | null {
    const refspecs = pendingRefs.map((pendingRef) => branchRefspec(pendingRef.branch));
    for (let attempt = 1; attempt <= PUSH_ATTEMPTS; attempt += 1) {
      const push = this.git.pushAtomic("origin", refspecs, false);
      const statuses = statusByBranch(push, pendingRefs);
      if (allRefsPushed(statuses) || hasCauseFailure(statuses)) {
        return push;
      }

      this.appendBatchTransportWarnings(pendingRefs, attempt, push.stderr.trim());
      if (attempt === PUSH_ATTEMPTS) {
        break;
      }
      sleep(this.config.pushRetryDelayMs);
    }
    return null;
  }

  private resyncAndRetryRejectedPromotedRefs(
    refsToPush: PendingPushRef[],
    rejectedRefs: PendingPushRef[],
    promotedBranches: string[],
    initialPush: PushResult,
  ): OutcomeName | null {
    this.appendPromoteFailureWarnings(rejectedRefs, initialPush, 1);
    for (const pendingRef of rejectedRefs) {
      const outcome = this.resyncPromotedDestination(pendingRef.source, pendingRef.branch);
      if (outcome) {
        return outcome;
      }
    }

    // The whole batch is retried, not only the rejected refs: --atomic means
    // none of the siblings landed either.
    const retryPush = this.git.pushAtomic(
      "origin",
      refsToPush.map((pendingRef) => branchRefspec(pendingRef.branch)),
      false,
    );
    if (allRefsPushed(statusByBranch(retryPush, refsToPush))) {
      this.markSuccessfulPushRefs(refsToPush, promotedBranches);
      return null;
    }

    this.appendPromoteFailureWarnings(
      refsToPush.filter((pendingRef) => pendingRef.kind === "promote"),
      retryPush,
      2,
    );
    return "PROMOTE_FAILED";
  }

  private appendPromoteFailureWarnings(
    pendingRefs: PendingPushRef[],
    push: PushResult,
    attempt: number,
  ): void {
    for (const pendingRef of pendingRefs) {
      this.warnings.push(
        `promote push ${pendingRef.branch} attempt ${attempt}/${PUSH_ATTEMPTS} failed: ${pushFailureText(push, pendingRef.branch)}`,
      );
    }
  }

  private appendBatchTransportWarnings(
    pendingRefs: PendingPushRef[],
    attempt: number,
    stderr: string,
  ): void {
    for (const pendingRef of pendingRefs) {
      if (pendingRef.kind === "feature") {
        this.warnings.push(`push attempt ${attempt}/${PUSH_ATTEMPTS} failed: ${stderr}`);
        continue;
      }
      this.warnings.push(
        `promote push ${pendingRef.branch} attempt ${attempt}/${PUSH_ATTEMPTS} failed: ${stderr}`,
      );
    }
  }

  private markSkippedPushRefs(skippedRefs: PendingPushRef[], promotedBranches: string[]): void {
    for (const pendingRef of skippedRefs) {
      if (pendingRef.kind === "feature") {
        this.pushed = true;
        continue;
      }
      this.appendPromotedInHopOrder(pendingRef.branch, promotedBranches);
    }
  }

  private markSuccessfulPushRefs(pendingRefs: PendingPushRef[], promotedBranches: string[]): void {
    for (const pendingRef of pendingRefs) {
      if (pendingRef.kind === "feature") {
        this.pushed = true;
        continue;
      }
      this.appendPromotedInHopOrder(pendingRef.branch, promotedBranches);
    }
  }

  private appendPromotedInHopOrder(branch: string, promotedBranches: string[]): void {
    if (!promotedBranches.includes(branch)) {
      return;
    }
    if (this.promoted.includes(branch)) {
      return;
    }
    this.promoted.push(branch);
  }
}

function branchRefspec(branch: string): string {
  return `refs/heads/${branch}:refs/heads/${branch}`;
}

function pushRefResult(push: PushResult, branch: string): PushRefResult | undefined {
  return push.refs[`refs/heads/${branch}`] ?? push.refs[branch];
}

function statusByBranch(
  push: PushResult,
  pendingRefs: PendingPushRef[],
): Record<string, PushRefResult> {
  const statuses: Record<string, PushRefResult> = {};
  for (const pendingRef of pendingRefs) {
    const parsed = pushRefResult(push, pendingRef.branch);
    if (parsed) {
      statuses[pendingRef.branch] = parsed;
      continue;
    }
    statuses[pendingRef.branch] = {
      status: push.code === 0 ? "ok" : "unknown",
      summary: "",
    };
  }
  return statuses;
}

function isCauseFailure(entry: PushRefResult | undefined): boolean {
  if (!entry) {
    return false;
  }
  if (entry.status !== "rejected" && entry.status !== "error") {
    return false;
  }
  return !ATOMIC_COLLATERAL_PATTERN.test(entry.summary);
}

function isCauseFailureOf(entry: PushRefResult | undefined, status: PushRefStatus): boolean {
  return isCauseFailure(entry) && entry?.status === status;
}

function allRefsPushed(statuses: Record<string, PushRefResult>): boolean {
  return Object.values(statuses).every(
    (entry) => entry.status === "ok" || entry.status === "up_to_date",
  );
}

function hasCauseFailure(statuses: Record<string, PushRefResult>): boolean {
  return Object.values(statuses).some((entry) => isCauseFailure(entry));
}

function pushFailureText(push: PushResult, branch: string): string {
  const parsed = pushRefResult(push, branch);
  const stderr = push.stderr.trim();
  if (parsed?.summary && stderr) {
    return `${parsed.summary}: ${stderr}`;
  }
  if (parsed?.summary) {
    return parsed.summary;
  }
  if (stderr) {
    return stderr;
  }
  return push.stdout.trim();
}

async function main(): Promise<never> {
  const config = parseArguments(process.argv.slice(2));
  const message = await readStdin();
  return emit(new Landing(process.cwd(), config).run(message));
}

if (process.argv[1] && import.meta.filename === process.argv[1]) {
  await main();
}
