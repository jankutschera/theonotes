#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

"""Exercise installer checks with fake commands; never contact a device."""
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class InstallIOSChecks(unittest.TestCase):
    def test_rejects_debug_and_wrong_entitlements_before_device_access(self):
        with tempfile.TemporaryDirectory(prefix="theo-ios-install-") as directory:
            root = Path(directory)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            app = root / "dd/Build/Products/Production-iphoneos/TheoNotesIOS.app"
            app.mkdir(parents=True)
            log, entitlements = root / "calls", root / "entitlements.plist"
            config = dict(line.split("=", 1) for line in (ROOT / "config/release.env").read_text().splitlines())
            bundle = (ROOT / "config/identity.env").read_text().split("=", 1)[1].strip()
            team = config["THEONOTES_TEAM_ID"]
            info = {"CFBundleIdentifier": bundle + ".ios", "THEONOTES_SyncSetupAvailable": "YES", "THEONOTES_ICloudSyncAvailable": "YES"}
            signed = {"application-identifier": team + "." + bundle + ".ios",
                      "keychain-access-groups": [team + "." + bundle + ".ios", team + "." + bundle],
                      "com.apple.developer.icloud-container-identifiers": [config["THEONOTES_CLOUDKIT_CONTAINER"]],
                      "com.apple.developer.icloud-container-environment": "Production", "aps-environment": "development"}
            for command in ("xcodegen", "xcodebuild", "xcrun"):
                stub = bin_dir / command
                stub.write_text('#!/bin/sh\nprintf "%s\\n" "$(basename "$0") $*" >> "$B5_TEST_LOG"\n')
                stub.chmod(0o755)
            codesign = bin_dir / "codesign"
            codesign.write_text('#!/bin/sh\nif [ "$1" = "-d" ]; then cat "$B5_TEST_ENT"; fi\n')
            codesign.chmod(0o755)
            env = dict(os.environ, PATH=str(bin_dir) + ":" + os.environ["PATH"],
                       BAERCHEN_IOS_BUILD_DIR=str(root / "dd"), B5_TEST_LOG=str(log), B5_TEST_ENT=str(entitlements))

            def run():
                (app / "Info.plist").write_bytes(plistlib.dumps(info))
                entitlements.write_bytes(plistlib.dumps(signed))
                log.write_text("")
                result = subprocess.run(["bash", str(ROOT / "scripts/install-ios.sh"), "synthetic-device"],
                                        cwd=ROOT, env=env, capture_output=True, text=True)
                return result, log.read_text()

            result, calls = run()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("-configuration Production", calls)
            self.assertIn("devicectl device install app", calls)
            info["CFBundleIdentifier"] = bundle + ".dev.ios"
            result, calls = run()
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("devicectl", calls)
            info["CFBundleIdentifier"] = bundle + ".ios"
            signed["keychain-access-groups"] = [team + "." + bundle + ".dev"]
            result, calls = run()
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("devicectl", calls)


if __name__ == "__main__":
    unittest.main()
