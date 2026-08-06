import os
import shutil
import tempfile
import textwrap
import unittest

from runner import scoring


class ScoringTests(unittest.TestCase):
    def setUp(self):
        self.tmp_dir = tempfile.mkdtemp(prefix="evals-scoring-test-")
        self.workspace = os.path.join(self.tmp_dir, "workspace")
        os.makedirs(self.workspace)

    def tearDown(self):
        shutil.rmtree(self.tmp_dir, ignore_errors=True)

    def _write_checks(self, body):
        task_dir = os.path.join(self.tmp_dir, "task")
        os.makedirs(task_dir, exist_ok=True)
        with open(os.path.join(task_dir, "checks.py"), "w", encoding="utf-8") as handle:
            handle.write(textwrap.dedent(body))
        return task_dir

    def test_passing_checks_returns_pass(self):
        task_dir = self._write_checks("""
            def run_checks(workspace, task, config):
                return {"passed": True, "reason_code": "pass", "detail": "ok"}
        """)
        result = scoring.score_task(task_dir, self.workspace, {"id": "t"}, {})
        self.assertTrue(result["passed"])
        self.assertEqual(result["reason_code"], "pass")

    def test_failing_checks_pass_through_their_own_reason_code(self):
        task_dir = self._write_checks("""
            def run_checks(workspace, task, config):
                return {"passed": False, "reason_code": "wrong-answer", "detail": "expected 4, got 5"}
        """)
        result = scoring.score_task(task_dir, self.workspace, {"id": "t"}, {})
        self.assertFalse(result["passed"])
        self.assertEqual(result["reason_code"], "wrong-answer")

    def test_raising_checks_normalizes_to_check_infra(self):
        task_dir = self._write_checks("""
            def run_checks(workspace, task, config):
                raise RuntimeError("boom")
        """)
        result = scoring.score_task(task_dir, self.workspace, {"id": "t"}, {})
        self.assertFalse(result["passed"])
        self.assertEqual(result["reason_code"], "check-infra")
        self.assertIn("boom", result["detail"])

    def test_missing_run_checks_function_normalizes_to_check_infra(self):
        task_dir = self._write_checks("x = 1\n")
        result = scoring.score_task(task_dir, self.workspace, {"id": "t"}, {})
        self.assertEqual(result["reason_code"], "check-infra")

    def test_malformed_result_normalizes_to_check_infra(self):
        task_dir = self._write_checks("""
            def run_checks(workspace, task, config):
                return {"detail": "missing required fields"}
        """)
        result = scoring.score_task(task_dir, self.workspace, {"id": "t"}, {})
        self.assertEqual(result["reason_code"], "check-infra")

    def test_timeout_normalizes_to_check_infra(self):
        task_dir = self._write_checks("""
            import time
            def run_checks(workspace, task, config):
                time.sleep(5)
                return {"passed": True, "reason_code": "pass", "detail": "ok"}
        """)
        result = scoring.score_task(task_dir, self.workspace, {"id": "t"}, {}, timeout_secs=1)
        self.assertEqual(result["reason_code"], "check-infra")

    def test_turn_capped_run_relabels_build_fail_and_preserves_original_detail(self):
        task_dir = self._write_checks("""
            def run_checks(workspace, task, config):
                return {"passed": False, "reason_code": "build-fail", "detail": "npm run typecheck failed"}
        """)
        result = scoring.score_task(
            task_dir, self.workspace, {"id": "t"}, {}, turns=30, max_turns=30,
        )
        self.assertFalse(result["passed"])
        self.assertEqual(result["reason_code"], "turn-capped")
        self.assertIn("build-fail", result["detail"])
        self.assertIn("npm run typecheck failed", result["detail"])

    def test_turn_capped_run_relabels_missing_events_when_turns_exceed_max(self):
        task_dir = self._write_checks("""
            def run_checks(workspace, task, config):
                return {"passed": False, "reason_code": "missing-events", "detail": "no register call found"}
        """)
        result = scoring.score_task(
            task_dir, self.workspace, {"id": "t"}, {}, turns=35, max_turns=30,
        )
        self.assertEqual(result["reason_code"], "turn-capped")

    def test_build_fail_under_the_turn_cap_is_not_relabeled(self):
        task_dir = self._write_checks("""
            def run_checks(workspace, task, config):
                return {"passed": False, "reason_code": "build-fail", "detail": "npm run typecheck failed"}
        """)
        result = scoring.score_task(
            task_dir, self.workspace, {"id": "t"}, {}, turns=5, max_turns=30,
        )
        self.assertEqual(result["reason_code"], "build-fail")

    def test_wrong_answer_at_the_turn_cap_is_not_relabeled(self):
        # turn-capped only ever stands in for build-fail/missing-events: a genuine
        # wrong-answer verdict means checks.py ran to completion and judged the result,
        # which is not a turn-budget artifact regardless of how many turns it took.
        task_dir = self._write_checks("""
            def run_checks(workspace, task, config):
                return {"passed": False, "reason_code": "wrong-answer", "detail": "expected 4, got 5"}
        """)
        result = scoring.score_task(
            task_dir, self.workspace, {"id": "t"}, {}, turns=30, max_turns=30,
        )
        self.assertEqual(result["reason_code"], "wrong-answer")

    def test_config_checks_timeout_secs_flows_through_as_the_subprocess_deadline(self):
        # config-plumbing: checks_timeout_secs from config.yml (not scoring.py's own
        # fallback default) must be the value actually enforced on the subprocess,
        # since it now has to cover both the typecheck and the event-poll budget.
        task_dir = self._write_checks("""
            import time
            def run_checks(workspace, task, config):
                time.sleep(5)
                return {"passed": True, "reason_code": "pass", "detail": "ok"}
        """)
        result = scoring.score_task(task_dir, self.workspace, {"id": "t"}, {"checks_timeout_secs": 1})
        self.assertEqual(result["reason_code"], "check-infra")
        self.assertIn("timed out after 1s", result["detail"])


if __name__ == "__main__":
    unittest.main()
