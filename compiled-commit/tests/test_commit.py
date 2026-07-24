import os
import unittest

from src.failures import Outcome, PipelineResult
from src.llm import LlmClient
from src.pipeline import Pipeline, PipelineConfig
from tests.helpers import cleanup, commit_file, make_repo, write_file


def _make_pipeline(repo, message="chore: test commit\n\nBody text here.", trivial_message=True):
    client = LlmClient(mode="live")
    config = PipelineConfig(
        repo=repo,
        llm_client=client,
        no_sync=True,
        skip_deslop=True,
        skip_review=True,
        no_push=True,
        message=message,
    )
    return Pipeline(config)


class CommitStageTests(unittest.TestCase):
    def test_real_commit_created_and_message_file_cleaned_up(self):
        repo = make_repo()
        try:
            commit_file(repo, "base.txt", "base\n", "init")
            write_file(repo, "base.txt", "base\nchanged\n")
            write_file(repo, "new.txt", "brand new content\n")

            pipeline = _make_pipeline(repo)
            result = pipeline.run()

            self.assertEqual(result.outcome, Outcome.COMMITTED)
            self.assertTrue(result.commit_hash)

            temp_dir = os.path.join(repo, ".compiled-commit-tmp")
            message_path = os.path.join(temp_dir, "commit_message.txt")
            self.assertFalse(os.path.exists(message_path))

            log = pipeline.git.rev_parse_head()
            self.assertEqual(log, result.commit_hash)
        finally:
            cleanup(repo)

    def test_staged_empty_at_commit_stage_is_nothing_to_commit(self):
        repo = make_repo()
        try:
            commit_file(repo, "only.txt", "content\n", "init")
            pipeline = _make_pipeline(repo)
            pipeline.result = PipelineResult()
            pipeline.untracked_files = []
            pipeline.rendered_message = "chore: noop"

            outcome = pipeline._commit()

            self.assertEqual(outcome, Outcome.NOTHING_TO_COMMIT)
        finally:
            cleanup(repo)


if __name__ == "__main__":
    unittest.main()
