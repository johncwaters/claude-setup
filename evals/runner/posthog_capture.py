"""Stdlib urllib capture to PostHog's batch endpoint.

No SDK dependency (none is installed in this environment); a plain POST to <host>/batch/
is enough for one event type. Telemetry never gates a run: an absent env key or any
network fault is a silent no-op, and the caller records posthog_captured=False.
"""

import dataclasses
import json
import os
import urllib.error
import urllib.request

DEFAULT_HOST = "https://us.i.posthog.com"


def _project_api_key(config):
    env_name = config.get("posthog", {}).get("project_api_key_env", "EVALS_POSTHOG_PROJECT_KEY")
    return os.environ.get(env_name)


def _build_event(api_key, entry):
    fields = dataclasses.asdict(entry)
    properties = {
        "task": fields["task"],
        "regime": fields["regime"],
        "trial": fields["trial"],
        "passed": fields["passed"],
        "reason_code": fields["reason_code"],
        "wall_secs": fields["wall_secs"],
        "turns": fields["turns"],
        "model": fields["model"],
        "bundle_hash": fields["bundle_hash"],
    }
    properties.update({f"usage_{key}": value for key, value in fields["usage"].items()})
    return {
        "api_key": api_key,
        "batch": [{
            "event": "eval_run_completed",
            "distinct_id": "evals-harness",
            "properties": properties,
        }],
    }


def capture_eval_run_completed(config, entry):
    """entry: the JournalEntry describing the run just scored."""
    api_key = _project_api_key(config)
    if not api_key:
        return False

    host = config.get("posthog", {}).get("host", DEFAULT_HOST)
    event = _build_event(api_key, entry)

    request = urllib.request.Request(
        f"{host}/batch/",
        data=json.dumps(event).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return 200 <= response.status < 300
    except (urllib.error.URLError, OSError, ValueError):
        return False
