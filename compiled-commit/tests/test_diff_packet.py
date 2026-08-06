import unittest

from src.git_ops import GitOps
from src.validators import build_diff_packet
from tests.helpers import cleanup, commit_file, make_repo, write_file


class DiffPacketTests(unittest.TestCase):
    def test_per_file_line_truncation(self):
        repo = make_repo()
        try:
            original = "\n".join(f"line {i}" for i in range(600)) + "\n"
            commit_file(repo, "big.txt", original, "init")
            modified = "\n".join(f"line {i} changed" for i in range(600)) + "\n"
            write_file(repo, "big.txt", modified)

            git = GitOps(repo)
            packet = build_diff_packet(git, [], "\n".join(git.status_short()), "main", max_file_lines=400)

            self.assertIn("[truncated", packet.text)
        finally:
            cleanup(repo)

    def test_total_char_budget_drops_largest_sections(self):
        repo = make_repo()
        try:
            commit_file(repo, "a.txt", "seed\n", "init")
            write_file(repo, "a.txt", "seed\n" + ("x" * 50000) + "\n")
            write_file(repo, "b.txt", "seed\n" + ("y" * 50000) + "\n")
            commit_file(repo, "a.txt", "seed\n" + ("x" * 50000) + "\n", "grow a")
            write_file(repo, "a.txt", "seed\n" + ("x" * 60000) + "\n")

            git = GitOps(repo)
            packet = build_diff_packet(
                git, ["b.txt"], "\n".join(git.status_short()), "main", max_total_chars=60000
            )

            self.assertLessEqual(len(packet.text), 60000 + 2000)  # header/footer overhead allowance
            self.assertTrue(packet.dropped_files)
        finally:
            cleanup(repo)

    def test_untracked_content_included(self):
        repo = make_repo()
        try:
            commit_file(repo, "keep.txt", "keep\n", "init")
            write_file(repo, "fresh.txt", "hello from a new file\n")

            git = GitOps(repo)
            packet = build_diff_packet(git, ["fresh.txt"], "\n".join(git.status_short()), "main")

            self.assertIn("fresh.txt", packet.text)
            self.assertIn("hello from a new file", packet.text)
        finally:
            cleanup(repo)


if __name__ == "__main__":
    unittest.main()
