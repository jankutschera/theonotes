#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

# Gate item 7: SIGKILL the WebContent process of the running Theo Notes app.
# WebContent is an XPC service (its ppid is launchd), so it is found through the app's
# launchd pid domain instead of the process tree.
# Usage: scripts/gate/kill-webcontent.sh [--dry-run] [app-pid]
set -euo pipefail

dry_run=0
if [ "${1:-}" = "--dry-run" ]; then dry_run=1; shift; fi

app_pid="${1:-$(pgrep -x "Theo Notes Dev" | head -1 || true)}"
if [ -z "$app_pid" ]; then
  echo "error: Theo Notes Dev is not running" >&2
  exit 1
fi

pids=$(launchctl print "pid/$app_pid" \
  | awk '$3 ~ /^com\.apple\.WebKit\.WebContent\./ && $1 ~ /^[0-9]+$/ && $1 != "0" { print $1 }')
if [ -z "$pids" ]; then
  echo "error: no running WebContent process for Theo Notes Dev pid $app_pid" >&2
  exit 1
fi

for pid in $pids; do
  echo "Theo Notes Dev $app_pid: WebContent pid $pid"
  if [ "$dry_run" = 0 ]; then
    kill -9 "$pid"
    while kill -0 "$pid" 2>/dev/null; do :; done
    echo "killed $pid (gone)"
  fi
done
