// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

/// Every leaf command of the CLI, in the order of the contract. `CommandTableContractTests`
/// checks it against `Fixtures/cli/contract.json`, which `HelpText` is generated from as well,
/// so table, help and contract cannot drift apart.
enum CommandTable {
    static let all: [CommandSpec] = specs.map(withExtensions)

    /// Group name to its default subcommand (`tags` means `tags list`); `app` has none.
    static let groupDefaults: [String: String] = ["tags": "list", "attachments": "list", "pin": "list"]

    static func spec(_ path: [String]) -> CommandSpec? { index[path] }

    /// Group name to its subcommands, in table order.
    static let groups: [String: [String]] = {
        var result: [String: [String]] = [:]
        for spec in all where spec.path.count == 2 { result[spec.path[0], default: []].append(spec.path[1]) }
        return result
    }()

    /// Top-level command and group names in table order, without repeats.
    static let topLevelNames: [String] = {
        var seen = Set<String>()
        return all.map(\.path[0]).filter { seen.insert($0).inserted }
    }()

    private static let index: [[String]: CommandSpec] = Dictionary(uniqueKeysWithValues: all.map { ($0.path, $0) })

    // MARK: Extensions beyond bearcli

    /// Every command accepts `--data-dir`; `create` also takes `--template` (not escaped).
    private static func withExtensions(_ spec: CommandSpec) -> CommandSpec {
        var spec = spec
        if spec.path == ["create"] {
            let at = spec.options.firstIndex { $0.long == "--if-not-exists" } ?? spec.options.endIndex
            spec.options.insert(opt("--template", value: "template"), at: at)
        }
        spec.options.append(opt("--data-dir", value: "path"))
        return spec
    }

    // MARK: Building blocks

    private static let integerOptions: Set<String> = [
        "--limit", "--offset", "--context", "--selection-offset", "--selection-length",
    ]

    /// Options whose value is arbitrary text, so a leading `-` is part of it.
    /// Escaped options are free text, except `--section`, which bearcli treats like `--title`.
    private static let otherFreeTextOptions: Set<String> = ["--query", "--selection-text", "--header"]

    private static func opt(
        _ long: String, _ short: Character? = nil, value: String, default defaultValue: String? = nil,
        aliases: [String] = [], escapes: Bool = false, repeatable: Bool = false
    ) -> OptionSpec {
        OptionSpec(
            long: long, short: short, aliases: aliases, valueName: value, defaultValue: defaultValue,
            escapes: escapes, repeatable: repeatable, integer: integerOptions.contains(long),
            freeText: (escapes && long != "--section") || otherFreeTextOptions.contains(long))
    }

    private static func flag(_ long: String, repeatable: Bool = false) -> OptionSpec {
        OptionSpec(long: long, repeatable: repeatable)
    }

    private static let title = opt("--title", "t", value: "title")
    private static let format = opt("--format", value: "format", default: "tsv")
    private static let fields = opt("--fields", value: "fields")
    private static let section = opt("--section", value: "section", escapes: true)
    private static let limit = opt("--limit", "n", value: "limit")
    private static let noUpdateModified = flag("--no-update-modified")
    private static let noteID = ArgumentSpec(name: "note-id")

    private static let noteFields = [
        "id", "title", "locked", "tags", "length", "created", "modified", "pins", "location", "todos", "done",
        "attachments",
    ]
    private static let contentField = ["content"]

    private static func command(
        _ path: [String], arguments: [ArgumentSpec] = [noteID], options: [OptionSpec], acceptsFormat: Bool = false,
        defaultFields: [String] = [], allFields: [String] = [], extraFields: [String] = [],
        readsContentFromStdin: Bool = false
    ) -> CommandSpec {
        CommandSpec(
            path: path, arguments: arguments, options: options, acceptsFormat: acceptsFormat,
            defaultFields: defaultFields, allFields: allFields, extraFields: extraFields,
            readsContentFromStdin: readsContentFromStdin)
    }

    /// `list`-style commands that identify a note and print one column of values.
    private static func noteScoped(
        _ path: [String], _ extra: [OptionSpec] = [], arguments: [ArgumentSpec] = [noteID]
    ) -> CommandSpec {
        command(path, arguments: arguments, options: [title] + extra)
    }

    private static func listing(_ path: [String], fields column: [String], _ extra: [OptionSpec] = []) -> CommandSpec {
        command(
            path, options: [title] + extra + [format, fields], acceptsFormat: true, defaultFields: column,
            allFields: column)
    }

    // MARK: Table (document order of the reference)

    private static let specs: [CommandSpec] = [
        command(
            ["list"], arguments: [],
            options: [
                opt("--sort", "s", value: "sort", default: "pinned,modified"), limit,
                opt("--offset", "o", value: "offset", default: "0"),
                opt("--location", "l", value: "location", default: "notes"), opt("--tag", value: "tag"),
                flag("--count"), format, fields,
            ],
            acceptsFormat: true, defaultFields: ["id", "title", "tags", "length"], allFields: noteFields,
            extraFields: contentField),
        command(
            ["search"], arguments: [ArgumentSpec(name: "query-arg")],
            options: [
                opt("--query", "q", value: "query"), opt("--sort", "s", value: "sort", default: "pinned,modified"),
                limit, opt("--offset", "o", value: "offset", default: "0"),
                opt("--location", "l", value: "location", default: "notes"), flag("--count"), format, fields,
            ],
            acceptsFormat: true, defaultFields: ["id", "title", "tags", "length", "matches"],
            allFields: noteFields + ["matches"], extraFields: contentField),
        command(
            ["cat"],
            options: [title, section, opt("--offset", "o", value: "offset"), limit, format],
            acceptsFormat: true),
        command(
            ["show"], options: [title, format, fields], acceptsFormat: true, defaultFields: ["id", "title", "tags"],
            allFields: noteFields, extraFields: contentField),
        command(
            ["outline"], options: [title, section, format, fields], acceptsFormat: true,
            defaultFields: ["address", "offset", "length"], allFields: ["address", "offset", "length"]),
        command(
            ["search-in"],
            options: [
                title, opt("--string", "s", value: "string", aliases: ["--find"], escapes: true),
                opt("--context", value: "context", default: "120"), limit, section, flag("--count"), format, fields,
            ],
            acceptsFormat: true, defaultFields: ["offset", "snippet", "section", "source"],
            allFields: ["offset", "snippet", "section", "source"]),
        command(
            ["create"], arguments: [ArgumentSpec(name: "title")],
            options: [
                opt("--content", "c", value: "content", escapes: true), opt("--tags", value: "tags"),
                flag("--if-not-exists"), format, fields,
            ],
            acceptsFormat: true, defaultFields: ["id", "title", "tags"], allFields: noteFields,
            extraFields: contentField, readsContentFromStdin: true),
        command(
            ["append"],
            options: [
                title, opt("--content", "c", value: "content", escapes: true),
                opt("--position", value: "position", default: "end"), section, noUpdateModified,
            ],
            readsContentFromStdin: true),
        command(
            ["edit"],
            options: [
                title, section, opt("--find", value: "find", escapes: true, repeatable: true),
                opt("--replace", value: "replace", escapes: true, repeatable: true),
                opt("--insert-after", value: "insert-after", escapes: true, repeatable: true),
                opt("--insert-before", value: "insert-before", escapes: true, repeatable: true),
                flag("--delete", repeatable: true), flag("--all", repeatable: true),
                flag("--ignore-case", repeatable: true), flag("--word", repeatable: true), noUpdateModified,
                flag("--force"),
            ]),
        command(
            ["overwrite"],
            options: [
                title, opt("--content", "c", value: "content", escapes: true), opt("--base", value: "base"), section,
                noUpdateModified, flag("--force"),
            ],
            readsContentFromStdin: true),
        command(
            ["tags", "list"], options: [title, flag("--count"), format, fields], acceptsFormat: true,
            defaultFields: ["tag"], allFields: ["tag"]),
        noteScoped(["tags", "add"], arguments: [noteID, ArgumentSpec(name: "tags", variadic: true)]),
        noteScoped(["tags", "remove"], arguments: [noteID, ArgumentSpec(name: "tags", variadic: true)]),
        command(
            ["tags", "rename"], arguments: [ArgumentSpec(name: "old"), ArgumentSpec(name: "new")],
            options: [opt("--from", value: "from"), opt("--to", value: "to"), flag("--force")]),
        command(["tags", "delete"], arguments: [ArgumentSpec(name: "tag")], options: [opt("--name", value: "name")]),
        listing(["attachments", "list"], fields: ["filename", "size"]),
        command(
            ["attachments", "add"], options: [title, opt("--filename", "f", value: "filename"), noUpdateModified],
            readsContentFromStdin: true),
        command(
            ["attachments", "add-url"],
            options: [
                title, opt("--url", "u", value: "url"), opt("--filename", "f", value: "filename"), noUpdateModified,
            ]),
        command(
            ["attachments", "delete"], options: [title, opt("--filename", "f", value: "filename"), noUpdateModified]),
        noteScoped(["attachments", "save"], [opt("--filename", "f", value: "filename")]),
        listing(["pin", "list"], fields: ["pin"]),
        noteScoped(["pin", "add"], arguments: [noteID, ArgumentSpec(name: "targets", variadic: true)]),
        noteScoped(["pin", "remove"], arguments: [noteID, ArgumentSpec(name: "targets", variadic: true)]),
        noteScoped(["trash"]),
        noteScoped(["archive"]),
        noteScoped(["restore"]),
        noteScoped(
            ["app", "open"],
            [
                opt("--header", value: "header"), flag("--edit"), flag("--new-window"), flag("--float"),
                opt("--selection-text", value: "selection-text"),
                opt("--selection-offset", value: "selection-offset"),
                opt("--selection-length", value: "selection-length"),
            ]),
        command(
            ["app", "get-selection"], arguments: [], options: [format, fields], acceptsFormat: true,
            defaultFields: ["id", "title", "selectionOffset", "selectionLength", "selectionText"],
            allFields: noteFields + ["selectionOffset", "selectionLength", "selectionText"],
            extraFields: contentField),
        command(
            ["mcp-server"], arguments: [],
            options: [opt("--only-tags", value: "only-tags"), opt("--exclude-tags", value: "exclude-tags")]),
    ]
}
