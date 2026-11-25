#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

# Tests the iCloud container rule of scripts/check-identities.sh (CloudKit plan Task 12): the check passes when no
# source names a container and fails when one does. It reads the generated project, so run `xcodegen generate` first.
# Only xcodebuild -showBuildSettings is called; nothing is built or launched. Run: bash scripts/tests/test_check_identities.sh
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/theo-identities-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
cd "$root"
[ -d TheoNotes.xcodeproj ] || { echo "no TheoNotes.xcodeproj: run xcodegen generate" >&2; exit 1; }

mkdir -p "$work/clean" "$work/planted"
echo 'let note = "nothing to see"' > "$work/clean/Clean.swift"
echo 'let container = "iCloud.com.example.planted"' > "$work/planted/Planted.swift"

# A clean extra source directory changes nothing: the whole check passes on the tree.
if IDENTITY_CHECK_SOURCES="Packages/TheoNotesCore/Sources Apps/TheoNotesMac Apps/TheoNotesMacShare Apps/TheoNotesCLI $work/clean" \
   bash scripts/check-identities.sh > "$work/clean.out" 2>&1; then
  grep -q "ok    no source file names an iCloud container" "$work/clean.out" || { echo "FAIL: clean run lacks the container line" >&2; exit 1; }
  echo "ok  the check passes when no source names a container"
else
  sed 's/^/    | /' "$work/clean.out" >&2
  echo "FAIL: the check should pass on the tree" >&2
  exit 1
fi

# A planted container literal fails it, and the failure names the file.
if IDENTITY_CHECK_SOURCES="Packages/TheoNotesCore/Sources Apps/TheoNotesMac Apps/TheoNotesMacShare Apps/TheoNotesCLI $work/planted" \
   bash scripts/check-identities.sh > "$work/planted.out" 2>&1; then
  echo "FAIL: a planted container literal must fail the check" >&2
  exit 1
fi
grep -q "an iCloud container literal appears in: .*Planted.swift" "$work/planted.out" || {
  sed 's/^/    | /' "$work/planted.out" >&2
  echo "FAIL: the failure should name the planted file" >&2
  exit 1
}
echo "ok  a planted container literal fails the check"
echo "all check-identities container checks passed"
