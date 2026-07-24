"""Commit message convention validation and diff packet construction (SPEC Stage 4, 7)."""

import os
from dataclasses import dataclass, field

ALLOWED_TYPES = {
    "feat",
    "fix",
    "refactor",
    "chore",
    "docs",
    "test",
    "style",
    "perf",
    "build",
    "ci",
}

EM_DASH = "—"
EN_DASH = "–"

# Unicode blocks that carry emoji in practice. Deliberately excludes general arrow and
# symbol ranges that would false-positive on ordinary punctuation-adjacent characters.
_EMOJI_RANGES = (
    (0x1F300, 0x1FAFF),  # misc symbols, emoticons, transport, supplemental pictographs
    (0x2600, 0x26FF),  # misc symbols
    (0x2700, 0x27BF),  # dingbats
    (0x1F1E6, 0x1F1FF),  # regional indicator letters (flag emoji)
    (0xFE00, 0xFE0F),  # variation selectors (emoji presentation)
)

_TRAILER_LABELS = (
    ("constraint", "Constraint"),
    ("rejected", "Rejected"),
    ("directive", "Directive"),
    ("confidence", "Confidence"),
    ("scope_risk", "Scope-risk"),
    ("not_tested", "Not-tested"),
)


def _is_emoji(ch):
    code = ord(ch)
    return any(lo <= code <= hi for lo, hi in _EMOJI_RANGES)


def find_banned_chars(text):
    found = set()
    if EM_DASH in text:
        found.add("em dash")
    if EN_DASH in text:
        found.add("en dash")
    for ch in text:
        if _is_emoji(ch):
            found.add(f"emoji {ch!r}")
    return sorted(found)


def _render_trailers(trailers):
    lines = []
    for key, label in _TRAILER_LABELS:
        value = trailers.get(key)
        if value:
            lines.append(f"{label}: {value}")
    return lines


def render_message(parsed):
    """Renders `<type>(<scope>): <description>` / body / trailers per the SPEC convention.

    Tolerant of missing/invalid fields so it can be used to render a draft for banned
    character checking even before the message has fully passed validation.
    """
    msg_type = parsed.get("type") or ""
    scope = parsed.get("scope")
    description = parsed.get("description") or ""
    body = (parsed.get("body") or "").strip()
    trailers = parsed.get("trailers") or {}
    trivial = bool(parsed.get("trivial"))

    header = f"{msg_type}({scope}): {description}" if scope else f"{msg_type}: {description}"

    parts = [header]
    if body:
        parts.append("")
        parts.append(body)

    trailer_lines = [] if trivial else _render_trailers(trailers)
    if trailer_lines:
        parts.append("")
        parts.extend(trailer_lines)

    return "\n".join(parts)


def validate_message(parsed):
    """Returns a list of validation error strings; empty list means the message is valid."""
    errors = []

    msg_type = parsed.get("type")
    if msg_type not in ALLOWED_TYPES:
        errors.append(f"type must be one of {sorted(ALLOWED_TYPES)}, got {msg_type!r}")

    description = parsed.get("description") or ""
    if not description.strip():
        errors.append("description must not be empty")
    if len(description) > 72:
        errors.append("description must be 72 characters or fewer")
    if description.endswith("."):
        errors.append("description must not end with a trailing period")

    trivial = parsed.get("trivial")
    trailers = parsed.get("trailers") or {}
    if trivial is False:
        if not trailers.get("confidence"):
            errors.append("confidence trailer is required when trivial is false")
        if not trailers.get("scope_risk"):
            errors.append("scope_risk trailer is required when trivial is false")

    banned = find_banned_chars(render_message(parsed))
    if banned:
        errors.append(f"message contains banned characters: {', '.join(banned)}")

    return errors


@dataclass
class DiffPacket:
    text: str
    dropped_files: list = field(default_factory=list)
    included_files: list = field(default_factory=list)


def _parse_diff_git_path(line):
    marker = " b/"
    idx = line.rfind(marker)
    if idx == -1:
        return line.strip()
    return line[idx + len(marker):].strip()


def split_diff_sections(diff_text):
    if not diff_text:
        return []
    sections = []
    current_path = None
    current_lines = []
    for line in diff_text.splitlines():
        if line.startswith("diff --git "):
            if current_path is not None:
                sections.append((current_path, "\n".join(current_lines)))
            current_path = _parse_diff_git_path(line)
            current_lines = [line]
            continue
        current_lines.append(line)
    if current_path is not None:
        sections.append((current_path, "\n".join(current_lines)))
    return sections


def truncate_diff_lines(content, max_lines):
    lines = content.splitlines()
    if len(lines) <= max_lines:
        return content
    kept = lines[:max_lines]
    dropped_count = len(lines) - max_lines
    kept.append(f"[truncated {dropped_count} lines]")
    return "\n".join(kept)


def _read_text_best_effort(full_path):
    try:
        with open(full_path, "r", encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError:
        return ""


def _read_untracked_section(repo, path, size_limit):
    full_path = os.path.join(repo, path)
    if not os.path.isfile(full_path):
        return None
    if os.path.getsize(full_path) >= size_limit:
        return None
    content = _read_text_best_effort(full_path)
    header = f"diff --git a/{path} b/{path}\nnew file mode 100644\n--- /dev/null\n+++ b/{path}\n"
    body = "\n".join(f"+{line}" for line in content.splitlines())
    return header + body


def _enforce_char_budget(sections, max_total_chars):
    remaining = list(sections)
    dropped = []
    total = sum(len(content) for _, content in remaining)
    while total > max_total_chars and remaining:
        largest_index = max(range(len(remaining)), key=lambda i: len(remaining[i][1]))
        path, content = remaining.pop(largest_index)
        dropped.append(path)
        total -= len(content)
    return remaining, dropped


def build_diff_packet(
    git,
    untracked_files,
    status_lines,
    branch,
    max_file_lines=400,
    max_total_chars=60000,
    untracked_size_limit=20000,
):
    tracked_diff = git.diff_head()
    sections = [
        (path, truncate_diff_lines(content, max_file_lines))
        for path, content in split_diff_sections(tracked_diff)
    ]

    for path in untracked_files:
        raw_section = _read_untracked_section(git.repo, path, untracked_size_limit)
        if raw_section is None:
            continue
        sections.append((path, truncate_diff_lines(raw_section, max_file_lines)))

    kept, dropped = _enforce_char_budget(sections, max_total_chars)

    dropped_note = f"\n\n(dropped {len(dropped)} file section(s) to fit budget: {', '.join(dropped)})" if dropped else ""
    body = "\n".join(content for _, content in kept)
    header = f"branch: {branch}\n\nstatus (git status --short):\n{status_lines}\n\ndiff:\n"
    text = header + body + dropped_note

    return DiffPacket(text=text, dropped_files=dropped, included_files=[path for path, _ in kept])


def apply_patch_gate(git, patch, temp_dir, filename="slop_patch.diff"):
    """Runs `git apply --check` then `git apply` if the check passes.

    Returns (applied: bool, stderr: str). Never raises on a bad patch; that is the
    expected, testable failure path (SPEC Stage 5 gate).
    """
    os.makedirs(temp_dir, exist_ok=True)
    patch_path = os.path.join(temp_dir, filename)
    with open(patch_path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(patch)

    check = git.apply_check(patch_path)
    if check.returncode != 0:
        return False, check.stderr

    git.apply(patch_path)
    return True, ""
