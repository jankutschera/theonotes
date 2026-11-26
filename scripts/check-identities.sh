#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

# Pins the two app identities in the build settings, without building anything.
#   Production + Release = the installed app: bundle id, keychain access group, App Group, URL schemes,
#                          display name exactly as before the dev identity existed (Jan's locked-note keys,
#                          notification permission and links depend on them).
#   Debug                = the dev identity (tests, agents, GUI checks): nothing shared with production.
# THEONOTES_SYNC_SETUP: YES in Debug and Production, NO in Release (the public build).
# Team: the Apple team is ONE setting, THEONOTES_TEAM_ID in config/release.env. The check
#                          reads it from there, requires every derived value to follow it (DEVELOPMENT_TEAM,
#                          App Groups, Info.plist key, the runtime fallback), and re-reads the build settings
#                          with the team overridden on the command line to prove nothing else carries it.
# iCloud: the container is one parameter too,
#                          THEONOTES_CLOUDKIT_CONTAINER in config/release.env (iCloud.com.truebrewbirdie.theonotes since the
#                          cutover). Only the main app's two entitlement files name it, through the build setting, never as a
#                          literal; the share extension and the CLI helper carry no iCloud key and no source file contains a
#                          container literal. Debug = Development environment, Production/Release = Production (acceptance
#                          section C recipe). THEONOTES_ICLOUD_SYNC is YES in every configuration (Release since
#, 2026-11-10), and the Mac Info.plist carries both.
# Run after `xcodegen generate`; scripts/test-all.sh runs it first. Exit 1 on the first mismatch.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
project="${IDENTITY_CHECK_PROJECT:-TheoNotes.xcodeproj}"
[ -d "$project" ] || { echo "no $project: run xcodegen generate" >&2; exit 1; }

# The team the repo is configured for: config/release.env is the single definition.
team="$(sed -n 's/^THEONOTES_TEAM_ID=//p' config/release.env | head -1)"
case "$team" in
  [A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]) ;;
  *) echo "config/release.env: THEONOTES_TEAM_ID='$team' is not a 10-character Team ID" >&2; exit 1 ;;
esac

# The container the repo is configured for (the pin exists so that it never changes by accident; change it together
# with config/release.env in one commit).
expected_container="iCloud.com.truebrewbirdie.theonotes"
container="$(sed -n 's/^THEONOTES_CLOUDKIT_CONTAINER=//p' config/release.env | head -1)"
if ! grep -q '^THEONOTES_CLOUDKIT_CONTAINER=' config/release.env; then
  echo "config/release.env: THEONOTES_CLOUDKIT_CONTAINER is missing (an empty value is fine, a missing line is not)" >&2
  exit 1
fi
case "$container" in
  "" | iCloud.*.*) ;;
  *) echo "config/release.env: THEONOTES_CLOUDKIT_CONTAINER='$container' is neither empty nor an iCloud.<reverse-dns> identifier" >&2; exit 1 ;;
esac

# The root of every bundle id is ONE value, THEONOTES_BUNDLE_ROOT in config/identity.env (project.yml reads it
# through config/build.xcconfig). The Swift copy is LegacyNames.bundleRoot, and AppIdentity.productionBundleIdentifier
# reads that; all of them must say the same thing, and it is the production bundle id pinned below.
bundle_root="$(sed -n 's/^THEONOTES_BUNDLE_ROOT=//p' config/identity.env | head -1)"
legacy_names=Packages/TheoNotesCore/Sources/TheoNotesCore/Legacy/LegacyNames.swift
case "$bundle_root" in
  "" | *[!a-z0-9.-]*) echo "config/identity.env: THEONOTES_BUNDLE_ROOT='$bundle_root' is not a reverse-dns identifier" >&2; exit 1 ;;
esac

failures=0
setting() { # <configuration> <target> <key>   (SETTING_OVERRIDES: extra KEY=VALUE command line settings)
  # shellcheck disable=SC2086
  # The output is read to the end before it is searched: quitting awk early closes the pipe and xcodebuild then
  # exits 74, which `set -o pipefail` turns into a random stop of this script.
  local settings
  settings="$(xcodebuild -project "$project" -target "$2" -configuration "$1" -showBuildSettings ${SETTING_OVERRIDES:-} 2>/dev/null || true)"
  printf '%s\n' "$settings" | awk -v key="$3" '{ k=$1 } k==key && $2=="=" && !done { sub(/^[^=]*= ?/, ""); print; done=1 }'
}
expect() { # <configuration> <target> <key> <expected>
  local got
  got="$(setting "$1" "$2" "$3")"
  if [ "$got" = "$4" ]; then
    echo "ok    $1 $2 $3 = $got"
  else
    echo "FAIL  $1 $2 $3 = '$got' (expected '$4')" >&2
    failures=$((failures + 1))
  fi
}

if grep -qF "public static let bundleRoot = \"$bundle_root\"" "$legacy_names"; then
  echo "ok    LegacyNames.bundleRoot = $bundle_root (config/identity.env)"
else
  echo "FAIL  LegacyNames.bundleRoot is not '$bundle_root' (config/identity.env)" >&2
  failures=$((failures + 1))
fi
if grep -qF "productionBundleIdentifier = LegacyNames.bundleRoot" Packages/TheoNotesCore/Sources/TheoNotesCore/AppIdentity.swift; then
  echo "ok    AppIdentity.productionBundleIdentifier = LegacyNames.bundleRoot"
else
  echo "FAIL  AppIdentity.productionBundleIdentifier does not read LegacyNames.bundleRoot" >&2
  failures=$((failures + 1))
fi

for config in Production Release; do
  expect "$config" TheoNotes PRODUCT_BUNDLE_IDENTIFIER "$bundle_root"
  expect "$config" TheoNotes THEONOTES_BUNDLE_ROOT "$bundle_root"
  expect "$config" TheoNotes INFOPLIST_KEY_CFBundleDisplayName "Theo Notes"
  expect "$config" TheoNotesMacShare INFOPLIST_KEY_CFBundleDisplayName "Theo Notes"
  expect "$config" TheoNotes THEONOTES_DISPLAY_NAME "Theo Notes"
  expect "$config" TheoNotes THEONOTES_APP_GROUP "$team.com.truebrewbirdie.notes"
  expect "$config" TheoNotes THEONOTES_URL_SCHEME theonotes
  expect "$config" TheoNotes THEONOTES_LEGACY_URL_SCHEME baerchen
  expect "$config" TheoNotes DEVELOPMENT_TEAM "$team"
  expect "$config" TheoNotes PRODUCT_NAME "Theo Notes"
  expect "$config" TheoNotesMacShare PRODUCT_BUNDLE_IDENTIFIER "$bundle_root.share"
  expect "$config" TheoNotesMacShare THEONOTES_APP_GROUP "$team.com.truebrewbirdie.notes"
  # The installed app is team-signed with its keychain access group, as it always was.
  expect "$config" TheoNotes CODE_SIGN_ENTITLEMENTS Apps/TheoNotesMac/TheoNotes.entitlements
  expect "$config" TheoNotesMacShare CODE_SIGN_ENTITLEMENTS Apps/TheoNotesMacShare/TheoNotesMacShare.entitlements
done
expect Release TheoNotes CODE_SIGN_STYLE Automatic
expect Release TheoNotesMacShare CODE_SIGN_STYLE Automatic
# Jan's installed build (Production) is signed like the shipped one: manual Developer ID, the Developer ID profile named in
# config/release.env (the profile carries the Production push environment and the iCloud container), a secure timestamp, no debug dylib.
profile_app="$(sed -n 's/^THEONOTES_PROFILE_APP=//p' config/release.env | head -1)"
expect Production TheoNotes CODE_SIGN_STYLE Manual
expect Production TheoNotes CODE_SIGN_IDENTITY "Developer ID Application"
expect Production TheoNotes PROVISIONING_PROFILE_SPECIFIER "$profile_app"
expect Production TheoNotesMacShare CODE_SIGN_STYLE Manual
expect Production TheoNotesMacShare CODE_SIGN_IDENTITY "Developer ID Application"
expect Production TheoNotesCLI CODE_SIGN_STYLE Manual
expect Production TheoNotesCLI CODE_SIGN_IDENTITY "Developer ID Application"
for target in TheoNotes TheoNotesMacShare TheoNotesCLI; do
  expect Production "$target" OTHER_CODE_SIGN_FLAGS "--timestamp"
done
expect Production TheoNotes ENABLE_DEBUG_DYLIB NO
expect Production TheoNotesMacShare ENABLE_DEBUG_DYLIB NO

expect Debug TheoNotes PRODUCT_BUNDLE_IDENTIFIER "$bundle_root.dev"
expect Debug TheoNotes THEONOTES_DISPLAY_NAME "Theo Notes Dev"
expect Debug TheoNotes INFOPLIST_KEY_CFBundleDisplayName "Theo Notes Dev"
expect Debug TheoNotes THEONOTES_APP_GROUP "$team.com.truebrewbirdie.notes.dev"
expect Debug TheoNotes THEONOTES_URL_SCHEME theonotes-dev
expect Debug TheoNotes THEONOTES_LEGACY_URL_SCHEME baerchen-dev
expect Debug TheoNotes PRODUCT_NAME "Theo Notes Dev"
# The Mac tests run inside the dev app, whose executable carries the product name.
test_host="$(setting Debug TheoNotesMacTests TEST_HOST)"
case "$test_host" in
  */"Theo Notes Dev.app/Contents/MacOS/Theo Notes Dev") echo "ok    Debug TheoNotesMacTests TEST_HOST = $test_host" ;;
  *) echo "FAIL  Debug TheoNotesMacTests TEST_HOST = '$test_host' (expected .../Theo Notes Dev.app/Contents/MacOS/Theo Notes Dev)" >&2
     failures=$((failures + 1)) ;;
esac
expect Debug TheoNotesMacShare PRODUCT_BUNDLE_IDENTIFIER "$bundle_root.dev.share"
expect Debug TheoNotesMacShare THEONOTES_APP_GROUP "$team.com.truebrewbirdie.notes.dev"
# The dev build is team-signed (automatic,; see project.yml) with its own entitlements (Development iCloud).
expect Debug TheoNotes CODE_SIGN_ENTITLEMENTS Apps/TheoNotesMac/TheoNotes.dev.entitlements
expect Debug TheoNotesMacShare CODE_SIGN_ENTITLEMENTS Apps/TheoNotesMacShare/TheoNotesMacShare.dev.entitlements
# The app signs manually with the profile scripts/release/asc_dev_profile.py makes; the extension signs automatically (no profile).
expect Debug TheoNotes CODE_SIGN_STYLE Manual
expect Debug TheoNotes CODE_SIGN_IDENTITY "Apple Development"
expect Debug TheoNotes PROVISIONING_PROFILE_SPECIFIER "Theo Notes Mac Dev Development"
expect Debug TheoNotesMacShare CODE_SIGN_STYLE Automatic
# The command line tool and the test bundle follow the same root.
for config in Debug Production Release; do
  expect "$config" TheoNotesCLI PRODUCT_BUNDLE_IDENTIFIER "$bundle_root.cli"
  expect "$config" TheoNotesMacTests PRODUCT_BUNDLE_IDENTIFIER "$bundle_root.tests"
done

# Whether the build shows the sync setup. Jan's own builds (Debug for tests and agents, Production for his
# install) show it; the public build (Release) must not. The default for any other configuration is NO.
expect Production TheoNotes THEONOTES_SYNC_SETUP YES
expect Debug TheoNotes THEONOTES_SYNC_SETUP YES
expect Release TheoNotes THEONOTES_SYNC_SETUP NO
expect Release TheoNotesMacShare THEONOTES_SYNC_SETUP NO

# CloudKit plan Task 12 (CK-J2): iCloud sync availability. The container follows config/release.env (pinned empty
# until the account exists); the flag is YES in Debug, Production and Release, NO for every other configuration.
if [ "$container" = "$expected_container" ]; then
  echo "ok    THEONOTES_CLOUDKIT_CONTAINER in config/release.env = '$container'"
else
  echo "FAIL  THEONOTES_CLOUDKIT_CONTAINER in config/release.env is '$container' (pinned '$expected_container' in scripts/check-identities.sh)" >&2
  failures=$((failures + 1))
fi
for config in Debug Production Release; do
  expect "$config" TheoNotes THEONOTES_CLOUDKIT_CONTAINER "$container"
done
expect Production TheoNotes THEONOTES_ICLOUD_SYNC YES
expect Debug TheoNotes THEONOTES_ICLOUD_SYNC YES
expect Release TheoNotes THEONOTES_ICLOUD_SYNC YES
expect Release TheoNotesMacShare THEONOTES_ICLOUD_SYNC YES

# The files that turn the settings into the signed identity: the keychain access group follows the bundle id
# (so one identity's locked-note keys are unreadable to the other), the App Group and URL schemes follow the
# settings above. A literal here would make both builds share it.
plist() { /usr/libexec/PlistBuddy -c "Print $2" "$1" 2>/dev/null || echo "<missing>"; }
check_file() { # <file> <key path> <expected>
  local got
  got="$(plist "$1" "$2")"
  if [ "$got" = "$3" ]; then echo "ok    $1 $2 = $got"; else echo "FAIL  $1 $2 = '$got' (expected '$3')" >&2; failures=$((failures + 1)); fi
}
check_file Apps/TheoNotesMac/TheoNotes.entitlements ':keychain-access-groups:0' '$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)'
check_file Apps/TheoNotesMac/TheoNotes.entitlements ':com.apple.security.application-groups:0' '$(THEONOTES_APP_GROUP)'
check_file Apps/TheoNotesMacShare/TheoNotesMacShare.entitlements ':com.apple.security.application-groups:0' '$(THEONOTES_APP_GROUP)'
check_file Apps/TheoNotesMac/TheoNotes.dev.entitlements ':keychain-access-groups:0' '$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)'
check_file Apps/TheoNotesMac/TheoNotes.dev.entitlements ':com.apple.security.application-groups:0' '$(THEONOTES_APP_GROUP)'
check_file Apps/TheoNotesMacShare/TheoNotesMacShare.dev.entitlements ':com.apple.security.application-groups:0' '$(THEONOTES_APP_GROUP)'
check_file Apps/TheoNotesMac/Info.plist ':CFBundleURLTypes:0:CFBundleURLSchemes:0' '$(THEONOTES_URL_SCHEME)'
check_file Apps/TheoNotesMac/Info.plist ':CFBundleURLTypes:0:CFBundleURLSchemes:1' '$(THEONOTES_LEGACY_URL_SCHEME)'
check_file Apps/TheoNotesMac/Info.plist ':THEONOTES_SyncSetupAvailable' '$(THEONOTES_SYNC_SETUP)'
# note-ids and tag-path follow the bundle root. The backup type is
# fixed ( amendment): chosen exports use the new type, internal and old backups the imported legacy one.
check_file Apps/TheoNotesMac/Info.plist ':UTExportedTypeDeclarations:0:UTTypeIdentifier' 'com.truebrewbirdie.theonotes.backup'
check_file Apps/TheoNotesMac/Info.plist ':UTImportedTypeDeclarations:0:UTTypeIdentifier' 'com.truebrewbirdie.baerchen.backup'
check_file Apps/TheoNotesMac/Info.plist ':UTExportedTypeDeclarations:1:UTTypeIdentifier' '$(THEONOTES_BUNDLE_ROOT).note-ids'
check_file Apps/TheoNotesMac/Info.plist ':UTExportedTypeDeclarations:2:UTTypeIdentifier' '$(THEONOTES_BUNDLE_ROOT).tag-path'

check_file Apps/TheoNotesMac/Info.plist ':THEONOTES_CloudKitContainer' '$(THEONOTES_CLOUDKIT_CONTAINER)'
check_file Apps/TheoNotesMac/Info.plist ':THEONOTES_ICloudSyncAvailable' '$(THEONOTES_ICLOUD_SYNC)'
# iCloud entitlements (acceptance section C recipe): the main app carries exactly the container build setting,
# CloudKit alone, the environment (Production for the shipped files, Development for the dev file) and the push environment;
# the share extension and the CLI helper carry none of it (scripts/release/check_entitlements.py refuses them there too).
check_file Apps/TheoNotesMac/TheoNotes.entitlements ':com.apple.developer.icloud-container-identifiers:0' '$(THEONOTES_CLOUDKIT_CONTAINER)'
check_file Apps/TheoNotesMac/TheoNotes.entitlements ':com.apple.developer.icloud-container-identifiers:1' '<missing>'
check_file Apps/TheoNotesMac/TheoNotes.entitlements ':com.apple.developer.icloud-services:0' 'CloudKit'
check_file Apps/TheoNotesMac/TheoNotes.entitlements ':com.apple.developer.icloud-services:1' '<missing>'
check_file Apps/TheoNotesMac/TheoNotes.entitlements ':com.apple.developer.icloud-container-environment' 'Production'
check_file Apps/TheoNotesMac/TheoNotes.entitlements ':com.apple.developer.aps-environment' 'production'
check_file Apps/TheoNotesMac/TheoNotes.dev.entitlements ':com.apple.developer.icloud-container-identifiers:0' '$(THEONOTES_CLOUDKIT_CONTAINER)'
check_file Apps/TheoNotesMac/TheoNotes.dev.entitlements ':com.apple.developer.icloud-container-identifiers:1' '<missing>'
check_file Apps/TheoNotesMac/TheoNotes.dev.entitlements ':com.apple.developer.icloud-services:0' 'CloudKit'
check_file Apps/TheoNotesMac/TheoNotes.dev.entitlements ':com.apple.developer.icloud-services:1' '<missing>'
check_file Apps/TheoNotesMac/TheoNotes.dev.entitlements ':com.apple.developer.icloud-container-environment' 'Development'
check_file Apps/TheoNotesMac/TheoNotes.dev.entitlements ':com.apple.developer.aps-environment' 'development'
for file in Apps/TheoNotesMacShare/TheoNotesMacShare.entitlements Apps/TheoNotesMacShare/TheoNotesMacShare.dev.entitlements \
            Apps/TheoNotesCLI/theonotes.entitlements; do
  for key in com.apple.developer.icloud-container-identifiers com.apple.developer.icloud-services \
             com.apple.developer.icloud-container-environment aps-environment com.apple.developer.aps-environment; do
    check_file "$file" ":$key" '<missing>'
  done
done

# R29: the team is one parameter. Every place that used to carry the literal follows it.
check_file Apps/TheoNotesMac/Info.plist ':THEONOTES_TeamID' '$(THEONOTES_TEAM_ID)'
check_file Apps/TheoNotesMacShare/Info.plist ':THEONOTES_TeamID' '$(THEONOTES_TEAM_ID)'
for config in Debug Production Release; do
  expect "$config" TheoNotes THEONOTES_TEAM_ID "$team"
  expect "$config" TheoNotesMacShare THEONOTES_TEAM_ID "$team"
done
for config in Production Release; do
  expect "$config" TheoNotesMacShare DEVELOPMENT_TEAM "$team"
  expect "$config" TheoNotesCLI DEVELOPMENT_TEAM "$team"
done
# The dev identity is team-signed too: the same team on every macOS target.
expect Debug TheoNotes DEVELOPMENT_TEAM "$team"
expect Debug TheoNotesMacShare DEVELOPMENT_TEAM "$team"
expect Debug TheoNotesCLI DEVELOPMENT_TEAM "$team"

# The shipped signatures carry no base entitlements (no get-task-allow; no application-identifier on the
# bare helper). Debug keeps Xcode's default (YES); Production is signed like Release.
for target in TheoNotes TheoNotesMacShare TheoNotesCLI; do
  expect Release "$target" CODE_SIGN_INJECT_BASE_ENTITLEMENTS NO
  expect Production "$target" CODE_SIGN_INJECT_BASE_ENTITLEMENTS NO
  expect Debug "$target" CODE_SIGN_INJECT_BASE_ENTITLEMENTS YES
done
# The bare helper claims nothing: an explicit empty entitlements file keeps Xcode from adding application-identifier.
expect Release TheoNotesCLI CODE_SIGN_ENTITLEMENTS Apps/TheoNotesCLI/theonotes.entitlements
expect Production TheoNotesCLI CODE_SIGN_ENTITLEMENTS Apps/TheoNotesCLI/theonotes.entitlements
check_file Apps/TheoNotesCLI/theonotes.entitlements ':com.apple.application-identifier' '<missing>'

# B5: iOS now uses the publishing team and keeps the App Intents module identity.
check_file Apps/TheoNotesIOS/Info.plist ':THEONOTES_TeamID' '$(THEONOTES_TEAM_ID)'
check_file Apps/TheoNotesIOS/Info.plist ':THEONOTES_AppGroupIdentifier' '$(THEONOTES_IOS_APP_GROUP)'
check_file Apps/TheoNotesIOSShare/Info.plist ':THEONOTES_AppGroupIdentifier' '$(THEONOTES_IOS_APP_GROUP)'
check_file Apps/TheoNotesIOSShare/TheoNotesIOSShare.entitlements ':com.apple.security.application-groups:0' '$(THEONOTES_IOS_APP_GROUP)'
check_file Apps/TheoNotesIOSWidgets/Info.plist ':THEONOTES_AppGroupIdentifier' '$(THEONOTES_IOS_APP_GROUP)'
check_file Apps/TheoNotesIOSWidgets/TheoNotesIOSWidgets.entitlements ':com.apple.security.application-groups:0' '$(THEONOTES_IOS_APP_GROUP)'
check_file Apps/TheoNotesIOS/TheoNotesIOS.entitlements ':com.apple.security.application-groups:0' '$(THEONOTES_IOS_APP_GROUP)'
check_file Apps/TheoNotesIOS/Info.plist ':THEONOTES_SyncSetupAvailable' '$(THEONOTES_SYNC_SETUP)'
check_file Apps/TheoNotesIOS/Info.plist ':THEONOTES_ICloudSyncAvailable' '$(THEONOTES_ICLOUD_SYNC)'
check_file Apps/TheoNotesIOS/Info.plist ':THEONOTES_CloudKitContainer' '$(THEONOTES_CLOUDKIT_CONTAINER)'
check_file Apps/TheoNotesIOS/Info.plist ':CFBundleURLTypes:0:CFBundleURLSchemes:0' '$(THEONOTES_URL_SCHEME)'
check_file Apps/TheoNotesIOS/Info.plist ':CFBundleURLTypes:0:CFBundleURLSchemes:1' '$(THEONOTES_LEGACY_URL_SCHEME)'
check_file Apps/TheoNotesWatch/Info.plist ':CFBundleURLTypes:0:CFBundleURLSchemes:0' '$(THEONOTES_WATCH_URL_SCHEME)'
for config in Debug Production Release; do
  for target in TheoNotesIOS TheoNotesIOSShare TheoNotesIOSWidgets TheoNotesIOSTests TheoNotesIOSUITests TheoNotesWatch TheoNotesWatchWidgets TheoNotesWatchTests; do
    expect "$config" "$target" DEVELOPMENT_TEAM "$team"
  done
  ios_root="$bundle_root"
  if [ "$config" = Debug ]; then ios_root="$bundle_root.dev"; fi
  expect "$config" TheoNotesIOS PRODUCT_BUNDLE_IDENTIFIER "$ios_root.ios"
  expect "$config" TheoNotesIOS THEONOTES_IOS_BUNDLE_ROOT "$ios_root"
  expect "$config" TheoNotesIOS THEONOTES_IOS_APP_GROUP "group.$ios_root.ios"
  expect "$config" TheoNotesIOSShare THEONOTES_IOS_APP_GROUP "group.$ios_root.ios"
  expect "$config" TheoNotesIOSShare PRODUCT_BUNDLE_IDENTIFIER "$ios_root.ios.share"
  expect "$config" TheoNotesIOSShare CODE_SIGN_ENTITLEMENTS Apps/TheoNotesIOSShare/TheoNotesIOSShare.entitlements
  expect "$config" TheoNotesIOSWidgets THEONOTES_IOS_APP_GROUP "group.$ios_root.ios"
  expect "$config" TheoNotesIOSWidgets PRODUCT_BUNDLE_IDENTIFIER "$ios_root.ios.widgets"
  expect "$config" TheoNotesWatch PRODUCT_BUNDLE_IDENTIFIER "$ios_root.ios.watchkitapp"
  expect "$config" TheoNotesWatchWidgets PRODUCT_BUNDLE_IDENTIFIER "$ios_root.ios.watchkitapp.widgets"
  watch_scheme=theonotes-watch
  if [ "$config" = Debug ]; then watch_scheme=theonotes-watch-dev; fi
  expect "$config" TheoNotesWatch THEONOTES_WATCH_URL_SCHEME "$watch_scheme"
  expect "$config" TheoNotesWatchWidgets THEONOTES_WATCH_URL_SCHEME "$watch_scheme"
  expect "$config" TheoNotesIOSWidgets CODE_SIGN_ENTITLEMENTS Apps/TheoNotesIOSWidgets/TheoNotesIOSWidgets.entitlements
  conditions="$(setting "$config" TheoNotesIOSWidgets SWIFT_ACTIVE_COMPILATION_CONDITIONS)"
  case " $conditions " in
    *' THEONOTES_WIDGET_EXTENSION '*) echo "ok    $config TheoNotesIOSWidgets extension compilation condition" ;;
    *) echo "FAIL  $config TheoNotesIOSWidgets missing THEONOTES_WIDGET_EXTENSION" >&2; failures=$((failures + 1)) ;;
  esac
  conditions="$(setting "$config" TheoNotesIOS SWIFT_ACTIVE_COMPILATION_CONDITIONS)"
  case " $conditions " in
    *' THEONOTES_WIDGET_EXTENSION '*) echo "FAIL  $config TheoNotesIOS has widget-only compilation condition" >&2; failures=$((failures + 1)) ;;
    *) echo "ok    $config TheoNotesIOS excludes widget compilation condition" ;;
  esac
  expect "$config" TheoNotesIOS PRODUCT_MODULE_NAME BaerchenIOS
  expect "$config" TheoNotesIOS CODE_SIGN_ENTITLEMENTS Apps/TheoNotesIOS/TheoNotesIOS.entitlements
  expect "$config" TheoNotesIOS SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD NO
done
for config in Debug Production; do
  expect "$config" TheoNotesIOS THEONOTES_SYNC_SETUP YES
  expect "$config" TheoNotesIOS THEONOTES_ICLOUD_SYNC YES
  expect "$config" TheoNotesIOS THEONOTES_IOS_APS_ENVIRONMENT development
done
expect Debug TheoNotesIOS THEONOTES_IOS_ICLOUD_ENVIRONMENT Development
expect Production TheoNotesIOS THEONOTES_IOS_ICLOUD_ENVIRONMENT Production
expect Release TheoNotesIOS THEONOTES_SYNC_SETUP NO
expect Release TheoNotesIOS THEONOTES_ICLOUD_SYNC YES
expect Release TheoNotesIOS THEONOTES_IOS_APS_ENVIRONMENT production
expect Release TheoNotesIOS THEONOTES_IOS_ICLOUD_ENVIRONMENT Production

# The only source file that may name the team is the runtime fallback, and it must equal the configured team.
literal_files="$(grep -rlF "$team" Packages/TheoNotesCore/Sources Apps/TheoNotesMac Apps/TheoNotesMacShare 2>/dev/null | grep -v '^Apps/TheoNotesMac/Tests/' | sort | tr '\n' ' ' || true)"
if [ "$literal_files" = "Packages/TheoNotesCore/Sources/TheoNotesCore/AppIdentity.swift " ]; then
  echo "ok    the team literal appears only in AppIdentity.swift"
else
  echo "FAIL  the team literal appears in: $literal_files(expected only Packages/TheoNotesCore/Sources/TheoNotesCore/AppIdentity.swift)" >&2
  failures=$((failures + 1))
fi
if grep -qF "fallbackTeamPrefix = \"$team\"" Packages/TheoNotesCore/Sources/TheoNotesCore/AppIdentity.swift; then
  echo "ok    AppIdentity.fallbackTeamPrefix = $team"
else
  echo "FAIL  AppIdentity.fallbackTeamPrefix is not '$team' (config/release.env)" >&2
  failures=$((failures + 1))
fi

# No source file contains a container name: it reaches the code only through the Info.plist key. IDENTITY_CHECK_SOURCES
# (space separated paths) lets scripts/tests/test_release_scripts.sh plant a literal and see this fail.
container_pattern='iCloud\.[A-Za-z0-9-]+\.[A-Za-z0-9.-]+'
sources="${IDENTITY_CHECK_SOURCES:-Packages/TheoNotesCore/Sources Apps/TheoNotesMac Apps/TheoNotesMacShare Apps/TheoNotesCLI}"
# shellcheck disable=SC2086
container_files="$(grep -rlE "$container_pattern" $sources 2>/dev/null | grep -v '^Apps/TheoNotesMac/Tests/' | sort | tr '\n' ' ' || true)"
if [ -z "$container_files" ]; then
  echo "ok    no source file names an iCloud container"
else
  echo "FAIL  an iCloud container literal appears in: $container_files(it must come only from the Info.plist key)" >&2
  failures=$((failures + 1))
fi
if [ -n "$container" ]; then
  # shellcheck disable=SC2086
  if grep -rlF "$container" $sources 2>/dev/null | grep -qv '^Apps/TheoNotesMac/Tests/'; then
    echo "FAIL  the configured container $container appears in a source file" >&2
    failures=$((failures + 1))
  fi
fi

# Changing config/release.env alone must move everything: re-read with another team on the command line.
other=ABCDE12345
export SETTING_OVERRIDES="THEONOTES_TEAM_ID=$other"
for config in Production Release; do
  expect "$config" TheoNotes DEVELOPMENT_TEAM "$other"
  expect "$config" TheoNotesMacShare DEVELOPMENT_TEAM "$other"
  expect "$config" TheoNotesCLI DEVELOPMENT_TEAM "$other"
  expect "$config" TheoNotesMacTests DEVELOPMENT_TEAM "$other"
  expect "$config" TheoNotes THEONOTES_APP_GROUP "$other.com.truebrewbirdie.notes"
  expect "$config" TheoNotesMacShare THEONOTES_APP_GROUP "$other.com.truebrewbirdie.notes"
done
expect Debug TheoNotes THEONOTES_APP_GROUP "$other.com.truebrewbirdie.notes.dev"
expect Debug TheoNotesMacShare THEONOTES_APP_GROUP "$other.com.truebrewbirdie.notes.dev"
expect Debug TheoNotes DEVELOPMENT_TEAM "$other"
unset SETTING_OVERRIDES

# Changing config/identity.env alone moves every bundle id (re-read with another root on the command line).
export SETTING_OVERRIDES="THEONOTES_BUNDLE_ROOT=com.example.probe"
for config in Production Release; do
  expect "$config" TheoNotes PRODUCT_BUNDLE_IDENTIFIER com.example.probe
  expect "$config" TheoNotesMacShare PRODUCT_BUNDLE_IDENTIFIER com.example.probe.share
  expect "$config" TheoNotesCLI PRODUCT_BUNDLE_IDENTIFIER com.example.probe.cli
  expect "$config" TheoNotesMacTests PRODUCT_BUNDLE_IDENTIFIER com.example.probe.tests
done
expect Debug TheoNotes PRODUCT_BUNDLE_IDENTIFIER com.example.probe.dev
expect Debug TheoNotesMacShare PRODUCT_BUNDLE_IDENTIFIER com.example.probe.dev.share
unset SETTING_OVERRIDES

if [ "$failures" -ne 0 ]; then
  echo "identity check: $failures mismatch(es)" >&2
  exit 1
fi
echo "identity check: ok"
