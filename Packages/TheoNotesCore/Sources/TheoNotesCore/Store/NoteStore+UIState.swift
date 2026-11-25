// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

/// Per-note editor state that is not note content (`note_ui_state`, migration v1): the folds
/// (M6 Task 8). Only line numbers and line hashes are stored, never note text. A locked note keeps
/// none: a 32-bit hash of a short heading can be found by dictionary search (M6-R81).
extension NoteStore {
    /// The stored folds of `noteId`; none when there are none, the note is locked, or the stored
    /// JSON does not decode (invalid entries are dropped, `FoldEntry.valid`).
    public func foldState(noteId: String) throws -> [FoldEntry] {
        let json = try db.pool.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT s.foldState FROM note_ui_state s JOIN note n ON n.id = s.noteId
                    WHERE s.noteId = ? AND n.isLocked = 0
                    """,
                arguments: [noteId])
        }
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode(FoldList.self, from: data).entries) ?? []
    }

    /// Stores the folds of `noteId` (at most `EditorBridge.maxFolds`). It never touches `note`:
    /// no revision or `modifiedAt` change, no index run and no change notification (Review Focus 5).
    /// A note that no longer exists stores nothing; a locked note stores nothing and loses any
    /// row written before it was locked (M6-R81).
    public func setFoldState(noteId: String, _ folds: [FoldEntry]) throws {
        let data = try JSONEncoder().encode(Array(folds.prefix(EditorBridge.maxFolds)))
        let json = String(decoding: data, as: UTF8.self)
        try db.pool.write { db in
            guard let locked = try Bool.fetchOne(db, sql: "SELECT isLocked FROM note WHERE id = ?", arguments: [noteId])
            else { return }
            if locked {
                try db.execute(sql: "DELETE FROM note_ui_state WHERE noteId = ?", arguments: [noteId])
                return
            }
            try db.execute(
                sql: """
                    INSERT INTO note_ui_state (noteId, foldState) VALUES (?, ?)
                    ON CONFLICT(noteId) DO UPDATE SET foldState = excluded.foldState
                    """,
                arguments: [noteId, json])
        }
    }
}

/// A fold list decoded leniently, as the bridge decodes `foldState.folds`.
private struct FoldList: Decodable {
    let entries: [FoldEntry]
    init(from decoder: any Decoder) throws { entries = try FoldEntry.valid(from: decoder) }
}
