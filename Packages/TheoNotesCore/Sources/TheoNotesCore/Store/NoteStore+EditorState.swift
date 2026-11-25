// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

/// Device-local editing position. Updating it never changes the note revision or modification date.
public struct NoteEditorState: Equatable, Sendable {
    public var selection: SelectionRange?
    public var scrollTop: Double?
    public init(selection: SelectionRange? = nil, scrollTop: Double? = nil) {
        self.selection = selection; self.scrollTop = scrollTop
    }
}

extension NoteStore {
    public func editorState(noteID: String) throws -> NoteEditorState {
        try db.pool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT selection, scrollTop FROM note_ui_state WHERE noteId = ?", arguments: [noteID]) else { return NoteEditorState() }
            let json: String? = row["selection"]
            let selection = try json.map { try JSONDecoder().decode(SelectionRange.self, from: Data($0.utf8)) }
            return NoteEditorState(selection: selection, scrollTop: row["scrollTop"])
        }
    }

    public func saveEditorState(noteID: String, selection: SelectionRange? = nil, scrollTop: Double? = nil) throws {
        guard !noteID.isEmpty, scrollTop?.isFinite != false, (scrollTop ?? 0) >= 0 else { return }
        let json = try selection.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try db.pool.write { db in
            guard let note = try Note.fetchOne(db, key: noteID), note.deletedAt == nil, !note.isLocked else { return }
            try db.execute(sql: """
                INSERT INTO note_ui_state (noteId, selection, scrollTop) VALUES (?, ?, ?)
                ON CONFLICT(noteId) DO UPDATE SET selection = COALESCE(excluded.selection, selection),
                    scrollTop = COALESCE(excluded.scrollTop, scrollTop)
                """, arguments: [noteID, json, scrollTop])
        }
    }

    public func setReadOnly(_ id: String, readOnly: Bool) throws {
        try write { db in
            let note = try Self.require(id, in: db)
            guard note.deletedAt == nil else { throw StoreError.noteNotFound(id: id) }
            try db.execute(sql: "UPDATE note SET isReadOnly = ?, revision = revision + 1 WHERE id = ? AND isReadOnly != ?", arguments: [readOnly, id, readOnly])
        }
    }
}
