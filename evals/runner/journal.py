"""Append-only run journal: one JSON object per line, resumable by (task, regime, trial, model).

Cell status vocabulary: "completed" cells are skipped on resume, "infra" cells (harness-side
faults, not agent or docs failures) always rerun. The latest line for a cell wins.
"""

import json
import os
from dataclasses import asdict, dataclass
from typing import Optional


@dataclass
class JournalEntry:
    ts: str
    task: str
    regime: str
    trial: int
    status: str  # "completed" | "infra"
    passed: bool
    reason_code: str
    wall_secs: float
    turns: Optional[int]
    usage: dict
    model: str
    bundle_hash: Optional[str]
    snapshot_hashes: dict
    posthog_captured: bool
    detail: str = ""

    def to_json_line(self):
        return json.dumps(asdict(self))


def cell_key(task, regime, trial, model):
    return (task, regime, trial, model)


class Journal:
    def __init__(self, path):
        self.path = path

    def append(self, entry):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        with open(self.path, "a", encoding="utf-8") as handle:
            handle.write(entry.to_json_line() + "\n")

    def read_all(self):
        if not os.path.isfile(self.path):
            return []
        rows = []
        with open(self.path, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                rows.append(json.loads(line))
        return rows

    def latest_by_cell(self):
        latest = {}
        for row in self.read_all():
            latest[cell_key(row["task"], row["regime"], row["trial"], row["model"])] = row
        return latest

    def is_cell_completed(self, task, regime, trial, model, latest_by_cell=None):
        # a batch's resume check calls this once per cell; passing a precomputed
        # latest_by_cell (built once by the caller) keeps that O(n) instead of O(n^2)
        latest_by_cell = self.latest_by_cell() if latest_by_cell is None else latest_by_cell
        row = latest_by_cell.get(cell_key(task, regime, trial, model))
        return bool(row and row["status"] == "completed")
