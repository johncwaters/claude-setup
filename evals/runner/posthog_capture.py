"""Stdlib urllib capture to PostHog's batch endpoint.

No SDK dependency (none is installed in this environment); a plain POST to <host>/batch/
is enough for one event type. Telemetry never gates a run: an absent env key or any
network fault is a silent no-op, and the caller records posthog_captured=False.
"""

import json
import os
import urllib.error
import urllib.request

DEFAULT_HOST = "https://us.i.posthog.com"


def _project_api_key(config):
    env_name = config.get("posthog", {}).get("project_api_key_env", "EVALS_POSTHOG_PROJECT_KEY")
    return os.environ.get(env_name)


def _build_event(api_key, task, regime, trial, passed, reason_code, wall_secs, turns, usage, model, bundle_hash):
    properties = {
        "task": task,
        "regime": regime,
        "trial": trial,
        "passed": passed,
        "reason_code": reason_code,
        "wall_secs": wall_secs,
        "turns": turns,
        "model": model,
        "bundle_hash": bundle_hash,
    }
    properties.update({f"usage_{key}": value for key, value in usage.items()})
    return {
        "api_key": api_key,
        "batch": [{
            "event": "eval_run_completed",
            "distinct_id": "evals-harness",
            "properties": properties,
        }],
    }


def capture_eval_run_completed(config, task, regime, trial, passed, reason_code, wall_secs,
                                turns, usage, model, bundle_hash):
    api_key = _project_api_key(config)
    if not api_key:
        return False

    host = config.get("posthog", {}).get("host", DEFAULT_HOST)
    event = _build_event(api_key, task, regime, trial, passed, reason_code, wall_secs, turns, usage, model, bundle_hash)

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
