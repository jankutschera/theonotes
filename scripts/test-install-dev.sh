#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

# Dry-run test of scripts/install-dev.sh: a fake HOME, a stub lsregister and stub pgrep/ps/kill, so
# nothing real is installed, registered or stopped. Fix round 1: with no other registered
# Baerchen.app (an empty `grep` result) the script must still register "Theo Notes.app".
# Only a production-identity bundle is installed, and only the installed copy is stopped.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/theo-install-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# A bundle with a given CFBundleIdentifier (or none).
make_bundle() { # <app dir> [<bundle id>]
  mkdir -p "$1/Contents/MacOS"
  echo new > "$1/Contents/MacOS/Theo Notes"
  if [ -n "${2:-}" ]; then
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>%s</string></dict></plist>\n' "$2" > "$1/Contents/Info.plist"
  fi
}

mkdir -p "$work/bin" "$work/home/Desktop"
make_bundle "$work/home/Applications/Baerchen.app" com.truebrewbirdie.baerchen
echo old > "$work/home/Applications/Baerchen.app/Contents/marker"
# The safety zip of the cutover day: must survive every run, untouched and unmentioned.
echo "old app zip" > "$work/home/Desktop/Theo Notes OLD.zip"
zip_sum="$(shasum "$work/home/Desktop/Theo Notes OLD.zip" | cut -d' ' -f1)"
make_bundle "$work/build/Theo Notes.app" com.truebrewbirdie.theonotes
# The processes the stubs report: 111 is the installed app, 222 a dev build of a worktree, 333 the old copy.
printf '111\n222\n333\n' > "$work/pids"
cat > "$work/bin/pgrep" <<STUB
#!/bin/sh
echo "pgrep \$*" >> "$work/calls"
cat "$work/pids"
STUB
cat > "$work/bin/ps" <<STUB
#!/bin/sh
# ps -p <pid> -o comm=
case "\$2" in
  111) echo "$work/home/Applications/Theo Notes.app/Contents/MacOS/Baerchen" ;;  # the installed 1.1 copy, old executable name
  222) echo "/elsewhere/build/DerivedData/Build/Products/Debug/Theo Notes Dev.app/Contents/MacOS/Theo Notes Dev" ;;
  333) echo "$work/home/Applications/Baerchen.app/Contents/MacOS/Baerchen" ;;
esac
STUB
cat > "$work/bin/kill" <<STUB
#!/bin/sh
echo "kill \$*" >> "$work/calls"
STUB
# pkill must never be used: it would reach another identity's process by name.
printf '#!/bin/sh\necho "pkill $*" >> "%s/calls"\nexit 1\n' "$work" > "$work/bin/pkill"
chmod +x "$work/bin/pgrep" "$work/bin/ps" "$work/bin/kill" "$work/bin/pkill"
# lsregister: `-dump` prints $DUMP_FILE (when set); every call is logged.
cat > "$work/bin/lsregister" <<STUB
#!/bin/sh
echo "lsregister \$*" >> "$work/calls"
if [ "\$1" = "-dump" ] && [ -n "\${DUMP_FILE:-}" ]; then cat "\$DUMP_FILE"; fi
exit 0
STUB
chmod +x "$work/bin/lsregister"

# A registered record as lsregister -dump prints it: the path line, then (a few lines later) the identifier line.
record() { # <path> <identifier>
  printf 'name:                       x\npath:                       %s (0x1)\ndirectory:                  ~/Applications\nidentifier:                 %s\nversion:                    1\n\n' "$1" "$2"
}

run() { # [<build dir>]
  : > "$work/calls"
  HOME="$work/home" PATH="$work/bin:$PATH" LSREGISTER="$work/bin/lsregister" KILL_CMD="$work/bin/kill" \
    bash "${INSTALL_SCRIPT:-$root/scripts/install-dev.sh}" "${1:-$work/build/Theo Notes.app}" > "$work/out" 2>&1 || { cat "$work/out" >&2; fail "install-dev.sh exited non-zero"; }
}
# A run that must be refused: non-zero exit, a message, nothing registered, stopped or replaced.
run_refused() { # <build dir> <message fragment>
  : > "$work/calls"
  if HOME="$work/home" PATH="$work/bin:$PATH" LSREGISTER="$work/bin/lsregister" KILL_CMD="$work/bin/kill" \
    bash "${INSTALL_SCRIPT:-$root/scripts/install-dev.sh}" "$1" > "$work/out" 2>&1; then
    fail "install-dev.sh accepted $1"
  fi
  grep -q "$2" "$work/out" || { cat "$work/out" >&2; fail "refusal message lacks '$2'"; }
  [ ! -s "$work/calls" ] || { cat "$work/calls" >&2; fail "a refused install still called something"; }
  [ ! -e "$work/home/Applications/Theo Notes.app" ] || fail "a refused install still installed"
  [ -f "$work/home/Applications/Baerchen.app/Contents/marker" ] || fail "a refused install removed the old copy"
}

# 1. Nothing else registered: the dump has no Baerchen.app line, so grep finds nothing.
record /Applications/Other.app com.example.other > "$work/dump-empty"
DUMP_FILE="$work/dump-empty" run
grep -q "lsregister -f $work/home/Applications/Theo Notes.app" "$work/calls" || fail "Theo Notes.app was not registered (empty dump)"
[ -d "$work/home/Applications/Theo Notes.app" ] || fail "Theo Notes.app missing"
[ ! -e "$work/home/Applications/Baerchen.app" ] || fail "old Baerchen.app not removed"
grep -q "lsregister -u $work/home/Applications/Baerchen.app" "$work/calls" || fail "old copy not unregistered"
grep -q "installed: $work/home/Applications/Theo Notes.app" "$work/out" || fail "no success line"

# 1b. Only the installed copies are stopped, by PID: 111 and 333, never the dev build 222, never by name.
grep -q "^kill 111" "$work/calls" || fail "the installed app was not stopped"
grep -q "^kill 333" "$work/calls" || fail "the old copy was not stopped"
if grep -q "^kill 222" "$work/calls"; then fail "stopped a process outside the installed copies (a dev build)"; fi
if grep -q "^pkill" "$work/calls"; then fail "used pkill (by name)"; fi
# The running copy is looked up under every executable name: the new ones and `Baerchen` of 1.1 and earlier.
for name in "Theo Notes" "Theo Notes Dev" Baerchen; do
  grep -qx "pgrep -x $name" "$work/calls" || fail "stop-app.sh did not look for '$name'"
done
[ "$(grep -c '^kill 111' "$work/calls")" = 1 ] || fail "the installed app was stopped more than once"

# 2. Another copy is registered: it is unregistered, ours is registered last.
make_bundle "$work/home/Applications/Baerchen.app" com.truebrewbirdie.baerchen
# Registered records, found by BUNDLE ID whatever the file is called: a production copy elsewhere, the old app under
# other names (a saved copy "Theo Notes OLD.app", one whose file is gone), and records that must survive: dev builds of both
# identities, a lookalike share bundle, an unrelated app, and an appex.
make_bundle "$work/other/Baerchen.app" com.truebrewbirdie.theonotes
make_bundle "$work/saved/Theo Notes OLD.app" com.truebrewbirdie.baerchen
make_bundle "$work/registered-dev/Baerchen.app" com.truebrewbirdie.theonotes.dev
make_bundle "$work/registered-olddev/Baerchen.app" com.truebrewbirdie.baerchen.dev
make_bundle "$work/registered-share/Theo Notes.app" com.truebrewbirdie.theonotes.share
{
  record "$work/other/Baerchen.app" com.truebrewbirdie.theonotes
  record "$work/saved/Theo Notes OLD.app" com.truebrewbirdie.baerchen
  record "$work/gone/Renamed Copy.app" com.truebrewbirdie.baerchen
  record "$work/registered-dev/Baerchen.app" com.truebrewbirdie.theonotes.dev
  record "$work/registered-olddev/Baerchen.app" com.truebrewbirdie.baerchen.dev
  record "$work/registered-share/Theo Notes.app" com.truebrewbirdie.theonotes.share
  record "$work/gone/Unknown.app" com.example.unknown
  record "$work/home/Applications/Theo Notes.app/Contents/PlugIns/TheoNotesMacShare.appex" com.truebrewbirdie.baerchen
  record "$work/home/Applications/Theo Notes.app" com.truebrewbirdie.baerchen
} > "$work/dump-other"
DUMP_FILE="$work/dump-other" run
grep -q "lsregister -u $work/other/Baerchen.app" "$work/calls" || fail "other production copy not unregistered"
grep -q "lsregister -u $work/saved/Theo Notes OLD.app" "$work/calls" || fail "a copy of the old app under another name was not unregistered by its id"
grep -q "lsregister -u $work/gone/Renamed Copy.app" "$work/calls" || fail "a record of the old id whose file is gone was not unregistered"
if grep -q "TheoNotesMacShare.appex" "$work/calls"; then fail "an appex record was touched"; fi
if grep -q "lsregister -u $work/gone/Unknown.app" "$work/calls"; then fail "unregistered a record with an unknown id"; fi
if grep -q "lsregister -u $work/registered-dev/Baerchen.app" "$work/calls"; then fail "unregistered a dev build"; fi
if grep -q "lsregister -u $work/registered-olddev/Baerchen.app" "$work/calls"; then fail "unregistered the old dev build"; fi
if grep -q "lsregister -u $work/registered-share/Theo Notes.app" "$work/calls"; then fail "unregistered a bundle that is not the production app"; fi
if grep -q "lsregister -u $work/home/Applications/Theo Notes.app" "$work/calls"; then fail "unregistered the new copy"; fi
[ "$(tail -1 "$work/calls")" = "lsregister -f $work/home/Applications/Theo Notes.app" ] || fail "registration is not the last step"

# 3. lsregister prints nothing at all.
DUMP_FILE="" run
grep -q "lsregister -f " "$work/calls" || fail "not registered with an empty dump"

# 4. A dev-identity build is refused, whatever else is true.
make_bundle "$work/home/Applications/Baerchen.app" com.truebrewbirdie.baerchen
echo old > "$work/home/Applications/Baerchen.app/Contents/marker"
rm -rf "$work/home/Applications/Theo Notes.app"
make_bundle "$work/dev/Baerchen.app" com.truebrewbirdie.theonotes.dev
run_refused "$work/dev/Baerchen.app" "com.truebrewbirdie.theonotes.dev"
# Lookalikes, the old production identity and a bundle with no identifier are refused too.
make_bundle "$work/lookalike/Baerchen.app" com.truebrewbirdie.theonotes.share
run_refused "$work/lookalike/Baerchen.app" "not com.truebrewbirdie.theonotes"
make_bundle "$work/oldid/Baerchen.app" com.truebrewbirdie.baerchen
run_refused "$work/oldid/Baerchen.app" "not com.truebrewbirdie.theonotes"
make_bundle "$work/noid/Baerchen.app"
run_refused "$work/noid/Baerchen.app" "'none'"

# 4b. The copy at the destination carries the OLD id (the cutover day): its record is unregistered first, then replaced.
mkdir -p "$work/home/Applications"
rm -rf "$work/home/Applications/Theo Notes.app"
make_bundle "$work/home/Applications/Theo Notes.app" com.truebrewbirdie.baerchen
echo profile > "$work/home/Applications/Theo Notes.app/Contents/embedded.provisionprofile"
# With the OLD app installed the install is gated by cutover-safety.sh preflight (profile valid > 24 h, verified zip of the
# old app) and, in a terminal, by typing INSTALL. `security` is a stub that prints the profile's expiry date.
printf '#!/bin/sh\ncat <<PLIST\n<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>ExpirationDate</key><date>%s</date></dict></plist>\nPLIST\n' "2099-01-01T00:00:00Z" > "$work/security"
chmod +x "$work/security"
export SECURITY="$work/security"
: > "$work/calls"
if HOME="$work/home" PATH="$work/bin:$PATH" LSREGISTER="$work/bin/lsregister" KILL_CMD="$work/bin/kill" bash "$root/scripts/install-dev.sh" "$work/build/Theo Notes.app" > "$work/out" 2>&1; then fail "installed over the old app without a zip of it"; fi
grep -q "no verified zip" "$work/out" && grep -q "Nothing was stopped, removed or installed" "$work/out" || fail "no preflight refusal for a missing zip"
[ ! -s "$work/calls" ] || fail "the refused install stopped or registered something"
make_bundle "$work/oldapp/Theo Notes.app" com.truebrewbirdie.baerchen
/usr/bin/ditto -c -k --keepParent "$work/oldapp/Theo Notes.app" "$work/home/Desktop/Theo Notes OLD.zip"
zip_sum="$(shasum "$work/home/Desktop/Theo Notes OLD.zip" | cut -d" " -f1)"
printf '#!/bin/sh\ncat <<PLIST\n<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>ExpirationDate</key><date>%s</date></dict></plist>\nPLIST\n' "2020-01-01T00:00:00Z" > "$work/security"
if HOME="$work/home" PATH="$work/bin:$PATH" LSREGISTER="$work/bin/lsregister" KILL_CMD="$work/bin/kill" bash "$root/scripts/install-dev.sh" "$work/build/Theo Notes.app" > "$work/out" 2>&1; then fail "installed over an old app whose profile has expired"; fi
grep -q "coordinator renews" "$work/out" || fail "no renewal message for an expired profile"
[ -f "$work/home/Applications/Theo Notes.app/Contents/embedded.provisionprofile" ] || fail "the old app was touched by a refused install"
printf '#!/bin/sh\ncat <<PLIST\n<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>ExpirationDate</key><date>%s</date></dict></plist>\nPLIST\n' "2099-01-01T00:00:00Z" > "$work/security"
# In a terminal (a pty) anything but INSTALL stops before anything is changed.
: > "$work/calls"
python3 -I "$root/scripts/tests/tty_run.py" no "Type INSTALL" -- env HOME="$work/home" PATH="$work/bin:$PATH" LSREGISTER="$work/bin/lsregister" KILL_CMD="$work/bin/kill" SECURITY="$work/security" bash "$root/scripts/install-dev.sh" "$work/build/Theo Notes.app" > "$work/out" 2>&1 || true
grep -q "Type INSTALL" "$work/out" && grep -q "not confirmed" "$work/out" || { cat "$work/out" >&2; fail "no confirmation prompt, or it accepted 'no'"; }
[ -f "$work/home/Applications/Theo Notes.app/Contents/embedded.provisionprofile" ] || fail "the old app was removed without confirmation"
[ ! -s "$work/calls" ] || fail "something was stopped or registered without confirmation"
python3 -I "$root/scripts/tests/tty_run.py" INSTALL "Type INSTALL" -- env HOME="$work/home" PATH="$work/bin:$PATH" LSREGISTER="$work/bin/lsregister" KILL_CMD="$work/bin/kill" SECURITY="$work/security" DUMP_FILE="$work/dump-empty" bash "$root/scripts/install-dev.sh" "$work/build/Theo Notes.app" > "$work/out" 2>&1 || true
grep -q "installed: " "$work/out" || { cat "$work/out" >&2; fail "typing INSTALL did not install"; }
[ ! -e "$work/home/Applications/Theo Notes.app/Contents/embedded.provisionprofile" ] || fail "the old app is still there after INSTALL"
[ -f "$work/home/Desktop/Theo Notes OLD.zip" ] || fail "the zip is gone"
# Now the same as the plain run of before (non-terminal, no gate beyond the preflight): reset to the old app and go on.
rm -rf "$work/home/Applications/Theo Notes.app"
make_bundle "$work/home/Applications/Theo Notes.app" com.truebrewbirdie.baerchen
echo profile > "$work/home/Applications/Theo Notes.app/Contents/embedded.provisionprofile"
DUMP_FILE="$work/dump-empty" run
grep -q "lsregister -u $work/home/Applications/Theo Notes.app" "$work/calls" || fail "the old record at the destination was not unregistered"
[ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$work/home/Applications/Theo Notes.app/Contents/Info.plist")" = com.truebrewbirdie.theonotes ] || fail "the old app was not replaced by the new one"
[ "$(tail -1 "$work/calls")" = "lsregister -f $work/home/Applications/Theo Notes.app" ] || fail "registration is not the last step (old destination)"

# 4c. a bundle at the destination that is NOT a production id is never deleted: the install stops before anything is
#     stopped, unregistered or removed. A pre-rename Baerchen.app of another id is left alone, the install goes on.
rm -rf "$work/home/Applications/Theo Notes.app"
make_bundle "$work/home/Applications/Theo Notes.app" com.example.somethingelse
echo keep > "$work/home/Applications/Theo Notes.app/Contents/marker"
: > "$work/calls"
if HOME="$work/home" PATH="$work/bin:$PATH" LSREGISTER="$work/bin/lsregister" KILL_CMD="$work/bin/kill" bash "$root/scripts/install-dev.sh" "$work/build/Theo Notes.app" > "$work/out" 2>&1; then fail "replaced a foreign bundle at the destination"; fi
grep -q "refusing to replace" "$work/out" || fail "no refusal message for a foreign destination"
[ -f "$work/home/Applications/Theo Notes.app/Contents/marker" ] || fail "the foreign bundle was removed"
[ ! -s "$work/calls" ] || { cat "$work/calls" >&2; fail "a refused replacement still stopped or registered something"; }
rm -rf "$work/home/Applications/Theo Notes.app"
make_bundle "$work/home/Applications/Theo Notes.app" ""
if HOME="$work/home" PATH="$work/bin:$PATH" LSREGISTER="$work/bin/lsregister" KILL_CMD="$work/bin/kill" bash "$root/scripts/install-dev.sh" "$work/build/Theo Notes.app" > "$work/out" 2>&1; then fail "replaced a destination with no bundle id"; fi
rm -rf "$work/home/Applications/Theo Notes.app" "$work/home/Applications/Baerchen.app"
make_bundle "$work/home/Applications/Baerchen.app" com.example.stranger
echo keep > "$work/home/Applications/Baerchen.app/Contents/marker"
DUMP_FILE="$work/dump-empty" run
[ -f "$work/home/Applications/Baerchen.app/Contents/marker" ] || fail "a Baerchen.app of a foreign id was removed"
if grep -q "lsregister -u $work/home/Applications/Baerchen.app" "$work/calls"; then fail "unregistered a Baerchen.app of a foreign id"; fi
grep -q "installed: " "$work/out" || fail "the install should go on when only the pre-rename copy is foreign"

# 4d. The Desktop zip of the cutover day is never touched, mentioned or registered by any run above.
[ "$(shasum "$work/home/Desktop/Theo Notes OLD.zip" | cut -d' ' -f1)" = "$zip_sum" ] || fail "the Desktop zip changed"
if grep -q "Desktop" "$work/calls"; then fail "a call named the Desktop"; fi
code_lines="$(grep -v '^ *#' "$root/scripts/install-dev.sh")"
case "$code_lines" in *Desktop*) fail "install-dev.sh code mentions the Desktop" ;; esac

# 5. The default source is the Production build, not Debug.
grep -q 'Products/Production/Theo Notes.app' "$root/scripts/install-dev.sh" || fail "default source is not the Production build"
if grep -q 'Products/Debug' "$root/scripts/install-dev.sh"; then fail "install-dev.sh still names the Debug build"; fi
echo "install-dev.sh dry run: ok"
