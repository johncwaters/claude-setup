import hashlib
import json
import os
import shutil
import tempfile
import unittest

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

    def tearDown(self):
        shutil.rmtree(self.tmp_dir, ignore_errors=True)
        os.environ.pop("EVALS_TEST_MCP_TOKEN", None)

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
        self.assertEqual(written["mcpServers"]["posthog"]["url"], "https://mcp.posthog.com/mcp")
        self.assertEqual(written["mcpServers"]["posthog"]["headers"]["Authorization"], "Bearer test-token")
        self.assertIsNone(assembly.context_text)

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


if __name__ == "__main__":
    unittest.main()
