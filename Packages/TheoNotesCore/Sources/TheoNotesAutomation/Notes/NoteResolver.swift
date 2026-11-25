// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import GRDB

/// Turns whatever a database call threw into the error a command reports.
enum ReadFailure {
    static func wrap(_ error: any Error) -> AutomationError {
        if let error = error as? AutomationError { return error }
        if let error = error as? DatabaseError, error.resultCode.primaryResultCode == .SQLITE_BUSY {
            return AutomationError(code: .busy, message: "The library is busy. Try again in a moment.")
        }
        return AutomationError(code: .internal, message: "The library could not be read: \(error.localizedDescription)")
    }

    /// One read transaction on the library.
    static func read<T>(_ library: AutomationLibrary, _ body: (Database) throws -> T) throws(AutomationError) -> T {
        do {
            return try library.database.pool.read(body)
        } catch {
            throw wrap(error)
        }
    }
}

enum NoteResolver {
    /// An id is the Theo Notes id, else a Bear id of the import (`external_ref`, source `bear`), each
    /// exact first and then case-insensitive; a note in any location is found. A title is found in
    /// Notes only (as bearcli does) under the index's title key (`NoteStore.noteId(forTitle:)`:
    /// case, normalization and whitespace runs do not count); the most recently modified note wins.
    static func resolve(_ selector: NoteSelector, scope: NoteScope, db: Database) throws(AutomationError) -> Note {
        do {
            switch selector {
            case .id(let id):
                guard let note = try byId(id, db: db) else {
                    throw AutomationError(code: .noteNotFound, message: "Note not found: \(id)")
                }
                guard try scope.contains(note.id, db: db) else {
                    throw AutomationError(code: .outOfScope, message: "Note is outside this server's scope: \(note.id)")
                }
                return note
            case .title(let title):
                let inScope = scope.predicate(note: "n")
                let note = try NoteStore.noteId(
                    forTitle: title, filter: inScope.sql, arguments: StatementArguments(inScope.arguments), in: db
                ).flatMap { try Note.fetchOne(db, key: $0) }
                guard let note else {
                    throw AutomationError(
                        code: .noteNotFound,
                        message: "No active note has the title \(title). Trashed and archived notes can only be named by ID.")
                }
                return note
            }
        } catch {
            throw ReadFailure.wrap(error)
        }
    }

    private static func byId(_ id: String, db: Database) throws -> Note? {
        let direct = "SELECT n.* FROM note n WHERE n.id = ? AND n.deletedAt IS NULL"
        let folded = "SELECT n.* FROM note n WHERE lower(n.id) = lower(?) AND n.deletedAt IS NULL ORDER BY n.id LIMIT 1"
        let linked = """
            SELECT n.* FROM note n JOIN external_ref r ON r.noteId = n.id
            WHERE r.source = ? AND r.externalId = ? AND n.deletedAt IS NULL ORDER BY n.id LIMIT 1
            """
        let linkedFolded = """
            SELECT n.* FROM note n JOIN external_ref r ON r.noteId = n.id
            WHERE r.source = ? AND lower(r.externalId) = lower(?) AND n.deletedAt IS NULL ORDER BY n.id LIMIT 1
            """
        let attempts: [(String, StatementArguments)] = [
            (direct, [id]), (linked, [BearImporter.source, id]), (folded, [id]),
            (linkedFolded, [BearImporter.source, id]),
        ]
        for (sql, arguments) in attempts {
            if let note = try Note.fetchOne(db, sql: sql, arguments: arguments) { return note }
        }
        return nil
    }
}
