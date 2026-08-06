"""All git subprocess calls for the pipeline, funneled through one op counter.

The op counter feeds the benchmark's tool-call comparison against historical Claude
Code sessions (SPEC bench/run_bench.py step 5).
"""

import subprocess


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
        return subprocess.run(
            ["git"] + args,
            cwd=cwd or self.repo,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )

    def is_inside_work_tree(self):
        proc = self._run(["rev-parse", "--is-inside-work-tree"])
        return proc.returncode == 0 and proc.stdout.strip() == "true"

    def current_branch(self):
        proc = self._run(["rev-parse", "--abbrev-ref", "HEAD"])
        return proc.stdout.strip()

    def verify_ref(self, ref):
        proc = self._run(["rev-parse", "-q", "--verify", ref])
        return proc.returncode == 0

    def fetch(self, remote, branch):
        return self._run(["fetch", remote, branch])

    def fetch_update_local_ref(self, remote, branch):
        return self._run(["fetch", remote, f"{branch}:{branch}"])

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
