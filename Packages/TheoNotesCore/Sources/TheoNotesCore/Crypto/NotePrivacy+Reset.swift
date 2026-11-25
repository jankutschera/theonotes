// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

public enum NotePasswordResetError: LocalizedError, Equatable, Sendable {
    case lockedNotesRemain, trashNotEmpty
    public var errorDescription: String? {
        switch self {
        case .lockedNotesRemain: "Unlock or delete all locked notes first, including locked notes in Trash. No notes were deleted."
        case .trashNotEmpty: "Empty Trash yourself before deleting the notes password. No notes were deleted."
        }
    }
}

public struct NotePasswordResetStatus: Sendable {
    public let hasPassword: Bool
    public let lockedNotes: Int
    public let trashedNotes: Int
    public var canReset: Bool { hasPassword && lockedNotes == 0 && trashedNotes == 0 }
}

extension NotePrivacy {
    public func passwordResetStatus() throws -> NotePasswordResetStatus {
        try store.db.pool.read { db in
            NotePasswordResetStatus(
                hasPassword: try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM crypto_envelope)") == true,
                lockedNotes: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note WHERE isLocked=1") ?? 0,
                trashedNotes: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note WHERE location='trash'") ?? 0)
        }
    }

    /// Emergency reset after the user unlocks/deletes protected notes and empties Trash.
    /// Callers stop sync, flush sessions and revoke every cached access/biometric key first.
    /// No note or attachment is deleted here. Existing semantic triggers capture the envelope
    /// deletion as a keyBundle tombstone without replacing immutable pending mutations.
    public func deletePassword() throws {
        try store.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM note WHERE isLocked=1)") != true else { throw NotePasswordResetError.lockedNotesRemain }
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM note WHERE location='trash')") != true else { throw NotePasswordResetError.trashNotEmpty }
            guard try Int.fetchOne(db, sql: "SELECT (SELECT COUNT(*) FROM staging_batch)+(SELECT COUNT(*) FROM privacy_transition)") == 0 else { throw NotePrivacyError.pendingAttachments }
            for file in try FileManager.default.contentsOfDirectory(at: store.paths.journal, includingPropertiesForKeys: [.fileSizeKey]) {
                let journalBytes = file.pathExtension == "jsonl" ? try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 : 0
                if file.lastPathComponent.contains(".unreplayed") || journalBytes > 0 {
                    throw NotePrivacyError.pendingEdits
                }
            }
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM crypto_envelope)") == true else { throw NotePrivacyError.passwordNotSet }
            try db.execute(sql: "DELETE FROM crypto_envelope WHERE id=1")
        }
    }
}
