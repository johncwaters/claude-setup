"""Subprocess wrapper for headless Claude Code eval runs.

Mirrors compiled-commit/src/llm.py's mechanics: prompt goes over stdin (Windows argv caps
near 32k chars), a nonzero exit is not fatal by itself since stdout can still hold a valid
response. Extended with a fixture
replay/record mode keyed by (task, regime, trial) so scored runs can be reproduced offline.

The agent subprocess runs with a scrubbed environment: PostHog credentials reach a run only
through the mcp regime's generated config file, never through inherited env vars.
"""

import json
import os
import subprocess

# run.py loads evals/.env into os.environ, so an unscrubbed subprocess hands every agent the
# PostHog keys and project ids regardless of regime. A bundle-regime agent that reads them can
# query the live API directly, which silently turns a no-credentials regime into an MCP-grade
# one and invalidates the comparison. The mcp regime gets its token from the generated MCP
# config file instead, so nothing legitimately needs these on the agent's environment.
_CREDENTIAL_ENV_PREFIX = "EVALS_POSTHOG_"


class ClaudeRunResult:
    def __init__(self, result_text, num_turns, duration_ms, total_cost_usd, usage, raw):
        self.result_text = result_text
        self.num_turns = num_turns
        self.duration_ms = duration_ms
        self.total_cost_usd = total_cost_usd
        self.usage = usage
        self.raw = raw


def _fixture_path(replay_dir, task_id, regime, trial):
    return os.path.join(replay_dir, f"{task_id}_{regime}_{trial}.json")


def _read_fixture(replay_dir, task_id, regime, trial):
    path = _fixture_path(replay_dir, task_id, regime, trial)
    if not os.path.isfile(path):
        raise FileNotFoundError(f"replay fixture not found: {path}")
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def _write_fixture(replay_dir, task_id, regime, trial, raw):
    os.makedirs(replay_dir, exist_ok=True)
    path = _fixture_path(replay_dir, task_id, regime, trial)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(raw, handle, indent=2)


def _parse_raw(raw):
    usage = raw.get("usage") or raw.get("modelUsage") or {}
    return ClaudeRunResult(
        result_text=raw.get("result", ""),
        num_turns=raw.get("num_turns"),
        duration_ms=raw.get("duration_ms"),
        total_cost_usd=raw.get("total_cost_usd", 0.0),
        usage={
            "input_tokens": usage.get("input_tokens", 0),
            "cache_creation_input_tokens": usage.get("cache_creation_input_tokens", 0),
            "cache_read_input_tokens": usage.get("cache_read_input_tokens", 0),
            "output_tokens": usage.get("output_tokens", 0),
        },
        raw=raw,
    )


def _build_cmd(model, max_turns, disallowed_tools, allowed_tools, mcp_config_path):
    # --strict-mcp-config on every run, not just the mcp regime: without it the operator's own
    # user-scoped MCP servers load into all four regimes, so a machine with a connected server
    # would hand none/llms-txt/bundle tools the regime is supposed to withhold. With no
    # --mcp-config alongside it, the run gets zero MCP servers, which is what those regimes want.
    cmd = [
        "claude", "-p", "--output-format", "json",
        "--model", model,
        "--max-turns", str(max_turns),
        "--strict-mcp-config",
        "--disallowedTools", ",".join(disallowed_tools),
    ]
    if allowed_tools:
        cmd.extend(["--allowedTools", ",".join(allowed_tools)])
    if mcp_config_path:
        cmd.extend(["--mcp-config", mcp_config_path])
    return cmd


def _scrubbed_agent_env():
    # case-folded because only Windows upper-normalizes env keys; POSIX would let a
    # lowercased duplicate slip past a case-sensitive prefix match
    return {
        name: value for name, value in os.environ.items()
        if not name.upper().startswith(_CREDENTIAL_ENV_PREFIX)
    }


def _invoke_live(cmd, cwd, prompt, timeout_secs):
    proc = subprocess.run(
        cmd, cwd=cwd, input=prompt, capture_output=True,
        text=True, encoding="utf-8", errors="replace",
        timeout=timeout_secs, shell=False, env=_scrubbed_agent_env(),
    )
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        pass
    if proc.returncode != 0:
        return {"result": "", "usage": {}, "_error": proc.stderr}
    return {"result": proc.stdout, "usage": {}}


def run(prompt, model, max_turns, cwd, disallowed_tools, task_id, regime, trial,
        replay_dir=None, record=False, timeout_secs=1800, mcp_config_path=None, allowed_tools=None):
    if replay_dir and not record:
        raw = _read_fixture(replay_dir, task_id, regime, trial)
        return _parse_raw(raw)

    cmd = _build_cmd(model, max_turns, disallowed_tools, allowed_tools, mcp_config_path)
    raw = _invoke_live(cmd, cwd, prompt, timeout_secs)
    if record and replay_dir:
        _write_fixture(replay_dir, task_id, regime, trial, raw)
    return _parse_raw(raw)
