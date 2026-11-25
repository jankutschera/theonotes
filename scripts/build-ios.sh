#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
xcodegen generate
xcodebuild -project TheoNotes.xcodeproj -scheme TheoNotesIOS \
  -destination "${BAERCHEN_IOS_DESTINATION:-generic/platform=iOS Simulator}" \
  -derivedDataPath "${BAERCHEN_IOS_BUILD_DIR:-$ROOT/build/ios}" \
  CODE_SIGNING_ALLOWED=NO build
