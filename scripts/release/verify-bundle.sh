#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

# Static verification of a built Theo Notes bundle before it is notarized or shipped. Nothing in the
# bundle is executed: codesign, plutil, file, security and the Python checkers only read.
#
#   scripts/release/verify-bundle.sh [--dry-run] [--skip-acknowledgements] [--personal-install] <Theo Notes.app>
#
# Exit 0 = every check passed, 1 = a check failed, 2 = refused (not the production identity, no bundle, bad usage).
#
# Real mode asserts, for every Mach-O in the bundle: a valid signature, the hardened-runtime flag, a secure
# timestamp, a "Developer ID Application" authority and the configured team. It also asserts the production bundle id,
# the sync switch off, the entitlement sets of scripts/release/check_entitlements.py (no get-task-allow),
# an embedded provisioning profile for every item that claims a restricted entitlement (the app) that authorises it, `codesign --verify --deep --strict` (a check; signing itself is done inside-out by the export), and
# that the Acknowledgements list matches the bundle.
#
# --personal-install is for the Production build Jan installs on his own Mac: it is signed like the shipped build
# (Developer ID, hardened runtime, no get-task-allow, the same entitlement and profile rules) but it shows the sync setup, so the
# switch must be ON instead of off. Nothing else is relaxed.
#
# --dry-run is for a bundle signed with the development identity: the checks that can only pass with a Developer ID
# (authority, secure timestamp, a Developer ID profile) are printed as PENDING and do not fail the run. Everything
# else is enforced exactly as in real mode.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
root="$(release_root)"

dry=0 skip_ack=0 personal=0 app=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry=1 ;;
    --skip-acknowledgements) skip_ack=1 ;;
    --personal-install) personal=1 ;;
    -h|--help) sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *) [ -z "$app" ] || { echo "only one bundle can be verified" >&2; exit 2; }; app="${arg%/}" ;;
  esac
done
[ -n "$app" ] || { echo "usage: verify-bundle.sh [--dry-run] [--skip-acknowledgements] [--personal-install] <Theo Notes.app>" >&2; exit 2; }

# Refusals come first and need nothing else.
require_production_bundle "$app"

team="$(setting THEONOTES_TEAM_ID)"
[ "${#team}" -eq 10 ] || refuse "THEONOTES_TEAM_ID in $(release_env_file) is '$team', not a 10-character Team ID"

failures=0 pending=0
pass() { echo "PASS     $*"; }
fail() { echo "FAIL     $*" >&2; failures=$((failures + 1)); }
# A check that needs a real Developer ID signature: pending in a dry run, a failure otherwise.
needs_developer_id() {
  if [ "$dry" -eq 1 ]; then echo "PENDING  $* (expected to fail until a Developer ID signature exists)"; pending=$((pending + 1)); else fail "$*"; fi
}

info="$app/Contents/Info.plist"
sync="$(plist_value "$info" THEONOTES_SyncSetupAvailable)"
if [ "$personal" -eq 1 ]; then
  case "$sync" in
    YES|true|yes) pass "Info.plist THEONOTES_SyncSetupAvailable is on ($sync), as Jan's own install has it" ;;
    *) fail "Info.plist THEONOTES_SyncSetupAvailable is '${sync:-missing}', Jan's own install (--personal-install) must have it on" ;;
  esac
else
  case "$sync" in
    NO|false|no) pass "Info.plist THEONOTES_SyncSetupAvailable is off ($sync)" ;;
    *) fail "Info.plist THEONOTES_SyncSetupAvailable is '${sync:-missing}', the shipped build must have it off (REL-R4)" ;;
  esac
fi

# Every Mach-O file, signed or not.
macho=()
while IFS= read -r -d '' file; do
  if file -b "$file" | grep -q 'Mach-O'; then macho+=("$file"); fi
done < <(find "$app" -type f -print0)
[ "${#macho[@]}" -gt 0 ] || fail "no Mach-O file found in $app"

for required in "Contents/Helpers/theonotes" "Contents/PlugIns/TheoNotesMacShare.appex"; do
  [ -e "$app/$required" ] && pass "present: $required" || fail "missing: $required"
done

for file in "${macho[@]}"; do
  relative="${file#"$app"/}"
  details="$(codesign -dvv "$file" 2>&1 || true)"
  if echo "$details" | grep -q 'not signed'; then fail "$relative: not signed"; continue; fi
  echo "$details" | grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\(.*runtime' \
    && pass "$relative: hardened runtime" || fail "$relative: hardened runtime flag missing"
  echo "$details" | grep -q "^TeamIdentifier=$team\$" \
    && pass "$relative: team $team" || fail "$relative: TeamIdentifier is not $team"
  echo "$details" | grep -q '^Authority=Developer ID Application: ' \
    && pass "$relative: Developer ID Application authority" || needs_developer_id "$relative: no Developer ID Application authority"
  echo "$details" | grep -q '^Timestamp=' \
    && pass "$relative: secure timestamp" || needs_developer_id "$relative: no secure timestamp"
done

echo "--- entitlements as signed"
for item in "" "Contents/PlugIns/TheoNotesMacShare.appex" "Contents/Helpers/theonotes"; do
  path="$app${item:+/$item}"
  [ -e "$path" ] || continue
  echo "[${item:-app}]"
  entitlements="$(codesign -d --entitlements :- "$path" 2>/dev/null | plutil -p - 2>/dev/null || true)"
  echo "${entitlements:-  (none)}"
done

check_entitlements=("python3" "-I" "$here/check_entitlements.py")
[ -z "${CHECK_ENTITLEMENTS_CMD:-}" ] || check_entitlements=("$CHECK_ENTITLEMENTS_CMD")
# A bundle that carries an iCloud entitlement is checked in iCloud mode against the configured container (CloudKit plan, B7); a bundle
# without one keeps the unchanged check, which refuses any iCloud entitlement as unexpected.
check_args=("$app")
carries_icloud=0
codesign -d --entitlements :- "$app" 2>/dev/null | plutil -p - 2>/dev/null | grep -q 'com\.apple\.developer\.icloud-' && carries_icloud=1
if [ "$carries_icloud" -eq 1 ]; then
  container="$(setting THEONOTES_CLOUDKIT_CONTAINER)"
  if [ -n "$container" ]; then check_args+=(--icloud --container "$container"); fi
fi
if [ "$carries_icloud" -eq 1 ] && [ -z "${container:-}" ]; then
  fail "the bundle carries iCloud entitlements but THEONOTES_CLOUDKIT_CONTAINER in $(release_env_file) is empty (nothing to check them against)"
elif "${check_entitlements[@]}" "${check_args[@]}"; then
  if [ "$carries_icloud" -eq 1 ]; then pass "entitlement sets with iCloud (container $container, CloudKit alone, Production environment)"
  else pass "entitlement sets (no get-task-allow, no sandbox on the app, no cs exceptions)"; fi
else fail "entitlement check"; fi

# An item needs an embedded profile exactly when its signature claims a restricted entitlement. The app does
# (keychain-access-groups); the share extension's set (sandbox, App Group, read-only files) has none today, so no
# profile is required for it, but one that is embedded is checked all the same.
for item in "" "Contents/PlugIns/TheoNotesMacShare.appex"; do
  path="$app${item:+/$item}"
  label="${item:-app}"
  claims="$(codesign -d --entitlements :- "$path" 2>/dev/null | plutil -p - 2>/dev/null || true)"
  restricted=0
  echo "$claims" | grep -Eq 'keychain-access-groups|com\.apple\.application-identifier|com\.apple\.developer\.team-identifier' && restricted=1
  if [ ! -f "$path/Contents/embedded.provisionprofile" ]; then
    if [ "$restricted" -eq 1 ]; then fail "$label: claims a restricted entitlement but has no Contents/embedded.provisionprofile"
    else pass "$label: claims no restricted entitlement, so no provisioning profile is needed"; fi
    continue
  fi
  pass "$label: embedded.provisionprofile present"
  if python3 -I "$here/profiles.py" verify "$path" "$team"; then
    pass "$label: embedded profile authorises the restricted entitlements"
  else
    needs_developer_id "$label: embedded profile problem (listed above)"
  fi
done

if codesign --verify --deep --strict --verbose=2 "$app"; then pass "codesign --verify --deep --strict"; else fail "codesign --verify --deep --strict"; fi

if [ "$skip_ack" -eq 1 ]; then
  echo "SKIPPED  acknowledgements check (--skip-acknowledgements)"
else
  ack=(python3 -I "$root/scripts/gen-acknowledgements.py" --check --app-bundle "$app")
  [ -z "${THEONOTES_SWIFT_CHECKOUTS:-}" ] || ack+=(--swift-checkouts "$THEONOTES_SWIFT_CHECKOUTS")
  if "${ack[@]}"; then pass "Acknowledgements list matches the bundle"; else fail "Acknowledgements check"; fi
fi

echo "verify-bundle: $failures failed, $pending pending ($([ "$dry" -eq 1 ] && echo dry-run || echo real))"
[ "$failures" -eq 0 ]
