// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// `FocusPurge` (FOC-R10, FOC-R11): what locking a note, here or through sync, does to its
/// reminders, hides, snapshots and notification ledger rows. The call sites are in the locking
/// transaction itself, so a failure later in that transaction leaves all of it unchanged.
@Suite struct FocusPurgeTests {
    static let day = Date(timeIntervalSince1970: 1_800_000_000)
    static func at(_ hour: Int) -> Date { day.addingTimeInterval(Double(hour) * 3600) }

    struct Ping: Equatable {
        var id: String
        var line: Int?
        var hash: String?
        var fireAt: Date
        var firedAt: Date?
    }

    /// Whichever library the test locks in: the shared helpers only need a pool.
    static func seed(_ pings: [Ping], noteId: String, in db: AppDatabase) throws {
        try db.pool.write { db in
            for ping in pings {
                try db.execute(sql: """
                    INSERT INTO note_ping(id, noteId, anchorLine, anchorHash, fireAt, firedAt, createdAt)
                    VALUES(?,?,?,?,?,?,?)
                    """, arguments: [ping.id, noteId, ping.line, ping.hash, ping.fireAt, ping.firedAt, day])
            }
        }
    }

    static func pings(noteId: String, in db: AppDatabase) throws -> [Ping] {
        try db.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM note_ping WHERE noteId = ? ORDER BY fireAt, id", arguments: [noteId]).map {
                Ping(id: $0["id"], line: $0["anchorLine"], hash: $0["anchorHash"], fireAt: $0["fireAt"], firedAt: $0["firedAt"])
            }
        }
    }

    static func hideCount(noteId: String, in db: AppDatabase) throws -> Int {
        try db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM focus_hide WHERE noteId = ?", arguments: [noteId])! }
    }

    static let threeReminders = [
        Ping(id: "whole", line: nil, hash: nil, fireAt: at(10), firedAt: nil),
        Ping(id: "early", line: 2, hash: "aaaaaaaa", fireAt: at(9), firedAt: nil),
        Ping(id: "late", line: 3, hash: "bbbbbbbb", fireAt: at(11), firedAt: nil),
    ]

    static func seedHides(noteId: String, otherNoteId: String, in db: AppDatabase) throws {
        try db.pool.write { db in
            try db.execute(sql: "INSERT INTO focus_hide(candidateKey, noteId, hiddenUntil) VALUES(?,?,?)",
                           arguments: ["todo:\(noteId):2:aaaaaaaa", noteId, at(24)])
            try db.execute(sql: "INSERT INTO focus_hide(candidateKey, noteId, hiddenUntil) VALUES(?,?,?)",
                           arguments: ["note:\(otherNoteId)", otherNoteId, at(24)])
            try db.execute(sql: "INSERT INTO focus_hide(candidateKey, noteId, hiddenUntil) VALUES('pool', NULL, ?)", arguments: [at(24)])
        }
    }

    /// Ledger rows of the locked note, of another note and one without a note (a timer).
    static func seedLedger(noteId: String, otherNoteId: String, in db: AppDatabase) throws {
        try db.pool.write { db in
            try db.execute(sql: """
                INSERT INTO notification_ledger(identifier, kind, pingId, noteId, contentHash, recordedAt) VALUES
                ('reminder:early:u1', 'reminder', 'early', ?, 'hash-1', ?),
                ('reminder:whole:u2', 'reminder', 'whole', ?, 'hash-2', ?),
                ('reminder:other:u3', 'reminder', 'other', ?, 'hash-3', ?),
                ('timer:u4', 'timer', NULL, NULL, 'hash-4', ?)
                """, arguments: [noteId, day, noteId, day, otherNoteId, day, day])
        }
    }

    static func ledger(in db: AppDatabase) throws -> [String: String?] {
        try db.pool.read { db in
            var result: [String: String?] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT identifier, contentHash FROM notification_ledger") {
                result[row["identifier"] as String] = row["contentHash"] as String?
            }
            return result
        }
    }

    // MARK: local lock

    @Test func localLockCollapsesThreeRemindersToTheEarliestTitleOnly() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Plan\n- [ ] first\n- [ ] second")
        let other = try library.store.create(text: "# Other")
        try Self.seed(Self.threeReminders, noteId: note.id, in: library.db)
        try Self.seedHides(noteId: note.id, otherNoteId: other.id, in: library.db)
        let access = try library.access(); defer { access.revoke() }

        try access.lock(noteId: note.id)

        #expect(try library.store.note(id: note.id)?.isLocked == true)
        let kept = try Self.pings(noteId: note.id, in: library.db)
        #expect(kept == [Ping(id: "early", line: nil, hash: nil, fireAt: Self.at(9), firedAt: nil)])
        #expect(try Self.hideCount(noteId: note.id, in: library.db) == 0)
        // Another note's hide, and a hide with no note, are not touched.
        #expect(try Self.hideCount(noteId: other.id, in: library.db) == 1)
        #expect(try library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM focus_hide WHERE candidateKey = 'pool'") } == 1)
    }

    @Test func firedRemindersRankAfterPendingOnes() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Plan\nline")
        try Self.seed([
            Ping(id: "fired", line: 2, hash: "aaaaaaaa", fireAt: Self.at(8), firedAt: Self.at(8)),
            Ping(id: "pending", line: nil, hash: nil, fireAt: Self.at(12), firedAt: nil),
        ], noteId: note.id, in: library.db)
        let access = try library.access(); defer { access.revoke() }

        try access.lock(noteId: note.id)

        #expect(try Self.pings(noteId: note.id, in: library.db)
            == [Ping(id: "pending", line: nil, hash: nil, fireAt: Self.at(12), firedAt: nil)])
    }

    @Test func aNoteWithoutRemindersLocksAsBefore() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Plain")
        let access = try library.access(); defer { access.revoke() }
        try access.lock(noteId: note.id)
        #expect(try library.store.note(id: note.id)?.isLocked == true)
        #expect(try Self.pings(noteId: note.id, in: library.db).isEmpty)
    }

    @Test func collapseIsAtomicWithTheLock() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Plan\n- [ ] first")
        let other = try library.store.create(text: "# Other")
        try Self.seed(Self.threeReminders, noteId: note.id, in: library.db)
        try Self.seedHides(noteId: note.id, otherNoteId: other.id, in: library.db)
        try Self.seedLedger(noteId: note.id, otherNoteId: other.id, in: library.db)
        struct Injected: Error {}
        let (envelope, key) = try CryptoEnvelope.create(password: "fixture-password", iterations: 1)
        try library.db.pool.write {
            try $0.execute(sql: "INSERT INTO crypto_envelope(id,envelope) VALUES(1,?)", arguments: [try JSONEncoder().encode(envelope)])
        }
        let noteId = note.id
        // Inside the locking transaction, just before it would commit, the purge has already run.
        // Without this check the rollback assertions below would also pass if the purge never ran.
        let guarded = library.store.guarded { db, stage in
            guard stage == .beforeCommit else { return }
            let pings = try Row.fetchAll(db, sql: "SELECT id, anchorLine, anchorHash FROM note_ping WHERE noteId = ?", arguments: [noteId])
            #expect(pings.count == 1)
            #expect(pings.first?["id"] as String? == "early")
            #expect(pings.first?["anchorLine"] as Int? == nil)
            #expect(pings.first?["anchorHash"] as String? == nil)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM focus_hide WHERE noteId = ?", arguments: [noteId]) == 0)
            #expect(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM notification_ledger WHERE noteId = ? AND contentHash IS NOT NULL
                """, arguments: [noteId]) == 0)
            throw Injected()
        }
        let access = LockedNoteAccess(store: guarded, key: key); defer { access.revoke() }
        let ledgerBefore = try Self.ledger(in: library.db)

        #expect(throws: Injected.self) { try access.lock(noteId: note.id) }

        #expect(try library.store.note(id: note.id)?.isLocked == false)
        #expect(try Self.pings(noteId: note.id, in: library.db).sorted { $0.id < $1.id }
            == Self.threeReminders.sorted { $0.id < $1.id })
        #expect(try Self.hideCount(noteId: note.id, in: library.db) == 1)
        #expect(try Self.ledger(in: library.db) == ledgerBefore)
    }

    @Test func lockNullsLedgerContentHashesButKeepsIdentifiersLocally() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Plan\n- [ ] first")
        let other = try library.store.create(text: "# Other")
        try Self.seed(Self.threeReminders, noteId: note.id, in: library.db)
        try Self.seedLedger(noteId: note.id, otherNoteId: other.id, in: library.db)
        let access = try library.access(); defer { access.revoke() }

        try access.lock(noteId: note.id)

        let ledger = try Self.ledger(in: library.db)
        #expect(Set(ledger.keys) == ["reminder:early:u1", "reminder:whole:u2", "reminder:other:u3", "timer:u4"])
        #expect(ledger["reminder:early:u1"] == .some(nil))
        #expect(ledger["reminder:whole:u2"] == .some(nil))
        #expect(ledger["reminder:other:u3"] == .some("hash-3"))
        #expect(ledger["timer:u4"] == .some("hash-4"))
    }

    // MARK: remote lock and unlock

    /// A locked sync payload for the note, built the way `SyncLockedNoteMergeTests` does.
    private static func lockedPayload(_ library: SyncMaterializerTests.Library, id: String) throws -> SyncNotePayload {
        var incoming = library.payload("# Remote secret", id: id)
        incoming.isLocked = true
        incoming.text = ""
        incoming.encryptedPayload = try NoteCipher.seal(
            JSONEncoder().encode(LockedNotePayload(text: "# Remote secret", attachments: [:])),
            vaultKey: library.key, context: id)
        return incoming
    }

    private static func write(_ payload: SyncNotePayload, in library: SyncMaterializerTests.Library) throws {
        let files = AttachmentFiles(paths: library.paths, database: library.db)
        var staged: [AttachmentFiles.Staged] = []
        try library.db.pool.write { db in
            try library.materializer().writeNote(payload, downloads: [], copying: false, files: files, staged: &staged, in: db)
        }
        // As `commitNote` does after the commit.
        for batch in staged { files.install(batch) }
    }

    @Test func remoteLockCollapsesThreeRemindersToTheEarliestTitleOnly() throws {
        let library = try SyncMaterializerTests.Library(enabled: false); defer { library.cleanup() }
        let note = try library.store.create(text: "# Plan\n- [ ] first\n- [ ] second")
        let other = try library.store.create(text: "# Other")
        try Self.seed(Self.threeReminders, noteId: note.id, in: library.db)
        try Self.seedHides(noteId: note.id, otherNoteId: other.id, in: library.db)

        try Self.write(try Self.lockedPayload(library, id: note.id), in: library)

        #expect(try library.store.note(id: note.id)?.isLocked == true)
        #expect(try Self.pings(noteId: note.id, in: library.db)
            == [Ping(id: "early", line: nil, hash: nil, fireAt: Self.at(9), firedAt: nil)])
        #expect(try Self.hideCount(noteId: note.id, in: library.db) == 0)
        #expect(try Self.hideCount(noteId: other.id, in: library.db) == 1)
    }

    @Test func lockNullsLedgerContentHashesButKeepsIdentifiersRemotely() throws {
        let library = try SyncMaterializerTests.Library(enabled: false); defer { library.cleanup() }
        let note = try library.store.create(text: "# Plan\n- [ ] first")
        let other = try library.store.create(text: "# Other")
        try Self.seed(Self.threeReminders, noteId: note.id, in: library.db)
        try Self.seedLedger(noteId: note.id, otherNoteId: other.id, in: library.db)

        try Self.write(try Self.lockedPayload(library, id: note.id), in: library)

        let ledger = try Self.ledger(in: library.db)
        #expect(Set(ledger.keys) == ["reminder:early:u1", "reminder:whole:u2", "reminder:other:u3", "timer:u4"])
        #expect(ledger["reminder:early:u1"] == .some(nil))
        #expect(ledger["reminder:whole:u2"] == .some(nil))
        #expect(ledger["reminder:other:u3"] == .some("hash-3"))
    }

    @Test func remoteUnlockDeletesSealedSnapshotsOnly() throws {
        let library = try SyncMaterializerTests.Library(enabled: false); defer { library.cleanup() }
        let note = try library.store.create(text: "# Plan")
        try Self.write(try Self.lockedPayload(library, id: note.id), in: library)
        // The materializer finishes the privacy transition after its commit; so does the test.
        try NotePrivacy(store: library.store).finishPendingCleanup()
        try library.db.pool.write { db in
            try db.execute(sql: "INSERT INTO note_snapshot(id, noteId, takenAt, sealedText) VALUES('sealed', ?, ?, ?)",
                           arguments: [note.id, Self.day, Data([1, 2, 3])])
            try db.execute(sql: "INSERT INTO note_snapshot(id, noteId, takenAt, text) VALUES('plain', ?, ?, 'x')",
                           arguments: [note.id, Self.day])
        }

        var unlocked = library.payload("# Plan", id: note.id)
        unlocked.isLocked = false
        try Self.write(unlocked, in: library)

        #expect(try library.store.note(id: note.id)?.isLocked == false)
        let remaining = try library.db.pool.read { try String.fetchAll($0, sql: "SELECT id FROM note_snapshot WHERE noteId = ?", arguments: [note.id]) }
        #expect(remaining == ["plain"])
    }

    @Test func aRemoteUpdateOfAnUnlockedNoteKeepsItsSnapshots() throws {
        let library = try SyncMaterializerTests.Library(enabled: false); defer { library.cleanup() }
        let note = try library.store.create(text: "# Plan")
        try library.db.pool.write {
            try $0.execute(sql: "INSERT INTO note_snapshot(id, noteId, takenAt, text) VALUES('plain', ?, ?, 'x')", arguments: [note.id, Self.day])
        }
        try Self.write(library.payload("# Plan v2", id: note.id), in: library)
        #expect(try library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note_snapshot WHERE noteId = ?", arguments: [note.id]) } == 1)
    }
}
