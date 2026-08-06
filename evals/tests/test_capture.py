import os
import shutil
import tempfile
import unittest

import yaml

from runner import capture
from tests.helpers import commit_file, make_repo


class CaptureTests(unittest.TestCase):
    def setUp(self):
        self.repo = make_repo()
        self.tmp_dir = tempfile.mkdtemp(prefix="evals-capture-test-")
        self.tasks_dir = os.path.join(self.tmp_dir, "tasks")
        os.makedirs(self.tasks_dir)
        commit_file(self.repo, "app.py", "print('hi')\n", "init")
        self.prompt_file = os.path.join(self.tmp_dir, "prompt.md")
        with open(self.prompt_file, "w", encoding="utf-8") as handle:
            handle.write("Wire up renderer capture.\n")

    def tearDown(self):
        shutil.rmtree(self.repo, ignore_errors=True)
        shutil.rmtree(self.tmp_dir, ignore_errors=True)

    def test_capture_creates_well_formed_task_dir_with_pinned_commit(self):
        task_dir = capture.capture_task(
            self.tasks_dir, "ch-renderer-capture", "install-instrumentation", "prospective",
            self.prompt_file, repo=self.repo,
        )

        self.assertTrue(os.path.isfile(os.path.join(task_dir, "task.yml")))
        self.assertTrue(os.path.isfile(os.path.join(task_dir, "prompt.md")))
        self.assertTrue(os.path.isfile(os.path.join(task_dir, "checks.py")))
        self.assertTrue(os.path.isfile(os.path.join(task_dir, "reference.md")))

        with open(os.path.join(task_dir, "task.yml"), encoding="utf-8") as handle:
            content = handle.read()
        self.assertIn("id: ch-renderer-capture", content)
        self.assertIn("class: install-instrumentation", content)
        self.assertIn("mode: prospective", content)
        self.assertNotIn("pinned_commit: null", content)

        with open(os.path.join(task_dir, "checks.py"), encoding="utf-8") as handle:
            checks_content = handle.read()
        self.assertIn("NotImplementedError", checks_content)
        self.assertIn("check-infra", checks_content)

    def test_capture_analysis_only_task_has_null_repo_and_pinned_commit(self):
        task_dir = capture.capture_task(
            self.tasks_dir, "kp-release-impact", "hogql-analysis", "retrospective", self.prompt_file
        )
        with open(os.path.join(task_dir, "task.yml"), encoding="utf-8") as handle:
            content = handle.read()
        self.assertIn("repo: null", content)
        self.assertIn("pinned_commit: null", content)

    def test_capture_refuses_to_overwrite_existing_task(self):
        capture.capture_task(self.tasks_dir, "dup-task", "hogql-analysis", "retrospective", self.prompt_file)
        with self.assertRaises(FileExistsError):
            capture.capture_task(self.tasks_dir, "dup-task", "hogql-analysis", "retrospective", self.prompt_file)

    def test_capture_rejects_unknown_class_or_mode(self):
        with self.assertRaises(ValueError):
            capture.capture_task(self.tasks_dir, "bad-class", "not-a-class", "retrospective", self.prompt_file)
        with self.assertRaises(ValueError):
            capture.capture_task(self.tasks_dir, "bad-mode", "hogql-analysis", "not-a-mode", self.prompt_file)

    def test_capture_rejects_ids_with_uppercase_or_invalid_leading_characters(self):
        for bad_id in ("Bad-Id", "-leading-dash", "has_underscore", "has space", ""):
            with self.assertRaises(ValueError):
                capture.capture_task(self.tasks_dir, bad_id, "hogql-analysis", "retrospective", self.prompt_file)

    def test_capture_accepts_lowercase_alphanumeric_dash_ids(self):
        task_dir = capture.capture_task(
            self.tasks_dir, "kp-release-impact-2", "hogql-analysis", "retrospective", self.prompt_file
        )
        self.assertTrue(os.path.isdir(task_dir))

    def test_capture_safely_quotes_repo_paths_with_special_characters_in_task_yml(self):
        # _task_yml_text only formats strings, it never touches disk, so this can use a
        # path shape (drive-letter colon, brackets, comma) that would be a YAML plain-scalar
        # hazard if hand-formatted, without needing the directory to actually exist.
        tricky_repo = r"C:\Users\dev\repos\card-harbor: fork, [staging]"

        text = capture._task_yml_text("tricky-task", "hogql-analysis", "retrospective", tricky_repo, None)
        loaded = yaml.safe_load(text)

        self.assertEqual(loaded["repo"], tricky_repo)
        self.assertEqual(loaded["id"], "tricky-task")

    def test_home_relative_repo_collapses_home_prefix(self):
        repo_under_home = os.path.join(os.path.expanduser("~"), "Projects", "sample-repo")
        self.assertEqual(capture._home_relative_repo(repo_under_home), "~/Projects/sample-repo")

    def test_home_relative_repo_leaves_paths_outside_home_untouched(self):
        outside_home = os.path.join("D:" + os.sep, "builds", "sample-repo")
        self.assertEqual(capture._home_relative_repo(outside_home), outside_home)
        self.assertIsNone(capture._home_relative_repo(None))


if __name__ == "__main__":
    unittest.main()
