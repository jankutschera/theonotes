// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Synchronization
import Testing
@testable import TheoNotesAutomation
@testable import TheoNotesCore

/// The 28 tools against throw-away libraries: called directly (`MCPTools.call`) and, for the shapes
/// Bear's server was probed with, through `MCPServer` so keys come out sorted.
final class OpenCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = 0
    func bump() { lock.withLock { opened += 1 } }
    var count: Int { lock.withLock { opened } }
}

struct ToolFixture {
    let lib: TestLibrary
    let tools: MCPTools
    let opens: OpenCounter

    init(
        _ notes: [TestNote] = [], fetcher: (any URLFetcher)? = nil, scope: NoteScope = .unrestricted,
        privacyLock: Bool = false
    ) throws {
        lib = try TestLibrary.make(notes, privacyLock: privacyLock)
        let library = lib.library
        let opens = OpenCounter()
        self.opens = opens
        var context = AutomationContext.fixed(TestLibrary.epoch)
        if let fetcher { context.fetcher = fetcher }
        tools = MCPTools(
            libraryProvider: LibraryProvider { () throws(AutomationError) -> AutomationLibrary in
                opens.bump()
                return library
            }, context: context, scope: scope)
    }

    func call(_ name: String, _ arguments: String = "{}") async throws -> Result<JSONValue, AutomationError> {
        await tools.call(name, arguments: try JSONValue(parsing: Data(arguments.utf8)))
    }

    /// The result of a call that must succeed.
    func ok(_ name: String, _ arguments: String = "{}") async throws -> JSONValue {
        switch try await call(name, arguments) {
        case .success(let value): return value
        case .failure(let error):
            Issue.record("\(name) \(arguments) failed: \(error.code.rawValue) \(error.message)")
            return .null
        }
    }

    /// The error of a call that must fail.
    func fail(_ name: String, _ arguments: String = "{}") async throws -> AutomationError {
        switch try await call(name, arguments) {
        case .success(let value):
            Issue.record("\(name) \(arguments) succeeded: \(value.serialized(sortedKeys: true))")
            return AutomationError(code: .internal, message: "succeeded")
        case .failure(let error): return error
        }
    }
}

private func json(_ text: String) throws -> JSONValue { try JSONValue(parsing: Data(text.utf8)) }

/// Quotes `text` as a JSON string.
private func quoted(_ text: String) -> String { JSONValue.string(text).serialized(sortedKeys: true) }

/// The minimal JSON-schema subset the catalog's output schemas use: type, required, properties, items.
private func schemaProblems(_ value: JSONValue, _ schema: JSONValue, path: String = "$") -> [String] {
    var problems: [String] = []
    switch schema["type"]?.string {
    case "object":
        guard case .object = value else { return ["\(path): not an object"] }
        for name in schema["required"]?.array?.compactMap(\.string) ?? [] where value[name] == nil {
            problems.append("\(path): missing \(name)")
        }
        if case .object(let properties)? = schema["properties"] {
            for (name, sub) in properties {
                if let found = value[name] { problems += schemaProblems(found, sub, path: path + "." + name) }
            }
        }
    case "array":
        guard let items = value.array else { return ["\(path): not an array"] }
        if let sub = schema["items"] {
            for (index, item) in items.enumerated() { problems += schemaProblems(item, sub, path: "\(path)[\(index)]") }
        }
    case "string": if value.string == nil { problems.append("\(path): not a string") }
    case "integer": if case .int = value {} else { problems.append("\(path): not an integer") }
    case "boolean": if case .bool = value {} else { problems.append("\(path): not a boolean") }
    default: break
    }
    return problems
}

@Suite struct MCPToolsTests {
    static let alphaText = "# Alpha\n#work/x #multi word#\n- [ ] t\n- [x] d\nintro\n## B\nfoo bar\n## C\nbaz foo\n"

    // MARK: Brief tests

    @Test func everyCatalogToolIsHandled() async throws {
        let f = try ToolFixture([TestNote(text: Self.alphaText)])
        for name in MCPToolCatalog.toolNames where !name.hasPrefix("app_") {
            let result = await f.tools.call(name, arguments: .object([]))
            if case .failure(let error) = result { #expect(error.code != .internal, "\(name) not implemented") }
        }
    }

    @Test func structuredOutputsValidateAgainstOutputSchemas() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let f = try ToolFixture(
            [TestNote(text: Self.alphaText, pinned: true), TestNote(text: "# Tpl\n#template"), TestNote(text: "# Gone")],
            fetcher: StubFetcher(png, name: "pic.png"))
        let id = try f.lib.id(titled: "Alpha")
        let q = quoted(id)
        let gone = quoted(try f.lib.id(titled: "Gone"))
        let hash = try await f.ok("read_note_content", ###"{"id":\###(q)}"###)["hash"]?.string ?? ""
        let calls: [(String, String)] = [
            ("list_notes", "{}"), ("list_notes", ###"{"includeContent":true,"limit":1}"###), ("list_notes", ###"{"limit":0}"###),
            ("search_notes", ###"{"query":"foo"}"###), ("search_notes", ###"{"query":"foo","includeContent":true}"###),
            ("get_note", ###"{"id":\###(q)}"###), ("get_note", ###"{"id":\###(q),"includeContent":true}"###),
            ("read_note_content", ###"{"id":\###(q)}"###), ("read_note_content", ###"{"id":\###(q),"address":"## B"}"###),
            ("read_note_content", ###"{"id":\###(q),"offset":2,"limit":5}"###),
            ("read_note_outline", ###"{"id":\###(q)}"###), ("search_in_note", ###"{"id":\###(q),"string":"foo"}"###),
            ("list_pins", "{}"), ("list_pins", ###"{"id":\###(q)}"###), ("list_tags", "{}"), ("list_tags", ###"{"id":\###(q)}"###),
            ("list_attachments", ###"{"id":\###(q)}"###),
            ("create_note", ###"{"title":"New","content":"body","tags":["t1"]}"###),
            ("create_note_from_template", ###"{"template":"Tpl","title":"From tpl"}"###),
            ("append_to_note", ###"{"id":\###(q),"content":"more"}"###),
            ("append_to_note", ###"{"id":\###(q),"content":"sub","address":"## B"}"###),
            ("edit_note", ###"{"id":\###(q),"edits":[{"find":"baz","replace":"qux"}]}"###),
            ("add_pins", ###"{"id":\###(q),"targets":["work/x"]}"###), ("remove_pins", ###"{"id":\###(q),"targets":["work/x"]}"###),
            ("add_tags", ###"{"id":\###(q),"tags":["extra"]}"###), ("remove_tags", ###"{"id":\###(q),"tags":["extra"]}"###),
            ("rename_tag", ###"{"old":"extra2","new":"extra3"}"###), ("delete_tag", ###"{"tag":"nothing"}"###),
            ("add_attachment_from_url", ###"{"id":\###(q),"url":"https://example.com/pic.png"}"###),
            ("list_attachments", ###"{"id":\###(q)}"###),
            ("delete_attachment", ###"{"id":\###(q),"filename":"pic.png"}"###),
            ("archive_note", ###"{"id":\###(gone)}"###), ("restore_note", ###"{"id":\###(gone)}"###),
            ("trash_note", ###"{"id":\###(gone)}"###),
        ]
        var checked = 0
        for (name, arguments) in calls {
            let result = try await f.ok(name, arguments)
            let schema = try #require(MCPToolCatalog.tools.first { $0["name"]?.string == name }?["outputSchema"])
            let problems = schemaProblems(result, schema)
            #expect(problems.isEmpty, "\(name) \(arguments): \(problems)")
            checked += 1
        }
        // An overwrite needs the hash of the current text.
        let current = try await f.ok("read_note_content", ###"{"id":\###(q)}"###)
        let overwritten = try await f.ok(
            "overwrite_note",
            ###"{"id":\###(q),"content":"# Alpha\nnew","baseHash":\###(quoted(current["hash"]?.string ?? ""))}"###)
        let schema = try #require(MCPToolCatalog.tools.first { $0["name"]?.string == "overwrite_note" }?["outputSchema"])
        #expect(schemaProblems(overwritten, schema).isEmpty)
        #expect(!hash.isEmpty && checked == calls.count)
    }

    @Test func mcpMetadataUsesBareTagsAndBoolLocked() async throws {
        let f = try ToolFixture([TestNote(text: Self.alphaText, pinned: true)])
        let id = try f.lib.id(titled: "Alpha")
        let metadata = try #require(try await f.ok("get_note", ###"{"id":\###(quoted(id))}"###)["metadata"])
        #expect(metadata["tags"] == .array(["multi word", "work", "work/x"]))
        #expect(metadata["locked"] == .bool(false))
        #expect(metadata["pins"] == .array(["global"]))
        #expect(metadata["location"] == "notes" && metadata["todos"] == 1 && metadata["done"] == 1)
        #expect(metadata["created"] == "2026-01-02T03:04:05Z")
        #expect(try await f.ok("get_note", ###"{"id":\###(quoted(id))}"###)["content"] == nil)
        // A pin in a tag is the bare tag name.
        _ = try await f.ok("add_pins", ###"{"id":\###(quoted(id)),"targets":["work/x"]}"###)
        #expect(try await f.ok("list_pins", ###"{"id":\###(quoted(id))}"###)["pins"] == .array(["global", "work/x"]))
        #expect(try await f.ok("list_pins")["pins"] == .array(["global", "work/x"]))
    }

    @Test func overwriteRequiresBaseHashAndGateUsesExpectedRemovedAttachments() async throws {
        let f = try ToolFixture([TestNote(text: "# T\nbody\n")])
        let id = try f.lib.firstId()
        let q = quoted(id)
        let service = AutomationService(library: f.lib.library, context: .fixed(TestLibrary.epoch))
        _ = try service.addAttachment(.id(id), data: Data([1, 2]), filename: "pic.png", preservingModifiedDate: false)
        let before = try f.lib.text(id)
        #expect(before.contains("pic.png"))

        // The schema requires baseHash (ruling M5-R29's wording).
        let missing = try await f.fail("overwrite_note", ###"{"id":\###(q),"content":"x"}"###)
        #expect(missing.code == .usage && missing.message == "missing required field: baseHash")

        let hash = try #require(try await f.ok("read_note_content", ###"{"id":\###(q)}"###)["hash"]?.string)
        // Dropping the link without declaring it is refused, and nothing is written.
        let refused = try await f.fail("overwrite_note", ###"{"id":\###(q),"content":"# T\nbody\n","baseHash":\###(quoted(hash))}"###)
        #expect(refused.code == .attachmentsRemoved)
        #expect(refused.details?["removed"] == .array(["pic.png"]))
        #expect(try f.lib.text(id) == before)
        // Declaring something else, or something that is not removed, is refused as well.
        let wrong = try await f.fail(
            "overwrite_note",
            ###"{"id":\###(q),"content":"# T\nbody\n","baseHash":\###(quoted(hash)),"expectedRemovedAttachments":["other.png"]}"###)
        #expect(wrong.code == .attachmentsRemoved)
        let nothing = try await f.fail(
            "overwrite_note",
            ###"{"id":\###(q),"content":"\###(before.replacingOccurrences(of: "\n", with: "\\n"))","baseHash":\###(quoted(hash)),"expectedRemovedAttachments":["pic.png"]}"###)
        #expect(nothing.code == .attachmentsRemoved)
        #expect(nothing.message == "No attachment would be dropped, but expectedRemovedAttachments names: pic.png.")
        // A stale hash is refused with the current one.
        let stale = try await f.fail("overwrite_note", ###"{"id":\###(q),"content":"# T","baseHash":"0000000"}"###)
        #expect(stale.code == .staleHash && stale.details?["hash"]?.string == hash)

        let done = try await f.ok(
            "overwrite_note",
            ###"{"id":\###(q),"content":"# T\nbody\n","baseHash":\###(quoted(hash)),"expectedRemovedAttachments":["pic.png"]}"###)
        #expect(done["changedMetadata"]?["attachments"] == .array([]))
        #expect(done["section"] == nil)
        #expect(try f.lib.text(id) == "# T\nbody\n")
    }

    @Test func editNoteReportsOpsWithSections() async throws {
        let f = try ToolFixture([TestNote(text: Self.alphaText)])
        let id = try f.lib.id(titled: "Alpha")
        let q = quoted(id)
        let result = try await f.ok(
            "edit_note",
            ###"{"id":\###(q),"edits":[{"find":"bar","replace":"BAR"},{"find":"baz","insertAfter":"!"},{"find":"intro","delete":true}]}"###)
        let ops = try #require(result["ops"]?.array)
        #expect(ops.count == 3)
        #expect(ops[0]["index"] == 0 && ops[0]["section"]?["address"] == "## B")
        #expect(ops[1]["index"] == 1 && ops[1]["section"]?["address"] == "## C")
        #expect(ops[2]["index"] == 2 && ops[2]["section"]?["address"]?.string?.hasPrefix("# Alpha") == true)
        #expect(ops[0]["section"]?.keys.sorted() == ["address", "length", "offset"])
        #expect(result["changedMetadata"]?["length"] != nil)
        let edited = try f.lib.text(id)
        #expect(edited.contains("foo BAR") && edited.contains("baz!"))
        // Confined to a section, a find that recurs elsewhere resolves in that section only.
        _ = try await f.ok("edit_note", ###"{"id":\###(q),"address":"## C","edits":[{"find":"foo","replace":"F"}]}"###)
        let confined = try f.lib.text(id)
        #expect(confined.contains("## B\nfoo BAR") && confined.contains("baz! F"))
        // One miss writes nothing.
        let text = try f.lib.text(id)
        let miss = try await f.fail("edit_note", ###"{"id":\###(q),"edits":[{"find":"F","replace":"G"},{"find":"nothing here","delete":true}]}"###)
        #expect(miss.code != .internal && miss.code != .busy)
        #expect(try f.lib.text(id) == text)
        // Each edit has exactly one action; an empty list is a usage error (ruling M5-R93).
        let none = try await f.fail("edit_note", ###"{"id":\###(q),"edits":[]}"###)
        #expect(none.code == .usage && none.message == "At least one edit is required")
        let two = try await f.fail("edit_note", ###"{"id":\###(q),"edits":[{"find":"a","replace":"b","delete":true}]}"###)
        #expect(two.code == .usage && two.message.hasPrefix("edits[0] needs exactly one of"))
        let noFind = try await f.fail("edit_note", ###"{"id":\###(q),"edits":[{"replace":"b"}]}"###)
        #expect(noFind.message == "missing required field: edits[0].find")
        let noAction = try await f.fail("edit_note", ###"{"id":\###(q),"edits":[{"find":"a","delete":false}]}"###)
        #expect(noAction.code == .usage)
    }

    @Test func errorsComeBackAsToolErrors() async throws {
        let f = try ToolFixture([TestNote(text: Self.alphaText)])
        let unknown = try await f.fail("get_note", ###"{"id":"ZZZ-NOPE"}"###)
        #expect(unknown.code == .noteNotFound && unknown.message == "Note not found: ZZZ-NOPE")
        let none = try await f.fail("get_note")
        #expect(none.code == .usage && none.message == "Note ID or title is required")
        let both = try await f.fail("get_note", ###"{"id":"a","title":"b"}"###)
        #expect(both.message == "Provide note ID or title, not both")
        let location = try await f.fail("list_notes", ###"{"location":"bogus"}"###)
        #expect(location.code == .usage && location.message == "Invalid location: bogus")
        let title = try await f.fail("get_note", ###"{"title":"ZZZ NOPE TITLE"}"###)
        #expect(title.message == "No active note has the title ZZZ NOPE TITLE. Trashed and archived notes can only be named by ID.")
        // Wrong types and negative numbers.
        #expect(try await f.fail("list_notes", ###"{"limit":"3"}"###).message == "Invalid value for limit")
        #expect(try await f.fail("list_notes", ###"{"limit":1.5}"###).message == "Invalid value for limit")
        #expect(try await f.fail("list_notes", ###"{"limit":-1}"###).message == "Limit must be non-negative")
        #expect(try await f.fail("list_notes", ###"{"offset":-1}"###).message == "Offset must be non-negative")
        #expect(try await f.fail("list_notes", ###"{"includeContent":"yes"}"###).message == "Invalid value for includeContent")
        #expect(try await f.fail("add_tags", ###"{"id":"x","tags":"a"}"###).message == "Invalid value for tags")
        #expect(try await f.fail("add_tags", ###"{"id":"x","tags":[1]}"###).message == "Invalid value for tags")
        #expect(try await f.fail("search_notes", "{}").message == "missing required field: query")
        #expect(try await f.fail("search_notes", ###"{"query":""}"###).message == "Query is required")
        // Unknown arguments are ignored; whole numbers written as 1.0 or 1e0 are accepted.
        #expect(try await f.ok("list_notes", ###"{"bogus_property":1,"limit":1.0}"###)["total"] == 1)
        #expect(try await f.fail("append_to_note", ###"{"id":"x","content":"y","position":"middle"}"###).message
            == "Invalid position: middle (use beginning or end)")
    }

    // MARK: capture_thought (FOC-R14)

    private static func noteCount(_ f: ToolFixture) throws -> Int {
        try f.lib.library.database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note") ?? 0 }
    }

    /// Spec 9, bullet 7: the text is stored as given, tagged `mcp`, with no model, no network and no title,
    /// tag or other edit of ours. The result has `create_note`'s shape.
    @Test func captureThoughtStoresTheTextUnchanged() async throws {
        let stub = StubFetcher(Data([1]), name: "x.png")
        let f = try ToolFixture([TestNote(text: "# Other\nbody")], fetcher: stub)
        let text = "  buy oat milk, call Ana \u{2014} \u{1F600}\t\n\n  indented line  \n#loose-tag trailing \n\n\n"
        let made = try await f.ok("capture_thought", ###"{"text":\###(quoted(text))}"###)
        let id = try #require(made["id"]?.string)
        #expect(try f.lib.text(id) == text)
        #expect(made["content"] == .string(text))
        #expect(made.keys.sorted() == ["attachments", "content", "created", "done", "id", "length", "location", "locked", "modified", "pins", "tags", "title", "todos"])
        #expect(made["tags"] == .array(["loose-tag"]) && made["location"] == "notes" && made["locked"] == .bool(false))
        let schema = try #require(MCPToolCatalog.tools.first { $0["name"] == "create_note" }?["outputSchema"])
        #expect(schemaProblems(made, schema).isEmpty)
        #expect(try f.lib.library.store.captureSource(noteId: id) == .mcp)
        #expect(try f.lib.library.store.captureSource(noteId: try f.lib.id(titled: "Other")) == nil)
        #expect(try Self.noteCount(f) == 2)
        #expect(try f.lib.text(try f.lib.id(titled: "Other")) == "# Other\nbody")
        // The first line becomes the title; a single line is a note of its own.
        let one = try await f.ok("capture_thought", ###"{"text":"Ring the dentist"}"###)
        #expect(one["title"] == "Ring the dentist" && one["tags"] == .array([]))
        #expect(try f.lib.text(try #require(one["id"]?.string)) == "Ring the dentist")
        // Nothing went out: the fetcher was never asked.
        #expect(stub.urls.isEmpty)
    }

    /// FOC-R170: "exactly as given" means no trimming, titling or rewriting of the words. The one change is
    /// the store's own, the same for every note: CRLF and a lone CR become LF.
    @Test func captureThoughtNormalisesLineEndingsAndNothingElse() async throws {
        let f = try ToolFixture([])
        let cases: [(given: String, stored: String)] = [
            ("one\r\ntwo\r\n\r\nthree", "one\ntwo\n\nthree"),
            ("one\rtwo\r\rthree", "one\ntwo\n\nthree"),
            ("mixed\r\na\rb\nc", "mixed\na\nb\nc"),
            ("  \n\n  lead and trail \t \n\n\u{00E9}\u{1F600} \u{0301}\n\n", "  \n\n  lead and trail \t \n\n\u{00E9}\u{1F600} \u{0301}\n\n"),
        ]
        for (given, stored) in cases {
            let made = try await f.ok("capture_thought", ###"{"text":\###(quoted(given))}"###)
            let id = try #require(made["id"]?.string)
            #expect(try f.lib.text(id) == stored, "\(quoted(given))")
            #expect(made["content"] == .string(stored), "\(quoted(given))")
        }
    }

    @Test func captureThoughtRejectsEmptyText() async throws {
        let f = try ToolFixture([TestNote(text: "# Other")])
        for text in ["", " ", "\n\t \r\n"] {
            let error = try await f.fail("capture_thought", ###"{"text":\###(quoted(text))}"###)
            #expect(error.code == .usage && error.message == "text must not be empty", "\(quoted(text))")
        }
        #expect(try await f.fail("capture_thought", "{}").message == "missing required field: text")
        #expect(try await f.fail("capture_thought", ###"{"text":null}"###).message == "missing required field: text")
        #expect(try await f.fail("capture_thought", ###"{"text":5}"###).message == "Invalid value for text")
        #expect(try Self.noteCount(f) == 1)
    }

    /// The schema says `additionalProperties: false`, and a dropped `tags` or `title` would be a silent
    /// loss, so unlike the 26 tools this one refuses a field it does not take.
    @Test func captureThoughtRejectsUnknownFields() async throws {
        let f = try ToolFixture([TestNote(text: "# Other")])
        let tags = try await f.fail("capture_thought", ###"{"text":"x","tags":["a"]}"###)
        #expect(tags.code == .usage && tags.message == "Unknown field: tags")
        #expect(try await f.fail("capture_thought", ###"{"text":"x","title":"T","content":"c"}"###).message == "Unknown field: title")
        #expect(try await f.fail("capture_thought", ###"{"bogus":1}"###).message == "missing required field: text")
        #expect(try Self.noteCount(f) == 1)
        _ = try await f.ok("capture_thought", ###"{"text":"x"}"###)
        #expect(try Self.noteCount(f) == 2)
    }

    @Test func createNoteFromTemplateFillsTitle() async throws {
        let f = try ToolFixture([
            TestNote(text: "# {{title}}\nMeeting on {{date}}\n#template"), TestNote(text: "# Plain"),
            TestNote(text: "# Secret\n#template", locked: true),
        ])
        let made = try await f.ok("create_note_from_template", ###"{"template":"{{title}}","title":"Standup","tags":["team"]}"###)
        #expect(made["title"] == "Standup" && made["content"]?.string?.hasPrefix("# Standup\nMeeting on ") == true)
        #expect(made["tags"] == .array(["team"]))
        #expect(made["locked"] == .bool(false) && made["location"] == "notes")
        #expect(made.keys.sorted() == ["attachments", "content", "created", "done", "id", "length", "location", "locked", "modified", "pins", "tags", "title", "todos"])
        let id = try #require(made["id"]?.string)
        #expect(try f.lib.text(id) == made["content"]?.string)
        // By id, and a missing, locked or non-template note is an error.
        let templateId = try f.lib.firstId()
        let byId = try await f.ok("create_note_from_template", ###"{"template":\###(quoted(templateId)),"title":"Retro"}"###)
        #expect(byId["title"] == "Retro")
        let missing = try await f.fail("create_note_from_template", ###"{"template":"Nope"}"###)
        #expect(missing.code == .noteNotFound && missing.message == "No template with title: Nope")
        #expect(try await f.fail("create_note_from_template", ###"{"template":"Plain"}"###).code == .noteNotFound)
        #expect(try await f.fail("create_note_from_template", ###"{"template":"Secret"}"###).code == .noteLocked)
        #expect(try await f.fail("create_note_from_template", "{}").message == "missing required field: template")
        #expect(try await f.fail("create_note_from_template", ###"{"template":"Plain","tags":[" "]}"###).code == .usage)
    }

    // MARK: Reads

    @Test func listAndSearchShapesAndLimits() async throws {
        let f = try ToolFixture([
            TestNote(text: "# One\nfoo foo", pinned: true), TestNote(text: "# Two\nfoo"), TestNote(text: "# Locked", locked: true),
            TestNote(text: "# Old\nfoo", location: .archive),
        ])
        let all = try await f.ok("list_notes")
        #expect(all.keys == ["metadata", "total"] && all["total"] == 3 && all["metadata"]?.array?.count == 3)
        #expect(all["metadata"]?.array?.first?["title"] == "One")
        let zero = try await f.ok("list_notes", ###"{"limit":0}"###)
        #expect(zero == .object([("metadata", .array([])), ("total", 3)]))
        let paged = try await f.ok("list_notes", ###"{"limit":1,"offset":1,"sort":"title:asc"}"###)
        #expect(paged["metadata"]?.array?.count == 1 && paged["total"] == 3)
        // Content: the locked note is left out of `notes` but still counted.
        let withContent = try await f.ok("list_notes", ###"{"includeContent":true}"###)
        #expect(withContent.keys == ["notes", "total"] && withContent["total"] == 3)
        #expect(withContent["notes"]?.array?.count == 2)
        #expect(withContent["notes"]?.array?.first?.keys == ["content", "metadata"])
        #expect(try await f.ok("list_notes", ###"{"location":"all"}"###)["total"] == 4)
        #expect(try await f.ok("list_notes", ###"{"location":"archive"}"###)["total"] == 1)
        #expect(try await f.ok("list_notes", ###"{"tag":"nothing"}"###)["total"] == 0)

        let found = try await f.ok("search_notes", ###"{"query":"foo"}"###)
        #expect(found.keys == ["results", "total"] && found["total"] == 2)
        let first = try #require(found["results"]?.array?.first)
        #expect(first.keys == ["matchCount", "metadata"] && first["matchCount"] == 2 && first["metadata"]?["title"] == "One")
        let none = try await f.ok("search_notes", ###"{"query":"zzqq-nohit"}"###)
        #expect(none == .object([("results", .array([])), ("total", 0)]))
        let content = try await f.ok("search_notes", ###"{"query":"foo","includeContent":true,"limit":1}"###)
        #expect(content.keys == ["resultsWithContent", "total"] && content["total"] == 2)
        let hit = try #require(content["resultsWithContent"]?.array?.first)
        #expect(hit.keys == ["matchCount", "note"] && hit["note"]?.keys == ["content", "metadata"])
        #expect(try await f.ok("search_notes", ###"{"query":"foo","limit":0}"###) == .object([("results", .array([])), ("total", 2)]))
        #expect(try await f.ok("search_notes", ###"{"query":"foo","location":"archive"}"###)["total"] == 1)
    }

    @Test func getNoteAndLockedNotes() async throws {
        let f = try ToolFixture([TestNote(text: "# Secret\nhidden #t", locked: true), TestNote(text: "# Open\nbody")])
        let locked = try f.lib.id(titled: "Secret")
        let plain = try await f.ok("get_note", ###"{"id":\###(quoted(locked))}"###)
        #expect(plain["metadata"]?["locked"] == .bool(true) && plain["metadata"]?["length"] == 0)
        let refused = try await f.fail("get_note", ###"{"id":\###(quoted(locked)),"includeContent":true}"###)
        #expect(refused.code == .noteLocked && refused.message == "Note is locked: \(locked)")
        #expect(try await f.fail("read_note_content", ###"{"id":\###(quoted(locked))}"###).code == .noteLocked)
        #expect(try await f.fail("read_note_outline", ###"{"id":\###(quoted(locked))}"###).code == .noteLocked)
        #expect(try await f.fail("search_in_note", ###"{"id":\###(quoted(locked)),"string":"x"}"###).code == .noteLocked)
        #expect(try await f.fail("append_to_note", ###"{"id":\###(quoted(locked)),"content":"x"}"###).code == .noteLocked)
        #expect(try await f.fail("add_tags", ###"{"id":\###(quoted(locked)),"tags":["x"]}"###).code == .noteLocked)
        let open = try await f.ok("get_note", ###"{"title":"open","includeContent":true}"###)
        #expect(open["content"] == "# Open\nbody" && open.keys.sorted() == ["content", "metadata"])
    }

    @Test func contentOutlineAndSearchInNote() async throws {
        let text = "# A\nlead\n## Same\none\n## Same\ntwo foo\n"
        let f = try ToolFixture([TestNote(text: text)])
        let id = try f.lib.firstId()
        let q = quoted(id)
        let whole = try await f.ok("read_note_content", ###"{"id":\###(q)}"###)
        #expect(whole.keys == ["content", "hash"] && whole["content"]?.string == text)
        #expect(whole["hash"]?.string == ContentHash.of(text))
        let slice = try await f.ok("read_note_content", ###"{"id":\###(q),"offset":2,"limit":4}"###)
        #expect(slice == .object([("content", "A\nle")]))
        let outline = try await f.ok("read_note_outline", ###"{"id":\###(q)}"###)
        let entries = try #require(outline["outline"]?.array)
        #expect(outline.keys == ["outline"] && entries.first?.keys.sorted() == ["address", "length", "offset"])
        #expect(entries.first?["address"] == "# A" && entries.first?["offset"] == 0)
        // A section by address: its text, its address and a hash of just its bytes.
        let sames = entries.compactMap { $0["address"]?.string }.filter { $0.contains("Same") && !$0.hasSuffix("preamble") }
        #expect(sames.count == 2)
        let second = try #require(sames.last)
        let secondArg = quoted(second)
        let firstArg = quoted(try #require(sames.first))
        let section = try await f.ok("read_note_content", ###"{"id":\###(q),"address":\###(secondArg)}"###)
        #expect(section["content"] == "## Same\ntwo foo\n")
        #expect(section["hash"]?.string == ContentHash.of("## Same\ntwo foo\n"))
        #expect(section["section"]?["offset"] == .int(text.utf8.count - 16) && section["section"]?["length"] == 16)
        // Ambiguous and missing addresses.
        let ambiguous = try await f.fail("read_note_content", ###"{"id":\###(q),"address":"## Same"}"###)
        #expect(ambiguous.code == .ambiguous)
        #expect(ambiguous.message == "2 sections match that address; repeat the call with one of the candidates.")
        #expect(ambiguous.details?["candidates"]?.array?.first?.keys == ["address", "offset", "length", "snippet"])
        let absent = try await f.fail("read_note_outline", ###"{"id":\###(q),"address":"## Nope"}"###)
        #expect(absent.code == .notFound && absent.message == "No section matched the address.")
        #expect(try await f.fail("read_note_content", ###"{"id":\###(q),"address":"# A","limit":3}"###).message
            == "Provide address or offset/limit, not both")
        // Review: the conflict wins over an invalid slice value.
        #expect(try await f.fail("read_note_content", ###"{"id":\###(q),"address":"# A","offset":-1}"###).message
            == "Provide address or offset/limit, not both")
        #expect(try await f.ok("read_note_outline", ###"{"id":\###(q),"address":\###(firstArg)}"###)["outline"]?.array?.count == 1)

        let hits = try await f.ok("search_in_note", ###"{"id":\###(q),"string":"FOO","context":6}"###)
        let match = try #require(hits["matches"]?.array?.first)
        #expect(match.keys.sorted() == ["offset", "section", "snippet", "source"])
        #expect(match["source"] == "body" && match["snippet"] == "wo foo\\n")
        #expect(match["section"]?["address"]?.string == second)
        #expect(try await f.ok("search_in_note", ###"{"id":\###(q),"string":"foo","limit":0}"###) == .object([("matches", .array([]))]))
        #expect(try await f.ok("search_in_note", ###"{"id":\###(q),"string":""}"###) == .object([("matches", .array([]))]))
        #expect(try await f.ok("search_in_note", ###"{"id":\###(q),"string":"foo","address":\###(firstArg)}"###)["matches"]?.array?.isEmpty == true)
        // A hit above the first heading lies in the lead, addressed `preamble` (M5-R233).
        let g = try ToolFixture([TestNote(text: "lead foo\n# H\nx")])
        let early = try await g.ok("search_in_note", ###"{"id":\###(quoted(try g.lib.firstId())),"string":"foo"}"###)
        #expect(early["matches"]?.array?.first?["section"]?["address"]?.string == "preamble")
    }

    @Test func tagsPinsAndAttachmentLists() async throws {
        let f = try ToolFixture([
            TestNote(text: "# One\n#b/c #a", pinned: true), TestNote(text: "# Two\n#z\n#archived", location: .archive),
        ])
        let id = try f.lib.id(titled: "One")
        #expect(try await f.ok("list_tags")["tags"] == .array(["a", "b", "b/c"]))
        #expect(try await f.ok("list_tags", ###"{"id":\###(quoted(id))}"###)["tags"] == .array(["a", "b", "b/c"]))
        #expect(try await f.ok("list_pins")["pins"] == .array(["global"]))
        #expect(try await f.ok("list_attachments", ###"{"id":\###(quoted(id))}"###) == .object([("attachments", .array([]))]))
        #expect(try await f.fail("list_tags", ###"{"id":"ZZZ-NOPE"}"###).code == .noteNotFound)
        #expect(try await f.fail("list_pins", ###"{"id":"ZZZ-NOPE"}"###).code == .noteNotFound)
        #expect(try await f.fail("list_attachments", ###"{"id":"ZZZ-NOPE"}"###).code == .noteNotFound)
        #expect(try await f.fail("list_attachments", "{}").message == "Note ID or title is required")
    }

    // MARK: Writes

    @Test func createNote() async throws {
        let f = try ToolFixture([TestNote(text: "# Existing\nold")])
        let made = try await f.ok("create_note", ###"{"title":"Fresh","content":"body","tags":["#a","b c"]}"###)
        #expect(made["title"] == "Fresh" && made["tags"] == .array(["a", "b c"]))
        #expect(made["content"]?.string?.hasPrefix("# Fresh\nbody") == true)
        let id = try #require(made["id"]?.string)
        #expect(try f.lib.text(id) == made["content"]?.string)
        // ifNotExists returns the existing note untouched.
        let again = try await f.ok("create_note", ###"{"title":"existing","ifNotExists":true}"###)
        #expect(again["title"] == "Existing" && again["content"] == "# Existing\nold")
        #expect(try await f.fail("create_note", ###"{"ifNotExists":true}"###).message == "--if-not-exists requires a title")
        #expect(try await f.fail("create_note", ###"{"tags":[" "]}"###).code == .usage)
        let empty = try await f.ok("create_note")
        #expect(empty["id"]?.string != nil)
    }

    @Test func appendAndOverwriteReturnChangedMetadataAndSections() async throws {
        let f = try ToolFixture([TestNote(text: "# T\nbody\n## S\nin s\n")])
        let id = try f.lib.firstId()
        let q = quoted(id)
        let appended = try await f.ok("append_to_note", ###"{"id":\###(q),"content":"tail #new"}"###)
        #expect(appended.keys == ["changedMetadata"])
        let changed = try #require(appended["changedMetadata"])
        #expect(changed["tags"] == .array(["new"]) && changed["length"] != nil && changed["id"] == nil)
        let sectioned = try await f.ok("append_to_note", ###"{"id":\###(q),"content":"more","address":"## S","position":"beginning"}"###)
        #expect(sectioned["section"]?["address"] == "## S")
        #expect(try f.lib.text(id).contains("## S\nmore\nin s"))
        // Content is required; an explicit empty string is a valid append.
        #expect(try await f.fail("append_to_note", ###"{"id":\###(q)}"###).message == "missing required field: content")
        let empty = try await f.ok("append_to_note", ###"{"id":\###(q),"content":""}"###)
        #expect(empty["changedMetadata"]?.keys.contains("tags") == false)

        let hash = try #require(try await f.ok("read_note_content", ###"{"id":\###(q),"address":"## S"}"###)["hash"]?.string)
        let over = try await f.ok(
            "overwrite_note", ###"{"id":\###(q),"address":"## S","content":"## S\nreplaced\n","baseHash":\###(quoted(hash))}"###)
        #expect(over["section"]?["address"] == "## S")
        #expect(try f.lib.text(id).contains("## S\nreplaced\n"))
        // A hash can only come from a read: the section hash no longer fits after the change.
        #expect(try await f.fail("overwrite_note", ###"{"id":\###(q),"address":"## S","content":"## S\nx","baseHash":\###(quoted(hash))}"###).code == .staleHash)
        // Deleting a section with empty content returns no section.
        let freshHash = try #require(try await f.ok("read_note_content", ###"{"id":\###(q),"address":"## S"}"###)["hash"]?.string)
        let deleted = try await f.ok("overwrite_note", ###"{"id":\###(q),"address":"## S","content":"","baseHash":\###(quoted(freshHash))}"###)
        #expect(deleted["section"] == nil)
        let afterDelete = try f.lib.text(id)
        #expect(!afterDelete.contains("## S"))
    }

    @Test func pinsTagsAndLocationReturnOnlyWhatChanged() async throws {
        let f = try ToolFixture([TestNote(text: "# T\n#work")])
        let id = try f.lib.firstId()
        let q = quoted(id)
        let pinned = try await f.ok("add_pins", ###"{"id":\###(q),"targets":["global","work"]}"###)
        #expect(pinned == .object([("pins", .array(["global", "work"]))]))
        let again = try await f.ok("add_pins", ###"{"id":\###(q),"targets":["global"]}"###)
        #expect(again == .object([]))
        #expect(try await f.ok("remove_pins", ###"{"id":\###(q),"targets":["global"]}"###) == .object([("pins", .array(["work"]))]))
        #expect(try await f.fail("add_pins", ###"{"id":\###(q),"targets":["nope"]}"###).code == .tagNotFound)
        #expect(try await f.fail("add_pins", ###"{"id":\###(q),"targets":[]}"###).code == .usage)

        let tagged = try await f.ok("add_tags", ###"{"id":\###(q),"tags":["#x","y/z"]}"###)
        #expect(tagged["tags"] == .array(["work", "x", "y", "y/z"]) && tagged.keys.contains("length"))
        let removed = try await f.ok("remove_tags", ###"{"id":\###(q),"tags":["x"]}"###)
        #expect(removed["tags"] == .array(["work", "y", "y/z"]))
        #expect(try await f.fail("add_tags", ###"{"id":\###(q),"tags":[]}"###).message == "At least one tag is required")

        let archived = try await f.ok("archive_note", ###"{"id":\###(q)}"###)
        #expect(archived["location"] == "archive")
        #expect(try await f.ok("archive_note", ###"{"id":\###(q)}"###) == .object([]))
        #expect(try await f.ok("trash_note", ###"{"id":\###(q)}"###)["location"] == "trash")
        #expect(try await f.ok("restore_note", ###"{"id":\###(q)}"###)["location"] == "notes")
        // Reachable by title only while in Notes.
        _ = try await f.ok("trash_note", ###"{"id":\###(q)}"###)
        #expect(try await f.fail("restore_note", ###"{"title":"T"}"###).code == .noteNotFound)
    }

    @Test func renameAndDeleteTagReportNotesUpdated() async throws {
        let f = try ToolFixture([TestNote(text: "# A\n#old"), TestNote(text: "# B\n#old/child"), TestNote(text: "# C\n#keep")])
        #expect(try await f.ok("rename_tag", ###"{"old":"old","new":"fresh"}"###) == .object([("notesUpdated", 2)]))
        #expect(try await f.ok("list_tags")["tags"] == .array(["fresh", "fresh/child", "keep"]))
        let exists = try await f.fail("rename_tag", ###"{"old":"fresh","new":"keep"}"###)
        #expect(exists.code == .tagExists)
        #expect(try await f.ok("rename_tag", ###"{"old":"fresh","new":"keep","force":true}"###)["notesUpdated"] == 2)
        #expect(try await f.ok("rename_tag", ###"{"old":"missing","new":"other"}"###) == .object([("notesUpdated", 0)]))
        #expect(try await f.fail("rename_tag", ###"{"old":"a","new":"a/b"}"###).code == .usage)
        #expect(try await f.fail("rename_tag", ###"{"old":"a"}"###).message == "missing required field: new")
        #expect(try await f.ok("delete_tag", ###"{"tag":"keep"}"###)["notesUpdated"] == 3)
        #expect(try await f.ok("delete_tag", ###"{"tag":"keep"}"###) == .object([("notesUpdated", 0)]))
        #expect(try await f.fail("delete_tag", ###"{"tag":" # "}"###).code == .usage)
    }

    // MARK: Attachments

    @Test func addAttachmentFromURLRefusesAnOverlongURLBeforeFetching() async throws {
        let stub = StubFetcher(Data([1]), name: "x.png")
        let f = try ToolFixture([TestNote(text: "# T\nbody")], fetcher: stub)
        let long = "https://example.com/?q=" + String(repeating: "a", count: 2048)
        let error = try await f.fail("add_attachment_from_url", ###"{"title":"T","url":"\###(long)"}"###)
        #expect(error.code == .invalidURL && error.message == "The URL is longer than 2048 bytes (in its encoded form)")
        #expect(stub.urls.isEmpty)
        #expect(try f.lib.text(try f.lib.id(titled: "T")) == "# T\nbody")
    }

    @Test func addAttachmentFromURLUsesTheInjectedFetcherAndMapsErrors() async throws {
        let stub = StubFetcher(Data([1, 2, 3]), name: "from-server.png")
        let f = try ToolFixture([TestNote(text: "# T\nbody"), TestNote(text: "# Locked", locked: true)], fetcher: stub)
        let id = try f.lib.id(titled: "T")
        let q = quoted(id)
        let added = try await f.ok("add_attachment_from_url", ###"{"id":\###(q),"url":"https://example.com/a/b.png"}"###)
        #expect(added["attachments"] == .array(["from-server.png"]) && added["length"] != nil)
        #expect(stub.urls.map(\.absoluteString) == ["https://example.com/a/b.png"])
        #expect(try f.lib.text(id).contains("from-server.png"))
        let listed = try await f.ok("list_attachments", ###"{"id":\###(q)}"###)
        #expect(listed == .object([("attachments", .array([.object([("filename", "from-server.png"), ("size", 3)])]))]))
        let named = try await f.ok("add_attachment_from_url", ###"{"title":"T","url":"https://example.com/x","filename":"mine.bin"}"###)
        #expect(named["attachments"] == .array(["from-server.png", "mine.bin"]))

        // Arguments are checked before anything is fetched or the library is opened.
        let before = stub.urls.count
        let http = try await f.fail("add_attachment_from_url", ###"{"id":\###(q),"url":"http://example.com/x"}"###)
        #expect(http.code == .usage && http.message == "Only https:// URLs are supported")
        #expect(try await f.fail("add_attachment_from_url", ###"{"id":\###(q),"url":"https://localhost/x"}"###).code == .invalidURL)
        #expect(try await f.fail("add_attachment_from_url", ###"{"id":\###(q),"url":"https://127.0.0.1/x"}"###).code == .invalidURL)
        #expect(try await f.fail("add_attachment_from_url", ###"{"id":\###(q),"url":"nonsense"}"###).code == .invalidURL)
        #expect(try await f.fail("add_attachment_from_url", ###"{"id":\###(q),"url":"  "}"###).message == "missing required field: url")
        #expect(try await f.fail("add_attachment_from_url", ###"{"url":"https://example.com/x"}"###).message == "Note ID or title is required")
        let locked = try await f.fail("add_attachment_from_url", ###"{"title":"Locked","url":"https://example.com/x"}"###)
        #expect(locked.code == .noteLocked)
        #expect(stub.urls.count == before)

        let failing = try ToolFixture([TestNote(text: "# T")], fetcher: StubFetcher(failing: URLError(.timedOut)))
        let timedOut = try await failing.fail("add_attachment_from_url", ###"{"title":"T","url":"https://example.com/x"}"###)
        #expect(timedOut.code == .fetchFailed && timedOut.message.hasPrefix("Could not fetch the URL ("))
        let denied = try ToolFixture(
            [TestNote(text: "# T")],
            fetcher: StubFetcher(failing: AutomationError(code: .fetchFailed, message: "Could not fetch the URL (HTTP 404)")))
        #expect(try await denied.fail("add_attachment_from_url", ###"{"title":"T","url":"https://example.com/x"}"###).message
            == "Could not fetch the URL (HTTP 404)")
    }

    @Test func deleteAttachmentTakesTheLinkOut() async throws {
        let f = try ToolFixture([TestNote(text: "# T\nbody")], fetcher: StubFetcher(Data([7]), name: "p.png"))
        let id = try f.lib.firstId()
        let q = quoted(id)
        _ = try await f.ok("add_attachment_from_url", ###"{"id":\###(q),"url":"https://example.com/p.png"}"###)
        let removed = try await f.ok("delete_attachment", ###"{"id":\###(q),"filename":"p.png"}"###)
        #expect(removed["attachments"] == .array([]))
        let again = try await f.fail("delete_attachment", ###"{"id":\###(q),"filename":"p.png"}"###)
        #expect(again.code == .attachmentNotFound && again.message == "Attachment not found: p.png")
        #expect(try await f.fail("delete_attachment", ###"{"id":\###(q)}"###).message == "missing required field: filename")
    }

    // MARK: Library handling (rulings M5-R45, M5-R72)

    @Test func argumentsAreCheckedBeforeTheLibraryOpens() async throws {
        final class Counter: @unchecked Sendable { var opens = 0 }
        let counter = Counter()
        let tools = MCPTools(
            libraryProvider: LibraryProvider { () throws(AutomationError) -> AutomationLibrary in
                counter.opens += 1
                throw AutomationError(code: .libraryUnavailable, message: "nope")
            }, context: .fixed(TestLibrary.epoch), scope: .unrestricted)
        func fail(_ name: String, _ arguments: String) async throws -> AutomationError {
            guard case .failure(let error) = await tools.call(name, arguments: try json(arguments)) else {
                Issue.record("\(name) succeeded")
                return AutomationError(code: .internal, message: "")
            }
            return error
        }
        let usage: [(String, String, String)] = [
            ("get_note", "{}", "Note ID or title is required"),
            ("list_notes", ###"{"location":"bogus"}"###, "Invalid location: bogus"),
            ("list_notes", ###"{"sort":"nope"}"###, "invalid sort field: nope (valid: pinned, modified, created, title)"),
            ("search_notes", "{}", "missing required field: query"),
            ("search_in_note", ###"{"id":"x"}"###, "missing required field: string"),
            ("overwrite_note", ###"{"id":"x","content":"c"}"###, "missing required field: baseHash"),
            ("edit_note", ###"{"id":"x","edits":[]}"###, "At least one edit is required"),
            ("add_tags", ###"{"id":"x","tags":[" "]}"###, "A tag name must not be empty"),
            ("add_attachment_from_url", ###"{"id":"x","url":"http://example.com"}"###, "Only https:// URLs are supported"),
            ("rename_tag", ###"{"old":"a","new":"a/b"}"###, "A tag cannot be renamed into its own subtree: a -> a/b"),
            ("read_note_content", ###"{"id":"x","address":"# A","offset":1}"###, "Provide address or offset/limit, not both"),
            ("create_note", ###"{"ifNotExists":true}"###, "--if-not-exists requires a title"),
        ]
        for (name, arguments, message) in usage {
            let error = try await fail(name, arguments)
            #expect(error.code == .usage && error.message == message, "\(name): \(error)")
        }
        #expect(counter.opens == 0)
        // With good arguments the failure is the library's, as a tool error, on every call.
        for _ in 0..<2 {
            let error = try await fail("list_notes", "{}")
            #expect(error.code == .libraryUnavailable && error.message == "nope")
        }
        #expect(counter.opens == 2)
    }

    @Test func theLibraryIsOpenedOncePerSuccess() async throws {
        let f = try ToolFixture([TestNote(text: "# T")])
        _ = try await f.ok("list_notes")
        _ = try await f.ok("list_tags")
        _ = try await f.ok("list_notes")
        // The provider is asked on every call and memoizes the success itself: one real open.
        #expect(f.opens.count == 1)
    }

    @Test func aToolCallGoesThroughTheServerWithSortedKeysAndMatchingText() async throws {
        let f = try ToolFixture([TestNote(text: "# T\nbody #t")])
        let id = try f.lib.firstId()
        let replies = try await runServer(
            [
                ###"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_note","arguments":{"id":\###(quoted(id)),"includeContent":true}}}"###,
                ###"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_note","arguments":{"id":"ZZZ-NOPE"}}}"###,
            ], handler: f.tools)
        let result = try #require(replies[0]["result"])
        let structured = try #require(result["structuredContent"])
        #expect(structured["metadata"]?["tags"] == .array(["t"]) && structured["content"] == "# T\nbody #t")
        let text = try #require(result["content"]?.array?.first?["text"]?.string)
        #expect(text == structured.serialized(sortedKeys: true))
        #expect(text.hasPrefix(###"{"content":"# T\nbody #t","metadata":{"attachments":[],"created":"###))
        let failure = try #require(replies[1]["result"])
        #expect(failure["isError"] == true)
        #expect(failure["content"]?.array?.first?["text"]?.string
            == ###"{"error":{"code":"note_not_found","message":"Note not found: ZZZ-NOPE"}}"###)
    }
}
