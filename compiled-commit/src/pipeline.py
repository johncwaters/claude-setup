"""Typed state machine driving the compiled commit workflow (SPEC Stages 1-8)."""

import json
import os
import sys
import time
from dataclasses import dataclass

from src.failures import Outcome, PipelineResult
from src.git_ops import GitOps
from src.validators import (
    apply_patch_gate,
    build_diff_packet,
    render_message,
    validate_message,
)
from src.schemas import CODE_REVIEW_SCHEMA, COMMIT_MESSAGE_SCHEMA, SLOP_REVIEW_SCHEMA

INTEGRATION_BRANCH_CANDIDATES = ("develop", "main", "master")

MAINLINE_CANDIDATES = ("main", "master")

DENYLIST_DIR_PREFIXES = ("node_modules/", "dist/", "__pycache__/", ".compiled-commit-tmp/")

PUSH_ATTEMPTS = 3

CONVENTION_NOTE = (
    "Commit message convention: header is `<type>(<scope>): <description>` or "
    "`<type>: <description>` with no scope. type is one of feat, fix, refactor, chore, "
    "docs, test, style, perf, build, ci. description is a single line, 72 characters or "
    "fewer, no trailing period. Then a blank line and a body paragraph. Then, when the "
    "change is not trivial, a blank line and trailer lines: Constraint, Rejected, "
    "Directive (any of these three may be omitted if not applicable), Confidence "
    "(high/medium/low, required), Scope-risk (narrow/moderate/broad, required), "
    "Not-tested (optional). Never use an em dash, en dash, or emoji anywhere in the "
    "message. Set trivial true and omit all trailers only for genuinely trivial changes "
    "(e.g. a version bump with no logic change)."
)


def is_denylisted(path):
    normalized = path.replace("\\", "/")
    if normalized.startswith("./"):
        normalized = normalized[2:]
    for prefix in DENYLIST_DIR_PREFIXES:
        if normalized.startswith(prefix) or f"/{prefix}" in normalized:
            return True
    basename = normalized.rsplit("/", 1)[-1]
    if basename.startswith(".env"):
        return True
    if basename.endswith(".log"):
        return True
    return False


def compute_scope(git, paths=None):
    """Stage 3 SCOPE: returns (changed: set[str], untracked: list[str])."""
    changed = set(git.diff_name_only(cached=False, paths=paths)) | set(
        git.diff_name_only(cached=True, paths=paths)
    )
    untracked = []
    for line in git.status_short(paths=paths):
        if not line.startswith("??"):
            continue
        path = line[3:].strip()
        if is_denylisted(path):
            continue
        untracked.append(path)
    return changed, untracked


def is_dirty_status_line_in_scope(line):
    path = line[3:].strip()
    return not is_denylisted(path)


def resolve_integration_branch(git):
    for name in INTEGRATION_BRANCH_CANDIDATES:
        if git.verify_ref(f"refs/heads/{name}"):
            return name
        if git.verify_ref(f"refs/remotes/origin/{name}"):
            return name
    return None


def resolve_mainline(git):
    for name in MAINLINE_CANDIDATES:
        if git.verify_ref(f"refs/heads/{name}"):
            return name
        if git.verify_ref(f"refs/remotes/origin/{name}"):
            return name
    return None


def find_worktree_for_branch(porcelain_text, branch):
    target = f"refs/heads/{branch}"
    worktree_path = None
    worktree_branch = None
    for line in porcelain_text.splitlines() + [""]:
        if not line.strip():
            if worktree_path and worktree_branch == target:
                return worktree_path
            worktree_path = None
            worktree_branch = None
            continue
        if line.startswith("worktree "):
            worktree_path = line[len("worktree "):]
            continue
        if line.startswith("branch "):
            worktree_branch = line[len("branch "):]
    return None


def _intent_block(context):
    """Author-intent lines shared by the slop and review prompts."""
    if not context:
        return []
    return [
        "Author intent for this change (trusted, from the invoking session):",
        context,
        "Judge the diff against this intent. Do not flag a decision the intent "
        "explicitly documents (such as a removal, reversal, or scope choice it "
        "explains) unless it introduces a concrete defect visible in the diff.",
        "",
    ]


def _build_slop_prompt(packet, prior_error=None, context=None):
    parts = [
        "Task: find AI-authored slop in this diff (dead code, duplicated helpers, "
        "useless comments, over-abstraction). Optionally propose a unified diff patch "
        "(paths relative to repo root) that fixes it. Only include a patch you are "
        "confident applies cleanly; omit it (null) otherwise.",
        "",
        *_intent_block(context),
        packet.text,
    ]
    if prior_error:
        parts.append("")
        parts.append(f"Previous patch failed to apply, fix it or return null: {prior_error}")
    return "\n".join(parts)


def _build_review_prompt(packet, context=None):
    return "\n".join(
        [
            "Task: review this diff for defects. Rate each finding severity "
            "critical/high/medium/low. critical or high findings block the commit.",
            "Reserve critical and high strictly for concrete defects visible in the "
            "diff itself: logic bugs, security holes, data loss, broken syntax, "
            "references to symbols the diff removed. Process concerns (missing tests, "
            "unverified builds, unreviewed dependency bumps, lockfile churn, style) "
            "are medium at most, never blocking.",
            "",
            *_intent_block(context),
            packet.text,
        ]
    )


def _build_message_prompt(packet, branch, subjects, context=None):
    subjects_text = "\n".join(f"- {s}" for s in subjects) or "(no prior commits)"
    lines = [
        "Task: write a commit message for this diff.",
        CONVENTION_NOTE,
        f"branch: {branch}",
        "recent commit subjects:",
        subjects_text,
    ]
    if context:
        lines += ["author intent (use it to explain the why):", context]
    lines += ["", packet.text]
    return "\n".join(lines)


@dataclass
class PipelineConfig:
    repo: str
    workspace: str = None
    message: str = None
    no_sync: bool = False
    skip_deslop: bool = False
    skip_review: bool = False
    no_push: bool = False
    promote: bool = False
    promote_target: str = "mainline"
    llm_client: object = None
    fixture_prefix: str = "run"
    context: str = None
    paths: list = None
    push_retry_delay_sec: float = 2.0

    def __post_init__(self):
        if self.workspace is None:
            self.workspace = self.repo


@dataclass
class PendingPushRef:
    branch: str
    kind: str
    source: str = None


class Pipeline:
    def __init__(self, config):
        self.config = config
        self.git = GitOps(config.repo)
        self.llm = config.llm_client
        self.result = PipelineResult()
        self.start_time = time.monotonic()
        self.changed_files = set()
        self.untracked_files = []
        self.rendered_message = None
        self._diff_packet = None
        self._no_origin_promote_warned = False
        self._checkpoint_warning_recorded = False
        self._deferred_feature_branch = None

    def run(self):
        if not self._workspace_confined():
            self.result.warnings.append(
                "workspace confinement violated: repo is not inside the caller-supplied workspace"
            )
            return self._finish(Outcome.GATE_FAILED)

        outcome = self._run_stage("PREFLIGHT", self._preflight)
        if outcome:
            return self._finish(outcome)

        outcome = self._run_stage("SYNC", self._sync)
        if outcome:
            return self._finish(outcome)

        scope_outcome = self._run_stage("SCOPE", self._scope)
        if scope_outcome:
            if scope_outcome == Outcome.NOTHING_TO_COMMIT and self.config.promote:
                promote_outcome = self._run_stage("PROMOTE", self._promote)
                if promote_outcome:
                    return self._finish(promote_outcome)
                return self._finish(Outcome.NOTHING_TO_COMMIT)
            return self._finish(scope_outcome)

        self._run_stage("SLOP", self._slop)

        outcome = self._run_stage("REVIEW", self._review)
        if outcome:
            return self._finish(outcome)

        outcome = self._run_stage("MESSAGE", self._message)
        if outcome:
            return self._finish(outcome)

        outcome = self._run_stage("COMMIT", self._commit)
        if outcome != Outcome.COMMITTED:
            return self._finish(outcome)

        push_outcome = self._run_stage("PUSH", self._push)
        if push_outcome:
            return self._finish(push_outcome)

        if self.config.promote:
            promote_outcome = self._run_stage("PROMOTE", self._promote)
            if promote_outcome:
                return self._finish(promote_outcome)

        return self._finish(Outcome.COMMITTED)

    def _run_stage(self, stage_name, stage_func):
        print(f"[{time.strftime('%H:%M:%S')}] stage {stage_name}", file=sys.stderr)
        stage_start = time.monotonic()
        outcome = stage_func()
        seconds = time.monotonic() - stage_start
        self.result.stage_times.append({"stage": stage_name, "seconds": seconds})
        completed_stage = self.result.stages_run[-1] if self.result.stages_run else stage_name
        self._checkpoint(completed_stage)
        return outcome

    def _workspace_confined(self):
        repo_real = os.path.realpath(self.config.repo)
        workspace_real = os.path.realpath(self.config.workspace)
        if repo_real == workspace_real:
            return True
        return repo_real.startswith(workspace_real + os.sep)

    def _finish(self, outcome):
        self.result.outcome = outcome
        self.result.git_op_count = self.git.op_count
        self.result.wall_time_sec = time.monotonic() - self.start_time
        self._write_result_snapshot(checkpoint=False, stage=self._last_completed_stage())
        return self.result

    def _last_completed_stage(self):
        if self.result.stages_run:
            return self.result.stages_run[-1]
        return None

    def _checkpoint(self, stage_name):
        self.result.git_op_count = self.git.op_count
        self.result.wall_time_sec = time.monotonic() - self.start_time
        self._write_result_snapshot(checkpoint=True, stage=stage_name)

    def _write_result_snapshot(self, checkpoint, stage):
        data = self.result.to_dict()
        data["checkpoint"] = checkpoint
        data["stage"] = stage
        try:
            path = os.path.join(self._temp_dir(), "checkpoint.json")
            with open(path, "w", encoding="utf-8", newline="\n") as handle:
                handle.write(json.dumps(data, indent=2))
        except OSError as error:
            if self._checkpoint_warning_recorded:
                return
            self.result.warnings.append(f"could not write checkpoint: {error}")
            self._checkpoint_warning_recorded = True

    # -- Stage 1 --------------------------------------------------------

    def _preflight(self):
        self.result.stages_run.append("PREFLIGHT")
        if not self.git.is_inside_work_tree():
            return Outcome.NOT_A_REPO
        if self.git.current_branch() == "HEAD":
            return Outcome.DETACHED_HEAD
        for marker in ("MERGE_HEAD", "REBASE_HEAD", "CHERRY_PICK_HEAD"):
            if self.git.verify_ref(marker):
                return Outcome.OPERATION_IN_PROGRESS
        return None

    # -- Stage 2 --------------------------------------------------------

    def _sync(self):
        if self.config.no_sync or self.llm.mode == "replay":
            self.result.stages_run.append("SYNC(skipped)")
            return None

        self.result.stages_run.append("SYNC")
        integration = resolve_integration_branch(self.git)
        if integration is None:
            self.result.warnings.append(
                "no integration branch found (develop/main/master); skipping sync"
            )
            return None

        current = self.git.current_branch()
        fetch = self.git.fetch("origin", integration)
        if fetch.returncode != 0:
            self.result.warnings.append(
                f"git fetch origin {integration} failed; skipping sync: {fetch.stderr.strip()}"
            )
            return None

        if current == integration:
            return self._handle_merge_result(self.git.merge_no_edit(f"origin/{integration}"))

        update = self.git.fetch_update_local_ref("origin", integration)
        if update.returncode != 0:
            if "checked out" in update.stderr:
                self.result.warnings.append(
                    "integration branch checked out in another worktree; merging origin/<branch> directly"
                )
                return self._handle_merge_result(self.git.merge_no_edit(f"origin/{integration}"))
            return Outcome.SYNC_DIVERGED

        return self._handle_merge_result(self.git.merge_no_edit(integration))

    def _handle_merge_result(self, proc):
        if proc.returncode == 0:
            return None
        conflicting = self.git.conflicting_files()
        self.git.merge_abort()
        self.result.warnings.append(f"merge conflict in: {', '.join(conflicting)}")
        return Outcome.MERGE_CONFLICT

    # -- Stage 3 --------------------------------------------------------

    def _scope(self):
        self.result.stages_run.append("SCOPE")
        changed, untracked = compute_scope(self.git, paths=self.config.paths)
        if not changed and not untracked:
            return Outcome.NOTHING_TO_COMMIT
        self.changed_files = changed
        self.untracked_files = untracked
        return None

    # -- Stage 4 --------------------------------------------------------

    def _build_packet(self):
        if self._diff_packet is None:
            self._diff_packet = self._compute_packet()
        return self._diff_packet

    def _compute_packet(self):
        status_lines = "\n".join(self.git.status_short(paths=self.config.paths))
        branch = self.git.current_branch()
        return build_diff_packet(
            self.git, self.untracked_files, status_lines, branch, paths=self.config.paths
        )

    def _rescope_and_rebuild(self):
        self.result.stages_run.append("SCOPE(rerun)")
        changed, untracked = compute_scope(self.git, paths=self.config.paths)
        self.changed_files = changed
        self.untracked_files = untracked
        self._diff_packet = None
        self._diff_packet = self._compute_packet()

    # -- Stage 5 --------------------------------------------------------

    def _slop(self):
        if self.config.skip_deslop:
            self.result.stages_run.append("SLOP(skipped)")
            return

        self.result.stages_run.append("SLOP")
        packet = self._build_packet()
        prompt = _build_slop_prompt(packet, context=self.config.context)
        parsed, usage, errors = self.llm.call(
            name="slop_review",
            key=self._fixture_key("slop_review"),
            prompt_body=prompt,
            schema=SLOP_REVIEW_SCHEMA,
            max_retries=2,
        )
        self.result.llm_usage.extend(usage)

        if parsed is None:
            self.result.warnings.append("slop_review call failed: " + "; ".join(errors))
            return

        for finding in parsed.get("findings") or []:
            self.result.findings.append({"stage": "slop", **finding})

        patch = parsed.get("patch")
        if not patch:
            return

        self._apply_slop_patch(patch, packet)

    def _apply_slop_patch(self, patch, packet):
        applied, stderr = apply_patch_gate(self.git, patch, self._temp_dir())
        if applied:
            self._rescope_and_rebuild()
            return

        prompt = _build_slop_prompt(packet, prior_error=stderr, context=self.config.context)
        parsed, usage, _errors = self.llm.call(
            name="slop_review",
            key=self._fixture_key("slop_review_retry"),
            prompt_body=prompt,
            schema=SLOP_REVIEW_SCHEMA,
            max_retries=0,
        )
        self.result.llm_usage.extend(usage)

        retry_patch = parsed.get("patch") if parsed else None
        if not retry_patch:
            self.result.warnings.append("SLOP_PATCH_INVALID: retry produced no usable patch")
            return

        applied2, stderr2 = apply_patch_gate(self.git, retry_patch, self._temp_dir(), filename="slop_patch_retry.diff")
        if not applied2:
            self.result.warnings.append(f"SLOP_PATCH_INVALID: {stderr2.strip()}")
            return

        self._rescope_and_rebuild()

    # -- Stage 6 --------------------------------------------------------

    def _review(self):
        if self.config.skip_review:
            self.result.stages_run.append("REVIEW(skipped)")
            return None

        self.result.stages_run.append("REVIEW")
        packet = self._build_packet()
        prompt = _build_review_prompt(packet, context=self.config.context)
        parsed, usage, _errors = self.llm.call(
            name="code_review",
            key=self._fixture_key("code_review"),
            prompt_body=prompt,
            schema=CODE_REVIEW_SCHEMA,
            max_retries=1,
        )
        self.result.llm_usage.extend(usage)

        if parsed is None:
            return Outcome.REVIEW_DEAD

        all_files = self.changed_files | set(self.untracked_files)
        kept_findings = []
        for finding in parsed.get("findings") or []:
            if finding.get("file") not in all_files:
                self.result.warnings.append(
                    f"review finding for unknown file dropped: {finding.get('file')}"
                )
                continue
            kept_findings.append(finding)

        has_blocking = any(f.get("severity") in ("critical", "high") for f in kept_findings)
        self.result.findings.extend({"stage": "review", **f} for f in kept_findings)

        if has_blocking:
            return Outcome.REVIEW_BLOCKED

        if parsed.get("verdict") == "block":
            self.result.warnings.append(
                "review verdict 'block' with only medium/low findings downgraded to approve"
            )

        return None

    # -- Stage 7 --------------------------------------------------------

    def _message(self):
        if self.config.message:
            self.result.stages_run.append("MESSAGE(skipped)")
            self.rendered_message = self.config.message
            self.result.commit_message = self.rendered_message
            return None

        self.result.stages_run.append("MESSAGE")
        packet = self._build_packet()
        branch = self.git.current_branch()
        subjects = self.git.log_subjects(10)
        prompt = _build_message_prompt(packet, branch, subjects, self.config.context)

        parsed, usage, _errors = self.llm.call(
            name="commit_message",
            key=self._fixture_key("commit_message"),
            prompt_body=prompt,
            schema=COMMIT_MESSAGE_SCHEMA,
            max_retries=2,
            extra_validate=validate_message,
        )
        self.result.llm_usage.extend(usage)

        if parsed is None:
            return Outcome.MESSAGE_INVALID

        self.rendered_message = render_message(parsed)
        self.result.commit_message = self.rendered_message
        return None

    # -- Stage 8 --------------------------------------------------------

    def _commit(self):
        self.result.stages_run.append("COMMIT")
        self.git.add_update(paths=self.config.paths)
        for path in self.untracked_files:
            self.git.add_path(path)

        staged = self.git.diff_name_only(cached=True)
        if not staged:
            return Outcome.NOTHING_TO_COMMIT

        message_path = self._write_workspace_temp("commit_message.txt", self.rendered_message)
        try:
            proc = self.git.commit(message_path)
        finally:
            if os.path.exists(message_path):
                os.remove(message_path)

        if proc.returncode != 0:
            self.result.warnings.append((proc.stderr or "").strip())
            return Outcome.HOOK_FAILED

        self.result.commit_hash = self.git.rev_parse_head()
        return Outcome.COMMITTED

    # -- Stage 9 --------------------------------------------------------

    def _push(self):
        if self.config.no_push:
            self.result.stages_run.append("PUSH(skipped)")
            return None

        self.result.stages_run.append("PUSH")
        if "origin" not in self.git.list_remotes():
            self.result.warnings.append("no origin remote configured; skipping push")
            return None

        branch = self.git.current_branch()
        if self.config.promote:
            self._deferred_feature_branch = branch
            return None

        pending_refs = [PendingPushRef(branch=branch, kind="feature")]
        refs_to_push, skipped_refs = self._filter_up_to_date_refs(pending_refs)
        if skipped_refs:
            self.result.pushed = True
            return None

        outcome = self._push_pending_refs(
            refs_to_push,
            set_upstream=not self.git.has_upstream(),
            exhausted_outcome=Outcome.PUSH_FAILED,
        )
        if outcome:
            return outcome

        self.result.pushed = True
        return None

    # -- Stage 10 -------------------------------------------------------

    def _promote(self):
        if not self.config.promote:
            return None

        origin_exists = "origin" in self.git.list_remotes()
        self._prefetch_promotion_branches(origin_exists)

        mainline = resolve_mainline(self.git)
        develop_present = self.git.verify_ref("refs/heads/develop") or self.git.verify_ref(
            "refs/remotes/origin/develop"
        )

        if not develop_present and mainline is None:
            self.result.stages_run.append("PROMOTE(skipped)")
            self.result.warnings.append("no develop or mainline branch; promotion skipped")
            return None

        current = self.git.current_branch()
        if mainline is not None and current == mainline:
            self.result.stages_run.append("PROMOTE(skipped)")
            self.result.warnings.append(
                f"commit landed directly on {mainline}; promotion skipped, develop not updated"
            )
            return None

        if self.config.promote_target == "develop" and current == "develop":
            self.result.stages_run.append("PROMOTE(skipped)")
            self.result.warnings.append(
                "promote target is develop and current branch is develop; nothing to promote"
            )
            return None

        hops = self._promotion_hops(current, mainline)
        if not hops:
            self.result.stages_run.append("PROMOTE(skipped)")
            self.result.warnings.append(
                "current branch is develop and no mainline exists; nothing to promote"
            )
            return None

        self.result.stages_run.append("PROMOTE")

        if not develop_present:
            self._create_develop(mainline, origin_exists)

        promoted_branches = []
        for src, dst in hops:
            outcome = self._promote_hop(src, dst, origin_exists)
            if outcome:
                return outcome
            promoted_branches.append(dst)

        self.result.stages_run.append("PROMOTE(merged)")
        self._checkpoint("PROMOTE(merged)")

        if not origin_exists:
            return None

        pending_refs = []
        if self._deferred_feature_branch:
            pending_refs.append(PendingPushRef(branch=self._deferred_feature_branch, kind="feature"))
        pending_refs.extend(
            PendingPushRef(branch=dst, kind="promote", source=src)
            for src, dst in hops
        )

        outcome = self._push_promoted_batch(pending_refs, promoted_branches)
        if outcome:
            return outcome

        self.result.stages_run.append("PROMOTE(pushed)")
        self._checkpoint("PROMOTE(pushed)")
        return None

    def _promotion_hops(self, current, mainline):
        if self.config.promote_target == "develop":
            return [(current, "develop")]
        if current == "develop":
            if mainline is None:
                return []
            return [("develop", mainline)]
        hops = [(current, "develop")]
        if mainline is not None:
            hops.append(("develop", mainline))
        return hops

    def _prefetch_promotion_branches(self, origin_exists):
        if not origin_exists:
            return

        candidates = self._local_promotion_candidates()
        if not candidates:
            return

        fetch = self.git.fetch_many("origin", candidates)
        if fetch.returncode == 0:
            return

        self.result.warnings.append(
            "combined promotion fetch failed; falling back to per-branch fetches: "
            f"{(fetch.stderr or '').strip()}"
        )
        for name in candidates:
            self.git.fetch("origin", name)

    def _local_promotion_candidates(self):
        candidates = []
        for name in ("develop",) + MAINLINE_CANDIDATES:
            if self.git.verify_ref(f"refs/heads/{name}"):
                candidates.append(name)
                continue
            if self.git.verify_ref(f"refs/remotes/origin/{name}"):
                candidates.append(name)
        return candidates

    def _create_develop(self, mainline, origin_exists):
        start_point = mainline
        if origin_exists and self.git.verify_ref(f"refs/remotes/origin/{mainline}"):
            start_point = f"origin/{mainline}"
        self.git.create_branch_at("develop", start_point)
        self.result.warnings.append(
            f"develop branch did not exist; created it at {start_point}"
        )

    def _promote_hop(self, src, dst, origin_exists):
        if origin_exists:
            outcome = self._sync_dst_with_origin(dst)
            if outcome:
                return outcome

        ff = self.git.fetch_local_ff(src, dst)
        if ff.returncode != 0:
            outcome = self._handle_ff_refusal(src, dst, ff.stderr or "")
            if outcome:
                return outcome

        if origin_exists:
            return None

        if not self._no_origin_promote_warned:
            self.result.warnings.append(
                "no origin remote; promoted branches updated locally only"
            )
            self._no_origin_promote_warned = True
        self.result.promoted.append(dst)
        return None

    def _sync_dst_with_origin(self, dst, fetch_remote=False):
        if fetch_remote:
            fetch = self.git.fetch("origin", dst)
            if fetch.returncode != 0:
                self.result.warnings.append(
                    f"could not fetch origin {dst}; continuing with local state: {(fetch.stderr or '').strip()}"
                )

        if self.git.verify_ref(f"refs/remotes/origin/{dst}"):
            return self._update_dst_from_origin_tracking(dst)

        update = self.git.fetch_update_local_ref("origin", dst)
        return self._handle_dst_origin_update(dst, update)

    def _update_dst_from_origin_tracking(self, dst):
        update = self.git.fetch_local_from_tracking(dst)
        return self._handle_dst_origin_update(dst, update)

    def _handle_dst_origin_update(self, dst, update):
        if update.returncode == 0:
            return None

        stderr = update.stderr or ""
        if "checked out" in stderr:
            return self._ff_in_holding_worktree(f"origin/{dst}", dst)

        if "non-fast-forward" in stderr or "rejected" in stderr:
            outcome = self._merge_for_promotion(f"origin/{dst}", dst)
            if outcome:
                return outcome
            self.result.warnings.append(
                f"local {dst} diverged from origin/{dst}; merged origin/{dst} into {dst} and continued promotion"
            )
            return None

        self.result.warnings.append(
            f"could not update local {dst} from origin, continuing with local state: {stderr.strip()}"
        )
        return None

    def _handle_ff_refusal(self, src, dst, stderr):
        if "checked out" in stderr:
            return self._ff_in_holding_worktree(src, dst)
        if "non-fast-forward" not in stderr and "rejected" not in stderr:
            self.result.warnings.append(
                f"could not fast-forward {dst} from {src}; promotion stopped: {stderr.strip()}"
            )
            return Outcome.PROMOTE_FAILED
        return self._merge_for_promotion(src, dst)

    def _ff_in_holding_worktree(self, src, dst):
        worktrees = self.git.worktree_list_porcelain()
        holder = None
        if worktrees.returncode == 0:
            holder = find_worktree_for_branch(worktrees.stdout, dst)

        if holder is None:
            self.result.warnings.append(
                f"{dst} is checked out in another worktree but the holding worktree could not be found; promotion stopped"
            )
            return Outcome.PROMOTE_FAILED

        dirty = [line for line in self.git.status_short_in(holder) if not line.startswith("??")]
        if dirty:
            self.result.warnings.append(
                f"{dst} is checked out in {holder} and has uncommitted changes; promotion stopped"
            )
            return Outcome.PROMOTE_FAILED

        merge = self.git.merge_ff_only_in(holder, src)
        if merge.returncode != 0:
            self.result.warnings.append(
                f"could not fast-forward {dst} from {src} in {holder}; promotion stopped: {(merge.stderr or '').strip()}"
            )
            return Outcome.PROMOTE_FAILED

        self.result.warnings.append(
            f"{dst} was fast-forwarded in its holding worktree: {holder}"
        )
        return None

    def _merge_for_promotion(self, src, dst):
        dirty = [
            line for line in self.git.status_short()
            if not line.startswith("??") and is_dirty_status_line_in_scope(line)
        ]
        if dirty:
            self.result.warnings.append(f"working tree not clean; cannot merge {src} into {dst}")
            return Outcome.PROMOTE_FAILED

        original = self.git.current_branch()
        checkout_dst = self.git.checkout(dst)
        if checkout_dst.returncode != 0:
            self.result.warnings.append(
                f"could not check out {dst} for merge; promotion stopped: {(checkout_dst.stderr or '').strip()}"
            )
            return Outcome.PROMOTE_FAILED

        merge = self.git.merge_no_edit(src)
        if merge.returncode != 0:
            conflicting = self.git.conflicting_files()
            self.git.merge_abort()
            restore = self.git.checkout(original)
            if restore.returncode != 0:
                self.result.warnings.append(
                    f"aborted the conflicted merge of {src} into {dst} but could not return to "
                    f"{original}; repository left on {dst}: {(restore.stderr or '').strip()}"
                )
            self.result.warnings.append(
                f"merge conflict promoting {src} into {dst}: {', '.join(conflicting)}"
            )
            return Outcome.PROMOTE_CONFLICT

        restore = self.git.checkout(original)
        if restore.returncode != 0:
            self.result.warnings.append(
                f"merged {src} into {dst} locally but could not return to {original}; repository "
                f"left on {dst}, push of {dst} skipped: {(restore.stderr or '').strip()}"
            )
            return Outcome.PROMOTE_FAILED
        return None

    def _push_promoted(self, src, dst, origin_exists):
        if not origin_exists:
            if not self._no_origin_promote_warned:
                self.result.warnings.append(
                    "no origin remote; promoted branches updated locally only"
                )
                self._no_origin_promote_warned = True
            self.result.promoted.append(dst)
            return None

        def resync_promoted_dst():
            return self._resync_promoted_dst(src, dst)

        outcome = self._push_with_retries(
            lambda: self.git.push_ref("origin", dst),
            Outcome.PROMOTE_FAILED,
            lambda attempt, stderr: (
                f"promote push {dst} attempt {attempt}/{PUSH_ATTEMPTS} failed: {stderr}"
            ),
            on_rejected=resync_promoted_dst,
        )
        if outcome:
            return outcome

        self.result.promoted.append(dst)
        return None

    def _filter_up_to_date_refs(self, pending_refs):
        refs_to_push = []
        skipped_refs = []
        for pending_ref in pending_refs:
            if self._origin_ref_is_up_to_date(pending_ref.branch):
                skipped_refs.append(pending_ref)
                continue
            refs_to_push.append(pending_ref)
        return refs_to_push, skipped_refs

    def _origin_ref_is_up_to_date(self, branch):
        local_sha = self.git.rev_parse_ref(f"refs/heads/{branch}")
        if local_sha is None:
            return False
        remote_sha = self.git.rev_parse_ref(f"refs/remotes/origin/{branch}")
        if remote_sha is None:
            return False
        return local_sha == remote_sha

    def _push_pending_refs(self, pending_refs, set_upstream, exhausted_outcome):
        if not pending_refs:
            return None

        refspecs = [self._branch_refspec(pending_ref.branch) for pending_ref in pending_refs]
        for attempt in range(1, PUSH_ATTEMPTS + 1):
            push = self.git.push_refs_porcelain("origin", refspecs, set_upstream=set_upstream)
            ref_statuses = self._push_status_by_branch(push, pending_refs)
            if self._all_refs_pushed(ref_statuses):
                return None
            if self._has_per_ref_failure(ref_statuses):
                return self._push_outcome_for_ref_failures(ref_statuses, exhausted_outcome)

            stderr = (push.stderr or "").strip()
            self._append_batch_transport_warnings(pending_refs, attempt, stderr)
            if attempt == PUSH_ATTEMPTS:
                break
            time.sleep(self.config.push_retry_delay_sec)
        return exhausted_outcome

    def _push_promoted_batch(self, pending_refs, promoted_branches):
        refs_to_push, skipped_refs = self._filter_up_to_date_refs(pending_refs)
        self._mark_skipped_push_refs(skipped_refs, promoted_branches)
        if not refs_to_push:
            return None

        push = self._push_batch_until_per_ref_result(refs_to_push, set_upstream=False)
        if push is None:
            return Outcome.PROMOTE_FAILED

        ref_statuses = self._push_status_by_branch(push, refs_to_push)
        feature_failures = [
            pending_ref for pending_ref in refs_to_push
            if pending_ref.kind == "feature" and self._ref_failed(ref_statuses[pending_ref.branch])
        ]
        if feature_failures:
            return Outcome.PUSH_FAILED

        rejected_promoted_refs = [
            pending_ref for pending_ref in refs_to_push
            if pending_ref.kind == "promote" and ref_statuses[pending_ref.branch] == "rejected"
        ]
        error_promoted_refs = [
            pending_ref for pending_ref in refs_to_push
            if pending_ref.kind == "promote" and ref_statuses[pending_ref.branch] == "error"
        ]
        if error_promoted_refs:
            self._append_promote_failure_warnings(error_promoted_refs, ref_statuses, push)
            return Outcome.PROMOTE_FAILED

        if rejected_promoted_refs:
            return self._resync_and_retry_rejected_promoted_refs(
                refs_to_push,
                ref_statuses,
                rejected_promoted_refs,
                promoted_branches,
                push,
            )

        self._mark_successful_push_refs(refs_to_push, promoted_branches)
        return None

    def _push_batch_until_per_ref_result(self, pending_refs, set_upstream):
        refspecs = [self._branch_refspec(pending_ref.branch) for pending_ref in pending_refs]
        for attempt in range(1, PUSH_ATTEMPTS + 1):
            push = self.git.push_refs_porcelain("origin", refspecs, set_upstream=set_upstream)
            ref_statuses = self._push_status_by_branch(push, pending_refs)
            if self._all_refs_pushed(ref_statuses) or self._has_per_ref_failure(ref_statuses):
                return push

            stderr = (push.stderr or "").strip()
            self._append_batch_transport_warnings(pending_refs, attempt, stderr)
            if attempt == PUSH_ATTEMPTS:
                break
            time.sleep(self.config.push_retry_delay_sec)
        return None

    def _resync_and_retry_rejected_promoted_refs(
        self,
        initial_refs_to_push,
        initial_statuses,
        rejected_promoted_refs,
        promoted_branches,
        initial_push,
    ):
        self._append_promote_failure_warnings(rejected_promoted_refs, initial_statuses, initial_push)
        for pending_ref in rejected_promoted_refs:
            outcome = self._resync_promoted_dst(pending_ref.source, pending_ref.branch)
            if outcome:
                return outcome

        retry_refs = rejected_promoted_refs
        retry_push = self.git.push_refs_porcelain(
            "origin",
            [self._branch_refspec(pending_ref.branch) for pending_ref in retry_refs],
            set_upstream=False,
        )
        retry_statuses = self._push_status_by_branch(retry_push, retry_refs)
        if self._all_refs_pushed(retry_statuses):
            self._mark_successful_push_refs(initial_refs_to_push, promoted_branches, initial_statuses)
            self._mark_successful_push_refs(retry_refs, promoted_branches, retry_statuses)
            return None

        self._append_promote_failure_warnings(retry_refs, retry_statuses, retry_push, attempt=2)
        return Outcome.PROMOTE_FAILED

    def _append_promote_failure_warnings(self, pending_refs, statuses, push, attempt=1):
        for pending_ref in pending_refs:
            summary = self._push_failure_text(push, pending_ref.branch)
            self.result.warnings.append(
                f"promote push {pending_ref.branch} attempt {attempt}/{PUSH_ATTEMPTS} failed: {summary}"
            )

    def _mark_skipped_push_refs(self, skipped_refs, promoted_branches):
        for pending_ref in skipped_refs:
            if pending_ref.kind == "feature":
                self.result.pushed = True
                continue
            self._append_promoted_in_hop_order(pending_ref.branch, promoted_branches)

    def _mark_successful_push_refs(self, pending_refs, promoted_branches, statuses=None):
        for pending_ref in pending_refs:
            if statuses is not None and not self._ref_succeeded(statuses[pending_ref.branch]):
                continue
            if pending_ref.kind == "feature":
                self.result.pushed = True
                continue
            self._append_promoted_in_hop_order(pending_ref.branch, promoted_branches)

    def _append_promoted_in_hop_order(self, branch, promoted_branches):
        for promoted_branch in promoted_branches:
            if promoted_branch != branch:
                continue
            if promoted_branch in self.result.promoted:
                return
            self.result.promoted.append(promoted_branch)
            return

    def _push_status_by_branch(self, push, pending_refs):
        statuses = {}
        for pending_ref in pending_refs:
            parsed = self._push_ref_result(push, pending_ref.branch)
            if parsed is None and push.returncode == 0:
                statuses[pending_ref.branch] = "ok"
                continue
            if parsed is None:
                statuses[pending_ref.branch] = "unknown"
                continue
            statuses[pending_ref.branch] = parsed["status"]
        return statuses

    def _push_ref_result(self, push, branch):
        refname = f"refs/heads/{branch}"
        if refname in push.refs:
            return push.refs[refname]
        return push.refs.get(branch)

    def _all_refs_pushed(self, statuses):
        return all(self._ref_succeeded(status) for status in statuses.values())

    def _has_per_ref_failure(self, statuses):
        return any(self._ref_failed(status) for status in statuses.values())

    def _ref_succeeded(self, status):
        return status in ("ok", "up_to_date")

    def _ref_failed(self, status):
        return status in ("rejected", "error")

    def _push_outcome_for_ref_failures(self, statuses, exhausted_outcome):
        if exhausted_outcome == Outcome.PUSH_FAILED:
            return Outcome.PUSH_FAILED
        return Outcome.PROMOTE_FAILED

    def _append_batch_transport_warnings(self, pending_refs, attempt, stderr):
        for pending_ref in pending_refs:
            if pending_ref.kind == "feature":
                self.result.warnings.append(
                    f"push attempt {attempt}/{PUSH_ATTEMPTS} failed: {stderr}"
                )
                continue
            self.result.warnings.append(
                f"promote push {pending_ref.branch} attempt {attempt}/{PUSH_ATTEMPTS} failed: {stderr}"
            )

    def _push_failure_text(self, push, branch):
        parsed = self._push_ref_result(push, branch)
        stderr = (push.stderr or "").strip()
        if parsed is not None and parsed.get("summary") and stderr:
            return f"{parsed['summary']}: {stderr}"
        if parsed is not None and parsed.get("summary"):
            return parsed["summary"]
        if stderr:
            return stderr
        return (push.stdout or "").strip()

    def _branch_refspec(self, branch):
        return f"refs/heads/{branch}:refs/heads/{branch}"

    def _push_with_retries(self, push_once, exhausted_outcome, warn, on_rejected=None):
        for attempt in range(1, PUSH_ATTEMPTS + 1):
            push = push_once()
            if push.returncode == 0:
                return None

            stderr = (push.stderr or "").strip()
            self.result.warnings.append(warn(attempt, stderr))
            if attempt == PUSH_ATTEMPTS:
                break

            if on_rejected is not None and self._is_fetch_first_rejection(stderr):
                outcome = on_rejected()
                if outcome:
                    return outcome

            time.sleep(self.config.push_retry_delay_sec)
        return exhausted_outcome

    def _resync_promoted_dst(self, src, dst):
        outcome = self._sync_dst_with_origin(dst, fetch_remote=True)
        if outcome:
            return outcome

        ff = self.git.fetch_local_ff(src, dst)
        if ff.returncode == 0:
            return None
        return self._handle_ff_refusal(src, dst, ff.stderr or "")

    def _is_fetch_first_rejection(self, stderr):
        normalized = stderr.lower()
        if "non-fast-forward" in normalized:
            return True
        if "fetch first" in normalized:
            return True
        return "rejected" in normalized

    # -- helpers ----------------------------------------------------------

    def _fixture_key(self, call_name):
        return f"{self.config.fixture_prefix}_{call_name}"

    def _temp_dir(self):
        path = os.path.join(self.config.workspace, ".compiled-commit-tmp")
        os.makedirs(path, exist_ok=True)
        return path

    def _write_workspace_temp(self, name, content):
        path = os.path.join(self._temp_dir(), name)
        with open(path, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(content)
        return path
