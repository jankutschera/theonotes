// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import GRDB
import os

/// A note's record before and after a write. Equal when the write changed nothing.
struct MutationResult {
    var before: NoteRecord
    var after: NoteRecord
}

/// How the attachment-removal gate is passed: `--force` on the CLI, `expectedRemovedAttachments`
/// on MCP.
enum AttachmentGateMode {
    case cli(force: Bool)
    case mcp(expected: [String]?)
}

/// Turns whatever a write threw into the error a command reports.
enum WriteFailure {
    static func wrap(_ error: any Error) -> AutomationError {
        if let error = error as? AutomationError { return error }
        if let error = error as? StoreError { return map(error) }
        if let error = error as? DatabaseError, error.resultCode.primaryResultCode == .SQLITE_BUSY {
            return AutomationError(code: .busy, message: "The library is busy. Try again in a moment.")
        }
        return AutomationError(
            code: .internal, message: "The library could not be written: \(error.localizedDescription)")
    }

    private static func map(_ error: StoreError) -> AutomationError {
        switch error {
        case .revisionConflict:
            return AutomationError(code: .busy, message: "The note kept changing; try again")
        case .noteNotFound(let id):
            return AutomationError(code: .noteNotFound, message: "Note not found: \(id)")
        case .noteLocked(let id):
            return AutomationError(code: .noteLocked, message: "Note is locked: \(id)")
        case .tagNotFound(let path):
            return AutomationError(code: .tagNotFound, message: "Tag not found: \(NoteRecord.tagToken(path))")
        case .noteNotTagged(_, let path):
            return AutomationError(code: .tagNotFound, message: "Note is not tagged \(NoteRecord.tagToken(path))")
        case .invalidTag(let path):
            return AutomationError(code: .usage, message: "Invalid tag name: \(path)")
        case .tagNotRoot(let path):
            return AutomationError(code: .usage, message: "Only root tags can be pinned in the sidebar: \(path)")
        case .tagIntoOwnSubtree(let path, let target):
            return AutomationError(
                code: .usage, message: "A tag cannot be renamed into its own subtree: \(path) -> \(target)")
        case .reservedTagName(let name):
            return AutomationError(code: .usage, message: "\(NoteRecord.tagToken(name)) is a reserved tag name")
        case .externalRefTombstoned:
            return AutomationError(code: .internal, message: "The library could not be written: \(error)")
        }
    }
}

/// Every write of the CLI, the MCP server and x-callback goes through here: one place resolves
/// the note, refuses locked and read-only notes, runs the change and retries on a revision
/// conflict (ruling M5-R49 for locks, M5-R8 for read-only notes).
final class AutomationService: Sendable {
    /// Tries before a note that keeps changing is given up on.
    static let maxAttempts = 8

    let library: AutomationLibrary
    let context: AutomationContext
    let scope: NoteScope
    private let attachments: AttachmentStore
    /// Called with the attempt number between the transform and the commit: tests use it to race
    /// a write against the service.
    private let beforeCommit: (@Sendable (Int) -> Void)?
    /// Called after a write committed and before its result is read back: tests use it to change the
    /// note at that moment.
    private let afterCommit: (@Sendable () -> Void)?

    init(
        library: AutomationLibrary, context: AutomationContext, scope: NoteScope = .unrestricted,
        beforeCommit: (@Sendable (Int) -> Void)? = nil, afterCommit: (@Sendable () -> Void)? = nil
    ) {
        self.library = library
        self.context = context
        self.scope = scope
        self.beforeCommit = beforeCommit
        self.afterCommit = afterCommit
        self.attachments = AttachmentStore(paths: library.paths, database: library.database)
    }

    // MARK: Records

    /// What a caller is told when a write committed and the note then left the scope: the change is
    /// stored, but nothing about the note is returned (ruling M5-R176).
    static let savedButOutsideScope = AutomationError(
        code: .outOfScope, message: "The change was saved, but the note is now outside this server's scope",
        details: .object([("committed", .bool(true))]))

    /// An error raised after the write committed (reading the result back: `busy`, `internal`)
    /// carries `details.committed: true`, so a caller does not retry a change that is stored (final
    /// review M3); leaving the scope is `savedButOutsideScope`.
    static func committed(_ error: AutomationError) -> AutomationError {
        if error.code == .outOfScope { return savedButOutsideScope }
        var fields: [(String, JSONValue)] = []
        if case .object(let existing)? = error.details { fields = existing.filter { $0.0 != "committed" } }
        return AutomationError(code: error.code, message: error.message, details: .object(fields + [("committed", .bool(true))]))
    }

    /// The record of a note a write just changed. Under a scope it is read in one transaction with
    /// the scope check, so a note that left the scope in the meantime is never described to the
    /// caller (ruling M5-R171). `afterCommit` marks a write that already committed: any failure then
    /// says so (`committed`).
    func record(of note: Note, afterCommit: Bool = false) throws(AutomationError) -> NoteRecord {
        if afterCommit { self.afterCommit?() }
        do throws(AutomationError) {
            return try ReadFailure.read(library) { db in
                try requireInScope(note.id, db: db)
                return try NoteRecord.load(note, db: db, attachments: attachments)
            }
        } catch {
            throw afterCommit ? Self.committed(error) : error
        }
    }

    func record(id: String, afterCommit: Bool = false) throws(AutomationError) -> NoteRecord {
        if afterCommit { self.afterCommit?() }
        do throws(AutomationError) {
            return try ReadFailure.read(library) { db in
                guard let note = try Note.fetchOne(db, key: id) else {
                    throw AutomationError(code: .noteNotFound, message: "Note not found: \(id)")
                }
                try requireInScope(id, db: db)
                return try NoteRecord.load(note, db: db, attachments: attachments)
            }
        } catch {
            throw afterCommit ? Self.committed(error) : error
        }
    }

    private func requireInScope(_ id: String, db: Database) throws {
        guard try scope.contains(id, db: db) else {
            throw AutomationError(code: .outOfScope, message: "Note is outside this server's scope: \(id)")
        }
    }

    var tagPosition: TagPosition { Settings(db: library.database).tagPosition }

    // MARK: Scope

    static let leavesScope = AutomationError(
        code: .outOfScope, message: "The change would move the note out of this server's scope")
    static let newNoteOutsideScope = AutomationError(
        code: .outOfScope, message: "The new note would be outside this server's scope")

    /// The store the writes of a scoped caller go through. Its write transactions check the scope
    /// themselves, before they commit (ruling M5-R143): a failed check rolls the transaction back,
    /// so nothing is written and nothing needs undoing. `notes` must be in scope when the write
    /// starts (a note that left the scope since it was resolved is not re-admitted by a write that
    /// puts the tag back, ruling M5-R170) and still afterwards, a `creating` write may only add
    /// notes that are in scope, `template` must be in scope when the write starts, and `tags` (a
    /// rename's or delete's subjects) must not be carried by a note outside the scope. Without a
    /// scope this is the plain store.
    private func guardedStore(
        notes: [String] = [], creating: Bool = false, template: String? = nil,
        tags: [(key: String, name: String)] = [], rewriting: (key: String, name: String)? = nil
    ) -> NoteStore {
        guard scope.isRestricted else { return library.store }
        let scope = scope
        let newest = RowMark()
        return library.store.guarded { db, stage in
            switch stage {
            case .begin:
                if creating { newest.value = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(rowid), 0) FROM note") ?? 0 }
                for id in notes + (template.map { [$0] } ?? []) where try !scope.contains(id, db: db) {
                    throw AutomationError(code: .outOfScope, message: "Note is outside this server's scope: \(id)")
                }
                for tag in tags { try scope.refuseTagCarriedOutside(tag.key, name: tag.name, db: db) }
                if let rewriting { try scope.refuseHiddenTagRows(below: rewriting.key, name: rewriting.name, db: db) }
            case .beforeCommit:
                for id in notes where try !scope.contains(id, db: db) { throw Self.leavesScope }
                if creating {
                    let added = try String.fetchAll(
                        db, sql: "SELECT id FROM note WHERE rowid > ?", arguments: [newest.value])
                    for id in added where try !scope.contains(id, db: db) { throw Self.newNoteOutsideScope }
                }
            }
        }
    }

    // MARK: Text writes

    /// resolve, `preflight`, lock and read-only check, `transform` on the current text, then write
    /// with `expectedRevision`. A revision conflict (someone wrote in between) re-reads the note
    /// and runs everything again, up to `maxAttempts` times, then `busy`. A transform that
    /// returns the text unchanged writes nothing.
    ///
    /// `preflight` runs after the note is found and before the lock check: the place for checks
    /// that must not depend on the note's content (an address's syntax, ruling M5-R59).
    /// `didCommit` runs right after the text was committed, before anything else can fail.
    func mutate(
        _ selector: NoteSelector, preservingModifiedDate: Bool,
        preflight: (Note) throws(AutomationError) -> Void = { _ in },
        didCommit: () -> Void = {},
        transform: (Note, NoteSections) throws(AutomationError) -> String
    ) throws(AutomationError) -> MutationResult {
        // The first resolve fixes the note: a title lookup must not follow a concurrent rename to
        // another note on a retry.
        var selector = selector
        for attempt in 0..<Self.maxAttempts {
            let (note, before) = try ReadFailure.read(library) { [selector] db -> (Note, NoteRecord) in
                let note = try NoteResolver.resolve(selector, scope: scope, db: db)
                try preflight(note)
                try NoteAccess.requireWritable(note)
                return (note, try NoteRecord.load(note, db: db, attachments: attachments))
            }
            selector = .id(note.id)
            let changed = try transform(note, NoteSections(text: note.text))
            let text = TextNormalization.normalizeLineEndings(changed)
            if text == note.text { return MutationResult(before: before, after: before) }
            beforeCommit?(attempt)
            let written: Note
            do {
                written = try guardedStore(notes: [note.id]).updateText(
                    id: note.id, text: text, expectedRevision: note.revision, now: context.now(),
                    preservingModifiedDate: preservingModifiedDate)
            } catch StoreError.revisionConflict {
                continue
            } catch {
                throw WriteFailure.wrap(error)
            }
            didCommit()
            return MutationResult(before: before, after: try record(of: written, afterCommit: true))
        }
        throw AutomationError(code: .busy, message: "The note kept changing; try again")
    }

    /// The section a write left behind: the same section index in the new text, nil when it is gone.
    static func entry(_ target: SectionTarget?, in text: String) -> OutlineEntry? {
        guard let target else { return nil }
        let sections = NoteSections(text: text)
        switch target {
        case .section(let i): guard i < sections.sections.count else { return nil }
        case .preamble(let i): guard i < sections.sections.count, sections.sections[i].preamble != nil else { return nil }
        case .lead: guard sections.lead != nil else { return nil }
        }
        return sections.entry(target)
    }

    func append(
        _ selector: NoteSelector, content: String, position: AppendPosition, address: String?,
        preservingModifiedDate: Bool
    ) throws(AutomationError) -> (MutationResult, section: OutlineEntry?) {
        var parsed: SectionAddress?
        var target: SectionTarget?
        let tagPosition = tagPosition
        let result = try mutate(
            selector, preservingModifiedDate: preservingModifiedDate,
            preflight: { _ throws(AutomationError) in parsed = try address.map { a throws(AutomationError) in try SectionAddress.parse(a) } },
            transform: { note, sections throws(AutomationError) in
                target = try parsed.map { p throws(AutomationError) in try sections.resolve(p) }
                return AppendEngine.apply(
                    content, position: position, target: target, to: note.text, tagPosition: tagPosition
                ).text
            })
        return (result, Self.entry(target, in: result.after.content ?? ""))
    }

    func edit(
        _ selector: NoteSelector, edits: [EditSpec], address: String?, gate: AttachmentGateMode,
        preservingModifiedDate: Bool
    ) throws(AutomationError) -> (MutationResult, ops: [(index: Int, section: OutlineEntry?)]) {
        guard !edits.isEmpty else {
            throw AutomationError(code: .usage, message: "At least one edit is required")
        }
        var parsed: SectionAddress?
        var applied: EditResult?
        let result = try mutate(
            selector, preservingModifiedDate: preservingModifiedDate,
            preflight: { _ throws(AutomationError) in parsed = try address.map { a throws(AutomationError) in try SectionAddress.parse(a) } },
            transform: { note, sections throws(AutomationError) in
                let target = try parsed.map { p throws(AutomationError) in try sections.resolve(p) }
                let edited = try EditEngine.apply(edits, to: note.text, within: target)
                try checkGate(gate, note: note, newText: edited.text)
                applied = edited
                return edited.text
            })
        let text = result.after.content ?? ""
        let finalSections = NoteSections(text: text)
        let ops = (applied?.ops ?? []).map { op in
            (
                index: op.index,
                section: finalSections.innermost(at: op.firstMatch).map {
                    OutlineEntry(address: $0.address, offset: $0.offset, length: $0.length)
                }
            )
        }
        return (result, ops)
    }

    func overwrite(
        _ selector: NoteSelector, content: String, base: String?, address: String?, gate: AttachmentGateMode,
        preservingModifiedDate: Bool
    ) throws(AutomationError) -> (MutationResult, section: OutlineEntry?) {
        var parsed: SectionAddress?
        var target: SectionTarget?
        let result = try mutate(
            selector, preservingModifiedDate: preservingModifiedDate,
            preflight: { _ throws(AutomationError) in parsed = try address.map { a throws(AutomationError) in try SectionAddress.parse(a) } },
            transform: { note, sections throws(AutomationError) in
                target = try parsed.map { p throws(AutomationError) in try sections.resolve(p) }
                if let base { try checkBase(base, text: note.text, sections: sections, target: target) }
                let text = try OverwriteEngine.apply(content, to: note.text, target: target)
                try checkGate(gate, note: note, newText: text)
                return text
            })
        return (result, content.isEmpty ? nil : Self.entry(target, in: result.after.content ?? ""))
    }

    /// `base` must be the current hash of the addressed section, or of the whole note.
    private func checkBase(
        _ base: String, text: String, sections: NoteSections, target: SectionTarget?
    ) throws(AutomationError) {
        let whole = ContentHash.of(text)
        var unit = whole
        if let target {
            let range = sections.range(of: target)
            unit = ContentHash.of(String(decoding: Array(text.utf8)[range], as: UTF8.self))
        }
        let given = base.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard given != unit, given != whole else { return }
        throw AutomationError(
            code: .staleHash, message: "The note changed since it was read. Re-read it and retry.",
            details: .object([("hash", .string(unit))]))
    }

    /// A removed link counts when its file exists in the note's attachment storage or the note
    /// has a live `attachment` row for it (the bytes may still be arriving, ruling M5-R80). A link
    /// with neither loses nothing.
    func checkGate(_ mode: AttachmentGateMode, note: Note, newText: String) throws(AutomationError) {
        let candidates = AttachmentGate.removed(before: note.text, after: TextNormalization.normalizeLineEndings(newText))
        let live: Set<String> =
            candidates.isEmpty
            ? []
            : try ReadFailure.read(library) { db in
                Set(
                    try String.fetchAll(
                        db, sql: "SELECT filenameKey FROM attachment WHERE noteId = ? AND deletedAt IS NULL",
                        arguments: [note.id]))
            }
        let removed = candidates.filter {
            attachments.url(for: $0, noteId: note.id) != nil || live.contains(AttachmentFiles.fileSystemKey($0))
        }
        switch mode {
        case .cli(let force): try AttachmentGate.checkCLI(removed: removed, force: force)
        case .mcp(let expected): try AttachmentGate.checkMCP(removed: removed, expected: expected)
        }
    }

    // MARK: Create

    /// The checks `create` makes before it touches the library.
    static func validateCreate(
        title: String?, content: String, ifNotExists: Bool, template: String?
    ) throws(AutomationError) {
        if ifNotExists, cleanTitle(title) == nil {
            throw AutomationError(code: .usage, message: "--if-not-exists requires a title")
        }
        if template != nil, !content.isEmpty {
            throw AutomationError(code: .usage, message: "Provide content or a template, not both")
        }
    }

    /// Line breaks become spaces; nil for a blank title.
    static func cleanTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let flat = title.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.isEmpty ? nil : flat
    }

    /// `# <title>` as the first line after front matter, unless the text's title already reads as `title`.
    static func addingTitle(_ title: String, to text: String) -> String {
        guard !text.isEmpty else { return "# " + title }
        if CanonicalKey.make(NoteParser.metadata(for: text).title) == CanonicalKey.make(title) { return text }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let bodyStart = NoteParser.bodyStartLine(in: text)
        // A leading BOM stays first in the text, so the heading takes it over.
        if bodyStart == 0, let first = lines.first, first.unicodeScalars.first == "\u{FEFF}" {
            lines[0] = String(first.unicodeScalars.dropFirst())
            lines.insert("\u{FEFF}# " + title, at: 0)
        } else {
            lines.insert("# " + title, at: min(bodyStart, lines.count))
        }
        return lines.joined(separator: "\n")
    }

    /// `onCreated` gets the new note's id as soon as the note is stored, before its record is
    /// loaded, so a caller can undo the creation whatever fails afterwards.
    func create(
        title rawTitle: String?, content: String, tags: [String], ifNotExists: Bool, template: String?,
        onCreated: ((String) throws(AutomationError) -> Void)? = nil
    ) throws(AutomationError) -> NoteRecord {
        try Self.validateCreate(title: rawTitle, content: content, ifNotExists: ifNotExists, template: template)
        let title = Self.cleanTitle(rawTitle)
        let tags = try tags.map { raw throws(AutomationError) in try TagArgument.name(raw) }
        if ifNotExists, let title {
            do {
                let existing = try ReadFailure.read(library) { db in
                    try NoteResolver.resolve(.title(title), scope: scope, db: db)
                }
                return try record(of: existing)
            } catch {
                guard error.code == .noteNotFound else { throw error }
            }
        }
        let position = tagPosition
        let now = context.now()
        let source = try template.map { reference throws(AutomationError) in try templateNote(reference) }
        do {
            if let source {
                let templateContext = TemplateContext(
                    now: now, calendar: context.calendar, locale: context.locale, clipboard: nil, title: title)
                // The scope tag goes on the note the template makes, not on the template text.
                let carried =
                    scope.onlyKeys.isEmpty
                    ? []
                    : NoteParser.metadata(
                        for: Templates.instantiate(templateText: source.text, context: templateContext).text).tags
                let extra = try scope.tagsForNewNote(carrying: carried, extra: tags)
                let (note, _) = try guardedStore(creating: true, template: source.id).createFromTemplate(
                    templateText: source.text, context: templateContext, workspace: nil, tagPosition: position,
                    extraTags: extra)
                try onCreated?(note.id)
                return try record(of: note, afterCommit: true)
            }
            var text = TextNormalization.normalizeLineEndings(content)
            if let title { text = Self.addingTitle(title, to: text) }
            let carried = NoteParser.metadata(for: text).tags
            let tokens = try NoteStore.newNoteTagTokens(
                carrying: carried, extraTags: try scope.tagsForNewNote(carrying: carried, extra: tags),
                workspace: nil)
            if !tokens.isEmpty {
                let line = tokens.joined(separator: " ")
                if text.isEmpty {
                    // The new-note layout of an empty note (ruling M5-R94).
                    text = position == .bottom ? "\n\n" + line : line + "\n\n"
                } else {
                    text = NoteStore.addingTagLine(line, to: text, position: position)
                }
            }
            let created = try guardedStore(creating: true).create(text: text, now: now)
            try onCreated?(created.id)
            return try record(of: created, afterCommit: true)
        } catch {
            throw WriteFailure.wrap(error)
        }
    }

    /// The check `capture` makes before it touches the library: the text must hold something besides
    /// whitespace (FOC-R14).
    static func validateCapture(text: String) throws(AutomationError) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AutomationError(code: .usage, message: "text must not be empty")
        }
    }

    /// `capture_thought` (FOC-R14): the text becomes a new note with `captureSource = mcp`. Nothing is
    /// titled, tagged or rewritten, with one exception that `create` shares: under a scope with a single
    /// `--only-tags` value, that tag is added on a line of its own unless the text already carries a tag
    /// that qualifies. With several scope tags the call fails like `create`, as `out_of_scope`.
    func capture(text: String) throws(AutomationError) -> NoteRecord {
        try Self.validateCapture(text: text)
        do {
            var stored = text
            let carried = scope.onlyKeys.isEmpty ? [] : NoteParser.metadata(for: text).tags
            let extra = try scope.tagsForNewNote(carrying: carried, extra: [])
            if !extra.isEmpty {
                let tokens = try NoteStore.newNoteTagTokens(carrying: carried, extraTags: extra, workspace: nil)
                if !tokens.isEmpty {
                    stored = NoteStore.addingTagLine(tokens.joined(separator: " "), to: text, position: tagPosition)
                }
            }
            let created = try guardedStore(creating: true).create(text: stored, now: context.now(), captureSource: .mcp)
            return try record(of: created, afterCommit: true)
        } catch {
            throw WriteFailure.wrap(error)
        }
    }

    /// The template named by title or id: a note in Notes tagged `#template`. Under a scope a title
    /// finds in-scope templates only and an id outside the scope is `out_of_scope`, as for any note
    /// (ruling M5-R18); the scope is checked again when the copy is written.
    private func templateNote(_ reference: String) throws(AutomationError) -> Note {
        let keys = Set(NoteStore.titleLookupKeys(reference))
        let found: Note? = try ReadFailure.read(library) { db in
            let templates = try Templates.list(db: db)
            var inScope = Set<String>()
            for template in templates where try scope.contains(template.id, db: db) { inScope.insert(template.id) }
            let hit =
                templates.first { $0.id == reference }
                ?? templates.first { inScope.contains($0.id) && keys.contains(TitleKey.make($0.title)) }
                ?? templates.first { $0.id.lowercased() == reference.lowercased() }
            if let hit {
                guard inScope.contains(hit.id) else {
                    throw AutomationError(code: .outOfScope, message: "Note is outside this server's scope: \(hit.id)")
                }
                return try Note.fetchOne(db, key: hit.id)
            }
            // A locked template is not listed, but it exists: say so rather than "not found".
            let visible = scope.predicate(note: "n")
            let lockedTemplate = """
                n.isLocked AND EXISTS (SELECT 1 FROM note_tag nt JOIN tag t ON t.id = nt.tagId
                                       WHERE nt.noteId = n.id AND t.pathKey = 'template')
                """
            let byId = try String.fetchOne(
                db,
                sql: """
                    SELECT n.id FROM note n
                    WHERE n.id = ? AND n.location = 'notes' AND n.deletedAt IS NULL AND \(lockedTemplate)
                    """,
                arguments: [reference])
            let lockedId = try byId
                ?? NoteStore.noteId(
                    forTitle: reference, filter: "\(lockedTemplate) AND (\(visible.sql))",
                    arguments: StatementArguments(visible.arguments), in: db)
            let locked = try lockedId.flatMap { try Note.fetchOne(db, key: $0) }
            if let locked, try !scope.contains(locked.id, db: db) {
                throw AutomationError(code: .outOfScope, message: "Note is outside this server's scope: \(locked.id)")
            }
            return locked
        }
        guard let found else {
            throw AutomationError(code: .noteNotFound, message: "No template with title: \(reference)")
        }
        try NoteAccess.requireReadable(found)
        return found
    }

    // MARK: Attachments

    /// The files the note's text links that exist on disk, once each, in text order (ruling M5-R5).
    private func linkedFiles(of note: Note, in db: Database) throws -> [(filename: String, url: URL)] {
        var seen = Set<String>()
        var files: [(filename: String, url: URL)] = []
        for ref in NoteParser.metadata(for: note.text).attachments {
            guard seen.insert(AttachmentFiles.fileSystemKey(ref.filename)).inserted,
                let url = try attachments.url(for: ref.filename, noteId: note.id, in: db)
            else { continue }
            files.append((ref.filename, url))
        }
        return files
    }

    /// `preflight` runs after the note is found and before the lock check, like `mutate`'s.
    func listAttachments(
        _ selector: NoteSelector, preflight: (Note) throws(AutomationError) -> Void = { _ in }
    ) throws(AutomationError) -> [(filename: String, size: Int)] {
        try ReadFailure.read(library) { db in
            let note = try NoteResolver.resolve(selector, scope: scope, db: db)
            try preflight(note)
            try NoteAccess.requireReadable(note)
            return try linkedFiles(of: note, in: db).map { file in
                (file.filename, (try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
    }

    /// The stored file of an attachment the note links: `attachment_not_found` for any other name
    /// and for a link whose file is gone.
    func attachmentFile(_ selector: NoteSelector, filename: String) throws(AutomationError) -> URL {
        try ReadFailure.read(library) { db in
            let note = try NoteResolver.resolve(selector, scope: scope, db: db)
            try NoteAccess.requireReadable(note)
            let key = AttachmentFiles.fileSystemKey(filename)
            guard let file = try linkedFiles(of: note, in: db).first(where: { AttachmentFiles.fileSystemKey($0.filename) == key })
            else { throw Self.attachmentNotFound(filename) }
            return file.url
        }
    }

    static func tooLarge(_ limit: Int) -> String {
        "Attachment is larger than \(URLFetchPolicy.describe(limit: limit))"
    }

    private static func attachmentNotFound(_ filename: String) -> AutomationError {
        AutomationError(code: .attachmentNotFound, message: "Attachment not found: \(filename)")
    }

    /// Stores `data` in the note's attachment folder (the app's rules: a unique name, a quarantine
    /// record), then appends its link at the end of the note on a line of its own. The file is
    /// placed once, after the note passed the lock and read-only checks, however often the write
    /// retries. Returns the name the file got.
    ///
    /// `compose` (x-callback `add-file`) decides where the link goes: it gets the link, the note
    /// and its sections and returns the whole new text; without it the link is appended.
    func addAttachment(
        _ selector: NoteSelector, data: Data, filename: String, preservingModifiedDate: Bool,
        compose: ((_ link: String, _ note: Note, _ sections: NoteSections) throws(AutomationError) -> String)? = nil
    ) throws(AutomationError) -> (MutationResult, filename: String) {
        guard let name = AttachmentName.clean(filename) else {
            throw AutomationError(code: .usage, message: "Invalid filename: \(filename)")
        }
        guard data.count <= context.maxAttachmentBytes else {
            throw AutomationError(code: .usage, message: Self.tooLarge(context.maxAttachmentBytes))
        }
        var placed: (name: String, noteId: String)?
        var committed = false
        let tagPosition = tagPosition
        do throws(AutomationError) {
            let result = try mutate(
                selector, preservingModifiedDate: preservingModifiedDate, didCommit: { committed = true }
            ) { note, sections throws(AutomationError) in
                if placed == nil {
                    do {
                        placed = (try attachments.add(data: data, filename: name, to: note.id), note.id)
                    } catch {
                        throw WriteFailure.wrap(error)
                    }
                }
                let link = AttachmentMarkdown.link(for: placed?.name ?? name)
                if let compose { return try compose(link, note, sections) }
                return AppendEngine.apply(link, position: .end, target: nil, to: note.text, tagPosition: tagPosition).text
            }
            return (result, placed?.name ?? name)
        } catch {
            // The file was put down before the guarded commit. When the write failed for good (out of
            // scope, busy, ...) no text links it: take it away again. After a commit it stays (M5-R172).
            if !committed, let placed {
                Self.discard(placed.name, of: placed.noteId, remove: attachments.delete, report: Self.logCleanupFailure)
            }
            throw error
        }
    }

    /// Removes a file a failed write put down. A removal that fails is reported (file name and note
    /// id, never text) and does not replace the error the caller gets (ruling M5-R179).
    static func discard(
        _ name: String, of noteId: String, remove: (String, String) throws -> Void,
        report: (String, String, any Error) -> Void
    ) {
        do {
            try remove(name, noteId)
        } catch {
            report(name, noteId, error)
        }
    }

    private static let logger = Logger(subsystem: "com.truebrewbirdie.baerchen", category: "automation")

    private static func logCleanupFailure(_ name: String, _ noteId: String, _ error: any Error) {
        logger.error(
            "Could not remove attachment \(name, privacy: .private) of note \(noteId, privacy: .public) after a failed write: \(error.localizedDescription, privacy: .private)"
        )
    }

    /// Fetches `url`, then `addAttachment`. The name is `filename`, else the one the fetch
    /// suggested (`Content-Disposition`, then the URL's last path component). A locked or read-only
    /// note is refused before anything is fetched.
    func addAttachment(
        _ selector: NoteSelector, url: URL, filename: String?, preservingModifiedDate: Bool
    ) async throws(AutomationError) -> (MutationResult, filename: String) {
        try URLFetchPolicy.check(url)
        let named: String?
        if let filename {
            guard let clean = AttachmentName.clean(filename) else {
                throw AutomationError(code: .usage, message: "Invalid filename: \(filename)")
            }
            named = clean
        } else {
            named = nil
        }
        let (note, _) = try resolveWritable(selector, textWrite: true)
        let fetched: (data: Data, suggestedName: String?)
        do {
            fetched = try await context.fetcher.fetch(url)
        } catch let error as AutomationError {
            throw error
        } catch {
            throw URLFetchPolicy.fetchFailed(error.localizedDescription)
        }
        guard fetched.data.count <= context.maxAttachmentBytes else {
            throw URLFetchPolicy.fetchFailed("larger than \(URLFetchPolicy.describe(limit: context.maxAttachmentBytes))")
        }
        guard !fetched.data.isEmpty else { throw URLFetchPolicy.fetchFailed("empty response") }
        guard let name = named ?? AttachmentName.clean(fetched.suggestedName) else {
            throw AutomationError(
                code: .invalidURL, message: "Could not tell a filename from the URL; use --filename")
        }
        return try addAttachment(
            .id(note.id), data: fetched.data, filename: name, preservingModifiedDate: preservingModifiedDate)
    }

    /// Takes every link to the file out of the note (ruling M5-R5: the file itself stays; the app's
    /// cleanup removes it, R23). `attachment_not_found` when the text links no such file.
    func deleteAttachment(
        _ selector: NoteSelector, filename: String, preservingModifiedDate: Bool
    ) throws(AutomationError) -> MutationResult {
        try mutate(selector, preservingModifiedDate: preservingModifiedDate) { note, _ throws(AutomationError) in
            guard let text = try AttachmentLinkRemoval.remove(filename, from: note.text) else {
                throw Self.attachmentNotFound(filename)
            }
            return text
        }
    }

    // MARK: Tags

    func addTags(_ selector: NoteSelector, tags: [String]) throws(AutomationError) -> MutationResult {
        try changeTags(selector, tags: tags) { store, names, id, position in
            try store.addTags(names, to: [id], position: position, now: context.now(), preservingModifiedDate: true)
        }
    }

    func removeTags(_ selector: NoteSelector, tags: [String]) throws(AutomationError) -> MutationResult {
        try changeTags(selector, tags: tags) { store, names, id, _ in
            try store.removeTags(names, from: [id], now: context.now(), preservingModifiedDate: true)
        }
    }

    private func changeTags(
        _ selector: NoteSelector, tags: [String],
        _ apply: (NoteStore, [String], String, TagPosition) throws -> Void
    ) throws(AutomationError) -> MutationResult {
        guard !tags.isEmpty else { throw AutomationError(code: .usage, message: "At least one tag is required") }
        let names = try tags.map { raw throws(AutomationError) in try TagArgument.name(raw) }
        let (note, before) = try resolveWritable(selector, textWrite: true)
        let position = tagPosition
        beforeCommit?(0)
        do {
            // One transaction for all the names, checked against the scope when it starts and
            // before it commits.
            try apply(guardedStore(notes: [note.id]), names, note.id, position)
        } catch {
            throw WriteFailure.wrap(error)
        }
        return MutationResult(before: before, after: try record(id: note.id, afterCommit: true))
    }

    /// The note, refused when locked (and, for a write to its text, when read-only).
    private func resolveWritable(
        _ selector: NoteSelector, textWrite: Bool
    ) throws(AutomationError) -> (Note, NoteRecord) {
        try ReadFailure.read(library) { db -> (Note, NoteRecord) in
            let note = try NoteResolver.resolve(selector, scope: scope, db: db)
            if textWrite { try NoteAccess.requireWritable(note) } else { try NoteAccess.requireReadable(note) }
            return (note, try NoteRecord.load(note, db: db, attachments: attachments))
        }
    }

    /// Renames `old` and its descendants in every note; returns the notes rewritten. A missing
    /// `old` is a silent no-op (0). `new` already in use needs `force` (a merge); a locked note
    /// carrying the tag or a child refuses the whole rename.
    func renameTag(old rawOld: String, new rawNew: String, force: Bool) throws(AutomationError) -> Int {
        let (old, new) = try Self.validateRename(old: rawOld, new: rawNew)
        let oldKey = CanonicalKey.make(old)
        let newKey = CanonicalKey.make(new)
        // Both names: merging into a tag that notes outside the scope carry is as much a change of
        // their state as renaming one of theirs (ruling M5-R174).
        try refuseTagChange(
            [(oldKey, old), (newKey, new)], subjects: [(oldKey, old), (newKey, new)], rewritten: (oldKey, old))
        let (oldExists, newExists, locked) = try tagState(oldKey: oldKey, newKey: newKey)
        guard oldExists else { return 0 }
        if newExists, newKey != oldKey, !force {
            throw AutomationError(
                code: .tagExists, message: "Tag already exists: \(NoteRecord.tagToken(new)). Use --force to merge.")
        }
        if locked { throw Self.lockedNotes }
        beforeCommit?(0)
        do {
            let result = try guardedStore(tags: [(oldKey, old), (newKey, new)], rewriting: (oldKey, old)).renameTag(
                old, to: new, now: context.now(), preservingModifiedDate: true)
            return result.changedNoteIds.count
        } catch StoreError.tagNotFound {
            return 0
        } catch {
            throw WriteFailure.wrap(error)
        }
    }

    /// The normalized names of a rename, or `usage`: checks that need no library (M5-R45).
    static func validateRename(old rawOld: String, new rawNew: String) throws(AutomationError) -> (String, String) {
        let old = try TagArgument.name(rawOld)
        let new = try TagArgument.name(rawNew)
        if NoteType.isReservedWorkspace(path: new) {
            throw AutomationError(code: .usage, message: "\(NoteRecord.tagToken(new)) is a reserved tag name")
        }
        if NoteStore.isRenameIntoOwnSubtree(old, to: new) {
            throw AutomationError(
                code: .usage, message: "A tag cannot be renamed into its own subtree: \(old) -> \(new)")
        }
        return (old, new)
    }

    /// Removes the tag and its descendants from every note; returns the notes rewritten.
    func deleteTag(_ rawName: String) throws(AutomationError) -> Int {
        let name = try TagArgument.name(rawName)
        let key = CanonicalKey.make(name)
        try refuseTagChange([(key, name)], subjects: [(key, name)], rewritten: (key, name))
        let (exists, _, locked) = try tagState(oldKey: key, newKey: key)
        guard exists else { return 0 }
        if locked { throw Self.lockedNotes }
        beforeCommit?(0)
        do {
            return try guardedStore(tags: [(key, name)], rewriting: (key, name)).deleteTag(
                name, now: context.now(), preservingModifiedDate: true
            ).changedNoteIds.count
        } catch StoreError.tagNotFound {
            return 0
        } catch {
            throw WriteFailure.wrap(error)
        }
    }

    /// Under a scope: refuses `tags` that define it (pure, no library) and any of `subjects` that a
    /// note outside the scope carries (ruling M5-R142). The write checks the second again inside its
    /// transaction; checking first keeps a refused caller from learning anything from the later
    /// `tag_exists` / `locked_notes` answers.
    private func refuseTagChange(
        _ tags: [(key: String, name: String)], subjects: [(key: String, name: String)],
        rewritten: (key: String, name: String)
    ) throws(AutomationError) {
        guard scope.isRestricted else { return }
        try scope.refuseTagChange(tags)
        try ReadFailure.read(library) { db in
            for subject in subjects { try scope.refuseTagCarriedOutside(subject.key, name: subject.name, db: db) }
            try scope.refuseHiddenTagRows(below: rewritten.key, name: rewritten.name, db: db)
        }
    }

    private static let lockedNotes = AutomationError(
        code: .lockedNotes, message: "A locked note uses this tag. Unlock it in Theo Notes first.")

    /// Whether the tag (or a descendant) exists, whether `newKey` exists, and whether a locked
    /// note carries the tag or a descendant (`note_tag` holds ancestors, so the tag's own rows
    /// cover its subtree).
    private func tagState(oldKey: String, newKey: String) throws(AutomationError) -> (Bool, Bool, Bool) {
        try ReadFailure.read(library) { db in
            // Under a scope only tags that in-scope notes carry exist for the caller: no
            // `tag_exists` answer about tags only hidden notes use, and no rename or delete of a
            // tag row no visible note carries (ruling M5-R175).
            let visible = scope.predicate(note: "n")
            let keys = try String.fetchAll(
                db,
                sql: scope.isRestricted
                    ? """
                        SELECT DISTINCT t.pathKey FROM tag t JOIN note_tag vnt ON vnt.tagId = t.id
                        JOIN note n ON n.id = vnt.noteId WHERE (\(visible.sql))
                        """
                    : "SELECT pathKey FROM tag",
                arguments: StatementArguments(scope.isRestricted ? visible.arguments : []))
            let oldExists = keys.contains { $0 == oldKey || $0.hasPrefix(oldKey + "/") }
            let newExists = keys.contains(newKey)
            let locked =
                try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT EXISTS (SELECT 1 FROM note n JOIN note_tag nt ON nt.noteId = n.id
                            JOIN tag t ON t.id = nt.tagId WHERE n.isLocked AND t.pathKey = ?)
                        """,
                    arguments: [oldKey]) ?? false
            return (oldExists, newExists, locked)
        }
    }

    // MARK: Pins

    func addPins(_ selector: NoteSelector, targets: [String]) throws(AutomationError) -> MutationResult {
        try changePins(selector, targets: targets, pinned: true)
    }

    func removePins(_ selector: NoteSelector, targets: [String]) throws(AutomationError) -> MutationResult {
        try changePins(selector, targets: targets, pinned: false)
    }

    /// `global`, or tag names. Every tag must exist (and, to pin, be carried by the note) before
    /// anything changes.
    private func changePins(
        _ selector: NoteSelector, targets: [String], pinned: Bool
    ) throws(AutomationError) -> MutationResult {
        guard !targets.isEmpty else {
            throw AutomationError(code: .usage, message: "At least one pin target is required")
        }
        var global = false
        var tagNames: [String] = []
        for raw in targets {
            if raw.trimmingCharacters(in: .whitespaces).lowercased() == "global" {
                global = true
            } else if let name = try? TagArgument.name(raw) {
                tagNames.append(name)
            } else {
                throw AutomationError(code: .tagNotFound, message: "Tag not found: \(raw)")
            }
        }
        let (note, before) = try resolveWritable(selector, textWrite: false)
        try ReadFailure.read(library) { db in
            // Under a scope a tag that no in-scope note carries does not exist for the caller, so
            // the answer is the same as for an unknown tag (ruling M5-R173).
            let visible = scope.predicate(note: "n")
            let tagSQL =
                scope.isRestricted
                ? """
                    SELECT t.id FROM tag t WHERE t.pathKey = ? AND EXISTS (
                        SELECT 1 FROM note_tag vnt JOIN note n ON n.id = vnt.noteId
                        WHERE vnt.tagId = t.id AND (\(visible.sql)))
                    """
                : "SELECT id FROM tag WHERE pathKey = ?"
            for name in tagNames {
                guard
                    let tagId = try String.fetchOne(
                        db, sql: tagSQL,
                        arguments: StatementArguments([CanonicalKey.make(name)] + (scope.isRestricted ? visible.arguments : [])))
                else {
                    throw AutomationError(code: .tagNotFound, message: "Tag not found: \(NoteRecord.tagToken(name))")
                }
                guard pinned else { continue }
                let carried =
                    try Bool.fetchOne(
                        db, sql: "SELECT EXISTS (SELECT 1 FROM note_tag WHERE noteId = ? AND tagId = ?)",
                        arguments: [note.id, tagId]) ?? false
                guard carried else {
                    throw AutomationError(
                        code: .tagNotFound, message: "Note is not tagged \(NoteRecord.tagToken(name))")
                }
            }
        }
        beforeCommit?(0)
        do {
            // One transaction for every target: a refusal rolls all of them back (ruling M5-R177).
            try guardedStore(notes: [note.id]).setPins([note.id], pinned: pinned, inTags: tagNames, global: global)
        } catch {
            throw WriteFailure.wrap(error)
        }
        return MutationResult(before: before, after: try record(id: note.id, afterCommit: true))
    }

    // MARK: Location

    func trash(_ selector: NoteSelector) throws(AutomationError) -> MutationResult {
        try relocate(selector, unless: .trash) { try $0.trash([$1], now: context.now()) }
    }

    func archive(_ selector: NoteSelector) throws(AutomationError) -> MutationResult {
        try relocate(selector, unless: .archive) { try $0.archive([$1], now: context.now()) }
    }

    /// Back to Notes; a note already there is left alone.
    func restore(_ selector: NoteSelector) throws(AutomationError) -> MutationResult {
        try relocate(selector, unless: .notes) { try $0.restore([$1]) }
    }

    /// A note already in `location` is left alone (moving it again would restart its trash or
    /// archive date).
    private func relocate(
        _ selector: NoteSelector, unless location: NoteLocation, _ apply: (NoteStore, String) throws -> Void
    ) throws(AutomationError) -> MutationResult {
        let (note, before) = try resolveWritable(selector, textWrite: false)
        if note.location == location { return MutationResult(before: before, after: before) }
        beforeCommit?(0)
        do {
            try apply(guardedStore(notes: [note.id]), note.id)
        } catch {
            throw WriteFailure.wrap(error)
        }
        return MutationResult(before: before, after: try record(id: note.id, afterCommit: true))
    }
}

/// The highest `note` rowid before a create, kept between the two stages of a guarded write.
private final class RowMark: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int64 = 0
    var value: Int64 {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// A tag as a command line or MCP argument gives it: surrounding `#` and whitespace stripped.
enum TagArgument {
    static func name(_ raw: String) throws(AutomationError) -> String {
        var scalars = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        while scalars.first == "#" { scalars = scalars.dropFirst() }
        while scalars.last == "#" { scalars = scalars.dropLast() }
        let name = scalars.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AutomationError(code: .usage, message: "A tag name must not be empty") }
        do {
            return try NoteStore.tagToken(name).name
        } catch {
            throw AutomationError(code: .usage, message: "Invalid tag name: \(raw)")
        }
    }

    /// `--tags`: comma-separated; empty entries are dropped.
    static func list(_ raw: String?) throws(AutomationError) -> [String] {
        guard let raw else { return [] }
        return try raw.split(separator: ",", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.trimmingCharacters(in: CharacterSet(charactersIn: "#")).isEmpty }
            .map { raw throws(AutomationError) in try name(raw) }
    }
}
