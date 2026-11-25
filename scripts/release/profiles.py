#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

"""Provisioning-profile checks for the release scripts (REL-R67). Static: nothing in a bundle is executed.

    python3 -I scripts/release/profiles.py find <profile name>          path of an installed profile with that name
    python3 -I scripts/release/profiles.py verify <app-or-appex> <team>  that item's embedded profile covers the
                                                                         restricted entitlements it is signed with

A restricted entitlement is only valid when an embedded distribution profile authorises it (Apple, "Creating
distribution-signed code for the Mac"). `verify` reads Contents/embedded.provisionprofile and the entitlements the
signature claims, and reports every restricted claim the profile does not allow, an expired profile, a profile of
another team, and a profile that lists devices (a development profile, not a Developer ID one).
"""

import plistlib
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

RESTRICTED = ("keychain-access-groups", "com.apple.application-identifier", "com.apple.developer.team-identifier")

PROFILE_DIRS = (
    "~/Library/Developer/Xcode/UserData/Provisioning Profiles",
    "~/Library/MobileDevice/Provisioning Profiles",
)


def decode(path: Path) -> dict:
    result = subprocess.run(["security", "cms", "-D", "-i", str(path)], capture_output=True)
    if result.returncode != 0:
        raise ValueError(f"cannot decode {path}: {result.stderr.decode(errors='replace').strip()}")
    return plistlib.loads(result.stdout)


def allows(granted: list[str], value: str) -> bool:
    return any(g == value or (g.endswith("*") and value.startswith(g[:-1])) for g in granted)


def problems(profile: dict, signed: dict, team: str, now: datetime | None = None) -> list[str]:
    """The pure rule set; `profile` and `signed` are the decoded property lists."""
    found: list[str] = []
    now = now or datetime.now(timezone.utc)
    expires = profile.get("ExpirationDate")
    if expires is not None:
        if expires.tzinfo is None:
            expires = expires.replace(tzinfo=timezone.utc)
        if expires <= now:
            found.append(f"profile '{profile.get('Name', '?')}' expired on {expires:%Y-%m-%d}")
    if team not in profile.get("TeamIdentifier", []):
        found.append(f"profile belongs to team {profile.get('TeamIdentifier', [])}, not {team}")
    if profile.get("ProvisionedDevices"):
        found.append("profile lists devices: it is a development profile, not a Developer ID profile")
    entitlements = profile.get("Entitlements", {})
    for key in RESTRICTED:
        if key not in signed:
            continue
        claimed = signed[key] if isinstance(signed[key], list) else [signed[key]]
        granted_raw = entitlements.get(key, [])
        granted = granted_raw if isinstance(granted_raw, list) else [granted_raw]
        for value in claimed:
            if not allows(granted, value):
                found.append(f"{key} = {value} is not authorised by the embedded profile")
    return found


def find(name: str) -> Path | None:
    for directory in PROFILE_DIRS:
        folder = Path(directory).expanduser()
        if not folder.is_dir():
            continue
        for candidate in sorted(folder.iterdir()):
            if candidate.suffix not in (".provisionprofile", ".mobileprovision"):
                continue
            try:
                if decode(candidate).get("Name") == name:
                    return candidate
            except ValueError:
                continue
    return None


def signed_entitlements(item: Path) -> dict:
    result = subprocess.run(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(item)], capture_output=True)
    return plistlib.loads(result.stdout) if result.stdout.strip() else {}


def verify(item: Path, team: str) -> list[str]:
    embedded = item / "Contents" / "embedded.provisionprofile"
    if not embedded.is_file():
        return [f"{item.name}: no Contents/embedded.provisionprofile"]
    try:
        profile = decode(embedded)
    except ValueError as error:
        return [f"{item.name}: {error}"]
    return [f"{item.name}: {p}" for p in problems(profile, signed_entitlements(item), team)]


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[0] == "find":
        path = find(argv[1])
        if path is None:
            return 1
        print(path)
        return 0
    if len(argv) == 3 and argv[0] == "verify":
        found = verify(Path(argv[1]), argv[2])
        for line in found:
            print(f"  profile problem: {line}", file=sys.stderr)
        return 1 if found else 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    sys.exit(main(sys.argv[1:]))
