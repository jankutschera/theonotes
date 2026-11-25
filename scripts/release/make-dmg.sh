#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

# Packs a built Theo Notes into a disk image: the app plus a link to /Applications (REL-R64). Nothing is mounted
# or executed.
#
#   scripts/release/make-dmg.sh --app <Theo Notes.app> --out <file.dmg> --identity <SHA-1 of the Developer ID Application cert>
#   scripts/release/make-dmg.sh --dry-run --app <Theo Notes.app> --out <file.dmg>      (image is left unsigned)
#
# Exit 0 = done, 1 = a step failed, 2 = refused (bad usage, no identity in real mode, or the app is not the
# production identity). Signing follows Apple's "Creating distribution-signed code for the Mac": the image gets
# its own Developer ID signature with a secure timestamp, then it is submitted to the notary service by the caller.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

dry=0 app="" out="" identity="${THEONOTES_SIGN_IDENTITY_HASH:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1 ;;
    --app) [ $# -ge 2 ] || { echo "--app needs a value" >&2; exit 2; }; app="${2%/}"; shift ;;
    --out) [ $# -ge 2 ] || { echo "--out needs a value" >&2; exit 2; }; out="$2"; shift ;;
    --identity) [ $# -ge 2 ] || { echo "--identity needs a value" >&2; exit 2; }; identity="$2"; shift ;;
    -h|--help) sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$app" ] || { echo "--app is required" >&2; exit 2; }
[ -n "$out" ] || { echo "--out is required" >&2; exit 2; }
case "$out" in *.dmg) ;; *) echo "--out must end in .dmg" >&2; exit 2 ;; esac

require_production_bundle "$app"
if [ "$dry" -eq 0 ] && [ -z "$identity" ]; then
  refuse "real mode needs --identity (the SHA-1 of the Developer ID Application certificate); use --dry-run for an unsigned image"
fi

stage="$(mktemp -d "${TMPDIR:-/tmp}/theonotes-dmg.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Theo Notes.app"
ln -s /Applications "$stage/Applications"

mkdir -p "$(dirname "$out")"
rm -f "$out"
say "hdiutil create $out"
hdiutil create -volname "Theo Notes" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$out"
hdiutil verify "$out"

if [ "$dry" -eq 1 ]; then
  echo "dry run: $out is NOT signed"
else
  say "sign $out"
  codesign --force --timestamp --sign "$identity" "$out"
  codesign --verify --strict --verbose=2 "$out"
fi
echo "dmg: $out"
