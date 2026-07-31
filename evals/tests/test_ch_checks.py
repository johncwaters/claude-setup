"""Untracked-file blindness fix for the ch- checks modules' `_changed_files` helper.

Only `_changed_files` is exercised here: the rest of each ch- checks.py (typecheck,
node_modules linking, the renderer-SDK/wrong-api regex scans over real card-harbor
source) needs an actual card-harbor checkout and cannot be unit-tested from this repo.
"""

import importlib.util
import os
import unittest

from tests.helpers import cleanup, commit_file, make_repo

TASKS_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tasks")
CH_TASK_IDS = ("ch-main-process-capture", "ch-flag-gated-rollout", "ch-release-tagging")


def _load_checks_module(task_id):
    path = os.path.join(TASKS_DIR, task_id, "checks.py")
    spec = importlib.util.spec_from_file_location(f"{task_id.replace('-', '_')}_checks", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ChangedFilesIntentToAddTests(unittest.TestCase):
    def setUp(self):
        self.repo = make_repo()
        self.pinned_commit = commit_file(self.repo, "src/main/index.ts", "export {};\n", "init")

    def tearDown(self):
        cleanup(self.repo)

    def test_untracked_new_file_is_detected_via_intent_to_add(self):
        new_file_path = os.path.join(self.repo, "src", "main", "crashHandlers.ts")
        with open(new_file_path, "w", encoding="utf-8") as handle:
            handle.write("export function broadcastMainProcessError() {}\n")

        for task_id in CH_TASK_IDS:
            checks = _load_checks_module(task_id)
            changed = checks._changed_files(self.repo, self.pinned_commit)
            self.assertIsNotNone(changed, f"{task_id}: git diff unexpectedly failed")
            self.assertIn("src/main/crashHandlers.ts", changed, f"{task_id} missed the untracked new file")

    def test_modified_tracked_file_is_still_detected(self):
        with open(os.path.join(self.repo, "src", "main", "index.ts"), "w", encoding="utf-8") as handle:
            handle.write("export const x = 1;\n")

        for task_id in CH_TASK_IDS:
            checks = _load_checks_module(task_id)
            changed = checks._changed_files(self.repo, self.pinned_commit)
            self.assertIn("src/main/index.ts", changed, f"{task_id} missed the modified tracked file")


if __name__ == "__main__":
    unittest.main()
