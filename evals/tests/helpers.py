"""Shared test scaffolding: real temp git repos, no git mocking (repo convention; see
compiled-commit/tests/helpers.py for the precedent). Only external LLM/HTTP calls get canned.
"""

import os
import shutil
import subprocess
import tempfile


def run_git(repo, args, check=True):
    proc = subprocess.run(["git"] + args, cwd=repo, capture_output=True, text=True)
    if check and proc.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {proc.stderr}")
    return proc


def make_repo(tmp_root=None):
    repo = tempfile.mkdtemp(prefix="evals-test-", dir=tmp_root)
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
    return run_git(repo, ["rev-parse", "HEAD"]).stdout.strip()


def cleanup(*paths):
    for path in paths:
        shutil.rmtree(path, ignore_errors=True)
