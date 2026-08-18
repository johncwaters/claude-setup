"""All git subprocess calls for the pipeline, funneled through one op counter.

The op counter feeds the benchmark's tool-call comparison against historical Claude
Code sessions (SPEC bench/run_bench.py step 5).
"""

import subprocess
import sys
import time
from dataclasses import dataclass

SLOW_OP_THRESHOLD_SEC = 1.0


@dataclass
class PushPorcelainResult:
    returncode: int
    stdout: str
    stderr: str
    refs: dict


def _scoped(args, paths):
    if not paths:
        return args
    return args + ["--"] + list(paths)


class GitOps:
    def __init__(self, repo):
        self.repo = repo
        self.op_count = 0

    def _run(self, args, cwd=None):
        self.op_count += 1
        started = time.monotonic()
        proc = subprocess.run(
            ["git"] + args,
            cwd=cwd or self.repo,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        seconds = time.monotonic() - started
        if seconds >= SLOW_OP_THRESHOLD_SEC:
            print(f"[git {seconds:.1f}s] {' '.join(args)}", file=sys.stderr)
        return proc

    def is_inside_work_tree(self):
        proc = self._run(["rev-parse", "--is-inside-work-tree"])
        return proc.returncode == 0 and proc.stdout.strip() == "true"

    def current_branch(self):
        proc = self._run(["rev-parse", "--abbrev-ref", "HEAD"])
        return proc.stdout.strip()

    def verify_ref(self, ref):
        proc = self._run(["rev-parse", "-q", "--verify", ref])
        return proc.returncode == 0

    def rev_parse_ref(self, ref):
        proc = self._run(["rev-parse", "-q", "--verify", ref])
        if proc.returncode != 0:
            return None
        return proc.stdout.strip()

    def fetch(self, remote, branch):
        return self._run(["fetch", remote, branch])

    def fetch_many(self, remote, branches):
        return self._run(["fetch", remote] + list(branches))

    def fetch_update_local_ref(self, remote, branch):
        return self._run(["fetch", remote, f"{branch}:{branch}"])

    def fetch_local_from_tracking(self, branch):
        return self.fetch_local_ff(f"refs/remotes/origin/{branch}", f"refs/heads/{branch}")

    def fetch_local_ff(self, src, dst):
        # Fast-forward local ref dst to src without touching the working tree.
        return self._run(["fetch", ".", f"{src}:{dst}"])

    def worktree_list_porcelain(self):
        return self._run(["worktree", "list", "--porcelain"])

    def checkout(self, ref):
        return self._run(["checkout", ref])

    def create_branch_at(self, name, start_point):
        return self._run(["branch", name, start_point])

    def merge_no_edit(self, ref):
        return self._run(["merge", "--no-edit", ref])

    def merge_abort(self):
        return self._run(["merge", "--abort"])

    def conflicting_files(self):
        proc = self._run(["diff", "--name-only", "--diff-filter=U"])
        return [line for line in proc.stdout.splitlines() if line.strip()]

    def diff_name_only(self, cached=False, paths=None):
        args = ["diff", "--cached", "--name-only"] if cached else ["diff", "--name-only", "HEAD"]
        proc = self._run(_scoped(args, paths))
        return [line for line in proc.stdout.splitlines() if line.strip()]

    def status_short(self, paths=None):
        proc = self._run(_scoped(["status", "--short"], paths))
        return [line for line in proc.stdout.splitlines() if line.strip()]

    def status_short_in(self, worktree_path):
        proc = self._run(["status", "--short"], cwd=worktree_path)
        return [line for line in proc.stdout.splitlines() if line.strip()]

    def merge_ff_only_in(self, worktree_path, ref):
        return self._run(["merge", "--ff-only", ref], cwd=worktree_path)

    def diff_head(self, paths=None):
        proc = self._run(_scoped(["diff", "HEAD"], paths))
        if proc.returncode == 0:
            return proc.stdout
        # Unborn HEAD (no commits yet): fall back to the staged-vs-empty-tree diff.
        fallback = self._run(_scoped(["diff", "--cached"], paths))
        return fallback.stdout

    def log_subjects(self, n=10):
        proc = self._run(["log", "--format=%s", "-n", str(n)])
        if proc.returncode != 0:
            return []
        return [line for line in proc.stdout.splitlines() if line.strip()]

    def add_update(self, paths=None):
        return self._run(_scoped(["add", "-u"], paths))

    def add_path(self, path):
        return self._run(["add", "--", path])

    def commit(self, message_path):
        return self._run(["commit", "-F", message_path])

    def rev_parse_head(self):
        proc = self._run(["rev-parse", "HEAD"])
        return proc.stdout.strip()

    def apply_check(self, patch_path):
        return self._run(["apply", "--check", patch_path])

    def apply(self, patch_path):
        return self._run(["apply", patch_path])

    def list_remotes(self):
        proc = self._run(["remote"])
        return [line.strip() for line in proc.stdout.splitlines() if line.strip()]

    def has_upstream(self):
        proc = self._run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])
        return proc.returncode == 0

    def push(self):
        return self._run(["push"])

    def push_set_upstream(self, remote, branch):
        return self._run(["push", "-u", remote, branch])

    def push_ref(self, remote, branch):
        return self._run(["push", remote, branch])

    def push_refs_porcelain(self, remote, refspecs, set_upstream=False):
        args = ["push", "--porcelain"]
        if set_upstream:
            args.append("-u")
        proc = self._run(args + [remote] + list(refspecs))
        return PushPorcelainResult(
            returncode=proc.returncode,
            stdout=proc.stdout,
            stderr=proc.stderr,
            refs=parse_push_porcelain(proc.stdout),
        )


def parse_push_porcelain(stdout):
    parsed = {}
    for line in stdout.splitlines():
        if not line:
            continue
        flag = line[0]
        if flag not in (" ", "*", "=", "!"):
            continue
        fields = line[1:].split("\t")
        parts = [field for field in fields if field]
        if len(parts) < 2:
            continue
        refname = _push_porcelain_refname(parts[0].strip())
        if not refname:
            continue
        parsed[refname] = {
            "status": _push_porcelain_status(flag),
            "summary": "\t".join(parts[1:]).strip(),
        }
    return parsed


def _push_porcelain_refname(refspec_text):
    if ":" not in refspec_text:
        return refspec_text
    return refspec_text.rsplit(":", 1)[-1]


def _push_porcelain_status(flag):
    if flag == "!":
        return "rejected"
    if flag == "=":
        return "up_to_date"
    if flag in (" ", "*"):
        return "ok"
    return "error"
