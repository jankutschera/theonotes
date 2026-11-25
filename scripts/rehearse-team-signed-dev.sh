#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

# Rehearsal 2 of the identity and team cutover (rename stage 2, plan task B6; REN2-R57 ... R62).
#
# Rehearsal 1 (scripts/rehearse-identity-flip.sh) proved that a build with the flipped bundle root opens a copy of the
# library. This one runs after the B7 cutover commit is in HEAD and uses what only the NEW TEAM adds: the dev identity
# (com.truebrewbirdie.theonotes.dev) signed by team Q446J364FH, its keychain access group, its App Group container, the share
# drain on that container, the empty vault key cache in the new group, and the counts of a library copy opened by it.
#
# What it never does (dispatch rules, REL-R37, FOC-R362):
#   - it never writes to the source library (ditto, and `sqlite3 -readonly ... .backup` for the database);
#   - it never launches, opens or builds the PRODUCTION identity, and never touches ~/Applications, Jan's keychain items or
#     his sync account; the tests it runs use throw-away keychain accounts and a throw-away library;
#   - it never kills by name: the one process it starts is stopped by its own PID;
#   - it prints COUNTS and digests only, never a note title or text.
#
# Signing (REN2-R58): `xcodebuild -allowProvisioningUpdates` with the App Store Connect key cannot create the profile of a new
# App ID ("Authentication failed ... bearer token", measured 2026-10-31), so scripts/release/asc_dev_profile.py makes the App ID,
# the capabilities and a MAC_APP_DEVELOPMENT profile through the public API and installs it. The throw-away tree (a
# `git archive HEAD` copy; the worktree is never edited) signs the app with the committed Debug settings, which name that profile
# (project.yml). The container association of the dev App ID is a portal click (Jan, "Final session" in
# docs/release/team-migration.md): while the profile does not list the container, the COPY's dev entitlements drop the four
# iCloud keys (REN2-R59) and the result says so; as soon as the profile lists it the committed entitlements are used unchanged.
#
# Usage: scripts/rehearse-team-signed-dev.sh [--keep] [--evidence FILE]
# Environment: ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID (never printed); SOURCE_LIBRARY (default "$HOME/Library/Application Support/Theo Notes");
#   EDITOR_NODE_MODULES; LAUNCH_SETTLE_SECONDS (default 15).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

KEEP=0
EVIDENCE="$ROOT/docs/release/evidence/flip-rehearsal-2.txt"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1 ;;
    --evidence) EVIDENCE="$2"; shift ;;
    *) echo "usage: scripts/rehearse-team-signed-dev.sh [--keep] [--evidence FILE]" >&2; exit 2 ;;
  esac
  shift
done

SOURCE_LIBRARY="${SOURCE_LIBRARY:-$HOME/Library/Application Support/Theo Notes}"
EDITOR_NODE_MODULES="${EDITOR_NODE_MODULES:-$ROOT/web/editor/node_modules}"
SETTLE="${LAUNCH_SETTLE_SECONDS:-15}"
TEAM="$(sed -n 's/^THEONOTES_TEAM_ID=//p' config/release.env | head -1)"
CONTAINER="$(sed -n 's/^THEONOTES_CLOUDKIT_CONTAINER=//p' config/release.env | head -1)"
ROOT_ID="$(sed -n 's/^THEONOTES_BUNDLE_ROOT=//p' config/identity.env | head -1)"
DEV_ID="$ROOT_ID.dev"
PROFILE_NAME="Theo Notes Mac Dev Development"
GROUP="$TEAM.com.truebrewbirdie.notes.dev"
STAMP="$(date +%Y%m%d-%H%M%S)"
WORK="/tmp/flip-rehearsal2-$STAMP"
LIB="$WORK/library-copy"
SRC="$WORK/src"
DD="$WORK/DerivedData"
FAKE_HOME="$WORK/home"
PIDS=()

case "$WORK" in /tmp/flip-rehearsal2-*) ;; *) echo "refusing: work folder outside /tmp" >&2; exit 2 ;; esac
[ "$TEAM" = Q446J364FH ] && [ "$ROOT_ID" = com.truebrewbirdie.theonotes ] \
  || { echo "refusing: HEAD is not the B7 cutover (team '$TEAM', bundle root '$ROOT_ID')" >&2; exit 2; }
[ -d "$SOURCE_LIBRARY" ] && [ -f "$SOURCE_LIBRARY/Baerchen.sqlite" ] || { echo "no library with Baerchen.sqlite at: $SOURCE_LIBRARY" >&2; exit 2; }
[ -d "$EDITOR_NODE_MODULES" ] || { echo "web/editor/node_modules not found; set EDITOR_NODE_MODULES" >&2; exit 2; }
: "${ASC_KEY_PATH:?ASC_KEY_PATH is not set}" "${ASC_KEY_ID:?ASC_KEY_ID is not set}" "${ASC_ISSUER_ID:?ASC_ISSUER_ID is not set}"
for tool in git xcodegen xcodebuild sqlite3 ditto shasum python3 lsof plutil codesign security openssl; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 2; }
done
if ! git -C "$ROOT" diff --quiet HEAD -- || [ -n "$(git -C "$ROOT" ls-files --others --exclude-standard | head -1)" ]; then
  echo "note: the working tree has uncommitted changes; the rehearsal builds HEAD ($(git -C "$ROOT" rev-parse --short HEAD)) only" >&2
fi

# Artefacts the builds and the test host may leave outside /tmp: the preference domain of the dev id, throw-away test suites,
# and the dev App Group container. Remember what existed before and remove only what the rehearsal created.
DOMAIN_BEFORE=0; defaults read "$DEV_ID" >/dev/null 2>&1 && DOMAIN_BEFORE=1
GROUP_FOLDER="$HOME/Library/Group Containers/$GROUP"
GROUP_BEFORE=0; [ -e "$GROUP_FOLDER" ] && GROUP_BEFORE=1
REPORT="$WORK/report.txt"
FAILS=0
mkdir -p "$WORK"
say() { printf '%s\n' "$*" | tee -a "$REPORT"; }
check() { # check <PASS|FAIL|NOT VERIFIED> <name> <detail>
  [ "$1" = FAIL ] && FAILS=$((FAILS + 1))
  say "[$1] $2 -- $3"
}
redact() { sed -E 's#(-authentication(KeyPath|KeyID|KeyIssuerID)) [^ ]+#\1 <redacted>#g'; }
cleanup() {
  for pid in ${PIDS[@]+"${PIDS[@]}"}; do
    if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null || true; fi
  done
  if [ "$DOMAIN_BEFORE" = 0 ]; then
    defaults delete "$DEV_ID" >/dev/null 2>&1 || true
    rm -f "$HOME/Library/Preferences/$DEV_ID.plist"
  fi
  rm -f "$HOME/Library/Preferences"/test.theo.rehearsal.*.plist
  if [ "$GROUP_BEFORE" = 0 ] && [ -d "$GROUP_FOLDER" ]; then rm -rf "$GROUP_FOLDER"; fi
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

say "flip rehearsal 2 -- $(date -u +%Y-%m-%dT%H:%M:%SZ) -- HEAD $(git -C "$ROOT" rev-parse --short HEAD)"
say "dev identity $DEV_ID, team $TEAM, container $CONTAINER; work folder $WORK (deleted at the end unless --keep)"

# ---------------------------------------------------------------- 1. App ID, capabilities and profile (public API)
PROFILE_JSON="$(python3 -I "$ROOT/scripts/release/asc_dev_profile.py" "$DEV_ID" "$PROFILE_NAME" "$CONTAINER")" \
  || { check FAIL "dev App ID and profile" "scripts/release/asc_dev_profile.py failed"; exit 1; }
profile_field() { python3 -I -c 'import json,sys; v=json.loads(sys.argv[1]).get(sys.argv[2]); print(json.dumps(v) if isinstance(v,(list,bool)) else v)' "$PROFILE_JSON" "$1"; }
LISTS_CONTAINER="$(profile_field listsContainer)"
check PASS "dev App ID exists with iCloud and Push, development profile installed" \
  "profile uuid $(profile_field profileUUID), team $(profile_field team), application identifier $(profile_field applicationIdentifier), keychain groups $(profile_field keychainGroups)"
if [ "$LISTS_CONTAINER" = True ]; then
  check PASS "the dev profile lists the iCloud container" "$CONTAINER"
else
  check "NOT VERIFIED" "the dev App ID is associated with the iCloud container" \
    "the profile lists no container (the public API has no endpoint for the association; portal click, see 'Final session' in docs/release/team-migration.md); this run drops the iCloud entitlements from the dev build (REN2-R59)"
fi

# ---------------------------------------------------------------- 2. copy the library, read-only on the source
mkdir -p "$LIB"
shopt -s dotglob nullglob
for entry in "$SOURCE_LIBRARY"/*; do
  name="$(basename "$entry")"
  case "$name" in
    Baerchen.sqlite|Baerchen.sqlite-wal|Baerchen.sqlite-shm|app.sock|app.sock.lock|.DS_Store) continue ;;
  esac
  ditto "$entry" "$LIB/$name"
done
shopt -u dotglob nullglob
sqlite3 -readonly "$SOURCE_LIBRARY/Baerchen.sqlite" ".backup '$LIB/Baerchen.sqlite'"
DB="$LIB/Baerchen.sqlite"
say "copied the library (database through SQLite's backup API; attachments, journal, backups through ditto)"

digest() { shasum -a 256 | cut -c1-16; }
metrics() { # metrics <db> <library folder>  -> key=value lines (counts and digests only)
  local db="$1" dir="$2"
  echo "notes_total=$(sqlite3 "$db" 'SELECT COUNT(*) FROM note')"
  echo "notes_locked=$(sqlite3 "$db" 'SELECT COUNT(*) FROM note WHERE isLocked = 1')"
  echo "notes_trashed=$(sqlite3 "$db" 'SELECT COUNT(*) FROM note WHERE trashedAt IS NOT NULL')"
  echo "tags=$(sqlite3 "$db" 'SELECT COUNT(*) FROM tag')"
  echo "attachment_rows=$(sqlite3 "$db" 'SELECT COUNT(*) FROM attachment')"
  echo "attachment_files=$(find "$dir/Attachments" -type f 2>/dev/null | wc -l | tr -d ' ')"
  echo "quick_check=$(sqlite3 "$db" 'PRAGMA quick_check')"
  echo "migrations=$(sqlite3 "$db" 'SELECT identifier FROM grdb_migrations ORDER BY identifier' | tr '\n' ',')"
  echo "envelope_digest=$(sqlite3 "$db" 'SELECT hex(envelope) FROM crypto_envelope' | digest)"
  echo "locked_payload_digest=$(sqlite3 "$db" 'SELECT id||hex(encryptedPayload) FROM note WHERE isLocked = 1 ORDER BY id' | digest)"
  echo "database_files=$(cd "$dir" && ls | grep -E '^(Baerchen|Library)\.sqlite$' | tr '\n' ' ')"
}
BEFORE="$WORK/before.txt"; AFTER="$WORK/after.txt"
metrics "$DB" "$LIB" > "$BEFORE"
INODE_BEFORE="$(stat -f %i "$DB")"
say "before the launch: $(tr '\n' ';' < "$BEFORE" | sed 's/;/; /g')"

# The safety steps of the cutover session (REN2-R63), on the COPY: the pre-cutover folder copy is made before the new build opens the
# library, and the rollback below puts it back after the build migrated the copy.
export THEO_LIBRARY="$LIB" THEO_DESKTOP="$WORK/desktop"
mkdir -p "$THEO_DESKTOP"
if "$ROOT/scripts/cutover-safety.sh" backup-folder > "$WORK/backup-folder.txt" 2>&1; then
  check PASS "cutover-safety backup-folder on the copy: folder copy equals the library" "$(tr '\n' ' ' < "$WORK/backup-folder.txt")"
else
  check FAIL "cutover-safety backup-folder on the copy" "$(tail -3 "$WORK/backup-folder.txt" | tr '\n' ' ')"
fi

# ---------------------------------------------------------------- 3. throw-away tree with the dev signing of this rehearsal
mkdir -p "$SRC"
git -C "$ROOT" archive HEAD | tar -x -C "$SRC"
ln -s "$EDITOR_NODE_MODULES" "$SRC/web/editor/node_modules"
if [ "$LISTS_CONTAINER" != True ]; then
  python3 -I - "$SRC" <<'PY'
import plistlib, sys
src = sys.argv[1]
keys = plistlib.load(open(f"{src}/Apps/TheoNotesMac/TheoNotes.dev.entitlements", "rb"))
for key in ("com.apple.developer.icloud-container-identifiers", "com.apple.developer.icloud-services",
            "com.apple.developer.icloud-container-environment", "com.apple.developer.aps-environment"):
    del keys[key]
plistlib.dump(keys, open(f"{src}/Apps/TheoNotesMac/TheoNotes.dev.rehearsal.entitlements", "wb"))
path = f"{src}/project.yml"
text = open(path).read()
needle = "            CODE_SIGN_ENTITLEMENTS: Apps/TheoNotesMac/TheoNotes.dev.entitlements\n"
assert needle in text, "project.yml no longer has the app target's Debug entitlements line"
open(path, "w").write(text.replace(needle, "            CODE_SIGN_ENTITLEMENTS: Apps/TheoNotesMac/TheoNotes.dev.rehearsal.entitlements\n", 1))
PY
fi
say "throw-away tree: HEAD $(git -C "$ROOT" rev-parse --short HEAD); the app signs with the committed Debug settings (manual, profile '$PROFILE_NAME')$([ "$LISTS_CONTAINER" = True ] || echo ', dev entitlements without the iCloud keys')"

# ---------------------------------------------------------------- 4. build + the gated and the identity tests in the signed host
SCREEN_LOCKED="$(ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked | grep -c true || true)"
PREFS_FIXTURE="$WORK/legacy-prefs.plist"
PREFS_JSON="$WORK/prefs-checks.json"
R2_JSON="$WORK/rehearsal2-checks.json"
cp "$ROOT/Fixtures/rehearsal/legacy-prefs.plist" "$PREFS_FIXTURE"
mkdir -p "$FAKE_HOME/Library/Application Support" "$FAKE_HOME/Library/Preferences" "$FAKE_HOME/Library/Caches" "$FAKE_HOME/Library/Logs"
APP="$DD/Build/Products/Debug/Theo Notes Dev.app"
SIGN_FLAGS=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration
  -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
( cd "$SRC" && xcodegen generate > "$WORK/xcodegen.log" 2>&1 )
if [ "$SCREEN_LOCKED" != 0 ]; then
  ( cd "$SRC" && xcodebuild -project TheoNotes.xcodeproj -scheme TheoNotes -configuration Debug -derivedDataPath "$DD" build "${SIGN_FLAGS[@]}" 2>&1 | redact > "$WORK/xcodebuild.log" ) && BUILD_RC=0 || BUILD_RC=$?
  check "NOT VERIFIED" "tests in the signed host (share drain, keychain group, entitlements)" "the screen is locked (R34); only the build and the static read-back ran"
else
  ( cd "$SRC" && TEST_RUNNER_THEONOTES_REHEARSAL2_OUT="$R2_JSON" \
      TEST_RUNNER_THEONOTES_REHEARSAL_PREFS_FIXTURE="$PREFS_FIXTURE" TEST_RUNNER_THEONOTES_REHEARSAL_PREFS_OUT="$PREFS_JSON" \
      xcodebuild -project TheoNotes.xcodeproj -scheme TheoNotes -configuration Debug -derivedDataPath "$DD" test "${SIGN_FLAGS[@]}" \
        -only-testing:TheoNotesMacTests/FlipRehearsal2Checks -only-testing:TheoNotesMacTests/FlipRehearsalPreferencesChecks \
        -only-testing:TheoNotesMacTests/AppIdentityBuildTests -only-testing:TheoNotesMacTests/NoteVaultTests \
        -only-testing:TheoNotesMacTests/KeychainVaultKeyCacheTests -only-testing:TheoNotesMacTests/MacSyncTests \
        -only-testing:TheoNotesMacTests/ShareInboxDrainTests -only-testing:TheoNotesMacTests/LegacyPreferencesMigrationTests \
        2>&1 | redact > "$WORK/xcodebuild.log" ) && BUILD_RC=0 || BUILD_RC=$?
fi
if [ ! -d "$APP" ]; then
  check FAIL "build of the team-signed dev identity" "xcodebuild exit $BUILD_RC; last lines: $(grep -E 'error:' "$WORK/xcodebuild.log" | head -3 | cut -c1-300 | tr '\n' ' ')"
  exit 1
fi

# static read-back of what the build was really signed with
ENT="$WORK/app-entitlements.plist"
codesign -d --entitlements :- "$APP" > "$ENT" 2>/dev/null
# PlistBuddy, not plutil: the entitlement names contain dots, which plutil reads as a key path.
ent() { /usr/libexec/PlistBuddy -c "Print :$1" "$ENT" 2>/dev/null || echo "<missing>"; }
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")"
SIGNING="$(codesign -dv "$APP" 2>&1 | grep -E '^(TeamIdentifier|Authority)=' | head -2 | tr '\n' ' ' || true)"
[ "$BUNDLE_ID" = "$DEV_ID" ] && check PASS "built bundle id is the dev id of the new root" "$BUNDLE_ID; $SIGNING" || check FAIL "built bundle id" "expected $DEV_ID, got $BUNDLE_ID"
[ "$(ent com.apple.developer.team-identifier)" = "$TEAM" ] && check PASS "signed team identifier" "$TEAM" || check FAIL "signed team identifier" "$(ent com.apple.developer.team-identifier)"
[ "$(ent keychain-access-groups:0)" = "$TEAM.$DEV_ID" ] && check PASS "keychain access group read back from the signature" "$TEAM.$DEV_ID" || check FAIL "keychain access group" "$(ent keychain-access-groups:0)"
[ "$(ent com.apple.security.application-groups:0)" = "$GROUP" ] && check PASS "App Group of the app read back from the signature" "$GROUP" || check FAIL "app group" "$(ent com.apple.security.application-groups:0)"
APPEX="$APP/Contents/PlugIns/TheoNotesMacShare.appex"
codesign -d --entitlements :- "$APPEX" > "$WORK/appex-entitlements.plist" 2>/dev/null || true
APPEX_GROUP="$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.application-groups:0" "$WORK/appex-entitlements.plist" 2>/dev/null || echo '<missing>')"
APPEX_TEAM="$(codesign -dv "$APPEX" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[ "$APPEX_GROUP" = "$GROUP" ] && [ "$APPEX_TEAM" = "$TEAM" ] \
  && check PASS "share extension is signed by the new team with the same App Group" "team $APPEX_TEAM, group $APPEX_GROUP" \
  || check FAIL "share extension signature" "team $APPEX_TEAM, group $APPEX_GROUP"
if [ "$LISTS_CONTAINER" = True ]; then
  [ "$(ent com.apple.developer.icloud-container-identifiers:0)" = "$CONTAINER" ] && [ "$(ent com.apple.developer.icloud-container-environment)" = Development ] \
    && check PASS "iCloud entitlements read back (Development environment)" "$CONTAINER" || check FAIL "iCloud entitlements" "container '$(ent com.apple.developer.icloud-container-identifiers:0)', environment '$(ent com.apple.developer.icloud-container-environment)'"
else
  [ "$(ent com.apple.developer.icloud-container-identifiers)" = "<missing>" ] \
    && check "NOT VERIFIED" "iCloud entitlements on the dev build" "dropped for this run because the dev App ID has no container yet (REN2-R59)" \
    || check FAIL "iCloud entitlements were expected to be dropped" "present"
fi

if [ "$SCREEN_LOCKED" = 0 ]; then
  if [ "$BUILD_RC" = 0 ]; then
    ran="$(grep -Eo 'Test run with [0-9]+ tests? in [0-9]+ suites? passed' "$WORK/xcodebuild.log" | tail -1 || true)"
    skipped="$(grep -Ec 'Test .* skipped' "$WORK/xcodebuild.log" || true)"
    check PASS "tests in the team-signed host (entitlements, share drain, keychain group, vault absent-cache path, preference migration)" "${ran:-xcodebuild test succeeded}; skipped: $skipped"
  else
    check FAIL "tests in the team-signed host" "xcodebuild exit $BUILD_RC; $(grep -E '✘|error:' "$WORK/xcodebuild.log" | head -5 | cut -c1-240 | tr '\n' ' ')"
  fi
  if [ -f "$R2_JSON" ]; then
    python3 -I - "$R2_JSON" "$TEAM" "$DEV_ID" > "$WORK/r2-verdict.txt" <<'PY'
import json, sys
r = json.load(open(sys.argv[1])); team, dev = sys.argv[2], sys.argv[3]
ok = (r["teamIdentifier"] == team and r["bundleIdentifier"] == dev and r["identityIsDev"]
      and r["accessGroupIsNewTeam"] and r["appGroupIsNewTeam"]
      and r["containerResolved"] and r["containerIsInGroupFolder"] and r["containerWritable"]
      and r["inboxHoldsTheItem"] and r["drainedItems"] == 1 and r["noteArrived"] and r["inboxEmptyAfterDrain"]
      and r["vaultCacheEmptyInNewGroup"] and not r["absentAccountContains"] and r["absentAccountLoadIsNil"]
      and r["probeStoredAndFound"] and r["probeRoundTrips"] and r["probeRemoved"])
print(("PASS" if ok else "FAIL") + "|" + "; ".join(f"{k}={r[k]}" for k in sorted(r)))
PY
    verdict="$(cat "$WORK/r2-verdict.txt")"
    check "${verdict%%|*}" "new access group holds no vault key (asks for the password once), App Group container of the new team created and the share drain works on it, the group is usable" "${verdict#*|}"
  else
    check FAIL "rehearsal 2 host checks" "the gated Mac test wrote no result (see xcodebuild.log)"
  fi
  if [ -f "$PREFS_JSON" ]; then
    check PASS "preference migration run in the team-signed flipped build" "$(python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); print("; ".join(f"{k}={r[k]}" for k in sorted(r)))' "$PREFS_JSON")"
  else
    check FAIL "preference migration check" "no result written"
  fi
fi

# ---------------------------------------------------------------- 5. launch the signed dev build on the copy, quit it by PID
EXE="$APP/Contents/MacOS/Theo Notes Dev"
if [ "$SCREEN_LOCKED" != 0 ]; then
  check "NOT VERIFIED" "launch of the team-signed dev build on the copy" "the screen is locked (R34)"
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
      && check PASS "team-signed dev build opened Baerchen.sqlite of the copy and stayed up $SETTLE s" "pid $PID alive" \
      || check FAIL "team-signed dev build opened the library but exited within $SETTLE s" "pid $PID gone; launch.log tail: $(tail -3 "$WORK/launch.log" | tr '\n' ' ')"
  else
    check FAIL "team-signed dev build did not open the library copy" "launch.log tail: $(tail -3 "$WORK/launch.log" | tr '\n' ' ')"
  fi
  if kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null || true
    for _ in $(seq 1 20); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
    if kill -0 "$PID" 2>/dev/null; then kill -9 "$PID" 2>/dev/null || true; say "pid $PID needed SIGKILL"; fi
  fi
  wait "$PID" 2>/dev/null || true
  kill -0 "$PID" 2>/dev/null && check FAIL "app stopped by its PID" "pid $PID still alive" || check PASS "app stopped by its own PID" "pid $PID gone"
fi

# ---------------------------------------------------------------- 6. counts before and after
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
REMOVED="$(comm -23 <(val "$BEFORE" migrations | tr ',' '\n' | sort) <(val "$AFTER" migrations | tr ',' '\n' | sort) | tr '\n' ' ')"
[ -z "$REMOVED" ] && check PASS "no migration removed or renamed" "added by HEAD: $(comm -13 <(val "$BEFORE" migrations | tr ',' '\n' | sort) <(val "$AFTER" migrations | tr ',' '\n' | sort) | tr '\n' ' ')" || check FAIL "migrations removed or renamed" "$REMOVED"
for key in envelope_digest locked_payload_digest; do
  [ "$(val "$BEFORE" $key)" = "$(val "$AFTER" $key)" ] \
    && check PASS "$key byte-identical (locked notes untouched)" "$(val "$AFTER" $key)" \
    || check FAIL "$key changed" "before $(val "$BEFORE" $key), after $(val "$AFTER" $key)"
done
# ---------------------------------------------------------------- 7. rollback rehearsal on the copy (REN2-R63)
# The old app refuses a migrated library (it knows no migration after v15 and has LibraryOpenError.newerThanThisBuild), so the
# rollback is the folder copy made above, never the migrated database. The migrated copy is moved aside, not deleted.
if [ "$(val "$AFTER" migrations)" = "$(val "$BEFORE" migrations)" ]; then
  # The app was not launched (locked screen): migrate the copy with the normal opener so the rollback is rehearsed on a migrated library.
  ( cd "$ROOT" && THEONOTES_REHEARSAL_MIGRATE="$DB" swift test --package-path Packages/TheoNotesCore --filter FlipRehearsalMigrate > "$WORK/migrate.log" 2>&1 ) \
    && AFTER="$WORK/after-migrate.txt" && metrics "$DB" "$LIB" > "$AFTER" \
    || check FAIL "migrating the copy with the normal opener" "$(tail -3 "$WORK/migrate.log" | tr '\n' ' ')"
fi
if [ "$(val "$AFTER" migrations)" != "$(val "$BEFORE" migrations)" ]; then
  check PASS "the build migrated the copy, so the old app could not open it any more" "migrations added: $(comm -13 <(val "$BEFORE" migrations | tr ',' '\n' | sort) <(val "$AFTER" migrations | tr ',' '\n' | sort) | tr '\n' ' ')"
else
  check "NOT VERIFIED" "rollback after a migration" "the build added no migration to this copy, so the restore below proves less"
fi
if "$ROOT/scripts/cutover-safety.sh" restore-folder > "$WORK/restore-folder.txt" 2>&1; then
  metrics "$DB" "$LIB" > "$WORK/restored.txt"
  [ "$(cat "$WORK/restored.txt")" = "$(cat "$BEFORE")" ] \
    && check PASS "rollback: restore-folder put the pre-cutover library back; counts, quick_check, migrations and digests equal the state before the launch" "$(grep -c '' "$WORK/restored.txt") metrics compared, no v16 to v18 in the restored database" \
    || check FAIL "rollback: the restored library differs from the state before the launch" "$(diff "$BEFORE" "$WORK/restored.txt" | tr '\n' ' ')"
  aside="$(ls -d "$LIB".after-cutover-* 2>/dev/null | head -1 || true)"
  [ -n "$aside" ] && [ "$(sqlite3 "$aside/Baerchen.sqlite" 'SELECT COUNT(*) FROM note')" = "$(val "$BEFORE" notes_total)" ] \
    && check PASS "rollback: the migrated library was kept aside, not deleted" "notes $(sqlite3 "$aside/Baerchen.sqlite" 'SELECT COUNT(*) FROM note'), migrations include v18: $(sqlite3 "$aside/Baerchen.sqlite" "SELECT COUNT(*) FROM grdb_migrations WHERE identifier LIKE 'v18%'")" \
    || check FAIL "rollback: the migrated library is not kept aside" "aside='${aside:-none}'"
else
  check FAIL "rollback: restore-folder on the copy" "$(tail -3 "$WORK/restore-folder.txt" | tr '\n' ' ')"
fi

check "NOT VERIFIED" "Touch ID re-arm and the first Touch ID unlock of a real locked note" "needs the person: Jan's password and his finger at the Mac (Final session)"

say "---"
if [ "$FAILS" = 0 ]; then say "RESULT: no check failed"; else say "RESULT: $FAILS check(s) FAILED"; fi
[ "$FAILS" = 0 ]
