"""Context regime assembly: what each regime injects into a run, and what every regime forbids.

WebSearch, Task, and Agent are always disallowed so every run stays single-agent and
never searches the open web. WebFetch is regime-dependent: posthog.com/llms.txt is a
~330 KB link index of doc URLs, not inline content (llms-full.txt does not exist), so its
designed use is link-following. Blocking WebFetch in the llms-txt regime would measure
nothing, so that regime alone permits it, scoped to posthog.com via allowed_tools. Every
other regime keeps WebFetch off so the regime stays the only context variable.
"""

import hashlib
import json
import os
import shutil
import tempfile
from dataclasses import dataclass, field
from typing import Optional

ALWAYS_DISALLOWED_TOOLS = ["WebSearch", "Task", "Agent"]
LLMS_TXT_WEB_FETCH_RULE = "WebFetch(domain:posthog.com)"

REGIME_NAMES = ("none", "llms-txt", "mcp", "bundle")

# Deliberately not "posthog": Claude Code caches a per-server-name "needs auth" verdict from
# any earlier OAuth attempt, and a cached entry makes it skip connecting entirely
# ("Skipping connection (cached needs-auth)") without ever sending our Authorization header.
# A developer machine with the stock `claude mcp add ... posthog` server therefore silently
# disables the mcp regime. The name must stay distinct from any server a human would install.
MCP_SERVER_NAME = "posthog-evals"

# Tasks that don't name their own project pin to the scratch sandbox rather than running
# unpinned: an unpinned session silently adopts whichever project the personal key defaults
# to, which is how a kp- trial ended up answering from Card Harbor's near-empty project.
DEFAULT_PROJECT_ID_ENV = "EVALS_POSTHOG_SCRATCH_PROJECT_ID"

# Same root tasks/results/config resolve against by default (see runner/run.py's
# EVALS_ROOT); used to anchor a relative bundles_dir so it never depends on cwd.
EVALS_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


@dataclass
class RegimeAssembly:
    context_text: Optional[str]
    mcp_config_path: Optional[str]
    disallowed_tools: list
    snapshot_hashes: dict
    allowed_tools: list = field(default_factory=list)
    # run_cell deletes this in its finally; the file under it holds a live bearer token.
    mcp_config_dir: Optional[str] = None
    mcp_config_preview: Optional[dict] = None


_private_mcp_config_root = None


def _mcp_config_root():
    """Private parent for token-bearing configs, kept out of the workspaces' own directory.

    This is defence in depth, not a boundary. Passing a secret through a file the agent's
    process can open means a determined agent with filesystem read can read the raw key
    during its own mcp cell, whatever the path; nesting only takes it off the obvious `..`
    walk out of the workspace. What the layout does buy is the other three regimes: combined
    with per-cell deletion, no token file exists on disk at all while a none/llms-txt/bundle
    cell runs. The key itself is the real control, scoped query-read-only and project-pinned
    via the Authorization and x-posthog-* headers, so reading it grants no more than the
    session already had.
    """
    global _private_mcp_config_root
    if _private_mcp_config_root and os.path.isdir(_private_mcp_config_root):
        return _private_mcp_config_root
    _private_mcp_config_root = tempfile.mkdtemp(prefix="evals-mcpcfg-")
    return _private_mcp_config_root


def discard_empty_config_root():
    """Reclaim the private root once a cell's config dir is gone, so a finished run leaves
    nothing behind at all. The next cell recreates it on demand.

    Best-effort by design: this runs from run_cell's finally, where an antivirus or indexer
    holding a transient handle (WinError 32/145) would otherwise abort the batch loop and
    skip summary.json. An orphaned empty dir is a far smaller problem than a lost batch.
    """
    global _private_mcp_config_root
    if not _private_mcp_config_root:
        return
    try:
        if not os.path.isdir(_private_mcp_config_root):
            _private_mcp_config_root = None
            return
        if os.listdir(_private_mcp_config_root):
            return
        os.rmdir(_private_mcp_config_root)
    except OSError:
        return
    _private_mcp_config_root = None


def _disallowed_tools(disallow_web_fetch):
    tools = list(ALWAYS_DISALLOWED_TOOLS)
    if disallow_web_fetch:
        tools.append("WebFetch")
    return tools


def _sha256_text(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _read_required(path, missing_instructions):
    if not os.path.isfile(path):
        raise FileNotFoundError(f"{path} not found. {missing_instructions}")
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read()


def _resolve_bundles_dir(config, evals_root):
    bundles_dir = config.get("bundles_dir", "bundles")
    if os.path.isabs(bundles_dir):
        return bundles_dir
    return os.path.join(evals_root or EVALS_ROOT, bundles_dir)


def _assemble_none(task, config, workspace, evals_root, dry_run):
    return RegimeAssembly(
        context_text=None,
        mcp_config_path=None,
        disallowed_tools=_disallowed_tools(disallow_web_fetch=True),
        snapshot_hashes={},
    )


def _assemble_llms_txt(task, config, workspace, evals_root, dry_run):
    bundles_dir = _resolve_bundles_dir(config, evals_root)
    path = os.path.join(bundles_dir, "snapshots", "llms-txt.md")
    text = _read_required(
        path,
        "run the llms.txt snapshot step (see README) to download posthog.com/llms.txt "
        "into bundles/snapshots/llms-txt.md before running the llms-txt regime; a separate "
        "snapshot step freezes this file, the regime itself never fetches it at run time.",
    )
    return RegimeAssembly(
        context_text=text,
        mcp_config_path=None,
        disallowed_tools=_disallowed_tools(disallow_web_fetch=False),
        snapshot_hashes={"llms_txt": _sha256_text(text)},
        allowed_tools=[LLMS_TXT_WEB_FETCH_RULE],
    )


def _assemble_mcp(task, config, workspace, evals_root, dry_run):
    posthog_config = config.get("posthog", {})
    mcp_url = posthog_config.get("mcp_url", "https://mcp.posthog.com/mcp")
    token_env = posthog_config.get("mcp_token_env", "EVALS_POSTHOG_PERSONAL_KEY")
    token = os.environ.get(token_env, "")
    if not token:
        raise FileNotFoundError(
            f"{token_env} is not set. Export {token_env} with a valid PostHog personal API "
            "key before running the mcp regime; the mcp regime never runs with an empty "
            "Authorization header."
        )

    default_project_id_env = posthog_config.get("scratch_project_id_env", DEFAULT_PROJECT_ID_ENV)
    project_id_env = task.get("posthog_project_id_env") or default_project_id_env
    project_id = os.environ.get(project_id_env, "")
    if not project_id:
        raise FileNotFoundError(
            f"{project_id_env} is not set. Export {project_id_env} with the PostHog project id "
            f"the mcp regime should pin task {task.get('id')!r} to (task.yml's "
            "posthog_project_id_env names it, defaulting to config.yml's "
            f"posthog.scratch_project_id_env, currently {default_project_id_env}); the mcp "
            "regime never runs unpinned, because an "
            "unpinned session answers from whichever project the personal key defaults to."
        )

    # "type" is required: an entry carrying only a url is dropped with a warning that
    # `claude -p` never surfaces, so the regime would run with no MCP server at all.
    # Pinning the project also removes the switch-project/switch-organization tools, so the
    # agent cannot wander off the pin, which is why no organization header is needed.
    mcp_config = {
        "mcpServers": {
            MCP_SERVER_NAME: {
                "type": "http",
                "url": mcp_url,
                "headers": {
                    "Authorization": f"Bearer {token}",
                    "x-posthog-read-only": "true",
                    "x-posthog-project-id": project_id,
                },
            }
        }
    }
    if dry_run:
        return RegimeAssembly(
            context_text=None,
            mcp_config_path=None,
            disallowed_tools=_disallowed_tools(disallow_web_fetch=True),
            snapshot_hashes={},
            mcp_config_preview=_redacted_preview(mcp_config),
        )

    config_dir = tempfile.mkdtemp(prefix="cell-", dir=_mcp_config_root())
    config_path = os.path.join(config_dir, ".mcp.json")
    try:
        with open(config_path, "w", encoding="utf-8") as handle:
            json.dump(mcp_config, handle, indent=2)
    except BaseException:
        # nobody owns this dir until it reaches run_cell on the assembly, so a failure here
        # would strand a half-written token file no teardown knows about
        shutil.rmtree(config_dir, ignore_errors=True)
        raise

    return RegimeAssembly(
        context_text=None,
        mcp_config_path=config_path,
        disallowed_tools=_disallowed_tools(disallow_web_fetch=True),
        snapshot_hashes={},
        mcp_config_dir=config_dir,
    )


def _redacted_preview(mcp_config):
    server = dict(mcp_config["mcpServers"][MCP_SERVER_NAME])
    server["headers"] = dict(server["headers"], Authorization="Bearer <redacted>")
    return {"mcpServers": {MCP_SERVER_NAME: server}}


def _assemble_bundle(task, config, workspace, evals_root, dry_run):
    bundle_rel_path = task.get("bundle")
    if not bundle_rel_path:
        raise FileNotFoundError(
            f"task {task.get('id')!r} has no bundle configured; author "
            f"bundles/<name>.md and set task.yml's bundle field before running "
            "the bundle regime."
        )
    bundles_dir = _resolve_bundles_dir(config, evals_root)
    path = os.path.join(bundles_dir, bundle_rel_path)
    text = _read_required(path, f"author the bundle at {path} before running the bundle regime.")
    return RegimeAssembly(
        context_text=text,
        mcp_config_path=None,
        disallowed_tools=_disallowed_tools(disallow_web_fetch=True),
        snapshot_hashes={"bundle": _sha256_text(text)},
    )


_ASSEMBLERS = {
    "none": _assemble_none,
    "llms-txt": _assemble_llms_txt,
    "mcp": _assemble_mcp,
    "bundle": _assemble_bundle,
}


def assemble(regime, task, config, workspace, evals_root=None, dry_run=False):
    assembler = _ASSEMBLERS.get(regime)
    if assembler is None:
        raise ValueError(f"unknown regime {regime!r}; expected one of {REGIME_NAMES}")
    return assembler(task, config, workspace, evals_root, dry_run)
