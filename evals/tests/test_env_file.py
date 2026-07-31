import io
import os
import shutil
import tempfile
import unittest
from contextlib import redirect_stdout

from runner import env_file, run as run_module


class LoadEnvFileTests(unittest.TestCase):
    def setUp(self):
        self.tmp_dir = tempfile.mkdtemp(prefix="evals-env-file-test-")
        self.env_path = os.path.join(self.tmp_dir, ".env")

    def tearDown(self):
        shutil.rmtree(self.tmp_dir, ignore_errors=True)

    def _write(self, content):
        with open(self.env_path, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(content)

    def test_missing_file_returns_empty_dict(self):
        self.assertEqual(env_file.load_env_file(os.path.join(self.tmp_dir, "nope.env")), {})

    def test_skips_blank_lines_and_comments(self):
        self._write("\n# a comment\nFOO=bar\n\n# another\n")
        self.assertEqual(env_file.load_env_file(self.env_path), {"FOO": "bar"})

    def test_strips_matching_single_or_double_quotes(self):
        self._write('FOO="bar"\nBAZ=\'qux\'\n')
        self.assertEqual(env_file.load_env_file(self.env_path), {"FOO": "bar", "BAZ": "qux"})

    def test_mismatched_quotes_are_left_intact(self):
        self._write('FOO="bar\'\n')
        self.assertEqual(env_file.load_env_file(self.env_path), {"FOO": '"bar\''})

    def test_lines_without_equals_are_ignored(self):
        self._write("FOO=bar\nthis line has no equals sign\nBAZ=qux\n")
        self.assertEqual(env_file.load_env_file(self.env_path), {"FOO": "bar", "BAZ": "qux"})

    def test_export_prefix_is_tolerated(self):
        self._write("export FOO=bar\n")
        self.assertEqual(env_file.load_env_file(self.env_path), {"FOO": "bar"})


class ApplyEnvFileTests(unittest.TestCase):
    def setUp(self):
        self.tmp_dir = tempfile.mkdtemp(prefix="evals-env-file-apply-test-")
        self.env_path = os.path.join(self.tmp_dir, ".env")
        self._preexisting_keys = set(os.environ.keys())

    def tearDown(self):
        for key in set(os.environ.keys()) - self._preexisting_keys:
            del os.environ[key]
        shutil.rmtree(self.tmp_dir, ignore_errors=True)

    def _write(self, content):
        with open(self.env_path, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(content)

    def test_missing_file_is_silent_no_op(self):
        applied_keys = env_file.apply_env_file(os.path.join(self.tmp_dir, "nope.env"))
        self.assertEqual(applied_keys, [])

    def test_sets_keys_not_already_present(self):
        self._write("EVALS_ENV_FILE_TEST_NEW_KEY=from-file\n")
        applied_keys = env_file.apply_env_file(self.env_path)
        self.assertEqual(applied_keys, ["EVALS_ENV_FILE_TEST_NEW_KEY"])
        self.assertEqual(os.environ["EVALS_ENV_FILE_TEST_NEW_KEY"], "from-file")

    def test_real_environment_always_wins_over_env_file(self):
        os.environ["EVALS_ENV_FILE_TEST_EXISTING_KEY"] = "from-machine"
        self._write("EVALS_ENV_FILE_TEST_EXISTING_KEY=from-file\n")
        applied_keys = env_file.apply_env_file(self.env_path)
        self.assertEqual(applied_keys, [])
        self.assertEqual(os.environ["EVALS_ENV_FILE_TEST_EXISTING_KEY"], "from-machine")


class RunStartupAppliesEnvFileTests(unittest.TestCase):
    FIXTURE_TASK_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "sample-task")

    def setUp(self):
        self.tmp_root = tempfile.mkdtemp(prefix="evals-run-env-file-test-")
        self.tasks_dir = os.path.join(self.tmp_root, "tasks")
        os.makedirs(self.tasks_dir)
        shutil.copytree(self.FIXTURE_TASK_DIR, os.path.join(self.tasks_dir, "sample-task"))

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
        with open(os.path.join(self.tmp_root, ".env"), "w", encoding="utf-8", newline="\n") as handle:
            handle.write("EVALS_RUN_STARTUP_ENV_FILE_TEST_KEY=applied-at-startup\n")

        self._preexisting_keys = set(os.environ.keys())

    def tearDown(self):
        for key in set(os.environ.keys()) - self._preexisting_keys:
            del os.environ[key]
        shutil.rmtree(self.tmp_root, ignore_errors=True)

    def test_dry_run_applies_env_file_from_evals_root_not_cwd(self):
        other_cwd = tempfile.mkdtemp(prefix="evals-run-env-file-other-cwd-")
        original_cwd = os.getcwd()
        os.chdir(other_cwd)
        try:
            buffer = io.StringIO()
            with redirect_stdout(buffer):
                exit_code = run_module.main([
                    "--dry-run",
                    "--tasks-dir", self.tasks_dir,
                    "--config", self.config_path,
                    "--results-dir", self.results_dir,
                ])
        finally:
            os.chdir(original_cwd)
            shutil.rmtree(other_cwd, ignore_errors=True)

        self.assertEqual(exit_code, 0)
        self.assertEqual(os.environ.get("EVALS_RUN_STARTUP_ENV_FILE_TEST_KEY"), "applied-at-startup")


if __name__ == "__main__":
    unittest.main()
