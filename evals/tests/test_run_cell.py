import json
import os
import shutil
import tempfile
import unittest

from runner import run as run_module
from runner.journal import Journal, JournalEntry

FIXTURE_TASK_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "sample-task")


class CellLoopExceptionHandlingTests(unittest.TestCase):
    def setUp(self):
        self.tmp_root = tempfile.mkdtemp(prefix="evals-run-cell-test-")
        self.tasks_dir = os.path.join(self.tmp_root, "tasks")
        os.makedirs(self.tasks_dir)
        shutil.copytree(FIXTURE_TASK_DIR, os.path.join(self.tasks_dir, "sample-task"))

        self.bundles_dir = os.path.join(self.tmp_root, "bundles")
        os.makedirs(os.path.join(self.bundles_dir, "snapshots"))
        self.results_dir = os.path.join(self.tmp_root, "results")

        self.config_path = os.path.join(self.tmp_root, "config.yml")
        with open(self.config_path, "w", encoding="utf-8") as handle:
            handle.write(
                "model: claude-sonnet-5\n"
                "max_turns: 5\n"
                "trials_per_cell: 1\n"
                "regimes: [none, bundle]\n"
                f"bundles_dir: {self.bundles_dir}\n"
            )

        self.replay_dir = os.path.join(self.tmp_root, "fixtures")
        os.makedirs(self.replay_dir)
        with open(os.path.join(self.replay_dir, "sample-task_none_1.json"), "w", encoding="utf-8") as handle:
            json.dump({
                "num_turns": 1, "total_cost_usd": 0.01,
                "usage": {"input_tokens": 10, "cache_creation_input_tokens": 0,
                          "cache_read_input_tokens": 0, "output_tokens": 5},
                "result": "4",
            }, handle)

    def tearDown(self):
        shutil.rmtree(self.tmp_root, ignore_errors=True)

    def test_bundle_less_task_journals_infra_and_batch_still_scores_the_good_cell(self):
        # sample-task's task.yml has bundle: null, so the bundle regime raises inside
        # regimes.assemble; that must not crash the whole batch or skip summary.json.
        exit_code = run_module.main([
            "--tasks-dir", self.tasks_dir,
            "--config", self.config_path,
            "--results-dir", self.results_dir,
            "--replay-dir", self.replay_dir,
        ])

        self.assertEqual(exit_code, 0)

        journal = Journal(os.path.join(self.results_dir, "journal.jsonl"))
        by_regime = {row["regime"]: row for row in journal.read_all()}

        self.assertEqual(by_regime["none"]["status"], "completed")
        self.assertTrue(by_regime["none"]["passed"])

        self.assertEqual(by_regime["bundle"]["status"], "infra")
        self.assertIn("bundle", by_regime["bundle"]["detail"])

        with open(os.path.join(self.results_dir, "summary.json"), encoding="utf-8") as handle:
            summary = json.load(handle)
        self.assertEqual(summary["sample-task::none"]["scored_trials"], 1)
        self.assertEqual(summary["sample-task::bundle"]["scored_trials"], 0)
        self.assertEqual(summary["sample-task::bundle"]["infra_trials"], 1)


class TokenBudgetTests(unittest.TestCase):
    def setUp(self):
        self.tmp_root = tempfile.mkdtemp(prefix="evals-token-budget-test-")
        self.replay_dir = os.path.join(self.tmp_root, "fixtures")
        os.makedirs(self.replay_dir)
        with open(os.path.join(self.replay_dir, "sample-task_none_1.json"), "w", encoding="utf-8") as handle:
            json.dump({
                "num_turns": 1, "total_cost_usd": 5.0,
                "usage": {"input_tokens": 900000, "cache_creation_input_tokens": 0,
                          "cache_read_input_tokens": 0, "output_tokens": 100000},
                "result": "way too much",
            }, handle)
        self.results_dir = os.path.join(self.tmp_root, "results")

    def tearDown(self):
        shutil.rmtree(self.tmp_root, ignore_errors=True)

    def test_gross_tokens_over_cap_journals_infra_with_token_budget_detail(self):
        task = run_module.load_task(FIXTURE_TASK_DIR)
        journal = Journal(os.path.join(self.results_dir, "journal.jsonl"))
        config = {
            "model": "claude-sonnet-5", "max_turns": 5,
            "token_budget": {"max_gross_tokens_per_run": 1000},
        }

        entry = run_module.run_cell(task, "none", 1, config, journal, self.replay_dir, False, False)

        self.assertEqual(entry.status, "infra")
        self.assertEqual(entry.reason_code, "check-infra")
        self.assertEqual(entry.detail, "token-budget-exceeded: 1000000 > 1000")

    def test_gross_tokens_within_cap_scores_normally(self):
        task = run_module.load_task(FIXTURE_TASK_DIR)
        journal = Journal(os.path.join(self.results_dir, "journal.jsonl"))
        config = {
            "model": "claude-sonnet-5", "max_turns": 5,
            "token_budget": {"max_gross_tokens_per_run": 5_000_000},
        }

        entry = run_module.run_cell(task, "none", 1, config, journal, self.replay_dir, False, False)

        self.assertEqual(entry.status, "completed")
        self.assertTrue(entry.passed)


class SummarizeScopingTests(unittest.TestCase):
    def setUp(self):
        self.tmp_dir = tempfile.mkdtemp(prefix="evals-summarize-test-")
        self.journal_path = os.path.join(self.tmp_dir, "journal.jsonl")

    def tearDown(self):
        shutil.rmtree(self.tmp_dir, ignore_errors=True)

    def _append(self, journal, task, regime, status="completed", passed=True, reason_code="pass"):
        journal.append(JournalEntry(
            ts="2026-07-30T00:00:00+00:00", task=task, regime=regime, trial=1,
            status=status, passed=passed, reason_code=reason_code, wall_secs=1.0, turns=1,
            usage={"gross": 100, "noncached": 100, "output": 10, "cache_read": 0, "cost_usd": 0.01},
            model="claude-sonnet-5", bundle_hash=None, snapshot_hashes={}, posthog_captured=False,
        ))

    def test_summarize_only_rolls_up_cells_selected_in_the_current_batch(self):
        journal = Journal(self.journal_path)
        self._append(journal, "sample-task", "none")
        self._append(journal, "other-task", "none", passed=False, reason_code="wrong-answer")

        summary = run_module._summarize(journal, [{"id": "sample-task"}], ["none"], 1)

        self.assertIn("sample-task::none", summary)
        self.assertNotIn("other-task::none", summary)
        cell = summary["sample-task::none"]
        self.assertEqual(cell["scored_trials"], 1)
        self.assertEqual(cell["infra_trials"], 0)
        self.assertEqual(cell["total_trials"], 1)
        self.assertEqual(sum(cell["reason_code_histogram"].values()), cell["total_trials"])

    def test_summarize_counts_infra_trials_separately_from_scored(self):
        journal = Journal(self.journal_path)
        self._append(journal, "sample-task", "bundle", status="infra", passed=False, reason_code="check-infra")

        summary = run_module._summarize(journal, [{"id": "sample-task"}], ["bundle"], 1)

        cell = summary["sample-task::bundle"]
        self.assertEqual(cell["scored_trials"], 0)
        self.assertEqual(cell["infra_trials"], 1)
        self.assertEqual(cell["total_trials"], 1)


if __name__ == "__main__":
    unittest.main()
