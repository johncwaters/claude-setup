import json
import os
import tempfile
import unittest

from src.failures import Outcome
from src.llm import LlmClient
from src.pipeline import Pipeline, PipelineConfig
from src.validators import render_message
from tests.helpers import cleanup, commit_file, make_repo, write_file

# The only permitted fixture-driven test (SPEC tests/ policy): the LLM response is
# canned, but every git operation runs for real against a temp repo.

FIXTURE_MESSAGE = {
    "type": "fix",
    "scope": None,
    "description": "adjust retry threshold",
    "body": "Bumped the retry threshold from 10 to 20 based on load testing.",
    "trailers": {
        "constraint": None,
        "rejected": None,
        "directive": None,
        "confidence": "high",
        "scope_risk": "narrow",
        "not_tested": None,
    },
    "trivial": False,
}


class LlmReplayAdapterTests(unittest.TestCase):
    def test_replay_fixture_drives_message_stage_to_a_real_commit(self):
        repo = make_repo()
        fixtures_dir = tempfile.mkdtemp(prefix="cc-test-fixtures-")
        try:
            commit_file(repo, "retry.py", "THRESHOLD = 10\n", "init")
            write_file(repo, "retry.py", "THRESHOLD = 20\n")

            fixture_path = os.path.join(fixtures_dir, "replaytest_commit_message.json")
            raw_response = {
                "result": "```json\n" + json.dumps(FIXTURE_MESSAGE) + "\n```",
                "usage": {
                    "input_tokens": 500,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 80,
                },
            }
            with open(fixture_path, "w", encoding="utf-8") as handle:
                json.dump(raw_response, handle)

            client = LlmClient(mode="replay", fixtures_dir=fixtures_dir)
            config = PipelineConfig(
                repo=repo,
                llm_client=client,
                skip_deslop=True,
                skip_review=True,
                no_push=True,
                fixture_prefix="replaytest",
            )
            result = Pipeline(config).run()

            self.assertEqual(result.outcome, Outcome.COMMITTED)
            self.assertTrue(result.commit_hash)
            self.assertEqual(result.commit_message, render_message(FIXTURE_MESSAGE))
            self.assertEqual(len(result.llm_usage), 1)
            self.assertEqual(result.llm_usage[0].name, "commit_message")
            self.assertEqual(result.llm_usage[0].input_tokens, 500)
        finally:
            cleanup(repo, fixtures_dir)


if __name__ == "__main__":
    unittest.main()
