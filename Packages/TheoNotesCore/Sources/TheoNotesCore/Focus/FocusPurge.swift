// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

/// What the capture-and-next-up state does when a note becomes locked.
/// Every function runs inside the transaction that locks (or unlocks) the note, so a failure later
/// in that transaction leaves the reminders, hides and ledger exactly as they were.
///
/// The call sites are `LockedNoteAccess.purgeDerivedContent` (local lock) and
/// `SyncMaterializer.writeNote` (remote lock and remote unlock). Later tasks extend the bodies;
/// the call sites do not change again.
enum FocusPurge {
    /// The note was locked on this device.
    static func purgeLocalLock(noteId: String, in db: Database) throws {
        try purgeLock(noteId: noteId, in: db)
    }

    /// The note arrived locked through sync. The vault may not be open while sync applies, so its
    /// plaintext snapshots cannot be sealed: they are deleted. Sealed ones stay.
    static func purgeRemoteLock(noteId: String, in db: Database) throws {
        try purgeLock(noteId: noteId, in: db)
        try db.execute(sql: "DELETE FROM note_snapshot WHERE noteId = ? AND text IS NOT NULL", arguments: [noteId])
    }

    /// The note arrived unlocked through sync after being locked here. Sealed snapshots
    /// belong to locked notes only, and the vault may not be open while sync applies, so they are
    /// deleted instead of opened.
    static func purgeRemoteUnlock(noteId: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM note_snapshot WHERE noteId = ? AND sealedText IS NOT NULL", arguments: [noteId])
    }

    private static func purgeLock(noteId: String, in db: Database) throws {
        // A voice capture into this note stops before the lock commits; a failed cleanup aborts the
        // lock.
        try CaptureLockGuard.noteWillLock(noteId)
        // The ledger keeps its identifiers (cold launch removes notifications by id) but no longer
        // knows what the notification said.
        try db.execute(sql: "UPDATE notification_ledger SET contentHash = NULL WHERE noteId = ?", arguments: [noteId])
        try db.execute(sql: "DELETE FROM focus_hide WHERE noteId = ?", arguments: [noteId])
        try collapseReminders(noteId: noteId, in: db)
    }

    /// A locked note keeps one reminder, title only: the first by `(firedAt IS NOT NULL, fireAt, id)`.
    /// The others are deleted before the survivor loses its anchor, so `note_ping_target` never
    /// sees two whole-note rows.
    private static func collapseReminders(noteId: String, in db: Database) throws {
        guard let kept = try String.fetchOne(db, sql: """
            SELECT id FROM note_ping WHERE noteId = ? ORDER BY firedAt IS NOT NULL, fireAt, id LIMIT 1
            """, arguments: [noteId]) else { return }
        try db.execute(sql: "DELETE FROM note_ping WHERE noteId = ? AND id != ?", arguments: [noteId, kept])
        try db.execute(sql: "UPDATE note_ping SET anchorLine = NULL, anchorHash = NULL WHERE id = ?", arguments: [kept])
    }
}
