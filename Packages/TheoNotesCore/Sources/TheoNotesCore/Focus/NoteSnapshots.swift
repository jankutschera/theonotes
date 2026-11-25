// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB

/// One entry of a note's history (FOC-R11). Device-local: not in the note, the sync payload or
/// any export.
public struct NoteSnapshot: Equatable, Sendable {
    public let id: String
    public let noteId: String
    public let takenAt: Date
    /// The text is ciphertext under the vault key (the note is locked).
    public let isSealed: Bool
    /// The first non-blank line as a card shows it (`FocusClock.displayLine`). Nil for a sealed
    /// snapshot read without the vault key.
    public let preview: String?

    public init(id: String, noteId: String, takenAt: Date, isSealed: Bool, preview: String?) {
        self.id = id
        self.noteId = noteId
        self.takenAt = takenAt
        self.isSealed = isSealed
        self.preview = preview
    }
}

public enum SnapshotError: Error, Equatable {
    case snapshotNotFound(id: String)
}

/// Which snapshots of a note are kept (FOC-R11): the newest `maxCount` that are at most `maxAge`
/// old, plus the oldest one that is at most `maxAge` old (the floor). Anything older goes.
public enum SnapshotRetention {
    public static let maxCount = 20
    public static let maxAge: TimeInterval = 90 * 86_400

    public static func survivors(_ items: [(id: String, takenAt: Date)], now: Date) -> Set<String> {
        let young = items
            .filter { now.timeIntervalSince($0.takenAt) <= maxAge }
            .sorted { ($0.takenAt, $0.id) > ($1.takenAt, $1.id) }
        var kept = Set(young.prefix(maxCount).map(\.id))
        if let floor = young.last { kept.insert(floor.id) }
        return kept
    }
}

/// Takes a snapshot of a note's text. Returns nil when `text` equals the newest snapshot.
public protocol SnapshotWriting: Sendable {
    func takeSnapshot(noteId: String, text: String, now: Date) throws -> NoteSnapshot?
}

/// The `note_snapshot` rows. Every function runs inside the caller's transaction. Plaintext rows
/// belong to unlocked notes and sealed rows to locked notes; no snapshot text is ever logged.
enum NoteSnapshots {
    struct Stored {
        let id: String
        let noteId: String
        let takenAt: Date
        let text: String?
        let sealed: Data?

        static func from(_ row: Row) -> Stored {
            Stored(id: row["id"], noteId: row["noteId"], takenAt: row["takenAt"], text: row["text"], sealed: row["sealedText"])
        }

        func snapshot(preview: String?) -> NoteSnapshot {
            NoteSnapshot(id: id, noteId: noteId, takenAt: takenAt, isSealed: sealed != nil, preview: preview)
        }
    }

    /// The AAD context of a sealed snapshot (Global Constraints): the ciphertext opens only as this row.
    static func context(_ id: String) -> String { "snapshot:" + id }

    static func preview(_ text: String) -> String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { FocusClock.displayLine(String($0)) }
            .first { !$0.isEmpty }
        return line ?? ""
    }

    static func row(id: String, in db: Database) throws -> Stored? {
        try Row.fetchOne(db, sql: "SELECT * FROM note_snapshot WHERE id = ?", arguments: [id]).map(Stored.from)
    }

    /// Newest first.
    static func rows(noteId: String, in db: Database) throws -> [Stored] {
        try Row.fetchAll(db, sql: "SELECT * FROM note_snapshot WHERE noteId = ? ORDER BY takenAt DESC, id DESC",
                         arguments: [noteId]).map(Stored.from)
    }

    static func seal(_ text: String, id: String, key: SymmetricKey) throws -> Data {
        try NoteCipher.seal(Data(text.utf8), vaultKey: key, context: context(id))
    }

    static func open(_ row: Stored, key: SymmetricKey) throws -> String {
        if let text = row.text { return text }
        guard let sealed = row.sealed else { throw NotePrivacyError.invalidPayload }
        guard let text = String(data: try NoteCipher.open(sealed, vaultKey: key, context: context(row.id)), encoding: .utf8)
        else { throw NotePrivacyError.invalidPayload }
        return text
    }

    /// A plaintext snapshot of an unlocked note, then the retention prune.
    static func takePlain(noteId: String, text: String, now: Date, in db: Database) throws -> NoteSnapshot? {
        let text = TextNormalization.normalizeLineEndings(text)
        if let newest = try rows(noteId: noteId, in: db).first, newest.text == text { return nil }
        let row = try insert(noteId: noteId, now: now, in: db) { _ in (text, nil) }
        return row.snapshot(preview: preview(text))
    }

    /// A sealed snapshot of a locked note, then the retention prune. The dedupe opens the newest one.
    static func takeSealed(noteId: String, text: String, now: Date, key: SymmetricKey, in db: Database) throws -> NoteSnapshot? {
        let text = TextNormalization.normalizeLineEndings(text)
        if let newest = try rows(noteId: noteId, in: db).first, (try? open(newest, key: key)) == text { return nil }
        let row = try insert(noteId: noteId, now: now, in: db) { id in (nil, try seal(text, id: id, key: key)) }
        return row.snapshot(preview: preview(text))
    }

    private static func insert(noteId: String, now: Date, in db: Database,
                               body: (String) throws -> (text: String?, sealed: Data?)) throws -> Stored {
        let id = UUIDv7.make(now: now)
        let (text, sealed) = try body(id)
        try db.execute(sql: "INSERT INTO note_snapshot(id, noteId, takenAt, text, sealedText) VALUES(?,?,?,?,?)",
                       arguments: [id, noteId, NoteStore.roundedToMillis(now), text, sealed])
        let all = try rows(noteId: noteId, in: db)
        let survivors = SnapshotRetention.survivors(all.map { ($0.id, $0.takenAt) }, now: now)
        for stale in all where !survivors.contains(stale.id) {
            try db.execute(sql: "DELETE FROM note_snapshot WHERE id = ?", arguments: [stale.id])
        }
        return Stored(id: id, noteId: noteId, takenAt: NoteStore.roundedToMillis(now), text: text, sealed: sealed)
    }

    /// Replace This Note on an unlocked note: the current text becomes a snapshot first, then the
    /// snapshot's text is written as an ordinary edit.
    static func replacePlain(snapshotId: String, expectedRevision: Int, now: Date, in db: Database) throws -> Note {
        guard let row = try row(id: snapshotId, in: db) else { throw SnapshotError.snapshotNotFound(id: snapshotId) }
        let note = try NoteStore.require(row.noteId, in: db)
        guard !note.isLocked, let text = row.text else { throw StoreError.noteLocked(id: note.id) }
        guard note.revision == expectedRevision else { throw StoreError.revisionConflict(current: note.revision) }
        _ = try takePlain(noteId: note.id, text: note.text, now: now, in: db)
        return try NoteStore.writeText(id: note.id, text: text, expectedRevision: expectedRevision, now: now, in: db)
    }

    /// Local lock (inside its transaction): every plaintext snapshot of the note is sealed in place.
    static func sealAll(noteId: String, key: SymmetricKey, in db: Database) throws {
        for row in try rows(noteId: noteId, in: db) {
            guard let text = row.text else { continue }
            try db.execute(sql: "UPDATE note_snapshot SET text = NULL, sealedText = ? WHERE id = ?",
                           arguments: [try seal(text, id: row.id, key: key), row.id])
        }
    }

    /// Remove Lock (inside its transaction): every sealed snapshot is opened in place. One that does
    /// not open under this key and its own context is deleted, so an unlocked note never keeps a
    /// sealed row and a damaged entry cannot block Remove Lock. Returns how many were dropped; the
    /// caller logs that only after its transaction commits (`logDropped`), since a later failure
    /// rolls the deletion back.
    static func openAll(noteId: String, key: SymmetricKey, in db: Database) throws -> Int {
        var dropped = 0
        for row in try rows(noteId: noteId, in: db) where row.sealed != nil {
            if let text = try? open(row, key: key) {
                try db.execute(sql: "UPDATE note_snapshot SET text = ?, sealedText = NULL WHERE id = ?", arguments: [text, row.id])
            } else {
                try db.execute(sql: "DELETE FROM note_snapshot WHERE id = ?", arguments: [row.id])
                dropped += 1
            }
        }
        return dropped
    }

    /// What `repairInconsistent` removed, per note id.
    struct Repair: Equatable {
        /// Plaintext snapshots of locked notes: they must never exist.
        var plaintextOfLocked: [String: Int] = [:]
        /// Sealed snapshots of unlocked notes: nothing can open them any more.
        var sealedOfUnlocked: [String: Int] = [:]
        var isEmpty: Bool { plaintextOfLocked.isEmpty && sealedOfUnlocked.isEmpty }
    }

    /// Library open (FOC-R305): deletes exactly the rows that break "sealed if and only if locked"
    /// and so make every backup fail (`BackupError.inconsistentHistory`, FOC-R277). Idempotent;
    /// a consistent library is not written. One transaction; the caller logs afterwards.
    static func repairInconsistent(in db: Database) throws -> Repair {
        func counts(_ condition: String) throws -> [String: Int] {
            var result: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT s.noteId, COUNT(*) AS n FROM note_snapshot s JOIN note n ON n.id = s.noteId
                WHERE \(condition) GROUP BY s.noteId
                """) {
                result[row["noteId"]] = row["n"]
            }
            return result
        }
        let plaintext = "n.isLocked = 1 AND s.text IS NOT NULL"
        let sealed = "n.isLocked = 0 AND s.sealedText IS NOT NULL"
        var repair = Repair()
        repair.plaintextOfLocked = try counts(plaintext)
        repair.sealedOfUnlocked = try counts(sealed)
        guard !repair.isEmpty else { return repair }
        for condition in [plaintext, sealed] {
            try db.execute(sql: """
                DELETE FROM note_snapshot WHERE id IN (
                  SELECT s.id FROM note_snapshot s JOIN note n ON n.id = s.noteId WHERE \(condition))
                """)
        }
        return repair
    }

    /// After the repair commit: note ids and counts, never snapshot text.
    static func logRepair(_ repair: Repair) {
        for (noteId, count) in repair.plaintextOfLocked.sorted(by: { $0.key < $1.key }) {
            storeLogger.error("note \(noteId, privacy: .public): \(count) plaintext snapshot(s) of a locked note removed")
        }
        for (noteId, count) in repair.sealedOfUnlocked.sorted(by: { $0.key < $1.key }) {
            storeLogger.error("note \(noteId, privacy: .public): \(count) sealed snapshot(s) of an unlocked note removed")
        }
    }

    /// After the Remove Lock commit: the note id and a count, never snapshot text.
    static func logDropped(_ dropped: Int, noteId: String) {
        guard dropped > 0 else { return }
        storeLogger.error("note \(noteId, privacy: .public): \(dropped) snapshot(s) did not open and were dropped")
    }
}

extension NoteStore: SnapshotWriting {
    /// A plaintext snapshot (FOC-R11). Refuses a locked note: those go through `LockedNoteAccess`.
    /// Writes no note row and posts no change notification.
    public func takeSnapshot(noteId: String, text: String, now: Date) throws -> NoteSnapshot? {
        try db.pool.write { db in
            guard try !Self.require(noteId, in: db).isLocked else { throw StoreError.noteLocked(id: noteId) }
            return try NoteSnapshots.takePlain(noteId: noteId, text: text, now: now, in: db)
        }
    }

    /// Newest first. A sealed snapshot is listed without a preview.
    public func snapshots(noteId: String) throws -> [NoteSnapshot] {
        try db.pool.read { db in
            try NoteSnapshots.rows(noteId: noteId, in: db).map { $0.snapshot(preview: $0.text.map(NoteSnapshots.preview)) }
        }
    }

    /// The text of a plaintext snapshot. A sealed one throws `noteLocked`.
    public func snapshotText(id: String) throws -> String {
        try db.pool.read { db in
            guard let row = try NoteSnapshots.row(id: id, in: db) else { throw SnapshotError.snapshotNotFound(id: id) }
            guard let text = row.text else { throw StoreError.noteLocked(id: row.noteId) }
            return text
        }
    }

    /// A new note in Notes with the snapshot's text and a copy of the source's attachment files,
    /// like Duplicate. The source note and its history are not touched.
    public func restoreSnapshotAsCopy(id: String, now: Date = .now) throws -> Note {
        guard let source = try db.pool.read({ try NoteSnapshots.row(id: id, in: $0) }) else {
            throw SnapshotError.snapshotNotFound(id: id)
        }
        return try copyingAttachments(of: source.noteId, now: now) { newId, db in
            guard let row = try NoteSnapshots.row(id: id, in: db), row.noteId == source.noteId else {
                throw SnapshotError.snapshotNotFound(id: id)
            }
            guard try !Self.require(row.noteId, in: db).isLocked, let text = row.text else {
                throw StoreError.noteLocked(id: row.noteId)
            }
            return try Self.insert(id: newId, text: text, now: now, in: db)
        }
    }

    /// Replace This Note: snapshots the current text, then writes the snapshot's text, in one
    /// transaction. A stale `expectedRevision` throws `revisionConflict` and writes nothing.
    public func replaceNote(withSnapshot id: String, expectedRevision: Int, now: Date = .now) throws -> Note {
        try write { db in
            try NoteSnapshots.replacePlain(snapshotId: id, expectedRevision: expectedRevision, now: now, in: db)
        }
    }
}
