"""JSON schema dicts for the three bounded LLM calls, plus a small stdlib validator.

This is a deliberately narrow subset of JSON Schema (type, enum, properties, required,
items) sufficient for the compiled-commit response shapes. No third-party dependency.
"""


def _type_matches(value, type_name):
    if type_name == "null":
        return value is None
    if type_name == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if type_name == "boolean":
        return isinstance(value, bool)
    if type_name == "string":
        return isinstance(value, str)
    if type_name == "array":
        return isinstance(value, list)
    if type_name == "object":
        return isinstance(value, dict)
    return False


def validate_schema(data, schema, path="$"):
    """Returns a list of human-readable error strings; empty list means valid."""
    errors = []
    expected = schema.get("type")
    if expected is not None:
        types = expected if isinstance(expected, list) else [expected]
        if not any(_type_matches(data, t) for t in types):
            errors.append(f"{path}: expected type {types}, got {type(data).__name__}")
            return errors

    enum = schema.get("enum")
    if enum is not None and data not in enum:
        errors.append(f"{path}: value {data!r} not in allowed set {enum}")
        return errors

    if isinstance(data, dict) and "properties" in schema:
        for key in schema.get("required", []):
            if key not in data:
                errors.append(f"{path}.{key}: missing required field")
        for key, subschema in schema["properties"].items():
            if key in data:
                errors.extend(validate_schema(data[key], subschema, f"{path}.{key}"))

    if isinstance(data, list) and "items" in schema:
        for index, item in enumerate(data):
            errors.extend(validate_schema(item, schema["items"], f"{path}[{index}]"))

    return errors


SLOP_REVIEW_SCHEMA = {
    "type": "object",
    "required": ["findings", "patch"],
    "properties": {
        "findings": {
            "type": "array",
            "items": {
                "type": "object",
                "required": ["file", "issue", "category"],
                "properties": {
                    "file": {"type": "string"},
                    "issue": {"type": "string"},
                    "category": {"type": "string"},
                },
            },
        },
        "patch": {"type": ["string", "null"]},
    },
}


CODE_REVIEW_SCHEMA = {
    "type": "object",
    "required": ["verdict", "findings"],
    "properties": {
        "verdict": {"type": "string", "enum": ["approve", "block"]},
        "findings": {
            "type": "array",
            "items": {
                "type": "object",
                "required": ["severity", "file", "line", "issue", "fix"],
                "properties": {
                    "severity": {
                        "type": "string",
                        "enum": ["critical", "high", "medium", "low"],
                    },
                    "file": {"type": "string"},
                    "line": {"type": ["integer", "null"]},
                    "issue": {"type": "string"},
                    "fix": {"type": "string"},
                },
            },
        },
    },
}


COMMIT_MESSAGE_SCHEMA = {
    "type": "object",
    "required": ["type", "scope", "description", "body", "trailers", "trivial"],
    "properties": {
        "type": {"type": "string"},
        "scope": {"type": ["string", "null"]},
        "description": {"type": "string"},
        "body": {"type": "string"},
        "trailers": {
            "type": "object",
            "required": [
                "constraint",
                "rejected",
                "directive",
                "confidence",
                "scope_risk",
                "not_tested",
            ],
            "properties": {
                "constraint": {"type": ["string", "null"]},
                "rejected": {"type": ["string", "null"]},
                "directive": {"type": ["string", "null"]},
                "confidence": {
                    "type": ["string", "null"],
                    "enum": ["high", "medium", "low", None],
                },
                "scope_risk": {
                    "type": ["string", "null"],
                    "enum": ["narrow", "moderate", "broad", None],
                },
                "not_tested": {"type": ["string", "null"]},
            },
        },
        "trivial": {"type": "boolean"},
    },
}
