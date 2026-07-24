import os
import tempfile
import unittest

from src.failures import Outcome
from src.llm import LlmClient
from src.pipeline import Pipeline, PipelineConfig
from tests.helpers import clone_repo, cleanup, commit_file, make_bare_origin, make_repo, run_git, write_file


def _make_pipeline(repo):
    client = LlmClient(mode="live")
    config = PipelineConfig(
        repo=repo,
        llm_client=client,
        no_sync=False,
        skip_deslop=True,
        skip_review=True,
        message="chore: x",
    )
    return Pipeline(config)


class SyncTests(unittest.TestCase):
    def test_feature_branch_behind_develop_merges_cleanly(self):
        origin = make_bare_origin()
        seed = make_repo()
        local_parent = tempfile.mkdtemp(prefix="cc-test-local-parent-")
        local = os.path.join(local_parent, "local")
        try:
            run_git(seed, ["remote", "add", "origin", origin])
            commit_file(seed, "base.txt", "base\n", "init")
            run_git(seed, ["push", "-u", "origin", "main"])
            run_git(seed, ["checkout", "-b", "develop"])
            run_git(seed, ["push", "-u", "origin", "develop"])
            run_git(seed, ["checkout", "-b", "feature"])
            run_git(seed, ["push", "-u", "origin", "feature"])
            run_git(seed, ["checkout", "develop"])
            commit_file(seed, "develop_only.txt", "develop advance\n", "develop advance")
            run_git(seed, ["push", "origin", "develop"])

            clone_repo(origin, local)
            run_git(local, ["checkout", "-b", "feature", "origin/feature"])

            pipeline = _make_pipeline(local)
            outcome = pipeline._sync()

            self.assertIsNone(outcome)
            log = run_git(local, ["log", "--oneline", "--all"]).stdout
            self.assertIn("develop advance", log)
            self.assertTrue(os.path.exists(os.path.join(local, "develop_only.txt")))
        finally:
            cleanup(origin, seed, local_parent)

    def test_diverged_local_develop_is_sync_diverged(self):
        origin = make_bare_origin()
        seed = make_repo()
        local_parent = tempfile.mkdtemp(prefix="cc-test-local-parent-")
        local = os.path.join(local_parent, "local")
        try:
            run_git(seed, ["remote", "add", "origin", origin])
            commit_file(seed, "base.txt", "base\n", "init")
            run_git(seed, ["push", "-u", "origin", "main"])
            run_git(seed, ["checkout", "-b", "develop"])
            run_git(seed, ["push", "-u", "origin", "develop"])
            run_git(seed, ["checkout", "-b", "feature"])
            run_git(seed, ["push", "-u", "origin", "feature"])

            clone_repo(origin, local)
            run_git(local, ["checkout", "-b", "feature", "origin/feature"])
            run_git(local, ["branch", "develop", "origin/develop"])
            run_git(local, ["checkout", "develop"])
            write_file(local, "base.txt", "amended locally\n")
            run_git(local, ["add", "-A"])
            run_git(local, ["commit", "--amend", "-q", "-m", "amended develop commit"])
            run_git(local, ["checkout", "feature"])

            pipeline = _make_pipeline(local)
            outcome = pipeline._sync()

            self.assertEqual(outcome, Outcome.SYNC_DIVERGED)
        finally:
            cleanup(origin, seed, local_parent)

    def test_conflicting_change_aborts_merge_cleanly(self):
        origin = make_bare_origin()
        seed = make_repo()
        local_parent = tempfile.mkdtemp(prefix="cc-test-local-parent-")
        local = os.path.join(local_parent, "local")
        try:
            run_git(seed, ["remote", "add", "origin", origin])
            commit_file(seed, "shared.txt", "one\ntwo\nthree\n", "init")
            run_git(seed, ["push", "-u", "origin", "main"])
            run_git(seed, ["checkout", "-b", "develop"])
            run_git(seed, ["push", "-u", "origin", "develop"])

            clone_repo(origin, local)
            run_git(local, ["checkout", "-b", "develop", "origin/develop"])
            write_file(local, "shared.txt", "one\nLOCAL\nthree\n")
            run_git(local, ["commit", "-q", "-am", "local change"])

            write_file(seed, "shared.txt", "one\nREMOTE\nthree\n")
            run_git(seed, ["checkout", "develop"])
            run_git(seed, ["commit", "-q", "-am", "remote change"])
            run_git(seed, ["push", "origin", "develop"])

            pipeline = _make_pipeline(local)
            outcome = pipeline._sync()

            self.assertEqual(outcome, Outcome.MERGE_CONFLICT)
            merge_head_present = run_git(local, ["rev-parse", "-q", "--verify", "MERGE_HEAD"], check=False)
            self.assertNotEqual(merge_head_present.returncode, 0)
        finally:
            cleanup(origin, seed, local_parent)


if __name__ == "__main__":
    unittest.main()
