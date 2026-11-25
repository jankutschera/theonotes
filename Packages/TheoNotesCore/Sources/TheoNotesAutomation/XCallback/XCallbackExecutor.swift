// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import GRDB

/// Runs one parsed x-callback request against the library through the same service the CLI and
/// the MCP server use, and says what the app should show and what the caller gets back. It never
/// opens a URL or touches the UI itself. Rules: inventory §2.18, rulings M5-R19, R21, R22 and
/// M5-R120…R129.
public final class XCallbackExecutor {
    private let library: AutomationLibrary
    private let context: AutomationContext
    private let selectedNoteId: () -> String?
    private let clipboard: () -> String?
    private let service: AutomationService
    /// Test seams: run right after a new note is stored, and in place of its permanent deletion.
    var afterCreateHook: ((String) throws(AutomationError) -> Void)?
    var deleteNotes: (([String]) throws -> Void)?

    public init(
        library: AutomationLibrary, context: AutomationContext, selectedNoteId: @escaping () -> String?,
        clipboard: @escaping () -> String?
    ) {
        self.library = library
        self.context = context
        self.selectedNoteId = selectedNoteId
        self.clipboard = clipboard
        self.service = AutomationService(library: library, context: context)
    }

    public func execute(_ r: XCallbackRequest) -> XCallbackOutcome {
        // Whether the caller proved itself decides how much an error may say (ruling M5-R168).
        let detailed = (try? tokenIsValid(r)) ?? false
        do throws(XCallbackFailure) {
            // A token that is given must be right, whatever the action (ruling M5-R167).
            _ = try tokenIsValid(r)
            var outcome = try dispatch(r)
            outcome.detailedErrors = detailed
            return outcome
        } catch {
            return XCallbackOutcome(ui: .none, success: nil, failure: error, detailedErrors: detailed)
        }
    }

    private func dispatch(_ r: XCallbackRequest) throws(XCallbackFailure) -> XCallbackOutcome {
        switch r.action {
        case .openNote: return try openNote(r)
        case .create: return try create(r)
        case .addText: return try addText(r)
        case .addFile: return try addFile(r)
        case .tags: return try tags(r)
        case .openTag: return try openTag(r)
        case .renameTag: return try renameTag(r)
        case .deleteTag: return try deleteTag(r)
        case .trash: return try move(r, to: .trash)
        case .archive: return try move(r, to: .archive)
        case .untagged: return try list(r, scope: .untagged, search: r.params["search"])
        case .todo: return try list(r, scope: .todo, search: r.params["search"])
        case .today: return try list(r, scope: .today, search: r.params["search"])
        case .locked:
            return XCallbackOutcome(ui: select(r, .locked, search: r.params["search"]), success: [], failure: nil)
        case .search: return try search(r)
        case .grabURL:
            throw .unsupported("grab-url is not supported: Theo Notes does not fetch web pages")
        case .openWorkspace:
            guard let name = value(r, "name") else { throw .invalid("name is required") }
            return XCallbackOutcome(ui: .openWorkspace(name), success: [], failure: nil)
        case .closeWorkspace:
            return XCallbackOutcome(ui: .closeWorkspace, success: [], failure: nil)
        }
    }

    // MARK: Helpers

    /// A parameter's value; nil when absent or empty.
    private func value(_ r: XCallbackRequest, _ key: String) -> String? {
        guard let v = r.params[key], !v.isEmpty else { return nil }
        return v
    }

    private func wrap<T>(_ body: () throws(AutomationError) -> T) throws(XCallbackFailure) -> T {
        do {
            return try body()
        } catch {
            throw XCallbackFailure(error)
        }
    }

    private func read<T>(_ body: (Database) throws -> T) throws(XCallbackFailure) -> T {
        try wrap { () throws(AutomationError) in try ReadFailure.read(library, body) }
    }

    /// True for a valid `token`, false without one; a token that does not match is failure 4.
    private func tokenIsValid(_ r: XCallbackRequest) throws(XCallbackFailure) -> Bool {
        // `token=` (empty) is a token that was given, and it is wrong (ruling M5-R167).
        guard let given = r.params["token"] else { return false }
        let stored = (try? Settings(db: library.database).value(.automationToken)) ?? ""
        guard AutomationToken.matches(given, stored) else { throw .badToken }
        return true
    }

    private func requireToken(_ r: XCallbackRequest) throws(XCallbackFailure) {
        guard try tokenIsValid(r) else { throw .badToken }
    }

    /// Replacing text is destructive, so it needs the token (ruling M5-R161).
    private func requireTokenForReplace(_ mode: XCallbackMode, _ r: XCallbackRequest) throws(XCallbackFailure) {
        if mode == .replace || mode == .replaceAll { try requireToken(r) }
    }

    /// `selected=yes` (needs the token), else `id`, else `title`.
    private func resolveNote(_ r: XCallbackRequest) throws(XCallbackFailure) -> Note {
        let selector: NoteSelector
        let label: String
        if r.flag("selected") == true {
            try requireToken(r)
            guard let id = selectedNoteId() else { throw .noteNotFound("no note is selected") }
            selector = .id(id)
            label = id
        } else if let id = value(r, "id") {
            selector = .id(id)
            label = id
        } else if let title = value(r, "title") {
            selector = .title(title)
            label = title
        } else {
            throw .invalid("Note ID or title is required")
        }
        let note: Note
        do {
            note = try read { db in try NoteResolver.resolve(selector, scope: .unrestricted, db: db) }
        } catch where error.code == 2 {
            throw .noteNotFound(label)
        }
        if r.flag("exclude_trashed") == true, note.location == .trash { throw .noteNotFound(label) }
        return note
    }

    private func openIntent(_ r: XCallbackRequest, id: String, header: String? = nil, find: String? = nil) -> XCallbackUIIntent {
        if r.flag("open_note") == false { return .none }
        return .openNote(
            id: id, header: header, newWindow: r.flag("new_window") ?? false, float: r.flag("float") ?? false,
            edit: r.flag("edit") ?? false, find: find, showWindow: r.flag("show_window") != false)
    }

    private func select(_ r: XCallbackRequest, _ scope: SidebarScope, search: String?) -> XCallbackUIIntent {
        .select(scope, search: search.flatMap { $0.isEmpty ? nil : $0 }, showWindow: r.flag("show_window") != false)
    }

    /// `text`, or the clipboard's text for `clipboard=yes`, with the timestamp line when asked.
    private func textParameter(_ r: XCallbackRequest) -> String {
        var text = r.params["text"] ?? ""
        if r.flag("clipboard") == true { text = clipboard() ?? "" }
        return text
    }

    private func stamped(_ text: String, _ r: XCallbackRequest) -> String {
        guard r.flag("timestamp") == true else { return text }
        let c = context.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: context.now())
        func two(_ n: Int?) -> String { String(format: "%02d", n ?? 0) }
        let line = "\(String(format: "%04d", c.year ?? 0))-\(two(c.month))-\(two(c.day)) \(two(c.hour)):\(two(c.minute))"
        return text.isEmpty ? line : line + "\n" + text
    }

    /// `file` and `filename`, both or neither. The encoded length is checked before anything is
    /// decoded, so an oversized `file` costs no memory; the cap is `maxAttachmentBytes`.
    private func fileParameters(_ r: XCallbackRequest) throws(XCallbackFailure) -> (data: Data, filename: String)? {
        let file = value(r, "file")
        let filename = value(r, "filename")
        if file == nil, filename == nil { return nil }
        guard let file, let filename else { throw .invalid("file and filename must be given together") }
        guard AttachmentName.clean(filename) != nil else { throw .invalid("Invalid filename: \(filename)") }
        let limit = context.maxAttachmentBytes
        let encodedLimit = (limit + 2) / 3 * 4
        // Whitespace in the encoding is tolerated, up to as much again.
        guard file.utf8.count <= encodedLimit * 2 else { throw .invalid(AutomationService.tooLarge(limit)) }
        let clean = file.filter { !$0.isWhitespace }
        guard clean.utf8.count <= encodedLimit else { throw .invalid(AutomationService.tooLarge(limit)) }
        guard let data = Data(base64Encoded: clean), !data.isEmpty else { throw .invalid("file is not valid base64") }
        guard data.count <= limit else { throw .invalid(AutomationService.tooLarge(limit)) }
        return (data, filename)
    }

    private func json(_ value: JSONValue) -> String { value.serialized(sortedKeys: false) }

    // MARK: open-note

    private func openNote(_ r: XCallbackRequest) throws(XCallbackFailure) -> XCallbackOutcome {
        let withData = try tokenIsValid(r)
        let note = try resolveNote(r)
        let ui = openIntent(r, id: note.id, header: value(r, "header"), find: value(r, "search"))
        if note.isLocked { return XCallbackOutcome(ui: ui, success: nil, failure: .locked("Note is locked: \(note.id)")) }
        if r.flag("pin") == true { _ = try wrap { () throws(AutomationError) in try service.addPins(.id(note.id), targets: ["global"]) } }
        // Without the token the note opens, but nothing about it goes back to the caller (M5-R162).
        guard withData else { return XCallbackOutcome(ui: ui, success: [], failure: nil) }
        let record = try wrap { () throws(AutomationError) in try service.record(id: note.id) }
        let success: [(String, String)] = [
            ("note", record.content ?? ""), ("identifier", record.id), ("title", record.title),
            ("tags", json(.array(record.tags.map { .string($0) }))),
            ("is_trashed", record.location == .trash ? "yes" : "no"),
            ("modificationDate", NoteRecord.timestamp(record.modified)),
            ("creationDate", NoteRecord.timestamp(record.created)),
        ]
        return XCallbackOutcome(ui: ui, success: success, failure: nil)
    }

    // MARK: create

    /// Total bytes of the images `type=html` may carry in, and the largest single one.
    private var imageLimit: Int { min(context.maxAttachmentBytes, 20 * 1024 * 1024) }

    private func create(_ r: XCallbackRequest) throws(XCallbackFailure) -> XCallbackOutcome {
        let withData = try tokenIsValid(r)
        var text = textParameter(r)
        // A request whose answer may not have arrived gets its first note back (REL-R90, REL-R92).
        let receipts = XCallbackReceipts(database: library.database)
        let fingerprint = XCallbackReceipts.fingerprint(
            action: r.action.rawValue, parameters: r.params, clipboard: r.flag("clipboard") == true ? text : nil)
        if let id = receipts.noteID(for: fingerprint, now: context.now()) {
            var success = [("identifier", id)]
            if withData { success.append(("title", try wrap { () throws(AutomationError) in try service.record(id: id) }.title)) }
            var outcome = XCallbackOutcome(ui: openIntent(r, id: id), success: success, failure: nil)
            outcome.receipt = fingerprint
            return outcome
        }
        var images: [ImportedAttachment] = []
        if r.params["type"]?.lowercased() == "html" {
            // `url` is the page the HTML came from: relative images resolve against it as text,
            // nothing is fetched (final review M7, amends M5-R123).
            let base = r.params["url"].flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let converted = HTMLToMarkdown.convert(
                text, imageLimits: .init(each: imageLimit, total: imageLimit), baseURL: base)
            // Oversized images were not decoded at all (ruling M5-R169).
            if converted.oversizedImages > 0 {
                throw .invalid("The HTML images are larger than \(URLFetchPolicy.describe(limit: imageLimit))")
            }
            text = converted.markdown
            images = converted.images
        }
        // Everything is checked before the note exists (ruling M5-R163).
        var total = 0
        for image in images {
            total += image.data.count
            guard image.data.count <= imageLimit, total <= imageLimit else {
                throw .invalid("The HTML images are larger than \(URLFetchPolicy.describe(limit: imageLimit))")
            }
            guard AttachmentName.clean(image.filename) != nil else { throw .invalid("Invalid image name: \(image.filename)") }
        }
        text = stamped(text, r)
        let title = AutomationService.cleanTitle(r.params["title"])
        let file = try fileParameters(r)
        let tags = try wrap { () throws(AutomationError) in try TagArgument.list(r.params["tags"]) }
        if title == nil, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, file == nil, images.isEmpty {
            throw .invalid("Empty notes are not allowed")
        }
        // From the moment the note is stored, every failure undoes it (ruling M5-R166): the id
        // comes from the create step itself, so even a failed read of the new record is covered.
        var createdId: String?
        let record: NoteRecord
        do throws(XCallbackFailure) {
            record = try wrap { () throws(AutomationError) in
                try service.create(
                    title: title, content: text, tags: tags, ifNotExists: false, template: nil,
                    onCreated: { id throws(AutomationError) in
                        createdId = id
                        try self.afterCreateHook?(id)
                    })
            }
            if !images.isEmpty {
                let store = AttachmentStore(paths: library.paths, database: library.database)
                for image in images {
                    do {
                        _ = try store.add(data: image.data, filename: image.filename, to: record.id)
                    } catch {
                        throw .failed("An image could not be stored: \(error.localizedDescription)")
                    }
                }
            }
            if let file {
                _ = try wrap { () throws(AutomationError) in
                    try service.addAttachment(
                        .id(record.id), data: file.data, filename: file.filename, preservingModifiedDate: false)
                }
            }
            if r.flag("pin") == true {
                _ = try wrap { () throws(AutomationError) in try service.addPins(.id(record.id), targets: ["global"]) }
            }
        } catch {
            if let id = createdId {
                do {
                    try (deleteNotes ?? { try self.library.store.deletePermanently($0) })([id])
                } catch let undo {
                    throw .failed(
                        "The note was only partly created and could not be removed (\(id)): \(undo.localizedDescription). Original error: \(error.message)")
                }
            }
            throw error
        }
        receipts.record(fingerprint, noteID: record.id, now: context.now())
        var success = [("identifier", record.id)]
        if withData { success.append(("title", record.title)) }
        var outcome = XCallbackOutcome(ui: openIntent(r, id: record.id), success: success, failure: nil)
        outcome.receipt = fingerprint
        return outcome
    }

    // MARK: add-text, add-file

    private func addText(_ r: XCallbackRequest) throws(XCallbackFailure) -> XCallbackOutcome {
        let withData = try tokenIsValid(r)
        let mode = try XCallbackMode.parse(r.params["mode"])
        try requireTokenForReplace(mode, r)
        let note = try resolveNote(r)
        let tags = try wrap { () throws(AutomationError) in try TagArgument.list(r.params["tags"]) }
        let content = stamped(textParameter(r), r)
        guard !content.isEmpty || !tags.isEmpty else { throw .invalid("Nothing to add: text is required") }
        if note.isLocked { throw .locked("Note is locked: \(note.id)") }
        let header = value(r, "header")
        // A header that is not there fails before anything is written, tags included (M5-R124).
        if let header { _ = try wrap { () throws(AutomationError) in try XCallbackTextEdit.section(header: header, in: note.text) } }
        let newLine = r.flag("new_line") == true
        if !content.isEmpty {
            let position = service.tagPosition
            _ = try wrap { () throws(AutomationError) in
                try service.mutate(.id(note.id), preservingModifiedDate: false) { n, _ throws(AutomationError) in
                    let text = try XCallbackTextEdit.apply(
                        content, mode: mode, newLine: newLine, header: header, to: n.text, tagPosition: position)
                    try self.service.checkGate(.cli(force: false), note: n, newText: text)
                    return text
                }
            }
        }
        if !tags.isEmpty {
            _ = try wrap { () throws(AutomationError) in try service.addTags(.id(note.id), tags: tags) }
        }
        guard withData else {
            return XCallbackOutcome(ui: openIntent(r, id: note.id), success: [("identifier", note.id)], failure: nil)
        }
        let record = try wrap { () throws(AutomationError) in try service.record(id: note.id) }
        return XCallbackOutcome(
            ui: openIntent(r, id: note.id), success: [("note", record.content ?? ""), ("title", record.title)],
            failure: nil)
    }

    private func addFile(_ r: XCallbackRequest) throws(XCallbackFailure) -> XCallbackOutcome {
        let withData = try tokenIsValid(r)
        let mode = try XCallbackMode.parse(r.params["mode"])
        try requireTokenForReplace(mode, r)
        let note = try resolveNote(r)
        guard value(r, "file") != nil, value(r, "filename") != nil, let file = try fileParameters(r) else {
            throw .invalid("file and filename are required")
        }
        if note.isLocked { throw .locked("Note is locked: \(note.id)") }
        let header = value(r, "header")
        // The file is stored before the link is placed, so a missing header must fail first.
        if let header { _ = try wrap { () throws(AutomationError) in try XCallbackTextEdit.section(header: header, in: note.text) } }
        let position = service.tagPosition
        // If the gate refuses the change, the service takes the stored file out again (M5-R164).
        _ = try wrap { () throws(AutomationError) in
            try service.addAttachment(
                .id(note.id), data: file.data, filename: file.filename, preservingModifiedDate: false
            ) { link, n, _ throws(AutomationError) in
                let text = try XCallbackTextEdit.apply(
                    link, mode: mode, newLine: true, header: header, to: n.text, tagPosition: position)
                try self.service.checkGate(.cli(force: false), note: n, newText: text)
                return text
            }
        }
        guard withData else {
            return XCallbackOutcome(ui: openIntent(r, id: note.id), success: [("identifier", note.id)], failure: nil)
        }
        let record = try wrap { () throws(AutomationError) in try service.record(id: note.id) }
        return XCallbackOutcome(ui: openIntent(r, id: note.id), success: [("note", record.content ?? "")], failure: nil)
    }

    // MARK: Tags

    private func tags(_ r: XCallbackRequest) throws(XCallbackFailure) -> XCallbackOutcome {
        try requireToken(r)
        let tree = try read { db in try LibraryQueries.tagTree(db: db) }
        func flatten(_ nodes: [TagNode]) -> [String] { nodes.flatMap { [$0.path] + flatten($0.children) } }
        let names = flatten(tree).map { JSONValue.object([("name", .string($0))]) }
        return XCallbackOutcome(ui: .none, success: [("tags", json(.array(names)))], failure: nil)
    }

    private func openTag(_ r: XCallbackRequest) throws(XCallbackFailure) -> XCallbackOutcome {
        guard let raw = value(r, "name") else { throw .invalid("name is required") }
        let names = try wrap { () throws(AutomationError) in try TagArgument.list(raw) }
        guard let first = names.first else { throw .invalid("name is required") }
        let allowed = try tokenIsValid(r)
        let ui = select(r, .tag(first), search: nil)
        guard allowed else { return XCallbackOutcome(ui: ui, success: [], failure: nil) }
        let sort = Settings(db: library.database).noteSort
        let items = try read { db in
            try names.flatMap {
                try LibraryQueries.notes(in: .tag($0), sort: sort, now: context.now(), calendar: context.calendar, db: db)
            }
        }
        return XCallbackOutcome(
            ui: ui, success: [("notes", json(try notesJSON(items, withTags: false)))], failure: nil)
    }

    private func renameTag(_ r: XCallbackRequest) throws(XCallbackFailure) -> XCallbackOutcome {
        try requireToken(r)
        guard let old = value(r, "name"), let new = value(r, "new_name") else {
            throw .invalid("name and new_name are required")
        }
        _ = try wrap { () throws(AutomationError) in try service.renameTag(old: old, new: new, force: false) }
        return XCallbackOutcome(ui: .none, success: [], failure: nil)
    }

    private func deleteTag(_ r: XCallbackRequest) throws(XCallbackFailure) -> XCallbackOutcome {
        try requireToken(r)
        guard let name = value(r, "name") else { throw .invalid("name is required") }
        _ = try wrap { () throws(AutomationError) in try service.deleteTag(name) }
        return XCallbackOutcome(ui: .none, success: [], failure: nil)
    }

    // MARK: trash, archive

    private func move(_ r: XCallbackRequest, to location: NoteLocation) throws(XCallbackFailure) -> XCallbackOutcome {
        let scope: SidebarScope = location == .trash ? .trash : .archive
        if let id = value(r, "id") {
            try requireToken(r)
            _ = try wrap { () throws(AutomationError) in
                location == .trash ? try service.trash(.id(id)) : try service.archive(.id(id))
            }
            return XCallbackOutcome(ui: select(r, scope, search: nil), success: [], failure: nil)
        }
        _ = try tokenIsValid(r)
        guard let search = value(r, "search") else { throw .invalid("id or search is required") }
        return XCallbackOutcome(ui: select(r, scope, search: search), success: [], failure: nil)
    }

    // MARK: Note lists

    private func list(_ r: XCallbackRequest, scope: SidebarScope, search: String?) throws(XCallbackFailure) -> XCallbackOutcome {
        let allowed = try tokenIsValid(r)
        let query = search.flatMap { $0.isEmpty ? nil : $0 }
        let ui = select(r, scope, search: query)
        guard allowed else { return XCallbackOutcome(ui: ui, success: [], failure: nil) }
        let sort = Settings(db: library.database).noteSort
        let items = try read { db -> [NoteListItem] in
            if let query {
                return try LibraryQueries.search(
                    query, in: scope, sort: sort, now: context.now(), calendar: context.calendar,
                    locale: context.locale, db: db
                ).items
            }
            return try LibraryQueries.notes(in: scope, sort: sort, now: context.now(), calendar: context.calendar, db: db)
        }
        return XCallbackOutcome(
            ui: ui, success: [("notes", json(try notesJSON(items, withTags: true)))], failure: nil)
    }

    private func search(_ r: XCallbackRequest) throws(XCallbackFailure) -> XCallbackOutcome {
        var scope = SidebarScope.notes
        if let raw = value(r, "tag") {
            let names = try wrap { () throws(AutomationError) in try TagArgument.list(raw) }
            if let first = names.first { scope = .tag(first) }
        }
        return try list(r, scope: scope, search: r.params["term"])
    }

    /// `[{"title","identifier","modificationDate","creationDate","pin"[,"tags"]}]`; locked notes
    /// never appear and a note found twice appears once.
    private func notesJSON(_ items: [NoteListItem], withTags: Bool) throws(XCallbackFailure) -> JSONValue {
        var seen = Set<String>()
        let shown = items.filter { !$0.isLocked && seen.insert($0.id).inserted }
        let tags: [String: [String]] =
            withTags
            ? try read { db in
                var found: [String: [String]] = [:]
                for note in try Note.fetchAll(db, keys: shown.map(\.id)) {
                    found[note.id] = NoteParser.metadata(for: note.text).tags
                }
                return found
            } : [:]
        return .array(
            shown.map { item in
                var fields: [(String, JSONValue)] = [
                    ("title", .string(item.title)), ("identifier", .string(item.id)),
                    ("modificationDate", .string(NoteRecord.timestamp(item.modifiedAt))),
                    ("creationDate", .string(NoteRecord.timestamp(item.createdAt))),
                    ("pin", .string(item.isPinned ? "yes" : "no")),
                ]
                if withTags { fields.append(("tags", .array((tags[item.id] ?? []).map { .string($0) }))) }
                return .object(fields)
            })
    }
}
