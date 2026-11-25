// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import GRDB

/// One note as the CLI and the MCP server describe it.
struct NoteRecord: Equatable {
    var id: String
    var title: String
    var locked: Bool
    /// The tags bearcli lists: the direct tags and every ancestor of a nested one, without `#`,
    /// spelled as the tag table spells them, in code point order (ruling M5-R232).
    var tags: [String]
    /// UTF-8 bytes of the text; 0 for a locked note.
    var length: Int
    var created: Date
    var modified: Date
    /// The global pin, then the tags the note is pinned in.
    var pins: [Pin]
    var location: NoteLocation
    /// Open tasks.
    var todos: Int
    /// Completed tasks.
    var done: Int
    /// Files the text links that exist on disk, in text order.
    var attachments: [String]
    /// nil when the note is locked: a locked note has no readable text.
    var content: String?

    /// A pin context. The kind is carried explicitly, so a tag that is named `global` is not
    /// mistaken for the global pin.
    enum Pin: Equatable {
        case global
        case tag(String)

        /// The CLI spelling: `global`, or the tag token (`#work/x`, `#multi word#`).
        var cliText: String {
            switch self {
            case .global: "global"
            case .tag(let name): NoteRecord.tagToken(name)
            }
        }

        /// The MCP spelling: `global`, or the bare tag name.
        var mcpText: String {
            switch self {
            case .global: "global"
            case .tag(let name): name
            }
        }
    }

    /// The record of one note with every field filled in.
    static func load(_ note: Note, db: Database, attachments: AttachmentStore) throws -> NoteRecord {
        try loadMany([note], db: db, attachments: attachments)[0]
    }

    /// The records of `notes`, in order. With `fields`, the work behind fields that are not asked
    /// for is skipped and those fields stay empty (a listing of ids and titles parses no text).
    static func loadMany(
        _ notes: [Note], db: Database, attachments: AttachmentStore, fields: Set<String>? = nil
    ) throws -> [NoteRecord] {
        func wants(_ field: String) -> Bool { fields?.contains(field) ?? true }
        let tagPins = try wants("pins") ? tagPinNames(db: db) : [:]
        var stats: [String: (open: Int, done: Int)] = [:]
        if wants("todos") || wants("done") {
            for start in stride(from: 0, to: notes.count, by: 800) {
                let ids = notes[start..<min(start + 800, notes.count)].map(\.id)
                let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
                let rows = try Row.fetchAll(
                    db, sql: "SELECT noteId, openTodos, doneTodos FROM note_stats WHERE noteId IN (\(marks))",
                    arguments: StatementArguments(ids))
                for row in rows { stats[row[0]] = (row[1], row[2]) }
            }
        }
        let spelling = wants("tags") ? try tagSpelling(db: db) : [:]
        return try notes.map { note in
            var pins: [Pin] = []
            if wants("pins") {
                if note.isPinnedGlobal { pins.append(.global) }
                pins += (tagPins[note.id] ?? []).map(Pin.tag)
            }
            var tags: [String] = []
            var files: [String] = []
            // Tags require '#'; both image and file attachments require a '[' opener.
            // Plain notes need no complete Markdown parse just to prove these fields empty.
            let needsText = (wants("tags") && note.text.utf8.contains(35))
                || (wants("attachments") && note.text.utf8.contains(91))
            if needsText, !note.isLocked {
                let meta = NoteParser.tagsAndAttachments(in: note.text)
                tags = listedTags(direct: meta.tags, spelling: spelling)
                if wants("attachments") {
                    for ref in meta.attachments where !files.contains(ref.filename) {
                        if try attachments.url(for: ref.filename, noteId: note.id, in: db) != nil { files.append(ref.filename) }
                    }
                }
            }
            return NoteRecord(
                id: note.id, title: note.title, locked: note.isLocked, tags: tags,
                length: note.isLocked ? 0 : note.text.utf8.count, created: note.createdAt,
                modified: note.modifiedAt, pins: pins, location: note.location,
                todos: stats[note.id]?.open ?? 0, done: stats[note.id]?.done ?? 0, attachments: files,
                content: note.isLocked ? nil : note.text)
        }
    }

    /// Tag key to the spelling the tag table keeps for it (one spelling for the whole library).
    private static func tagSpelling(db: Database) throws -> [String: String] {
        var result: [String: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT pathKey, displayPath FROM tag") { result[row[0]] = row[1] }
        return result
    }

    /// `direct` plus each ancestor of a nested tag (`a/b/c` brings `a` and `a/b`), one entry per
    /// tag key, in the table's spelling when it has one, sorted by name (ruling M5-R232).
    static func listedTags(direct: [String], spelling: [String: String]) -> [String] {
        var seen: Set<String> = []
        var names: [String] = []
        for tag in direct {
            let parts = tag.split(separator: "/", omittingEmptySubsequences: false)
            for end in 1...max(parts.count, 1) {
                let path = parts.prefix(end).joined(separator: "/")
                let key = CanonicalKey.make(path)
                if seen.insert(key).inserted { names.append(spelling[key] ?? path) }
            }
        }
        return names.sorted()
    }

    /// Note id to the display names of the tags it is pinned in. Pins are few, so one query reads them all.
    private static func tagPinNames(db: Database) throws -> [String: [String]] {
        var result: [String: [String]] = [:]
        let rows = try Row.fetchAll(
            db, sql: """
                SELECT p.noteId, t.displayPath FROM note_pin p JOIN tag t ON t.id = p.tagId
                ORDER BY t.pathKey, t.displayPath
                """)
        for row in rows { result[row[0], default: []].append(row[1]) }
        return result
    }

    // MARK: CLI

    /// `#name`, or `#name#` when an open tag would not read back as the same name.
    static func tagToken(_ name: String) -> String {
        (try? NoteStore.tagToken(name).token) ?? "#" + name
    }

    /// One cell. Tags and tag pins are written as tokens (`#work/x`, `#multi word#`); `global` stays.
    func cliValue(_ field: String) -> FieldValue {
        switch field {
        case "id": .string(id)
        case "title": .string(title)
        case "locked": .flag(locked)
        case "tags": .list(tags.map(Self.tagToken))
        case "length": .int(length)
        case "created": .string(Self.timestamp(created))
        case "modified": .string(Self.timestamp(modified))
        case "pins": .list(pins.map(\.cliText))
        case "location": .string(location.rawValue)
        case "todos": .int(todos)
        case "done": .int(done)
        case "attachments": .list(attachments)
        case "content": content.map(FieldValue.string) ?? .null
        default: .null
        }
    }

    // MARK: MCP

    /// The metadata object of an MCP result: bare tag names, a boolean `locked`, keys sorted.
    func mcpMetadata() -> JSONValue {
        .object([
            ("attachments", .array(attachments.map { .string($0) })),
            ("created", .string(Self.timestamp(created))),
            ("done", .int(done)),
            ("id", .string(id)),
            ("length", .int(length)),
            ("location", .string(location.rawValue)),
            ("locked", .bool(locked)),
            ("modified", .string(Self.timestamp(modified))),
            ("pins", .array(pins.map { .string($0.mcpText) })),
            ("tags", .array(tags.map { .string($0) })),
            ("title", .string(title)),
            ("todos", .int(todos)),
        ])
    }

    /// `yyyy-MM-dd'T'HH:mm:ss'Z'` in UTC, seconds rounded down.
    static func timestamp(_ date: Date) -> String {
        let seconds = Int((date.timeIntervalSince1970).rounded(.down))
        var days = seconds / 86_400
        var rest = seconds % 86_400
        if rest < 0 {
            rest += 86_400
            days -= 1
        }
        // Civil date from days since 1970-01-01 (proleptic Gregorian).
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        let yearText = String(year)
        let paddedYear = String(repeating: "0", count: max(0, 4 - yearText.count)) + yearText
        return "\(paddedYear)-\(two(month))-\(two(day))T\(two(rest / 3600)):\(two(rest % 3600 / 60)):\(two(rest % 60))Z"
    }
}
