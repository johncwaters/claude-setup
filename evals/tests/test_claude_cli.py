import json
import os
import shutil
import tempfile
import unittest
from unittest import mock

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

    def test_strict_mcp_config_is_set_on_every_run_so_ambient_servers_never_load(self):
        with_mcp = claude_cli._build_cmd("claude-sonnet-5", 30, [], [], "/tmp/.mcp.json")
        without_mcp = claude_cli._build_cmd("claude-sonnet-5", 30, ["WebFetch"], [], None)
        self.assertIn("--strict-mcp-config", with_mcp)
        self.assertIn("--strict-mcp-config", without_mcp)

    def test_strict_mcp_config_precedes_the_variadic_mcp_config_flag(self):
        cmd = claude_cli._build_cmd("claude-sonnet-5", 30, [], [], "/tmp/.mcp.json")
        self.assertLess(cmd.index("--strict-mcp-config"), cmd.index("--mcp-config"))


class AgentSubprocessEnvironmentTests(unittest.TestCase):
    """run.py loads evals/.env into os.environ; the agent must never inherit those keys."""

    def setUp(self):
        self.saved_environ = dict(os.environ)

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.saved_environ)

    def _env_handed_to_subprocess(self):
        class FakeCompletedProcess:
            returncode = 0
            stdout = json.dumps({"result": "ok", "usage": {}})
            stderr = ""

        captured = {}

        def fake_run(cmd, **kwargs):
            captured["env"] = kwargs.get("env")
            return FakeCompletedProcess()

        with mock.patch.object(claude_cli.subprocess, "run", fake_run):
            claude_cli.run(
                prompt="x", model="claude-sonnet-5", max_turns=1, cwd=os.getcwd(),
                disallowed_tools=[], task_id="t", regime="none", trial=1,
            )
        self.assertIsNotNone(captured["env"], "claude_cli must pass an explicit env, not inherit")
        return captured["env"]

    def test_no_evals_posthog_variable_reaches_the_agent(self):
        os.environ["EVALS_POSTHOG_PERSONAL_KEY"] = "phx-secret"
        os.environ["EVALS_POSTHOG_PROJECT_KEY"] = "phc-secret"
        os.environ["EVALS_POSTHOG_SCRATCH_PROJECT_ID"] = "1"
        os.environ["EVALS_POSTHOG_KEEPLINGS_PROJECT_ID"] = "2"

        agent_env = self._env_handed_to_subprocess()

        leaked = [name for name in agent_env if name.startswith("EVALS_POSTHOG_")]
        self.assertEqual(leaked, [])
        self.assertNotIn("phx-secret", agent_env.values())

    def test_future_evals_posthog_variables_are_dropped_by_prefix(self):
        os.environ["EVALS_POSTHOG_SOME_FUTURE_CREDENTIAL"] = "not-yet-invented"

        agent_env = self._env_handed_to_subprocess()

        self.assertNotIn("EVALS_POSTHOG_SOME_FUTURE_CREDENTIAL", agent_env)

    def test_unrelated_variables_still_reach_the_agent(self):
        os.environ["EVALS_UNRELATED_SETTING"] = "keep-me"

        agent_env = self._env_handed_to_subprocess()

        self.assertEqual(agent_env.get("EVALS_UNRELATED_SETTING"), "keep-me")


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
        # (the compiled-commit fixture-replay format), trimmed to the fields we read.
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
