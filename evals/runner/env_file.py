"""Load PostHog credentials from evals/.env so the harness doesn't require machine env
vars. Real environment variables always win: apply_env_file never overwrites a key that
is already set.
"""

import os


def load_env_file(path):
    if not os.path.isfile(path):
        return {}

    entries = {}
    with open(path, "r", encoding="utf-8") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[len("export "):].strip()
            if "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            if not key:
                continue
            entries[key] = _strip_quotes(value.strip())
    return entries


def _strip_quotes(value):
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
        return value[1:-1]
    return value


def apply_env_file(path):
    applied_keys = []
    for key, value in load_env_file(path).items():
        if key in os.environ:
            continue
        os.environ[key] = value
        applied_keys.append(key)
    return applied_keys
