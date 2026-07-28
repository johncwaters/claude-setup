"""Typed terminal outcomes and result/usage dataclasses for the compiled-commit pipeline."""

import json
from dataclasses import asdict, dataclass, field
from enum import Enum


class Outcome(Enum):
    COMMITTED = "COMMITTED"
    NOT_A_REPO = "NOT_A_REPO"
    DETACHED_HEAD = "DETACHED_HEAD"
    OPERATION_IN_PROGRESS = "OPERATION_IN_PROGRESS"
    NOTHING_TO_COMMIT = "NOTHING_TO_COMMIT"
    SYNC_DIVERGED = "SYNC_DIVERGED"
    MERGE_CONFLICT = "MERGE_CONFLICT"
    GATE_FAILED = "GATE_FAILED"
    REVIEW_DEAD = "REVIEW_DEAD"
    REVIEW_BLOCKED = "REVIEW_BLOCKED"
    SLOP_PATCH_INVALID = "SLOP_PATCH_INVALID"
    MESSAGE_INVALID = "MESSAGE_INVALID"
    HOOK_FAILED = "HOOK_FAILED"
    PUSH_FAILED = "PUSH_FAILED"
    PROMOTE_CONFLICT = "PROMOTE_CONFLICT"
    PROMOTE_FAILED = "PROMOTE_FAILED"


# Exit code 0 is reserved for COMMITTED (see SPEC "Runner"). Every failure class gets a
# distinct nonzero code so callers can branch on exit status alone.
EXIT_CODES = {
    Outcome.COMMITTED: 0,
    Outcome.NOT_A_REPO: 10,
    Outcome.DETACHED_HEAD: 11,
    Outcome.OPERATION_IN_PROGRESS: 12,
    Outcome.NOTHING_TO_COMMIT: 13,
    Outcome.SYNC_DIVERGED: 14,
    Outcome.MERGE_CONFLICT: 15,
    Outcome.GATE_FAILED: 16,
    Outcome.REVIEW_DEAD: 17,
    Outcome.REVIEW_BLOCKED: 18,
    Outcome.SLOP_PATCH_INVALID: 19,
    Outcome.MESSAGE_INVALID: 20,
    Outcome.HOOK_FAILED: 21,
    Outcome.PUSH_FAILED: 22,
    Outcome.PROMOTE_CONFLICT: 23,
    Outcome.PROMOTE_FAILED: 24,
}


@dataclass
class LlmUsage:
    name: str
    model: str
    input_tokens: int
    cache_creation_input_tokens: int
    cache_read_input_tokens: int
    output_tokens: int
    duration_ms: float
    retries: int


@dataclass
class PipelineResult:
    outcome: Outcome = None
    commit_hash: str = None
    commit_message: str = None
    pushed: bool = False
    promoted: list = field(default_factory=list)
    findings: list = field(default_factory=list)
    warnings: list = field(default_factory=list)
    llm_usage: list = field(default_factory=list)
    git_op_count: int = 0
    wall_time_sec: float = 0.0
    stages_run: list = field(default_factory=list)

    def to_dict(self):
        data = asdict(self)
        data["outcome"] = self.outcome.value if self.outcome else None
        return data

    def to_json(self):
        return json.dumps(self.to_dict(), indent=2)
