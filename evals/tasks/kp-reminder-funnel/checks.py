"""Programmatic checks for kp-reminder-funnel.

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
  "window": {"start": "<iso8601>", "end": "<iso8601>"},
  "users_created_reminder": <int>,
  "users_confirmed_after": <int>,
  "conversion_rate": <number>,
  "hogql": "<the query text the agent ran>"
}

Numeric tolerance (see reference.md): user counts within 2 absolute; conversion rate
within 0.03 (3 percentage points) absolute.
"""

import json
import os
import re
import urllib.error
import urllib.request

REQUIRED_KEYS = {
    "window", "users_created_reminder", "users_confirmed_after",
    "conversion_rate", "hogql",
}
WRITE_KEYWORDS_RE = re.compile(
    r"\b(INSERT|UPDATE|DELETE|DROP|ALTER|CREATE|TRUNCATE)\b", re.IGNORECASE
)

REFERENCE_HOGQL = """
SELECT
    countIf(has_created) AS users_created_reminder,
    countIf(has_created AND has_confirmed_after) AS users_confirmed_after
FROM (
    SELECT
        person_id,
        minIf(timestamp, event = 'reminder_created') AS first_created,
        minIf(timestamp, event = 'habit_confirmed') AS first_confirmed,
        first_created != toDateTime(0) AS has_created,
        (first_confirmed != toDateTime(0) AND first_confirmed >= first_created) AS has_confirmed_after
    FROM events
    WHERE timestamp >= toDateTime('2026-07-12 00:00:00')
      AND timestamp < toDateTime('2026-07-26 00:00:00')
      AND event IN ('reminder_created', 'habit_confirmed')
    GROUP BY person_id
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
    for key in ("users_created_reminder", "users_confirmed_after"):
        if not isinstance(answer.get(key), int) or isinstance(answer.get(key), bool):
            return False
    if not isinstance(answer.get("conversion_rate"), (int, float)) or isinstance(answer.get("conversion_rate"), bool):
        return False
    window = answer.get("window")
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
    ref_created, ref_confirmed_after = reference_rows[0]
    ref_conversion_rate = (ref_confirmed_after / ref_created) if ref_created else 0.0

    mismatches = []
    if not _within_tolerance(answer["users_created_reminder"], ref_created):
        mismatches.append(f"users_created_reminder {answer['users_created_reminder']} vs reference {ref_created}")
    if not _within_tolerance(answer["users_confirmed_after"], ref_confirmed_after):
        mismatches.append(f"users_confirmed_after {answer['users_confirmed_after']} vs reference {ref_confirmed_after}")
    if abs(answer["conversion_rate"] - ref_conversion_rate) > 0.03:
        mismatches.append(f"conversion_rate {answer['conversion_rate']} vs reference {ref_conversion_rate:.4f}")
    if mismatches:
        return _fail("wrong-answer", "reported numbers outside tolerance of the reference query: " + "; ".join(mismatches))

    agent_values = _flatten_numeric(agent_body.get("results"))
    reported_values = [answer["users_created_reminder"], answer["users_confirmed_after"]]
    if not any(_within_tolerance(reported, agent_value, rel=0.05, abs_min=1) for reported in reported_values for agent_value in agent_values):
        return _fail(
            "wrong-answer",
            "the agent's own HogQL executed but returned no value matching any reported count; "
            "the reported answer.json numbers do not appear to come from the supplied query",
        )

    return _pass("answer.json numbers match the reference query within tolerance, and the agent's own HogQL corroborates them")
