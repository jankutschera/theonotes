#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

# Regenerates the Theo Notes macOS app icon from Jan's existing artwork in docs/brand/.
#
#   scripts/make-app-icon.sh           rebuild the head crop and every PNG in the AppIcon set
#   scripts/make-app-icon.sh --check   verify the set without writing anything
#
# macOS 26 draws the icon shape itself (HIG "App icons": "provide square layers so the system
# can apply rounded corners"; pre-masked layers "negatively impact specular highlight effects").
# So the PNGs must fill the whole square: no baked rounded rectangle, no margin, opaque corners.
# docs/brand/app-icon-1024.png is the OLD pre-masked art and is no longer an input.
#
# Input (docs/brand/, never modified):
#   app-icon-source.png        1254x1254, full-bleed, opaque (the artwork)
# Generated:
#   app-icon-small-source.png  the head crop below, used for the 16 pt and 32 pt slots
#
# Head crop (pixels of the 1254x1254 source, top-left origin): x 120..1160, y 100..1140,
# a 1040x1040 square. It keeps both ears, the glasses, nose and smile and trims the cream
# margin, so the bear's silhouette and glasses fill the frame at 16 and 32 px (a tighter
# face-only crop lost the ears and read as a brown blob at 16 px). sips takes it as
# --cropToHeightWidth 1040 1040 --cropOffset 100 120 (offset is y then x).
#
# Slots: every pixel size that serves a 16 pt or 32 pt slot (16, 32, 64 px) comes from the head
# crop, so 1x and 2x of the same slot look identical. 128 pt and up come from the full artwork.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/docs/brand/app-icon-source.png"
SMALL="$ROOT/docs/brand/app-icon-small-source.png"
SET="$ROOT/Apps/TheoNotesMac/Assets.xcassets/AppIcon.appiconset"
CROP_SIDE=1040 CROP_Y=100 CROP_X=120

check() {
  [ -f "$SET/Contents.json" ] || { echo "FAIL: $SET/Contents.json missing" >&2; return 1; }
  python3 -I - "$SET" <<'PY'
import json, os, struct, subprocess, sys, zlib

set_dir = sys.argv[1]
contents = json.load(open(os.path.join(set_dir, "Contents.json")))
failures = []

def pixel_size(path):
    out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", path],
                         capture_output=True, text=True, check=True).stdout
    values = {l.split(":")[0].strip(): int(l.split(":")[1]) for l in out.splitlines() if ":" in l and "pixel" in l}
    return values["pixelWidth"], values["pixelHeight"]

def has_alpha(path):
    out = subprocess.run(["sips", "-g", "hasAlpha", path], capture_output=True, text=True, check=True).stdout
    return "yes" in out

def corner_alphas(path):
    """Alpha of the four corner pixels of an 8-bit non-interlaced PNG (color type 2, 4 or 6)."""
    data = open(path, "rb").read()
    pos, idat, ihdr = 8, b"", None
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR": ihdr = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT": idat += body
        pos += 12 + length
    w, h, depth, ctype, _, _, interlace = ihdr
    if depth != 8 or interlace != 0 or ctype not in (2, 4, 6):
        raise ValueError("unsupported PNG layout (depth %d, color type %d, interlace %d)" % (depth, ctype, interlace))
    channels = {2: 3, 4: 2, 6: 4}[ctype]
    stride = w * channels
    raw = zlib.decompress(idat)
    rows, prev = [], bytearray(stride)
    for y in range(h):
        ft = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - channels] if i >= channels else 0
            b = prev[i]
            c = prev[i - channels] if i >= channels else 0
            if ft == 1: line[i] = (line[i] + a) & 255
            elif ft == 2: line[i] = (line[i] + b) & 255
            elif ft == 3: line[i] = (line[i] + (a + b) // 2) & 255
            elif ft == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        rows.append(line)
        prev = line
    def alpha(x, y):
        return 255 if channels == 3 else rows[y][x * channels + channels - 1]
    return [alpha(0, 0), alpha(w - 1, 0), alpha(0, h - 1), alpha(w - 1, h - 1)]

largest = (None, 0)
for image in contents["images"]:
    name = image.get("filename")
    if not name:
        failures.append("slot %s %s has no filename" % (image.get("size"), image.get("scale")))
        continue
    path = os.path.join(set_dir, name)
    if not os.path.isfile(path):
        failures.append("%s is listed in Contents.json but missing" % name)
        continue
    points = int(image["size"].split("x")[0])
    scale = int(image["scale"].rstrip("x"))
    expected = points * scale
    w, h = pixel_size(path)
    if (w, h) != (expected, expected):
        failures.append("%s is %dx%d, Contents.json says %dx%d" % (name, w, h, expected, expected))
    if expected > largest[1]:
        largest = (path, expected)

if largest[0] is None:
    failures.append("no 1024 image in Contents.json")
else:
    path = largest[0]
    if largest[1] != 1024:
        failures.append("largest image is %d px, expected 1024" % largest[1])
    elif has_alpha(path):
        try:
            alphas = corner_alphas(path)
        except Exception as e:
            alphas = None
            failures.append("cannot read corner pixels of %s: %s" % (os.path.basename(path), e))
        if alphas is not None and min(alphas) < 255:
            failures.append("%s has transparent corner pixels (alpha %s): the rounded mask is baked in, "
                            "macOS 26 needs a full-bleed square" % (os.path.basename(path), alphas))

if failures:
    for f in failures: print("FAIL: " + f, file=sys.stderr)
    sys.exit(1)
print("ok: %d images match Contents.json, 1024 corners are opaque" % len(contents["images"]))
PY
}

generate() {
  [ -f "$SOURCE" ] || { echo "FAIL: $SOURCE missing" >&2; exit 1; }
  [ "$(sips -g pixelWidth "$SOURCE" | awk '/pixelWidth/{print $2}')" = 1254 ] \
    || { echo "FAIL: $SOURCE is not 1254 px wide" >&2; exit 1; }
  [ "$(sips -g hasAlpha "$SOURCE" | awk '/hasAlpha/{print $2}')" = no ] \
    || { echo "FAIL: $SOURCE has an alpha channel; it must be full-bleed and opaque" >&2; exit 1; }

  sips --cropToHeightWidth "$CROP_SIDE" "$CROP_SIDE" --cropOffset "$CROP_Y" "$CROP_X" \
    "$SOURCE" --out "$SMALL" >/dev/null

  # name:pixels:from (from = full or head)
  for spec in \
    icon_16x16.png:16:head icon_16x16@2x.png:32:head \
    icon_32x32.png:32:head icon_32x32@2x.png:64:head \
    icon_128x128.png:128:full icon_128x128@2x.png:256:full \
    icon_256x256.png:256:full icon_256x256@2x.png:512:full \
    icon_512x512.png:512:full icon_512x512@2x.png:1024:full; do
    IFS=: read -r name px from <<<"$spec"
    src="$SOURCE"; [ "$from" = head ] && src="$SMALL"
    sips --resampleHeightWidth "$px" "$px" "$src" --out "$SET/$name" >/dev/null
  done
  echo "regenerated $SMALL and 10 PNGs in $SET"
}

case "${1:-}" in
  --check) check ;;
  "") generate && check ;;
  *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac
