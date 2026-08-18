import os
import shutil
import unittest

from src.failures import Outcome
from src.git_ops import GitOps, parse_push_porcelain
from src.llm import LlmClient
from src.pipeline import Pipeline, PipelineConfig
from tests.helpers import (
    cleanup,
    commit_file,
    make_bare_origin,
    make_repo,
    run_git,
    write_file,
    write_flaky_hook,
)


class RecordingGitOps(GitOps):
    def __init__(self, repo):
        super().__init__(repo)
        self.calls = []

    def _run(self, args, cwd=None):
        self.calls.append(list(args))
        return super()._run(args, cwd=cwd)


def _make_pipeline(repo, message="chore: push test", push_retry_delay_sec=0):
    client = LlmClient(mode="live")  # never dispatched: message is always supplied here
    config = PipelineConfig(
        repo=repo,
        llm_client=client,
        no_sync=True,
        skip_deslop=True,
        skip_review=True,
        message=message,
        push_retry_delay_sec=push_retry_delay_sec,
    )
    return Pipeline(config)


class PushStageTests(unittest.TestCase):
    def test_parse_push_porcelain_status_flags(self):
        parsed = parse_push_porcelain(
            "\n".join(
                [
                    " \trefs/heads/main:refs/heads/main\t111..222",
                    "*\trefs/heads/feature:refs/heads/feature\t[new branch]",
                    "=\trefs/heads/develop:refs/heads/develop\t[up to date]",
                    "!\trefs/heads/release:refs/heads/release\t[rejected] fetch first",
                ]
            )
        )

        self.assertEqual(parsed["refs/heads/main"]["status"], "ok")
        self.assertEqual(parsed["refs/heads/feature"]["status"], "ok")
        self.assertEqual(parsed["refs/heads/develop"]["status"], "up_to_date")
        self.assertEqual(parsed["refs/heads/release"]["status"], "rejected")
        self.assertEqual(parsed["refs/heads/release"]["summary"], "[rejected] fetch first")

    def test_push_from_feature_branch_advances_origin_ref(self):
        origin = make_bare_origin()
        repo = make_repo()
        try:
            run_git(repo, ["remote", "add", "origin", origin])
            commit_file(repo, "base.txt", "base\n", "init")
            run_git(repo, ["push", "-u", "origin", "main"])

            run_git(repo, ["checkout", "-b", "feature"])
            write_file(repo, "base.txt", "base\nfeature change\n")
            pipeline = _make_pipeline(repo)
            recording_git = RecordingGitOps(repo)
            pipeline.git = recording_git

            before = run_git(origin, ["rev-parse", "-q", "--verify", "refs/heads/feature"], check=False)
            self.assertNotEqual(before.returncode, 0)  # feature does not exist on origin yet

            result = pipeline.run()

            self.assertEqual(result.outcome, Outcome.COMMITTED)
            self.assertTrue(result.pushed)
            push_calls = [call for call in recording_git.calls if call[:2] == ["push", "--porcelain"]]
            self.assertEqual(len(push_calls), 1)

            after = run_git(origin, ["rev-parse", "refs/heads/feature"])
            self.assertEqual(after.stdout.strip(), result.commit_hash)
        finally:
            cleanup(repo, origin)

    def test_no_origin_remote_skips_push_but_commit_succeeds(self):
        repo = make_repo()
        try:
            commit_file(repo, "base.txt", "base\n", "init")
            write_file(repo, "base.txt", "base\nchanged\n")

            result = _make_pipeline(repo).run()

            self.assertEqual(result.outcome, Outcome.COMMITTED)
            self.assertTrue(result.commit_hash)
            self.assertFalse(result.pushed)
            self.assertTrue(any("no origin remote" in w for w in result.warnings))
        finally:
            cleanup(repo)

    def test_push_failure_is_push_failed_with_commit_hash_set(self):
        origin = make_bare_origin()
        repo = make_repo()
        try:
            run_git(repo, ["remote", "add", "origin", origin])
            commit_file(repo, "base.txt", "base\n", "init")
            write_file(repo, "base.txt", "base\nchanged\n")

            shutil.rmtree(origin, ignore_errors=True)  # origin now unreachable; push must fail

            result = _make_pipeline(repo).run()

            self.assertEqual(result.outcome, Outcome.PUSH_FAILED)
            self.assertTrue(result.commit_hash)
            self.assertFalse(result.pushed)
        finally:
            cleanup(repo)

    def test_flaky_pre_push_hook_retries_and_pushes(self):
        origin = make_bare_origin()
        repo = make_repo()
        try:
            run_git(repo, ["remote", "add", "origin", origin])
            commit_file(repo, "base.txt", "base\n", "init")
            run_git(repo, ["push", "-u", "origin", "main"])
            write_flaky_hook(
                os.path.join(repo, ".git", "hooks"),
                "pre-push",
                ".git/hooks/pre-push-count",
                failing_attempts=1,
                label="flaky pre-push",
            )
            write_file(repo, "base.txt", "base\nchanged\n")

            result = _make_pipeline(repo).run()

            self.assertEqual(result.outcome, Outcome.COMMITTED)
            self.assertTrue(result.pushed)
            retry_warnings = [w for w in result.warnings if "push attempt" in w]
            self.assertEqual(len(retry_warnings), 1)
            self.assertIn("attempt 1/3", retry_warnings[0])
            self.assertIn("flaky pre-push attempt 1", retry_warnings[0])
        finally:
            cleanup(repo, origin)

    def test_pre_push_hook_exhausts_retries(self):
        origin = make_bare_origin()
        repo = make_repo()
        try:
            run_git(repo, ["remote", "add", "origin", origin])
            commit_file(repo, "base.txt", "base\n", "init")
            run_git(repo, ["push", "-u", "origin", "main"])
            write_flaky_hook(
                os.path.join(repo, ".git", "hooks"),
                "pre-push",
                ".git/hooks/pre-push-count",
                failing_attempts=3,
                label="flaky pre-push",
            )
            write_file(repo, "base.txt", "base\nchanged\n")

            result = _make_pipeline(repo).run()

            self.assertEqual(result.outcome, Outcome.PUSH_FAILED)
            self.assertTrue(result.commit_hash)
            self.assertFalse(result.pushed)
            retry_warnings = [w for w in result.warnings if "push attempt" in w]
            self.assertEqual(len(retry_warnings), 3)
            self.assertIn("attempt 3/3", retry_warnings[-1])
        finally:
            cleanup(repo, origin)


if __name__ == "__main__":
    unittest.main()
