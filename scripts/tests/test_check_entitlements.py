#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

"""Tests for scripts/release/check_entitlements.py. Run: python3 -I scripts/tests/test_check_entitlements.py

Builds fake bundles in a temp directory and signs them ad hoc with `codesign` (a copy of a small system tool as the
main executable). Nothing is launched.
"""

import importlib.util
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent.parent
spec = importlib.util.spec_from_file_location("check_entitlements", ROOT / "scripts" / "release" / "check_entitlements.py")
chk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(chk)

APP_KEYS = {
    "keychain-access-groups": ["TEAM.com.example.app"],
    "com.apple.security.application-groups": ["TEAM.com.example.notes"],
    "com.apple.security.automation.apple-events": True,
    "com.apple.security.device.audio-input": True,
}
APPEX_KEYS = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.application-groups": ["TEAM.com.example.notes"],
    "com.apple.security.files.user-selected.read-only": True,
}
SOURCE_TOOL = Path("/usr/bin/true")

CONTAINER = "iCloud.com.example.notes"
ICLOUD_KEYS = {
    "com.apple.developer.icloud-container-identifiers": [CONTAINER],
    "com.apple.developer.icloud-services": ["CloudKit"],
    "com.apple.developer.icloud-container-environment": "Production",
    "aps-environment": "production",
}
GOOD_PROFILE = {
    "Entitlements": {
        "com.apple.developer.icloud-container-identifiers": [CONTAINER],
        "com.apple.developer.icloud-services": ["CloudKit"],
        "aps-environment": "production",
    }
}


def sign(path: Path, entitlements: dict | None, runtime: bool = True) -> None:
    command = ["/usr/bin/codesign", "-s", "-", "-f"]
    if runtime:
        command += ["-o", "runtime"]
    holder = None
    if entitlements is not None:
        holder = path.parent / (path.name + ".entitlements.plist")
        holder.write_bytes(plistlib.dumps(entitlements))
        command += ["--entitlements", str(holder)]
    subprocess.run([*command, str(path)], check=True, capture_output=True)
    if holder:
        holder.unlink()


def make_bundle(root: Path, name: str, executable: str, identifier: str) -> Path:
    bundle = root / name
    (bundle / "Contents" / "MacOS").mkdir(parents=True)
    shutil.copy(SOURCE_TOOL, bundle / "Contents" / "MacOS" / executable)
    (bundle / "Contents" / "Info.plist").write_bytes(
        plistlib.dumps({"CFBundleIdentifier": identifier, "CFBundleExecutable": executable, "CFBundlePackageType": "APPL"})
    )
    return bundle


def build_app(root: Path, app=APP_KEYS, appex=APPEX_KEYS, helper=None, app_runtime=True) -> Path:
    app_dir = make_bundle(root, "Fake.app", "Fake", "com.example.app")
    (app_dir / "Contents" / "Helpers").mkdir()
    helper_path = app_dir / "Contents" / "Helpers" / "theonotes"
    shutil.copy(SOURCE_TOOL, helper_path)
    sign(helper_path, helper)
    appex_dir = make_bundle(app_dir / "Contents" / "PlugIns", "TheoNotesMacShare.appex", "Share", "com.example.app.share")
    sign(appex_dir, appex)
    sign(app_dir, app, runtime=app_runtime)
    return app_dir


def with_profile(app: Path) -> Path:
    """Marks the bundle as carrying an embedded profile; the decoded content comes from `loader`."""
    (app / "Contents" / "embedded.provisionprofile").write_bytes(b"synthetic")
    return app


def loader(profile: dict):
    return lambda path: profile


class CheckEntitlementsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="check-entitlements-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def test_expected_set_passes(self):
        self.assertEqual(chk.check(build_app(self.tmp)), [])

    def test_profile_keys_are_fine_on_app_and_extension(self):
        profile = {"com.apple.application-identifier": "TEAM.com.example.app", "com.apple.developer.team-identifier": "TEAM"}
        app = build_app(self.tmp, app={**APP_KEYS, **profile}, appex={**APPEX_KEYS, **profile})
        self.assertEqual(chk.check(app), [])

    def test_get_task_allow_is_refused_everywhere(self):
        flag = {"com.apple.security.get-task-allow": True}
        app = build_app(self.tmp, app={**APP_KEYS, **flag}, appex={**APPEX_KEYS, **flag}, helper=flag)
        problems = chk.check(app)
        self.assertEqual(sum("get-task-allow" in p for p in problems), 3, problems)
        # a development-signed local build may opt in
        self.assertEqual(chk.check(app, allow_get_task_allow=True), [])

    def test_helper_must_not_claim_a_restricted_entitlement(self):
        app = build_app(self.tmp, helper={"com.apple.application-identifier": "TEAM.com.example.app.cli"})
        problems = chk.check(app)
        self.assertTrue(any(p.startswith("helper: restricted entitlement") for p in problems), problems)

    def test_helper_with_any_other_entitlement_is_refused(self):
        app = build_app(self.tmp, helper={"com.apple.security.app-sandbox": True})
        self.assertIn("helper: unexpected entitlement com.apple.security.app-sandbox", chk.check(app))

    def test_app_must_not_be_sandboxed_or_use_runtime_exceptions(self):
        app = build_app(
            self.tmp,
            app={**APP_KEYS, "com.apple.security.app-sandbox": True, "com.apple.security.cs.allow-jit": True},
        )
        problems = chk.check(app)
        self.assertIn("app: unexpected entitlement com.apple.security.app-sandbox", problems)
        self.assertIn("app: unexpected entitlement com.apple.security.cs.allow-jit", problems)

    def test_missing_entitlement_is_named(self):
        keys = {k: v for k, v in APP_KEYS.items() if k != "com.apple.security.device.audio-input"}
        self.assertIn("app: missing entitlement com.apple.security.device.audio-input", chk.check(build_app(self.tmp, app=keys)))

    def test_extension_loses_its_sandbox(self):
        keys = {k: v for k, v in APPEX_KEYS.items() if k != "com.apple.security.app-sandbox"}
        self.assertIn(
            "share extension: missing entitlement com.apple.security.app-sandbox", chk.check(build_app(self.tmp, appex=keys))
        )

    def test_hardened_runtime_flag_is_required(self):
        problems = chk.check(build_app(self.tmp, app_runtime=False))
        self.assertIn("app: hardened runtime flag (0x10000) not set", problems)

    def test_unsigned_item_is_reported(self):
        app = build_app(self.tmp)
        helper = app / "Contents" / "Helpers" / "theonotes"
        subprocess.run(["/usr/bin/codesign", "--remove-signature", str(helper)], check=True, capture_output=True)
        self.assertIn("helper: not signed", chk.check(app))

    def test_missing_item_is_reported(self):
        app = build_app(self.tmp)
        (app / "Contents" / "Helpers" / "theonotes").unlink()
        self.assertTrue(any(p.startswith("helper:") and "does not exist" in p for p in chk.check(app)))

    # --icloud (CloudKit plan Task 12): the same bundle, plus the CloudKit entitlements and a profile listing the container.

    def icloud_app(self, keys=None, profile_file=True):
        root = Path(tempfile.mkdtemp(dir=self.tmp))
        app = build_app(root, app={**APP_KEYS, **(ICLOUD_KEYS if keys is None else keys)})
        return with_profile(app) if profile_file else app

    def test_default_mode_refuses_icloud_keys_it_does_not_expect(self):
        problems = chk.check(self.icloud_app())
        self.assertIn("app: unexpected entitlement com.apple.developer.icloud-container-identifiers", problems)
        self.assertIn("app: unexpected entitlement aps-environment", problems)

    def test_default_mode_is_unchanged_without_the_flag(self):
        self.assertEqual(chk.check(build_app(self.tmp)), [])

    def test_icloud_mode_fails_without_the_keys(self):
        problems = chk.check(build_app(self.tmp), icloud_container=CONTAINER, read_profile=loader(GOOD_PROFILE))
        for key in ICLOUD_KEYS:
            self.assertIn(f"app: missing entitlement {key}", problems)
        self.assertIn("app: no Contents/embedded.provisionprofile (the iCloud entitlements need a profile that lists the container)", problems)

    def test_icloud_mode_passes_on_a_good_bundle(self):
        self.assertEqual(chk.check(self.icloud_app(), icloud_container=CONTAINER, read_profile=loader(GOOD_PROFILE)), [])

    def test_icloud_mode_accepts_the_macos_name_of_the_push_entitlement(self):
        # A Mac signature and a Mac profile carry com.apple.developer.aps-environment; Xcode drops the iOS name there.
        mac = "com.apple.developer.aps-environment"
        keys = {k: v for k, v in ICLOUD_KEYS.items() if k != "aps-environment"} | {mac: "production"}
        profile = {"Entitlements": {k: v for k, v in GOOD_PROFILE["Entitlements"].items() if k != "aps-environment"} | {mac: "production"}}
        self.assertEqual(chk.check(self.icloud_app(keys), icloud_container=CONTAINER, read_profile=loader(profile)), [])
        wrong = {**keys, mac: "development"}
        problems = chk.check(self.icloud_app(wrong), icloud_container=CONTAINER, read_profile=loader(profile))
        self.assertTrue(any("aps-environment must be 'production'" in p for p in problems), problems)
        # without --icloud the macOS name is as unexpected as the iOS one
        self.assertIn(f"app: unexpected entitlement {mac}", chk.check(self.icloud_app(keys)))

    def test_icloud_mode_names_a_wrong_container(self):
        keys = {**ICLOUD_KEYS, "com.apple.developer.icloud-container-identifiers": ["iCloud.com.example.other"]}
        problems = chk.check(self.icloud_app(keys), icloud_container=CONTAINER, read_profile=loader(GOOD_PROFILE))
        self.assertIn(f"app: com.apple.developer.icloud-container-identifiers must be exactly [{CONTAINER!r}], is ['iCloud.com.example.other']", problems)

    def test_icloud_mode_wants_cloudkit_service_only(self):
        keys = {**ICLOUD_KEYS, "com.apple.developer.icloud-services": ["CloudKit", "CloudDocuments"]}
        problems = chk.check(self.icloud_app(keys), icloud_container=CONTAINER, read_profile=loader(GOOD_PROFILE))
        self.assertTrue(any("icloud-services must be exactly ['CloudKit']" in p for p in problems), problems)

    def test_icloud_mode_wants_production_environment_and_push_for_a_release(self):
        keys = {**ICLOUD_KEYS, "com.apple.developer.icloud-container-environment": "Development", "aps-environment": "development"}
        problems = chk.check(self.icloud_app(keys), icloud_container=CONTAINER, read_profile=loader(GOOD_PROFILE))
        self.assertTrue(any("icloud-container-environment must be 'Production'" in p for p in problems), problems)
        self.assertTrue(any("aps-environment must be 'production'" in p for p in problems), problems)
        # a development-signed local build may use the Development values
        self.assertEqual(
            chk.check(self.icloud_app(keys), allow_get_task_allow=True, icloud_container=CONTAINER, read_profile=loader(GOOD_PROFILE)), []
        )

    def test_icloud_mode_checks_the_profile_lists_the_container(self):
        other = {"Entitlements": {**GOOD_PROFILE["Entitlements"], "com.apple.developer.icloud-container-identifiers": ["iCloud.com.example.other"]}}
        problems = chk.check(self.icloud_app(), icloud_container=CONTAINER, read_profile=loader(other))
        self.assertIn(f"app: embedded profile does not list the container {CONTAINER}", problems)

    def test_icloud_mode_checks_the_profile_covers_cloudkit_and_push(self):
        thin = {"Entitlements": {"com.apple.developer.icloud-container-identifiers": [CONTAINER]}}
        problems = chk.check(self.icloud_app(), icloud_container=CONTAINER, read_profile=loader(thin))
        self.assertIn("app: embedded profile does not allow the CloudKit service", problems)
        self.assertIn("app: embedded profile has no aps-environment", problems)
        star = {"Entitlements": {**GOOD_PROFILE["Entitlements"], "com.apple.developer.icloud-services": "*"}}
        self.assertEqual(chk.check(self.icloud_app(), icloud_container=CONTAINER, read_profile=loader(star)), [])

    def test_icloud_mode_reports_an_unreadable_profile(self):
        def broken(path):
            raise ValueError("cannot decode")

        problems = chk.check(self.icloud_app(), icloud_container=CONTAINER, read_profile=broken)
        self.assertIn("app: embedded profile unreadable: cannot decode", problems)

    def test_icloud_keys_on_the_extension_are_still_refused(self):
        app = build_app(self.tmp, app={**APP_KEYS, **ICLOUD_KEYS}, appex={**APPEX_KEYS, **ICLOUD_KEYS})
        with_profile(app)
        problems = chk.check(app, icloud_container=CONTAINER, read_profile=loader(GOOD_PROFILE))
        self.assertIn("share extension: unexpected entitlement aps-environment", problems)

    def test_command_line_icloud_mode_fails_without_the_keys_and_default_passes(self):
        app = build_app(self.tmp)
        script = ROOT / "scripts" / "release" / "check_entitlements.py"
        base = [sys.executable, "-I", str(script), str(app)]
        self.assertEqual(subprocess.run(base, capture_output=True).returncode, 0)
        failed = subprocess.run([*base, "--icloud", "--container", CONTAINER], capture_output=True)
        self.assertEqual(failed.returncode, 1)
        self.assertIn(b"missing entitlement com.apple.developer.icloud-container-identifiers", failed.stderr)

    def test_command_line_icloud_mode_needs_a_container(self):
        app = build_app(self.tmp)
        script = ROOT / "scripts" / "release" / "check_entitlements.py"
        env_free = [sys.executable, "-I", str(script), str(app), "--icloud"]
        # config/release.env has an empty container until the account exists: nothing to check against.
        done = subprocess.run(env_free, capture_output=True, env={"THEONOTES_RELEASE_ENV": str(self.tmp / "none.env"), "PATH": "/usr/bin:/bin"})
        self.assertEqual(done.returncode, 2)
        self.assertIn(b"no container", done.stderr)


if __name__ == "__main__":
    unittest.main()
