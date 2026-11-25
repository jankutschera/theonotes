#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Fast pass: the 10k-note timing gates are skipped, cheap ones use loose bounds (ruling R29).
swift test --package-path Packages/TheoNotesCore
python3 -I scripts/gen-automation-sources.py --check
python3 -I scripts/tests/test_gen_acknowledgements.py
python3 -I scripts/tests/test_check_entitlements.py
python3 -I scripts/tests/test_asc_dev_profile.py
python3 -I scripts/tests/test_profiles.py
bash scripts/tests/test_release_scripts.sh
python3 -I scripts/ip-guard.py
python3 -I scripts/copy-guard.py
python3 -I scripts/licence-headers.py --check
# Rename stage 2 (A1): every use of the old working-title name must be covered by scripts/name-guard.json.
python3 -I scripts/tests/test_name_guard.py
python3 -I scripts/tests/test_stage2_rename.py
python3 -I scripts/name-guard.py --check
python3 -I scripts/mcp-smoke.py --self-test
bash scripts/test-install-dev.sh
bash scripts/tests/test_cutover_safety.sh
pnpm --dir web/editor typecheck
pnpm --dir web/editor test
pnpm --dir web/editor e2e
xcodegen generate
bash scripts/check-identities.sh
bash scripts/tests/test_check_identities.sh
xcodebuild -project TheoNotes.xcodeproj -scheme TheoNotes -configuration Debug \
  -derivedDataPath build/DerivedData test
# LIC-R17: the licence list must cover the app that was just built (every file in its Resources).
python3 -I scripts/gen-acknowledgements.py --check
# Perf pass (R29): every `.perf` test (named `testPerf…`), strict and one at a time.
BAERCHEN_PERF=1 swift test --package-path Packages/TheoNotesCore --no-parallel --filter '/testPerf'
