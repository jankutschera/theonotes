// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import GRDB

/// Bear's MCP tools on the automation layer (plus `create_note_from_template` and `capture_thought`). `app_open_note` and
/// `app_get_selection` need the running app and live in MCPToolsApp.swift.
///
/// Every tool checks its arguments first and asks for the library afterwards, per call (rulings M5-R45,
/// M5-R72): a library that cannot be opened is a `library_unavailable` tool error, and a later call
/// recovers once it exists. Result objects are plain values; the server writes them with sorted keys.
/// Writes run through `AutomationService` with the same scope as the reads.
///
/// The service calls are synchronous and short; the one slow tool, `add_attachment_from_url`, awaits the
/// fetcher, which carries its own 30 s total and 15 s idle timeouts (rulings M5-R73, M5-R97).
struct MCPTools: MCPToolHandler {
    let libraryProvider: LibraryProvider
    let context: AutomationContext
    let scope: NoteScope

    init(libraryProvider: LibraryProvider, context: AutomationContext, scope: NoteScope) {
        self.libraryProvider = libraryProvider
        self.context = context
        self.scope = scope
    }

    func call(_ name: String, arguments: JSONValue) async -> Result<JSONValue, AutomationError> {
        do throws(AutomationError) {
            let args = MCPArguments(arguments)
            try args.require(MCPToolCatalog.requiredFields[name] ?? [])
            if name == "capture_thought" { try Self.refuseUnknownFields(arguments, allowed: ["text"]) }
            return .success(try await run(name, args))
        } catch {
            return .failure(error)
        }
    }

    /// `capture_thought` takes `text` and nothing else, and says so (FOC-R14): a field it would drop
    /// without a word, such as `tags`, is a usage error. The other tools ignore unknown fields.
    private static func refuseUnknownFields(_ arguments: JSONValue, allowed: [String]) throws(AutomationError) {
        if let extra = arguments.keys.first(where: { !allowed.contains($0) }) {
            throw AutomationError(code: .usage, message: "Unknown field: \(extra)")
        }
    }

    private func run(_ name: String, _ a: MCPArguments) async throws(AutomationError) -> JSONValue {
        switch name {
        case "list_notes": return try listNotes(a)
        case "search_notes": return try searchNotes(a)
        case "get_note": return try getNote(a)
        case "read_note_content": return try readNoteContent(a)
        case "read_note_outline": return try readNoteOutline(a)
        case "search_in_note": return try searchInNote(a)
        case "list_pins": return try listPins(a)
        case "list_tags": return try listTags(a)
        case "list_attachments": return try listAttachments(a)
        case "create_note": return try createNote(a)
        case "create_note_from_template": return try createNoteFromTemplate(a)
        case "capture_thought": return try captureThought(a)
        case "append_to_note": return try appendToNote(a)
        case "overwrite_note": return try overwriteNote(a)
        case "edit_note": return try editNote(a)
        case "add_pins": return try changePins(a, pinned: true)
        case "remove_pins": return try changePins(a, pinned: false)
        case "archive_note": return try moveNote(a) { (service, selector) throws(AutomationError) in try service.archive(selector) }
        case "trash_note": return try moveNote(a) { (service, selector) throws(AutomationError) in try service.trash(selector) }
        case "restore_note": return try moveNote(a) { (service, selector) throws(AutomationError) in try service.restore(selector) }
        case "add_tags": return try changeTags(a, add: true)
        case "remove_tags": return try changeTags(a, add: false)
        case "rename_tag": return try renameTag(a)
        case "delete_tag": return try deleteTag(a)
        case "add_attachment_from_url": return try await addAttachmentFromURL(a)
        case "delete_attachment": return try deleteAttachment(a)
        case "app_open_note": return try appOpenNote(a)
        case "app_get_selection": return try appGetSelection(a)
        default:
            throw AutomationError(code: .internal, message: "Not implemented: \(name)")
        }
    }

    // MARK: Shared

    func openLibrary() throws(AutomationError) -> AutomationLibrary { try libraryProvider.library() }

    func makeService() throws(AutomationError) -> AutomationService {
        AutomationService(library: try openLibrary(), context: context, scope: scope)
    }

    func attachments(_ library: AutomationLibrary) -> AttachmentStore {
        AttachmentStore(paths: library.paths, database: library.database)
    }

    /// The note a tool names by `id` or `title`: exactly one of them.
    func noteSelector(_ a: MCPArguments) throws(AutomationError) -> NoteSelector {
        try NoteSelector.parse(id: try a.string("id"), title: try a.string("title"))
    }

    /// The note a tool may name, nil when it names none (every tag, every pin).
    func optionalSelector(_ a: MCPArguments) throws(AutomationError) -> NoteSelector? {
        let id = try a.string("id")
        let title = try a.string("title")
        if id == nil, title == nil { return nil }
        return try NoteSelector.parse(id: id, title: title)
    }

    static func sectionObject(_ entry: OutlineEntry) -> JSONValue {
        .object([("address", .string(entry.address)), ("length", .int(entry.length)), ("offset", .int(entry.offset))])
    }

    /// The flat shape of `create_note`: the metadata fields and the content.
    static func flat(_ record: NoteRecord) -> JSONValue {
        guard case .object(let fields) = record.mcpMetadata() else { return .object([]) }
        guard let content = record.content else { return .object(fields) }
        return .object(fields + [("content", .string(content))])
    }

    // MARK: list_notes, search_notes

    private func listNotes(_ a: MCPArguments) throws(AutomationError) -> JSONValue {
        let limit = try a.nonNegative("limit", "Limit")
        let offset = try a.nonNegative("offset", "Offset") ?? 0
        let location = try LocationFilter.parse(try a.string("location"))
        let sort = try SortSpec.parse(try a.string("sort"))
        let includeContent = try a.bool("includeContent") ?? false
        let tag = try a.string("tag")
        let library = try openLibrary()
        let (records, total) = try ReadFailure.read(library) { db -> ([NoteRecord], Int) in
            let found = try AutomationQueries.listNotes(
                location: location, tag: tag, sort: sort, limit: limit, offset: offset, scope: scope, db: db)
            guard limit != 0 else { return ([], found.total) }
            return (try NoteRecord.loadMany(found.notes, db: db, attachments: attachments(library)), found.total)
        }
        // A locked note has no readable text, so `notes` leaves it out; `total` still counts it.
        if includeContent {
            let notes = records.compactMap { record -> JSONValue? in
                guard let content = record.content else { return nil }
                return .object([("content", .string(content)), ("metadata", record.mcpMetadata())])
            }
            return .object([("notes", .array(notes)), ("total", .int(total))])
        }
        return .object([("metadata", .array(records.map { $0.mcpMetadata() })), ("total", .int(total))])
    }

    private func searchNotes(_ a: MCPArguments) throws(AutomationError) -> JSONValue {
        guard let query = try a.string("query"), !query.isEmpty else {
            throw AutomationError(code: .usage, message: "Query is required")
        }
        let limit = try a.nonNegative("limit", "Limit")
        let offset = try a.nonNegative("offset", "Offset") ?? 0
        let location = try LocationFilter.parse(try a.string("location"))
        let sort = try SortSpec.parse(try a.string("sort"))
        let includeContent = try a.bool("includeContent") ?? false
        let library = try openLibrary()
        let (records, matches, total) = try ReadFailure.read(library) { db -> ([NoteRecord], [String: Int], Int) in
            let found = try AutomationQueries.searchNotes(
                query, location: location, sort: sort, limit: limit, offset: offset, scope: scope,
                now: context.now(), calendar: context.calendar, locale: context.locale, db: db)
            guard limit != 0 else { return ([], [:], found.total) }
            let records = try NoteRecord.loadMany(found.hits.map(\.note), db: db, attachments: attachments(library))
            let counts = Dictionary(found.hits.map { ($0.note.id, $0.matches) }, uniquingKeysWith: { first, _ in first })
            return (records, counts, found.total)
        }
        if includeContent {
            let hits = records.compactMap { record -> JSONValue? in
                guard let content = record.content else { return nil }
                let note = JSONValue.object([("content", .string(content)), ("metadata", record.mcpMetadata())])
                return .object([("matchCount", .int(matches[record.id] ?? 0)), ("note", note)])
            }
            return .object([("resultsWithContent", .array(hits)), ("total", .int(total))])
        }
        let hits = records.map { record in
            JSONValue.object([("matchCount", .int(matches[record.id] ?? 0)), ("metadata", record.mcpMetadata())])
        }
        return .object([("results", .array(hits)), ("total", .int(total))])
    }

    // MARK: get_note, read_note_content, read_note_outline, search_in_note

    private func getNote(_ a: MCPArguments) throws(AutomationError) -> JSONValue {
        let selector = try noteSelector(a)
        let includeContent = try a.bool("includeContent") ?? false
        let library = try openLibrary()
        let record = try ReadFailure.read(library) { db -> NoteRecord in
            let note = try NoteResolver.resolve(selector, scope: scope, db: db)
            if includeContent { try NoteAccess.requireReadable(note) }
            return try NoteRecord.load(note, db: db, attachments: attachments(library))
        }
        var fields: [(String, JSONValue)] = [("metadata", record.mcpMetadata())]
        if includeContent { fields.append(("content", .string(record.content ?? ""))) }
        return .object(fields)
    }

    private func readNoteContent(_ a: MCPArguments) throws(AutomationError) -> JSONValue {
        let selector = try noteSelector(a)
        let rawAddress = try a.string("address")
        // The conflict comes first (M5-R59), whatever the slice values are.
        if rawAddress != nil, a.has("offset") || a.has("limit") {
            throw AutomationError(code: .usage, message: "Provide address or offset/limit, not both")
        }
        let offset = try a.nonNegative("offset", "Offset")
        let limit = try a.nonNegative("limit", "Limit")
        let library = try openLibrary()
        let (note, address) = try ReadFailure.read(library) { db -> (Note, SectionAddress?) in
            let note = try NoteResolver.resolve(selector, scope: scope, db: db)
            let address = try rawAddress.map { raw throws(AutomationError) in try SectionAddress.parse(raw) }
            try NoteAccess.requireReadable(note)
            return (note, address)
        }
        let text = note.text
        if let address {
            let sections = NoteSections(text: text)
            let entry = sections.entry(try sections.resolve(address))
            let slice = text.utf8[SectionCommands.byteRange(entry.offset..<entry.offset + entry.length, in: text)]
            return .object([
                ("content", .string(String(Substring(slice)))), ("hash", .string(ContentHash.of(slice))),
                ("section", Self.sectionObject(entry)),
            ])
        }
        if offset != nil || limit != nil {
            return .object([("content", .string(SectionCommands.byteSlice(text, offset: offset ?? 0, limit: limit)))])
        }
        return .object([("content", .string(text)), ("hash", .string(ContentHash.of(text)))])
    }

    private func readNoteOutline(_ a: MCPArguments) throws(AutomationError) -> JSONValue {
        let selector = try noteSelector(a)
        let rawAddress = try a.string("address")
        let library = try openLibrary()
        let (note, address) = try ReadFailure.read(library) { db -> (Note, SectionAddress?) in
            let note = try NoteResolver.resolve(selector, scope: scope, db: db)
            let address = try rawAddress.map { raw throws(AutomationError) in try SectionAddress.parse(raw) }
            try NoteAccess.requireReadable(note)
            return (note, address)
        }
        let sections = NoteSections(text: note.text)
        var target: SectionTarget?
        if let address { target = try sections.resolve(address) }
        return .object([("outline", .array(sections.outline(within: target).map(Self.sectionObject)))])
    }

    private func searchInNote(_ a: MCPArguments) throws(AutomationError) -> JSONValue {
        let selector = try noteSelector(a)
        guard let needle = try a.string("string") else {
            throw AutomationError(code: .usage, message: "missing required field: string")
        }
        let limit = try a.nonNegative("limit", "Limit")
        let snippetContext = try a.nonNegative("context", "Context") ?? 120
        let rawAddress = try a.string("address")
        let library = try openLibrary()
        let (note, address, recognized) = try ReadFailure.read(library) {
            db -> (Note, SectionAddress?, [String: String]) in
            let note = try NoteResolver.resolve(selector, scope: scope, db: db)
            let address = try rawAddress.map { raw throws(AutomationError) in try SectionAddress.parse(raw) }
            try NoteAccess.requireReadable(note)
            return (note, address, try SectionCommands.recognizedText(noteId: note.id, db: db))
        }
        let hits = try SectionCommands.searchHits(
            needle, text: note.text, recognized: recognized, address: address, context: snippetContext)
        let matches = hits.prefix(limit ?? Int.max).map { hit -> JSONValue in
            var fields: [(String, JSONValue)] = [
                ("offset", .int(hit.offset)), ("snippet", .string(TextEscapes.escapeTSV(hit.snippet))), ("source", .string(hit.source.rawValue)),
            ]
            if let section = hit.section { fields.append(("section", Self.sectionObject(section))) }
            return .object(fields)
        }
        return .object([("matches", .array(matches))])
    }

    // MARK: list_pins, list_tags, list_attachments

    private func listPins(_ a: MCPArguments) throws(AutomationError) -> JSONValue {
        let selector = try optionalSelector(a)
        let library = try openLibrary()
        let pins = try ReadFailure.read(library) { db -> [NoteRecord.Pin] in
            if let selector {
                let note = try NoteResolver.resolve(selector, scope: scope, db: db)
                return try NoteRecord.loadMany([note], db: db, attachments: attachments(library), fields: ["pins"])[0].pins
            }
            return try ReadCommands.pinContextsInUse(scope: scope, db: db)
        }
        return .object([("pins", .array(pins.map { .string($0.mcpText) }))])
    }

    private func listTags(_ a: MCPArguments) throws(AutomationError) -> JSONValue {
        let selector = try optionalSelector(a)
        let library = try openLibrary()
        let tags = try ReadFailure.read(library) { db -> [String] in
            if let selector {
                let note = try NoteResolver.resolve(selector, scope: scope, db: db)
                let record = try NoteRecord.loadMany([note], db: db, attachments: attachments(library), fields: ["tags"])[0]
                return record.tags
            }
            return try ReadCommands.allTagNames(scope: scope, db: db)
        }
        return .object([("tags", .array(tags.map { .string($0) }))])
    }

    private func listAttachments(_ a: MCPArguments) throws(AutomationError) -> JSONValue {
        let selector = try noteSelector(a)
        let files = try makeService().listAttachments(selector)
        return .object([
            ("attachments", .array(files.map { .object([("filename", .string($0.filename)), ("size", .int($0.size))]) }))
        ])
    }
}
