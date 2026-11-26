#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

# Tests for scripts/cutover-safety.sh in a temp directory: a fake library, a fake old app, a fake old App Group.
# Nothing real is read or written; lsregister and lsof are stubs.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/theo-cutover-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok  $*"; }
script="$root/scripts/cutover-safety.sh"
legacy_team="$(sed -n 's/^THEONOTES_LEGACY_TEAM_ID=//p' "$root/config/release.env")"

export THEO_LIBRARY="$work/Application Support/Theo Notes" THEO_APPLICATIONS="$work/Applications" THEO_DESKTOP="$work/Desktop" \
  THEO_OLD_GROUP="$work/Group/$legacy_team.com.truebrewbirdie.notes" LSREGISTER="$work/lsregister" LSOF="$work/lsof"
mkdir -p "$THEO_LIBRARY/Attachments" "$THEO_APPLICATIONS" "$THEO_DESKTOP" "$work/Group"
printf '#!/bin/sh\necho "lsregister $*" >> "%s/calls"\n' "$work" > "$work/lsregister"
# lsof: reports "in use" when the file $work/in-use exists.
printf '#!/bin/sh\n[ -e "%s/in-use" ]\n' "$work" > "$work/lsof"
chmod +x "$work/lsregister" "$work/lsof"

make_library() { # <dir> <notes>
  sqlite3 "$1/Baerchen.sqlite" "PRAGMA journal_mode=wal; CREATE TABLE note(id INTEGER PRIMARY KEY, text TEXT); CREATE TABLE tag(id INTEGER PRIMARY KEY); CREATE TABLE attachment(id INTEGER PRIMARY KEY); CREATE TABLE grdb_migrations(identifier TEXT PRIMARY KEY);
    INSERT INTO grdb_migrations VALUES ('v14-sync-capture-before-upload'),('v15-focus');
    INSERT INTO tag VALUES (1),(2); INSERT INTO attachment VALUES (1);"
  for i in $(seq 1 "$2"); do sqlite3 "$1/Baerchen.sqlite" "INSERT INTO note(text) VALUES ('secret text $i')"; done
  echo file > "$1/Attachments/a.bin"
}
make_app() { # <dir> <bundle id>
  mkdir -p "$1/Contents/MacOS"
  echo "$3" > "$1/Contents/MacOS/Baerchen"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>%s</string></dict></plist>\n' "$2" > "$1/Contents/Info.plist"
}
make_library "$THEO_LIBRARY" 7
make_app "$THEO_APPLICATIONS/Theo Notes.app" com.truebrewbirdie.baerchen "old binary"

# 1. The old inbox: a missing folder and empty folder count 0, items count, only .capture folders.
"$script" inbox-count | grep -q ": 0$" || fail "missing inbox should count 0"
mkdir -p "$THEO_OLD_GROUP/CaptureInbox/one.capture" "$THEO_OLD_GROUP/CaptureInbox/two.capture" "$THEO_OLD_GROUP/CaptureInbox/three.tmp" "$THEO_OLD_GROUP/CaptureInbox/rejected"
"$script" inbox-count | grep -q ": 2$" || fail "two .capture folders should count 2"
rm -rf "$THEO_OLD_GROUP/CaptureInbox/one.capture" "$THEO_OLD_GROUP/CaptureInbox/two.capture"
"$script" inbox-count | grep -q ": 0$" || fail "a drained inbox should count 0"
ok "inbox-count counts only .capture items (a count, no names)"

# 2. The zip of the old app: a zip, verified, never overwritten, refuses the new app.
"$script" zip-old-app > "$work/out"
[ -f "$THEO_DESKTOP/Theo Notes OLD.zip" ] || fail "no zip"
[ ! -e "$THEO_DESKTOP/Theo Notes OLD.app" ] || fail "an .app was left on the Desktop"
if "$script" zip-old-app > "$work/out" 2>&1; then fail "overwrote the zip"; fi
grep -q "exists already" "$work/out" || fail "no message for an existing zip"
zip_sum="$(shasum "$THEO_DESKTOP/Theo Notes OLD.zip" | cut -d' ' -f1)"
make_app "$work/new-app/Theo Notes.app" com.truebrewbirdie.theonotes "new"
THEO_APPLICATIONS="$work/new-app" THEO_DESKTOP="$work/Desktop2" "$script" zip-old-app > "$work/out" 2>&1 && fail "zipped the NEW app as the old one"
grep -q "not the old app" "$work/out" || fail "no message for the new app"
ok "zip-old-app writes a verified zip once and refuses the new app"

# 3. Snapshot is read only and prints counts.
before="$("$script" snapshot)"
echo "$before" | grep -q "^notes=7$" && echo "$before" | grep -q "^tags=2$" && echo "$before" | grep -q "^attachments=1$" || fail "snapshot counts wrong: $before"
echo "$before" | grep -q "^quick_check=ok$" || fail "quick_check missing"
if echo "$before" | grep -q "secret text"; then fail "snapshot printed note text"; fi
ok "snapshot prints counts only"

# 4. backup-folder refuses while the library is open, then copies and compares.
touch "$work/in-use"
if "$script" backup-folder > "$work/out" 2>&1; then fail "copied an open library"; fi
grep -q "still has the library open" "$work/out" || fail "no message for an open library"
[ ! -e "$THEO_DESKTOP/Theo Notes pre-cutover" ] || fail "a copy was started on an open library"
rm "$work/in-use"
"$script" backup-folder > "$work/out" || { cat "$work/out" >&2; fail "backup-folder failed"; }
grep -q "folder copy equals the library" "$work/out" || fail "no equality line"
[ -f "$THEO_DESKTOP/Theo Notes pre-cutover/Attachments/a.bin" ] || fail "attachments not copied"
# A second backup (after the share inbox was drained: one more note) goes to "... 2"; the first stays; a third run refuses.
sqlite3 "$THEO_LIBRARY/Baerchen.sqlite" "INSERT INTO note(text) VALUES ('a drained share')"
"$script" backup-folder > "$work/out" || { cat "$work/out" >&2; fail "the second backup failed"; }
grep -q "pre-cutover 2" "$work/out" || fail "the second backup is not named '... 2'"
[ "$(sqlite3 "$THEO_DESKTOP/Theo Notes pre-cutover/Baerchen.sqlite" 'SELECT COUNT(*) FROM note')" = 7 ] || fail "the first backup changed"
[ "$(sqlite3 "$THEO_DESKTOP/Theo Notes pre-cutover 2/Baerchen.sqlite" 'SELECT COUNT(*) FROM note')" = 8 ] || fail "the second backup is wrong"
if "$script" backup-folder > "$work/out" 2>&1; then fail "overwrote a folder copy"; fi
before="$("$script" snapshot)"
ok "backup-folder copies a quit library, compares counts, makes a second copy, never overwrites"

# 5. The cutover happens: the library is migrated (v16) and changes. The old app could not open it any more.
sqlite3 "$THEO_LIBRARY/Baerchen.sqlite" "INSERT INTO grdb_migrations VALUES ('v16-cloudkit-native'); INSERT INTO note(text) VALUES ('after cutover'); DELETE FROM tag;"
make_app "$THEO_APPLICATIONS/Theo Notes.app" com.truebrewbirdie.theonotes "new binary"
echo "$("$script" snapshot)" | grep -q "^notes=9$" || fail "setup: the migrated library should have 9 notes"

# 6. Rollback: refuses while open; the old app comes back from the zip; the folder comes back; the migrated one is kept aside.
touch "$work/in-use"
if "$script" restore-folder > "$work/out" 2>&1; then fail "restored over an open library"; fi
rm "$work/in-use"
"$script" restore-old-app > "$work/out" || { cat "$work/out" >&2; fail "restore-old-app failed"; }
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$THEO_APPLICATIONS/Theo Notes.app/Contents/Info.plist")" = com.truebrewbirdie.baerchen ] || fail "the old app is not back"
[ "$(cat "$THEO_APPLICATIONS/Theo Notes.app/Contents/MacOS/Baerchen")" = "old binary" ] || fail "not the old binary"
grep -q "lsregister -f $THEO_APPLICATIONS/Theo Notes.app" "$work/calls" || fail "the restored app was not registered"
"$script" restore-folder > "$work/out" || { cat "$work/out" >&2; fail "restore-folder failed"; }
after="$("$script" snapshot)"
[ "$after" = "$before" ] || { echo "$after" >&2; fail "the restored library differs from the one before the cutover"; }
echo "$after" | grep -q "v16" && fail "the restored library still has the new migration"
aside="$(ls -d "$work/Application Support/Theo Notes.after-cutover-"* | head -1)"
[ "$(sqlite3 "$aside/Baerchen.sqlite" 'SELECT COUNT(*) FROM note')" = 9 ] || fail "the post-cutover library was not kept aside intact"
grep -q "kept at: $aside" "$work/out" || fail "the aside folder is not named in the output"
grep -q "restoring from: .*pre-cutover 2" "$work/out" || fail "restore-folder did not use the newest copy"
[ "$(shasum "$THEO_DESKTOP/Theo Notes OLD.zip" | cut -d' ' -f1)" = "$zip_sum" ] || fail "the zip was touched"
[ -d "$THEO_DESKTOP/Theo Notes pre-cutover" ] || fail "the pre-cutover copy was consumed"
ok "rollback restores the old app from the zip and the pre-cutover folder, keeps the migrated library aside"

# 7. restore-old-app does not replace a foreign bundle.
make_app "$THEO_APPLICATIONS/Theo Notes.app" com.example.other "foreign"
if "$script" restore-old-app > "$work/out" 2>&1; then fail "replaced a foreign bundle"; fi
grep -q "unexpected bundle id" "$work/out" || fail "no message for a foreign bundle"
ok "restore-old-app leaves a foreign bundle alone"

# 8. preflight: static gate on the old app's profile expiry and the zip. The `security` tool is a stub that prints a profile.
make_app "$THEO_APPLICATIONS/Theo Notes.app" com.truebrewbirdie.baerchen "old binary"
echo profile > "$THEO_APPLICATIONS/Theo Notes.app/Contents/embedded.provisionprofile"
expiry_stub() { # <ISO date>
  printf '#!/bin/sh\ncat <<PLIST\n<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>ExpirationDate</key><date>%s</date></dict></plist>\nPLIST\n' "$1" > "$work/security"
  chmod +x "$work/security"
}
export SECURITY="$work/security"
now_epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' 2026-10-31T12:00:00Z +%s)"
export THEO_NOW="$now_epoch"
expiry_stub 2026-11-04T06:51:42Z
"$script" preflight > "$work/out" 2>&1 || { cat "$work/out" >&2; fail "preflight refused a profile with days left"; }
grep -q "expires: 2026-11-04T06:51:42Z" "$work/out" && grep -q "preflight: ok" "$work/out" || fail "preflight did not print the expiry and ok"
expiry_stub 2026-11-01T11:00:00Z
if "$script" preflight > "$work/out" 2>&1; then fail "preflight accepted a profile expiring in 23 hours"; fi
grep -q "expires within 24 hours" "$work/out" && grep -q "coordinator renews" "$work/out" || fail "no renew message for an expiring profile"
expiry_stub 2026-10-30T00:00:00Z
if "$script" preflight > "$work/out" 2>&1; then fail "preflight accepted an expired profile"; fi
expiry_stub 2026-11-04T06:51:42Z
mv "$THEO_DESKTOP/Theo Notes OLD.zip" "$work/zip.saved"
if "$script" preflight > "$work/out" 2>&1; then fail "preflight accepted a missing zip"; fi
grep -q "no verified zip" "$work/out" || fail "no message for a missing zip"
echo "not a zip" > "$THEO_DESKTOP/Theo Notes OLD.zip"
if "$script" preflight > "$work/out" 2>&1; then fail "preflight accepted a broken zip"; fi
mv "$work/zip.saved" "$THEO_DESKTOP/Theo Notes OLD.zip"
make_app "$THEO_APPLICATIONS/Theo Notes.app" com.truebrewbirdie.theonotes "new"
if "$script" preflight > "$work/out" 2>&1; then fail "preflight accepted the new app as the old one"; fi
make_app "$THEO_APPLICATIONS/Theo Notes.app" com.truebrewbirdie.baerchen "old binary"
rm "$THEO_APPLICATIONS/Theo Notes.app/Contents/embedded.provisionprofile"
if "$script" preflight > "$work/out" 2>&1; then fail "preflight accepted an app without a profile"; fi
ok "preflight refuses an expiring or expired profile, a missing or broken zip, the new app and a missing profile"
echo "cutover-safety tests: ok"
