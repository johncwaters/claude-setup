#!/usr/bin/env python3
"""Deterministic linter for .claude/release-profile.yml. No AI judgment.

Usage:
    python lint-profile.py [repo_root] [--preflight]

Exit 0: profile valid (warnings allowed). Exit 1: errors. Exit 2: cannot run.
"""

import json
import re
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ERROR: pyyaml not installed (pip install pyyaml)")
    sys.exit(2)

TRIGGERS = {"tag_push", "workflow_dispatch", "local_script", "push_to_main"}
TYPES = {"flutter_play", "npm_cli", "astro_convex_netlify", "electron_nsis", "other"}
REQUIRED_TOP = [
    "type",
    "versioning",
    "changelog",
    "git",
    "gates",
    "publish",
    "rollback",
    "approval",
]

errors: list[str] = []
warnings: list[str] = []


def err(msg: str) -> None:
    errors.append(msg)


def warn(msg: str) -> None:
    warnings.append(msg)


def section(profile: dict, key: str) -> dict:
    """Nested section as a mapping; present-but-scalar is a typed error, not a crash."""
    value = profile.get(key)
    if value is None:
        return {}
    if not isinstance(value, dict):
        err(f"{key} must be a mapping, got {type(value).__name__}: {value!r}")
        return {}
    return value


def git(root: Path, *args: str) -> str:
    r = subprocess.run(
        ["git", "-C", str(root), *args], capture_output=True, text=True, check=False
    )
    if r.returncode != 0:
        return ""
    return r.stdout.strip()


def branch_exists(root: Path, name: str) -> bool:
    if git(root, "rev-parse", "--verify", "-q", f"refs/heads/{name}"):
        return True
    return bool(git(root, "rev-parse", "--verify", "-q", f"refs/remotes/origin/{name}"))


def read_version(root: Path, version_file: str) -> str:
    p = root / version_file
    if not p.is_file():
        return ""
    if version_file.endswith("package.json"):
        try:
            return json.loads(p.read_text(encoding="utf-8")).get("version", "")
        except (json.JSONDecodeError, UnicodeDecodeError):
            return ""
    if version_file.endswith("pubspec.yaml"):
        m = re.search(r"^version:\s*(\S+)", p.read_text(encoding="utf-8"), re.MULTILINE)
        return m.group(1) if m else ""
    return ""


def check_schema(profile: dict) -> None:
    for key in REQUIRED_TOP:
        if key not in profile:
            err(f"missing required top-level key: {key}")
    ptype = profile.get("type")
    if ptype not in TYPES:
        err(f"type must be one of {sorted(TYPES)}, got: {ptype}")

    v = section(profile, "versioning")
    for key in ("scheme", "version_file", "tag_format"):
        if not v.get(key):
            err(f"versioning.{key} is required")

    g = section(profile, "git")
    for key in ("release_from", "release_commit_pattern"):
        if not g.get(key):
            err(f"git.{key} is required")

    pub = section(profile, "publish")
    if pub.get("trigger") not in TRIGGERS:
        err(
            f"publish.trigger must be one of {sorted(TRIGGERS)}, got: {pub.get('trigger')}"
        )

    gates = section(profile, "gates")
    if not gates.get("evidence"):
        err("gates.evidence must be a non-empty list (what proves the release shipped)")

    rb = section(profile, "rollback")
    if not rb.get("steps"):
        err("rollback.steps must be non-empty (derive them before you need them)")
    if not rb.get("never"):
        err("rollback.never must be non-empty")

    ap = section(profile, "approval")
    if not ap.get("human_before"):
        err("approval.human_before must be non-empty")


def check_repo(root: Path, profile: dict) -> None:
    v = section(profile, "versioning")
    vf = v.get("version_file", "")
    if vf and not (root / vf).is_file():
        err(f"versioning.version_file not found in repo: {vf}")
    if vf and (root / vf).is_file() and not read_version(root, vf):
        warn(
            f"could not extract a version value from {vf} (unsupported format for deterministic read)"
        )

    ch = section(profile, "changelog")
    ch_path = ch.get("path", "")
    ch_missing_ok = str(ch.get("status", "")).upper() == "MISSING"
    if ch_path and not ch_missing_ok and not (root / ch_path).is_file():
        err(
            f"changelog.path not found: {ch_path} (set changelog.status: MISSING if introducing it at next release)"
        )

    g = section(profile, "git")
    for key in ("release_from", "integration"):
        name = g.get(key)
        if name and not branch_exists(root, str(name)):
            err(f"git.{key} branch not found locally or on origin: {name}")

    tags = git(root, "tag", "--list").splitlines()
    tag_format = str(v.get("tag_format", ""))
    if tags and tag_format.startswith("v"):
        unprefixed = [t for t in tags if re.fullmatch(r"[0-9].*", t)]
        if unprefixed:
            warn(
                f"{len(unprefixed)} existing tag(s) lack the v prefix declared in tag_format: {unprefixed[:3]}"
            )
    if tags and tag_format and not tag_format.startswith("v"):
        prefixed = [t for t in tags if t.startswith("v")]
        if prefixed:
            warn(
                f"tag_format has no v prefix but {len(prefixed)} existing tag(s) are v-prefixed: {prefixed[:3]}"
            )

    # Formatter-enforced line endings without .gitattributes burn CI on
    # cross-platform repos (autocrlf flips what the formatter then rejects).
    for bio in ("biome.json", "biome.jsonc"):
        bp = root / bio
        if (
            bp.is_file()
            and '"lineEnding"' in bp.read_text(encoding="utf-8", errors="ignore")
            and not (root / ".gitattributes").is_file()
        ):
            warn(
                f"{bio} pins lineEnding but repo has no .gitattributes; CI line-ending failures likely (add .gitattributes + one renormalize commit)"
            )

    targets = profile.get("targets")
    if targets is not None:
        if not isinstance(targets, list):
            err(f"targets must be a list, got {type(targets).__name__}")
        for i, t in enumerate(targets if isinstance(targets, list) else []):
            if not isinstance(t, dict) or not t.get("name") or not t.get("trigger"):
                err(f"targets[{i}] needs at least name and trigger")

    detail = section(profile, "publish").get("detail") or {}
    for value in detail.values():
        for m in re.findall(r"\.github/workflows/[\w.-]+\.ya?ml", str(value)):
            if not (root / m).is_file():
                err(f"publish.detail references missing workflow file: {m}")

    if section(profile, "publish").get("trigger") == "local_script":
        cmd = str(detail.get("command", ""))
        m = re.fullmatch(r"npm run (\S+)", cmd)
        if not m:
            warn(
                f"publish.detail.command not in 'npm run <script>' form; script existence not verified: {cmd!r}"
            )
        if m:
            pkg = root / "package.json"
            scripts = {}
            if pkg.is_file():
                try:
                    scripts = json.loads(pkg.read_text(encoding="utf-8")).get(
                        "scripts", {}
                    )
                except (json.JSONDecodeError, UnicodeDecodeError):
                    pass
            if m.group(1) not in scripts:
                err(
                    f"publish.detail.command references npm script '{m.group(1)}' not present in package.json"
                )


def check_preflight(root: Path, profile: dict) -> None:
    if git(root, "status", "--porcelain"):
        err("preflight: working tree is not clean")
    g = section(profile, "git")
    current = git(root, "rev-parse", "--abbrev-ref", "HEAD")
    if current == "HEAD":
        err("preflight: detached HEAD")
    allowed = {str(g.get("release_from", "")), str(g.get("integration", ""))} - {""}
    if current and allowed and current not in allowed:
        warn(
            f"preflight: current branch '{current}' is neither release_from nor integration ({sorted(allowed)})"
        )
    vf = section(profile, "versioning").get("version_file", "")
    version = read_version(root, vf) if vf else ""
    if version:
        base = version.split("+")[0]
        existing = git(root, "tag", "--list", f"v{version}") or git(
            root, "tag", "--list", f"v{base}"
        )
        # Preflight runs before the Phase 2 bump, so an existing tag for the
        # CURRENT version is normal after any successful prior release. This is
        # informational; the hard guard is re-checking the TARGET tag right
        # before Phase 3 creates it.
        if existing:
            warn(
                f"preflight: current version {version} is already released ({existing}); Phase 2 must bump before Phase 3 tags"
            )


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--preflight"]
    preflight = "--preflight" in sys.argv
    root = Path(args[0]).resolve() if args else Path.cwd()
    profile_path = root / ".claude" / "release-profile.yml"

    if not (root / ".git").exists():
        print(f"ERROR: {root} is not a git repository")
        return 2
    if not profile_path.is_file():
        print(
            f"ERROR: no profile at {profile_path} (run the skill's derive step first)"
        )
        return 2

    try:
        profile = yaml.safe_load(profile_path.read_text(encoding="utf-8"))
    except yaml.YAMLError as e:
        print(f"ERROR: profile is not valid YAML: {e}")
        return 1
    if not isinstance(profile, dict):
        print("ERROR: profile did not parse to a mapping")
        return 1

    check_schema(profile)
    check_repo(root, profile)
    if preflight:
        check_preflight(root, profile)

    unique_warnings = list(dict.fromkeys(warnings))
    unique_errors = list(dict.fromkeys(errors))
    for w in unique_warnings:
        print(f"WARN  {w}")
    for e in unique_errors:
        print(f"ERROR {e}")
    status = "FAIL" if unique_errors else "OK"
    print(
        f"{status}: {len(unique_errors)} error(s), {len(unique_warnings)} warning(s) [{root.name}]"
    )
    return 1 if unique_errors else 0


if __name__ == "__main__":
    sys.exit(main())
