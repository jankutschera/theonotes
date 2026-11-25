#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

"""Finds the old working-title name in tracked files and compares it with a ledger of allowed exceptions.

Run it with `python3 -I scripts/name-guard.py --check`. Python standard library only.

What counts as a hit: every match of the pattern `(?i)b(ae|a-umlaut|a)rchen` in the content of a tracked
file (git ls-files; a directory walk when --root is not a git work tree), and in every file and
directory name. For each hit the guard takes the surrounding "token": the longest run of word
characters, `.`, `-` and `:` around the match, with leading `-`/`:` and trailing `.`/`-`/`:` cut off.
Example: in `Foo.Name.x` the token is the whole dotted run; a sentence-final dot is not part of it.

Ledger (scripts/name-guard.json): `{"entries": [{"path": GLOB, "match": TOKEN, "reason": STR, "until": STR}]}`.
A hit is allowed when some entry has a glob that matches the file path and a `match` that is exactly
the hit's token. A glob uses `*` for "anything except /", `**` for "anything including /", `?` for one
character other than /. `until` names the task that removes the entry (A1..A8, B1..B8) or `never`.
The guard's own files (this script, its ledger, its test) are not scanned: they must spell the name.

Options:
  --check                 exit 0 when every hit is covered; prints `path:line rule` lines otherwise
  --baseline              rewrite the ledger from the current hits (one entry per token and place)
  --root DIR              scan DIR instead of the repository this script lives in
  --ledger FILE           use FILE as the ledger (default scripts/name-guard.json under --root)
  --phase TASK            reject every entry whose `until` is TASK or earlier (`never` never expires);
                          `--phase B8` therefore rejects everything except `never`
  --strict                also fail on ledger entries that cover no hit any more (the ledger must shrink)
"""

import argparse
import json
import os
import re
import subprocess
import sys
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LEDGER_REL = "scripts/name-guard.json"

PATTERN = re.compile("(?i)b(ae|ä|a)rchen")
TOKEN = re.compile(r"[\w.\-:]*(?i:b(?:ae|ä|a)rchen)[\w.\-:]*")

# Tasks in the order they land. `never` outlives all of them.
PHASE_ORDER = ["A1", "A2", "A3", "A4", "A5", "A6", "A7", "A8", "B1", "B2", "B3", "B4", "B5", "B6", "B7", "B8"]
VALID_UNTIL = set(PHASE_ORDER) | {"never"}

SELF_FILES = {"scripts/name-guard.py", "scripts/name-guard.json", "scripts/tests/test_name_guard.py",
              "scripts/rename/stage2-rename.py", "scripts/tests/test_stage2_rename.py",
              "docs/release/evidence/a3-dry-run.txt"}
# Outside a git work tree (an export copy) generated output is skipped the way .gitignore skips it in a clone.
WALK_SKIP_DIRS = {".git", "node_modules", ".build", "build", "DerivedData", ".swiftpm"}
BINARY_SNIFF_BYTES = 8192

# The 12 frozen crypto/protocol labels (plan "Global Constraints"). Opaque byte strings; never renamed.
FROZEN_LABELS = [
    "baerchen-envelope-v1", "baerchen-journal-v1", "baerchen-sync:1", "baerchen-account:1",
    "baerchen-transfer:1", "baerchen-transfer-key:1", "baerchen-transfer-words:1",
    "baerchen-device-name:1", "baerchen-conflict:1", "baerchen-request:1", "baerchen-recovery:1",
    "baerchen-semantic-id:1",
]


# ---------------------------------------------------------------- hits

def normalise(text):
    return unicodedata.normalize("NFC", text)


def clean_token(raw):
    # `${VAR:-default}` in shell scripts: the default is not part of the name.
    return raw.split(":-")[0].lstrip("-:").rstrip(".-:")


def tokens_in(text):
    """Yield the clean token of every hit in `text`."""
    for match in TOKEN.finditer(normalise(text)):
        token = clean_token(match.group())
        if PATTERN.search(token):
            yield token


def list_files(root):
    """Relative POSIX paths of the files to scan: tracked files, or a walk outside a work tree."""
    root = Path(root)
    try:
        top = subprocess.run(["git", "-C", str(root), "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, check=True).stdout.strip()
        if Path(top).resolve() == root.resolve():
            out = subprocess.run(["git", "-C", str(root), "ls-files", "-z"],
                                 capture_output=True, check=True).stdout.decode("utf-8", "replace")
            return sorted(p for p in out.split("\0") if p)
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass
    found = []
    for base, dirs, files in os.walk(root):
        dirs[:] = sorted(d for d in dirs if d not in WALK_SKIP_DIRS and not d.endswith(".xcodeproj"))
        for name in files:
            found.append((Path(base) / name).relative_to(root).as_posix())
    return sorted(found)


def collect_hits(root, files, skip=()):
    """[(path, line number, token, kind, line text)]; kind is "name" (file or directory name) or "text" (content)."""
    root = Path(root)
    hits = []
    for rel in files:
        if rel in skip:
            continue
        for component in normalise(rel).split("/"):
            for token in tokens_in(component):
                hits.append((rel, 0, token, "name", None))
        full = root / rel
        if full.is_symlink() or not full.is_file():
            continue
        try:
            data = full.read_bytes()
        except OSError:
            continue
        if b"\0" in data[:BINARY_SNIFF_BYTES]:
            continue
        for number, line in enumerate(data.decode("utf-8", "replace").split("\n"), 1):
            if len(line) < 6:
                continue
            for token in tokens_in(line):
                hits.append((rel, number, token, "text", line))
    return hits


# ---------------------------------------------------------------- ledger

def glob_to_regex(glob):
    out = []
    i = 0
    while i < len(glob):
        c = glob[i]
        if c == "*":
            if glob[i:i + 2] == "**":
                out.append(".*")
                i += 2
                continue
            out.append("[^/]*")
        elif c == "?":
            out.append("[^/]")
        else:
            out.append(re.escape(c))
        i += 1
    return re.compile("".join(out) + r"\Z")


class LedgerError(Exception):
    pass


def load_ledger(path):
    path = Path(path)
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise LedgerError("cannot read ledger %s: %s" % (path, error))
    try:
        data = json.loads(text)
    except ValueError as error:
        raise LedgerError("ledger %s is not valid JSON: %s" % (path, error))
    entries = data.get("entries") if isinstance(data, dict) else None
    if not isinstance(entries, list):
        raise LedgerError("ledger %s has no `entries` list" % path)
    # One entry per line in the file: the i-th line that starts an entry belongs to the i-th entry.
    entry_lines = [n for n, line in enumerate(text.split("\n"), 1) if line.lstrip().startswith('{"path"')]
    result = []
    for index, entry in enumerate(entries):
        line = entry_lines[index] if len(entry_lines) == len(entries) else 1
        if not isinstance(entry, dict) or set(entry) != {"path", "match", "reason", "until"}:
            raise LedgerError("ledger line %d: an entry needs exactly path, match, reason, until" % line)
        if not all(isinstance(entry[k], str) and entry[k] for k in entry):
            raise LedgerError("ledger line %d: path, match, reason and until must be non-empty strings" % line)
        if entry["until"] not in VALID_UNTIL:
            raise LedgerError("ledger line %d: until %r is not one of %s or never" % (line, entry["until"], PHASE_ORDER[0] + ".." + PHASE_ORDER[-1]))
        if not PATTERN.search(entry["match"]):
            raise LedgerError("ledger line %d: match %r does not contain the old name" % (line, entry["match"]))
        result.append({**entry, "line": line, "regex": glob_to_regex(entry["path"]), "match": normalise(entry["match"])})
    return result


def expired(entry, phase):
    if phase is None or entry["until"] == "never":
        return False
    return PHASE_ORDER.index(entry["until"]) <= PHASE_ORDER.index(phase)


# ---------------------------------------------------------------- check

def run_check(root, ledger_path, phase, strict):
    ledger_rel = os.path.relpath(ledger_path, root).replace(os.sep, "/")
    entries = load_ledger(ledger_path)
    by_token = {}
    for entry in entries:
        by_token.setdefault(entry["match"], []).append(entry)
    files = list_files(root)
    hits = collect_hits(root, files, skip=SELF_FILES | {ledger_rel})

    problems = []
    used = set()
    for path, line, token, kind, _ in hits:
        cover = [e for e in by_token.get(token, []) if e["regex"].match(path)]
        if not cover:
            rule = "unlisted-name" if kind == "name" else "unlisted-match"
            problems.append((path, line, "%s:%s" % (rule, token)))
        for e in cover:
            used.add(id(e))
    for entry in entries:
        if expired(entry, phase):
            problems.append((ledger_rel, entry["line"], "expired-entry:until-%s" % entry["until"]))
        elif strict and id(entry) not in used:
            problems.append((ledger_rel, entry["line"], "unused-entry:%s" % entry["match"]))
    # name hits share a path with many text hits; keep the output stable and free of duplicates
    seen = set()
    unique = []
    for problem in problems:
        if problem not in seen:
            seen.add(problem)
            unique.append(problem)
    return unique, len(hits), len(entries)


# ---------------------------------------------------------------- baseline classification

PROSE_SUFFIXES = (".md", ".markdown")
PROSE_DIRS = ("docs/", "website/")
# Files whose Stage 1 product-name workaround goes away with PRODUCT_NAME (task A5).
A5_FILES = {
    "project.yml", "scripts/install-dev.sh", "scripts/run.sh", "scripts/build.sh", "scripts/stop-app.sh",
    "scripts/test-install-dev.sh", "scripts/check-identities.sh", "scripts/gen-acknowledgements.py",
    "scripts/tests/test_check_identities.sh", "scripts/tests/test_gen_acknowledgements.py",
}

URL_SCHEME_CONTEXT = re.compile(r"""baerchen://|"baerchen"|<string>baerchen</string>|'baerchen'""", re.I)

REASONS = {
    "never": "frozen crypto/protocol label: opaque bytes, never renamed (plan Global Constraints, REN2-R2)",
    "B8-bundle": "persisted identifier: production bundle id, Keychain service, App Group or UTType (changes in the B7 cutover)",
    "B8-data": "persisted data name: library folder, database file, backup extension or migration backup (B2 migrator, removed in B8)",
    "B8-scheme": "persisted URL scheme: copied baerchen:// links keep working until B8 (REN2-R3)",
    "B8-theme": "persisted theme id: stored in user settings, mapped by the legacy migrator (B2)",
    "B8-worker": "deployed Worker name and request headers: switch together in B4/B7",
    "B8-intent": "App Intent / Shortcuts identifier that users' shortcuts refer to by name",
    "B8-env": "environment variable kept until B8 so the old library folder is still refused (REN-R4/R14)",
    "A4-bridge": "internal protocol name: editor bridge, asset scheme or pasteboard type (renamed on both sides in A4)",
    "A4-env": "tooling environment variable BAERCHEN_* (renamed to THEONOTES_* in A4)",
    "A4-label": "internal queue, thread or log label (A4)",
    "A4-dev": "dev identity bundle id or URL scheme (moves in A4; the dev identity holds no user data)",
    "A4-temp": "temp-file, temp-directory or tooling prefix (A4)",
    "A5-product": "Stage 1 product-name workaround: app bundle and executable name until PRODUCT_NAME changes (A5)",
    "A3-code": "module, target, directory, file or type name (scripted rename in A3)",
    "A3-prose": "working-title wording in code or UI strings (becomes Theo Notes in A3)",
    "A7-docs": "documentation, script or repo-file wording (rewritten in A7)",
}


def classify(path, token, line):
    """(until, reason key) for one hit. `line` is None for file and directory names."""
    low = token.lower()
    if any(low == lab or low.startswith(lab + ":") for lab in FROZEN_LABELS):
        return "never", "never"

    bundle_root = re.match(r"(?:[A-Z0-9]{10}\.|provisioningProfiles:|\.)?com\.truebrewbirdie\.baerchen(\.[\w.\-]*)?$", token)
    if bundle_root:
        suffix = bundle_root.group(1) or ""
        if suffix == ".dev" or suffix.startswith(".dev.") or suffix == ".devious":
            return "A4", "A4-dev"
        if re.match(r"\.(socket|off-pool|dns|db-changed)", suffix):
            return "A4", "A4-label"
        return "B8", "B8-bundle"
    if low in ("baerchen.note-vault", "baerchen.sync", "baerchen.dev"):
        return "B8", "B8-bundle"
    if token in ("baerchen.pipe-drain",):
        return "A4", "A4-label"
    if re.search(r"(?i)baerchen\.sqlite|^Baerchen\.(pre|stray)|BaerchenMigrationBackups|^Baerchen-Recovery$|\.baerchen-backup$|^baerchen-backup$", token):
        return "B8", "B8-data"
    if token == "BAERCHEN_DATA_DIR" or "BaerchenDataDir" in token:
        return "B8", "B8-env"
    if token.startswith("X-Baerchen"):
        return "B8", "B8-worker"
    if low.startswith("baerchen-sync.") or token == "baerchen-sync":
        return "B8", "B8-worker"
    if re.fullmatch(r"baerchen-(red|dark)|baerchen(Red|Dark)|theme-baerchen-(red|dark)\.json", token):
        return "B8", "B8-theme"
    if token in ("SaveToBaerchen", "OpenBaerchenShortcut"):
        return "B8", "B8-intent"
    if token in ("baerchenNoteIDs", ".baerchenNoteIDs", "baerchenTagPath", ".baerchenTagPath", "baerchenLocked"):
        return "B8", "B8-bundle"
    if token == "baerchen" and line is not None and URL_SCHEME_CONTEXT.search(line):
        return "B8", "B8-scheme"
    if low == "baerchen-dev":
        return "A4", "A4-dev"

    shipped_markdown = path.startswith(("Packages/", "Apps/")) and "/Resources/" in path
    prose_file = (path.endswith(PROSE_SUFFIXES) and not shipped_markdown) or path.startswith(PROSE_DIRS)
    if prose_file:
        return "A7", "A7-docs"

    if re.search(r"__baerchen|baerchenExport|baerchen-asset|x-baerchen-attachments", token, re.I):
        return "A4", "A4-bridge"
    if re.search(r"(^|\.)(TEST_RUNNER_)?BAERCHEN_", token):
        return "A4", "A4-env"
    if token in ("Baerchen.app", "BaerchenDev.app", "Bärchen.app"):
        return "A5", "A5-product"
    if path in A5_FILES and token in ("Baerchen", "Bärchen", "baerchen"):
        return "A5", "A5-product"
    if path.startswith("scripts/") and not re.match(r"\.?Baerchen[A-Z.]", token) and token not in ("Baerchen", "BaerchenCore"):
        return "A7", "A7-docs"
    if re.match(r"\.?baerchen[-.\w]*$", token) and token != "baerchen":
        return "A4", "A4-temp"
    if token in ("Baerchen", "Bärchen", "baerchen", "BAERCHEN", "Bärchen-only", "Bärchen-own", "barchen", "Barchen"):
        return "A3", "A3-prose"
    if re.match(r"\.?[A-Za-z_]*[Bb]aerchen", token) or low.startswith("baerchen"):
        return "A3", "A3-code"
    return "A3", "A3-prose"


LIFE = {"never": 100}
for _i, _p in enumerate(PHASE_ORDER):
    LIFE[_p] = _i


def merge_until(a, b):
    return a if LIFE[a[0]] >= LIFE[b[0]] else b


def covering_glob(paths):
    """A glob that covers all `paths` (one place), else None."""
    paths = sorted(set(paths))
    if len(paths) == 1:
        return paths[0]
    dirs = [p.rsplit("/", 1)[0] if "/" in p else "" for p in paths]
    common = os.path.commonpath(dirs) if all(dirs) else ""
    if not common:
        return None
    if all(d == common for d in dirs):
        return common + "/*"
    return common + "/**"


def area_key(path):
    parts = path.split("/")
    if len(parts) == 1:
        return ""
    return "/".join(parts[:min(2, len(parts) - 1)])


def build_baseline(hits):
    # (path, token) -> longest-lived classification over all hits of that token in that file
    per_file = {}
    for path, _, token, _, text in hits:
        decision = classify(path, token, text)
        key = (path, token)
        per_file[key] = merge_until(per_file[key], decision) if key in per_file else decision

    by_token = {}
    for (path, token), decision in per_file.items():
        by_token.setdefault(token, {}).setdefault(decision, set()).add(path)

    entries = []
    for token, groups in by_token.items():
        all_paths = {p: d for d, ps in groups.items() for p in ps}
        for (until, key), paths in groups.items():
            partitions = {}
            for path in paths:
                partitions.setdefault(area_key(path), []).append(path)
            for part in partitions.values():
                glob = covering_glob(part)
                regex = glob_to_regex(glob) if glob else None
                clash = regex and any(regex.match(p) and all_paths[p] != (until, key) for p in all_paths)
                targets = [glob] if glob and not clash else sorted(part)
                for target in targets:
                    entries.append({"path": target, "match": token, "reason": REASONS[key], "until": until})
    entries.sort(key=lambda e: (-LIFE[e["until"]], e["path"], e["match"]))
    return entries


def write_ledger(path, entries):
    lines = ['{', ' "about": "Allowed uses of the old working-title name. Maintained by `python3 -I scripts/name-guard.py --baseline`, then reviewed by hand. Read the header of scripts/name-guard.py for the matching rules.",',
             ' "entries": [']
    for index, entry in enumerate(entries):
        comma = "," if index < len(entries) - 1 else ""
        lines.append("  " + json.dumps(entry, ensure_ascii=False) + comma)
    lines += [" ]", "}"]
    Path(path).write_text("\n".join(lines) + "\n", encoding="utf-8")


# ---------------------------------------------------------------- main

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--baseline", action="store_true")
    parser.add_argument("--root", default=str(ROOT))
    parser.add_argument("--ledger")
    parser.add_argument("--phase", choices=PHASE_ORDER)
    parser.add_argument("--strict", action="store_true")
    args = parser.parse_args(argv)

    root = Path(args.root).resolve()
    ledger = Path(args.ledger).resolve() if args.ledger else root / LEDGER_REL
    ledger_rel = os.path.relpath(ledger, root).replace(os.sep, "/")

    if args.baseline:
        hits = collect_hits(root, list_files(root), skip=SELF_FILES | {ledger_rel})
        entries = build_baseline(hits)
        write_ledger(ledger, entries)
        counts = {}
        for entry in entries:
            counts[entry["until"]] = counts.get(entry["until"], 0) + 1
        print("name-guard: wrote %s (%d entries for %d hits: %s)" % (
            ledger_rel, len(entries), len(hits), ", ".join("%s %d" % (k, counts[k]) for k in sorted(counts, key=lambda k: -LIFE[k]))))
        return 0

    try:
        problems, hit_count, entry_count = run_check(root, ledger, args.phase, args.strict)
    except LedgerError as error:
        print("name-guard: %s" % error, file=sys.stderr)
        return 2
    for path, line, rule in problems:
        print("%s:%d %s" % (path, line, rule))
    if problems:
        print("name-guard: %d problem(s); %d hits checked against %d ledger entries" % (len(problems), hit_count, entry_count), file=sys.stderr)
        return 1
    print("name-guard: ok (%d hits, all covered by %d ledger entries)" % (hit_count, entry_count))
    return 0


if __name__ == "__main__":
    sys.exit(main())
