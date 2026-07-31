import json
import os
import shutil
import tempfile
import unittest

from runner import claude_cli


class BuildCmdTests(unittest.TestCase):
    def test_allowed_tools_passed_through_when_present(self):
        cmd = claude_cli._build_cmd(
            "claude-sonnet-5", 30, ["WebSearch", "Task", "Agent"],
            ["WebFetch(domain:posthog.com)"], None,
        )
        self.assertIn("--allowedTools", cmd)
        self.assertEqual(cmd[cmd.index("--allowedTools") + 1], "WebFetch(domain:posthog.com)")
        self.assertIn("--disallowedTools", cmd)
        self.assertEqual(cmd[cmd.index("--disallowedTools") + 1], "WebSearch,Task,Agent")

    def test_allowed_tools_flag_omitted_when_empty(self):
        cmd = claude_cli._build_cmd("claude-sonnet-5", 30, ["WebFetch", "WebSearch", "Task", "Agent"], [], None)
        self.assertNotIn("--allowedTools", cmd)

    def test_mcp_config_path_passed_through_when_present(self):
        cmd = claude_cli._build_cmd("claude-sonnet-5", 30, [], [], "/tmp/.mcp.json")
        self.assertIn("--mcp-config", cmd)
        self.assertEqual(cmd[cmd.index("--mcp-config") + 1], "/tmp/.mcp.json")


class ClaudeCliReplayTests(unittest.TestCase):
    def setUp(self):
        self.replay_dir = tempfile.mkdtemp(prefix="evals-claude-cli-test-")

    def tearDown(self):
        shutil.rmtree(self.replay_dir, ignore_errors=True)

    def _write_fixture(self, task_id, regime, trial, raw):
        path = os.path.join(self.replay_dir, f"{task_id}_{regime}_{trial}.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(raw, handle)

    def test_replay_parses_real_shaped_claude_p_json(self):
        # Shape matches a real `claude -p --output-format json` response
        # (compiled-commit/bench/fixtures/*_commit_message.json), trimmed to the fields we read.
        self._write_fixture("sample-task", "none", 1, {
            "is_error": False,
            "num_turns": 3,
            "duration_ms": 4211,
            "total_cost_usd": 0.0421,
            "usage": {
                "input_tokens": 10,
                "cache_creation_input_tokens": 200,
                "cache_read_input_tokens": 500,
                "output_tokens": 30,
            },
            "result": "The answer is 4.",
        })

        result = claude_cli.run(
            prompt="what is 2+2", model="claude-sonnet-5", max_turns=30, cwd=self.replay_dir,
            disallowed_tools=["WebFetch", "WebSearch", "Task", "Agent"],
            task_id="sample-task", regime="none", trial=1, replay_dir=self.replay_dir,
        )

        self.assertEqual(result.result_text, "The answer is 4.")
        self.assertEqual(result.num_turns, 3)
        self.assertEqual(result.duration_ms, 4211)
        self.assertEqual(result.total_cost_usd, 0.0421)
        self.assertEqual(result.usage["input_tokens"], 10)
        self.assertEqual(result.usage["cache_creation_input_tokens"], 200)
        self.assertEqual(result.usage["cache_read_input_tokens"], 500)
        self.assertEqual(result.usage["output_tokens"], 30)

    def test_replay_missing_fixture_raises(self):
        with self.assertRaises(FileNotFoundError):
            claude_cli.run(
                prompt="x", model="claude-sonnet-5", max_turns=1, cwd=self.replay_dir,
                disallowed_tools=[], task_id="nope", regime="none", trial=1, replay_dir=self.replay_dir,
            )

    def test_haiku_model_is_rejected_even_in_replay_mode(self):
        with self.assertRaises(ValueError):
            claude_cli.run(
                prompt="x", model="claude-haiku-4-5-20251001", max_turns=1, cwd=self.replay_dir,
                disallowed_tools=[], task_id="t", regime="none", trial=1, replay_dir=self.replay_dir,
            )


if __name__ == "__main__":
    unittest.main()
