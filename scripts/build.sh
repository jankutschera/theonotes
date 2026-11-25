#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

# Builds the app. Without a flag: the DEV identity (configuration Debug, bundle id
# com.truebrewbirdie.baerchen.dev, "Theo Notes Dev", library "Theo Notes Dev"), the build for tests,
# agents and GUI checks. `--production`: the identity Jan installs (configuration Production, bundle id
# com.truebrewbirdie.baerchen), for scripts/install-dev.sh. `--release`: the public configuration (Release, same
# identity as production, sync setup hidden; REL-R4), team from config/release.env (REL-R20). See docs/decisions.md FOC-R360 ... FOC-R364.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

configuration=Debug
case "${1:-}" in
  "") ;;
  --production) configuration=Production ;;
  --release) configuration=Release ;;
  *) echo "usage: scripts/build.sh [--production|--release]" >&2; exit 2 ;;
esac

xcodegen generate
xcodebuild -project TheoNotes.xcodeproj -scheme TheoNotes -configuration "$configuration" \
  -derivedDataPath build/DerivedData build
if [ "$configuration" = Debug ]; then product="Theo Notes Dev"; else product="Theo Notes"; fi
echo "built: build/DerivedData/Build/Products/$configuration/$product.app"
