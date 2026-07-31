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
import tempfile
from dataclasses import dataclass, field
from typing import Optional

ALWAYS_DISALLOWED_TOOLS = ["WebSearch", "Task", "Agent"]
LLMS_TXT_WEB_FETCH_RULE = "WebFetch(domain:posthog.com)"

REGIME_NAMES = ("none", "llms-txt", "mcp", "bundle")

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


def _assemble_none(task, config, workspace):
    return RegimeAssembly(
        context_text=None,
        mcp_config_path=None,
        disallowed_tools=_disallowed_tools(disallow_web_fetch=True),
        snapshot_hashes={},
    )


def _assemble_llms_txt(task, config, workspace, evals_root=None):
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


def _assemble_mcp(task, config, workspace):
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

    mcp_config = {
        "mcpServers": {
            "posthog": {
                "url": mcp_url,
                "headers": {"Authorization": f"Bearer {token}"},
            }
        }
    }
    # written outside the agent workspace so the agent's own tools never see .mcp.json
    config_dir = tempfile.mkdtemp(prefix="evals-mcp-")
    config_path = os.path.join(config_dir, ".mcp.json")
    with open(config_path, "w", encoding="utf-8") as handle:
        json.dump(mcp_config, handle, indent=2)

    return RegimeAssembly(
        context_text=None,
        mcp_config_path=config_path,
        disallowed_tools=_disallowed_tools(disallow_web_fetch=True),
        snapshot_hashes={},
    )


def _assemble_bundle(task, config, workspace, evals_root=None):
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


def assemble(regime, task, config, workspace, evals_root=None):
    assembler = _ASSEMBLERS.get(regime)
    if assembler is None:
        raise ValueError(f"unknown regime {regime!r}; expected one of {REGIME_NAMES}")
    if regime in ("llms-txt", "bundle"):
        return assembler(task, config, workspace, evals_root=evals_root)
    return assembler(task, config, workspace)
