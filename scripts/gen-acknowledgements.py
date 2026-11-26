#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

"""Builds Apps/TheoNotesMac/Resources/Acknowledgements.json from what actually ships.

Run it with `python3 -I scripts/gen-acknowledgements.py`; `--check` fails when the committed file
is stale (scripts/test-all.sh runs it). Python standard library only.

Sources, in the order they appear in the output:

1. npm packages in the editor bundle. The list comes from the source maps of a Vite production
   build (`pnpm build --sourcemap`), i.e. from the bundle's real module graph: a package shows up
   only if one of its files was compiled into a chunk. `pnpm licenses list --prod` would also list
   packages the bundle never reaches (the audit counted 183 against about 100 that ship) and
   would drop the exact chunk evidence. Licence data is read from the package directories.
2. SwiftPM dependencies from Packages/TheoNotesCore/Package.resolved; the licence text comes from
   the checked-out package (`swift package resolve` or an Xcode build creates the checkout).
3. Bundled assets: the colour palettes (theme-*.json carry project, licence and copyright) and the
   word list / emoji data listed in scripts/acknowledgements-config.json.

`--check` also audits the BUILT app (default build/DerivedData/Build/Products/Debug/Theo Notes Dev.app,
or --app-bundle): the editor in its Resources must be byte-identical to the editor this script
builds with source maps (scripts/build-editor.sh builds with maps too and leaves them out of the
app), and every other file in Contents/Resources must be accounted for by a listed entry or by the
`bundle` section of the config; anything else fails the run with a list. Outside Resources only
the main executable and the `bundle.code` lines of the config are accepted (no stray framework,
helper or plug-in).

Licence texts are stored once per distinct text. For the short permissive licences (MIT, ISC,
BSD, 0BSD) the first copyright block is cut out of the text and stored per entry, so all texts that
differ only in the copyright line share one body; the app puts the block back where the
`{{copyright}}` placeholder sits.

Anything with an unknown or denied (GPL, LGPL, AGPL, SSPL, ...) licence, a missing licence text
or a licence file that contradicts the declared licence makes the script fail with a list.

GPL gate (L1, amended): the project is GPL-3.0-only, so every licence that ships also goes
through `gplCompatible(spdx)`. MIT, ISC, BSD, 0BSD, Zlib, Unlicense, CC0-1.0, BlueOak-1.0.0,
Unicode-3.0 and Apache-2.0 pass. OFL-1.1 (font data) and MPL-2.0 pass only with a ruling id in the
config; EPL-2.0 needs a ruling id and a filled-in Secondary-License notice (EPL-2.0 Exhibit A) that
names the GPL version 3 or later in the package, or the package has to go (elkjs).
Everything else (GPL-2.0-only, LGPL, AGPL, SSPL, CC-BY-SA, CC-BY-NC, unknown) fails.
See docs/legal/licence-compatibility.md.
"""

import argparse
import collections
import fnmatch
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SCHEMA_VERSION = 1
PLACEHOLDER = "{{copyright}}"

OUTPUT_REL = "Apps/TheoNotesMac/Resources/Acknowledgements.json"
CONFIG_REL = "scripts/acknowledgements-config.json"
EDITOR_REL = "web/editor"
RESOLVED_REL = "Packages/TheoNotesCore/Package.resolved"
DEFAULT_APP_REL = "build/DerivedData/Build/Products/Debug/Theo Notes Dev.app"

# Preference order when a package offers a choice ("A OR B"): permissive first, weak copyleft last.
PERMISSIVE = [
    "MIT", "ISC", "BSD-2-Clause", "BSD-3-Clause", "Apache-2.0", "0BSD", "Zlib",
    "Unlicense", "CC0-1.0", "BlueOak-1.0.0", "Unicode-3.0",
    "OFL-1.1",  # fonts only: the maths font data and the licence it passes on
]
# File-level copyleft: allowed, recorded in docs/decisions.md, and shown with a source statement.
WEAK_COPYLEFT = ["EPL-2.0", "MPL-2.0"]
DENIED_PREFIXES = (
    "GPL", "LGPL", "AGPL", "SSPL", "CC-BY-SA", "CC-BY-NC", "EUPL", "OSL", "CPAL", "RPL", "Sleepycat",
)
# Licences whose body starts with a copyright block that can be stored per entry.
TEMPLATED = {"MIT", "ISC", "BSD-2-Clause", "BSD-3-Clause", "0BSD"}

LICENCE_FILE = re.compile(r"(?i)^(licen[sc]e|copying|unlicense)([-._ ].*)?$")
NOTICE_FILE = re.compile(r"(?i)^notice([-._ ].*)?$")
TEXT_SUFFIXES = {"", ".md", ".txt", ".markdown"}
COPYRIGHT_LINE = re.compile(r"(?i)^\s*(copyright|\(c\))\s*(\(c\)|©|\d|by\b)")
PNPM_PATH = re.compile(r"node_modules/\.pnpm/[^/]+/node_modules/((?:@[^/]+/)?[^/]+)/")
# A chunk without a source map is accepted only when it is a re-export stub this small.
MAX_UNMAPPED_CHUNK_BYTES = 2048


class Problems(Exception):
    def __init__(self, problems):
        super().__init__("\n".join(problems))
        self.problems = problems


# ---------------------------------------------------------------- text helpers

def normalise(text):
    text = text.replace("﻿", "").replace("\r\n", "\n").replace("\r", "\n")
    return "\n".join(line.rstrip() for line in text.split("\n")).strip("\n")


def read_text(path):
    return normalise(Path(path).read_text(encoding="utf-8", errors="replace"))


def text_id(body):
    return hashlib.sha256(body.encode("utf-8")).hexdigest()[:16]


def text_id_full(text):
    """The full sha256 of a normalised licence text, as an `unrecognisedText` exception names it."""
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def split_copyright(text, spdx):
    """Returns (body with placeholder, copyright block) or (text, None) when nothing is cut out."""
    if spdx not in TEMPLATED:
        return text, None
    lines = text.split("\n")
    for start, line in enumerate(lines):
        if COPYRIGHT_LINE.match(line):
            end = start
            while end + 1 < len(lines) and COPYRIGHT_LINE.match(lines[end + 1]):
                end += 1
            block = "\n".join(lines[start:end + 1])
            body = "\n".join(lines[:start] + [PLACEHOLDER] + lines[end + 1:])
            return body, block
    return text, None


def detect_all(text):
    """Licences the text reads as, in order of appearance (a file may carry several)."""
    t = re.sub(r"\s+", " ", text.lower())
    markers = [
        ("AGPL-3.0", ["gnu affero general public license"]),
        ("LGPL-3.0", ["gnu lesser general public license"]),
        ("GPL-3.0", ["gnu general public license"]),
        ("SSPL-1.0", ["server side public license"]),
        ("EPL-2.0", ["eclipse public license - v 2.0", "eclipse public license, version 2.0"]),
        ("MPL-2.0", ["mozilla public license version 2.0"]),
        ("Apache-2.0", ["apache license version 2.0", "apache license, version 2.0"]),
        ("Unicode-3.0", ["unicode license v3"]),
        ("OFL-1.1", ["sil open font license, version 1.1", "sil open font license version 1.1"]),
        ("BlueOak-1.0.0", ["blue oak model license"]),
        ("Unlicense", ["this is free and unencumbered software released into the public domain"]),
        ("MIT", ["permission is hereby granted, free of charge"]),
        ("BSD", ["redistribution and use in source and binary forms"]),
        ("ISC", ["permission to use, copy, modify, and/or distribute this software for any purpose"]),
        ("Zlib", ["this software is provided 'as-is'"]),
    ]
    found = []
    for spdx, phrases in markers:
        positions = [t.find(p) for p in phrases if p in t]
        if not positions:
            continue
        if spdx == "BSD":
            spdx = "BSD-3-Clause" if "neither the name" in t else "BSD-2-Clause"
        elif spdx == "ISC":
            spdx = "ISC" if "provided that the above copyright notice" in t else "0BSD"
        found.append((min(positions), spdx))
    found.sort()
    result = []
    for _, spdx in found:
        if spdx not in result:
            result.append(spdx)
    return result


def detect_spdx(text):
    """The licence the text starts with; None when nothing matches."""
    found = detect_all(text)
    return found[0] if found else None


def classify(token):
    if token in PERMISSIVE:
        return "permissive"
    if token in WEAK_COPYLEFT:
        return "weak"
    if token.startswith(DENIED_PREFIXES):
        return "denied"
    return "unknown"


def family(spdx):
    """The family name used in reports and the decisions log."""
    if "AND" in spdx.split():
        return "multiple"
    kind = classify(spdx)
    return {"permissive": "permissive", "weak": "weak copyleft"}.get(kind, "other")


def elect(expression):
    """Picks the licence to ship from an SPDX expression. Returns (elected, problem)."""
    expr = re.sub(r"\s+", " ", re.sub(r"[()]", " ", expression)).strip()
    if " AND " in expr:
        parts = [p.strip() for p in expr.split(" AND ")]
        bad = [p for p in parts if classify(p) in ("denied", "unknown")]
        if bad:
            return None, "%s licence %s" % (classify(bad[0]), bad[0])
        return " AND ".join(parts), None
    options = [p.strip() for p in expr.split(" OR ")]
    ok = [p for p in options if classify(p) in ("permissive", "weak")]
    if not ok:
        kinds = ["denied" if classify(p) == "denied" else "unknown" for p in options]
        return None, "%s licence %s" % ("denied" if "denied" in kinds else "unknown", expression)
    return sorted(ok, key=lambda p: (PERMISSIVE + WEAK_COPYLEFT).index(p))[0], None


# ---------------------------------------------------------------- GPL-3.0 compatibility gate (L1)

Verdict = collections.namedtuple("Verdict", "status reason needs")
ALLOWED, CONDITIONAL, FAIL = "allowed", "conditional", "fail"
NEEDS_RULING = "ruling"
NEEDS_NOTICE = "secondary-licence-notice"
GPL3_COMPATIBLE = [
    "MIT", "ISC", "BSD-2-Clause", "BSD-3-Clause", "0BSD", "Zlib", "Unlicense", "CC0-1.0",
    "BlueOak-1.0.0", "Unicode-3.0", "Apache-2.0",
]
RULING_ID = re.compile(r"^[A-Z][A-Z0-9]*-R\d+$")
SECONDARY_SENTENCE = re.compile(
    r"may also be made available under the following secondary licenses[^:]*:\s*(.{0,300})", re.I | re.S)


def gplCompatible(spdx):
    """Can a component under `spdx` ship inside a GPL-3.0-only program? Returns a Verdict.

    status "allowed": yes. "conditional": only with what `needs` names (a ruling id in the config, and for
    EPL-2.0 a Secondary-License notice in the package). "fail": no. A single SPDX id, not an expression.
    """
    if spdx in GPL3_COMPATIBLE:
        reason = "compatible with GPLv3 only (never GPLv2), hence GPL-3.0-only" if spdx == "Apache-2.0" else "compatible with GPLv3"
        return Verdict(ALLOWED, reason, ())
    if spdx == "OFL-1.1":
        return Verdict(CONDITIONAL, "font data shipped as a separate file with its licence text; needs a ruling id", (NEEDS_RULING,))
    if spdx == "MPL-2.0":
        return Verdict(CONDITIONAL, "file-level copyleft; allowed as a secondary licence unless the files say otherwise; needs a ruling id", (NEEDS_RULING,))
    if spdx == "EPL-2.0":
        return Verdict(
            CONDITIONAL,
            "incompatible with the GPL unless the initial contributor attached the Secondary-License notice naming the GPL; needs a ruling id and that notice",
            (NEEDS_RULING, NEEDS_NOTICE))
    if spdx.startswith(("GPL-2.0", "LGPL", "AGPL", "SSPL", "CC-BY-SA", "CC-BY-NC")):
        return Verdict(FAIL, "not compatible with, or not allowed in, a GPL-3.0-only program", ())
    if classify(spdx) == "denied":
        return Verdict(FAIL, "denied by LIC-R6", ())
    return Verdict(FAIL, "unknown licence: no verdict, so it does not ship", ())


def secondary_gpl_notice(texts):
    """True when one of the texts holds a filled-in EPL-2.0 Exhibit A notice that names the GPL, version 3 or later.

    The unfilled template (`{name license(s), version(s), ...}`) and a notice naming only GPL-2.0 do not count.
    """
    for text in texts:
        for match in SECONDARY_SENTENCE.finditer(re.sub(r"\s+", " ", text)):
            sentence = match.group(1).split('"')[0]
            if "{" in sentence.split(".")[0] or not sentence.strip():
                continue
            low = sentence.lower()
            if "gnu general public license" not in low and "gpl" not in low:
                continue
            if re.search(r"(version|v\.?|gpl-?)\s*3|\b3\.0\b|or later|any later|or any later", low):
                return True
    return False


def gate_problems(label, elected, ruling, notice_texts):
    """Problems the GPL gate finds for an elected licence ("A AND B" is checked part by part)."""
    problems = []
    for part in elected.split(" AND "):
        verdict = gplCompatible(part)
        if verdict.status == FAIL:
            problems.append("%s: %s is not allowed in a GPL-3.0-only program (%s)" % (label, part, verdict.reason))
            continue
        if NEEDS_RULING in verdict.needs and not (isinstance(ruling, str) and RULING_ID.match(ruling)):
            problems.append("%s: %s needs a ruling id (config `ruling`, e.g. LIC-R34) before it can ship" % (label, part))
        if NEEDS_NOTICE in verdict.needs and not secondary_gpl_notice(notice_texts()):
            problems.append(
                "%s: %s without an EPL-2.0 Secondary-License notice naming the GPL (version 3 or later) in the package "
                "is incompatible with GPL-3.0-only; remove the package" % (label, part))
    return problems


# ---------------------------------------------------------------- npm (editor bundle)

def bundled_package_dirs(editor_dir, map_dir, problems):
    """(name, directory) of every package with a module in a chunk; one per installed version."""
    editor_dir = Path(editor_dir)
    map_dir = Path(map_dir)
    found = set()
    chunks = sorted(map_dir.rglob("*.js"))
    if not chunks:
        problems.append("no JavaScript chunks in %s (build the editor first)" % map_dir)
    for chunk in chunks:
        map_file = Path(str(chunk) + ".map")
        if not map_file.exists():
            if chunk.stat().st_size > MAX_UNMAPPED_CHUNK_BYTES:
                problems.append("chunk without a source map: %s" % chunk.name)
            continue
        for source in json.loads(map_file.read_text(encoding="utf-8")).get("sources", []):
            match = PNPM_PATH.search(source)
            if not match:
                continue
            relative = source[source.index("node_modules/.pnpm/"):match.end()]
            found.add((match.group(1), relative))
    return [(name, editor_dir / relative) for name, relative in sorted(found)]


def package_dir(editor_dir, name):
    return Path(editor_dir) / "node_modules" / name


def declared_licence(pkg):
    value = pkg.get("license")
    if isinstance(value, dict):
        value = value.get("type")
    if not value and isinstance(pkg.get("licenses"), list):
        types = [item.get("type") for item in pkg["licenses"] if isinstance(item, dict) and item.get("type")]
        value = " OR ".join(types) if types else None
    return value if isinstance(value, str) and value.strip() else None


def repository_url(pkg):
    repo = pkg.get("repository")
    url = repo.get("url") if isinstance(repo, dict) else repo
    if not isinstance(url, str):
        url = pkg.get("homepage") if isinstance(pkg.get("homepage"), str) else ""
    url = re.sub(r"^git\+", "", url)
    url = re.sub(r"^git://", "https://", url)
    url = re.sub(r"^ssh://git@", "https://", url)
    url = re.sub(r"^github:", "https://github.com/", url)
    if re.fullmatch(r"[\w.-]+/[\w.-]+", url):
        url = "https://github.com/" + url
    url = re.sub(r"\.git$", "", url)
    url = re.sub(r"#.*$", "", url)
    return url


def author_name(pkg):
    author = pkg.get("author")
    if isinstance(author, dict):
        author = author.get("name")
    if isinstance(author, str):
        author = re.sub(r"\s*[<(].*$", "", author).strip()
    return author or None


def licence_files(directory):
    names = []
    for entry in sorted(os.listdir(directory)):
        path = Path(directory) / entry
        if path.is_file() and LICENCE_FILE.match(entry) and path.suffix.lower() in TEXT_SUFFIXES:
            names.append(path)
    return names


def notice_files(directory):
    return [
        Path(directory) / entry for entry in sorted(os.listdir(directory))
        if (Path(directory) / entry).is_file() and NOTICE_FILE.match(entry)
        and Path(entry).suffix.lower() in TEXT_SUFFIXES
    ]


def pick_licence_text(files, elected):
    """The text of the licence file that matches the elected licence, else all files joined."""
    texts = [read_text(f) for f in files]
    if len(texts) == 1:
        return texts[0]
    matching = [t for t in texts if detect_spdx(t) == elected]
    if len(matching) == 1:
        return matching[0]
    return "\n\n----\n\n".join(texts)


def cut_slice(text, spec):
    start = text.find(spec["from"])
    end = text.find(spec["to"], start + 1) if start >= 0 else -1
    if start < 0 or end < 0:
        return None
    return text[start:end + len(spec["to"])]


def npm_entry(name, directory, editor_dir, override, extra, problems):
    directory = Path(directory)
    if not (directory / "package.json").exists():
        problems.append("%s: no package.json at %s" % (name, directory))
        return None
    pkg = json.loads((directory / "package.json").read_text(encoding="utf-8"))
    version = pkg.get("version", "")
    label = "%s@%s" % (name, version)

    expression = override.get("licence") or declared_licence(pkg)
    files = licence_files(directory)
    if not expression and files:
        expression = detect_spdx(pick_licence_text(files, None))
    if not expression:
        problems.append("%s: no licence declared and none recognised in its files" % label)
        return None
    elected, bad = elect(expression)
    if elected is None:
        problems.append("%s: %s" % (label, bad))
        return None

    # Licence text.
    if override.get("textFromPackage"):
        source_dir = package_dir(editor_dir, override["textFromPackage"])
        files = licence_files(source_dir) if source_dir.exists() else []
        if not files:
            problems.append("%s: textFromPackage %s has no licence file" % (label, override["textFromPackage"]))
            return None
    if not files:
        problems.append("%s: no licence file in the package" % label)
        return None
    text = pick_licence_text(files, elected)
    if extra and extra.get("textSlice"):
        text = cut_slice(text, extra["textSlice"])
        if text is None:
            problems.append("%s: textSlice markers not found in its licence file" % label)
            return None

    detected = detect_spdx(text)
    reads_as = detect_all(text)
    needed = set(elected.split(" AND "))
    if not reads_as:
        accepted = override.get("unrecognisedText")
        actual = text_id_full(text)
        if not (isinstance(accepted, dict) and accepted.get("ruling") and accepted.get("sha256") == actual):
            problems.append(
                "%s: licence text is not recognised as %s (declared %s); a custom text needs "
                "`unrecognisedText: {sha256, ruling}` in npmOverrides naming exactly this text "
                "(sha256 of the normalised text: %s)" % (label, elected, expression, actual))
            return None
    elif not needed <= set(reads_as):
        problems.append("%s: declares %s but its licence file reads as %s" % (label, expression, ", ".join(reads_as)))
        return None
    if classify(detected or elected) == "denied":
        problems.append("%s: denied licence %s" % (label, detected))
        return None

    def notice_texts():
        readmes = [Path(directory) / n for n in sorted(os.listdir(directory)) if n.lower().startswith("readme")]
        return [read_text(f) for f in files + notice_files(directory) + readmes if Path(f).is_file()]

    gate = gate_problems(label, elected, override.get("ruling"), notice_texts)
    if gate:
        problems.extend(gate)
        return None

    # Copyright.
    copyright_line = override.get("copyright")
    if not copyright_line:
        for candidate in text.split("\n"):
            if COPYRIGHT_LINE.match(candidate):
                copyright_line = candidate.strip()
                break
    if not copyright_line:
        author = author_name(pkg)
        copyright_line = "Copyright (c) %s" % author if author else "Copyright held by the authors of %s" % name

    notice = None
    notes = [n for n in (override.get("note"), (extra or {}).get("note")) if n]
    found_notices = notice_files(directory)
    if found_notices:
        notice = "\n\n----\n\n".join(read_text(f) for f in found_notices)

    source_url = override.get("sourceUrl")
    source_statement = override.get("sourceStatement")
    weak = classify(elected) == "weak"
    if (source_url or source_statement) and not weak:
        problems.append("%s: sourceUrl and sourceStatement are for weak-copyleft packages only" % label)
        return None
    if weak:
        if not (source_url and source_statement):
            problems.append("%s: weak copyleft needs npmOverrides sourceUrl and sourceStatement" % label)
            return None
        if not source_url.startswith("https://"):
            problems.append("%s: sourceUrl must be an https link" % label)
            return None
        if version not in source_url:
            problems.append("%s: sourceUrl must point at this exact version (%s), not at a branch" % (label, version))
            return None

    entry = {
        "name": name,
        "version": version,
        "kind": "npm",
        "licence": elected,
        "copyright": copyright_line,
        "source": repository_url(pkg),
        "usedIn": "Editor",
        "_text": text,
    }
    if expression != elected:
        entry["licenceExpression"] = expression
    if notice:
        entry["_notice"] = notice
    if weak:
        entry["sourceCode"] = source_url
        entry["note"] = " ".join(notes + [source_statement, "Source code of version %s: %s" % (version, source_url)])
    elif notes:
        entry["note"] = " ".join(notes)
    return entry


def collect_npm(root, editor_dir, map_dir, config, problems):
    bundled = bundled_package_dirs(editor_dir, map_dir, problems)
    names = {name for name, _ in bundled}
    overrides = config.get("npmOverrides", {})
    entries = []
    seen = set()
    for name, directory in bundled:
        entry = npm_entry(name, directory, editor_dir, overrides.get(name, {}), None, problems)
        if entry and (entry["name"], entry["version"]) not in seen:
            seen.add((entry["name"], entry["version"]))
            entries.append(entry)
    for extra in config.get("extraNpm", []):
        name = extra["name"]
        if name in names:
            continue
        directory = package_dir(editor_dir, name)
        entry = npm_entry(name, directory, editor_dir, overrides.get(name, {}), extra, problems)
        if entry:
            entries.append(entry)
    unused = sorted(set(overrides) - names - {e["name"] for e in config.get("extraNpm", [])})
    if unused:
        problems.append("npmOverrides for packages that are not in the bundle: %s" % ", ".join(unused))
    return entries


# ---------------------------------------------------------------- SwiftPM

def find_checkout(identity_names, checkout_dirs):
    for base in checkout_dirs:
        for name in identity_names:
            candidate = Path(base) / name
            if candidate.is_dir():
                return candidate
    return None


def checkout_revision(directory):
    head = Path(directory) / ".git" / "HEAD"
    try:
        value = head.read_text().strip()
    except OSError:
        return None
    return value if re.fullmatch(r"[0-9a-f]{40}", value) else None


def collect_swiftpm(root, resolved_path, checkout_dirs, problems):
    resolved = json.loads(Path(resolved_path).read_text(encoding="utf-8"))
    entries = []
    for pin in sorted(resolved.get("pins", []), key=lambda p: p["identity"]):
        location = pin["location"]
        state = pin.get("state", {})
        version = state.get("version") or state.get("branch") or state.get("revision", "")
        repo_name = re.sub(r"\.git$", "", location.rstrip("/").split("/")[-1])
        label = "%s@%s" % (repo_name, version)
        directory = find_checkout([repo_name, pin["identity"]], checkout_dirs)
        if directory is None:
            problems.append(
                "%s: no checkout found (looked in %s); run `swift package resolve --package-path "
                "Packages/TheoNotesCore`" % (label, ", ".join(str(d) for d in checkout_dirs)))
            continue
        revision = checkout_revision(directory)
        if revision and state.get("revision") and revision != state["revision"]:
            problems.append("%s: checkout at %s is not the pinned revision %s" % (label, revision[:10], state["revision"][:10]))
            continue
        files = licence_files(directory)
        if not files:
            problems.append("%s: no licence file in the checkout" % label)
            continue
        text = pick_licence_text(files, None)
        spdx = detect_spdx(text)
        if spdx is None or classify(spdx) in ("denied", "unknown"):
            problems.append("%s: licence not recognised or not allowed (%s)" % (label, spdx or "unknown"))
            continue
        gate = gate_problems(label, spdx, None, lambda: [text])
        if gate:
            problems.extend(gate)
            continue
        copyright_line = next((l.strip() for l in text.split("\n") if COPYRIGHT_LINE.match(l)), None)
        if not copyright_line:
            problems.append("%s: no copyright line in its licence file" % label)
            continue
        source = re.sub(r"\.git$", "", location)
        entry = {
            "name": repo_name, "version": version, "kind": "swiftpm", "licence": spdx,
            "copyright": copyright_line, "source": source, "usedIn": "App", "_text": text,
        }
        if classify(spdx) == "weak":
            entry["note"] = "Source code: %s (version %s)." % (source, version)
        entries.append(entry)
    return entries


# ---------------------------------------------------------------- assets

def collect_assets(root, config, problems):
    root = Path(root)
    entries = []
    referenced = set()

    theme_dir = root / config["themeDir"]
    own = config.get("themeOwnLicence")
    projects = {}
    for path in sorted(theme_dir.glob("theme-*.json")):
        data = json.loads(path.read_text(encoding="utf-8"))
        source = data.get("source") or {}
        project = source.get("project")
        if source.get("license") == own:
            continue
        if not project or not source.get("license"):
            problems.append("%s: theme has no source.project / source.license" % path.name)
            continue
        info = projects.setdefault(project, {"licences": set(), "copyrights": [], "urls": [], "themes": []})
        info["licences"].add(source["license"])
        if source.get("copyright") and source["copyright"] not in info["copyrights"]:
            info["copyrights"].append(source["copyright"])
        if source.get("url") and source["url"] not in info["urls"]:
            info["urls"].append(source["url"])
        info["themes"].append(data.get("name", data.get("id", path.stem)))
    files = config.get("themeLicenceFiles", {})
    for project, info in sorted(projects.items()):
        label = "theme palette %s" % project
        if project not in files:
            problems.append("%s: no entry in themeLicenceFiles (add its licence text file)" % label)
            continue
        referenced.add(files[project])
        path = theme_dir / files[project]
        if not path.exists():
            problems.append("%s: licence file %s is missing" % (label, files[project]))
            continue
        if len(info["licences"]) != 1:
            problems.append("%s: themes disagree on the licence: %s" % (label, sorted(info["licences"])))
            continue
        spdx = next(iter(info["licences"]))
        text = read_text(path)
        if classify(spdx) in ("denied", "unknown"):
            problems.append("%s: licence %s is %s" % (label, spdx, classify(spdx)))
            continue
        detected = detect_spdx(text)
        if detected != spdx:
            problems.append("%s: themes declare %s but the licence file reads as %s" % (label, spdx, detected))
            continue
        gate = gate_problems(label, spdx, None, lambda: [text])
        if gate:
            problems.extend(gate)
            continue
        entries.append({
            "name": "%s colour palette" % project, "version": "", "kind": "asset", "licence": spdx,
            "copyright": "; ".join(info["copyrights"]), "source": info["urls"][0] if info["urls"] else "",
            "usedIn": "Themes: %s" % ", ".join(sorted(info["themes"])), "_text": text,
        })

    for asset in config.get("assets", []):
        label = "asset %s" % asset["name"]
        path = root / asset["licenceFile"]
        referenced.add(Path(asset["licenceFile"]).name)
        if not path.exists():
            problems.append("%s: licence file %s is missing" % (label, asset["licenceFile"]))
            continue
        spdx = asset["licence"]
        text = read_text(path)
        if classify(spdx) in ("denied", "unknown"):
            problems.append("%s: licence %s is %s" % (label, spdx, classify(spdx)))
            continue
        detected = detect_spdx(text)
        if detected != spdx:
            problems.append("%s: declared %s but the licence file reads as %s" % (label, spdx, detected))
            continue
        gate = gate_problems(label, spdx, asset.get("ruling"), lambda: [text])
        if gate:
            problems.extend(gate)
            continue
        entry = {
            "name": asset["name"], "version": asset.get("version", ""), "kind": "asset", "licence": spdx,
            "copyright": asset["copyright"], "source": asset.get("source", ""), "usedIn": asset.get("usedIn", ""),
            "_text": text,
        }
        if asset.get("note"):
            entry["note"] = asset["note"]
        entries.append(entry)

    # A licence file next to the assets that nothing lists would silently miss the screen.
    for path in sorted(theme_dir.iterdir()):
        if re.search(r"(?i)licen[sc]e", path.name) and path.name not in referenced:
            problems.append("%s is not listed in %s (themeLicenceFiles or assets)" % (path.name, CONFIG_REL))
    return entries


# ---------------------------------------------------------------- the built app bundle

def matches_any(rel, patterns):
    return any(fnmatch.fnmatchcase(rel, pattern) for pattern in patterns)


def audit_bundle(resources, map_dir, entries, config, problems):
    """Every file in the built app's Resources must be accounted for, or the run fails.

    Accounted for means: an Editor file that is byte-identical to the audited build (a script is
    then covered by the module graph); a theme file whose own `source` names a listed palette or
    our own licence; a licence text or data file that a config line ties to a listed entry; or a
    file on the `bundle.ownWork` allowlist. The Editor's other files (CSS, fonts, pages) need a
    config line too, so nothing slips in with a dependency update.
    """
    resources = Path(resources)
    if not resources.is_dir():
        problems.append("no built app: %s does not exist (build the app first, or pass --app-bundle)" % resources)
        return
    names = {e["name"] for e in entries}
    settings = config.get("bundle", {})
    own = [item["pattern"] for item in settings.get("ownWork", [])]
    owners = settings.get("owners", [])
    for item in owners:
        if item["owner"] not in names:
            problems.append("bundle owner %s is not in the list (config pattern %s)" % (item["owner"], item["pattern"]))
    listed_patterns = own + [item["pattern"] for item in owners if item["owner"] in names]
    licence_names = {Path(f).name for f in config.get("themeLicenceFiles", {}).values()}
    licence_names |= {Path(a["licenceFile"]).name for a in config.get("assets", [])}
    own_licence = config.get("themeOwnLicence")

    unaccounted = []
    for path in sorted(resources.rglob("*")):
        if path.is_dir() and not path.is_symlink():
            continue
        rel = path.relative_to(resources).as_posix()
        # Signing metadata that codesign adds to a nested bundle (an ad hoc signed dev build).
        if "_CodeSignature" in path.relative_to(resources).parts:
            continue
        if rel.startswith("Editor/"):
            built = Path(map_dir) / rel[len("Editor/"):]
            if built.is_file() and path.read_bytes() != built.read_bytes():
                problems.append("shipped %s differs from the audited build (the app carries a stale or edited editor)" % rel)
            elif built.is_file() and rel.endswith(".js"):
                continue
            elif matches_any(rel, listed_patterns):
                continue
            else:
                unaccounted.append(rel)
            continue
        if path.name in licence_names or matches_any(rel, listed_patterns):
            continue
        if path.name.startswith("theme-") and path.suffix == ".json":
            try:
                source = json.loads(path.read_text(encoding="utf-8")).get("source") or {}
            except (OSError, ValueError):
                source = {}
            if source.get("license") == own_licence and own_licence:
                continue
            if "%s colour palette" % source.get("project") in names:
                continue
        unaccounted.append(rel)
    if unaccounted:
        problems.append(
            "%d shipped file(s) in the built app are not accounted for (list the package or asset in the "
            "config, or put them on bundle.ownWork with a reason):\n      %s" % (len(unaccounted), "\n      ".join(unaccounted)))


def audit_code(contents, config, problems):
    """Everything in the built app outside Resources (executables, helpers, plug-ins, frameworks).

    Only the app's own main executable (named by CFBundleExecutable) and files matching a
    `bundle.code` line of the config are accepted; a stray framework, helper or plug-in fails.
    """
    contents = Path(contents)
    if not contents.is_dir():
        problems.append("no built app: %s does not exist" % contents)
        return
    allowed = [item["pattern"] for item in config.get("bundle", {}).get("code", [])]
    executable = None
    try:
        info = plistlib.loads((contents / "Info.plist").read_bytes())
        if isinstance(info.get("CFBundleExecutable"), str):
            executable = "MacOS/" + info["CFBundleExecutable"]
    except (OSError, ValueError, plistlib.InvalidFileException):
        pass
    unaccounted = []
    for path in sorted(contents.rglob("*")):
        if path.is_dir() and not path.is_symlink():
            continue
        rel = path.relative_to(contents).as_posix()
        if rel.startswith("Resources/") or rel == executable or matches_any(rel, allowed):
            continue
        unaccounted.append(rel)
    if unaccounted:
        problems.append(
            "%d file(s) outside Resources in the built app are not accounted for (only the main executable "
            "and bundle.code lines are accepted):\n      %s" % (len(unaccounted), "\n      ".join(unaccounted)))


# ---------------------------------------------------------------- assembling

def assemble(entries, problems):
    """Moves licence texts into the shared table and returns the JSON document."""
    texts = {}
    out = []
    for entry in entries:
        entry = dict(entry)
        text = entry.pop("_text")
        notice = entry.pop("_notice", None)
        body, block = split_copyright(text, entry["licence"])
        if block is not None:
            entry["copyrightBlock"] = block
        tid = text_id(body)
        texts.setdefault(tid, body)
        entry["textId"] = tid
        if notice:
            nid = text_id(notice)
            texts.setdefault(nid, notice)
            entry["noticeId"] = nid
        out.append(entry)
    out.sort(key=lambda e: (e["name"].lower(), e["version"], e["kind"]))
    keys = ["name", "version", "kind", "licence", "licenceExpression", "copyright", "copyrightBlock",
            "textId", "noticeId", "source", "sourceCode", "usedIn", "note"]
    ordered = [{k: e[k] for k in keys if k in e} for e in out]
    return {
        "schemaVersion": SCHEMA_VERSION,
        "generatedBy": "scripts/gen-acknowledgements.py",
        "texts": {k: texts[k] for k in sorted(texts)},
        "entries": ordered,
    }


def build(root, editor_dir, map_dir, resolved_path, checkout_dirs, config):
    problems = []
    entries = []
    entries += collect_npm(root, editor_dir, map_dir, config, problems)
    entries += collect_swiftpm(root, resolved_path, checkout_dirs, problems)
    entries += collect_assets(root, config, problems)
    if problems:
        raise Problems(problems)
    document = assemble(entries, problems)
    return document


def render(document):
    return json.dumps(document, indent=1, ensure_ascii=False, sort_keys=False) + "\n"


def expand_text(document, entry, key="textId"):
    """The licence text of an entry, with its copyright block put back (what the app shows)."""
    body = document["texts"][entry[key]]
    return body.replace(PLACEHOLDER, entry.get("copyrightBlock", entry["copyright"]))


def summary(document):
    counts = {}
    for entry in document["entries"]:
        counts.setdefault(entry["licence"], []).append(entry["name"])
    lines = []
    families = {}
    for licence, names in counts.items():
        families.setdefault(family(licence), []).append((licence, len(names)))
    for fam in sorted(families):
        total = sum(n for _, n in families[fam])
        detail = ", ".join("%s %d" % item for item in sorted(families[fam]))
        lines.append("%s: %d (%s)" % (fam, total, detail))
    lines.append("entries: %d, distinct licence texts: %d" % (len(document["entries"]), len(document["texts"])))
    return lines


# ---------------------------------------------------------------- build the editor / main

def build_editor_maps(root, destination):
    env = dict(os.environ)
    extra = ["/opt/homebrew/bin", "/usr/local/bin", str(Path.home() / ".volta/bin"), str(Path.home() / "Library/pnpm")]
    env["PATH"] = os.pathsep.join(extra + [env.get("PATH", "")])
    if shutil.which("pnpm", path=env["PATH"]) is None:
        raise Problems(["pnpm not found; install Node and pnpm, or pass --editor-build with a build made with --sourcemap"])
    result = subprocess.run(
        ["pnpm", "--dir", str(Path(root) / EDITOR_REL), "build", "--sourcemap", "--outDir", str(destination), "--emptyOutDir"],
        env=env, capture_output=True, text=True)
    if result.returncode != 0:
        raise Problems(["editor build failed:\n" + (result.stdout + result.stderr)[-2000:]])


def default_checkout_dirs(root):
    return [Path(root) / "Packages/TheoNotesCore/.build/checkouts", Path(root) / "build/DerivedData/SourcePackages/checkouts"]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--check", action="store_true", help="fail when the committed file is stale")
    parser.add_argument("--summary", action="store_true", help="print the licence families")
    parser.add_argument("--root", default=str(Path(__file__).resolve().parent.parent))
    parser.add_argument("--app-bundle", help="the built app to audit (default for --check: build/DerivedData/.../Debug)")
    parser.add_argument("--editor-build", help="a finished `vite build --sourcemap` directory (skips the build)")
    parser.add_argument("--swift-checkouts", action="append", default=[], help="extra SwiftPM checkouts directory")
    args = parser.parse_args(argv)

    root = Path(args.root)
    config = json.loads((root / CONFIG_REL).read_text(encoding="utf-8"))
    output = root / OUTPUT_REL
    tmp = None
    try:
        if args.editor_build:
            map_dir = Path(args.editor_build)
        else:
            tmp = tempfile.mkdtemp(prefix="baerchen-ack-")
            map_dir = Path(tmp)
            build_editor_maps(root, map_dir)
        checkouts = [Path(p) for p in args.swift_checkouts] + default_checkout_dirs(root)
        document = build(root, root / EDITOR_REL, map_dir, root / RESOLVED_REL, checkouts, config)
        bundle = args.app_bundle or (str(root / DEFAULT_APP_REL) if args.check else None)
        if bundle:
            problems = []
            audit_bundle(Path(bundle) / "Contents/Resources", map_dir, document["entries"], config, problems)
            audit_code(Path(bundle) / "Contents", config, problems)
            if problems:
                raise Problems(problems)
    except Problems as error:
        print("gen-acknowledgements: %d problem(s):" % len(error.problems), file=sys.stderr)
        for problem in error.problems:
            print("  - " + problem, file=sys.stderr)
        return 1
    finally:
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)

    text = render(document)
    if args.summary:
        print("\n".join(summary(document)))
    if args.check:
        current = output.read_text(encoding="utf-8") if output.exists() else None
        if current != text:
            print("gen-acknowledgements: %s is stale; run `python3 -I scripts/gen-acknowledgements.py`" % OUTPUT_REL, file=sys.stderr)
            return 1
        print("gen-acknowledgements: %s is up to date (%d entries)" % (OUTPUT_REL, len(document["entries"])))
        return 0
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(text, encoding="utf-8")
    print("gen-acknowledgements: wrote %s (%d entries, %d licence texts)" % (OUTPUT_REL, len(document["entries"]), len(document["texts"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
