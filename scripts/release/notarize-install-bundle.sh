#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

# Notarizes and staples the Production bundle that Jan installs on his own Mac (REN2-R66), headlessly with the App Store Connect
# API key (notarytool --key, no keychain profile needed):
#
#   scripts/release/notarize-install-bundle.sh <path to Theo Notes.app of the Production build>
#
# Why: `spctl --assess` rejects an unnotarized Developer ID app ("source=Unnotarized Developer ID"). A build that was never
# downloaded carries no quarantine flag, so launching it should not be assessed, but that is a rule about Gatekeeper that cannot
# be tested without launching the production identity (not allowed to agents). Notarizing removes the doubt. It takes minutes to
# about half an hour (the first run of the gate spike took 35 minutes).
#
# Environment: ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID (never printed). Exit 0 = accepted, stapled, `spctl --assess` accepts it.
# Only a production-identity bundle is accepted (the same refusal as verify-bundle.sh); nothing is launched.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
app="${1:-}"
[ -n "$app" ] || { echo "usage: notarize-install-bundle.sh <Theo Notes.app>" >&2; exit 2; }
app="${app%/}"
require_production_bundle "$app"
: "${ASC_KEY_PATH:?ASC_KEY_PATH is not set}" "${ASC_KEY_ID:?ASC_KEY_ID is not set}" "${ASC_ISSUER_ID:?ASC_ISSUER_ID is not set}"

work="$(mktemp -d "${TMPDIR:-/tmp}/theo-notarize.XXXXXX")"
trap 'rm -rf "$work"' EXIT
/usr/bin/ditto -c -k --keepParent "$app" "$work/bundle.zip"
say "submitting $(basename "$app") to the notary service"
xcrun notarytool submit "$work/bundle.zip" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" \
  --wait --output-format json > "$work/result.json" || true
status="$(/usr/bin/python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$work/result.json" 2>/dev/null || true)"
id="$(/usr/bin/python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$work/result.json" 2>/dev/null || true)"
if [ "$status" != "Accepted" ]; then
  echo "notarization status: '${status:-unknown}' (submission ${id:-none})" >&2
  [ -z "$id" ] || xcrun notarytool log "$id" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" 2>&1 | head -40 >&2 || true
  exit 1
fi
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=4 "$app"
say "notarized and stapled (submission $id)"
