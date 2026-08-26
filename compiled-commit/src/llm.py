"""Bounded LLM adapter: live via `claude -p`, replay via recorded fixtures.

Every call is retried a bounded number of times, feeding the prior error back into the
next prompt attempt (schema-shape errors, JSON-parse errors, and any caller-supplied
domain validation all share this one retry loop).
"""

import json
import os
import re
import subprocess
import time

from src.failures import LlmUsage
from src.schemas import validate_schema

DEFAULT_MODEL = "claude-sonnet-5"

PREAMBLE = "Respond with a single JSON object matching this schema. No prose, no markdown, no tool use."

_FENCE_RE = re.compile(r"^```[a-zA-Z]*\n|```$", re.MULTILINE)


def _strip_fences(text):
    return _FENCE_RE.sub("", text).strip()


def _extract_balanced_json(text):
    start = text.find("{")
    if start == -1:
        return None
    depth = 0
    in_string = False
    escape = False
    for i in range(start, len(text)):
        ch = text[i]
        if in_string:
            if escape:
                escape = False
                continue
            if ch == "\\":
                escape = True
                continue
            if ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
            continue
        if ch == "{":
            depth += 1
            continue
        if ch == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    return None


def _build_prompt(schema, body, errors):
    parts = [PREAMBLE, "", "Schema:", json.dumps(schema, indent=2), ""]
    if errors:
        parts.append("The previous attempt was rejected for these reasons; fix them:")
        parts.extend(f"- {e}" for e in errors)
        parts.append("")
    parts.append(body)
    return "\n".join(parts)


class LlmClient:
    def __init__(self, mode, model=DEFAULT_MODEL, fixtures_dir=None, record=False, cwd=None):
        if mode not in ("live", "replay"):
            raise ValueError(f"unknown llm mode: {mode!r}")
        if mode == "replay" and not fixtures_dir:
            raise ValueError("replay mode requires fixtures_dir")

        self.mode = mode
        self.model = model
        self.fixtures_dir = fixtures_dir
        self.record = record
        self.cwd = cwd

    def call(self, name, key, prompt_body, schema, max_retries=2, extra_validate=None):
        attempt = 0
        errors = []
        usage_list = []

        while attempt <= max_retries:
            prompt = _build_prompt(schema, prompt_body, errors)
            start = time.monotonic()
            raw = self._dispatch(key, prompt)
            duration_ms = (time.monotonic() - start) * 1000
            usage_list.append(self._extract_usage(raw, name, duration_ms, attempt))

            parsed, parse_errors = self._parse_response(raw)
            if parse_errors:
                errors = parse_errors
                attempt += 1
                continue

            schema_errors = validate_schema(parsed, schema)
            if schema_errors:
                errors = schema_errors
                attempt += 1
                continue

            extra_errors = extra_validate(parsed) if extra_validate else []
            if extra_errors:
                errors = extra_errors
                attempt += 1
                continue

            return parsed, usage_list, []

        return None, usage_list, errors

    def _dispatch(self, key, prompt):
        if self.mode == "replay":
            return self._read_fixture(key)
        raw = self._live_call(prompt)
        if self.record:
            self._write_fixture(key, raw)
        return raw

    def _live_call(self, prompt):
        # prompt goes over stdin: Windows argv caps near 32k chars and diff
        # packets can reach 60k. Nonzero exit alone is not fatal: session-end
        # hooks in nested claude sessions fail while stdout still holds a
        # valid response, so stdout parse is the source of truth.
        cmd = [
            "claude",
            "-p",
            "--output-format",
            "json",
            "--model",
            self.model,
            "--max-turns",
            "1",
            # No MCP: a repo .mcp.json invites a tool round-trip whose continuation is cache-cold (189k cacheW, cacheR 0 measured)
            "--strict-mcp-config",
            "--disallowedTools",
            "Bash,PowerShell,Read,Grep,Glob,Edit,Write,WebFetch,WebSearch,"
            "Task,Agent,TodoWrite,NotebookEdit,Skill,ToolSearch",
        ]
        proc = subprocess.run(cmd, cwd=self.cwd, input=prompt, capture_output=True,
                              text=True, encoding="utf-8", errors="replace",
                              timeout=300, shell=False)
        try:
            return json.loads(proc.stdout)
        except json.JSONDecodeError:
            if proc.returncode != 0:
                return {"result": "", "usage": {}, "_error": proc.stderr}
            return {"result": proc.stdout, "usage": {}}

    def _read_fixture(self, key):
        path = os.path.join(self.fixtures_dir, f"{key}.json")
        if not os.path.isfile(path):
            raise FileNotFoundError(f"replay fixture not found: {path}")
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)

    def _write_fixture(self, key, raw):
        os.makedirs(self.fixtures_dir, exist_ok=True)
        path = os.path.join(self.fixtures_dir, f"{key}.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(raw, handle, indent=2)

    def _extract_usage(self, raw, name, duration_ms, attempt):
        usage = raw.get("usage") or raw.get("modelUsage") or {}
        return LlmUsage(
            name=name,
            model=self.model,
            input_tokens=usage.get("input_tokens", 0),
            cache_creation_input_tokens=usage.get("cache_creation_input_tokens", 0),
            cache_read_input_tokens=usage.get("cache_read_input_tokens", 0),
            output_tokens=usage.get("output_tokens", 0),
            duration_ms=duration_ms,
            retries=attempt,
        )

    def _parse_response(self, raw):
        text = raw.get("result", "")
        json_str = _extract_balanced_json(_strip_fences(text))
        if json_str is None:
            return None, ["no JSON object found in response"]
        try:
            return json.loads(json_str), []
        except json.JSONDecodeError as exc:
            return None, [f"JSON decode error: {exc}"]
