#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

# Theo Notes (Mac) release: archive, sign (Developer ID), verify, notarize, staple, DMG, notarize and staple the
# DMG, final Gatekeeper assessment R69, procedure in docs/release/release-procedure.md.
#
#   scripts/release-mac.sh              real run: needs a Developer ID Application certificate for the team in
#                                       config/release.env, two Developer ID provisioning profiles and a stored
#                                       notarytool keychain profile. Refuses to start without them.
#   scripts/release-mac.sh --dry-run    no account needed and nothing is sent to Apple: archives the Release
#                                       configuration with the current development signing, packs an unsigned
#                                       DMG, runs the static checks and prints the commands a real run would run.
#   --out DIR       where everything goes (default build/release; git-ignored)
#   --archive PATH  use this existing .xcarchive instead of running xcodegen and xcodebuild archive
#
# Configuration (config/release.env): THEONOTES_TEAM_ID, THEONOTES_NOTARY_PROFILE (the name given to
# `xcrun notarytool store-credentials`), THEONOTES_PROFILE_APP (the Developer ID provisioning profile of the app)
# and THEONOTES_PROFILE_APPEX (the share extension's; optional, empty today because its signature claims no
# restricted entitlement). The last three can be overridden by an environment variable of the same name.
# Credentials never appear here: the notary profile lives in the keychain.
#
# The built app is never launched, opened or installed.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
# shellcheck source=release/lib.sh
. "$here/release/lib.sh"

dry=0 out="$root/build/release" archive_in=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1 ;;
    --out) [ $# -ge 2 ] || { echo "--out needs a value" >&2; exit 2; }; out="$2"; shift ;;
    --archive) [ $# -ge 2 ] || { echo "--archive needs a value" >&2; exit 2; }; archive_in="$2"; shift ;;
    -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done
[ -z "$archive_in" ] || [ -d "$archive_in" ] || { echo "--archive: no directory at $archive_in" >&2; exit 2; }

team="$(setting THEONOTES_TEAM_ID)"
notary_profile="$(setting THEONOTES_NOTARY_PROFILE)"
profile_app="$(setting THEONOTES_PROFILE_APP)"
profile_appex="$(setting THEONOTES_PROFILE_APPEX)"
verify_cmd="${VERIFY_BUNDLE_CMD:-$here/release/verify-bundle.sh}"
if [ "$dry" -eq 1 ]; then work="$out/dry-run"; else work="$out/release"; fi
archive="${archive_in:-$work/Theo-Notes.xcarchive}"
app="$work/Theo Notes.app"
export THEONOTES_SWIFT_CHECKOUTS="$out/DerivedData/SourcePackages/checkouts"

# ---- preflight --------------------------------------------------------------------------------------------
[ "${#team}" -eq 10 ] || refuse "THEONOTES_TEAM_ID in $(release_env_file) is '$team', not a 10-character Team ID"
for tool in xcodebuild xcrun codesign hdiutil ditto plutil; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not found"
done
[ -n "$archive_in" ] || command -v xcodegen >/dev/null 2>&1 || die "xcodegen not found"

identity_hash=""
if [ "$dry" -eq 0 ]; then
  [ -n "$notary_profile" ] || refuse "no notary profile: set THEONOTES_NOTARY_PROFILE in config/release.env (the name used with: xcrun notarytool store-credentials)"
  [ -n "$profile_app" ] || refuse "no app provisioning profile name: set THEONOTES_PROFILE_APP in config/release.env"
  identity_hash="$(developer_id_hash "$team")"
  [ -n "$identity_hash" ] || refuse "no 'Developer ID Application' identity for team $team in the keychain (security find-identity -v -p codesigning); a real run cannot start without it"
  for name in "$profile_app" ${profile_appex:+"$profile_appex"}; do
    python3 -I "$here/release/profiles.py" find "$name" >/dev/null || refuse "provisioning profile '$name' is not installed (~/Library/Developer/Xcode/UserData/Provisioning Profiles)"
  done
  # The Claude extension inside the app is signed with this certificate (scripts/build-mcpb.py); without it the
  # build would fall back to a throwaway self-signed one, which is for local builds only.
  for var in MCPB_SIGN_CERT MCPB_SIGN_KEY; do
    [ -r "${!var:-}" ] || refuse "no Claude extension signing file: set $var to a readable PEM file (Developer ID certificate and its key)"
  done
  # Read-only call to the notary service: proves the stored profile works before 20 minutes of building.
  xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null || refuse "notarytool cannot use the keychain profile '$notary_profile' (xcrun notarytool store-credentials)"
fi

if [ "$dry" -eq 1 ] && { [ -z "${MCPB_SIGN_CERT:-}" ] || [ -z "${MCPB_SIGN_KEY:-}" ]; }; then
  say "note: MCPB_SIGN_CERT/MCPB_SIGN_KEY unset: the Claude extension is self-signed in this dry run (a real run refuses)"
fi
mkdir -p "$work"
say "team $team, mode $([ "$dry" -eq 1 ] && echo dry-run || echo real), output $work"

# would CMD...: print a command a real run would run (dry run only), shell-quoted.
would() { printf 'WOULD RUN:'; printf ' %q' "$@"; printf '\n'; }

# ---- 1. archive -------------------------------------------------------------------------------------------
if [ -z "$archive_in" ]; then
  say "archive (Release)"
  rm -rf "$archive"
  (cd "$root" && xcodegen generate)
  (cd "$root" && xcodebuild archive -project TheoNotes.xcodeproj -scheme TheoNotes -configuration Release \
    -archivePath "$archive" -derivedDataPath "$out/DerivedData")
fi
archived_app="$archive/Products/Applications/Theo Notes.app"
[ -d "$archived_app" ] || die "the archive has no Products/Applications/Theo Notes.app (is the app target's output the only one with SKIP_INSTALL off?)"

# ---- 2. export ---------------------------------------------------------------------------------------------
# Export re-signs the archive inside-out with the Developer ID certificate and the Developer ID profiles
# (xcodebuild -exportArchive, method developer-id). The archive was signed with the development identity; the
# project settings are not changed for this.
options="$work/ExportOptions.plist"
write_export_options() { # <certificate> <app profile> <appex profile>
  rm -f "$options"
  plutil -create xml1 "$options"
  /usr/libexec/PlistBuddy \
    -c "Add :method string developer-id" \
    -c "Add :destination string export" \
    -c "Add :signingStyle string manual" \
    -c "Add :teamID string $team" \
    -c "Add :signingCertificate string $1" \
    -c "Add :provisioningProfiles dict" \
    -c "Add :provisioningProfiles:$PRODUCTION_BUNDLE_ID string $2" "$options"
  if [ -n "$3" ]; then
    /usr/libexec/PlistBuddy -c "Add :provisioningProfiles:$PRODUCTION_BUNDLE_ID.share string $3" "$options"
  fi
}
if [ "$dry" -eq 1 ]; then
  write_export_options "<SHA-1 of the Developer ID Application certificate for $team>" "${profile_app:-<THEONOTES_PROFILE_APP>}" "$profile_appex"
  say "export: a dry run does not export (no Developer ID). ExportOptions.plist a real run would use:"
  plutil -p "$options"
  would xcodebuild -exportArchive -archivePath "$archive" -exportPath "$work/export" -exportOptionsPlist "$options"
  say "stand-in for the export: copy the archived app (development-signed)"
  rm -rf "$app"
  ditto "$archived_app" "$app"
else
  write_export_options "$identity_hash" "$profile_app" "$profile_appex"
  say "export (developer-id)"
  rm -rf "$work/export" "$app"
  xcodebuild -exportArchive -archivePath "$archive" -exportPath "$work/export" -exportOptionsPlist "$options"
  [ -d "$work/export/Theo Notes.app" ] || die "the export has no Theo Notes.app"
  ditto "$work/export/Theo Notes.app" "$app"
fi

require_production_bundle "$app"
version="$(plist_value "$app/Contents/Info.plist" CFBundleShortVersionString)"
[ -n "$version" ] || die "$app has no CFBundleShortVersionString"
base="Theo-Notes-$version"
[ "$dry" -eq 0 ] || base="$base-DRYRUN"
dmg="$work/$base.dmg"
zip="$work/$base.zip"

# ---- 3. verify the bundle ------------------------------------------------------------------------------------
say "verify the bundle"
verify_rc=0
if [ "$dry" -eq 1 ]; then
  # Only the Developer ID checks are allowed to be pending; any other failure still fails the run, but the dry run
  # keeps going so the rest of the output is recorded.
  "$verify_cmd" --dry-run "$app" || verify_rc=$?
else
  "$verify_cmd" "$app"
fi

# ---- 4. notarize and staple the app --------------------------------------------------------------------------
notarize() { # <file> <label>
  local file="$1" label="$2" status="" id=""
  local result="$work/notary-$label.json"
  say "notarize $label"
  xcrun notarytool submit "$file" --keychain-profile "$notary_profile" --wait --output-format json > "$result" || true
  status="$(plutil -extract status raw -o - "$result" 2>/dev/null || true)"
  id="$(plutil -extract id raw -o - "$result" 2>/dev/null || true)"
  if [ "$status" != "Accepted" ]; then
    echo "notarization of $label ended with status '${status:-unknown}'" >&2
    cat "$result" >&2
    if [ -n "$id" ]; then
      xcrun notarytool log "$id" --keychain-profile "$notary_profile" "$work/notary-$label-log.json" || true
      echo "notary log: $work/notary-$label-log.json" >&2
    fi
    exit 1
  fi
}

if [ "$dry" -eq 1 ]; then
  say "notarize + staple the app (not run in a dry run; nothing is sent to Apple)"
  would ditto -c -k --keepParent "$app" "$zip"
  would xcrun notarytool submit "$zip" --keychain-profile "${notary_profile:-<THEONOTES_NOTARY_PROFILE>}" --wait --output-format json
  would xcrun notarytool log "<submission id>" --keychain-profile "${notary_profile:-<THEONOTES_NOTARY_PROFILE>}" "$work/notary-app-log.json"
  would xcrun stapler staple "$app"
  would xcrun stapler validate "$app"
else
  rm -f "$zip"
  ditto -c -k --keepParent "$app" "$zip"
  notarize "$zip" app
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
fi

# ---- 5. DMG, notarize, staple ----------------------------------------------------------------------------------
if [ "$dry" -eq 1 ]; then
  say "pack the DMG (unsigned in a dry run)"
  "$here/release/make-dmg.sh" --dry-run --app "$app" --out "$dmg"
  would "$here/release/make-dmg.sh" --app "$app" --out "$work/Theo-Notes-$version.dmg" --identity "<SHA-1>"
  would xcrun notarytool submit "$work/Theo-Notes-$version.dmg" --keychain-profile "${notary_profile:-<THEONOTES_NOTARY_PROFILE>}" --wait --output-format json
  would xcrun stapler staple "$work/Theo-Notes-$version.dmg"
  would xcrun stapler validate "$work/Theo-Notes-$version.dmg"
else
  "$here/release/make-dmg.sh" --app "$app" --out "$dmg" --identity "$identity_hash"
  notarize "$dmg" dmg
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
fi

# ---- 6. Gatekeeper assessment ----------------------------------------------------------------------------------
# spctl only asks the system policy; it does not start the app.
if [ "$dry" -eq 1 ]; then
  say "Gatekeeper assessment (a dry run is expected to be REJECTED: no Developer ID, not notarized)"
  rc=0; spctl --assess --type execute -vv "$app" || rc=$?
  echo "spctl --assess --type execute: exit $rc (expected non-zero in a dry run)"
  rc=0; spctl --assess --type open --context context:primary-signature -vv "$dmg" || rc=$?
  echo "spctl --assess --type open: exit $rc (expected non-zero in a dry run)"
  say "dry run finished. Nothing was sent to Apple, nothing was installed or launched."
  echo "app: $app"
  echo "dmg: $dmg (unsigned, not for distribution)"
  [ "$verify_rc" -eq 0 ] || { echo "dry run FAILED: verify-bundle reported a failure that is not a Developer ID check" >&2; exit 1; }
else
  say "Gatekeeper assessment"
  spctl --assess --type execute -vv "$app"
  spctl --assess --type open --context context:primary-signature -vv "$dmg"
  say "release finished"
  echo "dmg:    $dmg"
  shasum -a 256 "$dmg"
fi
