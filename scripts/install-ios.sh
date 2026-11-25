#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

set -euo pipefail

# Personal-device Production install. The new identity installs alongside the old app.
# Usage: scripts/install-ios.sh <paired-device-name-or-UDID>
DEVICE="${1:-${BAERCHEN_IOS_DEVICE:-}}"
if [[ -z "$DEVICE" ]]; then
  echo 'Usage: scripts/install-ios.sh <paired-device-name-or-UDID>' >&2
  xcrun devicectl list devices
  exit 2
fi
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BAERCHEN_IOS_BUILD_DIR:-$PROJECT_ROOT/build/IOSDevice}"
cd "$PROJECT_ROOT"
xcodegen generate
xcodebuild -project TheoNotes.xcodeproj -scheme TheoNotesIOS \
  -configuration Production -destination 'generic/platform=iOS' -derivedDataPath "$BUILD_DIR" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration -jobs 4 build
APP_PATH="$BUILD_DIR/Build/Products/Production-iphoneos/TheoNotesIOS.app"
ENTITLEMENTS="$(mktemp -t theonotes-ios-entitlements)"
trap 'rm -f "$ENTITLEMENTS"' EXIT
codesign --verify --strict "$APP_PATH"
codesign -d --entitlements :- "$APP_PATH" > "$ENTITLEMENTS" 2>/dev/null
python3 - "$APP_PATH/Info.plist" "$ENTITLEMENTS" config/identity.env config/release.env <<'PY'
import plistlib, sys

def setting(path, name):
    return next(line.split('=', 1)[1].strip() for line in open(path) if line.startswith(name + '='))

with open(sys.argv[1], 'rb') as f: info = plistlib.load(f)
with open(sys.argv[2], 'rb') as f: entitlements = plistlib.load(f)
root = setting(sys.argv[3], 'THEONOTES_BUNDLE_ROOT')
team = setting(sys.argv[4], 'THEONOTES_TEAM_ID')
container = setting(sys.argv[4], 'THEONOTES_CLOUDKIT_CONTAINER')
checks = {
    'bundle identifier': info.get('CFBundleIdentifier') == root + '.ios',
    'private sync enabled': info.get('THEONOTES_SyncSetupAvailable') == 'YES',
    'iCloud sync enabled': info.get('THEONOTES_ICloudSyncAvailable') == 'YES',
    'signed app identifier': entitlements.get('application-identifier') == team + '.' + root + '.ios',
    'keychain groups': entitlements.get('keychain-access-groups') == [team + '.' + root + '.ios', team + '.' + root],
    'iCloud container': entitlements.get('com.apple.developer.icloud-container-identifiers') == [container],
    'iCloud environment': entitlements.get('com.apple.developer.icloud-container-environment') == 'Production',
    'push environment': entitlements.get('aps-environment') == 'development',
}
failed = [name for name, ok in checks.items() if not ok]
if failed: sys.exit('Refusing installation: invalid ' + ', '.join(failed))
PY
xcrun devicectl device install app --device "$DEVICE" "$APP_PATH"
xcrun devicectl device info apps --device "$DEVICE" --bundle-id com.truebrewbirdie.theonotes.ios
xcrun devicectl device process launch --device "$DEVICE" com.truebrewbirdie.theonotes.ios
