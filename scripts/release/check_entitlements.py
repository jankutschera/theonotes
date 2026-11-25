#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

"""Static check of the signed entitlements and hardened-runtime flag of a built Mac bundle (REL-R30 ... R32).

    python3 -I scripts/release/check_entitlements.py <path>/Theo\\ Notes.app  [--allow-get-task-allow]
                                                      [--icloud [--container iCloud.com.example.app]]

Reads only (`codesign -d`); nothing inside the bundle is executed. The expected sets follow M10-D1 (Developer ID,
not sandboxed) and docs/release/sandbox-audit.md:

  app    keychain access group, App Group, Apple events, audio input. Never the App Sandbox (that would move the
         library and break the CLI, REL-R31), never a hardened-runtime exception (no JIT, no unsigned memory, no
         disabled library validation), never get-task-allow.
  appex  App Sandbox + App Group + user-selected read-only files, nothing else.
  helper none. A bare tool must not claim a restricted entitlement: the Mac has no profile for it.

`com.apple.application-identifier` and `com.apple.developer.team-identifier` are allowed on the app and the
extension (they come from the provisioning profile) and forbidden on the helper. Every code item must carry the
hardened-runtime flag. `--allow-get-task-allow` is for development-signed local builds only; the release script
never passes it.

`--icloud` (CloudKit plan, Task 12) checks a build that carries iCloud sync, which only exists under the publishing
team. The app must then also be signed with exactly the configured container
(`com.apple.developer.icloud-container-identifiers`), the CloudKit service alone (`com.apple.developer.icloud-services`),
`com.apple.developer.icloud-container-environment` = Production and `aps-environment` = production (on macOS the key is
`com.apple.developer.aps-environment`, accepted under the same rule; Development values
are accepted only with `--allow-get-task-allow`), and its embedded profile must list the container, allow CloudKit
and carry `aps-environment`. The container comes from `--container`, else THEONOTES_CLOUDKIT_CONTAINER in
config/release.env (or the file named by THEONOTES_RELEASE_ENV); with neither the check stops (exit 2). The extension
and the helper never carry these keys. Without `--icloud` the default sets above apply unchanged, so a build that
carries an iCloud entitlement is refused as unexpected. Apple: Configuring iCloud services
(https://developer.apple.com/documentation/xcode/configuring-icloud-services).
"""

import importlib.util
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path
from typing import Callable

PROFILE_KEYS = {"com.apple.application-identifier", "com.apple.developer.team-identifier"}

APP_REQUIRED = {
    "keychain-access-groups",
    "com.apple.security.application-groups",
    "com.apple.security.automation.apple-events",
    "com.apple.security.device.audio-input",
}
APPEX_REQUIRED = {
    "com.apple.security.app-sandbox",
    "com.apple.security.application-groups",
    "com.apple.security.files.user-selected.read-only",
}
HELPER_REQUIRED: set[str] = set()

ICLOUD_CONTAINERS = "com.apple.developer.icloud-container-identifiers"
ICLOUD_SERVICES = "com.apple.developer.icloud-services"
ICLOUD_ENVIRONMENT = "com.apple.developer.icloud-container-environment"
APS_ENVIRONMENT = "aps-environment"
# macOS names the push entitlement differently (CK-R150, measured in rehearsal 2, REN2-R58): a Mac signature and a Mac profile
# carry com.apple.developer.aps-environment, and Xcode drops the iOS name from a Mac signature. With --icloud both count as APS_ENVIRONMENT.
APS_ENVIRONMENT_MACOS = "com.apple.developer.aps-environment"
ICLOUD_REQUIRED = {ICLOUD_CONTAINERS, ICLOUD_SERVICES, ICLOUD_ENVIRONMENT, APS_ENVIRONMENT}

CODE_ITEMS = (
    ("app", "", APP_REQUIRED, True),
    ("share extension", "Contents/PlugIns/TheoNotesMacShare.appex", APPEX_REQUIRED, True),
    ("helper", "Contents/Helpers/theonotes", HELPER_REQUIRED, False),
)


def _codesign(args: list[str], path: Path) -> subprocess.CompletedProcess:
    return subprocess.run(["/usr/bin/codesign", *args, str(path)], capture_output=True)


def entitlements(path: Path) -> dict | None:
    """The signed entitlements, `{}` when there are none, None when the item is unsigned."""
    result = _codesign(["-d", "--entitlements", ":-"], path)
    if b"code object is not signed" in result.stderr:
        return None
    if not result.stdout.strip():
        return {}
    return plistlib.loads(result.stdout)


def has_runtime_flag(path: Path) -> bool:
    result = _codesign(["-d", "--verbose=2"], path)
    match = re.search(rb"flags=0x([0-9a-f]+)", result.stderr)
    return bool(match) and int(match.group(1), 16) & 0x10000 != 0


def decode_profile(path: Path) -> dict:
    """The decoded embedded profile (`security cms -D`, shared with profiles.py); ValueError when unreadable."""
    spec = importlib.util.spec_from_file_location("profiles", Path(__file__).with_name("profiles.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.decode(path)


def with_push_alias(keys: dict) -> dict:
    """`keys` with the macOS push entitlement read under the name the rules and messages use."""
    if APS_ENVIRONMENT_MACOS in keys and APS_ENVIRONMENT not in keys:
        keys = {**keys, APS_ENVIRONMENT: keys[APS_ENVIRONMENT_MACOS]}
        del keys[APS_ENVIRONMENT_MACOS]
    return keys


def _as_list(value) -> list:
    return value if isinstance(value, list) else [value]


def icloud_problems(
    signed: dict, app: Path, container: str, allow_dev: bool, read_profile: Callable[[Path], dict]
) -> list[str]:
    """The extra rules of --icloud for the app: signed values and the embedded profile."""
    problems: list[str] = []
    if ICLOUD_CONTAINERS in signed and sorted(_as_list(signed[ICLOUD_CONTAINERS])) != [container]:
        problems.append(f"app: {ICLOUD_CONTAINERS} must be exactly [{container!r}], is {_as_list(signed[ICLOUD_CONTAINERS])}")
    if ICLOUD_SERVICES in signed and sorted(_as_list(signed[ICLOUD_SERVICES])) != ["CloudKit"]:
        problems.append(f"app: {ICLOUD_SERVICES} must be exactly ['CloudKit'], is {_as_list(signed[ICLOUD_SERVICES])}")
    environments = ("Production", "Development") if allow_dev else ("Production",)
    if ICLOUD_ENVIRONMENT in signed and signed[ICLOUD_ENVIRONMENT] not in environments:
        problems.append(f"app: {ICLOUD_ENVIRONMENT} must be {' or '.join(map(repr, environments))}, is {signed[ICLOUD_ENVIRONMENT]!r}")
    pushes = ("production", "development") if allow_dev else ("production",)
    if APS_ENVIRONMENT in signed and signed[APS_ENVIRONMENT] not in pushes:
        problems.append(f"app: {APS_ENVIRONMENT} must be {' or '.join(map(repr, pushes))}, is {signed[APS_ENVIRONMENT]!r}")
    embedded = app / "Contents" / "embedded.provisionprofile"
    if not embedded.is_file():
        problems.append("app: no Contents/embedded.provisionprofile (the iCloud entitlements need a profile that lists the container)")
        return problems
    try:
        granted = with_push_alias(read_profile(embedded).get("Entitlements", {}))
    except ValueError as error:
        problems.append(f"app: embedded profile unreadable: {error}")
        return problems
    if container not in _as_list(granted.get(ICLOUD_CONTAINERS, [])):
        problems.append(f"app: embedded profile does not list the container {container}")
    services = _as_list(granted.get(ICLOUD_SERVICES, []))
    if "CloudKit" not in services and "*" not in services:
        problems.append("app: embedded profile does not allow the CloudKit service")
    if APS_ENVIRONMENT not in granted:
        problems.append(f"app: embedded profile has no {APS_ENVIRONMENT}")
    return problems


def check(
    app: Path,
    allow_get_task_allow: bool = False,
    icloud_container: str | None = None,
    read_profile: Callable[[Path], dict] = decode_profile,
) -> list[str]:
    problems: list[str] = []
    for name, relative, required, takes_profile_keys in CODE_ITEMS:
        item = app / relative if relative else app
        if not item.exists():
            problems.append(f"{name}: {item} does not exist")
            continue
        signed = entitlements(item)
        if signed is None:
            problems.append(f"{name}: not signed")
            continue
        icloud = icloud_container is not None and name == "app"
        if icloud:
            signed = with_push_alias(signed)
        required = required | (ICLOUD_REQUIRED if icloud else set())
        allowed = required | (PROFILE_KEYS if takes_profile_keys else set())
        if allow_get_task_allow:
            allowed = allowed | {"com.apple.security.get-task-allow"}
        for key in sorted(set(signed) - allowed):
            if key == "com.apple.security.get-task-allow":
                problems.append(f"{name}: get-task-allow is signed in (notarization rejects it)")
            elif key in PROFILE_KEYS:
                problems.append(f"{name}: restricted entitlement {key} on a bare tool with no profile")
            else:
                problems.append(f"{name}: unexpected entitlement {key}")
        for key in sorted(required - set(signed)):
            problems.append(f"{name}: missing entitlement {key}")
        if icloud:
            problems.extend(icloud_problems(signed, item, icloud_container, allow_get_task_allow, read_profile))
        if not has_runtime_flag(item):
            problems.append(f"{name}: hardened runtime flag (0x10000) not set")
    return problems


def configured_container() -> str:
    """THEONOTES_CLOUDKIT_CONTAINER from release.env, read by key like lib.sh does (never sourced); '' when absent."""
    path = Path(os.environ.get("THEONOTES_RELEASE_ENV") or Path(__file__).resolve().parents[2] / "config" / "release.env")
    try:
        for line in path.read_text().splitlines():
            if line.startswith("THEONOTES_CLOUDKIT_CONTAINER="):
                return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return ""


def main(argv: list[str]) -> int:
    args = list(argv)
    container = None
    if "--container" in args:
        at = args.index("--container")
        if at + 1 >= len(args):
            print(__doc__, file=sys.stderr)
            return 2
        container = args[at + 1]
        del args[at : at + 2]
    paths = [a for a in args if not a.startswith("--")]
    if len(paths) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    app = Path(paths[0])
    icloud_container = None
    if "--icloud" in args:
        icloud_container = container or configured_container()
        if not icloud_container:
            print("--icloud: no container configured (pass --container or set THEONOTES_CLOUDKIT_CONTAINER in config/release.env)", file=sys.stderr)
            return 2
    problems = check(app, allow_get_task_allow="--allow-get-task-allow" in args, icloud_container=icloud_container)
    for problem in problems:
        print(f"FAIL  {problem}", file=sys.stderr)
    if problems:
        print(f"entitlement check: {len(problems)} problem(s)", file=sys.stderr)
        return 1
    print("entitlement check: ok")
    return 0


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    sys.exit(main(sys.argv[1:]))
