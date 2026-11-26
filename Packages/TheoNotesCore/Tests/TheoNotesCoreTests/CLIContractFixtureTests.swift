// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing


/// `Fixtures/cli/contract.json` (generated from `docs/research/bearcli-help-all.txt` by
/// `scripts/cli-contract.py`) and `Fixtures/cli/cli-observed.json` (written by
/// `bear-oracle --cli-probe`). M5's command table, parser and output code are checked against them.
struct ContractFixture: Decodable {
    struct Argument: Decodable, Equatable {
        let name: String
        let variadic: Bool
    }

    struct Option: Decodable, Equatable {
        let long: String
        let short: String?
        let aliases: [String]
        let value: String?
        let `default`: String?
        let escapes: Bool

        static func missing(_ name: String) -> Option {
            Option(long: name, short: nil, aliases: [], value: nil, default: nil, escapes: false)
        }
    }

    struct Command: Decodable {
        let path: [String]
        let defaultSubcommand: Bool
        let arguments: [Argument]
        let options: [Option]
        let flags: [String]
        let acceptsFormat: Bool
        let defaultFields: [String]
        /// What `--fields all` selects: never `content`.
        let allFields: [String]
        /// Fields that exist but only on request (`--fields all,content`).
        let extraFields: [String]

        /// The option named `name` (or one of its aliases); records an issue and returns an empty
        /// stand-in when the command has none.
        func option(_ name: String, sourceLocation: SourceLocation = #_sourceLocation) -> Option {
            guard let found = options.first(where: { $0.long == name || $0.aliases.contains(name) }) else {
                Issue.record("\(path.joined(separator: " ")) has no option \(name)", sourceLocation: sourceLocation)
                return .missing(name)
            }
            return found
        }

        static func missing(_ path: [String]) -> Command {
            Command(path: path, defaultSubcommand: false, arguments: [], options: [], flags: [], acceptsFormat: false,
                    defaultFields: [], allFields: [], extraFields: [])
        }
    }

    let commands: [Command]
    /// Group name → its default subcommand (`null` when the group has none).
    let groups: [String: String?]

    func command(_ path: String..., sourceLocation: SourceLocation = #_sourceLocation) -> Command {
        guard let found = commands.first(where: { $0.path == path }) else {
            Issue.record("no command \(path.joined(separator: " "))", sourceLocation: sourceLocation)
            return .missing(path)
        }
        return found
    }

    static func load() throws -> ContractFixture {
        try JSONDecoder().decode(ContractFixture.self, from: Data(contentsOf: fixtureURL("contract.json")))
    }
}

/// A JSON value as the probe writes it into `facts` and `shapes`.
indirect enum AnyJSON: Decodable, Equatable {
    case int(Int)
    case bool(Bool)
    case string(String)
    case array([AnyJSON])
    case object([String: AnyJSON])

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .bool(v) } else if let v = try? c.decode(Int.self) { self = .int(v) } else if let v = try? c.decode(String.self) { self = .string(v) } else if let v = try? c.decode([AnyJSON].self) {
            self = .array(v)
        } else {
            self = .object(try c.decode([String: AnyJSON].self))
        }
    }

    subscript(key: String) -> AnyJSON? { if case .object(let o) = self { o[key] } else { nil } }
    var keys: Set<String> { if case .object(let o) = self { Set(o.keys) } else { [] } }
    var strings: [String]? { if case .array(let a) = self { a.compactMap { if case .string(let s) = $0 { s } else { nil } } } else { nil } }
    var string: String? { if case .string(let s) = self { s } else { nil } }
}

struct ObservedFixture: Decodable {
    struct ErrorCase: Decodable {
        let args: [String]
        let exit: Int
        let stdout: String
        let stderr: String
    }

    struct Shape: Decodable {
        let args: [String]?
        let exit: Int?
        let stdout: AnyJSON?
        let stderr: String?
        let request: AnyJSON?
        let response: AnyJSON?
    }

    let bearcliVersion: String
    let errors: [ErrorCase]
    let facts: [String: AnyJSON]
    let shapes: [String: Shape]

    func error(_ args: [String], sourceLocation: SourceLocation = #_sourceLocation) -> ErrorCase? {
        let found = errors.first { $0.args == args }
        if found == nil { Issue.record("no recorded error for \(args)", sourceLocation: sourceLocation) }
        return found
    }

    static func load() throws -> ObservedFixture {
        try JSONDecoder().decode(ObservedFixture.self, from: Data(contentsOf: fixtureURL("cli-observed.json")))
    }
}

private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func fixtureURL(_ name: String) -> URL {
    repoRoot().appendingPathComponent("Fixtures/cli").appendingPathComponent(name)
}

@Suite struct CLIContractFixtureTests {
    static let leafCommands: Set<[String]> = [
        ["list"], ["search"], ["cat"], ["show"], ["outline"], ["search-in"], ["create"], ["append"], ["edit"],
        ["overwrite"],
        ["tags", "list"], ["tags", "add"], ["tags", "remove"], ["tags", "rename"], ["tags", "delete"],
        ["attachments", "list"], ["attachments", "add"], ["attachments", "add-url"], ["attachments", "delete"],
        ["attachments", "save"],
        ["pin", "list"], ["pin", "add"], ["pin", "remove"],
        ["trash"], ["archive"], ["restore"],
        ["app", "open"], ["app", "get-selection"],
        ["mcp-server"],
    ]

    @Test func contractCoversEveryLeafCommand() throws {
        let c = try ContractFixture.load()
        #expect(c.commands.count == 29)
        #expect(Set(c.commands.map(\.path)) == Self.leafCommands)
        #expect(c.command("edit").options.map(\.long).contains("--find"))
        #expect(c.command("search-in").option("--string").aliases == ["--find"])
        #expect(c.command("append").option("--content").escapes)
        #expect(c.command("list").defaultFields == ["id", "title", "tags", "length"])
        #expect(c.command("app", "get-selection").allFields.last == "selectionText")
        #expect(c.command("app", "get-selection").extraFields == ["content"])
    }

    @Test func groupsNameTheirDefaultSubcommand() throws {
        let c = try ContractFixture.load()
        #expect(Set(c.groups.keys) == ["tags", "attachments", "pin", "app"])
        #expect(c.groups["tags"] == .some("list") && c.groups["attachments"] == .some("list") && c.groups["pin"] == .some("list"))
        #expect(c.groups["app"] == .some(nil))
        for (group, sub) in c.groups {
            for command in c.commands where command.path.first == group && command.path.count == 2 {
                #expect(command.defaultSubcommand == (command.path[1] == sub), "\(command.path)")
            }
        }
        #expect(!c.command("list").defaultSubcommand)
    }

    @Test func optionDetailsFollowTheHelp() throws {
        let c = try ContractFixture.load()
        let sort = c.command("list").option("--sort")
        #expect(sort.short == "-s" && sort.value == "sort" && sort.default == "pinned,modified" && !sort.escapes)
        #expect(c.command("list").option("--format").default == "tsv")
        #expect(c.command("list").option("--offset").default == "0")
        #expect(c.command("list").option("--limit").short == "-n")
        #expect(c.command("list").flags == ["--count"])
        #expect(c.command("list").acceptsFormat && !c.command("append").acceptsFormat)
        #expect(!c.commands.flatMap(\.options).contains { $0.long == "--help" })
        #expect(c.command("edit").flags == ["--delete", "--all", "--ignore-case", "--word", "--no-update-modified", "--force"])
        #expect(c.command("edit").option("--insert-after").escapes && c.command("edit").option("--section").escapes)
        #expect(c.command("overwrite").option("--base").escapes == false)
        #expect(c.command("mcp-server").option("--only-tags").value == "only-tags")
        #expect(c.command("create").option("--content").short == "-c")
    }

    @Test func argumentsFollowTheUsageLines() throws {
        let c = try ContractFixture.load()
        #expect(c.command("list").arguments.isEmpty)
        #expect(c.command("show").arguments == [.init(name: "note-id", variadic: false)])
        #expect(c.command("create").arguments == [.init(name: "title", variadic: false)])
        #expect(c.command("search").arguments == [.init(name: "query-arg", variadic: false)])
        #expect(c.command("tags", "add").arguments == [.init(name: "note-id", variadic: false), .init(name: "tags", variadic: true)])
        #expect(c.command("tags", "rename").arguments.map(\.name) == ["old", "new"])
        #expect(c.command("pin", "add").arguments.last == .init(name: "targets", variadic: true))
        #expect(c.command("edit").arguments == [.init(name: "note-id", variadic: false)])
    }

    /// `--fields all` never includes `content`; `content` is an extra, requestable field.
    @Test func allFieldsNeverIncludeContent() throws {
        let c = try ContractFixture.load()
        let base = ["id", "title", "locked", "tags", "length", "created", "modified", "pins", "location", "todos", "done", "attachments"]
        for command in c.commands { #expect(!command.allFields.contains("content"), "\(command.path)") }
        #expect(c.command("list").allFields == base && c.command("list").extraFields == ["content"])
        #expect(c.command("show").allFields == base && c.command("create").allFields == base)
        #expect(c.command("search").allFields == base + ["matches"] && c.command("search").extraFields == ["content"])
        #expect(c.command("outline").extraFields.isEmpty && c.command("tags", "list").extraFields.isEmpty)
    }

    @Test func fieldListsIncludeContinuationLines() throws {
        let c = try ContractFixture.load()
        #expect(c.command("search").defaultFields == ["id", "title", "tags", "length", "matches"])
        #expect(c.command("show").defaultFields == ["id", "title", "tags"])
        #expect(c.command("outline").defaultFields == ["address", "offset", "length"])
        #expect(c.command("search-in").defaultFields == ["offset", "snippet", "section", "source"])
        #expect(c.command("tags", "list").defaultFields == ["tag"])
        #expect(c.command("attachments", "list").allFields == ["filename", "size"])
        #expect(c.command("pin", "list").defaultFields == ["pin"])
        #expect(c.command("app", "get-selection").defaultFields == ["id", "title", "selectionOffset", "selectionLength", "selectionText"])
        #expect(c.command("app", "get-selection").allFields.count == 15)
        #expect(c.command("trash").allFields.isEmpty)
    }

    /// The checked-in fixture is exactly what the generator produces from the checked-in reference.
    static let pythonAvailable = FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")

    /// The private research dump is not part of a public checkout; without it there is nothing to regenerate from.
    static let researchDumpPresent = FileManager.default.fileExists(
        atPath: repoRoot().appendingPathComponent("docs/research/bearcli-help-all.txt").path)

    @Test(.enabled(if: pythonAvailable && researchDumpPresent, "needs /usr/bin/python3 and docs/research"))
    func contractMatchesTheGeneratorOutput() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-I", "scripts/cli-contract.py", "docs/research/bearcli-help-all.txt"]
        process.currentDirectoryURL = repoRoot()
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let generated = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(generated == (try Data(contentsOf: fixtureURL("contract.json"))), "run scripts/cli-contract.py and commit Fixtures/cli/contract.json")
    }

    // MARK: Observed

    @Test func observedFactsArePresent() throws {
        let o = try ObservedFixture.load()
        #expect(o.facts["hashLength"] == .int(7) && o.facts["hashAlgorithm"] == .string("sha256-hex-prefix"))
        #expect(o.error(["show", "ZZZ-NOPE", "--format", "json"])?.exit == 1)
    }

    @Test func errorsRecordOnlyFailures() throws {
        let o = try ObservedFixture.load()
        #expect(o.errors.count > 40)
        for e in o.errors { #expect([1, 64].contains(e.exit), "\(e.args)") }
    }

    @Test func observedErrorsPinTheEnvelopeAndUsageTexts() throws {
        let o = try ObservedFixture.load()
        let json = o.error(["show", "ZZZ-NOPE", "--format", "json"])
        #expect(json?.stdout == #"{"error":{"code":"note_not_found","message":"Note not found: ZZZ-NOPE"}}"# + "\n" && json?.stderr.isEmpty == true)
        let tsv = o.error(["show", "ZZZ-NOPE"])
        #expect(tsv?.exit == 1 && tsv?.stdout.isEmpty == true && tsv?.stderr == "Error: Note not found: ZZZ-NOPE\n")
        let missing = o.error(["show", "--format", "json"])
        #expect(missing?.exit == 64 && missing?.stdout.contains(#""code":"usage""#) == true)
        let limit = o.error(["list", "-n"])
        #expect(limit?.exit == 64 && limit?.stderr.hasPrefix("Error: Missing value for '-n <limit>'\n") == true)
        let bogus = o.error(["bogus-subcommand"])
        #expect(bogus?.exit == 64 && bogus?.stderr.hasPrefix("Error: Unexpected argument 'bogus-subcommand'") == true)
    }

    /// The usage and validation texts the M5 plan quotes.
    @Test func observedUsageTextsAreExact() throws {
        let o = try ObservedFixture.load()
        func message(_ args: [String]) -> String? {
            guard let out = o.error(args)?.stdout, let data = out.data(using: .utf8),
                  let json = try? JSONDecoder().decode(AnyJSON.self, from: data) else { return nil }
            return json["error"]?["message"]?.string
        }
        func stderr(_ args: [String]) -> String? { o.error(args)?.stderr }
        #expect(message(["cat", "ZZZ-NOPE", "--section", "## X", "--offset", "1", "--format", "json"]) == "Provide address or offset/limit, not both")
        #expect(stderr(["search"]) == "Error: Query is required\n")
        #expect(stderr(["search", "a", "--query", "b"]) == "Error: Specify the query as a positional argument or --query, not both\n")
        #expect(stderr(["search", "-x"]) == #"Error: Query starts with "-". Use --query to pass it"# + "\n")
        #expect(stderr(["list", "--location", "bogus"]) == "Error: Invalid location: bogus\n")
        #expect(stderr(["list", "--fields", "bogus"]) == "Error: Unknown field: bogus (valid: id, title, locked, tags, length, created, modified, pins, location, todos, done, attachments)\n")
        #expect(stderr(["list", "--sort", "bogus"]) == "Error: invalid sort field: bogus (valid: pinned, modified, created, title)\n")
        #expect(message(["list", "--sort", "title:sideways", "--format", "json"]) == "invalid sort order: sideways (valid: asc, desc)")
        #expect(stderr(["list", "-n", "-1"])?.hasPrefix("Error: Missing value for '-n <limit>'\n") == true)
        #expect(stderr(["list", "-n", "x"])?.hasPrefix("Error: The value 'x' is invalid for '-n <limit>'\n") == true)
        #expect(stderr(["list", "--bogus"])?.hasPrefix("Error: Unknown option '--bogus'\n") == true)
        #expect(stderr(["list", "extra"])?.hasPrefix("Error: Unexpected argument 'extra'\n") == true)
        #expect(message(["search-in", "ZZZ-NOPE", "--format", "json"]) == "--string is required")
        #expect(message(["show", "ZZZ-NOPE", "--title", "ZZZ NOPE TITLE", "--format", "json"]) == "Provide note ID or title, not both")
        #expect(message(["show", "--title", "ZZZ NOPE TITLE", "--format", "json"]) == "No note with title: ZZZ NOPE TITLE (in notes; use the note ID for trash/archive)")
        #expect(stderr(["show", "ZZZ-NOPE", "--format", "xml"])?.hasPrefix("Error: The value 'xml' is invalid for '--format <format>'. Please provide one of 'tsv', 'csv' or 'json'.\n") == true)
    }

    @Test func observedFactsCoverTheOutputRules() throws {
        let o = try ObservedFixture.load()
        #expect(o.facts["hashMatchesSHA256Prefix"] == .bool(true))
        #expect(o.facts["catAddsNoNewline"] == .bool(true))
        #expect(o.facts["csvLineEnding"] == .string("\n"))
        #expect(o.facts["zeroLimitPrintsNothing"] == .bool(true))
        // Output from real notes is stored as "expected literal + did it match", never as raw text.
        func literal(_ name: String, is expected: String, sourceLocation: SourceLocation = #_sourceLocation) {
            let fact = o.facts[name]
            #expect(fact?["expected"] == .string(expected) && fact?["matchesExpected"] == .bool(true) && fact?["observed"] == nil, "\(name)", sourceLocation: sourceLocation)
        }
        literal("countTSV", is: "N\n")
        literal("countCSV", is: "count\nN\n")
        literal("countJSON", is: #"{"count":N}"# + "\n")
        literal("countSearchJSON", is: #"{"count":N}"# + "\n")
        literal("countTagsListJSON", is: #"{"count":N}"# + "\n")
        literal("countSearchInJSON", is: #"{"count":N}"# + "\n")
        literal("emptyListJSON", is: "[]\n")
        literal("emptyListStderr", is: "No notes found.\n")
        literal("emptyListStdout", is: "")
        literal("searchInNoHitJSON", is: "[]\n")
        literal("searchInNoHitTSV", is: "")
        literal("searchInEmptyStringJSON", is: "[]\n")
        literal("catOffsetPastEndJSON", is: #"{"content":""}"# + "\n")
        if let locked = o.facts["cliLockedValues"]?.strings { #expect(Set(locked).isSubset(of: ["no", "yes"]) && locked.contains("no")) } else { Issue.record("cliLockedValues missing") }
        #expect(o.facts["cliTagsAreHashTokens"] == .bool(true) && o.facts["cliDatesAreISO8601Z"] == .bool(true))
        #expect(o.facts["cliJSONKeyOrderFollowsFieldsOption"] == .bool(true))
        #expect(o.facts["jsonSingleLineWithTrailingNewline"] == .bool(true))
        #expect(o.facts["jsonEscapesSlash"] != .bool(true) && o.facts["mcpEscapesSlash"] == .bool(true))
        #expect(o.facts["mcpEnvelopeKeysSorted"] == .bool(true) && o.facts["mcpToolTextKeysSorted"] == .bool(true))
        #expect(o.facts["mcpNotificationGetsNoReply"] == .bool(true) && o.facts["mcpMalformedJSONCode"] == .int(-32700))
        #expect(o.facts["mcpLockedIsBoolean"] == .bool(true) && o.facts["mcpTagsAreBareNames"] == .bool(true))
        #expect(o.facts["mcpToolErrorsAreIsError"] == .bool(true))
        #expect(o.facts["mcpUnknownToolCode"] == .int(-32602) && o.facts["mcpUnknownMethodCode"] == .int(-32601))
        #expect(o.facts["mcpUnknownMethodMessage"] == .string("method not found: bogus/method"))
        #expect(o.facts["mcpUnknownArgumentIgnored"] == .bool(true))
    }

    /// `all` has no `content`; the content probes record exit codes only.
    @Test func contentIsAnExplicitExtraField() throws {
        let o = try ObservedFixture.load()
        let c = try ContractFixture.load()
        #expect(o.facts["cliAllExcludesContent"] == .bool(true))
        #expect(o.facts["cliListAllKeys"]?.strings == c.command("list").allFields)
        #expect(o.facts["cliShowAllContentKeys"]?.strings == c.command("show").allFields + ["content"])
        #expect(o.facts["cliSearchAllKeys"]?.strings == c.command("search").allFields)
        #expect(o.facts["cliSearchAllContentKeys"]?.strings == c.command("search").allFields + ["content"])
        for name in ["listFieldsContentAloneExit", "showFieldsContentAloneExit", "listFieldsAllContentExit"] {
            if case .int(let exit)? = o.facts[name] { #expect([0, 64, 1].contains(exit), "\(name)") } else { Issue.record("\(name) missing") }
        }
        #expect(o.facts["listFieldsAllContentExit"] == .int(0))
    }

    /// Facts that need data the probed library lacks are listed, not asserted.
    @Test func unobservedBehaviourIsMarked() throws {
        let o = try ObservedFixture.load()
        let unobserved = Set(o.facts["unobserved"]?.strings ?? [])
        if o.facts["lockedNotesObserved"] == .bool(false) {
            #expect(unobserved.isSuperset(of: ["cliLockedYes", "mcpLockedTrue", "lockedNoteReadsAndWrites"]))
        }
        // `attachments save` is outside the probe's allow-list: its raw bytes are the help's word only.
        #expect(unobserved.contains("attachmentsSaveRawBytes"))
        #expect(unobserved.contains("cliTagScopedPins") == (o.facts["cliPinsAreGlobalOrHashTag"] == nil))
        #expect(unobserved.contains("mcpTagScopedPins") == (o.facts["mcpTagPinsAreBareNames"] == nil))
        #expect(!o.shapes.keys.contains { $0.hasPrefix("locked-") } || o.facts["lockedNotesObserved"] == .bool(true))
    }

    @Test func sectionAddressErrorsAreObservedReadOnly() throws {
        let o = try ObservedFixture.load()
        #expect(o.facts["sectionMissingExit"] == .int(1))
        #expect(o.facts["sectionMissingCode"] == .string("not_found") && o.facts["sectionMissingMessage"] == .string("No section matched the address."))
        let missing = o.shapes["section-missing-json"]
        #expect(missing?.exit == 1 && missing?.stdout?["error"]?.keys.isSuperset(of: ["code", "message"]) == true)
        if o.facts["sectionAmbiguousObserved"] == .bool(true) {
            #expect(o.facts["sectionAmbiguousExit"] == .int(1) && o.facts["sectionAmbiguousCode"] == .string("ambiguous"))
            #expect(o.facts["sectionAmbiguousMessage"] == .string("Address matched N sections. Retry with one of the candidate addresses."))
            #expect(o.facts["sectionAmbiguousDetailsKeys"] == .array([.string("candidates")]))
            let candidate = o.shapes["section-ambiguous-json"]?.stdout?["error"]?["details"]?["candidates"]
            if case .array(let list)? = candidate { #expect(list.first?.keys == ["address", "offset", "length", "snippet"]) } else { Issue.record("no candidates") }
            #expect(o.shapes["section-ambiguous-json"]?.exit == 1)
        }
    }

    @Test func shapesSectionPinsTheOutputStructure() throws {
        let o = try ObservedFixture.load()
        let c = try ContractFixture.load()
        let required: Set<String> = [
            "list-json-default", "list-json-all", "list-json-reordered", "list-tsv-default", "list-csv-default", "search-json-default",
            "show-json-default", "show-json-all", "show-json-all-content", "cat-json-whole", "cat-json-range", "outline-json",
            "search-in-json-default", "tags-list-json", "pin-list-json", "attachments-list-json", "cat-json-section",
            "section-missing-json", "mcp-initialize", "mcp-ping", "mcp-list_notes-limit-1", "mcp-get_note", "mcp-get_note-bogus-id",
            "mcp-search_notes-e", "mcp-search_in_note", "mcp-read_note_outline", "mcp-unknown-tool", "mcp-unknown-method", "mcp-malformed-json",
        ]
        #expect(required.isSubset(of: Set(o.shapes.keys)), "missing: \(required.subtracting(o.shapes.keys).sorted())")
        for (name, shape) in o.shapes { #expect(shape.args != nil || shape.request != nil, "\(name)") }

        // CLI JSON rows carry exactly the contract's fields.
        #expect(o.shapes["list-json-default"]?.stdout?.firstElement?.keys == Set(c.command("list").defaultFields))
        #expect(o.shapes["list-json-all"]?.stdout?.firstElement?.keys == Set(c.command("list").allFields))
        #expect(o.shapes["show-json-all"]?.stdout?.keys == Set(c.command("show").allFields))
        #expect(o.shapes["show-json-all-content"]?.stdout?.keys == Set(c.command("show").allFields + ["content"]))
        #expect(o.shapes["show-json-all-content"]?.stdout?["content"] == .string("<string>"))
        #expect(o.shapes["list-json-all"]?.stdout?.firstElement?["locked"] == .string("no"))
        #expect(o.shapes["search-json-default"]?.stdout?.firstElement?.keys == Set(c.command("search").defaultFields))
        #expect(o.shapes["outline-json"]?.stdout?.firstElement?.keys == Set(c.command("outline").defaultFields))
        #expect(o.shapes["search-in-json-default"]?.stdout?.firstElement?.keys == Set(c.command("search-in").defaultFields))
        #expect(o.shapes["cat-json-whole"]?.stdout?.keys == ["content", "hash"])
        #expect(o.shapes["cat-json-section"]?.stdout?.keys == ["content", "hash", "section"])
        #expect(o.shapes["cat-json-section"]?.stdout?["section"]?.keys == ["address", "offset", "length"])
        #expect(o.shapes["cat-json-range"]?.stdout?.keys == ["content"])

        // MCP: results duplicate the text in structuredContent; list/get/search shapes differ from the CLI's.
        func structured(_ name: String) -> AnyJSON? { o.shapes[name]?.response?["result"]?["structuredContent"] }
        #expect(structured("mcp-list_notes-limit-1")?.keys == ["metadata", "total"])
        #expect(structured("mcp-list_notes-content")?.keys == ["notes", "total"])
        #expect(structured("mcp-search_notes-e")?.keys == ["results", "total"])
        #expect(structured("mcp-get_note")?.keys == ["metadata"])
        #expect(structured("mcp-get_note-content")?.keys == ["content", "metadata"])
        #expect(structured("mcp-search_in_note")?["matches"]?.firstElement?["section"]?.keys == ["address", "offset", "length"])
        #expect(o.shapes["mcp-get_note"]?.response?["result"]?["content"]?.firstElement?["text"]?.keys == ["metadata"])
        #expect(o.shapes["mcp-get_note-bogus-id"]?.response?["result"]?["isError"] == .string("bool"))
        #expect(o.shapes["mcp-unknown-tool"]?.response?["error"]?["message"] == .string("unknown tool: no_such_tool"))
        #expect(o.shapes["mcp-malformed-json"]?.response?["id"] == .string("null"))
    }

    @Test func observedFixtureHasNoUUIDs() throws {
        let text = try String(contentsOf: fixtureURL("cli-observed.json"), encoding: .utf8)
        // Only the bogus placeholders may appear as ids; real note ids are 36-character UUIDs.
        let uuid = try Regex("[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
        #expect(text.firstMatch(of: uuid) == nil)
    }

    @Test func observedSortDefaultsAreRecorded() throws {
        let o = try ObservedFixture.load()
        let directions = o.facts["cliSortDefaultDirections"]
        #expect(directions == .object(["pinned": .string("desc"), "modified": .string("desc"), "created": .string("desc"), "title": .string("desc")]))
        #expect(o.facts["cliSortDefaultIsPinnedThenModified"] == .bool(true))
    }

    @Test func mcpToolListMatchesTheContractFile() throws {
        let o = try ObservedFixture.load()
        let contract = try Self.mcpContractTools()
        #expect(o.facts["mcpToolNames"]?.strings == contract.map(\.name))
        #expect(o.facts["mcpReadOnlyHintTools"]?.strings == contract.filter(\.readOnly).map(\.name))
    }
    struct MCPTool { let name: String; let readOnly: Bool }

    static func mcpContractTools() throws -> [MCPTool] {
        struct Contract: Decodable {
            struct Tool: Decodable { let name: String; let annotations: [String: Bool] }
            let tools: [Tool]
        }
        let url = repoRoot().appendingPathComponent("Fixtures/mcp/tool-schemas.json")
        return try JSONDecoder().decode(Contract.self, from: Data(contentsOf: url)).tools
            .map { MCPTool(name: $0.name, readOnly: $0.annotations["readOnlyHint"] == true) }
    }
}

private extension AnyJSON {
    var firstElement: AnyJSON? { if case .array(let a) = self { a.first } else { nil } }
}
