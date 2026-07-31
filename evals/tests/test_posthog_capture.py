import json
import os
import unittest
from unittest import mock

from runner import posthog_capture


class PosthogCaptureTests(unittest.TestCase):
    def setUp(self):
        self.config = {"posthog": {"project_api_key_env": "EVALS_TEST_PROJECT_KEY", "host": "https://us.i.posthog.com"}}
        os.environ.pop("EVALS_TEST_PROJECT_KEY", None)

    def tearDown(self):
        os.environ.pop("EVALS_TEST_PROJECT_KEY", None)

    def test_noop_without_env_key(self):
        captured = posthog_capture.capture_eval_run_completed(
            self.config, "t", "none", 1, True, "pass", 1.0, 3,
            {"gross": 100, "noncached": 100, "output": 10, "cache_read": 0, "cost_usd": 0.01},
            "claude-sonnet-5", None,
        )
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

        with mock.patch("runner.posthog_capture.urllib.request.urlopen", fake_urlopen):
            captured = posthog_capture.capture_eval_run_completed(
                self.config, "t1", "bundle", 2, False, "wrong-answer", 5.5, 4,
                {"gross": 1000, "noncached": 900, "output": 50, "cache_read": 100, "cost_usd": 0.1},
                "claude-sonnet-5", "abc123",
            )

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

    def test_network_failure_returns_false_without_raising(self):
        os.environ["EVALS_TEST_PROJECT_KEY"] = "test-key"

        def raising_urlopen(request, timeout=10):
            raise OSError("network unreachable")

        with mock.patch("runner.posthog_capture.urllib.request.urlopen", raising_urlopen):
            captured = posthog_capture.capture_eval_run_completed(
                self.config, "t", "none", 1, True, "pass", 1.0, 1,
                {"gross": 1, "noncached": 1, "output": 1, "cache_read": 0, "cost_usd": 0.0},
                "claude-sonnet-5", None,
            )
        self.assertFalse(captured)


if __name__ == "__main__":
    unittest.main()
