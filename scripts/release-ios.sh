#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

# Theo Notes (iPhone, iPad, Watch) release: archive the Release configuration, export for App Store Connect,
# check what was built, validate with Apple and upload. The upload makes a TestFlight build; nothing here
# submits for review.
#
#   scripts/release-ios.sh               archive, export, check, validate, upload
#   scripts/release-ios.sh --no-upload   stop after Apple's validation
#   --out DIR                            where everything goes (default build/release/ios; git-ignored)
#
# Needs an App Store Connect API key in the environment: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (the .p8 file).
# Apple refuses a build number it has already seen for a version: raise CURRENT_PROJECT_VERSION in project.yml
# before a second upload.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
# shellcheck source=release/lib.sh
. "$here/release/lib.sh"

upload=1 out="$root/build/release/ios"
while [ $# -gt 0 ]; do
  case "$1" in
    --no-upload) upload=0 ;;
    --out) [ $# -ge 2 ] || { echo "--out needs a value" >&2; exit 2; }; out="$2"; shift ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

[ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] || refuse "ASC_KEY_ID and ASC_ISSUER_ID must be set"
[ -f "${ASC_KEY_PATH:-}" ] || refuse "ASC_KEY_PATH does not point at a key file"
key=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
archive="$out/Theo-Notes-iOS.xcarchive"
ipa="$out/export/TheoNotesIOS.ipa"

cd "$root"
rm -rf "$archive" "$out/export"
mkdir -p "$out"

say "archive (Release)"
xcodegen generate
xcodebuild archive -project TheoNotes.xcodeproj -scheme TheoNotesIOS -configuration Release \
  -destination generic/platform=iOS -archivePath "$archive" -derivedDataPath "$out/DerivedData" \
  -allowProvisioningUpdates "${key[@]}" >"$out/archive.log" 2>&1 || die "archive failed, see $out/archive.log"

say "export (App Store Connect)"
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$out/export" \
  -exportOptionsPlist "$here/release/ios-export-options.plist" \
  -allowProvisioningUpdates "${key[@]}" >"$out/export.log" 2>&1 || die "export failed, see $out/export.log"
[ -f "$ipa" ] || die "no package at $ipa"

say "check the package"
payload="$out/payload"
rm -rf "$payload" && mkdir -p "$payload"
unzip -q "$ipa" -d "$payload"
app="$payload/Payload/TheoNotesIOS.app"
version="$(plist_value "$app/Info.plist" CFBundleShortVersionString)"
build="$(plist_value "$app/Info.plist" CFBundleVersion)"
for item in "$app" "$app/PlugIns/TheoNotesIOSShare.appex" "$app/PlugIns/TheoNotesIOSWidgets.appex" \
            "$app/Watch/TheoNotesWatch.app" "$app/Watch/TheoNotesWatch.app/PlugIns/TheoNotesWatchWidgets.appex"; do
  [ -d "$item" ] || die "missing in the package: ${item#"$payload/Payload/"}"
  [ "$(plist_value "$item/Info.plist" CFBundleShortVersionString)" = "$version" ] || die "version differs in $item"
  [ "$(plist_value "$item/Info.plist" CFBundleVersion)" = "$build" ] || die "build number differs in $item"
  entitlements="$(codesign -d --entitlements - --xml "$item" 2>/dev/null)" || die "cannot read the signature of $item"
  if grep -Eq 'get-task-allow</key>[[:space:]]*<true/>' <<<"$entitlements"; then die "debug entitlement in $item"; fi
done
# The iOS targets always carry the iCloud entitlement; whether the build offers sync is this Info.plist key.
echo "    offers iCloud sync: $(plist_value "$app/Info.plist" THEONOTES_ICloudSyncAvailable)"
echo "    version $version, build $build, id $(plist_value "$app/Info.plist" CFBundleIdentifier)"

altool=(xcrun altool --api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID" --p8-file-path "$ASC_KEY_PATH")
say "validate with Apple"
"${altool[@]}" --validate-app "$ipa" >"$out/validate.log" 2>&1 || die "validation failed, see $out/validate.log"

if [ "$upload" -eq 0 ]; then say "not uploaded (--no-upload): $ipa"; exit 0; fi
say "upload"
"${altool[@]}" --upload-package "$ipa" >"$out/upload.log" 2>&1 || die "upload failed, see $out/upload.log"
say "uploaded version $version build $build; it shows in TestFlight once Apple has processed it"
