"""Shared test scaffolding: real temp git repos, no git mocking (SPEC tests/ policy)."""

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
