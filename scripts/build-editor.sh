#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${1:-$ROOT/Apps/TheoNotesMac/Resources/Editor}"

# Xcode script phases run with a minimal PATH; add the usual tool locations.
EXTRA_PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.volta/bin:$HOME/.local/bin:$HOME/Library/pnpm"
for d in "$HOME"/.nvm/versions/node/*/bin; do
  [ -d "$d" ] && EXTRA_PATH="$EXTRA_PATH:$d"
done
export PATH="$EXTRA_PATH:$PATH"

for tool in node pnpm; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: '$tool' not found. PATH=$PATH" >&2
    echo "Install Node 22 and pnpm (e.g. brew install node pnpm) or add them to the PATH list in scripts/build-editor.sh." >&2
    exit 1
  fi
done

# Each native build owns its bundle directory. Concurrent Mac/iOS builds must not empty
# web/editor/dist while another target is copying hashed chunks from it.
EDITOR_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/baerchen-editor.XXXXXX")"
trap 'rm -rf "$EDITOR_BUILD"' EXIT
# Built with source maps so that scripts/gen-acknowledgements.py --check can rebuild the exact same
# bytes and read the module graph from the maps; the maps themselves are not shipped.
pnpm --dir "$ROOT/web/editor" build --sourcemap --outDir "$EDITOR_BUILD" --emptyOutDir
mkdir -p "$DEST"
rsync -a --delete --exclude='*.map' "$EDITOR_BUILD/" "$DEST/"
