import unittest

from src.failures import Outcome
from src.git_ops import GitOps
from src.llm import LlmClient
from src.pipeline import Pipeline, PipelineConfig, compute_scope
from tests.helpers import cleanup, commit_file, make_repo, run_git, write_file


class ScopeTests(unittest.TestCase):
    def test_modified_tracked_and_untracked_detected(self):
        repo = make_repo()
        try:
            commit_file(repo, "tracked.txt", "one\n", "init")
            write_file(repo, "tracked.txt", "one\ntwo\n")
            write_file(repo, "new_file.txt", "brand new\n")

            git = GitOps(repo)
            changed, untracked = compute_scope(git)

            self.assertIn("tracked.txt", changed)
            self.assertIn("new_file.txt", untracked)
        finally:
            cleanup(repo)

    def test_junk_untracked_excluded(self):
        repo = make_repo()
        try:
            commit_file(repo, "keep.txt", "keep\n", "init")
            write_file(repo, "debug.log", "log noise\n")
            write_file(repo, ".env", "SECRET=1\n")
            write_file(repo, "node_modules/pkg/index.js", "module.exports = {};\n")
            write_file(repo, "wanted.txt", "wanted\n")

            git = GitOps(repo)
            _changed, untracked = compute_scope(git)

            self.assertIn("wanted.txt", untracked)
            self.assertNotIn("debug.log", untracked)
            self.assertNotIn(".env", untracked)
            self.assertTrue(all("node_modules" not in path for path in untracked))
        finally:
            cleanup(repo)

    def test_clean_repo_is_nothing_to_commit(self):
        repo = make_repo()
        try:
            commit_file(repo, "only.txt", "content\n", "init")
            client = LlmClient(mode="live")
            config = PipelineConfig(
                repo=repo,
                llm_client=client,
                no_sync=True,
                skip_deslop=True,
                skip_review=True,
                message="chore: test",
            )
            result = Pipeline(config).run()
            self.assertEqual(result.outcome, Outcome.NOTHING_TO_COMMIT)
        finally:
            cleanup(repo)


if __name__ == "__main__":
    unittest.main()
