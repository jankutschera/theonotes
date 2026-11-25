// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import GRDB

/// App Intents use the current app library supplied by their host, never an independent store.
/// Protected notes stay outside automation even while their interactive vault is unlocked.
@MainActor
final class MobileShortcutService {
    enum Failure: LocalizedError, Equatable {
        case accessDenied, noteUnavailable, readOnly
        var errorDescription: String? {
            switch self {
            case .accessDenied: "Open and unlock Theo Notes before running this shortcut."
            case .noteUnavailable: "This note is unavailable to Shortcuts. It may have been deleted, moved to Trash or password protected."
            case .readOnly: "Restore this note to Notes and turn off read-only mode before appending text."
            }
        }
    }

    private let library: MobileLibrary
    init(library: MobileLibrary) { self.library = library }

    func create(text: String, title: String?) throws -> Note {
        try prepare()
        let source = title.map { "# " + $0 + "\n" + text } ?? text
        let note = try library.store.create(text: source)
        try library.refreshSessions()
        try library.reveal(note.id)
        return note
    }

    func append(text: String, to id: String) throws -> Note {
        try prepare()
        let current = try accessibleNote(id)
        guard current.location == .notes, !current.isReadOnly else { throw Failure.readOnly }
        let note = try library.store.updateText(id: id, text: current.text + text, expectedRevision: current.revision)
        try library.refreshSessions()
        return note
    }

    func note(id: String) throws -> Note {
        try prepare()
        return try accessibleNote(id)
    }

    /// The shared parser handles tags, phrases and Bear search operators. Apply privacy filters
    /// before LIMIT so protected results cannot hide eligible notes or escape through entities.
    func find(query: String, limit: Int = 50) throws -> [Note] {
        try prepare()
        let limit = min(100, max(0, limit))
        guard limit > 0 else { return [] }
        let expression = SearchParser.parse(query)
        let notes = SearchCompiler.compile(expression, scope: .notes, sort: .modifiedDescending, now: .now, calendar: .current)
        let archive = SearchCompiler.compile(expression, scope: .archive, sort: .modifiedDescending, now: .now, calendar: .current)
        return try library.database.pool.read { db in
            try Note.fetchAll(db, sql: """
                SELECT n.* FROM note n
                WHERE n.id IN (SELECT id FROM (\(notes.sql)) UNION SELECT id FROM (\(archive.sql)))
                  AND NOT n.isLocked AND n.location != 'trash' AND n.deletedAt IS NULL
                ORDER BY n.modifiedAt DESC, n.id DESC LIMIT ?
                """, arguments: notes.arguments + archive.arguments + StatementArguments([limit]))
        }
    }

    func open(id: String) throws {
        try prepare()
        let note = try accessibleNote(id)
        try library.reveal(note.id)
    }

    private func prepare() throws {
        guard !library.appLocked, !library.isClosed, !library.isClosing, !library.libraryOperationBusy else { throw Failure.accessDenied }
        try library.flush()
    }

    private func accessibleNote(_ id: String) throws -> Note {
        guard let note = try library.store.note(id: id), !note.isLocked, note.location != .trash, note.deletedAt == nil else {
            throw Failure.noteUnavailable
        }
        return note
    }
}
