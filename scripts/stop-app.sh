#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

# Stops running copies of the app that live under the given folders, one PID at a time.
#   scripts/stop-app.sh <folder> [<folder> ...]
# The executable is `Theo Notes` or `Theo Notes Dev` (REN2-R72); builds up to 1.1 call it `Baerchen` in both
# identities, so stopping by name could reach the other identity (FOC-R364). A process is stopped only when its
# executable path starts with one of the folders.
# KILL_CMD lets scripts/test-install-dev.sh run this against a stub.
set -euo pipefail
[ "$#" -ge 1 ] || { echo "usage: stop-app.sh <folder> [<folder> ...]" >&2; exit 2; }
for pid in $( { for name in "Theo Notes" "Theo Notes Dev" Baerchen; do pgrep -x "$name" || true; done; } | sort -u ); do
  exe="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
  for folder in "$@"; do
    case "$exe" in
      "${folder%/}"/*)
        echo "stopping pid $pid ($exe)"
        "${KILL_CMD:-kill}" "$pid" 2>/dev/null || true
        break
        ;;
    esac
  done
done
