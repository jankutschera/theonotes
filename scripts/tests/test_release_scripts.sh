#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

# Tests for scripts/release-mac.sh, scripts/release/verify-bundle.sh and scripts/release/make-dmg.sh.
# Every external tool is a stub on PATH that logs its arguments: no Apple service is contacted, no real signing
# identity is used, nothing is built, mounted, installed or launched. Run: bash scripts/tests/test_release_scripts.sh
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/theo-release-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; [ -f "$work/out" ] && sed 's/^/    | /' "$work/out" >&2; exit 1; }
passed=0
ok() { passed=$((passed + 1)); echo "ok  $*"; }

bin="$work/bin"
mkdir -p "$bin" "$work/home/Library/Developer/Xcode/UserData/Provisioning Profiles"
touch "$work/home/Library/Developer/Xcode/UserData/Provisioning Profiles/app.provisionprofile"
touch "$work/home/Library/Developer/Xcode/UserData/Provisioning Profiles/appex.provisionprofile"

# ---- stubs --------------------------------------------------------------------------------------------------
stub() { # name <<script body
  { echo '#!/bin/bash'; echo "echo \"$1 \$*\" >> \"$work/calls\""; cat; } > "$bin/$1"
  chmod +x "$bin/$1"
}
make_app() { # <dir> <bundle id> <sync flag>
  mkdir -p "$1/Contents/MacOS"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>%s</string><key>CFBundleShortVersionString</key><string>1.2.3</string><key>THEONOTES_SyncSetupAvailable</key><string>%s</string></dict></plist>\n' "$2" "$3" > "$1/Contents/Info.plist"
}
stub xcodegen <<'EOF'
exit 0
EOF
# xcodebuild: `archive` makes a fake archive, `-exportArchive` a fake export.
stub xcodebuild <<EOF
while [ \$# -gt 0 ]; do
  case "\$1" in
    archive) mode=archive ;;
    -exportArchive) mode=export ;;
    -archivePath) archive="\$2"; shift ;;
    -exportPath) export_path="\$2"; shift ;;
    -exportOptionsPlist) cp "\$2" "$work/export-options.plist"; shift ;;
  esac
  shift
done
if [ "\$mode" = archive ]; then
  mkdir -p "\$archive/Products/Applications"
  $(declare -f make_app)
  make_app "\$archive/Products/Applications/Theo Notes.app" "\${FAKE_BUNDLE_ID:-com.truebrewbirdie.theonotes}" NO
fi
if [ "\$mode" = export ]; then
  mkdir -p "\$export_path"
  $(declare -f make_app)
  make_app "\$export_path/Theo Notes.app" com.truebrewbirdie.theonotes NO
fi
EOF
stub xcrun <<'EOF'
case "$1 $2" in
  "notarytool submit")
    printf '{"id":"11111111-2222-3333-4444-555555555555","status":"%s","message":"x"}\n' "${NOTARY_STATUS:-Accepted}" ;;
  "notarytool history") [ "${NOTARY_PROFILE_BROKEN:-0}" = 1 ] && exit 1 || true ;;
  "notarytool log") echo '{"issues":[]}' > "${@: -1}" ;;
esac
exit 0
EOF
stub hdiutil <<'EOF'
if [ "$1" = create ]; then touch "${@: -1}"; fi
exit 0
EOF
stub codesign <<'EOF'
exit 0
EOF
stub spctl <<'EOF'
exit "${SPCTL_RC:-0}"
EOF
stub shasum <<'EOF'
echo "deadbeef  $2"
EOF
stub security <<'EOF'
case "$1" in
  find-identity) echo "$IDENTITY_LINE" ;;
  cms) f="${@: -1}"; n=Unknown
       case "$(basename "$f")" in app.provisionprofile) n="Theo Notes Developer ID" ;; appex.provisionprofile) n="Theo Notes Share Developer ID" ;; esac
       printf '<?xml version="1.0"?><plist version="1.0"><dict><key>Name</key><string>%s</string></dict></plist>\n' "$n" ;;
esac
EOF
# A stand-in for verify-bundle.sh when release-mac.sh is under test (verify-bundle has its own tests below).
cat > "$work/verify-stub" <<EOF
#!/bin/bash
echo "verify-bundle \$*" >> "$work/calls"
exit "\${VERIFY_RC:-0}"
EOF
chmod +x "$work/verify-stub"

team="$(sed -n 's/^THEONOTES_LEGACY_TEAM_ID=//p' "$root/config/release.env")"
good_identity="  1) 0123456789ABCDEF0123456789ABCDEF01234567 \"Developer ID Application: True Brew Birdie Ltd. ($team)\""
dev_identity="  1) 0123456789ABCDEF0123456789ABCDEF01234567 \"Apple Development: Jan ($team)\""

cat > "$work/release.env" <<EOF
THEONOTES_TEAM_ID=$team
THEONOTES_NOTARY_PROFILE=test-notary
THEONOTES_PROFILE_APP=Theo Notes Developer ID
THEONOTES_PROFILE_APPEX=Theo Notes Share Developer ID
EOF
sed 's/^THEONOTES_PROFILE_APPEX=.*/THEONOTES_PROFILE_APPEX=/' "$work/release.env" > "$work/no-appex-profile.env"

# run <script> args...: runs with the stubs; sets $rc, output in $work/out, calls in $work/calls.
run() {
  : > "$work/calls"
  rc=0
  HOME="$work/home" PATH="$bin:$PATH" THEONOTES_RELEASE_ENV="${ENV_FILE:-$work/release.env}" \
    VERIFY_BUNDLE_CMD="$work/verify-stub" IDENTITY_LINE="${IDENTITY_LINE:-$good_identity}" \
    CHECK_ENTITLEMENTS_CMD="${CHECK_CMD:-true}" \
    bash "$@" > "$work/out" 2>&1 || rc=$?
}
called() { grep -q -- "$1" "$work/calls"; }
release() { run "$root/scripts/release-mac.sh" --out "$work/out-dir" "$@"; }

# ---- release-mac.sh: argument parsing --------------------------------------------------------------------------
release --bogus
[ "$rc" -eq 2 ] || fail "unknown flag should exit 2, got $rc"
grep -q "unknown option" "$work/out" || fail "unknown flag message"
[ ! -s "$work/calls" ] || fail "unknown flag must not call any tool"
ok "unknown flag is refused with exit 2 before anything runs"

release --out
[ "$rc" -eq 2 ] || fail "--out without a value should exit 2, got $rc"
ok "a flag without its value exits 2"

release --help
[ "$rc" -eq 0 ] && grep -q "dry-run" "$work/out" || fail "--help"
ok "--help prints usage"

# ---- release-mac.sh: real mode refuses without its inputs -----------------------------------------------------
IDENTITY_LINE="$dev_identity" release
[ "$rc" -eq 2 ] || fail "real mode without a Developer ID identity should exit 2, got $rc"
grep -q "Developer ID Application" "$work/out" || fail "message should name the missing identity"
called "xcodebuild" && fail "xcodebuild must not run when the identity is missing"
ok "real mode refuses without a Developer ID Application identity for the team"

IDENTITY_LINE='  1) 0123456789ABCDEF0123456789ABCDEF01234567 "Developer ID Application: Someone Else (ZZZZZZZZZZ)"' release
[ "$rc" -eq 2 ] || fail "an identity of another team must be refused, got $rc"
ok "real mode refuses a Developer ID identity of another team"

sed '/NOTARY_PROFILE/d' "$work/release.env" > "$work/no-notary.env"
ENV_FILE="$work/no-notary.env" release
[ "$rc" -eq 2 ] || fail "real mode without a notary profile should exit 2, got $rc"
grep -q "THEONOTES_NOTARY_PROFILE" "$work/out" || fail "message should name THEONOTES_NOTARY_PROFILE"
called "xcodebuild" && fail "nothing may be built without a notary profile"
ok "real mode refuses without a notary profile name"

sed '/PROFILE_APP=/d' "$work/release.env" > "$work/no-app-profile.env"
ENV_FILE="$work/no-app-profile.env" release
[ "$rc" -eq 2 ] || fail "real mode without the app profile name should exit 2, got $rc"
grep -q "THEONOTES_PROFILE_APP" "$work/out" || fail "message should name THEONOTES_PROFILE_APP"
ok "real mode refuses without the app provisioning profile name"

sed 's/^THEONOTES_PROFILE_APP=.*/THEONOTES_PROFILE_APP=No Such Profile/' "$work/release.env" > "$work/bad-profile.env"
ENV_FILE="$work/bad-profile.env" release
[ "$rc" -eq 2 ] || fail "a provisioning profile that is not installed should exit 2, got $rc"
grep -q "No Such Profile" "$work/out" || fail "message should name the missing profile"
sed 's/^THEONOTES_PROFILE_APPEX=.*/THEONOTES_PROFILE_APPEX=Missing Share Profile/' "$work/release.env" > "$work/bad-appex.env"
ENV_FILE="$work/bad-appex.env" release
[ "$rc" -eq 2 ] || fail "a named extension profile that is not installed should exit 2, got $rc"
ok "real mode refuses when a named provisioning profile is not installed"

NOTARY_PROFILE_BROKEN=1 release
[ "$rc" -eq 2 ] || fail "an unusable notary profile should exit 2, got $rc"
called "notarytool submit" && fail "must not submit with a broken profile"
ok "real mode refuses when the stored notary profile does not work"

printf 'THEONOTES_TEAM_ID=short\n' > "$work/bad-team.env"
ENV_FILE="$work/bad-team.env" release --dry-run
[ "$rc" -eq 2 ] || fail "a malformed team id should exit 2 even for a dry run, got $rc"
ok "a malformed team id is refused"

# ---- release-mac.sh: refuses a dev-identity bundle --------------------------------------------------------------
FAKE_BUNDLE_ID=com.truebrewbirdie.theonotes.dev release --dry-run
[ "$rc" -eq 0 ] && fail "a dev-identity build must not pass a dry run"
grep -q "bundle id 'com.truebrewbirdie.theonotes.dev'" "$work/out" || fail "refusal should name the bundle id"
called "hdiutil create" && fail "no DMG may be made from a dev-identity bundle"
ok "a dev-identity bundle is refused (dry run, make-dmg)"

# ---- release-mac.sh: dry run --------------------------------------------------------------------------------------
release --dry-run
[ "$rc" -eq 0 ] || fail "dry run should succeed, got $rc"
called "verify-bundle --dry-run" || fail "dry run should verify with --dry-run"
for forbidden in "notarytool submit" "notarytool history" "stapler" "exportArchive"; do
  called "$forbidden" && fail "dry run must not call '$forbidden'"
done
grep -q "WOULD RUN: xcrun notarytool submit" "$work/out" || fail "dry run should print the notarytool command"
grep -q "WOULD RUN: xcrun stapler staple" "$work/out" || fail "dry run should print the stapler command"
grep -q "test-notary" "$work/out" || fail "the printed commands should use the configured notary profile"
[ -f "$work/out-dir/dry-run/Theo-Notes-1.2.3-DRYRUN.dmg" ] || fail "dry run should leave a -DRYRUN dmg"
ok "dry run archives, verifies, packs an unsigned DMG and prints (never runs) the notarize and staple commands"

VERIFY_RC=1 release --dry-run
[ "$rc" -eq 1 ] || fail "a failing non-Developer-ID check must fail the dry run, got $rc"
ok "a dry run still fails on a real verification failure"

# ---- release-mac.sh: real mode, all inputs present (stubs) ----------------------------------------------------------
release
[ "$rc" -eq 0 ] || fail "real run with stubs should succeed, got $rc"
archive_line="$(grep -n '^xcodebuild archive' "$work/calls" | head -1 | cut -d: -f1)"
export_line="$(grep -n '^xcodebuild -exportArchive' "$work/calls" | head -1 | cut -d: -f1)"
verify_line="$(grep -n '^verify-bundle' "$work/calls" | head -1 | cut -d: -f1)"
zip_line="$(grep -n 'notarytool submit .*\.zip' "$work/calls" | head -1 | cut -d: -f1)"
staple_app_line="$(grep -n 'stapler staple .*Theo Notes.app' "$work/calls" | head -1 | cut -d: -f1)"
dmg_line="$(grep -n 'hdiutil create' "$work/calls" | head -1 | cut -d: -f1)"
sign_dmg_line="$(grep -n 'codesign --force --timestamp --sign 0123456789ABCDEF0123456789ABCDEF01234567' "$work/calls" | head -1 | cut -d: -f1)"
submit_dmg_line="$(grep -n 'notarytool submit .*\.dmg' "$work/calls" | head -1 | cut -d: -f1)"
staple_dmg_line="$(grep -n 'stapler staple .*\.dmg' "$work/calls" | head -1 | cut -d: -f1)"
spctl_line="$(grep -n 'spctl --assess --type open' "$work/calls" | head -1 | cut -d: -f1)"
for var in archive_line export_line verify_line zip_line staple_app_line dmg_line sign_dmg_line submit_dmg_line staple_dmg_line spctl_line; do
  [ -n "${!var}" ] || fail "missing step: $var"
done
[ "$archive_line" -lt "$export_line" ] && [ "$export_line" -lt "$verify_line" ] && [ "$verify_line" -lt "$zip_line" ] \
  && [ "$zip_line" -lt "$staple_app_line" ] && [ "$staple_app_line" -lt "$dmg_line" ] && [ "$dmg_line" -lt "$sign_dmg_line" ] \
  && [ "$sign_dmg_line" -lt "$submit_dmg_line" ] && [ "$submit_dmg_line" -lt "$staple_dmg_line" ] && [ "$staple_dmg_line" -lt "$spctl_line" ] \
  || fail "order archive, export, verify, notarize app, staple app, dmg, sign, notarize dmg, staple dmg, spctl"
grep -q -- '--keychain-profile test-notary' "$work/calls" || fail "notarytool should use the configured profile"
grep -E '^codesign ' "$work/calls" | grep -q -- '--deep' && fail "signing must never use --deep"
called "verify-bundle --dry-run" && fail "real mode must verify without --dry-run"
/usr/libexec/PlistBuddy -c "Print :method" "$work/export-options.plist" | grep -q developer-id || fail "export method"
/usr/libexec/PlistBuddy -c "Print :signingCertificate" "$work/export-options.plist" | grep -q 0123456789ABCDEF0123456789ABCDEF01234567 || fail "export signing certificate should be the identity hash"
/usr/libexec/PlistBuddy -c "Print :provisioningProfiles:com.truebrewbirdie.theonotes.share" "$work/export-options.plist" | grep -q "Theo Notes Share Developer ID" || fail "extension profile in the export options"
/usr/libexec/PlistBuddy -c "Print :teamID" "$work/export-options.plist" | grep -q "$team" || fail "team id in the export options"
ok "real run (stubs): export options, order of sign/notarize/staple/DMG/notarize/staple/spctl, no --deep"

ENV_FILE="$work/no-appex-profile.env" release
[ "$rc" -eq 0 ] || fail "an empty extension profile name must be allowed, got $rc"
/usr/libexec/PlistBuddy -c "Print :provisioningProfiles:com.truebrewbirdie.theonotes.share" "$work/export-options.plist" >/dev/null 2>&1 && fail "no share profile should be mapped when the name is empty"
/usr/libexec/PlistBuddy -c "Print :provisioningProfiles:com.truebrewbirdie.theonotes" "$work/export-options.plist" | grep -q "Theo Notes Developer ID" || fail "app profile mapping"
ok "the share-extension profile is optional and left out of the export options when empty"

NOTARY_STATUS=Invalid release
[ "$rc" -eq 1 ] || fail "an Invalid notarization should exit 1, got $rc"
called "notarytool log" || fail "the notary log should be fetched on failure"
called "stapler" && fail "nothing may be stapled after a rejection"
called "hdiutil create" && fail "no DMG after a rejected app"
ok "a rejected notarization fetches the log, stops, and staples nothing"

SPCTL_RC=3 release
[ "$rc" -ne 0 ] || fail "a Gatekeeper rejection must fail a real run"
ok "a Gatekeeper rejection fails a real run"

# ---- make-dmg.sh -----------------------------------------------------------------------------------------------------
make_app "$work/prod/Theo Notes.app" com.truebrewbirdie.theonotes NO
make_app "$work/dev/Theo Notes.app" com.truebrewbirdie.theonotes.dev YES
run "$root/scripts/release/make-dmg.sh" --app "$work/dev/Theo Notes.app" --out "$work/x.dmg" --dry-run
[ "$rc" -eq 2 ] || fail "make-dmg must refuse a dev-identity bundle with exit 2, got $rc"
called "hdiutil" && fail "make-dmg must not run hdiutil for a dev bundle"
ok "make-dmg refuses a dev-identity bundle"

run "$root/scripts/release/make-dmg.sh" --app "$work/prod/Theo Notes.app" --out "$work/x.dmg"
[ "$rc" -eq 2 ] || fail "make-dmg real mode without an identity must exit 2, got $rc"
ok "make-dmg real mode refuses without a signing identity"

run "$root/scripts/release/make-dmg.sh" --app "$work/missing.app" --out "$work/x.dmg" --dry-run
[ "$rc" -eq 2 ] || fail "make-dmg with a missing app must exit 2, got $rc"
run "$root/scripts/release/make-dmg.sh" --app "$work/prod/Theo Notes.app" --out "$work/x.zip" --dry-run
[ "$rc" -eq 2 ] || fail "make-dmg with a non-dmg output must exit 2, got $rc"
run "$root/scripts/release/make-dmg.sh" --nope
[ "$rc" -eq 2 ] || fail "make-dmg unknown flag must exit 2, got $rc"
ok "make-dmg argument parsing"

run "$root/scripts/release/make-dmg.sh" --app "$work/prod/Theo Notes.app" --out "$work/y.dmg" --identity ABCDEF
[ "$rc" -eq 0 ] || fail "make-dmg with an identity should succeed, got $rc"
called "codesign --force --timestamp --sign ABCDEF $work/y.dmg" || fail "the image should be signed with a secure timestamp"
ok "make-dmg signs the image with a timestamp"

# ---- verify-bundle.sh --------------------------------------------------------------------------------------------------
verify() { run "$root/scripts/release/verify-bundle.sh" "$@"; }
verify "$work/dev/Theo Notes.app"
[ "$rc" -eq 2 ] || fail "verify-bundle must refuse a dev-identity bundle with exit 2, got $rc"
called "codesign" && fail "verify-bundle must not look at the signature of a refused bundle"
ok "verify-bundle refuses a dev-identity bundle"

verify
[ "$rc" -eq 2 ] || fail "verify-bundle without a bundle should exit 2, got $rc"
verify --bogus "$work/prod/Theo Notes.app"
[ "$rc" -eq 2 ] || fail "verify-bundle unknown flag should exit 2, got $rc"
verify "$work/nothing.app"
[ "$rc" -eq 2 ] || fail "verify-bundle with a missing bundle should exit 2, got $rc"
ok "verify-bundle argument parsing"

make_app "$work/sync/Theo Notes.app" com.truebrewbirdie.theonotes YES
verify --dry-run --skip-acknowledgements "$work/sync/Theo Notes.app"
[ "$rc" -eq 1 ] || fail "a bundle with the sync switch on must fail, got $rc"
grep -q "THEONOTES_SyncSetupAvailable" "$work/out" || fail "failure should name the sync key"
ok "verify-bundle fails a bundle that ships the sync setup"

make_app "$work/personal/Theo Notes.app" com.truebrewbirdie.theonotes YES
# The fake bundles hold no Mach-O files, so the run fails on those; what changes with the flag is the sync line.
verify --dry-run --skip-acknowledgements --personal-install "$work/personal/Theo Notes.app"
grep -q "PASS .*THEONOTES_SyncSetupAvailable is on (YES), as Jan's own install has it" "$work/out" || fail "--personal-install should accept the switch being on"
make_app "$work/personal-off/Theo Notes.app" com.truebrewbirdie.theonotes NO
verify --dry-run --skip-acknowledgements --personal-install "$work/personal-off/Theo Notes.app"
[ "$rc" -eq 1 ] || fail "--personal-install must fail a bundle with the sync switch off, got $rc"
grep -q "FAIL .*THEONOTES_SyncSetupAvailable is 'NO', Jan's own install" "$work/out" || fail "--personal-install should name the switch being off"
verify --dry-run --skip-acknowledgements "$work/personal/Theo Notes.app"
grep -q "FAIL .*THEONOTES_SyncSetupAvailable is 'YES', the shipped build must have it off" "$work/out" || fail "without --personal-install the sync switch stays forbidden"
verify --personal-install "$work/dev/Theo Notes.app"
[ "$rc" -eq 2 ] || fail "--personal-install must still refuse a dev-identity bundle, got $rc"
ok "verify-bundle --personal-install flips only the sync switch"

# ---- verify-bundle.sh: the entitlement check follows the iCloud entitlement (CloudKit plan, Task 15b fix round 1) -------
# The checker is a stub that logs its arguments; codesign prints the entitlements named by FAKE_ENTITLEMENTS.
stub codesign <<'EOF2'
case "$*" in *--entitlements*) [ -n "${FAKE_ENTITLEMENTS:-}" ] && cat "$FAKE_ENTITLEMENTS" ;; esac
exit 0
EOF2
cat > "$work/check-stub" <<EOF2
#!/bin/bash
echo "check-entitlements \$*" >> "$work/calls"
exit 0
EOF2
chmod +x "$work/check-stub"
cat > "$work/ent-icloud.plist" <<'EOF2'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>com.apple.developer.icloud-services</key><array><string>CloudKit</string></array>
<key>com.apple.developer.icloud-container-identifiers</key><array><string>iCloud.com.test.theonotes</string></array>
</dict></plist>
EOF2
cat > "$work/ent-plain.plist" <<'EOF2'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>keychain-access-groups</key><array><string>X.com.truebrewbirdie.theonotes</string></array></dict></plist>
EOF2
{ cat "$work/release.env"; echo 'THEONOTES_CLOUDKIT_CONTAINER=iCloud.com.test.theonotes'; } > "$work/release-icloud.env"
{ cat "$work/release.env"; echo 'THEONOTES_CLOUDKIT_CONTAINER='; } > "$work/release-nocontainer.env"
make_app "$work/ic/Theo Notes.app" com.truebrewbirdie.theonotes NO
cp /usr/bin/true "$work/ic/Theo Notes.app/Contents/MacOS/Baerchen"   # the script only counts Mach-O files; nothing is executed

FAKE_ENTITLEMENTS="$work/ent-icloud.plist" CHECK_CMD="$work/check-stub" ENV_FILE="$work/release-icloud.env" \
  verify --dry-run --skip-acknowledgements "$work/ic/Theo Notes.app"
grep -q "check-entitlements .*Theo Notes.app --icloud --container iCloud.com.test.theonotes" "$work/calls" \
  || fail "a bundle with the iCloud entitlement must be checked with --icloud --container <configured container>"
ok "verify-bundle checks an iCloud bundle with --icloud and the configured container"

FAKE_ENTITLEMENTS="$work/ent-plain.plist" CHECK_CMD="$work/check-stub" ENV_FILE="$work/release-icloud.env" \
  verify --dry-run --skip-acknowledgements "$work/ic/Theo Notes.app"
called "check-entitlements" || fail "the entitlement check must run"
called "--icloud" && fail "a bundle without the iCloud entitlement must keep the unchanged check (no --icloud)"
grep -q "^check-entitlements $work/ic/Theo Notes.app\$" "$work/calls" || fail "the unchanged check takes only the bundle"
ok "verify-bundle keeps the unchanged entitlement check without iCloud"

FAKE_ENTITLEMENTS="$work/ent-icloud.plist" CHECK_CMD="$work/check-stub" ENV_FILE="$work/release-nocontainer.env" \
  verify --dry-run --skip-acknowledgements "$work/ic/Theo Notes.app"
[ "$rc" -eq 1 ] || fail "an iCloud bundle with no configured container must fail, got $rc"
grep -q "THEONOTES_CLOUDKIT_CONTAINER" "$work/out" || fail "the failure must name the empty container setting"
called "--icloud" && fail "no --icloud call without a container to compare against"
ok "verify-bundle fails an iCloud bundle when no container is configured"

# ---- release-ios.sh: refusals before anything is built -----------------------------------------------------
rc=0; ASC_KEY_ID= ASC_ISSUER_ID= ASC_KEY_PATH= PATH="$bin:$PATH" bash "$root/scripts/release-ios.sh" >"$work/out" 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "release-ios without an upload key must refuse with 2, got $rc"
rc=0; PATH="$bin:$PATH" bash "$root/scripts/release-ios.sh" --bogus >"$work/out" 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "release-ios must reject an unknown option with 2, got $rc"
ok "release-ios refuses without a key and rejects unknown options"

echo "all $passed release-script checks passed"
