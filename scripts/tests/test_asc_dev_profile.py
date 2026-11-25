#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

"""Tests for scripts/release/asc_dev_profile.py (REN2-R66). Run: python3 -I scripts/tests/test_asc_dev_profile.py

Every API call is mocked: nothing here reaches Apple, reads the API key or touches the real provisioning-profile folder.
"""

import importlib.util
import io
import json
import sys
import tempfile
import unittest
import urllib.error
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent.parent
spec = importlib.util.spec_from_file_location("asc_dev_profile", ROOT / "scripts" / "release" / "asc_dev_profile.py")
asc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(asc)

ENV = {"ASC_KEY_PATH": "/nonexistent/key.p8", "ASC_KEY_ID": "KEYID", "ASC_ISSUER_ID": "ISSUER"}


def profile_entry(identifier, name, kind):
    return {"id": identifier, "attributes": {"name": name, "profileType": kind}}


class FakeApi:
    """A scripted App Store Connect: records every call, answers the few paths the script uses."""

    def __init__(self, profiles):
        self.calls = []
        self.profiles = profiles

    def __call__(self, method, path, body=None):
        self.calls.append((method, path.split("?")[0]))
        if method == "GET" and path.startswith("/v1/bundleIds?filter"):
            return {"data": [{"id": "APP1", "attributes": {"identifier": asc.DEV_APP_ID}}]}
        if method == "GET" and path.endswith("/bundleIdCapabilities"):
            return {"data": [{"attributes": {"capabilityType": "ICLOUD"}}, {"attributes": {"capabilityType": "PUSH_NOTIFICATIONS"}}]}
        if method == "GET" and path.startswith("/v1/certificates"):
            return {"data": [{"id": "C1", "attributes": {"certificateType": "DEVELOPMENT", "expirationDate": "2027-01-01"}},
                             {"id": "C2", "attributes": {"certificateType": "DEVELOPER_ID_APPLICATION", "expirationDate": "2030-01-01"}}]}
        if method == "GET" and path.startswith("/v1/devices"):
            return {"data": [{"id": "D1", "attributes": {"platform": "MAC_OS", "status": "ENABLED"}},
                             {"id": "D2", "attributes": {"platform": "IOS", "status": "ENABLED"}}]}
        if method == "GET" and path.startswith("/v1/bundleIds/APP1/profiles"):
            return {"data": self.profiles}
        if method == "DELETE":
            return {}
        if method == "POST" and path == "/v1/profiles":
            self.created = body
            return {"data": {"attributes": {"profileContent": "AAAA"}}}
        raise AssertionError(f"unexpected call {method} {path}")


class AscDevProfileTests(unittest.TestCase):
    def run_main(self, argv, api):
        out, err = io.StringIO(), io.StringIO()
        decoded = {"UUID": "U-1", "TeamIdentifier": ["Q446J364FH"], "Name": asc.PROFILE_NAME,
                   "Entitlements": {"com.apple.application-identifier": "Q446J364FH." + asc.DEV_APP_ID,
                                    "com.apple.developer.icloud-container-identifiers": []}}
        with tempfile.TemporaryDirectory() as folder, mock.patch.dict("os.environ", ENV), \
                mock.patch.object(asc, "call", api), mock.patch.object(asc, "decode_profile", return_value=decoded), \
                mock.patch.object(asc, "PROFILES_DIR", Path(folder)), redirect_stdout(out), redirect_stderr(err):
            code = asc.main(argv)
            installed = sorted(p.name for p in Path(folder).iterdir())
        return code, out.getvalue(), err.getvalue(), installed

    def test_other_app_ids_names_and_containers_are_refused_before_any_call(self):
        api = FakeApi([])
        for argv in (["com.truebrewbirdie.theonotes", asc.PROFILE_NAME, asc.CONTAINER],
                     [asc.DEV_APP_ID, "Theo Notes Mac Developer ID", asc.CONTAINER],
                     [asc.DEV_APP_ID, asc.PROFILE_NAME, "iCloud.com.example.other"],
                     [asc.DEV_APP_ID]):
            code, out, err, _ = self.run_main(argv, api)
            self.assertEqual(code, 2, argv)
            self.assertIn("refused", err)
        self.assertEqual(api.calls, [], "a refused run must not reach the API")

    def test_only_the_development_profile_of_that_app_id_with_that_name_is_deleted(self):
        api = FakeApi([
            profile_entry("OWN", asc.PROFILE_NAME, "MAC_APP_DEVELOPMENT"),
            profile_entry("SAMENAME_DEVID", asc.PROFILE_NAME, "MAC_APP_DIRECT"),
            profile_entry("SAMENAME_STORE", asc.PROFILE_NAME, "MAC_APP_STORE"),
            profile_entry("OTHERNAME", "Theo Notes Mac Developer ID", "MAC_APP_DIRECT"),
            profile_entry("OTHERDEV", "Some other development profile", "MAC_APP_DEVELOPMENT"),
        ])
        code, out, err, installed = self.run_main([], api)
        self.assertEqual(code, 0, err)
        deletes = [call for call in api.calls if call[0] == "DELETE"]
        self.assertEqual(deletes, [("DELETE", "/v1/profiles/OWN")])
        self.assertEqual(installed, ["U-1.provisionprofile"])
        result = json.loads(out)
        self.assertEqual(result["appId"], asc.DEV_APP_ID)
        self.assertFalse(result["listsContainer"])

    def test_the_created_profile_is_a_development_profile_for_the_dev_app_id_only(self):
        api = FakeApi([])
        self.run_main([], api)
        data = api.created["data"]
        self.assertEqual(data["attributes"], {"name": asc.PROFILE_NAME, "profileType": "MAC_APP_DEVELOPMENT"})
        self.assertEqual(data["relationships"]["bundleId"]["data"]["id"], "APP1")
        self.assertEqual(data["relationships"]["certificates"]["data"], [{"type": "certificates", "id": "C1"}], "development certificate only")
        self.assertEqual([d["id"] for d in data["relationships"]["devices"]["data"]], ["D1"], "macOS devices only")

    def test_an_error_prints_status_and_codes_never_the_body(self):
        secret = "SECRET-DETAIL-eyJhbGciOiJFUzI1NiJ9"
        body = json.dumps({"errors": [{"status": "403", "code": "FORBIDDEN_ERROR", "title": secret, "detail": secret}]}).encode()
        error = urllib.error.HTTPError("https://x", 403, "Forbidden", {}, io.BytesIO(body))
        with mock.patch.dict("os.environ", ENV), mock.patch.object(asc, "token", return_value="T"), \
                mock.patch("urllib.request.urlopen", side_effect=error):
            with self.assertRaises(asc.ApiError) as raised:
                asc.call("GET", "/v1/certificates?limit=200")
        message = str(raised.exception)
        self.assertIn("HTTP 403", message)
        self.assertIn("FORBIDDEN_ERROR", message)
        self.assertNotIn(secret, message)

    def test_a_failure_in_main_exits_1_without_the_body(self):
        def failing(method, path, body=None):
            raise asc.ApiError("App Store Connect API GET /v1/bundleIds: HTTP 401, error code(s) ['NOT_AUTHORIZED']")

        code, out, err, _ = self.run_main([], failing)
        self.assertEqual(code, 1)
        self.assertIn("HTTP 401", err)
        self.assertEqual(out, "")

    def test_unreadable_error_bodies_are_handled(self):
        self.assertEqual(asc.error_codes(b"<html>not json</html>"), [])
        self.assertEqual(asc.error_codes(b'{"errors": [{"code": "A"}, {"code": "B"}]}'), ["A", "B"])

    def test_stale_local_copies_are_removed_only_for_this_profile(self):
        def fake_decode(content):
            return json.loads(content)

        files = {
            "mine-old.provisionprofile": {"Name": asc.PROFILE_NAME, "Entitlements": {"com.apple.application-identifier": "Q446J364FH." + asc.DEV_APP_ID}},
            "devid.provisionprofile": {"Name": "Theo Notes Mac Developer ID", "Entitlements": {"com.apple.application-identifier": "Q446J364FH.com.truebrewbirdie.theonotes"}},
            "same-name-other-app.provisionprofile": {"Name": asc.PROFILE_NAME, "Entitlements": {"com.apple.application-identifier": "Q446J364FH.com.truebrewbirdie.theonotes"}},
            "managed.provisionprofile": {"Name": "Mac Team Provisioning Profile: com.truebrewbirdie.theonotes", "Entitlements": {"com.apple.application-identifier": "Q446J364FH.com.truebrewbirdie.theonotes"}},
        }
        with tempfile.TemporaryDirectory() as folder, mock.patch.object(asc, "decode_profile", side_effect=fake_decode):
            directory = Path(folder)
            for name, content in files.items():
                (directory / name).write_text(json.dumps(content))
            (directory / "ios.mobileprovision").write_text("{}")
            self.assertEqual(asc.remove_stale_local_copies(directory), 1)
            self.assertEqual(sorted(p.name for p in directory.iterdir()),
                             ["devid.provisionprofile", "ios.mobileprovision", "managed.provisionprofile", "same-name-other-app.provisionprofile"])


if __name__ == "__main__":
    unittest.main()
