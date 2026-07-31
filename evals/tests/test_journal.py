import json
import os
import shutil
import tempfile
import unittest

from runner.journal import Journal, JournalEntry


def _make_entry(task, regime, trial, status, passed=True, reason_code="pass", detail=""):
    return JournalEntry(
        ts="2026-07-30T00:00:00+00:00", task=task, regime=regime, trial=trial,
        status=status, passed=passed, reason_code=reason_code, wall_secs=1.0,
        turns=1, usage={"gross": 100, "noncached": 100, "output": 10, "cache_read": 0, "cost_usd": 0.01},
        model="claude-sonnet-5", bundle_hash=None, snapshot_hashes={}, posthog_captured=False,
        detail=detail,
    )


class JournalTests(unittest.TestCase):
    def setUp(self):
        self.tmp_dir = tempfile.mkdtemp(prefix="evals-journal-test-")
        self.journal_path = os.path.join(self.tmp_dir, "journal.jsonl")

    def tearDown(self):
        shutil.rmtree(self.tmp_dir, ignore_errors=True)

    def test_append_writes_one_json_line_per_entry(self):
        journal = Journal(self.journal_path)
        journal.append(_make_entry("t1", "none", 1, "completed"))
        journal.append(_make_entry("t1", "none", 2, "completed"))
        with open(self.journal_path, encoding="utf-8") as handle:
            lines = handle.readlines()
        self.assertEqual(len(lines), 2)
        self.assertEqual(json.loads(lines[0])["trial"], 1)
        self.assertEqual(json.loads(lines[1])["trial"], 2)

    def test_completed_cell_is_skipped_on_resume(self):
        journal = Journal(self.journal_path)
        journal.append(_make_entry("t1", "none", 1, "completed"))
        self.assertTrue(journal.is_cell_completed("t1", "none", 1))
        self.assertFalse(journal.is_cell_completed("t1", "none", 2))

    def test_infra_cell_is_not_marked_completed_so_it_reruns(self):
        journal = Journal(self.journal_path)
        journal.append(_make_entry("t1", "bundle", 1, "infra", passed=False, reason_code="check-infra"))
        self.assertFalse(journal.is_cell_completed("t1", "bundle", 1))

    def test_latest_line_for_a_cell_wins_on_resume(self):
        journal = Journal(self.journal_path)
        journal.append(_make_entry("t1", "none", 1, "infra", passed=False, reason_code="check-infra"))
        journal.append(_make_entry("t1", "none", 1, "completed"))
        self.assertTrue(journal.is_cell_completed("t1", "none", 1))

    def test_read_all_on_missing_file_returns_empty_list(self):
        journal = Journal(os.path.join(self.tmp_dir, "does-not-exist.jsonl"))
        self.assertEqual(journal.read_all(), [])

    def test_detail_defaults_to_empty_string(self):
        journal = Journal(self.journal_path)
        journal.append(_make_entry("t1", "none", 1, "completed"))
        row = journal.read_all()[0]
        self.assertEqual(row["detail"], "")

    def test_detail_round_trips_through_journal(self):
        journal = Journal(self.journal_path)
        journal.append(_make_entry(
            "t1", "bundle", 1, "infra", passed=False, reason_code="check-infra",
            detail="checks.py timed out after 600s",
        ))
        row = journal.read_all()[0]
        self.assertEqual(row["detail"], "checks.py timed out after 600s")


if __name__ == "__main__":
    unittest.main()
