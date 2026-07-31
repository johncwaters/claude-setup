import glob
import io
import json
import os
import shutil
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest import mock

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

    def test_noncached_tokens_over_cap_journals_infra_with_token_budget_detail(self):
        task = run_module.load_task(FIXTURE_TASK_DIR)
        journal = Journal(os.path.join(self.results_dir, "journal.jsonl"))
        config = {
            "model": "claude-sonnet-5", "max_turns": 5,
            "token_budget": {"max_noncached_tokens_per_run": 1000},
        }

        entry = run_module.run_cell(task, "none", 1, config, journal, self.replay_dir, False, False)

        self.assertEqual(entry.status, "infra")
        self.assertEqual(entry.reason_code, "check-infra")
        self.assertEqual(entry.detail, "token-budget-exceeded: 1000000 > 1000")

    def test_noncached_tokens_within_cap_scores_normally(self):
        task = run_module.load_task(FIXTURE_TASK_DIR)
        journal = Journal(os.path.join(self.results_dir, "journal.jsonl"))
        config = {
            "model": "claude-sonnet-5", "max_turns": 5,
            "token_budget": {"max_noncached_tokens_per_run": 5_000_000},
        }

        entry = run_module.run_cell(task, "none", 1, config, journal, self.replay_dir, False, False)

        self.assertEqual(entry.status, "completed")
        self.assertTrue(entry.passed)


class McpConfigLifecycleTests(unittest.TestCase):
    """The generated MCP config holds a live bearer token, so no cell may leave one behind."""

    def setUp(self):
        self.tmp_root = tempfile.mkdtemp(prefix="evals-lifecycle-test-")
        self.replay_dir = os.path.join(self.tmp_root, "fixtures")
        os.makedirs(self.replay_dir)
        self.results_dir = os.path.join(self.tmp_root, "results")
        self.saved_environ = dict(os.environ)
        os.environ["EVALS_TEST_LIFECYCLE_TOKEN"] = "test-token"
        os.environ["EVALS_TEST_LIFECYCLE_PROJECT"] = "1234"
        self.config = {
            "model": "claude-sonnet-5", "max_turns": 5,
            "posthog": {
                "mcp_token_env": "EVALS_TEST_LIFECYCLE_TOKEN",
                "scratch_project_id_env": "EVALS_TEST_LIFECYCLE_PROJECT",
            },
        }
        self.captured_dirs = []
        self.real_assemble = run_module.regimes.assemble

    def tearDown(self):
        run_module.regimes.assemble = self.real_assemble
        shutil.rmtree(self.tmp_root, ignore_errors=True)
        if run_module.regimes._private_mcp_config_root:
            shutil.rmtree(run_module.regimes._private_mcp_config_root, ignore_errors=True)
            run_module.regimes._private_mcp_config_root = None
        os.environ.clear()
        os.environ.update(self.saved_environ)

    def _run_mcp_cell(self):
        def recording_assemble(*args, **kwargs):
            assembly = self.real_assemble(*args, **kwargs)
            if assembly.mcp_config_dir:
                self.captured_dirs.append((assembly.mcp_config_dir, assembly.mcp_config_path))
            return assembly

        run_module.regimes.assemble = recording_assemble
        task = run_module.load_task(FIXTURE_TASK_DIR)
        journal = Journal(os.path.join(self.results_dir, "journal.jsonl"))
        return run_module.run_cell(task, "mcp", 1, self.config, journal, self.replay_dir, False, False)

    def _write_replay_fixture(self):
        with open(os.path.join(self.replay_dir, "sample-task_mcp_1.json"), "w", encoding="utf-8") as handle:
            json.dump({
                "num_turns": 1, "total_cost_usd": 0.01,
                "usage": {"input_tokens": 10, "cache_creation_input_tokens": 0,
                          "cache_read_input_tokens": 0, "output_tokens": 5},
                "result": "4",
            }, handle)

    def test_token_file_is_deleted_after_a_successful_cell(self):
        self._write_replay_fixture()

        entry = self._run_mcp_cell()

        self.assertEqual(entry.status, "completed")
        self.assertEqual(len(self.captured_dirs), 1)
        config_dir, config_path = self.captured_dirs[0]
        self.assertFalse(os.path.exists(config_path))
        self.assertFalse(os.path.exists(config_dir))

    def test_a_finished_cell_leaves_no_mcp_config_residue_in_temp(self):
        self._write_replay_fixture()
        # a delta, not an absolute count: a batch running concurrently from another checkout
        # owns its own temp dirs and must not flake this
        residue_before = set(glob.glob(os.path.join(tempfile.gettempdir(), "evals-mcp*")))

        self._run_mcp_cell()

        residue_after = set(glob.glob(os.path.join(tempfile.gettempdir(), "evals-mcp*")))
        self.assertEqual(residue_after - residue_before, set())

    def test_token_file_is_deleted_when_the_cell_fails(self):
        # no replay fixture written, so claude_cli.run raises inside run_cell
        entry = self._run_mcp_cell()

        self.assertEqual(entry.status, "infra")
        self.assertEqual(len(self.captured_dirs), 1)
        config_dir, config_path = self.captured_dirs[0]
        self.assertFalse(os.path.exists(config_path))
        self.assertFalse(os.path.exists(config_dir))

    def test_an_undeletable_config_is_left_empty_and_shouted_about(self):
        config_dir = tempfile.mkdtemp(prefix="cell-", dir=self.tmp_root)
        config_path = os.path.join(config_dir, ".mcp.json")
        with open(config_path, "w", encoding="utf-8") as handle:
            handle.write('{"headers": {"Authorization": "Bearer phx_live_secret"}}')

        # stand in for a lock that survives every retry: rmtree's ignore_errors fallback
        # would otherwise leave the readable token behind without a word
        with mock.patch.object(run_module.shutil, "rmtree"):
            with redirect_stdout(io.StringIO()) as printed:
                run_module._teardown_mcp_config(config_dir, config_path)

        with open(config_path, encoding="utf-8") as handle:
            self.assertEqual(handle.read(), "")
        self.assertIn("WARNING", printed.getvalue())
        self.assertIn(config_dir, printed.getvalue())

    def test_a_removable_config_is_deleted_without_a_warning(self):
        config_dir = tempfile.mkdtemp(prefix="cell-", dir=self.tmp_root)
        config_path = os.path.join(config_dir, ".mcp.json")
        with open(config_path, "w", encoding="utf-8") as handle:
            handle.write('{"headers": {"Authorization": "Bearer phx_live_secret"}}')

        with redirect_stdout(io.StringIO()) as printed:
            run_module._teardown_mcp_config(config_dir, config_path)

        self.assertFalse(os.path.exists(config_dir))
        self.assertNotIn("WARNING", printed.getvalue())

    def test_dry_run_leaves_no_token_file_behind(self):
        task = run_module.load_task(FIXTURE_TASK_DIR)
        journal = Journal(os.path.join(self.results_dir, "journal.jsonl"))

        with redirect_stdout(io.StringIO()) as printed:
            run_module.run_cell(task, "mcp", 1, self.config, journal, self.replay_dir, False, True)

        self.assertIn("mcp_config_path=None", printed.getvalue())
        self.assertNotIn("test-token", printed.getvalue())
        self.assertIn("Bearer <redacted>", printed.getvalue())


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
