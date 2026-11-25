#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors
"""Checks or writes the licence header of first-party source files (plan L3).

Usage: python3 -I scripts/licence-headers.py --check|--write [--root DIR]

A first-party file begins (after a shebang or a swift-tools-version line) with the SPDX line and the
copyright line. Files come from the tracked file list of the work tree (a directory walk when DIR is
not a work tree).
"""

import subprocess
import sys
from pathlib import Path

sys.dont_write_bytecode = True

SPDX = "SPDX-License-Identifier: GPL-3.0-only"
COPYRIGHT = "Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors"

COMMENT = {
    ".swift": ("// ", ""), ".ts": ("// ", ""), ".js": ("// ", ""), ".mjs": ("// ", ""),
    ".py": ("# ", ""), ".sh": ("# ", ""), ".css": ("/* ", " */"),
}

# Documents, fixtures and spikes are not shipped code; patches and generated binaries are not ours to edit.
EXCLUDE_PREFIXES = ("docs/", "Fixtures/", "spikes/", "third_party/", "web/editor/patches/")
EXCLUDE_FILES = {"web/editor/src/editor/features/hidden-font.ts"}  # base64 font written by make-hidden-font.py
EXCLUDE_DIRS = {"node_modules", ".build", "build", "DerivedData", "dist", ".git", ".superpowers"}


def is_preamble(line):
    return line.startswith("#!") or line.startswith("// swift-tools-version")


def header_lines(ext):
    pre, post = COMMENT[ext]
    return [f"{pre}{SPDX}{post}", f"{pre}{COPYRIGHT}{post}"]


def candidates(root):
    try:
        out = subprocess.run(["git", "-C", str(root), "ls-files", "-z"], check=True, capture_output=True).stdout
        names = [n for n in out.decode().split("\0") if n]
    except (subprocess.CalledProcessError, FileNotFoundError):
        names = [str(p.relative_to(root)) for p in root.rglob("*") if p.is_file()]
    for name in sorted(names):
        path = Path(name)
        if path.suffix not in COMMENT or name in EXCLUDE_FILES or name.startswith(EXCLUDE_PREFIXES):
            continue
        if EXCLUDE_DIRS.intersection(path.parts[:-1]):
            continue
        if (root / name).is_file():
            yield name, path.suffix


def preamble_length(lines):
    n = 0
    while n < len(lines) and is_preamble(lines[n]):
        n += 1
    return n


def has_header(lines, ext):
    n = preamble_length(lines)
    return lines[n:n + 2] == header_lines(ext)


def main(argv):
    mode = next((a for a in argv if a in ("--check", "--write")), None)
    root = Path(argv[argv.index("--root") + 1]) if "--root" in argv else Path(__file__).resolve().parent.parent
    if mode is None:
        print("usage: licence-headers.py --check|--write [--root DIR]", file=sys.stderr)
        return 2
    missing, changed = [], 0
    for name, ext in candidates(root):
        path = root / name
        lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
        bare = [l.rstrip("\r\n") for l in lines]
        if has_header(bare, ext):
            continue
        if mode == "--check":
            missing.append(name)
            continue
        n = preamble_length(bare)
        block = [l + "\n" for l in header_lines(ext)]
        if n < len(lines) and bare[n] != "":
            block.append("\n")
        if n and not lines[n - 1].endswith("\n"):
            lines[n - 1] += "\n"
        path.write_text("".join(lines[:n] + block + lines[n:]), encoding="utf-8")
        changed += 1
    if mode == "--check":
        for name in missing:
            print(f"missing-header {name}")
        print("licence-headers: ok" if not missing else f"licence-headers: {len(missing)} file(s) without header")
        return 1 if missing else 0
    print(f"licence-headers: wrote {changed} file(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
