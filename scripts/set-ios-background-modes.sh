#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

# CK-R176 (CloudKit plan Task 16, REL-R13): writes UIBackgroundModes into the built iOS Info.plist from the build setting
# THEONOTES_IOS_BACKGROUND_MODES (space separated). An Info.plist file cannot list an entry only when a build setting says so, and
# INFOPLIST_KEY_UIBackgroundModes is not one of the keys Xcode generates (measured), so the list is written here, before signing.
# `remote-notification` is in the setting only where THEONOTES_ICLOUD_SYNC is YES (project.yml); MobileIdentityTests pins that.
# Idempotent: the key is rebuilt from scratch on every run, so an incremental build never doubles an entry.
set -euo pipefail
plist="${TARGET_BUILD_DIR:?}/${INFOPLIST_PATH:?}"
[ -f "$plist" ] || { echo "error: no built Info.plist at $plist" >&2; exit 1; }
modes="${THEONOTES_IOS_BACKGROUND_MODES:-fetch}"
buddy=/usr/libexec/PlistBuddy
"$buddy" -c "Delete :UIBackgroundModes" "$plist" 2>/dev/null || true
"$buddy" -c "Add :UIBackgroundModes array" "$plist"
index=0
for mode in $modes; do
  case "$mode" in
    fetch | remote-notification) ;;
    *) echo "error: THEONOTES_IOS_BACKGROUND_MODES names '$mode'; only fetch and remote-notification are allowed" >&2; exit 1 ;;
  esac
  "$buddy" -c "Add :UIBackgroundModes:$index string $mode" "$plist"
  index=$((index + 1))
done
