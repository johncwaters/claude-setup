"""Credential-gate ordering for the kp- checks modules.

These tasks' checks.py files live under tasks/, not the runner package, so they are
loaded directly via importlib (same technique scoring.py's subprocess runner uses)
rather than imported as a module.
"""

import importlib.util
import os
import shutil
import tempfile
import unittest

TASKS_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tasks")
CREDENTIAL_ENV_VARS = ("EVALS_POSTHOG_PERSONAL_KEY", "EVALS_POSTHOG_KEEPLINGS_PROJECT_ID")


def _load_checks_module(task_id):
    path = os.path.join(TASKS_DIR, task_id, "checks.py")
    spec = importlib.util.spec_from_file_location(f"{task_id.replace('-', '_')}_checks", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class CredentialGateOrderingTests(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.mkdtemp(prefix="evals-kp-checks-test-")
        self._saved_env = {name: os.environ.pop(name, None) for name in CREDENTIAL_ENV_VARS}

    def tearDown(self):
        shutil.rmtree(self.workspace, ignore_errors=True)
        for name, value in self._saved_env.items():
            if value is not None:
                os.environ[name] = value

    def test_kp_checkin_funnel_returns_check_infra_without_creds_even_with_no_answer_json(self):
        self.assertFalse(os.path.isfile(os.path.join(self.workspace, "answer.json")))
        checks = _load_checks_module("kp-checkin-funnel")

        result = checks.run_checks(self.workspace, {"id": "kp-checkin-funnel"}, {"posthog": {}})

        self.assertFalse(result["passed"])
        self.assertEqual(result["reason_code"], "check-infra")

    def test_kp_release_impact_returns_check_infra_without_creds_even_with_no_answer_json(self):
        self.assertFalse(os.path.isfile(os.path.join(self.workspace, "answer.json")))
        checks = _load_checks_module("kp-release-impact")

        result = checks.run_checks(self.workspace, {"id": "kp-release-impact"}, {"posthog": {}})

        self.assertFalse(result["passed"])
        self.assertEqual(result["reason_code"], "check-infra")

    def test_kp_store_engagement_returns_check_infra_without_creds_even_with_no_answer_json(self):
        self.assertFalse(os.path.isfile(os.path.join(self.workspace, "answer.json")))
        checks = _load_checks_module("kp-store-engagement")

        result = checks.run_checks(self.workspace, {"id": "kp-store-engagement"}, {"posthog": {}})

        self.assertFalse(result["passed"])
        self.assertEqual(result["reason_code"], "check-infra")

    def test_keeplings_project_id_env_name_is_read_from_config(self):
        os.environ["EVALS_POSTHOG_PERSONAL_KEY"] = "test-key"
        os.environ["EVALS_TEST_CUSTOM_KEEPLINGS_ID"] = "12345"
        self.addCleanup(os.environ.pop, "EVALS_TEST_CUSTOM_KEEPLINGS_ID", None)
        checks = _load_checks_module("kp-checkin-funnel")

        creds = checks._read_env_creds({"posthog": {"keeplings_project_id_env": "EVALS_TEST_CUSTOM_KEEPLINGS_ID"}})

        self.assertIsNotNone(creds)
        self.assertEqual(creds["project_id"], "12345")


if __name__ == "__main__":
    unittest.main()
