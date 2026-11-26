#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

"""Generate the Swift sources of TheoNotesAutomation from the fixtures we own.

Usage: python3 -I scripts/gen-automation-sources.py          write the generated files
       python3 -I scripts/gen-automation-sources.py --check  fail when a generated file is stale

Clean room: nothing under docs/research/ is read here. Interface facts and our own
prose come from four files under Fixtures/:

Help part
  Fixtures/cli/contract.json      command, option and argument names, short forms, defaults, fields
  Fixtures/cli/help-prose.json    our own help text: summaries, usage lines, option and argument
                                  descriptions, reference blocks, examples
  -> Packages/TheoNotesCore/Sources/TheoNotesAutomation/Generated/HelpText.swift
The generator lays the pieces out (option labels, defaults and field lists come from the contract, so
they cannot drift from the prose) and fails if the prose and the contract name different options.
HelpText also carries every command's USAGE line and per-option help line, which the argument parser
quotes in its usage errors.

Catalog part
  Fixtures/mcp/tool-schemas.json  the 26 tools: name, title, annotations, input and output schemas,
                                  without any description
  Fixtures/mcp/extension-tools.json  the extension tools create_note_from_template and capture_thought:
                                  name, title, annotations, input schema and `outputSchemaFrom` (the tool
                                  whose output schema they share), without any description
  Fixtures/mcp/descriptions.json  our own descriptions (one entry per description slot of the schemas),
                                  the server instructions and the descriptions of the extension tools
  -> Packages/TheoNotesCore/Sources/TheoNotesAutomation/Generated/MCPToolCatalog.swift
Keys of every object are written in alphabetical order, which is the order the catalog has always had.
"""
import json
import re
import sys
import textwrap
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONTRACT = ROOT / "Fixtures/cli/contract.json"
HELP_PROSE = ROOT / "Fixtures/cli/help-prose.json"
HELP_OUTPUT = ROOT / "Packages/TheoNotesCore/Sources/TheoNotesAutomation/Generated/HelpText.swift"
MCP_SCHEMAS = ROOT / "Fixtures/mcp/tool-schemas.json"
MCP_EXTENSIONS = ROOT / "Fixtures/mcp/extension-tools.json"
MCP_DESCRIPTIONS = ROOT / "Fixtures/mcp/descriptions.json"
CATALOG_OUTPUT = ROOT / "Packages/TheoNotesCore/Sources/TheoNotesAutomation/Generated/MCPToolCatalog.swift"

SEPARATOR = "-" * 72
LABEL_WIDTH = 24
WRAP = 78


def load(path):
    return json.loads(path.read_text(encoding="utf-8"))


def swift_string(s):
    out = s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")
    return '"' + out + '"'


def swift_block(text):
    assert '"""##' not in text
    return '##"""\n' + text + '\n"""##'


# MARK: Help

def resolve(text, shared):
    """`@name` points at a shared description."""
    if isinstance(text, str) and text.startswith("@"):
        return shared[text[1:]]
    return text


def option_label(option):
    names = ([option["short"]] if option["short"] else []) + [option["long"]] + option["aliases"]
    label = ", ".join(names)
    return label + f" <{option['value']}>" if option["value"] else label


def layout_entry(label, text):
    """`  label   text`, the text wrapped under the label column; a long label gets its own line."""
    pad = " " * (2 + LABEL_WIDTH)
    wrapped = textwrap.wrap(text, width=WRAP, initial_indent=pad, subsequent_indent=pad) or [pad]
    if len(label) <= LABEL_WIDTH - 2:
        return ["  " + label.ljust(LABEL_WIDTH) + wrapped[0][len(pad):]] + wrapped[1:]
    return ["  " + label] + wrapped


def block(title, lines):
    return [f"{title}:"] + [("  " + line) if line else "" for line in lines]


def fields_block(command):
    if not command["allFields"] and not command["defaultFields"]:
        return []
    lines = ["Default: " + ", ".join(command["defaultFields"]), "All:     " + ", ".join(command["allFields"])]
    if command["extraFields"]:
        lines.append("Also on request: " + ", ".join(command["extraFields"]) + " (name it, or use --fields all,content).")
    return block("FIELDS", lines)


def contract_commands(contract):
    return {" ".join(c["path"]): c for c in contract["commands"]}


def build_section(key, entry, command, shared, groups):
    """(lines of the section, usage, {long option: one-line help})."""
    lines = [f"OVERVIEW: {entry['summary']}", "", f"USAGE: {entry['usage']}"]
    option_help = {}
    arguments = entry.get("arguments", {})
    if command is not None:
        declared = {a["name"] for a in command["arguments"]}
        assert declared == set(arguments) or (not arguments and not declared), (key, declared, set(arguments))
    if arguments:
        lines += ["", "ARGUMENTS:"]
        for name, text in arguments.items():
            lines += layout_entry(f"<{name}>", resolve(text, shared["arguments"]))
    options = entry.get("options", {})
    contract_options = {}
    if command is not None:
        contract_options = {o["long"]: o for o in command["options"]}
        flags = set(command["flags"])
        assert set(options) == set(contract_options) | flags | extension_options(options), (
            key, sorted(set(options) ^ (set(contract_options) | flags)))
    lines += ["", "OPTIONS:"]
    for long, spec in options.items():
        if isinstance(spec, dict):
            label, text, default, names = spec["label"], spec["text"], None, [long]
        else:
            text = resolve(spec, shared["options"])
            option = contract_options.get(long)
            label = option_label(option) if option else long
            default = option["default"] if option else None
            names = [long] + (option["aliases"] if option else [])
        assert "\n" not in text, (key, long)
        for name in names:
            option_help[name] = text
        shown = text + (f" (default: {default})" if default is not None else "")
        lines += layout_entry(label, shown)
    lines += layout_entry("-h, --help", "Show help for this command.")
    if "subcommands" in entry:
        default = groups.get(key)
        lines += ["", "SUBCOMMANDS:"]
        for name, text in entry["subcommands"]:
            lines += layout_entry(name + (" (default)" if name == default else ""), text)
        lines += ["", f"  Run 'theonotes help {key} <subcommand>' for the full help of one subcommand."]
    if command is not None:
        fields = fields_block(command)
        if fields:
            lines += [""] + fields
    for blk in entry.get("blocks", []):
        lines += [""] + block(blk["title"], blk["lines"])
    return lines, entry["usage"], option_help


def extension_options(options):
    return {long for long, spec in options.items() if isinstance(spec, dict)}


def build_help():
    contract = load(CONTRACT)
    prose = load(HELP_PROSE)
    shared = prose["shared"]
    commands = contract_commands(contract)
    groups = contract["groups"]
    overview_entry = prose["overview"]

    # Top-level overview.
    top = [f"OVERVIEW: {overview_entry['summary']}", "", f"USAGE: {overview_entry['usage']}", "", "OPTIONS:"]
    for label, text in overview_entry["options"]:
        top += layout_entry(label, text)
    top += ["", "SUBCOMMANDS:"]
    names = [name for name, _ in overview_entry["subcommands"]]
    for name, text in overview_entry["subcommands"]:
        top += layout_entry(name, text)
    top_level = {c["path"][0] for c in contract["commands"]}
    assert set(names) == top_level, sorted(set(names) ^ top_level)
    for blk in overview_entry["blocks"]:
        top += [""] + block(blk["title"], blk["lines"])
    cut = top.index("HELP:")
    subcommand_list = "\n".join(top[:cut] + ["  Run 'theonotes help <subcommand>' for the full help of one subcommand."])
    top += ["", "GLOBAL OPTIONS:"]
    for option in prose["globalOptions"]:
        top += layout_entry(option["flag"], option["text"])

    # Sections: every command of the contract, every group.
    wanted = set(commands) | set(groups) | {"mcp-server"}
    assert set(prose["commands"]) == wanted, sorted(set(prose["commands"]) ^ wanted)
    sections = []
    usages = {"": overview_entry["usage"]}
    option_help = {}
    for key, entry in prose["commands"].items():
        lines, usage, helps = build_section(key, entry, commands.get(key), shared, groups)
        sections.append((key, "THEONOTES " + key.upper(), lines))
        usages[key] = usage
        option_help[key] = helps
    for group, default in groups.items():
        subs = {name for name, _ in prose["commands"][group]["subcommands"]}
        expected = {c["path"][1] for c in contract["commands"] if c["path"][0] == group}
        assert subs == expected, (group, subs ^ expected)

    all_lines = list(top)
    for _, title, lines in sections:
        all_lines += ["", SEPARATOR, title, ""] + lines
    all_text = "\n".join(all_lines)
    overview_text = "\n".join(top)

    out = [
        "// SPDX-License-Identifier: GPL-3.0-only",
        "// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors",
        "",
    ]
    out.append("// Generated by scripts/gen-automation-sources.py from Fixtures/cli/contract.json and")
    out.append("// Fixtures/cli/help-prose.json. Do not edit by hand; run the script again (ruling M5-R3).")
    out.append("")
    out.append("enum HelpText {")
    out.append("    /// `theonotes help all`: the whole reference.")
    out.append("    static let all: String = " + swift_block(all_text))
    out.append("")
    out.append("    /// `theonotes -h` / `theonotes help`: the overview.")
    out.append("    static let overview: String = " + swift_block(overview_text))
    out.append("")
    out.append("    /// What `theonotes help <unknown command>` prints: the subcommand list of the overview.")
    out.append("    static let subcommandList: String = " + swift_block(subcommand_list))
    out.append("")
    out.append("    /// Section texts (starting at `OVERVIEW:`) by path, e.g. `\"tags add\"`.")
    out.append("    static let sections: [String: String] = [")
    for key, _, lines in sections:
        out.append("        " + swift_string(key) + ": " + swift_block("\n".join(lines)) + ",")
    out.append("    ]")
    out.append("")
    out.append("    /// The section for a command or group path; empty when there is none.")
    out.append("    static func section(for path: [String]) -> String {")
    out.append('        sections[path.joined(separator: " ")] ?? ""')
    out.append("    }")
    out.append("")
    out.append("    /// The `USAGE:` line of every section by path (`\"\"` is the top level), without the prefix.")
    out.append("    static let usages: [String: String] = [")
    for key, usage in usages.items():
        out.append("        " + swift_string(key) + ": " + swift_string(usage) + ",")
    out.append("    ]")
    out.append("")
    out.append("    /// One-line help of every option by path and long name, quoted in usage errors.")
    out.append("    static let optionHelp: [String: [String: String]] = [")
    for key, helps in option_help.items():
        if not helps:
            continue
        out.append("        " + swift_string(key) + ": [")
        for flag, text in helps.items():
            out.append("            " + swift_string(flag) + ": " + swift_string(text) + ",")
        out.append("        ],")
    out.append("    ]")
    out.append("")
    out.append("    /// Help of the options every command accepts.")
    out.append("    static let globalOptionHelp: [String: String] = [")
    for option in prose["globalOptions"]:
        out.append("        " + swift_string(option["flag"].split()[0]) + ": " + swift_string(option["text"]) + ",")
    out.append("    ]")
    out.append("}")
    return "\n".join(out) + "\n"


# MARK: MCP catalog

def inject(node, path, descriptions, used):
    """A copy of `node` with a `description` wherever `descriptions` has an entry for its path; keys sorted."""
    if isinstance(node, dict):
        out = {key: inject(value, f"{path}/{key}", descriptions, used) for key, value in node.items()}
        if path in descriptions:
            used.add(path)
            out["description"] = descriptions[path]
        return dict(sorted(out.items()))
    if isinstance(node, list):
        return [inject(value, f"{path}/{index}", descriptions, used) for index, value in enumerate(node)]
    return node


def extension_tool(owned, tools, extension):
    """An extension tool beyond the 26: the owned structure, its descriptions
    and the output schema of the tool it names. Key order inside the input schema is the fixture's; the
    tool's own keys are in alphabetical order like every other tool of the catalog."""
    owned = dict(owned)
    source = owned.pop("outputSchemaFrom")
    schema = json.loads(json.dumps(owned["inputSchema"]))
    texts = extension["properties"]
    assert set(texts) == set(schema["properties"]), (owned["name"], sorted(set(texts) ^ set(schema["properties"])))
    for name, prop in schema["properties"].items():
        prop["description"] = texts[name]
    owned["inputSchema"] = schema
    owned["description"] = extension["description"]
    owned["outputSchema"] = next(t for t in tools if t["name"] == source)["outputSchema"]
    return dict(sorted(owned.items()))


def build_catalog():
    schemas = load(MCP_SCHEMAS)["tools"]
    prose = load(MCP_DESCRIPTIONS)
    assert len(schemas) == 26, len(schemas)
    descriptions = prose["descriptions"]
    used = set()
    tools = [inject(tool, tool["name"], descriptions, used) for tool in schemas]
    assert used == set(descriptions), sorted(used ^ set(descriptions))
    extensions = load(MCP_EXTENSIONS)["tools"]
    assert [t["name"] for t in extensions] == list(prose["extensionTools"]), (
        [t["name"] for t in extensions], list(prose["extensionTools"]))
    for owned in extensions:
        assert "description" not in json.dumps(owned), owned["name"]
        tools.append(extension_tool(owned, tools, prose["extensionTools"][owned["name"]]))
    instructions = prose["instructions"]
    for text in [instructions] + [json.dumps(tool, ensure_ascii=False) for tool in tools]:
        assert not re.search(r"\bBear\b|bearcli|bear\.app|/Applications/", text), text[:80]

    lines = ",\n".join(json.dumps(tool, ensure_ascii=False, separators=(",", ":")) for tool in tools)
    out = [
        "// SPDX-License-Identifier: GPL-3.0-only",
        "// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors",
        "",
    ]
    out.append("// Generated by scripts/gen-automation-sources.py from Fixtures/mcp/tool-schemas.json,")
    out.append("// Fixtures/mcp/extension-tools.json and Fixtures/mcp/descriptions.json. Do not edit by hand;")
    out.append("// run the script again (ruling M5-R3).")
    out.append("import Foundation")
    out.append("")
    out.append("enum MCPToolCatalog {")
    out.append("    /// The 26 tools in their fixed order, then `create_note_from_template` and `capture_thought`.")
    out.append("    static let tools: [JSONValue] = {")
    out.append("        guard let parsed = try? JSONValue(parsing: Data(toolsJSON.utf8)), let tools = parsed.array else {")
    out.append('            fatalError("MCPToolCatalog.toolsJSON is not a JSON array")')
    out.append("        }")
    out.append("        return tools")
    out.append("    }()")
    out.append("")
    out.append('    static let toolNames: [String] = tools.compactMap { $0["name"]?.string }')
    out.append("")
    out.append("    /// The `instructions` of the `initialize` reply.")
    out.append("    static let instructions: String = " + swift_block(instructions))
    out.append("")
    out.append("    private static let toolsJSON: String = " + swift_block("[\n" + lines + "\n]"))
    out.append("}")
    return "\n".join(out) + "\n"


def main(argv):
    check = argv[1:] == ["--check"]
    if argv[1:] and not check:
        raise SystemExit(__doc__)
    generated = {HELP_OUTPUT: build_help(), CATALOG_OUTPUT: build_catalog()}
    stale = False
    for path, content in generated.items():
        if check:
            if not path.exists() or path.read_text(encoding="utf-8") != content:
                print(f"stale: {path.relative_to(ROOT)}", file=sys.stderr)
                stale = True
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
    return 1 if stale else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
