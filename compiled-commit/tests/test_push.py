import shutil
import unittest

from src.failures import Outcome
from src.llm import LlmClient
from src.pipeline import Pipeline, PipelineConfig
from tests.helpers import cleanup, commit_file, make_bare_origin, make_repo, run_git, write_file


def _make_pipeline(repo, message="chore: push test"):
    client = LlmClient(mode="live")  # never dispatched: message is always supplied here
    config = PipelineConfig(
        repo=repo,
        llm_client=client,
        no_sync=True,
        skip_deslop=True,
        skip_review=True,
        message=message,
    )
    return Pipeline(config)


class PushStageTests(unittest.TestCase):
    def test_push_from_feature_branch_advances_origin_ref(self):
        origin = make_bare_origin()
        repo = make_repo()
        try:
            run_git(repo, ["remote", "add", "origin", origin])
            commit_file(repo, "base.txt", "base\n", "init")
            run_git(repo, ["push", "-u", "origin", "main"])

            run_git(repo, ["checkout", "-b", "feature"])
            write_file(repo, "base.txt", "base\nfeature change\n")

            before = run_git(origin, ["rev-parse", "-q", "--verify", "refs/heads/feature"], check=False)
            self.assertNotEqual(before.returncode, 0)  # feature does not exist on origin yet

            result = _make_pipeline(repo).run()

            self.assertEqual(result.outcome, Outcome.COMMITTED)
            self.assertTrue(result.pushed)

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


if __name__ == "__main__":
    unittest.main()
