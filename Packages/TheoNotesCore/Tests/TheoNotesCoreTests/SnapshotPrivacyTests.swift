// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import OSLog
import Testing
@testable import TheoNotesCore

/// Snapshots of locked notes: sealed with the vault key under the context
/// `snapshot:<id>`, sealed by a local lock, opened by Remove Lock, deleted by a remote lock
/// (plaintext) or a remote unlock (sealed), and never readable after the access is revoked.
@Suite struct SnapshotPrivacyTests {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    struct Stored: Equatable {
        var id: String
        var text: String?
        var sealed: Data?
    }

    static func stored(_ noteId: String, in db: AppDatabase) throws -> [Stored] {
        try db.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, text, sealedText FROM note_snapshot WHERE noteId = ? ORDER BY takenAt, id", arguments: [noteId])
                .map { Stored(id: $0["id"], text: $0["text"], sealed: $0["sealedText"]) }
        }
    }

    static func sealedOnUnlockedNotes(in db: AppDatabase) throws -> Int {
        try db.pool.read {
            try Int.fetchOne($0, sql: """
                SELECT COUNT(*) FROM note_snapshot s JOIN note n ON n.id=s.noteId WHERE n.isLocked=0 AND s.sealedText IS NOT NULL
                """)!
        }
    }

    static func markers(_ count: Int) -> [String: String] {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return Dictionary(uniqueKeysWithValues: (0..<count).map { ("body\($0)", "snapbody\($0)" + token) })
    }

    /// Three plaintext snapshots of an unlocked note, one marker each; returns their texts, oldest first.
    static func seedSnapshots(_ store: NoteStore, noteId: String, markers: [String: String]) throws -> [String] {
        let texts = markers.keys.sorted().map { "# Permitted title\n\(markers[$0]!)" }
        for (index, text) in texts.enumerated() {
            _ = try #require(try store.takeSnapshot(noteId: noteId, text: text, now: start + Double(index) * 60))
        }
        return texts
    }

    // MARK: local lock and Remove Lock

    @Test func lockSealsEverySnapshot() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Permitted title\ncurrent")
        let markers = Self.markers(3)
        let texts = try Self.seedSnapshots(library.store, noteId: note.id, markers: markers)
        let scanner = PrivacyCanaryScanner(markers: markers)
        #expect(try library.db.pool.read { try scanner.tables($0) } == Set(markers.keys))
        let access = try library.access(); defer { access.revoke() }

        try access.lock(noteId: note.id)

        let rows = try Self.stored(note.id, in: library.db)
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.text == nil && $0.sealed != nil })
        #expect(try library.db.pool.read { try scanner.tables($0) }.isEmpty)
        #expect(try scanner.files(in: library.paths.root).isEmpty)
        #expect(try rows.map { try access.snapshotText(id: $0.id) } == texts)
        // The plain store sees that they exist, never what they say.
        let listed = try library.store.snapshots(noteId: note.id)
        #expect(listed.count == 3 && listed.allSatisfy { $0.isSealed && $0.preview == nil })
        #expect(throws: StoreError.noteLocked(id: note.id)) { try library.store.snapshotText(id: rows[0].id) }
        #expect(try access.snapshots(noteId: note.id).map(\.preview) == ["Permitted title", "Permitted title", "Permitted title"])
    }

    @Test func removeLockOpensThem() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Permitted title\ncurrent")
        let texts = try Self.seedSnapshots(library.store, noteId: note.id, markers: Self.markers(3))
        let access = try library.access(); defer { access.revoke() }
        try access.lock(noteId: note.id)
        let sealedIds = try Self.stored(note.id, in: library.db).map(\.id)

        try access.removeLock(noteId: note.id)

        let rows = try Self.stored(note.id, in: library.db)
        #expect(rows.map(\.id) == sealedIds)
        #expect(rows == zip(sealedIds, texts).map { Stored(id: $0, text: $1, sealed: nil) })
        #expect(try rows.map { try library.store.snapshotText(id: $0.id) } == texts)
    }

    @Test func lockedNoteSnapshotsAreTakenSealed() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Permitted title\ncurrent")
        let access = try library.access(); defer { access.revoke() }
        try access.lock(noteId: note.id)
        let markers = Self.markers(1)
        let text = "# Permitted title\n\(markers["body0"]!)"

        #expect(throws: StoreError.noteLocked(id: note.id)) {
            try library.store.takeSnapshot(noteId: note.id, text: text, now: Self.start)
        }
        let taken = try #require(try access.takeSnapshot(noteId: note.id, text: text, now: Self.start))
        #expect(taken.isSealed)
        // The same text again is skipped: the dedupe opens the newest sealed snapshot.
        #expect(try access.takeSnapshot(noteId: note.id, text: text, now: Self.start + 60) == nil)

        let rows = try Self.stored(note.id, in: library.db)
        #expect(rows.count == 1 && rows[0].text == nil && rows[0].sealed != nil)
        #expect(try library.db.pool.read { try PrivacyCanaryScanner(markers: markers).tables($0) }.isEmpty)
        #expect(try access.snapshotText(id: taken.id) == text)
    }

    @Test func wrongContextDoesNotOpen() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Permitted title\ncurrent")
        _ = try Self.seedSnapshots(library.store, noteId: note.id, markers: Self.markers(2))
        let access = try library.access(); defer { access.revoke() }
        try access.lock(noteId: note.id)
        let rows = try Self.stored(note.id, in: library.db)
        try #require(rows.count == 2)
        let a = rows[0], b = rows[1]
        // Each ciphertext is bound to its own row id: moved to the other row it no longer opens.
        try library.db.pool.write { db in
            try db.execute(sql: "UPDATE note_snapshot SET sealedText = ? WHERE id = ?", arguments: [b.sealed, a.id])
            try db.execute(sql: "UPDATE note_snapshot SET sealedText = ? WHERE id = ?", arguments: [a.sealed, b.id])
        }

        #expect(throws: (any Error).self) { try access.snapshotText(id: a.id) }
        #expect(throws: (any Error).self) { try access.snapshotText(id: b.id) }
        // Remove Lock still unlocks the note; a snapshot that does not open is dropped, never kept sealed.
        try access.removeLock(noteId: note.id)
        #expect(try library.store.note(id: note.id)?.isLocked == false)
        #expect(try Self.stored(note.id, in: library.db).isEmpty)
        #expect(try Self.sealedOnUnlockedNotes(in: library.db) == 0)
    }

    /// This process's app-subsystem log messages since `start`, once `ready` holds for them.
    static func logMessages(since start: Date, until ready: ([String]) -> Bool) async throws -> [String] {
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(500))
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let entries = try store.getEntries(at: store.position(date: start), matching:
                NSPredicate(format: "subsystem == %@", "com.truebrewbirdie.baerchen"))
            let messages = entries.compactMap { ($0 as? OSLogEntryLog)?.composedMessage }
            if ready(messages) { return messages }
        }
        throw PrivacyCanaryScanner.LogCollectorError.requiredRecordsNotObserved
    }

    @Test func droppedSnapshotsAreLoggedOnlyAfterCommit() async throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let started = Date.now.addingTimeInterval(-1)
        let note = try library.store.create(text: "# Permitted title\ncurrent")
        _ = try Self.seedSnapshots(library.store, noteId: note.id, markers: Self.markers(2))
        let key = SymmetricKey(size: .bits256)
        let access = LockedNoteAccess(store: library.store, key: key); defer { access.revoke() }
        try access.lock(noteId: note.id)
        let rows = try Self.stored(note.id, in: library.db)
        try #require(rows.count == 2)
        // Both ciphertexts moved to the other row: neither opens, so Remove Lock drops both.
        try await library.db.pool.write { db in
            try db.execute(sql: "UPDATE note_snapshot SET sealedText = ? WHERE id = ?", arguments: [rows[1].sealed, rows[0].id])
            try db.execute(sql: "UPDATE note_snapshot SET sealedText = ? WHERE id = ?", arguments: [rows[0].sealed, rows[1].id])
        }
        let swapped = try Self.stored(note.id, in: library.db)
        let noteId = note.id
        struct Injected: Error {}
        let failing = LockedNoteAccess(store: library.store.guarded { db, stage in
            guard stage == .beforeCommit else { return }
            // The drop has run in this transaction; the failure below rolls it back.
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note_snapshot WHERE noteId = ?", arguments: [noteId]) == 0)
            throw Injected()
        }, key: key)
        defer { failing.revoke() }
        let dropLine = { (message: String) in message.contains(noteId) && message.contains("did not open") }

        #expect(throws: Injected.self) { try failing.removeLock(noteId: noteId) }

        #expect(try library.store.note(id: noteId)?.isLocked == true)
        #expect(try Self.stored(noteId, in: library.db) == swapped)
        let sentinel = "c5-rollback-probe-" + UUID().uuidString
        Logger(subsystem: "com.truebrewbirdie.baerchen", category: "privacy-test-probe").notice("probe \(sentinel, privacy: .public)")
        let afterRollback = try await Self.logMessages(since: started) { $0.contains { $0.contains(sentinel) } }
        #expect(!afterRollback.contains(where: dropLine))

        // Positive control: the committed Remove Lock does log the count.
        try access.removeLock(noteId: noteId)
        let afterCommit = try await Self.logMessages(since: started) { $0.contains(where: dropLine) }
        #expect(afterCommit.contains { $0.contains("\(noteId): 2 snapshot(s) did not open") })
        #expect(try Self.stored(noteId, in: library.db).isEmpty)
    }

    @Test func revokedAccessRefusesSnapshotCalls() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Permitted title\ncurrent")
        _ = try Self.seedSnapshots(library.store, noteId: note.id, markers: Self.markers(1))
        let access = try library.access()
        try access.lock(noteId: note.id)
        let snapshotId = try #require(try Self.stored(note.id, in: library.db).first?.id)
        let revision = try #require(try library.store.note(id: note.id)?.revision)
        let before = try Self.stored(note.id, in: library.db)
        let notesBefore = try library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note")! }

        access.revoke()

        #expect(throws: NotePrivacyError.accessRevoked) { try access.takeSnapshot(noteId: note.id, text: "# Other", now: Self.start) }
        #expect(throws: NotePrivacyError.accessRevoked) { try access.snapshots(noteId: note.id) }
        #expect(throws: NotePrivacyError.accessRevoked) { try access.snapshotText(id: snapshotId) }
        #expect(throws: NotePrivacyError.accessRevoked) { try access.restoreSnapshotAsCopy(id: snapshotId, now: Self.start) }
        #expect(throws: NotePrivacyError.accessRevoked) {
            try access.replaceNote(withSnapshot: snapshotId, expectedRevision: revision, now: Self.start)
        }
        #expect(throws: NotePrivacyError.accessRevoked) { try access.withVaultKey { _ in 1 } }
        #expect(try Self.stored(note.id, in: library.db) == before)
        #expect(try library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note")! } == notesBefore)
        #expect(try library.store.note(id: note.id)?.revision == revision)
    }

    @Test func lockedRestoreAndReplaceStayLocked() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        var note = try library.store.create(text: "# Permitted title\nold")
        let old = try #require(try library.store.takeSnapshot(noteId: note.id, text: note.text, now: Self.start))
        note = try library.store.updateText(id: note.id, text: "# Permitted title\nnew", expectedRevision: note.revision)
        let access = try library.access(); defer { access.revoke() }
        try access.lock(noteId: note.id)
        let locked = try #require(try access.note(id: note.id))

        let copy = try access.restoreSnapshotAsCopy(id: old.id, now: Self.start + 60)
        #expect(copy.isLocked)
        #expect(try access.note(id: copy.id)?.text == "# Permitted title\nold")
        #expect(try access.note(id: note.id) == locked)

        #expect(throws: StoreError.revisionConflict(current: locked.revision)) {
            try access.replaceNote(withSnapshot: old.id, expectedRevision: locked.revision - 1, now: Self.start + 120)
        }
        let replaced = try access.replaceNote(withSnapshot: old.id, expectedRevision: locked.revision, now: Self.start + 120)
        #expect(replaced.isLocked && replaced.text == "# Permitted title\nold")
        #expect(try access.note(id: note.id)?.text == "# Permitted title\nold")
        let rows = try Self.stored(note.id, in: library.db)
        try #require(rows.count == 2)
        #expect(rows.allSatisfy { $0.text == nil && $0.sealed != nil })
        #expect(try access.snapshotText(id: rows[1].id) == "# Permitted title\nnew")
    }

    @Test func permanentDeleteOfALockedNoteRemovesItsSealedSnapshots() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Permitted title\ncurrent")
        let other = try library.store.create(text: "# Other")
        _ = try Self.seedSnapshots(library.store, noteId: note.id, markers: Self.markers(2))
        _ = try library.store.takeSnapshot(noteId: other.id, text: "# Other\nkept", now: Self.start)
        let access = try library.access(); defer { access.revoke() }
        try access.lock(noteId: note.id)
        #expect(try Self.stored(note.id, in: library.db).count == 2)

        try library.store.deletePermanently([note.id])

        #expect(try Self.stored(note.id, in: library.db).isEmpty)
        #expect(try Self.stored(other.id, in: library.db).count == 1)
    }

    @Test func passwordResetRefusesWhileLockedNotesRemainAndLeavesSnapshotsUntouched() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Permitted title\ncurrent")
        _ = try Self.seedSnapshots(library.store, noteId: note.id, markers: Self.markers(2))
        let access = try library.access(); defer { access.revoke() }
        try access.lock(noteId: note.id)
        let before = try Self.stored(note.id, in: library.db)

        #expect(throws: NotePasswordResetError.lockedNotesRemain) { try NotePrivacy(store: library.store).deletePassword() }

        #expect(try Self.stored(note.id, in: library.db) == before)
        #expect(try before.map { try access.snapshotText(id: $0.id) }.count == 2)
    }

    // MARK: remote lock and unlock

    static func lockedPayload(_ library: SyncMaterializerTests.Library, id: String, text: String) throws -> SyncNotePayload {
        var incoming = library.payload(text, id: id)
        incoming.isLocked = true
        incoming.text = ""
        incoming.encryptedPayload = try NoteCipher.seal(
            JSONEncoder().encode(LockedNotePayload(text: text, attachments: [:])), vaultKey: library.key, context: id)
        return incoming
    }

    /// `writeNote` inside one write transaction, as `commitNote` runs it, with `guard` called the
    /// way a `NoteStore.WriteGuard` is: at `.begin` and at `.beforeCommit`.
    static func write(_ payload: SyncNotePayload, in library: SyncMaterializerTests.Library,
                      guard writeGuard: NoteStore.WriteGuard? = nil) throws {
        let files = AttachmentFiles(paths: library.paths, database: library.db)
        var staged: [AttachmentFiles.Staged] = []
        do {
            try library.db.pool.write { db in
                try writeGuard?(db, .begin)
                try library.materializer().writeNote(payload, downloads: [], copying: false, files: files, staged: &staged, in: db)
                try writeGuard?(db, .beforeCommit)
            }
        } catch {
            for batch in staged { files.discard(batch) }
            throw error
        }
        for batch in staged { files.install(batch) }
        try NotePrivacy(store: library.store).finishPendingCleanup()
    }

    @Test func remoteLockDeletesPlaintextSnapshots() throws {
        let library = try SyncMaterializerTests.Library(enabled: false); defer { library.cleanup() }
        let note = try library.store.create(text: "# Permitted title\ncurrent")
        let other = try library.store.create(text: "# Other")
        let markers = Self.markers(3)
        _ = try Self.seedSnapshots(library.store, noteId: note.id, markers: markers)
        _ = try library.store.takeSnapshot(noteId: other.id, text: "# Other\nkept", now: Self.start)
        // A library with locked notes has a password envelope; the lock cleanup's replacement
        // backup is refused without one (`LibraryBackup.validateExtracted`).
        let (envelope, _) = try CryptoEnvelope.create(password: "fixture-password", iterations: CryptoEnvelope.publicIterationRange.lowerBound)
        try library.db.pool.write {
            try $0.execute(sql: "INSERT INTO crypto_envelope(id,envelope) VALUES(1,?)", arguments: [try JSONEncoder().encode(envelope)])
        }
        // A daily SQLite copy holds the plaintext snapshots too; the lock cleanup must prune it.
        let backup = try #require(try LibraryBackup(database: library.db, paths: library.paths).createDailyDatabaseSnapshot())
        let scanner = PrivacyCanaryScanner(markers: markers)
        // Positive control: the scan sees the plaintext before the lock (database, WAL, backup).
        #expect(try scanner.files(in: library.paths.root) == Set(markers.keys))

        try Self.write(try Self.lockedPayload(library, id: note.id, text: "# Permitted title\nremote"), in: library)
        try NotePrivacy(store: library.store).checkpoint()

        #expect(try library.store.note(id: note.id)?.isLocked == true)
        #expect(try Self.stored(note.id, in: library.db).isEmpty)
        #expect(try Self.stored(other.id, in: library.db).count == 1)
        #expect(try library.db.pool.read { try scanner.tables($0) }.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: backup.path))
        // Every file under the library root: database, -wal, -shm and backups.
        #expect(try scanner.files(in: library.paths.root).isEmpty)
    }

    @Test func remoteLockKeepsTheSealedSnapshotsOfAnAlreadyLockedNote() throws {
        let library = try SyncMaterializerTests.Library(enabled: false); defer { library.cleanup() }
        let note = try library.store.create(text: "# Permitted title\ncurrent")
        _ = try Self.seedSnapshots(library.store, noteId: note.id, markers: Self.markers(2))
        let access = LockedNoteAccess(store: library.store, key: library.key); defer { access.revoke() }
        try access.lock(noteId: note.id)
        let before = try Self.stored(note.id, in: library.db)

        try Self.write(try Self.lockedPayload(library, id: note.id, text: "# Permitted title\nremote edit"), in: library)

        #expect(try Self.stored(note.id, in: library.db) == before)
    }

    @Test func remoteUnlockDeletesSealedSnapshotsAtomically() throws {
        let library = try SyncMaterializerTests.Library(enabled: false); defer { library.cleanup() }
        let note = try library.store.create(text: "# Permitted title\ncurrent")
        _ = try Self.seedSnapshots(library.store, noteId: note.id, markers: Self.markers(2))
        let access = LockedNoteAccess(store: library.store, key: library.key); defer { access.revoke() }
        try access.lock(noteId: note.id)
        let sealedCount = { @Sendable (db: Database) throws -> Int in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note_snapshot WHERE noteId=? AND sealedText IS NOT NULL", arguments: [note.id])!
        }
        #expect(try library.db.pool.read(sealedCount) == 2)
        var unlocked = library.payload("# Permitted title\nremote", id: note.id)
        unlocked.isLocked = false

        // A failure at the end of the transaction rolls the deletion back with the unlock. The guard
        // checks first that the deletion had run, so the rollback assertions below bite.
        struct Injected: Error {}
        #expect(throws: Injected.self) {
            try Self.write(unlocked, in: library) { db, stage in
                guard stage == .beforeCommit else { return }
                #expect(try sealedCount(db) == 0)
                throw Injected()
            }
        }
        #expect(try library.store.note(id: note.id)?.isLocked == true)
        #expect(try library.db.pool.read(sealedCount) == 2)

        try Self.write(unlocked, in: library)

        #expect(try library.store.note(id: note.id)?.isLocked == false)
        #expect(try library.db.pool.read(sealedCount) == 0)
    }

    @Test func noUnlockedNoteEverHasSealedSnapshots() throws {
        let library = try SyncMaterializerTests.Library(enabled: false); defer { library.cleanup() }
        let note = try library.store.create(text: "# Permitted title\ncurrent")
        _ = try Self.seedSnapshots(library.store, noteId: note.id, markers: Self.markers(2))
        let access = LockedNoteAccess(store: library.store, key: library.key); defer { access.revoke() }

        try access.lock(noteId: note.id)
        #expect(try Self.sealedOnUnlockedNotes(in: library.db) == 0)
        #expect(try Self.stored(note.id, in: library.db).count == 2)

        try access.removeLock(noteId: note.id)
        #expect(try Self.sealedOnUnlockedNotes(in: library.db) == 0)
        #expect(try Self.stored(note.id, in: library.db).count == 2)

        try Self.write(try Self.lockedPayload(library, id: note.id, text: "# Permitted title\nremote"), in: library)
        #expect(try Self.sealedOnUnlockedNotes(in: library.db) == 0)
        _ = try #require(try access.takeSnapshot(noteId: note.id, text: "# Permitted title\nwhile locked", now: Self.start + 600))
        #expect(try Self.stored(note.id, in: library.db).count == 1)

        var unlocked = library.payload("# Permitted title\nremote", id: note.id)
        unlocked.isLocked = false
        try Self.write(unlocked, in: library)
        #expect(try library.store.note(id: note.id)?.isLocked == false)
        #expect(try Self.sealedOnUnlockedNotes(in: library.db) == 0)
    }

    // MARK: repair at library open

    /// A locked note with two sealed snapshots and an unlocked one with two plaintext snapshots.
    private static func consistentPair(_ library: PrivacyTestLibrary) throws -> (locked: Note, open: Note) {
        let locked = try library.store.create(text: "# Locked\ncurrent")
        let open = try library.store.create(text: "# Open\ncurrent")
        _ = try seedSnapshots(library.store, noteId: locked.id, markers: markers(2))
        _ = try seedSnapshots(library.store, noteId: open.id, markers: markers(2))
        // A real envelope: a backup validates it.
        let access = try library.access(iterations: CryptoEnvelope.publicIterationRange.lowerBound); defer { access.revoke() }
        try access.lock(noteId: locked.id)
        return (locked, open)
    }

    @Test func openingTheLibraryRemovesExactlyTheRowsThatBreakTheBackup() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let (locked, open) = try Self.consistentPair(library)
        let lockedBefore = try Self.stored(locked.id, in: library.db)
        let openBefore = try Self.stored(open.id, in: library.db)
        try library.db.pool.write { db in
            try db.execute(sql: "INSERT INTO note_snapshot(id, noteId, takenAt, text, sealedText) VALUES('plain-of-locked', ?, ?, 'secret text', NULL)",
                           arguments: [locked.id, Self.start])
            try db.execute(sql: "INSERT INTO note_snapshot(id, noteId, takenAt, text, sealedText) VALUES('sealed-of-open', ?, ?, NULL, ?)",
                           arguments: [open.id, Self.start, Data([1, 2, 3])])
        }
        // Positive control: the backup refuses while they exist.
        #expect(throws: BackupError.inconsistentHistory) {
            try LibraryBackup(database: library.db, paths: library.paths).createRolling()
        }
        try library.db.pool.close()

        let reopened = try AppDatabase(path: library.paths.database); defer { try? reopened.pool.close() }

        #expect(try Self.stored(locked.id, in: reopened) == lockedBefore)
        #expect(try Self.stored(open.id, in: reopened) == openBefore)
        let archive = try LibraryBackup(database: reopened, paths: library.paths).createRolling()
        #expect(FileManager.default.fileExists(atPath: archive.path))
        // A second open finds nothing to do.
        try reopened.pool.close()
        let again = try AppDatabase(path: library.paths.database); defer { try? again.pool.close() }
        #expect(try Self.stored(locked.id, in: again) == lockedBefore)
        #expect(try Self.stored(open.id, in: again) == openBefore)
    }

    @Test func openingAConsistentLibraryChangesNoSnapshotRow() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let (locked, open) = try Self.consistentPair(library)
        let all = { @Sendable (db: Database) throws -> [Row] in
            try Row.fetchAll(db, sql: "SELECT * FROM note_snapshot ORDER BY id")
        }
        let before = try library.db.pool.read(all)
        try library.db.pool.close()

        let reopened = try AppDatabase(path: library.paths.database); defer { try? reopened.pool.close() }

        #expect(try reopened.pool.read(all) == before)
        #expect(try Self.stored(locked.id, in: reopened).count == 2)
        #expect(try Self.stored(open.id, in: reopened).count == 2)
    }

    @Test func theRepairReportsCountsAndNoteIdsNeverText() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let (locked, open) = try Self.consistentPair(library)
        try library.db.pool.write { db in
            try db.execute(sql: "INSERT INTO note_snapshot(id, noteId, takenAt, text, sealedText) VALUES('p1', ?, ?, 'secret text', NULL)", arguments: [locked.id, Self.start])
            try db.execute(sql: "INSERT INTO note_snapshot(id, noteId, takenAt, text, sealedText) VALUES('p2', ?, ?, 'more secret', NULL)", arguments: [locked.id, Self.start])
            try db.execute(sql: "INSERT INTO note_snapshot(id, noteId, takenAt, text, sealedText) VALUES('s1', ?, ?, NULL, ?)", arguments: [open.id, Self.start, Data([9])])
        }

        let repair = try library.db.pool.write { try NoteSnapshots.repairInconsistent(in: $0) }

        #expect(repair.plaintextOfLocked == [locked.id: 2])
        #expect(repair.sealedOfUnlocked == [open.id: 1])
        #expect(try library.db.pool.write { try NoteSnapshots.repairInconsistent(in: $0) }.isEmpty)
    }
}
