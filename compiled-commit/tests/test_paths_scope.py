import unittest

from src.failures import Outcome
from src.git_ops import GitOps
from src.llm import LlmClient
from src.pipeline import Pipeline, PipelineConfig
from tests.helpers import cleanup, commit_file, make_repo, write_file


def _make_pipeline(repo, paths=None, message="chore: test commit\n\nBody text here."):
    client = LlmClient(mode="live")
    config = PipelineConfig(
        repo=repo,
        llm_client=client,
        no_sync=True,
        skip_deslop=True,
        skip_review=True,
        no_push=True,
        message=message,
        paths=paths,
    )
    return Pipeline(config)


class PathsScopeTests(unittest.TestCase):
    def test_scoped_commit_leaves_out_of_scope_file_dirty(self):
        repo = make_repo()
        try:
            commit_file(repo, "in_scope.txt", "one\n", "init")
            commit_file(repo, "out_of_scope.txt", "one\n", "init")
            write_file(repo, "in_scope.txt", "one\ntwo\n")
            write_file(repo, "out_of_scope.txt", "one\ntwo\n")

            pipeline = _make_pipeline(repo, paths=["in_scope.txt"])
            result = pipeline.run()

            self.assertEqual(result.outcome, Outcome.COMMITTED)

            git = GitOps(repo)
            status = git.status_short()
            self.assertTrue(any("out_of_scope.txt" in line for line in status))
            self.assertFalse(any("in_scope.txt" in line for line in status))
        finally:
            cleanup(repo)

    def test_scoped_untracked_file_committed_one_left_out(self):
        repo = make_repo()
        try:
            commit_file(repo, "base.txt", "base\n", "init")
            write_file(repo, "wanted/new.txt", "wanted new content\n")
            write_file(repo, "unwanted_new.txt", "unwanted new content\n")

            pipeline = _make_pipeline(repo, paths=["wanted"])
            result = pipeline.run()

            self.assertEqual(result.outcome, Outcome.COMMITTED)

            git = GitOps(repo)
            status = git.status_short()
            self.assertTrue(any("?? unwanted_new.txt" in line for line in status))
            self.assertFalse(any(line.endswith("wanted/new.txt") for line in status))
        finally:
            cleanup(repo)

    def test_no_paths_keeps_whole_tree_behavior(self):
        repo = make_repo()
        try:
            commit_file(repo, "a.txt", "one\n", "init")
            commit_file(repo, "b.txt", "one\n", "init")
            write_file(repo, "a.txt", "one\ntwo\n")
            write_file(repo, "b.txt", "one\ntwo\n")

            pipeline = _make_pipeline(repo, paths=None)
            result = pipeline.run()

            self.assertEqual(result.outcome, Outcome.COMMITTED)

            git = GitOps(repo)
            status = [
                line for line in git.status_short()
                if ".compiled-commit-tmp/" not in line
            ]
            self.assertEqual(status, [])
        finally:
            cleanup(repo)

    def test_paths_matching_nothing_dirty_is_nothing_to_commit(self):
        repo = make_repo()
        try:
            commit_file(repo, "a.txt", "one\n", "init")
            commit_file(repo, "b.txt", "one\n", "init")
            write_file(repo, "b.txt", "one\ntwo\n")

            pipeline = _make_pipeline(repo, paths=["a.txt"])
            result = pipeline.run()

            self.assertEqual(result.outcome, Outcome.NOTHING_TO_COMMIT)

            git = GitOps(repo)
            status = git.status_short()
            self.assertTrue(any("b.txt" in line for line in status))
        finally:
            cleanup(repo)


if __name__ == "__main__":
    unittest.main()
