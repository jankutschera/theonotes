#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

"""Clean-room guard (ruling M5-R269): no sentence of Bear's help or MCP prose may ship.

Usage: python3 -I scripts/ip-guard.py              compare the research dumps with the shipping sources
       python3 -I scripts/ip-guard.py --self-test  check the matcher itself on synthetic text

Reads the private research dumps (docs/research/bearcli-help-all.txt and the descriptions in
docs/research/bear-mcp-tools.json) and fails when any sentence of MIN_WORDS words or more from them
appears, after normalisation, in a shipping source: Packages/**/Sources, Apps/**/Sources,
web/editor/src, Fixtures/cli and Fixtures/mcp. The research files are only read here, never by a
build script. When they are absent (a public checkout), the guard passes.

Normalisation: lower case, words are runs of [a-z0-9]; the product names (bear, bearcli, baerchen,
barchen) collapse to one token, so a renamed copy still matches. USAGE lines and flag tokens are
interface facts and are left out of the reference sentences.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MIN_WORDS = 8
HELP_DUMP = ROOT / "docs/research/bearcli-help-all.txt"
MCP_DUMP = ROOT / "docs/research/bear-mcp-tools.json"
SCAN = [
    ("Packages/*/Sources", {".swift", ".json", ".txt", ".md"}),
    ("Apps/*/Sources", {".swift", ".json", ".txt", ".md"}),
    ("web/editor/src", {".ts", ".js", ".json", ".css", ".html", ".md"}),
    ("Fixtures/cli", {".json", ".txt", ".md"}),
    ("Fixtures/mcp", {".json", ".txt", ".md"}),
]
BRAND = {"bear", "bearcli", "baerchen", "barchen"}
FLAG = re.compile(r"(?<![\w-])--?[A-Za-z][\w-]*")
SENTENCE_END = re.compile(r"(?<=[.!?])\s+")


def words(text):
    text = text.replace("\\n", " ").replace("\\t", " ")
    text = re.sub(r"\\u[0-9a-fA-F]{4}", " ", text)
    text = text.replace("\\u{E4}", "a").replace("ä", "a")
    return ["brand" if w in BRAND else w for w in re.findall(r"[a-z0-9]+", text.lower())]


def sentences(text):
    out = []
    for paragraph in re.split(r"\n\s*\n", text):
        lines = [l for l in paragraph.splitlines() if not l.strip().startswith("USAGE:")]
        flat = " ".join(l.strip() for l in lines)
        flat = FLAG.sub(" ", flat)
        for sentence in SENTENCE_END.split(flat):
            w = words(sentence)
            if len(w) >= MIN_WORDS:
                out.append((sentence.strip(), w))
    return out


def mcp_prose(value, out):
    if isinstance(value, dict):
        for key, item in value.items():
            if key == "description" and isinstance(item, str):
                out.append(item)
            else:
                mcp_prose(item, out)
    elif isinstance(value, list):
        for item in value:
            mcp_prose(item, out)


def reference_sentences():
    found = []
    if HELP_DUMP.exists():
        found += sentences(HELP_DUMP.read_text(encoding="utf-8"))
    if MCP_DUMP.exists():
        data = json.loads(MCP_DUMP.read_text(encoding="utf-8"))
        prose = [data["initialize"]["result"].get("instructions", "")]
        mcp_prose(data["tools"]["result"]["tools"], prose)
        for text in prose:
            found += sentences(text)
    return found


def shipping_files():
    for pattern, suffixes in SCAN:
        for base in sorted(ROOT.glob(pattern)):
            for path in sorted(base.rglob("*")):
                if path.is_file() and path.suffix in suffixes and "node_modules" not in path.parts:
                    yield path


def find_hits(reference, texts):
    """[(name, reference sentence)] for every reference sentence that occurs in one of the texts."""
    hits = []
    for name, text in texts:
        haystack = " " + " ".join(words(text)) + " "
        for sentence, w in reference:
            if " " + " ".join(w) + " " in haystack:
                hits.append((name, sentence))
    return hits


def shipping_texts():
    for path in shipping_files():
        try:
            yield path.relative_to(ROOT), path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue


def self_test():
    """The guard must catch a copy (also with the product name swapped and quotes or wrapping changed)
    and let a rewrite through."""
    reference = sentences("Moves a note to the archive so that it is hidden from the main list of every user.")
    copy = 'let s = "Moves a note to the archive\\nso that it is hidden from the main list of every user."'
    renamed = "Moves a note to the archive so that it is hidden from the main list of every user"
    rewrite = "Puts the note into the archive; the active list no longer shows it."
    assert len(reference) == 1
    assert find_hits(reference, [("copy", copy)]), "a verbatim copy went unnoticed"
    assert find_hits(reference, [("renamed", renamed)]), "a copy without the full stop went unnoticed"
    assert not find_hits(reference, [("rewrite", rewrite)]), "a rewrite was flagged"
    short = sentences("Move a note to the archive.")
    assert not short, "short sentences must not count"
    print("ip-guard: self-test ok")
    return 0


def main(argv):
    if argv[1:] == ["--self-test"]:
        return self_test()
    if argv[1:]:
        raise SystemExit(__doc__)
    reference = reference_sentences()
    if not reference:
        print("ip-guard: no research dumps present, nothing to compare")
        return 0
    hits = find_hits(reference, shipping_texts())
    for path, sentence in hits:
        print(f"ip-guard: {path}: {sentence[:110]}", file=sys.stderr)
    if hits:
        print(f"ip-guard: {len(hits)} reference sentence(s) of {MIN_WORDS}+ words found in shipping sources", file=sys.stderr)
        return 1
    print(f"ip-guard: ok ({len(reference)} reference sentences, none shipped)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
