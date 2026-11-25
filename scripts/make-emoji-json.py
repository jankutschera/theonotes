#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

"""Generates Packages/TheoNotesCore/Sources/TheoNotesCore/Resources/emoji.json.

Inputs (Unicode data, Unicode License v3):
  emoji-test.txt         https://unicode.org/Public/emoji/latest/emoji-test.txt
  CLDR annotations       cldr-json cldr-annotations-full/annotations/{en,de}/annotations.json
  CLDR derived           cldr-json cldr-annotations-derived-full/annotationsDerived/{en,de}/annotations.json

Usage: make-emoji-json.py EMOJI_TEST EN EN_DERIVED DE DE_DERIVED OUT

Keeps the fully-qualified emoji in emoji-test.txt order, without skin-tone, hair and gender
variants, family/couple sequences, components, country and subdivision flags (about 1,500). Each
entry: {"e": emoji, "en": [name, keywords...], "de": [name, keywords...]} (name = CLDR `tts`,
at most MAX_NAMES words per language).
"""
import json
import sys


def annotations(*paths):
    table = {}
    for path in paths:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        node = data.get("annotations") or data.get("annotationsDerived")
        table.update(node["annotations"])
    return table


MAX_NAMES = 7


def names(entry):
    """The CLDR name first, then up to MAX_NAMES - 1 keywords."""
    if not entry:
        return []
    out = []
    for word in entry.get("tts", []) + entry.get("default", []):
        word = word.strip()
        if word and word not in out:
            out.append(word)
    return out[:MAX_NAMES]


def keep(group, subgroup, cps):
    if group == "Component" or subgroup in ("country-flag", "subdivision-flag"):
        return False
    if any(0x1F3FB <= c <= 0x1F3FF for c in cps):  # skin tones
        return False
    if 0x200D in cps and (0x2640 in cps or 0x2642 in cps):  # gender variants
        return False
    if len(cps) > 1 and any(0x1F9B0 <= c <= 0x1F9B3 for c in cps):  # hair variants
        return False
    if subgroup == "family" and 0x200D in cps:  # couples and families
        return False
    return True


def main(argv):
    emoji_test, en, en_derived, de, de_derived, out = argv[1:7]
    en_table = annotations(en, en_derived)
    de_table = annotations(de, de_derived)
    entries = []
    group = subgroup = None
    with open(emoji_test, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("# group:"):
                group = line[len("# group:"):].strip()
                continue
            if line.startswith("# subgroup:"):
                subgroup = line[len("# subgroup:"):].strip()
                continue
            if not line or line.startswith("#"):
                continue
            codes, rest = line.split(";", 1)
            if rest.split("#", 1)[0].strip() != "fully-qualified":
                continue
            cps = [int(c, 16) for c in codes.split()]
            if not keep(group, subgroup, cps):
                continue
            emoji = "".join(chr(c) for c in cps)
            # CLDR keys drop the emoji presentation selector.
            key = emoji.replace("\ufe0f", "")
            en_names = names(en_table.get(emoji) or en_table.get(key))
            de_names = names(de_table.get(emoji) or de_table.get(key))
            if not en_names:
                continue
            entries.append({"e": emoji, "en": en_names, "de": de_names})
    with open(out, "w", encoding="utf-8") as f:
        f.write("[\n")
        f.write(",\n".join(json.dumps(e, ensure_ascii=False, separators=(",", ":")) for e in entries))
        f.write("\n]\n")
    print(f"{len(entries)} emoji -> {out}")


if __name__ == "__main__":
    main(sys.argv)
