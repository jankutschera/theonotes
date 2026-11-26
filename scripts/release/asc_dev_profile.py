#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

"""Makes sure the dev identity has an App ID and a Mac development profile in the publishing team, headlessly.

Why this exists: `xcodebuild -allowProvisioningUpdates` with the App Store Connect API key cannot create the profile of a NEW
App ID ("Authentication failed ... bearer token", measured 2026-10-31), although the same key creates App IDs, capabilities
and profiles through the public API. This script does exactly this and nothing else:

  1. the App ID DEV_APP_ID (created when missing) with the iCloud and Push Notifications capabilities;
  2. a MAC_APP_DEVELOPMENT profile named PROFILE_NAME for that App ID, the newest development certificate and every enabled
     macOS device of the team. An existing profile is deleted first only when ALL of these hold: it is listed under that App
     ID, its name is PROFILE_NAME and its type is MAC_APP_DEVELOPMENT. Production App IDs, Developer ID or distribution
     profiles and profiles of any other name are never touched;
  3. the profile is installed in ~/Library/Developer/Xcode/UserData/Provisioning Profiles/<uuid>.provisionprofile; older local
     copies of the same profile (same name, same App ID) are removed so that copies do not pile up.

It is restricted to the exact App ID and the exact profile name below: other arguments are refused (exit 2).
What it cannot do: associate an iCloud container with the App ID. The public API has no endpoint for it; that is a click in
the portal (docs/release/team-migration.md, "Final session"). The result line says whether the profile lists the container.

Usage: scripts/release/asc_dev_profile.py [com.truebrewbirdie.theonotes.dev "Theo Notes Mac Dev Development" iCloud.com.truebrewbirdie.theonotes]
Environment: ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID (never printed). Output: one JSON line, no secrets.
Errors print the HTTP status and Apple's error codes only, never the response body.
Exit 0 when the profile is installed (whether or not it lists the container), 1 on an API error, 2 on bad usage.
"""

import base64
import json
import os
import plistlib
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

API = "https://api.appstoreconnect.apple.com"
DEV_APP_ID = "com.truebrewbirdie.theonotes.dev"
PROFILE_NAME = "Theo Notes Mac Dev Development"
PROFILE_TYPE = "MAC_APP_DEVELOPMENT"
CONTAINER = "iCloud.com.truebrewbirdie.theonotes"
PROFILES_DIR = Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"


class ApiError(Exception):
    """An API failure described by its status and error codes only (no response body)."""


def b64(data: bytes) -> bytes:
    return base64.urlsafe_b64encode(data).rstrip(b"=")


def der_to_raw(der: bytes) -> bytes:
    """ECDSA DER signature to the r||s form a JWT needs."""
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    rl = der[i + 1]
    r = der[i + 2 : i + 2 + rl]
    j = i + 2 + rl
    sl = der[j + 1]
    s = der[j + 2 : j + 2 + sl]
    return r.lstrip(b"\x00").rjust(32, b"\x00") + s.lstrip(b"\x00").rjust(32, b"\x00")


def token() -> str:
    now = int(time.time())
    header = {"alg": "ES256", "kid": os.environ["ASC_KEY_ID"], "typ": "JWT"}
    payload = {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}
    signing = b64(json.dumps(header).encode()) + b"." + b64(json.dumps(payload).encode())
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", os.environ["ASC_KEY_PATH"]], input=signing, capture_output=True, check=True).stdout
    return (signing + b"." + b64(der_to_raw(der))).decode()


def error_codes(body: bytes) -> list[str]:
    """Apple's error codes from an error body; nothing else of the body is kept."""
    try:
        return [str(e.get("code", "?"))[:80] for e in json.loads(body).get("errors", [])][:5]
    except (ValueError, AttributeError, TypeError):
        return []


def call(method: str, path: str, body: dict | None = None):
    request = urllib.request.Request(
        API + path,
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        codes = error_codes(error.read())
        raise ApiError(f"App Store Connect API {method} {path.split('?')[0]}: HTTP {error.code}, error code(s) {codes or 'none'}") from None


def ensure_app_id() -> str:
    found = call("GET", f"/v1/bundleIds?filter[identifier]={DEV_APP_ID}&limit=50")["data"]
    found = [item for item in found if item["attributes"]["identifier"] == DEV_APP_ID]
    if found:
        app_id = found[0]["id"]
    else:
        app_id = call("POST", "/v1/bundleIds", {"data": {"type": "bundleIds", "attributes": {
            "identifier": DEV_APP_ID, "name": "Theo Notes Mac Dev", "platform": "UNIVERSAL"}}})["data"]["id"]
    have = {c["attributes"]["capabilityType"] for c in call("GET", f"/v1/bundleIds/{app_id}/bundleIdCapabilities")["data"]}
    wanted = {
        "ICLOUD": {"settings": [{"key": "ICLOUD_VERSION", "options": [{"key": "XCODE_6", "enabled": True}]}]},
        "PUSH_NOTIFICATIONS": {},
    }
    for kind, extra in wanted.items():
        if kind not in have:
            call("POST", "/v1/bundleIdCapabilities", {"data": {"type": "bundleIdCapabilities", "attributes": {"capabilityType": kind, **extra},
                 "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": app_id}}}}})
    return app_id


def delete_own_old_profiles(app_id: str) -> int:
    """Deletes the earlier development profile(s) of this App ID with this name; returns how many."""
    deleted = 0
    for profile in call("GET", f"/v1/bundleIds/{app_id}/profiles?limit=200")["data"]:
        attributes = profile["attributes"]
        if attributes["name"] == PROFILE_NAME and attributes["profileType"] == PROFILE_TYPE:
            call("DELETE", f"/v1/profiles/{profile['id']}")
            deleted += 1
    return deleted


def decode_profile(content: bytes) -> dict:
    return plistlib.loads(subprocess.run(["security", "cms", "-D"], input=content, capture_output=True, check=True).stdout)


def remove_stale_local_copies(directory: Path = None) -> int:
    """Removes installed copies of this profile (same name AND the dev App ID); nothing else in the folder is touched."""
    directory = directory or PROFILES_DIR
    removed = 0
    if not directory.is_dir():
        return 0
    for path in directory.glob("*.provisionprofile"):
        try:
            decoded = decode_profile(path.read_bytes())
        except (subprocess.CalledProcessError, ValueError, OSError):
            continue
        identifier = str(decoded.get("Entitlements", {}).get("com.apple.application-identifier", ""))
        if decoded.get("Name") == PROFILE_NAME and identifier.endswith("." + DEV_APP_ID):
            path.unlink()
            removed += 1
    return removed


def main(argv: list[str]) -> int:
    if argv not in ([], [DEV_APP_ID, PROFILE_NAME, CONTAINER]):
        print(f"refused: this script only handles {DEV_APP_ID!r}, profile {PROFILE_NAME!r}, container {CONTAINER!r}", file=sys.stderr)
        return 2
    if not all(os.environ.get(k) for k in ("ASC_KEY_PATH", "ASC_KEY_ID", "ASC_ISSUER_ID")):
        print(__doc__, file=sys.stderr)
        return 2
    try:
        app_id = ensure_app_id()
        certificates = [c for c in call("GET", "/v1/certificates?limit=200")["data"] if c["attributes"]["certificateType"] in ("DEVELOPMENT", "MAC_APP_DEVELOPMENT")]
        if not certificates:
            raise ApiError("no development certificate in the team")
        certificate = max(certificates, key=lambda c: c["attributes"]["expirationDate"])
        devices = [d for d in call("GET", "/v1/devices?limit=200")["data"] if d["attributes"]["platform"] == "MAC_OS" and d["attributes"]["status"] == "ENABLED"]
        if not devices:
            raise ApiError("no enabled macOS device in the team")
        delete_own_old_profiles(app_id)
        created = call("POST", "/v1/profiles", {"data": {"type": "profiles", "attributes": {"name": PROFILE_NAME, "profileType": PROFILE_TYPE},
            "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": app_id}},
                              "certificates": {"data": [{"type": "certificates", "id": certificate["id"]}]},
                              "devices": {"data": [{"type": "devices", "id": d["id"]} for d in devices]}}}})["data"]
    except ApiError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    content = base64.b64decode(created["attributes"]["profileContent"])
    decoded = decode_profile(content)
    PROFILES_DIR.mkdir(parents=True, exist_ok=True)
    remove_stale_local_copies()
    (PROFILES_DIR / f"{decoded['UUID']}.provisionprofile").write_bytes(content)
    granted = decoded.get("Entitlements", {})
    containers = granted.get("com.apple.developer.icloud-container-identifiers", [])
    print(json.dumps({
        "appId": DEV_APP_ID, "profileName": PROFILE_NAME, "profileUUID": decoded["UUID"], "team": decoded["TeamIdentifier"][0],
        "listsContainer": CONTAINER in containers if isinstance(containers, list) else False,
        "containers": containers if isinstance(containers, list) else [],
        "applicationIdentifier": granted.get("com.apple.application-identifier"),
        "keychainGroups": granted.get("keychain-access-groups"),
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
