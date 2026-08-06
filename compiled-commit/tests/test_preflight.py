import os
import tempfile
import unittest

from src.failures import Outcome
from src.llm import LlmClient
from src.pipeline import Pipeline, PipelineConfig
from tests.helpers import cleanup, commit_file, make_repo, run_git


def _make_pipeline(repo):
    client = LlmClient(mode="live")  # never dispatched: every test here stops at preflight
    config = PipelineConfig(
        repo=repo,
        llm_client=client,
        no_sync=True,
        skip_deslop=True,
        skip_review=True,
        message="chore: test",
    )
    return Pipeline(config)


class PreflightTests(unittest.TestCase):
    def test_non_repo_dir_is_not_a_repo(self):
        plain_dir = tempfile.mkdtemp(prefix="cc-test-nonrepo-")
        try:
            result = _make_pipeline(plain_dir).run()
            self.assertEqual(result.outcome, Outcome.NOT_A_REPO)
        finally:
            cleanup(plain_dir)

    def test_detached_head(self):
        repo = make_repo()
        try:
            commit_file(repo, "a.txt", "one\n", "first")
            head_sha = run_git(repo, ["rev-parse", "HEAD"]).stdout.strip()
            run_git(repo, ["checkout", head_sha])
            result = _make_pipeline(repo).run()
            self.assertEqual(result.outcome, Outcome.DETACHED_HEAD)
        finally:
            cleanup(repo)

    def test_merge_in_progress(self):
        repo = make_repo()
        try:
            commit_file(repo, "f.txt", "base\n", "base")
            run_git(repo, ["checkout", "-b", "feature"])
            commit_file(repo, "f.txt", "feature change\n", "feature change")
            run_git(repo, ["checkout", "main"])
            commit_file(repo, "f.txt", "main change\n", "main change")
            merge = run_git(repo, ["merge", "feature"], check=False)
            self.assertNotEqual(merge.returncode, 0)

            result = _make_pipeline(repo).run()
            self.assertEqual(result.outcome, Outcome.OPERATION_IN_PROGRESS)
        finally:
            run_git(repo, ["merge", "--abort"], check=False)
            cleanup(repo)


if __name__ == "__main__":
    unittest.main()
