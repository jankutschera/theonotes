#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

"""Product copy guard (FOC-R1): no user-facing text names a condition.

Usage: python3 -I scripts/copy-guard.py              scan the repository
       python3 -I scripts/copy-guard.py --self-test  plant a word in every scope kind and check it is found

The feature layer "Capture & Next Up" is a productivity feature. Nothing a person can read in the
apps, the command line help, the MCP descriptions, the website or the store text may contain the
words "ADHD" or "ADHS" (whole words, any case). Internal names (code identifiers, comments, test
names, spec files) may describe the feature and are not scanned.

Scope:
  whole files   Apps/**/Info.plist, *.strings, *.xcstrings, *.entitlements; Fixtures/cli/help-prose.json,
                Fixtures/mcp/descriptions.json, Fixtures/mcp/extension-tools.json; website/**; docs/store/**;
                the bundled getting started notes (Packages/TheoNotesCore/Sources/TheoNotesCore/Resources/getting-started-*.md)
  project.yml   the values of INFOPLIST_KEY_* and PRODUCT_NAME settings
  Swift         string literals ("...", \"\"\"...\"\"\", #"..."#) in Apps/*/Sources/**, Apps/TheoNotesMacShare/**,
                Apps/TheoNotesIOSWidgets/**, Apps/TheoNotesIOSShare/**, Packages/TheoNotesCore/Sources/TheoNotesAutomation/**,
                Packages/TheoNotesCore/Sources/TheoNotesCore/Focus/**, Packages/TheoNotesCore/Sources/TheoNotesVoice/**.
                Comments are not scanned.
"""
import bisect
import plistlib
import re
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PATTERN = re.compile(r"(?i)\badhd\b|\badhs\b")
SKIP_DIRS = {"node_modules", ".build", "build", ".git", "DerivedData"}

WHOLE_FILE_GLOBS = [
    "Apps/**/Info.plist",
    "Apps/**/*.strings",
    "Apps/**/*.xcstrings",
    "Apps/**/*.entitlements",
    "Fixtures/cli/help-prose.json",
    "Fixtures/mcp/descriptions.json",
    "Fixtures/mcp/extension-tools.json",
    "website/**/*",
    "docs/store/**/*",
    "Packages/TheoNotesCore/Sources/TheoNotesCore/Resources/getting-started-*.md",
]
SWIFT_GLOBS = [
    "Apps/*/Sources/**/*.swift",
    "Apps/TheoNotesMacShare/**/*.swift",
    "Apps/TheoNotesIOSWidgets/**/*.swift",
    "Apps/TheoNotesIOSShare/**/*.swift",
    "Packages/TheoNotesCore/Sources/TheoNotesAutomation/**/*.swift",
    "Packages/TheoNotesCore/Sources/TheoNotesCore/Focus/**/*.swift",
    "Packages/TheoNotesCore/Sources/TheoNotesVoice/**/*.swift",
]
PROJECT_SETTING = re.compile(r"^\s*(INFOPLIST_KEY_\w+|PRODUCT_NAME)\s*:\s*(.*)$")


def files(root, patterns):
    seen = set()
    for pattern in patterns:
        for path in sorted(root.glob(pattern)):
            if path.is_file() and path not in seen and not (SKIP_DIRS & set(path.relative_to(root).parts)):
                seen.add(path)
                yield path


class Undecodable(Exception):
    """A scoped file whose text cannot be read: the guard must not pass over it."""


BINARY_SUFFIXES = {
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".icns", ".heic", ".pdf", ".woff", ".woff2",
    ".ttf", ".otf", ".mp3", ".mp4", ".mov", ".wav", ".zip", ".gz", ".car", ".nib", ".mom",
}


def decode_text(data):
    """Decode bytes as text, BOM-aware: UTF-8, UTF-8 with BOM, UTF-16 LE/BE (with a BOM, or
    recognised by the NUL bytes of mostly-ASCII text). Returns None for a binary file; raises
    Undecodable for text that is none of these."""
    if data.startswith(b"\xef\xbb\xbf"):
        return data[3:].decode("utf-8")
    if data.startswith((b"\xff\xfe", b"\xfe\xff")):
        return data.decode("utf-16")  # the codec consumes the BOM and picks the byte order
    head = data[:8192]
    if b"\0" in head:
        # BOM-less UTF-16 of mostly ASCII text has a NUL in every other byte.
        even, odd = head[0::2], head[1::2]
        for encoding, nuls in (("utf-16-le", odd), ("utf-16-be", even)):
            if nuls and nuls.count(0) * 10 >= len(nuls) * 9 and (len(data) % 2 == 0):
                return data.decode(encoding)
        return None  # an image or another binary: nothing readable to check
    return data.decode("utf-8")


def plist_strings(value):
    """Every string key and value of a parsed property list, recursively."""
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for key, item in value.items():
            yield from plist_strings(key)
            yield from plist_strings(item)
    elif isinstance(value, (list, tuple)):
        for item in value:
            yield from plist_strings(item)


def read_text(path):
    data = path.read_bytes()
    if path.suffix.lower() in (".plist", ".entitlements") and data.startswith(b"bplist"):
        # A binary property list: parse it and check every string in it.
        try:
            return "\n".join(plist_strings(plistlib.loads(data)))
        except Exception as error:
            raise Undecodable(f"{path}: binary property list cannot be parsed ({error}); convert it to XML") from None
    try:
        return decode_text(data)
    except UnicodeDecodeError as error:
        if path.suffix.lower() in BINARY_SUFFIXES:
            return None
        raise Undecodable(f"{path}: cannot decode as UTF-8 or UTF-16 ({error.reason}); convert it or add its extension to BINARY_SUFFIXES") from None


def line_starts(text):
    starts = [0]
    for match in re.finditer("\n", text):
        starts.append(match.end())
    return starts


def line_at(starts, index):
    return bisect.bisect_right(starts, index)


def swift_literals(source):
    """Every string literal of a Swift source as (offset, text), without comments.

    Handles line and (nested) block comments, single-line and multi-line strings, raw strings with
    any number of #, and string interpolation (code inside \\( ) is scanned for further literals;
    only the literal's own text is returned for the outer string.
    """
    n = len(source)
    found = []

    def skip_line_comment(i):
        end = source.find("\n", i)
        return n if end < 0 else end

    def skip_block_comment(i):
        depth = 0
        while i < n:
            if source.startswith("/*", i):
                depth += 1
                i += 2
            elif source.startswith("*/", i):
                depth -= 1
                i += 2
                if depth == 0:
                    return i
            else:
                i += 1
        return n

    def lex_string(i):
        """i is at the first # or the opening quote. Returns the index after the literal, or None."""
        start = i
        hashes = 0
        while i < n and source[i] == "#":
            hashes += 1
            i += 1
        if i >= n or source[i] != '"':
            return None
        multi = source.startswith('"""', i)
        i += 3 if multi else 1
        closer = ('"""' if multi else '"') + "#" * hashes
        escape = "\\" + "#" * hashes
        body_start = i
        parts = []
        while i < n:
            if source.startswith(escape + "(", i):
                parts.append(source[body_start:i])
                i = lex_code(i + len(escape) + 1, nested=True)
                body_start = i
            elif source.startswith(escape, i):
                i += len(escape) + 1  # the escaped character
            elif source.startswith(closer, i):
                parts.append(source[body_start:i])
                found.append((start, "".join(parts)))
                return i + len(closer)
            elif not multi and source[i] == "\n":
                break  # unterminated single-line literal: stop at the line end
            else:
                i += 1
        parts.append(source[body_start:i])
        found.append((start, "".join(parts)))
        return i

    def lex_code(i, nested=False):
        depth = 0
        while i < n:
            c = source[i]
            if source.startswith("//", i):
                i = skip_line_comment(i)
            elif source.startswith("/*", i):
                i = skip_block_comment(i)
            elif c == '"' or c == "#":
                end = lex_string(i)
                i = end if end is not None else i + 1
            elif nested and c == "(":
                depth += 1
                i += 1
            elif nested and c == ")":
                if depth == 0:
                    return i + 1
                depth -= 1
                i += 1
            else:
                i += 1
        return n

    lex_code(0)
    return found


def scan(root):
    """All findings under `root` as (relative path, line, kind, matched word)."""
    findings = []

    def add(path, line, kind, text):
        for match in PATTERN.finditer(text):
            findings.append((str(path.relative_to(root)), line, kind, match.group(0)))

    for path in files(root, WHOLE_FILE_GLOBS):
        text = read_text(path)
        if text is None:
            continue
        starts = line_starts(text)
        for match in PATTERN.finditer(text):
            findings.append((str(path.relative_to(root)), line_at(starts, match.start()), "file", match.group(0)))

    project = root / "project.yml"
    if project.is_file():
        for number, line in enumerate((read_text(project) or "").splitlines(), 1):
            setting = PROJECT_SETTING.match(line)
            if setting:
                add(project, number, f"project.yml {setting.group(1)}", setting.group(2))

    for path in files(root, SWIFT_GLOBS):
        text = read_text(path)
        if text is None:
            continue
        starts = line_starts(text)
        for offset, literal in swift_literals(text):
            first = line_at(starts, offset)
            for match in PATTERN.finditer(literal):
                findings.append((str(path.relative_to(root)), first + literal.count("\n", 0, match.start()), "swift literal", match.group(0)))
    return sorted(set(findings))


def report(findings):
    for path, line, kind, word in findings:
        print(f"{path}:{line}: '{word}' in {kind}", file=sys.stderr)


def self_test():
    failures = []

    def write(root, relative, text, encoding="utf-8"):
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(text.encode(encoding))

    with tempfile.TemporaryDirectory() as tmp, tempfile.TemporaryDirectory() as cases:
        root = Path(tmp)
        # Clean material, including every way a comment or code can mention the word.
        write(root, "Apps/Demo/Sources/Clean.swift", "\n".join([
            "// ADHD in a line comment",
            "/* adhd in a block comment /* nested ADHS */ still a comment ADHD */",
            "/// ADHS in a doc comment",
            'let ok = "Capture & Next Up"',
            'let raw = #"quote " and \\#(1) stay"#',
            "let adhdIdentifier = 1",
            'let hyphen = "adhdlike"',
            "",
        ]))
        write(root, "Apps/Demo/Info.plist", "<plist><string>Capture</string></plist>")
        write(root, "project.yml", "settings:\n  INFOPLIST_KEY_CFBundleDisplayName: Theo Notes\n  OTHER_KEY: adhd\n")
        write(root, "docs/store/listing.txt", "Capture and return.\n")
        write(root, "website/index.html", "<p>Notes</p>\n")
        clean = scan(root)
        if clean:
            failures.append(f"clean tree reported: {clean}")

        planted = {
            "swift literal": ("Apps/Demo/Sources/Bad.swift", 'import Foundation\nlet title = "Built for ADHD"\n', 2),
            "swift multi-line literal": ("Packages/TheoNotesCore/Sources/TheoNotesAutomation/Bad.swift", 'let t = """\nfirst\nfor adhs people\n"""\n', 3),
            "swift interpolation": ("Packages/TheoNotesCore/Sources/TheoNotesCore/Focus/Bad.swift", 'let t = "a \\(f("ADHD")) b"\n', 1),
            "swift raw literal": ("Packages/TheoNotesCore/Sources/TheoNotesVoice/Bad.swift", 'let t = #"ADHD"#\n', 1),
            "plist": ("Apps/Demo/Extra/Info.plist", "<plist>\n<string>ADHS helper</string>\n</plist>\n", 2),
            "strings": ("Apps/Demo/Base.lproj/Localizable.strings", '"k" = "adhd";\n', 1),
            "project.yml": ("project.yml", "settings:\n  INFOPLIST_KEY_CFBundleDisplayName: Theo Notes\n  INFOPLIST_KEY_NSMicrophoneUsageDescription: ADHD voice notes\n", 3),
            "project.yml product name": ("project.yml", "settings:\n  PRODUCT_NAME: ADHD Notes\n", None),
            "docs/store": ("docs/store/listing.txt", "Line one.\nFor ADHD brains.\n", 2),
            "fixture": ("Fixtures/mcp/extension-tools.json", '{"description": "ADHS"}\n', 1),
            "website": ("website/index.html", "<p>ADHD</p>\n", 1),
            "getting started note": ("Packages/TheoNotesCore/Sources/TheoNotesCore/Resources/getting-started-9-x.md", "# Title\n\nFor ADHD minds.\n", 3),
        }
        for name, (relative, text, line) in planted.items():
            # Every case starts from a copy of the clean tree plus the one planted file.
            fresh = Path(cases) / name.replace(" ", "_").replace("/", "_")
            shutil.copytree(root, fresh)
            write(fresh, relative, text)
            result = scan(fresh)
            if not result:
                failures.append(f"{name}: planted word not reported")
            elif line is not None and not any(r[0] == relative and r[1] == line for r in result):
                failures.append(f"{name}: expected {relative}:{line}, got {result}")
            elif any(r[0] != relative for r in result):
                failures.append(f"{name}: unrelated file reported: {result}")
        # Encodings of a .strings file: each must be decoded and the word found.
        encodings = {
            "utf-16 with BOM": "utf-16",
            "utf-16 LE with BOM": "utf-16-le-bom",
            "utf-16 BE with BOM": "utf-16-be-bom",
            "utf-16 LE without BOM": "utf-16-le",
            "utf-16 BE without BOM": "utf-16-be",
            "utf-8 with BOM": "utf-8-sig",
        }
        relative = "Apps/Demo/de.lproj/Localizable.strings"
        for name, encoding in encodings.items():
            fresh = Path(cases) / ("enc_" + name.replace(" ", "_"))
            shutil.copytree(root, fresh)
            text = '"k" = "Built for ADHD";\n'
            path = fresh / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            if encoding == "utf-16-le-bom":
                path.write_bytes(b"\xff\xfe" + text.encode("utf-16-le"))
            elif encoding == "utf-16-be-bom":
                path.write_bytes(b"\xfe\xff" + text.encode("utf-16-be"))
            else:
                path.write_bytes(text.encode(encoding))
            try:
                result = scan(fresh)
            except Undecodable as error:
                failures.append(f"{name}: not decoded: {error}")
                continue
            if not any(r[0] == relative and r[1] == 1 for r in result):
                failures.append(f"{name}: planted word not reported, got {result}")
        # A clean UTF-16 file raises no finding.
        fresh = Path(cases) / "enc_clean"
        shutil.copytree(root, fresh)
        write(fresh, relative, '"k" = "Capture";\n', "utf-16")
        if scan(fresh):
            failures.append(f"clean utf-16 reported: {scan(fresh)}")
        # Fail closed: a scoped text file that is neither UTF-8 nor UTF-16 stops the guard.
        fresh = Path(cases) / "enc_undecodable"
        shutil.copytree(root, fresh)
        (fresh / relative).parent.mkdir(parents=True, exist_ok=True)
        (fresh / relative).write_bytes(b'"k" = "caf\xe9 ADHD";\n')  # Latin-1
        try:
            scan(fresh)
            failures.append("undecodable file was skipped instead of failing closed")
        except Undecodable:
            pass
        # A binary property list is parsed, not skipped as a binary.
        fresh = Path(cases) / "enc_binary_plist"
        shutil.copytree(root, fresh)
        (fresh / "Apps/Demo/Extra").mkdir(parents=True, exist_ok=True)
        (fresh / "Apps/Demo/Extra/Info.plist").write_bytes(plistlib.dumps(
            {"CFBundleName": "Demo", "Nested": [{"NSMicrophoneUsageDescription": "Voice notes for ADHD"}]},
            fmt=plistlib.FMT_BINARY))
        if not any(r[0] == "Apps/Demo/Extra/Info.plist" for r in scan(fresh)):
            failures.append("binary plist: planted word not reported")
        (fresh / "Apps/Demo/Extra/Info.plist").write_bytes(plistlib.dumps({"CFBundleName": "Demo"}, fmt=plistlib.FMT_BINARY))
        if scan(fresh):
            failures.append(f"clean binary plist reported: {scan(fresh)}")
        (fresh / "Apps/Demo/Extra/Info.plist").write_bytes(b"bplist00\x00broken")
        try:
            scan(fresh)
            failures.append("corrupt binary plist was skipped instead of failing closed")
        except Undecodable:
            pass
        # project.yml: undecodable text fails closed, UTF-16 is read.
        fresh = Path(cases) / "enc_project_yml"
        shutil.copytree(root, fresh)
        (fresh / "project.yml").write_bytes(b"settings:\n  INFOPLIST_KEY_NSMicrophoneUsageDescription: caf\xe9 ADHD\n")
        try:
            if not scan(fresh):
                failures.append("project.yml Latin-1: neither caught nor failed closed")
        except Undecodable:
            pass
        write(fresh, "project.yml", "settings:\n  INFOPLIST_KEY_NSMicrophoneUsageDescription: ADHD voice\n", "utf-16")
        if not any(r[0] == "project.yml" and r[1] == 2 for r in scan(fresh)):
            failures.append("project.yml UTF-16: planted word not reported")
        # A real image in scope is still skipped.
        fresh = Path(cases) / "enc_binary"
        shutil.copytree(root, fresh)
        (fresh / "website").mkdir(exist_ok=True)
        (fresh / "website/logo.png").write_bytes(b"\x89PNG\r\n\x1a\n\0\0\xff\xfe ADHD")
        try:
            if scan(fresh):
                failures.append("binary image reported")
        except Undecodable as error:
            failures.append(f"binary image failed the guard: {error}")
    if failures:
        for failure in failures:
            print("self-test: " + failure, file=sys.stderr)
        return 1
    print("copy-guard self-test ok")
    return 0


def main(argv):
    if "--self-test" in argv:
        return self_test()
    try:
        findings = scan(ROOT)
    except Undecodable as error:
        print(f"copy-guard: {error}", file=sys.stderr)
        return 2
    if findings:
        report(findings)
        print("copy-guard: reword the text above; the guard stays.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
