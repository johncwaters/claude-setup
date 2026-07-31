import io
import os
import shutil
import tempfile
import unittest
from contextlib import redirect_stdout

from runner import run as run_module

FIXTURE_TASK_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "sample-task")


class RunDryRunTests(unittest.TestCase):
    def setUp(self):
        self.tmp_root = tempfile.mkdtemp(prefix="evals-run-dry-test-")
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
                "regimes: [none]\n"
                f"bundles_dir: {self.bundles_dir}\n"
            )

    def tearDown(self):
        shutil.rmtree(self.tmp_root, ignore_errors=True)

    def test_dry_run_exits_zero_and_prints_plan_without_invoking_claude(self):
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            exit_code = run_module.main([
                "--dry-run",
                "--tasks-dir", self.tasks_dir,
                "--config", self.config_path,
                "--results-dir", self.results_dir,
            ])

        self.assertEqual(exit_code, 0)
        output = buffer.getvalue()
        self.assertIn("sample-task", output)
        self.assertIn("dry-run", output)
        self.assertFalse(os.path.isfile(os.path.join(self.results_dir, "journal.jsonl")))

    def test_dry_run_over_two_regimes_prints_both(self):
        with open(os.path.join(self.bundles_dir, "snapshots", "llms-txt.md"), "w", encoding="utf-8") as handle:
            handle.write("snapshot content")

        buffer = io.StringIO()
        with redirect_stdout(buffer):
            exit_code = run_module.main([
                "--dry-run",
                "--tasks-dir", self.tasks_dir,
                "--config", self.config_path,
                "--results-dir", self.results_dir,
                "--regimes", "none,llms-txt",
            ])

        self.assertEqual(exit_code, 0)
        output = buffer.getvalue()
        self.assertIn("regime=none", output)
        self.assertIn("regime=llms-txt", output)

        none_block, llms_txt_block = output.split("regime=llms-txt")
        self.assertIn("'WebFetch'", none_block)  # none regime disallows WebFetch outright
        self.assertNotIn("'WebFetch'", llms_txt_block.split("allowed_tools")[0])  # absent from disallowed_tools
        self.assertIn("WebFetch(domain:posthog.com)", llms_txt_block)

    def test_relative_bundles_dir_resolves_against_evals_root_not_cwd(self):
        with open(os.path.join(self.tasks_dir, "sample-task", "task.yml"), "w", encoding="utf-8") as handle:
            handle.write(
                "id: sample-task\nclass: hogql-analysis\nmode: retrospective\nrepo: null\n"
                "pinned_commit: null\nprompt_file: prompt.md\ntime_window: null\n"
                "bundle: sample-bundle.md\ncaptured: \"2026-07-30\"\nreference: reference.md\n"
            )
        with open(os.path.join(self.bundles_dir, "sample-bundle.md"), "w", encoding="utf-8") as handle:
            handle.write("curated bundle content")

        relative_config_path = os.path.join(self.tmp_root, "relative-config.yml")
        with open(relative_config_path, "w", encoding="utf-8") as handle:
            handle.write(
                "model: claude-sonnet-5\n"
                "max_turns: 5\n"
                "trials_per_cell: 1\n"
                "regimes: [bundle]\n"
                "bundles_dir: bundles\n"
            )

        other_cwd = tempfile.mkdtemp(prefix="evals-run-dry-other-cwd-")
        original_cwd = os.getcwd()
        os.chdir(other_cwd)
        try:
            buffer = io.StringIO()
            with redirect_stdout(buffer):
                exit_code = run_module.main([
                    "--dry-run",
                    "--tasks-dir", self.tasks_dir,
                    "--config", relative_config_path,
                    "--results-dir", self.results_dir,
                ])
        finally:
            os.chdir(original_cwd)
            shutil.rmtree(other_cwd, ignore_errors=True)

        self.assertEqual(exit_code, 0)
        self.assertIn("regime=bundle", buffer.getvalue())

    def test_headline_flag_expands_to_configs_headline_regimes(self):
        with open(os.path.join(self.bundles_dir, "snapshots", "llms-txt.md"), "w", encoding="utf-8") as handle:
            handle.write("snapshot content")
        headline_config_path = os.path.join(self.tmp_root, "headline-config.yml")
        with open(headline_config_path, "w", encoding="utf-8") as handle:
            handle.write(
                "model: claude-sonnet-5\n"
                "max_turns: 5\n"
                "trials_per_cell: 1\n"
                "regimes: [none, llms-txt]\n"
                "headline_regimes: [none]\n"
                f"bundles_dir: {self.bundles_dir}\n"
            )

        buffer = io.StringIO()
        with redirect_stdout(buffer):
            exit_code = run_module.main([
                "--dry-run",
                "--headline",
                "--tasks-dir", self.tasks_dir,
                "--config", headline_config_path,
                "--results-dir", self.results_dir,
            ])

        self.assertEqual(exit_code, 0)
        output = buffer.getvalue()
        self.assertIn("regime=none", output)
        self.assertNotIn("regime=llms-txt", output)


if __name__ == "__main__":
    unittest.main()
