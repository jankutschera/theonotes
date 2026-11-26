#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

# Rehearsal 1 of the identity flip (rename stage 2, plan task B6; R55).
#
# What it proves, on a COPY of Jan's library and a throw-away build: that the app with the FLIPPED identity
# (bundle root com.truebrewbirdie.theonotes, ad hoc signed, no team) opens a library of the old identity without
# changing a count, keeps the database under its frozen name (Baerchen.sqlite), reads an old
# .baerchen-backup, copies the fixture preferences once, and leaves the frozen crypto labels alone.
#
# What it never does (dispatch rules)
#   - it never writes to the source library; the source is only read (ditto, and `sqlite3 -readonly ... .backup`
#     for the database, SQLite's own consistent-copy path, which also works while the installed app runs);
#   - it never launches, opens or builds the Production identity, and never touches ~/Applications;
#   - it never kills by name: the one process it starts is stopped by its own PID;
#   - it prints COUNTS and digests only, never a title, tag name, path inside a note or any note text.
#
# The flip is applied to a throw-away `git archive HEAD` copy of the tracked tree: the bundle root is a build-setting
# override on the xcodebuild command line, and the one Swift constant that cannot be a build setting
# (LegacyNames.bundleRoot) is changed in that copy only. Nothing is ever committed from it; the worktree is not edited.
#
# Usage: scripts/rehearse-identity-flip.sh [--keep] [--evidence FILE]
#   --keep           do not delete /tmp/flip-rehearsal-<timestamp> at the end (default: delete it)
#   --evidence FILE  where the counts-only report is written (default docs/release/evidence/flip-rehearsal-1.txt)
# Environment:
#   SOURCE_LIBRARY        default "$HOME/Library/Application Support/Theo Notes"
#   EDITOR_NODE_MODULES   web/editor/node_modules to link into the copy (default: the one in this tree)
#   FLIP_BUNDLE_ROOT      default com.truebrewbirdie.theonotes
#   LAUNCH_SETTLE_SECONDS default 15 (how long the app runs after it opened the database)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

KEEP=0
EVIDENCE="$ROOT/docs/release/evidence/flip-rehearsal-1.txt"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1 ;;
    --evidence) EVIDENCE="$2"; shift ;;
    *) echo "usage: scripts/rehearse-identity-flip.sh [--keep] [--evidence FILE]" >&2; exit 2 ;;
  esac
  shift
done

SOURCE_LIBRARY="${SOURCE_LIBRARY:-$HOME/Library/Application Support/Theo Notes}"
EDITOR_NODE_MODULES="${EDITOR_NODE_MODULES:-$ROOT/web/editor/node_modules}"
NEW_ROOT="${FLIP_BUNDLE_ROOT:-com.truebrewbirdie.theonotes}"
OLD_ROOT="com.truebrewbirdie.baerchen"
SETTLE="${LAUNCH_SETTLE_SECONDS:-15}"
STAMP="$(date +%Y%m%d-%H%M%S)"
WORK="/tmp/flip-rehearsal-$STAMP"
LIB="$WORK/library-copy"
SRC="$WORK/src"
DD="$WORK/DerivedData"
FAKE_HOME="$WORK/home"
PIDS=()

case "$WORK" in /tmp/flip-rehearsal-*) ;; *) echo "refusing: work folder outside /tmp" >&2; exit 2 ;; esac
[ -d "$SOURCE_LIBRARY" ] && [ -f "$SOURCE_LIBRARY/Baerchen.sqlite" ] || { echo "no library with Baerchen.sqlite at: $SOURCE_LIBRARY" >&2; exit 2; }
[ -d "$EDITOR_NODE_MODULES" ] || { echo "web/editor/node_modules not found; set EDITOR_NODE_MODULES" >&2; exit 2; }
for tool in git xcodegen xcodebuild swift sqlite3 ditto shasum python3 lsof plutil codesign; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 2; }
done
if ! git -C "$ROOT" diff --quiet HEAD -- || [ -n "$(git -C "$ROOT" ls-files --others --exclude-standard | head -1)" ]; then
  echo "note: the working tree has uncommitted changes; the rehearsal builds HEAD ($(git -C "$ROOT" rev-parse --short HEAD)) only" >&2
fi

# The builds and the launch may create preference files for the flipped bundle id and throw-away test suites in the
# real preferences folder (cfprefsd ignores CFFIXED_USER_HOME). They are the rehearsal's own artefacts; remember
# whether the domain existed before anything ran and remove what the rehearsal created at the end.
DOMAIN_BEFORE=0; defaults read "$NEW_ROOT.dev" >/dev/null 2>&1 && DOMAIN_BEFORE=1
REPORT="$WORK/report.txt"
FAILS=0
mkdir -p "$WORK"
say() { printf '%s\n' "$*" | tee -a "$REPORT"; }
check() { # check <PASS|FAIL|NOT VERIFIED> <name> <detail>
  [ "$1" = FAIL ] && FAILS=$((FAILS + 1))
  say "[$1] $2 -- $3"
}
cleanup() {
  for pid in ${PIDS[@]+"${PIDS[@]}"}; do
    if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null || true; fi
  done
  if [ "$DOMAIN_BEFORE" = 0 ]; then
    defaults delete "$NEW_ROOT.dev" >/dev/null 2>&1 || true
    rm -f "$HOME/Library/Preferences/$NEW_ROOT.dev.plist"
  fi
  rm -f "$HOME/Library/Preferences"/test.theo.rehearsal.*.plist
  mkdir -p "$(dirname "$EVIDENCE")"
  cp "$REPORT" "$EVIDENCE" 2>/dev/null || true
  if [ "$KEEP" = 1 ]; then
    echo "kept: $WORK"
  else
    rm -rf "$WORK"
    [ -e "$WORK" ] && echo "WARNING: $WORK still exists" || echo "deleted: $WORK"
  fi
}
trap cleanup EXIT

say "flip rehearsal 1 -- $(date -u +%Y-%m-%dT%H:%M:%SZ) -- HEAD $(git -C "$ROOT" rev-parse --short HEAD)"
say "work folder: $WORK (deleted at the end unless --keep)"
say "flip: bundle root $OLD_ROOT -> $NEW_ROOT, dev identity, ad hoc signed, no team"

# ---------------------------------------------------------------- 1. copy the library, read-only on the source
mkdir -p "$LIB"
shopt -s dotglob nullglob
for entry in "$SOURCE_LIBRARY"/*; do
  name="$(basename "$entry")"
  case "$name" in
    Baerchen.sqlite|Baerchen.sqlite-wal|Baerchen.sqlite-shm|app.sock.lock|.DS_Store) continue ;;
  esac
  ditto "$entry" "$LIB/$name"
done
shopt -u dotglob nullglob
sqlite3 -readonly "$SOURCE_LIBRARY/Baerchen.sqlite" ".backup '$LIB/Baerchen.sqlite'"
DB="$LIB/Baerchen.sqlite"
say "copied the library (database through SQLite's backup API; attachments, journal, backups through ditto)"

# ---------------------------------------------------------------- 2. metrics (counts and digests only)
digest() { shasum -a 256 | cut -c1-16; }
metrics() { # metrics <db> <library folder>  -> key=value lines
  local db="$1" dir="$2"
  echo "notes_total=$(sqlite3 "$db" 'SELECT COUNT(*) FROM note')"
  echo "notes_locked=$(sqlite3 "$db" 'SELECT COUNT(*) FROM note WHERE isLocked = 1')"
  echo "notes_trashed=$(sqlite3 "$db" 'SELECT COUNT(*) FROM note WHERE trashedAt IS NOT NULL')"
  echo "tags=$(sqlite3 "$db" 'SELECT COUNT(*) FROM tag')"
  echo "attachment_rows=$(sqlite3 "$db" 'SELECT COUNT(*) FROM attachment')"
  echo "attachment_files=$(find "$dir/Attachments" -type f 2>/dev/null | wc -l | tr -d ' ')"
  echo "quick_check=$(sqlite3 "$db" 'PRAGMA quick_check')"
  echo "migrations=$(sqlite3 "$db" 'SELECT identifier FROM grdb_migrations ORDER BY identifier' | tr '\n' ',')"
  echo "schema_digest=$(sqlite3 "$db" "SELECT type||name||ifnull(sql,'') FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY name" | digest)"
  echo "envelope_digest=$(sqlite3 "$db" 'SELECT hex(envelope) FROM crypto_envelope' | digest)"
  echo "locked_payload_digest=$(sqlite3 "$db" 'SELECT id||hex(encryptedPayload) FROM note WHERE isLocked = 1 ORDER BY id' | digest)"
  echo "themes=$(sqlite3 "$db" "SELECT key||'='||value FROM setting WHERE key IN ('lightTheme','darkTheme') ORDER BY key" | tr '\n' ' ')"
  echo "database_files=$(cd "$dir" && ls | grep -E '^(Baerchen|Library)\.sqlite$' | tr '\n' ' ')"
}
BEFORE="$WORK/before.txt"; AFTER="$WORK/after.txt"
metrics "$DB" "$LIB" > "$BEFORE"
INODE_BEFORE="$(stat -f %i "$DB")"
say "before the launch: $(tr '\n' ';' < "$BEFORE" | sed 's/;/; /g')"

# ---------------------------------------------------------------- 3. throw-away flipped source tree
mkdir -p "$SRC"
git -C "$ROOT" archive HEAD | tar -x -C "$SRC"
ln -s "$EDITOR_NODE_MODULES" "$SRC/web/editor/node_modules"
NAMES_FILE="$(find "$SRC/Packages" -name LegacyNames.swift -not -path '*/.build/*' | head -1)"
[ -n "$NAMES_FILE" ] || { check FAIL "flip applied" "LegacyNames.swift not found in the copy"; exit 1; }
sed -i '' "s|static let bundleRoot = \"$OLD_ROOT\"|static let bundleRoot = \"$NEW_ROOT\"|" "$NAMES_FILE"
grep -q "static let bundleRoot = \"$NEW_ROOT\"" "$NAMES_FILE" || { check FAIL "flip applied" "bundleRoot was not changed in the copy"; exit 1; }
say "flipped constants: LegacyNames.bundleRoot in the throw-away copy; THEONOTES_BUNDLE_ROOT as a build-setting override"

# ---------------------------------------------------------------- 4. package checks on the flipped copy
OLD_BACKUP="$(ls -1tr "$LIB/Backups"/*.baerchen-backup 2>/dev/null | head -1 || true)"
CORE_JSON="$WORK/core-checks.json"
if [ -n "$OLD_BACKUP" ]; then
  mkdir -p "$WORK/old-backup"
  cp "$OLD_BACKUP" "$WORK/old-backup/old.baerchen-backup"
  ( cd "$SRC" && THEONOTES_REHEARSAL_BACKUP="$WORK/old-backup/old.baerchen-backup" THEONOTES_REHEARSAL_OUT="$CORE_JSON" \
      swift test --package-path Packages/TheoNotesCore --filter FlipRehearsalChecks --filter 'IdentityPinsTests/test_frozen' \
      > "$WORK/core-tests.log" 2>&1 ) && CORE_RC=0 || CORE_RC=$?
  if [ "$CORE_RC" = 0 ] && [ -f "$CORE_JSON" ]; then
    summary="$(python3 -I - "$CORE_JSON" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
print("; ".join(f"{k}={r[k]}" for k in sorted(r)))
PY
)"
    check PASS "old .baerchen-backup restores into a second temporary library" "$summary"
    grep -Eq "test_frozen_labels_bytes|test_frozen_label_vectors" "$WORK/core-tests.log" \
      && check PASS "frozen labels: the 12 pinned strings and the crypto/sync vectors still decrypt and verify with the flipped bundle root" "IdentityPinsTests/test_frozen* passed in the flipped copy" \
      || check FAIL "frozen label tests did not run" "see core-tests.log"
  else
    check FAIL "package checks in the flipped copy" "swift test exit $CORE_RC; last lines: $(tail -5 "$WORK/core-tests.log" | tr '\n' ' ')"
  fi
else
  check "NOT VERIFIED" "old .baerchen-backup restore" "the library copy has no .baerchen-backup in Backups"
fi

# ---------------------------------------------------------------- 5. build the dev identity with the flipped constants,
#                                and run the preferences check inside the same build
PREFS_FIXTURE="$WORK/legacy-prefs.plist"
PREFS_JSON="$WORK/prefs-checks.json"
cp "$ROOT/Fixtures/rehearsal/legacy-prefs.plist" "$PREFS_FIXTURE"
mkdir -p "$FAKE_HOME/Library/Application Support" "$FAKE_HOME/Library/Preferences" "$FAKE_HOME/Library/Caches" "$FAKE_HOME/Library/Logs"
cp "$PREFS_FIXTURE" "$FAKE_HOME/Library/Preferences/$OLD_ROOT.dev.plist"
( cd "$SRC" && xcodegen generate > "$WORK/xcodegen.log" 2>&1 \
  && TEST_RUNNER_THEONOTES_REHEARSAL_PREFS_FIXTURE="$PREFS_FIXTURE" TEST_RUNNER_THEONOTES_REHEARSAL_PREFS_OUT="$PREFS_JSON" \
     xcodebuild -project TheoNotes.xcodeproj -scheme TheoNotes -configuration Debug -derivedDataPath "$DD" \
       THEONOTES_BUNDLE_ROOT="$NEW_ROOT" test -only-testing:TheoNotesMacTests/FlipRehearsalPreferencesChecks \
       > "$WORK/xcodebuild.log" 2>&1 ) && BUILD_RC=0 || BUILD_RC=$?
APP="$DD/Build/Products/Debug/Theo Notes Dev.app"
if [ "$BUILD_RC" != 0 ] || [ ! -d "$APP" ]; then
  check FAIL "build of the flipped dev identity" "xcodebuild exit $BUILD_RC; last lines: $(tail -8 "$WORK/xcodebuild.log" | tr '\n' ' ')"
  exit 1
fi
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")"
SIGNING="$(codesign -dv "$APP" 2>&1 | grep -E '^(Signature|TeamIdentifier)=' | tr '\n' ' ')"
[ "$BUNDLE_ID" = "$NEW_ROOT.dev" ] \
  && check PASS "built bundle id is the flipped dev id" "$BUNDLE_ID; $SIGNING" \
  || check FAIL "built bundle id" "expected $NEW_ROOT.dev, got $BUNDLE_ID"
case "$SIGNING" in *"Signature=adhoc"*) ;; *) check FAIL "ad hoc signature" "$SIGNING" ;; esac

if [ -f "$PREFS_JSON" ]; then
  python3 -I - "$PREFS_JSON" > "$WORK/prefs-verdict.txt" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
ok = (r["copiedFirstRun"] == r["allowListedInFixture"] > 0 and r["copiedSecondRun"] == 0 and r["flagSet"]
      and not r["syncFlagsCopied"] and not r["unlistedCopied"] and r["identityIsDev"]
      and r["syncKeychainService"] == "com.truebrewbirdie.theonotes.sync"
      and r["vaultKeychainService"] == "com.truebrewbirdie.theonotes.note-vault"
      and r["productionDomainMapsTo"] == "com.truebrewbirdie.baerchen"
      and r["devDomainMapsTo"] == "com.truebrewbirdie.baerchen.dev")
print(("PASS" if ok else "FAIL") + "|" + "; ".join(f"{k}={r[k]}" for k in sorted(r)))
PY
  verdict="$(cat "$WORK/prefs-verdict.txt")"
  check "${verdict%%|*}" "preferences: allow-list copied once, sync flags and unlisted keys never, flag set; Keychain services follow the flipped root" "${verdict#*|}"
else
  check FAIL "preferences check" "the gated Mac test wrote no result (see xcodebuild.log)"
fi

# ---------------------------------------------------------------- 6. launch the dev build on the copy, quit it by PID
SCREEN_LOCKED="$(ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked | grep -c true || true)"
EXE="$APP/Contents/MacOS/Theo Notes Dev"
if [ "$SCREEN_LOCKED" != 0 ]; then
  check "NOT VERIFIED" "launch of the flipped dev build on the copy" "the screen is locked (R34); no window test run"
else
  env CFFIXED_USER_HOME="$FAKE_HOME" "$EXE" --data-dir "$LIB" > "$WORK/launch.log" 2>&1 &
  PID=$!
  PIDS+=("$PID")
  opened=0
  for _ in $(seq 1 120); do
    kill -0 "$PID" 2>/dev/null || break
    if lsof -p "$PID" 2>/dev/null | grep -q 'Baerchen\.sqlite'; then opened=1; break; fi
    sleep 1
  done
  if [ "$opened" = 1 ]; then
    sleep "$SETTLE"
    kill -0 "$PID" 2>/dev/null \
      && check PASS "flipped dev build opened Baerchen.sqlite of the copy and stayed up $SETTLE s" "pid $PID alive" \
      || check FAIL "flipped dev build opened the library but exited within $SETTLE s" "pid $PID gone; launch.log tail: $(tail -3 "$WORK/launch.log" | tr '\n' ' ')"
  else
    check FAIL "flipped dev build did not open the library copy" "exit/early stop; launch.log tail: $(tail -3 "$WORK/launch.log" | tr '\n' ' ')"
  fi
  if kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null || true
    for _ in $(seq 1 20); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
    if kill -0 "$PID" 2>/dev/null; then kill -9 "$PID" 2>/dev/null || true; say "pid $PID needed SIGKILL"; fi
  fi
  wait "$PID" 2>/dev/null || true
  kill -0 "$PID" 2>/dev/null && check FAIL "app stopped by its PID" "pid $PID still alive" || check PASS "app stopped by its own PID" "pid $PID gone (SIGTERM is not a graceful quit; the database recovers from its WAL at the next open)"
fi

# ---------------------------------------------------------------- 7. compare before and after
metrics "$DB" "$LIB" > "$AFTER"
INODE_AFTER="$(stat -f %i "$DB")"
say "after the launch:  $(tr '\n' ';' < "$AFTER" | sed 's/;/; /g')"
val() { grep "^$2=" "$1" | cut -d= -f2-; }
for key in notes_total notes_locked notes_trashed tags attachment_rows attachment_files; do
  [ "$(val "$BEFORE" $key)" = "$(val "$AFTER" $key)" ] \
    && check PASS "$key equal before and after" "$(val "$BEFORE" $key)" \
    || check FAIL "$key changed" "before $(val "$BEFORE" $key), after $(val "$AFTER" $key)"
done
[ "$(val "$AFTER" quick_check)" = ok ] && check PASS "PRAGMA quick_check after the launch" "ok" || check FAIL "PRAGMA quick_check" "$(val "$AFTER" quick_check)"
case "$(val "$AFTER" database_files)" in
  "Baerchen.sqlite ") [ "$INODE_BEFORE" = "$INODE_AFTER" ] \
      && check PASS "Baerchen.sqlite present, same file, no Library.sqlite (REN2-R50)" "inode $INODE_BEFORE unchanged" \
      || check FAIL "Baerchen.sqlite was replaced" "inode $INODE_BEFORE -> $INODE_AFTER" ;;
  *) check FAIL "database file names" "$(val "$AFTER" database_files)" ;;
esac
# Schema: the flip changes no schema code, so the only legitimate difference is a migration that HEAD has and the
# installed app's library does not yet (the copy comes from the installed, older build). Those are listed by name
# (code identifiers, no content). A removed or renamed migration, or a schema change without a new migration, fails.
ADDED="$(comm -13 <(val "$BEFORE" migrations | tr ',' '\n' | sort) <(val "$AFTER" migrations | tr ',' '\n' | sort) | tr '\n' ' ')"
REMOVED="$(comm -23 <(val "$BEFORE" migrations | tr ',' '\n' | sort) <(val "$AFTER" migrations | tr ',' '\n' | sort) | tr '\n' ' ')"
if [ -n "$REMOVED" ]; then
  check FAIL "migrations removed or renamed" "$REMOVED"
elif [ -z "$ADDED" ]; then
  [ "$(val "$BEFORE" schema_digest)" = "$(val "$AFTER" schema_digest)" ] \
    && check PASS "no migration ran and the schema is unchanged (REN2-R50)" "schema $(val "$AFTER" schema_digest)" \
    || check FAIL "schema changed without a migration" "before $(val "$BEFORE" schema_digest), after $(val "$AFTER" schema_digest)"
else
  [ "$(val "$BEFORE" schema_digest)" != "$(val "$AFTER" schema_digest)" ] \
    && check PASS "forward migrations of HEAD ran on the older library (not caused by the flip: it changes no schema code)" "added: $ADDED" \
    || check FAIL "migrations were recorded but the schema did not change" "added: $ADDED"
fi
[ "$(val "$BEFORE" themes)" = "$(val "$AFTER" themes)" ] \
  && check PASS "stored theme ids unchanged (REN2-R50)" "${AFTER_THEMES:-$(val "$AFTER" themes)} (empty = defaults baerchen-red / baerchen-dark, nothing stored)" \
  || check FAIL "themes changed" "before $(val "$BEFORE" themes), after $(val "$AFTER" themes)"
for key in envelope_digest locked_payload_digest; do
  [ "$(val "$BEFORE" $key)" = "$(val "$AFTER" $key)" ] \
    && check PASS "$key byte-identical (locked notes untouched)" "$(val "$AFTER" $key)" \
    || check FAIL "$key changed" "before $(val "$BEFORE" $key), after $(val "$AFTER" $key)"
done
if [ "$(val "$BEFORE" notes_locked)" = 0 ]; then
  check "NOT VERIFIED" "a real locked note of the library opens with the note password" "this library has no locked notes and no vault envelope (digests are those of empty input), so there is nothing to open; the frozen-label vectors above are the proof of the decryption code"
else
  check "NOT VERIFIED" "a real locked note of the library opens with the note password" "needs Jan's password or Touch ID; the frozen-label vectors and the byte-identical envelope and locked payloads above are the proof available without it"
fi

say "---"
if [ "$FAILS" = 0 ]; then say "RESULT: no check failed"; else say "RESULT: $FAILS check(s) FAILED"; fi
[ "$FAILS" = 0 ]
