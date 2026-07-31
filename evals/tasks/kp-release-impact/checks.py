"""Programmatic checks for kp-release-impact.

The agent's deliverable is `answer.json` in the workspace root (schema below). This
validates that schema, then (when credentials are configured) executes a reference
HogQL query this task's author wrote independently and compares it against the agent's
reported numbers, plus a loose sanity check that the agent's own HogQL actually executes
and produces numbers in the same neighborhood as what they reported.

run_checks(workspace, task, config) -> dict with keys:
  passed: bool
  reason_code: one of "pass", "wrong-answer", "build-fail", "wrong-api", "missing-events", "check-infra"
  detail: str, human-readable explanation

Expected answer.json schema:
{
  "before_window": {"start": "<iso8601>", "end": "<iso8601>"},
  "after_window": {"start": "<iso8601>", "end": "<iso8601>"},
  "before_event_count": <int>,
  "after_event_count": <int>,
  "before_dau_avg": <number>,
  "after_dau_avg": <number>,
  "hogql": "<the query text the agent ran>"
}

Numeric tolerance (see reference.md): counts within 5% relative or 2 absolute, whichever
is larger; dau averages within 5% relative or 0.5 absolute, whichever is larger.
"""

import json
import os
import re
import urllib.error
import urllib.request

REQUIRED_KEYS = {
    "before_window", "after_window", "before_event_count", "after_event_count",
    "before_dau_avg", "after_dau_avg", "hogql",
}
WRITE_KEYWORDS_RE = re.compile(
    r"\b(INSERT|UPDATE|DELETE|DROP|ALTER|CREATE|TRUNCATE)\b", re.IGNORECASE
)

REFERENCE_HOGQL = """
SELECT
    sumIf(event_count, day_start < toDateTime('2026-07-12 00:00:00')) AS before_event_count,
    sumIf(event_count, day_start >= toDateTime('2026-07-12 00:00:00')) AS after_event_count,
    sumIf(daily_users, day_start < toDateTime('2026-07-12 00:00:00')) / 7 AS before_dau_avg,
    sumIf(daily_users, day_start >= toDateTime('2026-07-12 00:00:00')) / 7 AS after_dau_avg
FROM (
    SELECT
        toStartOfDay(timestamp) AS day_start,
        count() AS event_count,
        uniq(person_id) AS daily_users
    FROM events
    WHERE timestamp >= toDateTime('2026-07-05 00:00:00')
      AND timestamp < toDateTime('2026-07-19 00:00:00')
    GROUP BY day_start
)
"""


def _fail(reason_code, detail):
    return {"passed": False, "reason_code": reason_code, "detail": detail}


def _pass(detail):
    return {"passed": True, "reason_code": "pass", "detail": detail}


def _infra(detail):
    return {"passed": False, "reason_code": "check-infra", "detail": detail}


def _load_answer(workspace):
    path = os.path.join(workspace, "answer.json")
    if not os.path.isfile(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (json.JSONDecodeError, OSError):
        return None


def _schema_ok(answer):
    if not isinstance(answer, dict):
        return False
    if not REQUIRED_KEYS.issubset(answer.keys()):
        return False
    if not isinstance(answer.get("hogql"), str) or not answer["hogql"].strip():
        return False
    for key in ("before_event_count", "after_event_count"):
        if not isinstance(answer.get(key), int) or isinstance(answer.get(key), bool):
            return False
    for key in ("before_dau_avg", "after_dau_avg"):
        if not isinstance(answer.get(key), (int, float)) or isinstance(answer.get(key), bool):
            return False
    for window_key in ("before_window", "after_window"):
        window = answer.get(window_key)
        if not isinstance(window, dict) or "start" not in window or "end" not in window:
            return False
    return True


def _within_tolerance(value, reference, rel=0.05, abs_min=2):
    if reference is None or value is None:
        return False
    tolerance = max(abs(reference) * rel, abs_min)
    return abs(value - reference) <= tolerance


def _read_env_creds(config):
    posthog_config = config.get("posthog", {})
    personal_key = os.environ.get(posthog_config.get("personal_api_key_env", "EVALS_POSTHOG_PERSONAL_KEY"))
    keeplings_project_id_env = posthog_config.get("keeplings_project_id_env", "EVALS_POSTHOG_KEEPLINGS_PROJECT_ID")
    keeplings_project_id = os.environ.get(keeplings_project_id_env)
    host = posthog_config.get("host", "https://us.i.posthog.com")
    if not personal_key or not keeplings_project_id:
        return None
    return {"personal_key": personal_key, "project_id": keeplings_project_id, "host": host}


def _run_hogql(creds, hogql_text, timeout=60):
    request = urllib.request.Request(
        f"{creds['host']}/api/projects/{creds['project_id']}/query/",
        data=json.dumps({"query": {"kind": "HogQLQuery", "query": hogql_text}}).encode("utf-8"),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {creds['personal_key']}"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read())


def _flatten_numeric(rows):
    values = []
    for row in rows or []:
        for cell in row if isinstance(row, (list, tuple)) else [row]:
            if isinstance(cell, (int, float)) and not isinstance(cell, bool):
                values.append(float(cell))
    return values


def run_checks(workspace, task, config):
    creds = _read_env_creds(config)
    if creds is None:
        return _infra("PostHog credentials (EVALS_POSTHOG_PERSONAL_KEY / EVALS_POSTHOG_KEEPLINGS_PROJECT_ID) not configured")

    answer = _load_answer(workspace)
    if answer is None or not _schema_ok(answer):
        return _fail("wrong-answer", "answer.json is missing, not valid JSON, or does not match the required schema")

    if WRITE_KEYWORDS_RE.search(answer["hogql"]):
        return _fail("wrong-answer", "reported HogQL is not read-only (contains a write/DDL keyword)")

    try:
        reference_body = _run_hogql(creds, REFERENCE_HOGQL)
        agent_body = _run_hogql(creds, answer["hogql"])
    except (urllib.error.URLError, TimeoutError, ValueError, OSError) as exc:
        return _infra(f"query API call failed: {exc!r}")

    reference_rows = reference_body.get("results") or []
    if not reference_rows:
        return _infra("reference HogQL returned no rows; cannot verify")
    ref_before_count, ref_after_count, ref_before_dau, ref_after_dau = reference_rows[0]

    mismatches = []
    if not _within_tolerance(answer["before_event_count"], ref_before_count):
        mismatches.append(f"before_event_count {answer['before_event_count']} vs reference {ref_before_count}")
    if not _within_tolerance(answer["after_event_count"], ref_after_count):
        mismatches.append(f"after_event_count {answer['after_event_count']} vs reference {ref_after_count}")
    if not _within_tolerance(answer["before_dau_avg"], ref_before_dau, rel=0.05, abs_min=0.5):
        mismatches.append(f"before_dau_avg {answer['before_dau_avg']} vs reference {ref_before_dau}")
    if not _within_tolerance(answer["after_dau_avg"], ref_after_dau, rel=0.05, abs_min=0.5):
        mismatches.append(f"after_dau_avg {answer['after_dau_avg']} vs reference {ref_after_dau}")
    if mismatches:
        return _fail("wrong-answer", "reported numbers outside tolerance of the reference query: " + "; ".join(mismatches))

    agent_values = _flatten_numeric(agent_body.get("results"))
    reported_values = [answer["before_event_count"], answer["after_event_count"], answer["before_dau_avg"], answer["after_dau_avg"]]
    if not any(_within_tolerance(reported, agent_value, rel=0.05, abs_min=1) for reported in reported_values for agent_value in agent_values):
        return _fail(
            "wrong-answer",
            "the agent's own HogQL executed but returned no value matching any reported number; "
            "the reported answer.json numbers do not appear to come from the supplied query",
        )

    return _pass("answer.json numbers match the reference query within tolerance, and the agent's own HogQL corroborates them")
