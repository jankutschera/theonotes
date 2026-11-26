#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

# Shared helpers for the release scripts (sourced, not run) R69.
#
# config/release.env is read by key with sed, never sourced: Xcode reads the same file as an .xcconfig, and
# values such as a profile name may contain spaces.

release_root() { cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd; }

# THEONOTES_RELEASE_ENV points the scripts at another file (tests only).
release_env_file() { echo "${THEONOTES_RELEASE_ENV:-$(release_root)/config/release.env}"; }

# config_value KEY: the value after `KEY=` in release.env, empty when the key is missing.
config_value() { sed -n "s/^$1=//p" "$(release_env_file)" | head -1; }

# The team is never taken from the environment: Xcode reads it from the same file, so a second source could
# only disagree with what was built. The notary profile and the two provisioning profile names may be
# overridden per machine by a variable of the same name.
setting() { # NAME
  case "$1" in
    THEONOTES_TEAM_ID) config_value "$1" ;;
    *) local env_value="${!1:-}"; if [ -n "$env_value" ]; then echo "$env_value"; else config_value "$1"; fi ;;
  esac
}

say() { echo "==> $*"; }
die() { echo "error: $*" >&2; exit 1; }
refuse() { echo "refusing: $*" >&2; exit 2; }

# The identity a shipped bundle must have: the production bundle id, never the dev one.
PRODUCTION_BUNDLE_ID="com.truebrewbirdie.theonotes"

plist_value() { # FILE KEY
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}

# require_production_bundle APP: exit 2 unless APP is a bundle whose CFBundleIdentifier is exactly the production id.
require_production_bundle() {
  local app="$1" id=""
  [ -d "$app" ] || refuse "no bundle at $app"
  [ -f "$app/Contents/Info.plist" ] && id="$(plist_value "$app/Contents/Info.plist" CFBundleIdentifier)"
  [ "$id" = "$PRODUCTION_BUNDLE_ID" ] || refuse "$app has bundle id '${id:-none}', not $PRODUCTION_BUNDLE_ID (a dev-identity build is never packaged for release)"
}

# developer_id_hash TEAM: the SHA-1 of the "Developer ID Application" identity of TEAM in the keychain, or nothing.
developer_id_hash() {
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -n "s/^ *[0-9]*) \([0-9A-F]\{40\}\) \"Developer ID Application: .*($1)\".*/\1/p" | head -1
}
