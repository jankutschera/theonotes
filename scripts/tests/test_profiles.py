#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

"""Tests for the pure rules of scripts/release/profiles.py. Run: python3 -I scripts/tests/test_profiles.py"""

import importlib.util
import sys
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent.parent
spec = importlib.util.spec_from_file_location("profiles", ROOT / "scripts" / "release" / "profiles.py")
profiles = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profiles)

TEAM = "ABCDE12345"
NOW = datetime(2026, 10, 28, tzinfo=timezone.utc)

SIGNED = {
    "com.apple.application-identifier": f"{TEAM}.com.example.app",
    "com.apple.developer.team-identifier": TEAM,
    "keychain-access-groups": [f"{TEAM}.com.example.app"],
    "com.apple.security.application-groups": [f"{TEAM}.com.example.notes"],
}


def profile(**overrides) -> dict:
    base = {
        "Name": "Test",
        "TeamIdentifier": [TEAM],
        "ExpirationDate": NOW + timedelta(days=100),
        "Entitlements": {
            "com.apple.application-identifier": f"{TEAM}.com.example.app",
            "com.apple.developer.team-identifier": TEAM,
            "keychain-access-groups": [f"{TEAM}.*"],
        },
    }
    base.update(overrides)
    return base


class ProfileRules(unittest.TestCase):
    def test_matching_profile_has_no_problems(self):
        self.assertEqual(profiles.problems(profile(), SIGNED, TEAM, NOW), [])

    def test_wildcard_group_covers_the_keychain_group(self):
        self.assertEqual(profiles.problems(profile(), SIGNED, TEAM, NOW), [])

    def test_keychain_group_outside_the_profile_is_reported(self):
        signed = dict(SIGNED, **{"keychain-access-groups": ["OTHERTEAM1.com.example.app"]})
        found = profiles.problems(profile(), signed, TEAM, NOW)
        self.assertTrue(any("keychain-access-groups" in p for p in found), found)

    def test_application_identifier_mismatch_is_reported(self):
        signed = dict(SIGNED, **{"com.apple.application-identifier": f"{TEAM}.com.example.other"})
        found = profiles.problems(profile(), signed, TEAM, NOW)
        self.assertTrue(any("application-identifier" in p for p in found), found)

    def test_expired_profile_is_reported(self):
        found = profiles.problems(profile(ExpirationDate=NOW - timedelta(days=1)), SIGNED, TEAM, NOW)
        self.assertTrue(any("expired" in p for p in found), found)

    def test_profile_of_another_team_is_reported(self):
        found = profiles.problems(profile(TeamIdentifier=["ZZZZZZZZZZ"]), SIGNED, TEAM, NOW)
        self.assertTrue(any("team" in p for p in found), found)

    def test_development_profile_with_devices_is_reported(self):
        found = profiles.problems(profile(ProvisionedDevices=["00008103-000000000000001E"]), SIGNED, TEAM, NOW)
        self.assertTrue(any("development profile" in p for p in found), found)

    def test_unrestricted_entitlements_need_no_profile_entry(self):
        # application-groups is not restricted: it is absent from the profile above and still fine.
        self.assertEqual(profiles.problems(profile(), SIGNED, TEAM, NOW), [])

    def test_missing_embedded_profile_is_reported(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            found = profiles.verify(Path(tmp) / "X.app", TEAM)
        self.assertTrue(any("embedded.provisionprofile" in p for p in found), found)


if __name__ == "__main__":
    unittest.main()
