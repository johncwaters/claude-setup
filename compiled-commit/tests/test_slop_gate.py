import os
import unittest

from src.git_ops import GitOps
from src.validators import apply_patch_gate
from tests.helpers import cleanup, commit_file, make_repo

INVALID_PATCH = "this is not a unified diff at all\nrandom garbage\n"


class SlopGateTests(unittest.TestCase):
    def test_invalid_patch_rejected(self):
        repo = make_repo()
        try:
            commit_file(repo, "a.txt", "one\n", "init")
            git = GitOps(repo)
            temp_dir = os.path.join(repo, ".compiled-commit-tmp")

            applied, stderr = apply_patch_gate(git, INVALID_PATCH, temp_dir)

            self.assertFalse(applied)
            self.assertTrue(stderr.strip())
            with open(os.path.join(repo, "a.txt"), "r", encoding="utf-8") as handle:
                self.assertEqual(handle.read(), "one\n")
        finally:
            cleanup(repo)

    def test_valid_patch_applied_and_restaged(self):
        repo = make_repo()
        try:
            commit_file(repo, "a.txt", "one\ntwo\nthree\n", "init")
            git = GitOps(repo)
            temp_dir = os.path.join(repo, ".compiled-commit-tmp")

            patch = (
                "diff --git a/a.txt b/a.txt\n"
                "index e69de29..0000000 100644\n"
                "--- a/a.txt\n"
                "+++ b/a.txt\n"
                "@@ -1,3 +1,3 @@\n"
                " one\n"
                "-two\n"
                "+TWO\n"
                " three\n"
            )

            applied, stderr = apply_patch_gate(git, patch, temp_dir)

            self.assertTrue(applied, stderr)
            with open(os.path.join(repo, "a.txt"), "r", encoding="utf-8") as handle:
                self.assertEqual(handle.read(), "one\nTWO\nthree\n")
        finally:
            cleanup(repo)


if __name__ == "__main__":
    unittest.main()
