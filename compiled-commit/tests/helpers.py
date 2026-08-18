"""Shared test scaffolding: real temp git repos, no git mocking (SPEC tests/ policy)."""

import os
import shutil
import subprocess
import tempfile

from src.git_ops import GitOps


def run_git(repo, args, check=True):
    proc = subprocess.run(["git"] + args, cwd=repo, capture_output=True, text=True)
    if check and proc.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {proc.stderr}")
    return proc


def make_repo(tmp_root=None):
    repo = tempfile.mkdtemp(prefix="cc-test-", dir=tmp_root)
    run_git(repo, ["init", "-q"])
    run_git(repo, ["symbolic-ref", "HEAD", "refs/heads/main"])
    run_git(repo, ["config", "user.name", "Test User"])
    run_git(repo, ["config", "user.email", "test@example.com"])
    run_git(repo, ["config", "commit.gpgsign", "false"])
    return repo


def write_file(repo, path, content):
    full_path = os.path.join(repo, path)
    os.makedirs(os.path.dirname(full_path), exist_ok=True)
    with open(full_path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(content)
    return full_path


def commit_file(repo, path, content, message="init"):
    write_file(repo, path, content)
    run_git(repo, ["add", "--", path])
    run_git(repo, ["commit", "-q", "-m", message])


def cleanup(*paths):
    for path in paths:
        shutil.rmtree(path, ignore_errors=True)


def make_bare_origin():
    origin = tempfile.mkdtemp(prefix="cc-test-origin-")
    run_git(origin, ["init", "-q", "--bare"])
    return origin


def clone_repo(origin, dest):
    proc = subprocess.run(["git", "clone", "-q", origin, dest], capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"git clone failed: {proc.stderr}")
    run_git(dest, ["config", "user.name", "Test User"])
    run_git(dest, ["config", "user.email", "test@example.com"])
    run_git(dest, ["config", "commit.gpgsign", "false"])
    return dest


def write_flaky_hook(hooks_dir, hook_name, count_file_rel, failing_attempts, label):
    hook_path = os.path.join(hooks_dir, hook_name)
    with open(hook_path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(
            "#!/bin/sh\n"
            f"count_file=\"{count_file_rel}\"\n"
            "count=0\n"
            "[ -f \"$count_file\" ] && count=$(cat \"$count_file\")\n"
            "count=$((count + 1))\n"
            "printf \"%s\" \"$count\" > \"$count_file\"\n"
            f"if [ \"$count\" -le {failing_attempts} ]; then\n"
            f"  echo \"{label} attempt $count\" >&2\n"
            "  exit 1\n"
            "fi\n"
            "exit 0\n"
        )
    os.chmod(hook_path, 0o755)


class RecordingGitOps(GitOps):
    def __init__(self, repo):
        super().__init__(repo)
        self.calls = []

    def _run(self, args, cwd=None):
        self.calls.append(list(args))
        return super()._run(args, cwd=cwd)
