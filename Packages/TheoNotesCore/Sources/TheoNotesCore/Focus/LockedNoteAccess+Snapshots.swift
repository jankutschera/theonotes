// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

/// The history of a locked note. Every member runs through `withVaultKey`, so
/// it throws `NotePrivacyError.accessRevoked` after `revoke()` and writes nothing. A note that is
/// not locked (any more) is handled like `NoteStore` does, with plaintext rows.
extension LockedNoteAccess: SnapshotWriting {
    /// A sealed snapshot of a locked note. The key is checked against the note's own payload
    /// first, so a snapshot is never sealed under a key the note does not open with.
    public func takeSnapshot(noteId: String, text: String, now: Date) throws -> NoteSnapshot? {
        try withVaultKey { key in
            try store.db.pool.write { db in
                let note = try NoteStore.require(noteId, in: db)
                guard note.isLocked else { return try NoteSnapshots.takePlain(noteId: noteId, text: text, now: now, in: db) }
                _ = try lockedText(note, key: key)
                return try NoteSnapshots.takeSealed(noteId: noteId, text: text, now: now, key: key, in: db)
            }
        }
    }

    /// Newest first, sealed ones opened for their preview.
    public func snapshots(noteId: String) throws -> [NoteSnapshot] {
        try withVaultKey { key in
            try store.db.pool.read { db in
                try NoteSnapshots.rows(noteId: noteId, in: db).map {
                    $0.snapshot(preview: NoteSnapshots.preview(try NoteSnapshots.open($0, key: key)))
                }
            }
        }
    }

    public func snapshotText(id: String) throws -> String {
        try withVaultKey { key in
            try store.db.pool.read { db in
                guard let row = try NoteSnapshots.row(id: id, in: db) else { throw SnapshotError.snapshotNotFound(id: id) }
                return try NoteSnapshots.open(row, key: key)
            }
        }
    }

    /// A locked note's copy is created locked, with its attachments re-encrypted for the copy
    /// (`createFromSelection`). The source note and its history are not touched.
    public func restoreSnapshotAsCopy(id: String, now: Date = .now) throws -> Note {
        let source = try withVaultKey { key in
            try store.db.pool.read { db -> (noteId: String, text: String, isLocked: Bool) in
                guard let row = try NoteSnapshots.row(id: id, in: db) else { throw SnapshotError.snapshotNotFound(id: id) }
                let note = try NoteStore.require(row.noteId, in: db)
                return (row.noteId, try NoteSnapshots.open(row, key: key), note.isLocked)
            }
        }
        // `withVaultKey` is not reentrant: the copy takes the key lock again on its own.
        guard source.isLocked else { return try store.restoreSnapshotAsCopy(id: id, now: now) }
        return try createFromSelection(of: source.noteId, text: source.text, now: now)
    }

    /// Replace This Note on a locked note: the current text is sealed as a snapshot first, then the
    /// snapshot's text is written, in one transaction.
    public func replaceNote(withSnapshot id: String, expectedRevision: Int, now: Date = .now) throws -> Note {
        try withVaultKey { key in
            try store.write { db in
                guard let row = try NoteSnapshots.row(id: id, in: db) else { throw SnapshotError.snapshotNotFound(id: id) }
                let note = try NoteStore.require(row.noteId, in: db)
                guard note.isLocked else {
                    return try NoteSnapshots.replacePlain(snapshotId: id, expectedRevision: expectedRevision, now: now, in: db)
                }
                guard note.revision == expectedRevision else { throw StoreError.revisionConflict(current: note.revision) }
                let restored = try NoteSnapshots.open(row, key: key)
                _ = try NoteSnapshots.takeSealed(noteId: note.id, text: try lockedText(note, key: key), now: now, key: key, in: db)
                return try writeLockedText(id: note.id, text: restored, expectedRevision: expectedRevision, now: now, key: key, in: db)
            }
        }
    }
}
