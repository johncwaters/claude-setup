import json
import os
import unittest
from unittest import mock

from runner import posthog_capture
from runner.journal import JournalEntry


def _make_entry(task, regime, trial, passed, reason_code, wall_secs, turns, usage, model, bundle_hash):
    return JournalEntry(
        ts="2026-07-30T00:00:00+00:00", task=task, regime=regime, trial=trial,
        status="completed", passed=passed, reason_code=reason_code,
        wall_secs=wall_secs, turns=turns, usage=usage, model=model, bundle_hash=bundle_hash,
        snapshot_hashes={}, posthog_captured=False,
    )


class PosthogCaptureTests(unittest.TestCase):
    def setUp(self):
        self.config = {"posthog": {"project_api_key_env": "EVALS_TEST_PROJECT_KEY", "host": "https://us.i.posthog.com"}}
        os.environ.pop("EVALS_TEST_PROJECT_KEY", None)

    def tearDown(self):
        os.environ.pop("EVALS_TEST_PROJECT_KEY", None)

    def test_noop_without_env_key(self):
        entry = _make_entry(
            "t", "none", 1, True, "pass", 1.0, 3,
            {"gross": 100, "noncached": 100, "output": 10, "cache_read": 0, "cost_usd": 0.01},
            "claude-sonnet-5", None,
        )
        captured = posthog_capture.capture_eval_run_completed(self.config, entry)
        self.assertFalse(captured)

    def test_payload_shape_with_fake_urlopen(self):
        os.environ["EVALS_TEST_PROJECT_KEY"] = "test-key"
        captured_request = {}

        class FakeResponse:
            status = 200

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

        def fake_urlopen(request, timeout=10):
            captured_request["url"] = request.full_url
            captured_request["body"] = json.loads(request.data)
            return FakeResponse()

        entry = _make_entry(
            "t1", "bundle", 2, False, "wrong-answer", 5.5, 4,
            {"gross": 1000, "noncached": 900, "output": 50, "cache_read": 100, "cost_usd": 0.1},
            "claude-sonnet-5", "abc123",
        )
        with mock.patch("runner.posthog_capture.urllib.request.urlopen", fake_urlopen):
            captured = posthog_capture.capture_eval_run_completed(self.config, entry)

        self.assertTrue(captured)
        self.assertEqual(captured_request["url"], "https://us.i.posthog.com/batch/")
        body = captured_request["body"]
        self.assertEqual(body["api_key"], "test-key")
        event = body["batch"][0]
        self.assertEqual(event["event"], "eval_run_completed")
        self.assertEqual(event["properties"]["task"], "t1")
        self.assertEqual(event["properties"]["regime"], "bundle")
        self.assertEqual(event["properties"]["reason_code"], "wrong-answer")
        self.assertEqual(event["properties"]["bundle_hash"], "abc123")
        self.assertEqual(event["properties"]["usage_cost_usd"], 0.1)

    def test_payload_shape_accepts_a_plain_dict_entry_too(self):
        os.environ["EVALS_TEST_PROJECT_KEY"] = "test-key"
        captured_request = {}

        class FakeResponse:
            status = 200

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

        def fake_urlopen(request, timeout=10):
            captured_request["body"] = json.loads(request.data)
            return FakeResponse()

        entry = {
            "task": "t1", "regime": "none", "trial": 1, "passed": True, "reason_code": "pass",
            "wall_secs": 1.0, "turns": 1, "model": "claude-sonnet-5", "bundle_hash": None,
            "usage": {"gross": 1, "noncached": 1, "output": 1, "cache_read": 0, "cost_usd": 0.0},
        }
        with mock.patch("runner.posthog_capture.urllib.request.urlopen", fake_urlopen):
            captured = posthog_capture.capture_eval_run_completed(self.config, entry)

        self.assertTrue(captured)
        self.assertEqual(captured_request["body"]["batch"][0]["properties"]["task"], "t1")

    def test_network_failure_returns_false_without_raising(self):
        os.environ["EVALS_TEST_PROJECT_KEY"] = "test-key"

        def raising_urlopen(request, timeout=10):
            raise OSError("network unreachable")

        entry = _make_entry(
            "t", "none", 1, True, "pass", 1.0, 1,
            {"gross": 1, "noncached": 1, "output": 1, "cache_read": 0, "cost_usd": 0.0},
            "claude-sonnet-5", None,
        )
        with mock.patch("runner.posthog_capture.urllib.request.urlopen", raising_urlopen):
            captured = posthog_capture.capture_eval_run_completed(self.config, entry)
        self.assertFalse(captured)


if __name__ == "__main__":
    unittest.main()
