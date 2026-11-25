#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

# Builds and launches the DEV identity ("Theo Notes Dev", its own library). It never touches the
# installed Theo Notes: only a previous run of this build folder is stopped, by PID.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

"$ROOT/scripts/build.sh"
"$ROOT/scripts/stop-app.sh" "$ROOT/build/DerivedData/Build/Products"
open "$ROOT/build/DerivedData/Build/Products/Debug/Theo Notes Dev.app"
