#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

# Builds and tests an export in a temporary copy (plan task P1/P2). Prints the first failing command.
# Usage: scripts/oss/verify-export.sh EXPORT_DIR
# Heavy: runs the Swift package tests, the editor tests, the Python tests and a Mac build. Do not run it
# while someone is using the GUI. The Mac build uses the dev identity, unsigned (as a contributor or CI builds it);
# nothing is installed or launched.
set -u
if [ $# -ne 1 ] || [ ! -d "$1" ]; then
  echo "usage: $0 EXPORT_DIR" >&2
  exit 2
fi
SRC="$(cd "$1" && pwd)"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/verify-export.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cp -R "$SRC/." "$WORK/"
cd "$WORK" || exit 2

step() {
  echo "verify-export: $*" >&2
  if ! "$@"; then
    echo "verify-export: FAILED: $*" >&2
    exit 1
  fi
}

step python3 -I "$SELF/scan.py" "$WORK"
step bash scripts/bootstrap.sh
core="$(ls -d Packages/*Core | head -n 1)"
step swift build --package-path "$core"
step swift test --package-path "$core"
step pnpm --dir web/editor test
step python3 -I -m unittest discover -s scripts/tests -p 'test_*.py'
step xcodegen generate
project="$(ls -d ./*.xcodeproj | head -n 1)"
scheme="$(basename "$project" .xcodeproj)"
step xcodebuild -project "$project" -scheme "$scheme" -configuration Debug -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
echo "verify-export: all steps passed" >&2
