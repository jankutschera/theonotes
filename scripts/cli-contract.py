#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

"""Parse docs/research/bearcli-help-all.txt (`bearcli help all`) into Fixtures/cli/contract.json.

Usage: python3 -I scripts/cli-contract.py docs/research/bearcli-help-all.txt > Fixtures/cli/contract.json

One entry per leaf command (29 for bearcli 3.0.2), in document order:
  path, defaultSubcommand, arguments[{name, variadic}], options[{long, short, aliases, value,
  default, escapes}], flags[long], acceptsFormat, defaultFields, allFields, extraFields
`allFields` is what `--fields all` selects and never contains `content` (the help says "Content is
excluded from all"); `extraFields` holds `content`, which only an explicit `--fields all,content`
adds (ruling M5-R32). Plus `groups` (group name -> default subcommand or null). `-h, --help` is left out.
"""
import json
import re
import sys

SEPARATOR = re.compile(r"^-{20,}$")
HEADER = re.compile(r"^BEARCLI (.+)$")
OPTION = re.compile(
    r"^  ((?:-\w|--[\w-]+)(?:, (?:-\w|--[\w-]+))*)(?: <([\w-]+)>)?(?:\s+(.*))?$"
)
ARGUMENT = re.compile(r"\[<([\w-]+)>( \.\.\.)?\]")
DEFAULT = re.compile(r"\(([^()]*?;\s*)?default: ([^)]*)\)")
ESCAPES = re.compile(r"Interprets \\n, \\t, \\r, \\\\")


def split_sections(text):
    """[(upper-case name, body lines)] for every `BEARCLI <NAME>` section."""
    lines = text.splitlines()
    sections = []
    i = 0
    while i < len(lines):
        if SEPARATOR.match(lines[i]) and i + 1 < len(lines) and HEADER.match(lines[i + 1]):
            name = HEADER.match(lines[i + 1]).group(1)
            j = i + 2
            while j < len(lines) and not (
                SEPARATOR.match(lines[j]) and j + 1 < len(lines) and HEADER.match(lines[j + 1])
            ):
                j += 1
            sections.append((name, lines[i + 2 : j]))
            i = j
        else:
            i += 1
    return sections


def block(lines, title):
    """The indented lines under `TITLE:` (up to the first blank or unindented line)."""
    out = []
    started = False
    for line in lines:
        if not started:
            if line.rstrip() == title + ":":
                started = True
            continue
        if not line.strip() or not line.startswith(" "):
            break
        out.append(line)
    return out


def usage_line(lines):
    for line in lines:
        if line.startswith("USAGE: bearcli "):
            return line[len("USAGE: bearcli "):]
    raise SystemExit("no USAGE line")


def parse_options(lines):
    options = []
    flags = []
    current = None
    for line in block(lines, "OPTIONS"):
        m = OPTION.match(line)
        if m:
            if current:
                options.append(current)
            names = m.group(1).split(", ")
            current = {
                "names": names,
                "value": m.group(2),
                "text": (m.group(3) or "").strip(),
            }
        elif current is not None:
            current["text"] += " " + line.strip()
    if current:
        options.append(current)

    result = []
    for o in options:
        longs = [n for n in o["names"] if n.startswith("--")]
        shorts = [n for n in o["names"] if not n.startswith("--")]
        if longs == ["--help"]:
            continue
        text = re.sub(r"\s+", " ", o["text"])
        default = DEFAULT.search(text)
        entry = {
            "long": longs[0],
            "short": shorts[0] if shorts else None,
            "aliases": longs[1:],
            "value": o["value"],
            "default": default.group(2) if default else None,
            "escapes": bool(ESCAPES.search(text)),
        }
        if o["value"] is None:
            flags.append(entry["long"])
        else:
            result.append(entry)
    return result, flags


def parse_fields(lines, title):
    """`Default fields:` / `All fields:` values, continuation lines included."""
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith(title + ":"):
            text = stripped[len(title) + 1 :]
            j = i + 1
            while j < len(lines) and lines[j].startswith("              ") and lines[j].strip():
                text += " " + lines[j].strip()
                j += 1
            return [f.strip() for f in text.split(",") if f.strip()]
    return []


def split_content(fields):
    """(`all` without content, extra fields that must be requested)."""
    return [f for f in fields if f != "content"], [f for f in fields if f == "content"]


def parse_arguments(usage):
    return [
        {"name": m.group(1), "variadic": m.group(2) is not None}
        for m in ARGUMENT.finditer(usage)
        if m.group(1) != "options"
    ]


def group_default(lines):
    for line in block(lines, "SUBCOMMANDS"):
        m = re.match(r"^  ([\w-]+) \(default\)", line)
        if m:
            return m.group(1)
    return None


def main(path):
    sections = split_sections(open(path, encoding="utf-8").read())
    groups = {}
    commands = []
    for name, body in sections:
        path_ = name.lower().split(" ")
        usage = usage_line(body)
        is_group = usage.strip() == " ".join(path_) + " <subcommand>"
        if is_group:
            groups[path_[0]] = group_default(body)
            continue
        options, flags = parse_options(body)
        all_fields, extra_fields = split_content(parse_fields(body, "All fields"))
        commands.append(
            {
                "path": path_,
                "defaultSubcommand": len(path_) == 2 and groups.get(path_[0]) == path_[1],
                "arguments": parse_arguments(usage),
                "options": options,
                "flags": flags,
                "acceptsFormat": any(o["long"] == "--format" for o in options),
                "defaultFields": parse_fields(body, "Default fields"),
                "allFields": all_fields,
                "extraFields": extra_fields,
            }
        )
    json.dump({"commands": commands, "groups": groups}, sys.stdout, indent=1, ensure_ascii=False)
    sys.stdout.write("\n")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    main(sys.argv[1])
