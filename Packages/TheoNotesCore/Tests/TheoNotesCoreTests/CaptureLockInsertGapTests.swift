// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TheoNotesCore

/// An insert-mode voice capture (its guard keeps the note's journal) must never leave plaintext
/// in the journal of a note that a lock committed (FOC-R199 addendum 3).
@Suite struct CaptureLockInsertGapTests {
    private static func token() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    /// What the capture's Stop writes: a base and one journaled insertion.
    private static func journalInsertion(_ text: String, noteId: String, in directory: URL) throws {
        let journal = try EditJournal(directory: directory, noteId: noteId)
        try journal.writeBase(JournalBase(storeRevision: 1, baseText: ""))
        try journal.append(JournalEntry(
            txId: "voice", baseRevision: 0, changeSet: ChangeSet(sections: [.replace(deleteLength: 0, insert: text)])))
    }

    private static func journalHolds(_ marker: String, in directory: URL) throws -> Bool {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).contains { url in
            (try? Data(contentsOf: url))?.range(of: Data(marker.utf8)) != nil
        }
    }

    private static func insertGuard(_ store: NoteStore, paths: AppPaths, noteId: String) throws -> CaptureLockGuard {
        let folder = paths.recordings.appendingPathComponent(noteId)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let recording = folder.appendingPathComponent("Voice Note.m4a")
        try Data("audio".utf8).write(to: recording)
        return try CaptureLockGuard.register(noteId: noteId, store: store, recording: recording, discardsJournal: false) {}
    }

    @Test func aLocalLockStopsTheCaptureBeforeItsJournalCheck() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Plan\n")
        let guardian = try Self.insertGuard(library.store, paths: library.paths, noteId: note.id)
        defer { guardian.end() }
        let canary = "insert" + Self.token()
        let journal = library.paths.journal
        let wrote = Mutex<Bool?>(nil)
        // The capture's Stop comes in right after the lock checked the journal.
        LockTestHooks.afterJournalCheck.withLock {
            $0[note.id] = {
                let ran = try? guardian.ifUnlocked { () throws -> Bool in
                    try Self.journalInsertion(canary, noteId: note.id, in: journal)
                    return true
                }
                wrote.withLock { $0 = ran != nil }
            }
        }
        defer { LockTestHooks.afterJournalCheck.withLock { $0[note.id] = nil } }
        let access = try library.access(); defer { access.revoke() }

        #expect(throws: Never.self) { try access.lock(noteId: note.id) }

        #expect(wrote.withLock { $0 } == false)
        #expect(try library.store.note(id: note.id)?.isLocked == true)
        #expect(try !Self.journalHolds(canary, in: journal))
    }

    @Test func aRemoteLockRollsBackWhileTheCapturesJournalHoldsText() throws {
        let library = try SyncMaterializerTests.Library(enabled: false); defer { library.cleanup() }
        let store = library.store
        let note = try store.create(text: "# Plan\n")
        let guardian = try Self.insertGuard(store, paths: library.paths, noteId: note.id)
        defer { guardian.end() }
        let canary = "insert" + Self.token()
        let journal = library.paths.journal
        let (envelope, _) = try CryptoEnvelope.create(password: "fixture-password", iterations: CryptoEnvelope.publicIterationRange.lowerBound)
        try library.db.pool.write {
            try $0.execute(sql: "INSERT INTO crypto_envelope(id,envelope) VALUES(1,?)", arguments: [try JSONEncoder().encode(envelope)])
        }
        let payload = try SnapshotPrivacyTests.lockedPayload(library, id: note.id, text: "# Plan\nremote")

        // The capture's Stop journals its text after the sync transaction began.
        #expect(throws: (any Error).self) {
            try SnapshotPrivacyTests.write(payload, in: library) { _, stage in
                guard case .begin = stage else { return }
                _ = try guardian.ifUnlocked {
                    try Self.journalInsertion(canary, noteId: note.id, in: journal)
                    guardian.markJournaled()
                }
            }
        }

        // The lock did not commit: the text belongs to an unlocked note and is kept.
        #expect(try store.note(id: note.id)?.isLocked == false)
        #expect(try Self.journalHolds(canary, in: journal))
        #expect(guardian.isLocked)
    }

    // MARK: - A waiting note does not stop the sync pass (FOC-R303)

    @Test func aRemoteLockThatMustWaitForACaptureLeavesTheOtherNotesAndTheUploadsOfTheSamePass() async throws {
        let library = try SyncMaterializerTests.Library(); defer { library.cleanup() }
        let store = library.store
        let (envelope, _) = try CryptoEnvelope.create(password: "fixture-password", iterations: CryptoEnvelope.publicIterationRange.lowerBound)
        try await library.db.pool.write {
            try $0.execute(sql: "INSERT INTO crypto_envelope(id,envelope) VALUES(1,?)", arguments: [try JSONEncoder().encode(envelope)])
        }
        let server = SyncEngineTests.Server()
        let sync = SyncEngine(database: library.db, paths: library.paths, accountID: "account", vaultKey: library.key,
                              transport: server, blobs: SyncPayloadReaderTests.Blobs())
        defer { Task { await sync.shutdown() } }
        // Pass one: the note to be locked later arrives.
        await server.inject(try library.entity(library.payload("# Plan\n", id: "waiting-note"), id: "waiting-note", revision: 1, sequence: 1))
        _ = try await sync.synchronize()
        #expect(try store.note(id: "waiting-note")?.text == "# Plan\n")
        let guardian = try Self.insertGuard(store, paths: library.paths, noteId: "waiting-note")
        defer { guardian.end() }
        let canary = "insert" + Self.token()
        let journal = library.paths.journal
        // The capture journals its text after the commit looked at the journal, before the lock.
        LockTestHooks.afterRemoteJournalCheck.withLock {
            $0["waiting-note"] = {
                _ = try? guardian.ifUnlocked {
                    try Self.journalInsertion(canary, noteId: "waiting-note", in: journal)
                    guardian.markJournaled()
                }
            }
        }
        defer { LockTestHooks.afterRemoteJournalCheck.withLock { $0["waiting-note"] = nil } }
        // Pass two: the lock, another remote note, and a local note that still has to be uploaded.
        // (Pass one also published the lock envelope, so the sequence numbers continue from there.)
        let next = Int64(await server.count()) + 1
        await server.inject(try library.entity(try SnapshotPrivacyTests.lockedPayload(library, id: "waiting-note", text: "# Plan\nremote"),
                                               id: "waiting-note", revision: 2, sequence: next))
        await server.inject(try library.entity(library.payload("# Other\nremote", id: "other-note"), id: "other-note", revision: 1, sequence: next + 1))
        let local = try store.create(text: "# Local\nto upload")
        let published = await server.count()

        let summary = try await sync.synchronize()

        #expect(try store.note(id: "waiting-note")?.isLocked == false)
        #expect(try Self.journalHolds(canary, in: journal))
        #expect(try store.note(id: "other-note")?.text == "# Other\nremote")
        #expect(summary.uploaded > 0)
        #expect(await server.count() > published)
        #expect(await server.holds(noteId: local.id))
        // The lock stays in the inbox for a later pass.
        #expect(try library.inbox.pending().map(\.mutation.entityId) == ["waiting-note"])
    }
}

extension SyncEngineTests.Server {
    func inject(_ entity: SyncEntity) {
        history.append(entity)
        entities[entity.mutation.entityType.rawValue + ":" + entity.mutation.entityId] = entity
    }

    func holds(noteId: String) -> Bool {
        entities["note:" + noteId] != nil
    }
}
