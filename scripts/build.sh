#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

# Builds the app. Without a flag: the DEV identity (configuration Debug, bundle id
# com.truebrewbirdie.baerchen.dev, "Theo Notes Dev", library "Theo Notes Dev"), the build for tests,
# agents and GUI checks. `--production`: the identity Jan installs (configuration Production, bundle id
# com.truebrewbirdie.baerchen), for scripts/install-dev.sh. `--release`: the public configuration (Release, same
# identity as production, sync setup hidden), team from config/release.env. See docs/decisions.md.
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
