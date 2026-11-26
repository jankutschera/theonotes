// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

/// The gesture that made a note. Device-local: it is not in the sync payload.
public enum CaptureSource: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case share, voice, lockscreen, shortcut, command, mcp
}

extension NoteStore {
    /// How `noteId` was captured; nil for an ordinary note or an unknown id.
    public func captureSource(noteId: String) throws -> CaptureSource? {
        try db.pool.read {
            try CaptureSource.fetchOne($0, sql: "SELECT captureSource FROM note WHERE id = ?", arguments: [noteId])
        }
    }

    /// Records that an editor loaded `noteId` (`note_ui_state.lastOpenedAt`).
    ///
    /// Like `saveEditorState`, it never touches `note`: no revision or `modifiedAt` change, no
    /// index run and no change notification. A locked, deleted or unknown note stores nothing,
    /// because a locked note has no `note_ui_state` row.
    public func recordOpened(noteId: String, now: Date = .now) throws {
        try db.pool.write { db in
            guard let note = try Note.fetchOne(db, key: noteId), note.deletedAt == nil, !note.isLocked else { return }
            try db.execute(
                sql: """
                    INSERT INTO note_ui_state (noteId, lastOpenedAt) VALUES (?, ?)
                    ON CONFLICT(noteId) DO UPDATE SET lastOpenedAt = excluded.lastOpenedAt
                    """,
                arguments: [noteId, Self.roundedToMillis(now)])
        }
    }

    /// When an editor last loaded `noteId`; nil if it never did, or the note is locked.
    public func lastOpenedAt(noteId: String) throws -> Date? {
        try db.pool.read {
            try Date.fetchOne($0, sql: """
                SELECT s.lastOpenedAt FROM note_ui_state s JOIN note n ON n.id = s.noteId
                WHERE s.noteId = ? AND n.isLocked = 0
                """, arguments: [noteId])
        }
    }

    /// Cancels a capture: moves `noteId` to the Trash, but only when it is a captured note
    /// (`captureSource` set), still in Notes and unlocked, and its text still equals `createdText`
    /// (what the gesture created). Returns whether it was trashed. An edited capture and
    /// an ordinary note are left alone.
    @discardableResult
    public func cancelCapture(noteId: String, createdText: String, now: Date = .now) throws -> Bool {
        let expected = TextNormalization.normalizeLineEndings(createdText)
        return try write { db in
            guard let note = try Note.fetchOne(db, key: noteId), note.deletedAt == nil, !note.isLocked,
                  note.location == .notes, note.text == expected,
                  try CaptureSource.fetchOne(db, sql: "SELECT captureSource FROM note WHERE id = ?", arguments: [noteId]) != nil
            else { return false }
            try db.execute(
                sql: "UPDATE note SET location = 'trash', trashedAt = ?, revision = revision + 1 WHERE id = ?",
                arguments: [Self.roundedToMillis(now), noteId])
            return true
        }
    }
}
