import tempfile
import unittest

from src.failures import Outcome
from src.llm import LlmClient
from src.pipeline import Pipeline, PipelineConfig
from tests.helpers import cleanup, commit_file, make_repo, write_file


class WorkspaceConfinementTests(unittest.TestCase):
    def test_pipeline_refuses_when_repo_is_outside_workspace(self):
        repo = make_repo()
        unrelated_workspace = tempfile.mkdtemp(prefix="cc-test-unrelated-workspace-")
        try:
            commit_file(repo, "a.txt", "one\n", "init")
            write_file(repo, "a.txt", "one\ntwo\n")

            client = LlmClient(mode="live")
            config = PipelineConfig(
                repo=repo,
                workspace=unrelated_workspace,
                llm_client=client,
                no_sync=True,
                skip_deslop=True,
                skip_review=True,
                message="chore: test",
            )
            result = Pipeline(config).run()

            self.assertEqual(result.outcome, Outcome.GATE_FAILED)
            self.assertTrue(any("workspace confinement" in w for w in result.warnings))
            self.assertEqual(result.git_op_count, 0)
        finally:
            cleanup(repo, unrelated_workspace)

    def test_workspace_equal_to_repo_is_allowed(self):
        repo = make_repo()
        try:
            commit_file(repo, "a.txt", "one\n", "init")
            client = LlmClient(mode="live")
            config = PipelineConfig(
                repo=repo,
                workspace=repo,
                llm_client=client,
                no_sync=True,
                skip_deslop=True,
                skip_review=True,
                message="chore: test",
            )
            result = Pipeline(config).run()

            self.assertNotEqual(result.outcome, Outcome.GATE_FAILED)
        finally:
            cleanup(repo)


if __name__ == "__main__":
    unittest.main()
