import hashlib
import json
import os
import shutil
import tempfile
import unittest
from unittest import mock

import yaml

from runner import regimes


class RegimeAssemblyTests(unittest.TestCase):
    def setUp(self):
        self.tmp_dir = tempfile.mkdtemp(prefix="evals-regime-test-")
        self.bundles_dir = os.path.join(self.tmp_dir, "bundles")
        os.makedirs(os.path.join(self.bundles_dir, "snapshots"))
        self.workspace = os.path.join(self.tmp_dir, "workspace")
        os.makedirs(self.workspace)
        self.config = {
            "bundles_dir": self.bundles_dir,
            "posthog": {"mcp_url": "https://mcp.posthog.com/mcp", "mcp_token_env": "EVALS_TEST_MCP_TOKEN"},
        }

        self.saved_environ = dict(os.environ)
        os.environ[regimes.DEFAULT_PROJECT_ID_ENV] = "scratch-project-id"

    def tearDown(self):
        shutil.rmtree(self.tmp_dir, ignore_errors=True)
        if regimes._private_mcp_config_root:
            shutil.rmtree(regimes._private_mcp_config_root, ignore_errors=True)
            regimes._private_mcp_config_root = None
        os.environ.clear()
        os.environ.update(self.saved_environ)

    def test_every_regime_always_disallows_web_search_and_subagent_tools(self):
        os.environ["EVALS_TEST_MCP_TOKEN"] = "test-token"
        for regime_name in ("none", "llms-txt", "mcp"):
            task = {"id": "t"}
            if regime_name == "llms-txt":
                self._write_llms_txt_snapshot()
            assembly = regimes.assemble(regime_name, task, self.config, self.workspace)
            for tool in ("WebSearch", "Task", "Agent"):
                self.assertIn(tool, assembly.disallowed_tools)

    def test_non_llms_txt_regimes_disallow_web_fetch_outright(self):
        os.environ["EVALS_TEST_MCP_TOKEN"] = "test-token"
        for regime_name, task in (
            ("none", {"id": "t"}),
            ("mcp", {"id": "t"}),
        ):
            assembly = regimes.assemble(regime_name, task, self.config, self.workspace)
            self.assertIn("WebFetch", assembly.disallowed_tools)
            self.assertEqual(assembly.allowed_tools, [])

    def test_none_regime_has_no_context_and_no_hashes(self):
        assembly = regimes.assemble("none", {"id": "t"}, self.config, self.workspace)
        self.assertIsNone(assembly.context_text)
        self.assertIsNone(assembly.mcp_config_path)
        self.assertEqual(assembly.snapshot_hashes, {})

    def _write_llms_txt_snapshot(self, content="posthog docs content"):
        snapshot_path = os.path.join(self.bundles_dir, "snapshots", "llms-txt.md")
        with open(snapshot_path, "w", encoding="utf-8") as handle:
            handle.write(content)

    def test_llms_txt_regime_reads_snapshot_and_hashes_it(self):
        self._write_llms_txt_snapshot()

        assembly = regimes.assemble("llms-txt", {"id": "t"}, self.config, self.workspace)

        self.assertEqual(assembly.context_text, "posthog docs content")
        expected_hash = hashlib.sha256(b"posthog docs content").hexdigest()
        self.assertEqual(assembly.snapshot_hashes["llms_txt"], expected_hash)

    def test_llms_txt_regime_permits_domain_scoped_web_fetch_only(self):
        self._write_llms_txt_snapshot()

        assembly = regimes.assemble("llms-txt", {"id": "t"}, self.config, self.workspace)

        self.assertNotIn("WebFetch", assembly.disallowed_tools)
        self.assertIn("WebFetch(domain:posthog.com)", assembly.allowed_tools)
        self.assertIn("WebSearch", assembly.disallowed_tools)

    def test_llms_txt_regime_fails_loudly_when_snapshot_missing(self):
        with self.assertRaises(FileNotFoundError):
            regimes.assemble("llms-txt", {"id": "t"}, self.config, self.workspace)

    def test_mcp_regime_writes_config_outside_the_workspace_with_auth_header(self):
        os.environ["EVALS_TEST_MCP_TOKEN"] = "test-token"
        assembly = regimes.assemble("mcp", {"id": "t"}, self.config, self.workspace)

        self.assertIsNotNone(assembly.mcp_config_path)
        self.assertTrue(os.path.isfile(assembly.mcp_config_path))
        real_workspace = os.path.realpath(self.workspace)
        real_config_path = os.path.realpath(assembly.mcp_config_path)
        self.assertFalse(real_config_path.startswith(real_workspace + os.sep))
        with open(assembly.mcp_config_path, encoding="utf-8") as handle:
            written = json.load(handle)
        server = written["mcpServers"][regimes.MCP_SERVER_NAME]
        self.assertEqual(server["url"], "https://mcp.posthog.com/mcp")
        self.assertEqual(server["headers"]["Authorization"], "Bearer test-token")
        self.assertIsNone(assembly.context_text)

    def test_mcp_regime_declares_http_transport_so_the_entry_is_not_dropped(self):
        os.environ["EVALS_TEST_MCP_TOKEN"] = "test-token"
        assembly = regimes.assemble("mcp", {"id": "t"}, self.config, self.workspace)

        with open(assembly.mcp_config_path, encoding="utf-8") as handle:
            written = json.load(handle)
        self.assertEqual(written["mcpServers"][regimes.MCP_SERVER_NAME]["type"], "http")

    def test_mcp_server_name_avoids_the_stock_posthog_needs_auth_cache(self):
        os.environ["EVALS_TEST_MCP_TOKEN"] = "test-token"
        assembly = regimes.assemble("mcp", {"id": "t"}, self.config, self.workspace)

        with open(assembly.mcp_config_path, encoding="utf-8") as handle:
            written = json.load(handle)
        self.assertNotIn("posthog", written["mcpServers"])
        self.assertEqual(list(written["mcpServers"]), [regimes.MCP_SERVER_NAME])

    def _mcp_headers(self, task):
        assembly = regimes.assemble("mcp", task, self.config, self.workspace)
        with open(assembly.mcp_config_path, encoding="utf-8") as handle:
            return json.load(handle)["mcpServers"][regimes.MCP_SERVER_NAME]["headers"]

    def test_mcp_regime_is_always_read_only(self):
        os.environ["EVALS_TEST_MCP_TOKEN"] = "test-token"
        os.environ["EVALS_TEST_KEEPLINGS_ID"] = "999"

        for task in ({"id": "ch-task"}, {"id": "kp-task", "posthog_project_id_env": "EVALS_TEST_KEEPLINGS_ID"}):
            self.assertEqual(self._mcp_headers(task)["x-posthog-read-only"], "true")

    def test_mcp_regime_pins_the_project_named_by_the_task(self):
        os.environ["EVALS_TEST_MCP_TOKEN"] = "test-token"
        os.environ["EVALS_TEST_KEEPLINGS_ID"] = "keeplings-999"

        headers = self._mcp_headers({"id": "kp-task", "posthog_project_id_env": "EVALS_TEST_KEEPLINGS_ID"})

        self.assertEqual(headers["x-posthog-project-id"], "keeplings-999")

    def test_mcp_regime_pins_the_scratch_project_when_the_task_names_none(self):
        os.environ["EVALS_TEST_MCP_TOKEN"] = "test-token"

        headers = self._mcp_headers({"id": "ch-task"})

        self.assertEqual(headers["x-posthog-project-id"], "scratch-project-id")

    def test_mcp_config_dir_is_not_a_sibling_of_the_agent_workspace(self):
        os.environ["EVALS_TEST_MCP_TOKEN"] = "test-token"
        assembly = regimes.assemble("mcp", {"id": "t"}, self.config, self.workspace)

        sample_workspace = tempfile.mkdtemp(prefix="evals-ws-")
        agent_reachable_parent = os.path.realpath(os.path.dirname(sample_workspace))
        shutil.rmtree(sample_workspace, ignore_errors=True)
        config_parent = os.path.realpath(os.path.dirname(assembly.mcp_config_dir))
        self.assertNotEqual(config_parent, agent_reachable_parent)
        self.assertEqual(os.path.realpath(assembly.mcp_config_dir),
                         os.path.realpath(os.path.dirname(assembly.mcp_config_path)))

    def test_mcp_regime_default_project_env_comes_from_config(self):
        os.environ["EVALS_TEST_MCP_TOKEN"] = "test-token"
        os.environ["EVALS_TEST_CONFIGURED_SCRATCH"] = "configured-scratch-id"
        config = dict(self.config)
        config["posthog"] = dict(self.config["posthog"], scratch_project_id_env="EVALS_TEST_CONFIGURED_SCRATCH")

        assembly = regimes.assemble("mcp", {"id": "t"}, config, self.workspace)
        with open(assembly.mcp_config_path, encoding="utf-8") as handle:
            headers = json.load(handle)["mcpServers"][regimes.MCP_SERVER_NAME]["headers"]

        self.assertEqual(headers["x-posthog-project-id"], "configured-scratch-id")

    def test_dry_run_never_writes_a_token_bearing_file(self):
        os.environ["EVALS_TEST_MCP_TOKEN"] = "test-token"

        assembly = regimes.assemble("mcp", {"id": "t"}, self.config, self.workspace, dry_run=True)

        self.assertIsNone(assembly.mcp_config_path)
        self.assertIsNone(assembly.mcp_config_dir)
        preview = assembly.mcp_config_preview
        self.assertEqual(
            preview["mcpServers"][regimes.MCP_SERVER_NAME]["headers"]["Authorization"],
            "Bearer <redacted>",
        )
        self.assertNotIn("test-token", json.dumps(preview))

    def test_dry_run_still_fails_loudly_on_missing_credentials(self):
        os.environ.pop("EVALS_TEST_MCP_TOKEN", None)

        with self.assertRaises(FileNotFoundError):
            regimes.assemble("mcp", {"id": "t"}, self.config, self.workspace, dry_run=True)

    def test_mcp_regime_fails_loudly_rather_than_running_unpinned(self):
        os.environ["EVALS_TEST_MCP_TOKEN"] = "test-token"
        os.environ.pop(regimes.DEFAULT_PROJECT_ID_ENV, None)

        with self.assertRaises(FileNotFoundError):
            regimes.assemble("mcp", {"id": "ch-task"}, self.config, self.workspace)

    def test_mcp_regime_fails_loudly_when_the_tasks_named_project_env_is_unset(self):
        os.environ["EVALS_TEST_MCP_TOKEN"] = "test-token"
        os.environ.pop("EVALS_TEST_KEEPLINGS_ID", None)

        with self.assertRaises(FileNotFoundError):
            regimes.assemble(
                "mcp", {"id": "kp-task", "posthog_project_id_env": "EVALS_TEST_KEEPLINGS_ID"},
                self.config, self.workspace,
            )

    def test_mcp_regime_fails_loudly_when_token_env_is_missing(self):
        os.environ.pop("EVALS_TEST_MCP_TOKEN", None)
        with self.assertRaises(FileNotFoundError):
            regimes.assemble("mcp", {"id": "t"}, self.config, self.workspace)

    def test_mcp_regime_fails_loudly_when_token_env_is_empty(self):
        os.environ["EVALS_TEST_MCP_TOKEN"] = ""
        with self.assertRaises(FileNotFoundError):
            regimes.assemble("mcp", {"id": "t"}, self.config, self.workspace)

    def test_bundle_regime_reads_task_bundle_and_hashes_it(self):
        bundle_path = os.path.join(self.bundles_dir, "kp-release-impact.md")
        with open(bundle_path, "w", encoding="utf-8") as handle:
            handle.write("curated bundle content")

        assembly = regimes.assemble(
            "bundle", {"id": "kp-release-impact", "bundle": "kp-release-impact.md"}, self.config, self.workspace
        )

        self.assertEqual(assembly.context_text, "curated bundle content")
        expected_hash = hashlib.sha256(b"curated bundle content").hexdigest()
        self.assertEqual(assembly.snapshot_hashes["bundle"], expected_hash)
        self.assertIn("WebFetch", assembly.disallowed_tools)
        self.assertEqual(assembly.allowed_tools, [])

    def test_bundle_regime_resolves_relative_bundles_dir_against_evals_root_not_cwd(self):
        relative_config = {"bundles_dir": "bundles"}
        bundle_path = os.path.join(self.bundles_dir, "relative-bundle.md")
        with open(bundle_path, "w", encoding="utf-8") as handle:
            handle.write("relative bundle content")

        assembly = regimes.assemble(
            "bundle", {"id": "t", "bundle": "relative-bundle.md"}, relative_config, self.workspace,
            evals_root=self.tmp_dir,
        )

        self.assertEqual(assembly.context_text, "relative bundle content")

    def test_bundle_regime_fails_loudly_when_bundle_missing_from_task(self):
        with self.assertRaises(FileNotFoundError):
            regimes.assemble("bundle", {"id": "t", "bundle": None}, self.config, self.workspace)

    def test_bundle_regime_fails_loudly_when_bundle_file_missing_on_disk(self):
        with self.assertRaises(FileNotFoundError):
            regimes.assemble("bundle", {"id": "t", "bundle": "missing.md"}, self.config, self.workspace)

    def test_unknown_regime_raises(self):
        with self.assertRaises(ValueError):
            regimes.assemble("not-a-regime", {"id": "t"}, self.config, self.workspace)


class ConfigRootReclamationTests(unittest.TestCase):
    """Runs from run_cell's finally, so it must never be the reason a batch dies."""

    def setUp(self):
        self.saved_root = regimes._private_mcp_config_root

    def tearDown(self):
        if regimes._private_mcp_config_root:
            shutil.rmtree(regimes._private_mcp_config_root, ignore_errors=True)
        regimes._private_mcp_config_root = self.saved_root

    def test_a_locked_root_is_swallowed_rather_than_aborting_the_batch(self):
        regimes._private_mcp_config_root = regimes._mcp_config_root()

        with mock.patch.object(regimes.os, "rmdir", side_effect=OSError(32, "in use")):
            regimes.discard_empty_config_root()  # must not raise

        self.assertTrue(os.path.isdir(regimes._private_mcp_config_root))

    def test_a_listdir_failure_is_swallowed_too(self):
        regimes._private_mcp_config_root = regimes._mcp_config_root()

        with mock.patch.object(regimes.os, "listdir", side_effect=OSError(145, "not empty")):
            regimes.discard_empty_config_root()  # must not raise

    def test_an_empty_root_is_reclaimed_and_forgotten(self):
        root = regimes._mcp_config_root()
        regimes._private_mcp_config_root = root

        regimes.discard_empty_config_root()

        self.assertFalse(os.path.exists(root))
        self.assertIsNone(regimes._private_mcp_config_root)

    def test_a_root_still_holding_a_cell_dir_is_kept(self):
        root = regimes._mcp_config_root()
        regimes._private_mcp_config_root = root
        os.makedirs(os.path.join(root, "cell-still-running"))

        regimes.discard_empty_config_root()

        self.assertTrue(os.path.isdir(root))


class ConfigWriteFailureTests(unittest.TestCase):
    def setUp(self):
        self.saved_environ = dict(os.environ)
        os.environ["EVALS_TEST_MCP_TOKEN"] = "test-token"
        os.environ[regimes.DEFAULT_PROJECT_ID_ENV] = "1234"
        self.config = {"posthog": {"mcp_token_env": "EVALS_TEST_MCP_TOKEN"}}

    def tearDown(self):
        if regimes._private_mcp_config_root:
            shutil.rmtree(regimes._private_mcp_config_root, ignore_errors=True)
            regimes._private_mcp_config_root = None
        os.environ.clear()
        os.environ.update(self.saved_environ)

    def test_a_failed_write_strands_no_config_dir(self):
        root = regimes._mcp_config_root()

        with mock.patch.object(regimes.json, "dump", side_effect=RuntimeError("disk full")):
            with self.assertRaises(RuntimeError):
                regimes.assemble("mcp", {"id": "t"}, self.config, "workspace")

        self.assertEqual(os.listdir(root), [])


class ShippedTaskProjectPinTests(unittest.TestCase):
    """A kp- task left unpinned answers from the scratch sandbox instead of keeplings."""

    def test_every_kp_task_pins_the_keeplings_project(self):
        tasks_dir = os.path.join(regimes.EVALS_ROOT, "tasks")
        kp_task_ids = [name for name in os.listdir(tasks_dir) if name.startswith("kp-")]
        self.assertTrue(kp_task_ids, "expected kp- tasks to exist")

        for task_id in kp_task_ids:
            with open(os.path.join(tasks_dir, task_id, "task.yml"), encoding="utf-8") as handle:
                task = yaml.safe_load(handle)
            self.assertEqual(
                task.get("posthog_project_id_env"), "EVALS_POSTHOG_KEEPLINGS_PROJECT_ID",
                f"{task_id} must pin keeplings, not fall back to the scratch project",
            )


if __name__ == "__main__":
    unittest.main()
