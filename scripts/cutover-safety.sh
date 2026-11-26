#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

# The safety steps of Jan's cutover session (rename stage 2, B7), one command per step so nothing is typed by hand
#
#   scripts/cutover-safety.sh preflight        the gate before an install: refuses unless the old app is still launchable for at least 24
#                                              more hours (its embedded profile, read statically) and its zip exists and verifies
#   scripts/cutover-safety.sh inbox-count      how many share items wait in the OLD App Group inbox (a count only)
#   scripts/cutover-safety.sh zip-old-app      zip the installed OLD app to ~/Desktop/Theo Notes OLD.zip (a zip, never an .app,
#                                              so LaunchServices does not register it)
#   scripts/cutover-safety.sh snapshot         notes / tags / attachments / quick_check / migrations of the library (read only)
#   scripts/cutover-safety.sh backup-folder    copy the quit library to ~/Desktop/Theo Notes pre-cutover and check the counts; run
#                                              again after the share inbox was drained and the copy is named "... pre-cutover 2"
#   scripts/cutover-safety.sh restore-old-app  put the old app back from the zip
#   scripts/cutover-safety.sh restore-folder   put the pre-cutover library folder back; the current one is MOVED ASIDE, never deleted
#
# Why a folder copy and not only the product's own backup: the installed old app refuses a library that a newer build has
# migrated (v16 to v18; it contains LibraryOpenError.newerThanThisBuild and knows no migration after v14/v15), so it can neither
# open the migrated library nor restore a backup into it. Rollback therefore puts the pre-cutover FOLDER back, never the migrated
# database.
#
# Paths come from the environment so the tests can run in a temp directory: THEO_LIBRARY (default ~/Library/Application Support/Theo Notes),
# THEO_APPLICATIONS (~/Applications), THEO_DESKTOP (~/Desktop), THEO_OLD_GROUP (the old App Group container), LSREGISTER, LSOF,
# SECURITY (the `security` tool), THEO_NOW (epoch seconds) and THEO_MIN_HOURS (default 24) for the expiry gate.
# Counts only; no note text is read or printed. Nothing here touches the Keychain.
set -euo pipefail

library="${THEO_LIBRARY:-$HOME/Library/Application Support/Theo Notes}"
applications="${THEO_APPLICATIONS:-$HOME/Applications}"
desktop="${THEO_DESKTOP:-$HOME/Desktop}"
legacy_team="$(sed -n 's/^THEONOTES_LEGACY_TEAM_ID=//p' "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config/release.env")"
old_group="${THEO_OLD_GROUP:-$HOME/Library/Group Containers/$legacy_team.com.truebrewbirdie.notes}"
lsr="${LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
lsof_cmd="${LSOF:-lsof}"
security_cmd="${SECURITY:-security}"
min_hours="${THEO_MIN_HOURS:-24}"
installed="$applications/Theo Notes.app"
zip="$desktop/Theo Notes OLD.zip"
folder_copy="$desktop/Theo Notes pre-cutover"
old_id="com.truebrewbirdie.baerchen"
new_id="com.truebrewbirdie.theonotes"

die() { echo "stop: $*" >&2; exit 1; }
bundle_id_of() { /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$1/Contents/Info.plist" 2>/dev/null || true; }

library_in_use() { # <library>  true when a process has the database open
  local db="$1/Baerchen.sqlite"
  [ -e "$db" ] || return 1
  "$lsof_cmd" "$db" "$db-wal" >/dev/null 2>&1
}

# One line per number; the migrations are code identifiers, not content. No -readonly on purpose: a QUIT library in WAL mode has no
# -shm file and sqlite3 -readonly then fails with 'unable to open database file' (measured on a copy of the real library); a normal
# open only reads, replays a leftover write-ahead log and leaves the data unchanged.
snapshot_of() { # <library>
  local db="$1/Baerchen.sqlite"
  [ -f "$db" ] || die "no library database at $db"
  echo "notes=$(sqlite3 "$db" 'SELECT COUNT(*) FROM note')"
  echo "tags=$(sqlite3 "$db" 'SELECT COUNT(*) FROM tag')"
  echo "attachments=$(sqlite3 "$db" 'SELECT COUNT(*) FROM attachment')"
  echo "attachment_files=$(find "$1/Attachments" -type f 2>/dev/null | wc -l | tr -d ' ' || true)"
  echo "quick_check=$(sqlite3 "$db" 'PRAGMA quick_check')"
  echo "migrations=$(sqlite3 "$db" 'SELECT identifier FROM grdb_migrations ORDER BY identifier' | tr '\n' ',')"
}

# Copies a library: the database through SQLite's backup API (consistent, includes the write-ahead log), everything else through
# ditto; the live socket and lock files are skipped.
copy_library() { # <from> <to>
  mkdir -p "$2"
  local entry name
  shopt -s dotglob nullglob
  for entry in "$1"/*; do
    name="$(basename "$entry")"
    case "$name" in
      Baerchen.sqlite|Baerchen.sqlite-wal|Baerchen.sqlite-shm|app.sock|app.sock.lock|.DS_Store) continue ;;
    esac
    /usr/bin/ditto "$entry" "$2/$name"
  done
  shopt -u dotglob nullglob
  sqlite3 "$1/Baerchen.sqlite" ".backup '$2/Baerchen.sqlite'"
}

# True when the zip exists and holds the old app (extracts it to a temp folder and reads the bundle id; nothing is launched).
zip_holds_old_app() {
  [ -f "$zip" ] || return 1
  local check ok=1
  check="$(mktemp -d "${TMPDIR:-/tmp}/theo-zipcheck.XXXXXX")"
  if /usr/bin/ditto -x -k "$zip" "$check" 2>/dev/null && [ "$(bundle_id_of "$check/Theo Notes.app")" = "$old_id" ]; then ok=0; fi
  rm -rf "$check"
  return "$ok"
}

case "${1:-}" in
  preflight)
    # Read only and static: nothing is launched, nothing is written. The old app is the way back; it cannot start once its
    # embedded provisioning profile has expired, so an install is refused unless it stays launchable for at least $min_hours more hours.
    [ -d "$installed" ] || die "no app at $installed"
    [ "$(bundle_id_of "$installed")" = "$old_id" ] || die "$installed is not the old app (bundle id '$(bundle_id_of "$installed")', expected $old_id)"
    profile="$installed/Contents/embedded.provisionprofile"
    [ -f "$profile" ] || die "the old app has no embedded profile at $profile"
    expiry="$("$security_cmd" cms -D -i "$profile" 2>/dev/null | /usr/bin/plutil -extract ExpirationDate raw -o - - 2>/dev/null || true)"
    [ -n "$expiry" ] || die "cannot read the expiry date of the old app's profile"
    expiry_epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$expiry" +%s 2>/dev/null || true)"
    [ -n "$expiry_epoch" ] || die "cannot read the profile expiry '$expiry'"
    now="${THEO_NOW:-$(date +%s)}"
    left=$(( (expiry_epoch - now) / 3600 ))
    echo "old app profile expires: $expiry ($left hours from now; the gate needs more than $min_hours)"
    if [ $(( expiry_epoch - now )) -le $(( min_hours * 3600 )) ]; then
      die "the old app's profile expires within $min_hours hours or is expired, so the old app could not be started as the way back. Do not install. The coordinator renews the old free profile first (clean Production build on the old team and install, the documented procedure); then run this again"
    fi
    zip_holds_old_app || die "no verified zip of the old app at $zip (run: scripts/cutover-safety.sh zip-old-app)"
    echo "zip of the old app: $zip holds $old_id"
    echo "preflight: ok"
    ;;

  inbox-count)
    # Share items wait as <id>.capture folders in <old group>/CaptureInbox until the app drains them (it does on launch and on
    # activation). A missing folder means none.
    count="$(find "$old_group/CaptureInbox" -maxdepth 1 -name '*.capture' 2>/dev/null | wc -l | tr -d ' ' || true)"
    echo "share items waiting in the old inbox: $count"
    ;;

  zip-old-app)
    [ -d "$installed" ] || die "no app at $installed"
    [ "$(bundle_id_of "$installed")" = "$old_id" ] || die "$installed is not the old app (bundle id '$(bundle_id_of "$installed")', expected $old_id); it may already be the new one"
    [ ! -e "$zip" ] || die "$zip exists already; nothing was overwritten"
    mkdir -p "$desktop"
    /usr/bin/ditto -c -k --keepParent "$installed" "$zip"
    check="$(mktemp -d "${TMPDIR:-/tmp}/theo-zipcheck.XXXXXX")"
    /usr/bin/ditto -x -k "$zip" "$check"
    [ "$(bundle_id_of "$check/Theo Notes.app")" = "$old_id" ] || { rm -rf "$check"; die "the zip does not contain the old app; remove $zip and try again"; }
    rm -rf "$check"
    echo "zipped: $zip ($(du -h "$zip" | cut -f1)); it holds $old_id"
    ;;

  snapshot)
    snapshot_of "${2:-$library}"
    ;;

  backup-folder)
    library_in_use "$library" && die "Theo Notes (or the theonotes tool) still has the library open. Quit it first."
    if [ -e "$folder_copy" ]; then
      folder_copy="$folder_copy 2"   # the second backup, taken after the share inbox was drained
      [ ! -e "$folder_copy" ] || die "$folder_copy exists already too; nothing was overwritten"
    fi
    snapshot_of "$library" > "$folder_copy.snapshot.tmp"
    copy_library "$library" "$folder_copy"
    snapshot_of "$folder_copy" > "$folder_copy.copy.tmp"
    if diff -q "$folder_copy.snapshot.tmp" "$folder_copy.copy.tmp" >/dev/null; then
      cat "$folder_copy.snapshot.tmp" | grep -v '^migrations=' ; echo "folder copy equals the library: $folder_copy"
      rm -f "$folder_copy.snapshot.tmp" "$folder_copy.copy.tmp"
    else
      diff "$folder_copy.snapshot.tmp" "$folder_copy.copy.tmp" >&2 || true
      rm -f "$folder_copy.snapshot.tmp" "$folder_copy.copy.tmp"
      die "the copy differs from the library; do not continue (the copy was left at $folder_copy)"
    fi
    ;;

  restore-old-app)
    [ -f "$zip" ] || die "no $zip"
    current="$(bundle_id_of "$installed")"
    [ -z "$current" ] || [ "$current" = "$new_id" ] || [ "$current" = "$old_id" ] || die "$installed has the unexpected bundle id '$current'; not replaced"
    check="$(mktemp -d "${TMPDIR:-/tmp}/theo-oldapp.XXXXXX")"
    /usr/bin/ditto -x -k "$zip" "$check"
    [ "$(bundle_id_of "$check/Theo Notes.app")" = "$old_id" ] || { rm -rf "$check"; die "the zip does not contain the old app"; }
    mkdir -p "$applications"
    [ ! -e "$installed" ] || "$lsr" -u "$installed" 2>/dev/null || true
    rm -rf "$installed"
    /usr/bin/ditto "$check/Theo Notes.app" "$installed"
    rm -rf "$check"
    "$lsr" -f "$installed"
    echo "old app restored: $installed ($old_id). It runs until its profile expires on 2026-11-04."
    ;;

  restore-folder)
    [ -d "$folder_copy" ] || die "no pre-cutover copy at $folder_copy"
    # The newest copy is the state of the old app just before the install (the second one exists when shares were drained).
    if [ -d "$folder_copy 2" ]; then folder_copy="$folder_copy 2"; fi
    echo "restoring from: $folder_copy"
    library_in_use "$library" && die "Theo Notes (or the theonotes tool) still has the library open. Quit it first."
    library_in_use "$folder_copy" && die "something has the pre-cutover copy open"
    snapshot_of "$folder_copy" > "$folder_copy.expected.tmp"
    aside="$library.after-cutover-$(date +%Y%m%d-%H%M%S)"
    if [ -e "$library" ]; then mv "$library" "$aside"; fi
    copy_library "$folder_copy" "$library"
    if snapshot_of "$library" | diff -q - "$folder_copy.expected.tmp" >/dev/null; then
      grep -v '^migrations=' "$folder_copy.expected.tmp"
      rm -f "$folder_copy.expected.tmp"
      echo "restored: $library equals the pre-cutover copy; the library as it was after the cutover is kept at: ${aside}"
    else
      rm -f "$folder_copy.expected.tmp"
      die "the restored library differs from the pre-cutover copy; the library as it was is at ${aside}"
    fi
    ;;

  *)
    sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 2
    ;;
esac
