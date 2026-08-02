"""Unit tests for the two ch-release-tagging static-acceptance fixes:

1. _register_call_covers_release_properties must resolve one indirection hop, so a
   register(...) call that passes an imported symbol (the super-properties object built
   in its own module) still counts, not just an inline object literal.
2. _version_source_is_dynamic must ignore hardcoded semver literals inside test files,
   since a unit test's fixture value (`register` called with a literal in an assertion)
   is not the production hardcoding the task's "not typed in by hand" rule targets.
"""

import os
import unittest

from tests.helpers import load_checks_module, write_file

CHECKS = load_checks_module("ch-release-tagging")


class RegisterCallCoversReleasePropertiesTests(unittest.TestCase):
    def test_inline_object_literal_register_call_passes(self):
        added_lines_by_file = {
            "src/renderer/src/main.tsx": (
                "posthog.register({ $app_version: version, $app_build: build });\n"
            ),
        }

        self.assertTrue(CHECKS._register_call_covers_release_properties(added_lines_by_file))

    def test_register_call_with_symbol_defined_in_another_changed_file_passes(self):
        # models the audited real shape: src/shared/appIdentity.ts exports a builder
        # function, and the renderer imports and registers its return value.
        added_lines_by_file = {
            "src/renderer/src/main.tsx": (
                "import { toAppIdentitySuperProperties } from '../../shared/appIdentity';\n"
                "posthog.register(toAppIdentitySuperProperties());\n"
            ),
            "src/shared/appIdentity.ts": (
                "export function toAppIdentitySuperProperties() {\n"
                "  return { $app_version: version, $app_build: build };\n"
                "}\n"
            ),
        }

        self.assertTrue(CHECKS._register_call_covers_release_properties(added_lines_by_file))

    def test_register_call_with_bare_constant_symbol_from_another_file_passes(self):
        added_lines_by_file = {
            "src/renderer/src/telemetryRelease.ts": (
                "export const releaseSuperProperties = { $app_version: version, $app_build: build };\n"
            ),
            "src/renderer/src/main.tsx": (
                "import { releaseSuperProperties } from './telemetryRelease';\n"
                "posthog.register(releaseSuperProperties);\n"
            ),
        }

        self.assertTrue(CHECKS._register_call_covers_release_properties(added_lines_by_file))

    def test_missing_register_call_entirely_fails(self):
        added_lines_by_file = {
            "src/renderer/src/main.tsx": "posthog.capture('app_launched');\n",
        }

        self.assertFalse(CHECKS._register_call_covers_release_properties(added_lines_by_file))

    def test_register_call_referencing_unrelated_symbol_fails(self):
        added_lines_by_file = {
            "src/renderer/src/main.tsx": (
                "import { unrelatedConfig } from './config';\n"
                "posthog.register(unrelatedConfig);\n"
            ),
            "src/renderer/src/config.ts": "export const unrelatedConfig = { debug: true };\n",
        }

        self.assertFalse(CHECKS._register_call_covers_release_properties(added_lines_by_file))


class VersionSourceIsDynamicTests(unittest.TestCase):
    def setUp(self):
        import shutil
        import tempfile
        self.workspace = tempfile.mkdtemp(prefix="evals-ch-release-tagging-test-")
        self.addCleanup(shutil.rmtree, self.workspace, True)

    def test_semver_literal_in_test_file_does_not_trip_the_hardcoded_check(self):
        write_file(
            self.workspace, "src/renderer/src/main.tsx",
            "import { app } from 'electron';\n"
            "const version = app.getVersion();\n"
            "posthog.register({ $app_version: version });\n",
        )
        write_file(
            self.workspace, "src/renderer/src/main.test.ts",
            "expect(register).toHaveBeenCalledWith({ $app_version: '0.9.7' });\n",
        )
        changed_files = ["src/renderer/src/main.tsx", "src/renderer/src/main.test.ts"]

        self.assertTrue(CHECKS._version_source_is_dynamic(self.workspace, changed_files))

    def test_hardcoded_semver_in_production_file_still_fails(self):
        write_file(
            self.workspace, "src/renderer/src/main.tsx",
            "import { app } from 'electron';\n"
            "const version = app.getVersion();\n"
            "posthog.register({ $app_version: '0.9.7' });\n",
        )
        changed_files = ["src/renderer/src/main.tsx"]

        self.assertFalse(CHECKS._version_source_is_dynamic(self.workspace, changed_files))

    def test_spec_suffixed_test_file_is_also_excluded(self):
        write_file(
            self.workspace, "src/main/index.ts",
            "import { app } from 'electron';\nconst version = app.getVersion();\n",
        )
        write_file(
            self.workspace, "src/main/index.spec.ts",
            "expect(getReleaseInfo()).toEqual({ app_version: '1.2.3' });\n",
        )
        changed_files = ["src/main/index.ts", "src/main/index.spec.ts"]

        self.assertTrue(CHECKS._version_source_is_dynamic(self.workspace, changed_files))

    def test_no_dynamic_lookup_anywhere_fails(self):
        write_file(
            self.workspace, "src/renderer/src/main.tsx",
            "posthog.register({ $app_version: getConfiguredVersion() });\n",
        )
        changed_files = ["src/renderer/src/main.tsx"]

        self.assertFalse(CHECKS._version_source_is_dynamic(self.workspace, changed_files))


if __name__ == "__main__":
    unittest.main()
