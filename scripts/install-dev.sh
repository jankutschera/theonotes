#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

# Install a built Theo Notes into ~/Applications and make it the only registered copy.
# Only a PRODUCTION-identity build is installed: `scripts/build.sh --production` makes one
# (configuration Production, bundle id com.truebrewbirdie.theonotes since the B7 cutover). A dev-identity
# build (the Debug configuration that tests, agents and GUI checks use) and a build of the old identity
# (com.truebrewbirdie.baerchen) are refused, so neither can replace Jan's app.
# The Production build product is "Theo Notes.app", the name of the installed copy.
#
# Safety rules: nothing is deleted before its identity is known.
#   - ~/Applications/Theo Notes.app is replaced only when its bundle id is one of the two production ids (new or old);
#     any other bundle there stops the install before anything is stopped or removed.
#   - ~/Applications/Baerchen.app (the pre-rename name) is removed only when its bundle id is one of the two production
#     ids; any other bundle there is left alone.
#   - Old LaunchServices records are unregistered by BUNDLE ID (read from the lsregister dump), whatever the file is called
#     and wherever it is. `lsregister -u` removes a record only; no file is ever deleted for this.
#   - Nothing outside the two paths above is touched: the safety zip on the Desktop (~/Desktop/Theo Notes OLD.zip), the
#     library, backups and Keychain items are not read or written by this script.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="${1:-$root/build/DerivedData/Build/Products/Production/Theo Notes.app}"
dest="$HOME/Applications/Theo Notes.app"
old="$HOME/Applications/Baerchen.app"
production_id="com.truebrewbirdie.theonotes"
# The identity before the cutover. Its LaunchServices record (and that of any other copy of the old app) is unregistered
# by this id, so Spotlight and the Dock open the new app.
old_production_id="com.truebrewbirdie.baerchen"
# LSREGISTER lets scripts/test-install-dev.sh run this script against a stub.
lsr="${LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
[ -d "$src" ] || { echo "no build at $src" >&2; exit 1; }

bundle_id_of() { # <app>  -> its CFBundleIdentifier, or nothing
  [ -f "$1/Contents/Info.plist" ] && /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$1/Contents/Info.plist" 2>/dev/null || true
}
is_production_id() { [ "$1" = "$production_id" ] || [ "$1" = "$old_production_id" ]; }

# Refuse anything that is not exactly the production identity (a dev build, the old identity, or a bundle with no id).
bundle_id="$(bundle_id_of "$src")"
if [ "$bundle_id" != "$production_id" ]; then
  echo "refusing to install $src: its bundle id is '${bundle_id:-none}', not $production_id." >&2
  echo "Build the installable app with: scripts/build.sh --production" >&2
  exit 1
fi

# Look at what is installed BEFORE anything is stopped, unregistered or removed.
installed_id=""
if [ -e "$dest" ]; then
  installed_id="$(bundle_id_of "$dest")"
  if ! is_production_id "$installed_id"; then
    echo "refusing to replace $dest: its bundle id is '${installed_id:-none}', which is neither $production_id nor $old_production_id." >&2
    echo "Nothing was stopped, removed or installed. Move it away by hand if it should go." >&2
    exit 1
  fi
fi
remove_old=0
if [ -e "$old" ]; then
  if is_production_id "$(bundle_id_of "$old")"; then remove_old=1
  else echo "note: leaving $old alone: its bundle id is '$(bundle_id_of "$old")', not a production id" >&2; fi
fi

# The gate before anything is touched. When the installed app is the OLD app (the real cutover), the old app must be able
# to serve as the way back: `cutover-safety.sh preflight` refuses unless its profile stays valid for 24 more hours and the zip of it
# verifies. Then, in a terminal, Jan has to type INSTALL; up to this point nothing has been stopped, removed, replaced or migrated.
if [ "$installed_id" = "$old_production_id" ]; then
  "$root/scripts/cutover-safety.sh" preflight || { echo "Nothing was stopped, removed or installed." >&2; exit 1; }
fi
if [ -t 0 ] && [ -z "${THEO_INSTALL_CONFIRMED:-}" ]; then
  echo "This will replace ${installed_id:+the installed Theo Notes ($installed_id) }$dest with the new build."
  printf 'Type INSTALL to continue (anything else stops, nothing is changed): '
  read -r answer || answer=""
  [ "$answer" = INSTALL ] || { echo "not confirmed; nothing was stopped, removed or installed." >&2; exit 1; }
fi

# Stop only the copies that are installed, by PID: builds up to 1.1 share one executable name in both identities.
"$root/scripts/stop-app.sh" "$dest" "$old"
mkdir -p "$HOME/Applications"
if [ "$remove_old" = 1 ]; then
  "$lsr" -u "$old" 2>/dev/null || true
  rm -rf "$old"
fi
if [ -e "$dest" ]; then
  # The record of the app being replaced goes first when it still carries the old id.
  if [ "$installed_id" = "$old_production_id" ]; then "$lsr" -u "$dest" 2>/dev/null || true; fi
  rm -rf "$dest"
fi
/usr/bin/ditto "$src" "$dest"

# Unregister every OTHER registered copy of the production app or the old production app, found by bundle id in the dump
# (record = a "path:" line followed by its "identifier:" line), whatever it is called and even when its file is gone.
# A dev build, any other bundle, and an appex are never matched. `lsregister -u` touches the record only.
dump_records() { # prints "<identifier><TAB><path>" for every registered .app
  { "$lsr" -dump 2>/dev/null || true; } | awk '
    /^path:/ { sub(/^path: */, ""); sub(/ \(0x[0-9a-fA-F]+\)$/, ""); path = $0; want = 1; next }
    /^identifier:/ && want { sub(/^identifier: */, ""); if (path ~ /\.app$/) print $0 "\t" path; want = 0 }'
}
dump_records | sort -u | while IFS=$'\t' read -r id p; do
  if [ "$p" = "$dest" ]; then continue; fi
  if is_production_id "$id"; then "$lsr" -u "$p" 2>/dev/null || true; fi
done
"$lsr" -f "$dest"
echo "installed: $dest"
