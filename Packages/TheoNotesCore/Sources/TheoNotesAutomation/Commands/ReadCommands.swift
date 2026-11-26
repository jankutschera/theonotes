// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import GRDB

/// `list`, `search`, `show`, `tags list` and `pin list`. Each checks its arguments before it asks
/// for the library, so usage errors come before library errors.
enum ReadCommands {
    static let handlers: [[String]: CommandHandler] = [
        ["list"]: list,
        ["search"]: search,
        ["show"]: show,
        ["tags", "list"]: tagsList,
        ["pin", "list"]: pinList,
    ]

    // MARK: list

    private static func list(_ parsed: ParsedCommand, _ env: CommandEnvironment) throws(AutomationError) {
        let paging = try Paging(parsed)
        let location = try LocationFilter.parse(parsed.value("--location"))
        let sort = try SortSpec.parse(parsed.value("--sort"))
        let counting = parsed.flag("--count")
        let fields = counting ? [] : try NoteFields.parse(parsed.fieldsArgument, spec: parsed.spec)
        let library = try env.library()
        // `-n 0` prints nothing (observed), so there is no query to run.
        if paging.limit == 0, !counting { return }
        let (records, total) = try ReadFailure.read(library) { db in
            // `--count` reads no rows: one COUNT(*), whatever `-n` says.
            let found = try AutomationQueries.listNotes(
                location: location, tag: parsed.value("--tag"), sort: sort, limit: counting ? 0 : paging.limit,
                offset: paging.offset, scope: .unrestricted, countTotal: counting, db: db)
            guard !counting else { return ([NoteRecord](), found.total) }
            let attachments = AttachmentStore(paths: library.paths, database: library.database)
            return (try NoteRecord.loadMany(found.notes, db: db, attachments: attachments, fields: Set(fields)), 0)
        }
        if counting { return writeCount(total, format: parsed.format, env: env) }
        let rows = records.map { record in fields.map { record.cliValue($0) } }
        writeRows(rows, fields: fields, format: parsed.format, emptyMessage: "No notes found.", env: env)
    }

    // MARK: search

    private static func search(_ parsed: ParsedCommand, _ env: CommandEnvironment) throws(AutomationError) {
        let positional = parsed.positionals.first
        let option = parsed.value("--query")
        if positional != nil, option != nil {
            throw AutomationError(
                code: .usage, message: "Specify the query as a positional argument or --query, not both")
        }
        guard let query = positional ?? option, !query.isEmpty else {
            throw AutomationError(code: .usage, message: "Query is required")
        }
        let paging = try Paging(parsed)
        let location = try LocationFilter.parse(parsed.value("--location"))
        let sort = try SortSpec.parse(parsed.value("--sort"))
        let counting = parsed.flag("--count")
        let fields = counting ? [] : try NoteFields.parse(parsed.fieldsArgument, spec: parsed.spec)
        let library = try env.library()
        if paging.limit == 0, !counting { return }
        let (records, matches, total) = try ReadFailure.read(library) { db in
            let found = try AutomationQueries.searchNotes(
                query, location: location, sort: sort, limit: counting ? 0 : paging.limit, offset: paging.offset,
                scope: .unrestricted, now: env.context.now(), calendar: env.context.calendar,
                locale: env.context.locale, countTotal: counting, db: db)
            guard !counting else { return ([NoteRecord](), [String: Int](), found.total) }
            let attachments = AttachmentStore(paths: library.paths, database: library.database)
            let records = try NoteRecord.loadMany(
                found.hits.map(\.note), db: db, attachments: attachments, fields: Set(fields))
            return (records, Dictionary(found.hits.map { ($0.note.id, $0.matches) }, uniquingKeysWith: { first, _ in first }), 0)
        }
        if counting { return writeCount(total, format: parsed.format, env: env) }
        let rows = records.map { record in
            fields.map { $0 == "matches" ? FieldValue.int(matches[record.id] ?? 0) : record.cliValue($0) }
        }
        writeRows(rows, fields: fields, format: parsed.format, emptyMessage: "No notes found.", env: env)
    }

    // MARK: show

    private static func show(_ parsed: ParsedCommand, _ env: CommandEnvironment) throws(AutomationError) {
        let selector = try NoteSelector.parse(id: parsed.positionals.first, title: parsed.value("--title"))
        let library = try env.library()
        let (record, fields) = try ReadFailure.read(library) { db -> (NoteRecord, [String]) in
            let note = try NoteResolver.resolve(selector, scope: .unrestricted, db: db)
            let fields = try NoteFields.parse(parsed.fieldsArgument, spec: parsed.spec)
            if fields.contains("content") { try NoteAccess.requireReadable(note) }
            let attachments = AttachmentStore(paths: library.paths, database: library.database)
            return (try NoteRecord.load(note, db: db, attachments: attachments), fields)
        }
        writeRecord(record, fields: fields, format: parsed.format, env: env)
    }

    /// One note: a JSON object, or a single CSV (with header) or TSV row.
    static func writeRecord(_ record: NoteRecord, fields: [String], format: OutputFormat, env: CommandEnvironment) {
        let row = fields.map { record.cliValue($0) }
        switch format {
        case .json:
            let object = RecordWriter.jsonObject(Array(zip(fields, row)))
            env.io.write(Data((object.serialized(sortedKeys: false) + "\n").utf8))
        case .csv:
            env.io.write(Data(RecordWriter.csv(header: fields, [row]).utf8))
        case .tsv:
            env.io.write(Data(RecordWriter.tsv([row]).utf8))
        }
    }

    // MARK: tags list

    private static func tagsList(_ parsed: ParsedCommand, _ env: CommandEnvironment) throws(AutomationError) {
        let selector = try optionalSelector(parsed)
        let counting = parsed.flag("--count")
        // Without a note there is nothing to look up first, so the fields are checked before the
        // library; with a note, as in `show`, the note resolves first.
        var fields: [String] = []
        if selector == nil, !counting { fields = try NoteFields.parse(parsed.fieldsArgument, spec: parsed.spec) }
        let library = try env.library()
        let tokens = try ReadFailure.read(library) { db -> [String] in
            if let selector {
                let note = try NoteResolver.resolve(selector, scope: .unrestricted, db: db)
                if !counting { fields = try NoteFields.parse(parsed.fieldsArgument, spec: parsed.spec) }
                let attachments = AttachmentStore(paths: library.paths, database: library.database)
                let record = try NoteRecord.loadMany([note], db: db, attachments: attachments, fields: ["tags"])[0]
                return record.tags.map(NoteRecord.tagToken)
            }
            return try allTagNames(scope: .unrestricted, db: db).map(NoteRecord.tagToken)
        }
        if counting { return writeCount(tokens.count, format: parsed.format, env: env) }
        let rows = tokens.map { token in fields.map { _ in FieldValue.string(token) } }
        writeRows(rows, fields: fields, format: parsed.format, emptyMessage: nil, env: env)
    }

    /// Display paths of the tags that have a note in Notes (ancestors of a used tag included, as
    /// the index keeps them), sorted by tag key.
    static func allTagNames(scope: NoteScope, db: Database) throws -> [String] {
        let inScope = scope.predicate(note: "n")
        return try String.fetchAll(
            db,
            sql: """
                SELECT t.displayPath FROM tag t
                WHERE EXISTS (
                    SELECT 1 FROM note_tag nt JOIN note n ON n.id = nt.noteId
                    WHERE nt.tagId = t.id AND n.location = 'notes' AND n.deletedAt IS NULL AND (\(inScope.sql)))
                ORDER BY t.displayPath
                """,
            arguments: StatementArguments(inScope.arguments))
    }

    // MARK: pin list

    private static func pinList(_ parsed: ParsedCommand, _ env: CommandEnvironment) throws(AutomationError) {
        let selector = try optionalSelector(parsed)
        // As in `tags list`: fields before the library when no note is named, else after the note resolves.
        var fields: [String] = []
        if selector == nil { fields = try NoteFields.parse(parsed.fieldsArgument, spec: parsed.spec) }
        let library = try env.library()
        let pins = try ReadFailure.read(library) { db -> [NoteRecord.Pin] in
            if let selector {
                let note = try NoteResolver.resolve(selector, scope: .unrestricted, db: db)
                fields = try NoteFields.parse(parsed.fieldsArgument, spec: parsed.spec)
                let attachments = AttachmentStore(paths: library.paths, database: library.database)
                return try NoteRecord.loadMany([note], db: db, attachments: attachments, fields: ["pins"])[0].pins
            }
            return try pinContextsInUse(scope: .unrestricted, db: db)
        }
        let rows = pins.map { pin in fields.map { _ in FieldValue.string(pin.cliText) } }
        writeRows(rows, fields: fields, format: parsed.format, emptyMessage: nil, env: env)
    }

    /// `global` when a note in Notes is pinned there, then each tag a note in Notes is pinned in.
    static func pinContextsInUse(scope: NoteScope, db: Database) throws -> [NoteRecord.Pin] {
        let inScope = scope.predicate(note: "n")
        var pins: [NoteRecord.Pin] = []
        let anyGlobal = try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS (SELECT 1 FROM note n WHERE n.isPinnedGlobal AND n.location = 'notes'
                    AND n.deletedAt IS NULL AND (\(inScope.sql)))
                """,
            arguments: StatementArguments(inScope.arguments)) ?? false
        if anyGlobal { pins.append(.global) }
        let tagNames = try String.fetchAll(
            db,
            sql: """
                SELECT t.displayPath FROM tag t
                WHERE EXISTS (
                    SELECT 1 FROM note_pin p JOIN note n ON n.id = p.noteId
                    WHERE p.tagId = t.id AND n.location = 'notes' AND n.deletedAt IS NULL AND (\(inScope.sql)))
                ORDER BY t.pathKey, t.displayPath
                """,
            arguments: StatementArguments(inScope.arguments))
        return pins + tagNames.map(NoteRecord.Pin.tag)
    }

    // MARK: Shared

    /// `--limit` and `--offset`. Negative values parse (`--limit=-1`) and are refused here, as bearcli does.
    private struct Paging {
        var limit: Int?
        var offset: Int

        init(_ parsed: ParsedCommand) throws(AutomationError) {
            limit = parsed.value("--limit").map { Int($0) ?? Int.max }
            offset = parsed.value("--offset").map { Int($0) ?? Int.max } ?? 0
            if let limit, limit < 0 { throw AutomationError(code: .usage, message: "Limit must be non-negative") }
            if offset < 0 { throw AutomationError(code: .usage, message: "Offset must be non-negative") }
        }
    }

    /// The note a `tags list` / `pin list` names, nil when it names none (every tag / every pin).
    private static func optionalSelector(_ parsed: ParsedCommand) throws(AutomationError) -> NoteSelector? {
        let id = parsed.positionals.first
        let title = parsed.value("--title")
        if id == nil, title == nil { return nil }
        return try NoteSelector.parse(id: id, title: title)
    }

    static func writeCount(_ count: Int, format: OutputFormat, env: CommandEnvironment) {
        let text: String
        switch format {
        case .tsv: text = "\(count)\n"
        case .csv: text = "count\n\(count)\n"
        case .json: text = JSONValue.object([("count", .int(count))]).serialized(sortedKeys: false) + "\n"
        }
        env.io.write(Data(text.utf8))
    }

    /// TSV without a header, CSV with one, JSON as an array of objects. No rows: `[]` in JSON,
    /// otherwise `emptyMessage` on stderr (nothing when it is nil); the exit code stays 0.
    static func writeRows(
        _ rows: [[FieldValue]], fields: [String], format: OutputFormat, emptyMessage: String?,
        env: CommandEnvironment
    ) {
        if rows.isEmpty {
            if format == .json {
                env.io.write(Data("[]\n".utf8))
            } else if let emptyMessage {
                env.io.writeError(emptyMessage + "\n")
            }
            return
        }
        switch format {
        case .json:
            let objects = rows.map { RecordWriter.jsonObject(Array(zip(fields, $0))) }
            env.io.write(Data((JSONValue.array(objects).serialized(sortedKeys: false) + "\n").utf8))
        case .csv:
            env.io.write(Data(RecordWriter.csv(header: fields, rows).utf8))
        case .tsv:
            env.io.write(Data(RecordWriter.tsv(rows).utf8))
        }
    }
}
