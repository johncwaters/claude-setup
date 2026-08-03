"""Unit tests for ch-release-tagging's static acceptance surface.

_register_call_covers_release_properties accepts a register(...) call whose release
properties are inline, or one indirection hop away (an imported symbol whose own
definition, scoped to just that declaration, carries $app_version/$app_build).
_version_source_is_dynamic requires a real app.getVersion()-style lookup and rejects
hardcoded semver literals, but only in production files: a test file's fixture literal
doesn't count as the hand-typed version the task's acceptance surface is guarding against.
"""

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

    def test_release_keys_elsewhere_in_the_defining_file_do_not_leak_into_an_unrelated_symbol(self):
        # buildTelemetryContext's own body has no release keys; the file also happens to
        # have an unrelated capture call that does. The symbol's own definition, not the
        # whole file, decides the outcome, so this must still fail.
        added_lines_by_file = {
            "src/renderer/src/main.tsx": (
                "import { buildTelemetryContext } from './telemetry';\n"
                "posthog.register(buildTelemetryContext());\n"
            ),
            "src/renderer/src/telemetry.ts": (
                "export function buildTelemetryContext() {\n"
                "  return { locale: getLocale() };\n"
                "}\n"
                "posthog.capture('debug_info', { $app_version: '9.9.9' });\n"
            ),
        }

        self.assertFalse(CHECKS._register_call_covers_release_properties(added_lines_by_file))

    def test_destructured_parameter_arrow_function_body_with_release_keys_passes(self):
        # the destructuring brace `({ appVersion, buildNumber })` sits before the real
        # body; the body itself, not the destructuring pattern, must be what's inspected.
        added_lines_by_file = {
            "src/shared/appIdentity.ts": (
                "export const buildReleaseProperties = ({ appVersion, buildNumber }) => {\n"
                "  return { $app_version: appVersion, $app_build: buildNumber };\n"
                "};\n"
            ),
            "src/renderer/src/main.tsx": (
                "import { buildReleaseProperties } from '../../shared/appIdentity';\n"
                "posthog.register(buildReleaseProperties(getReleaseInfo()));\n"
            ),
        }

        self.assertTrue(CHECKS._register_call_covers_release_properties(added_lines_by_file))

    def test_plain_paren_arrow_function_body_with_release_keys_passes(self):
        added_lines_by_file = {
            "src/shared/appIdentity.ts": (
                "export const buildReleaseProperties = (appVersion) => ({ $app_version: appVersion });\n"
            ),
            "src/renderer/src/main.tsx": (
                "import { buildReleaseProperties } from '../../shared/appIdentity';\n"
                "posthog.register(buildReleaseProperties(getAppVersion()));\n"
            ),
        }

        self.assertTrue(CHECKS._register_call_covers_release_properties(added_lines_by_file))

    def test_arrow_function_body_without_keys_fails_despite_key_like_params_or_elsewhere_text(self):
        # the destructured param names and an unrelated capture call both contain
        # key-shaped text; only the arrow function's own real body should be inspected,
        # and that body has no release keys, so this must fail.
        added_lines_by_file = {
            "src/shared/appIdentity.ts": (
                "export const buildReleaseProperties = ({ app_version, app_build }) => {\n"
                "  return { locale: getLocale() };\n"
                "};\n"
                "posthog.capture('debug_info', { $app_version: '9.9.9' });\n"
            ),
            "src/renderer/src/main.tsx": (
                "import { buildReleaseProperties } from '../../shared/appIdentity';\n"
                "posthog.register(buildReleaseProperties(getReleaseInfo()));\n"
            ),
        }

        self.assertFalse(CHECKS._register_call_covers_release_properties(added_lines_by_file))

    def test_generic_function_declaration_with_release_keys_passes(self):
        added_lines_by_file = {
            "src/shared/appIdentity.ts": (
                "export function toAppIdentitySuperProperties<T extends ReleaseInfo>(source: T) {\n"
                "  return { $app_version: source.version, $app_build: source.build };\n"
                "}\n"
            ),
            "src/renderer/src/main.tsx": (
                "import { toAppIdentitySuperProperties } from '../../shared/appIdentity';\n"
                "posthog.register(toAppIdentitySuperProperties(getReleaseInfo()));\n"
            ),
        }

        self.assertTrue(CHECKS._register_call_covers_release_properties(added_lines_by_file))

    def test_overload_signature_followed_by_real_implementation_passes(self):
        # the first match is a body-less TS overload signature; the check must keep
        # looking for a later match with a real '{' implementation instead of stopping.
        added_lines_by_file = {
            "src/shared/appIdentity.ts": (
                "export function toAppIdentitySuperProperties(source: ReleaseInfo): SuperProperties;\n"
                "export function toAppIdentitySuperProperties(source: ReleaseInfo) {\n"
                "  return { $app_version: source.version, $app_build: source.build };\n"
                "}\n"
            ),
            "src/renderer/src/main.tsx": (
                "import { toAppIdentitySuperProperties } from '../../shared/appIdentity';\n"
                "posthog.register(toAppIdentitySuperProperties(getReleaseInfo()));\n"
            ),
        }

        self.assertTrue(CHECKS._register_call_covers_release_properties(added_lines_by_file))


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
