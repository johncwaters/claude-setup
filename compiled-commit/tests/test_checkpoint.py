import json
import os
import unittest

from src.failures import Outcome
from src.llm import LlmUsage
from src.pipeline import Pipeline, PipelineConfig
from tests.helpers import cleanup, commit_file, make_repo, write_file


class ReviewFindingLlm:
    mode = "live"

    def call(self, **_kwargs):
        return (
            {
                "verdict": "approve",
                "findings": [
                    {
                        "severity": "medium",
                        "file": "app.py",
                        "line": 1,
                        "issue": "Reviewed issue",
                        "fix": "Reviewed fix",
                    }
                ],
            },
            [
                LlmUsage(
                    name="code_review",
                    model="fixture",
                    input_tokens=1,
                    cache_creation_input_tokens=0,
                    cache_read_input_tokens=0,
                    output_tokens=1,
                    duration_ms=1,
                    retries=0,
                )
            ],
            [],
        )


def _make_pipeline(repo, llm_client):
    config = PipelineConfig(
        repo=repo,
        llm_client=llm_client,
        no_sync=True,
        skip_deslop=True,
        no_push=True,
        message="chore: checkpoint\n\nBody text here.",
    )
    return Pipeline(config)


class CheckpointTests(unittest.TestCase):
    def test_checkpoint_contains_review_findings_before_later_stage_failure(self):
        repo = make_repo()
        try:
            commit_file(repo, "app.py", "value = 1\n", "init")
            write_file(repo, "app.py", "value = 2\n")
            pipeline = _make_pipeline(repo, ReviewFindingLlm())

            def fail_after_review_checkpoint():
                raise RuntimeError("simulated later failure")

            pipeline._message = fail_after_review_checkpoint

            with self.assertRaises(RuntimeError):
                pipeline.run()

            checkpoint_path = os.path.join(repo, ".compiled-commit-tmp", "checkpoint.json")
            with open(checkpoint_path, encoding="utf-8") as handle:
                checkpoint = json.load(handle)

            self.assertTrue(checkpoint["checkpoint"])
            self.assertEqual(checkpoint["stage"], "REVIEW")
            self.assertEqual(checkpoint["findings"][0]["issue"], "Reviewed issue")
        finally:
            cleanup(repo)

    def test_stage_times_are_present_in_final_json(self):
        repo = make_repo()
        try:
            commit_file(repo, "app.py", "value = 1\n", "init")
            write_file(repo, "app.py", "value = 2\n")
            pipeline = _make_pipeline(repo, ReviewFindingLlm())

            result = pipeline.run()
            payload = json.loads(result.to_json())

            self.assertEqual(result.outcome, Outcome.COMMITTED)
            self.assertIn("stage_times", payload)
            self.assertTrue(payload["stage_times"])
            self.assertTrue(
                all("stage" in item and "seconds" in item for item in payload["stage_times"])
            )
        finally:
            cleanup(repo)


if __name__ == "__main__":
    unittest.main()
