// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct SyncVaultIntakeTests {
    @Test func mixedLockedNotesKeepForeignBytesAndCountThem() async throws {
        let library = try SyncMaterializerTests.Library(enabled: false); defer { library.cleanup() }
        let (envelope, key) = try CryptoEnvelope.create(password: "password")
        for (id, noteKey) in [("matching", key), ("foreign", SymmetricKey(size: .bits256))] {
            let sealed = try NoteCipher.seal(Data("sealed".utf8), vaultKey: noteKey, context: id)
            try await library.db.pool.write { db in
                try Note(id: id, text: "", title: "", titleKey: "", createdAt: .now, modifiedAt: .now,
                         isLocked: true, encryptedPayload: sealed).insert(db)
            }
        }
        let entity = try library.entity(SyncLockEnvelopePayload(envelope: JSONEncoder().encode(envelope)), type: .keyBundle, id: "lock-vault")
        let engine = SyncEngine(database: library.db, paths: library.paths, accountID: "account", vaultKey: library.key,
                                transport: Transport([entity]), blobs: SyncPayloadReaderTests.Blobs())
        let candidate = try #require(try await engine.scanPendingNoteVault(password: "password"))
        let before = try #require(try library.store.note(id: "foreign")?.encryptedPayload)
        #expect(try await engine.installPendingNoteVault(candidate))
        #expect(try await engine.unopenableLockedNoteCount(for: candidate) == 1)
        #expect(try library.store.note(id: "foreign")?.encryptedPayload == before)
    }
    @Test(arguments: ["match", "mismatch", "empty"]) func existingLockedRowsRequireMatchingKeyWhenSealed(kind: String) async throws {
        let library = try SyncMaterializerTests.Library(enabled: false); defer { library.cleanup() }
        let (envelope, key) = try CryptoEnvelope.create(password: "password")
        let selected = kind == "mismatch" ? SymmetricKey(size: .bits256) : key
        let body = kind == "empty" ? nil : try NoteCipher.seal(Data("sealed".utf8), vaultKey: selected, context: "locked")
        try await library.db.pool.write { db in
            try Note(id: "locked", text: "", title: "", titleKey: "", createdAt: .now, modifiedAt: .now,
                     isLocked: true, encryptedPayload: body).insert(db)
        }
        let entity = try library.entity(SyncLockEnvelopePayload(envelope: JSONEncoder().encode(envelope)), type: .keyBundle, id: "lock-vault")
        let engine = SyncEngine(database: library.db, paths: library.paths, accountID: "account", vaultKey: library.key,
                                transport: Transport([entity]), blobs: SyncPayloadReaderTests.Blobs())
        if kind == "mismatch" {
            await #expect(throws: (any Error).self) { try await engine.recoverPendingNoteVault(password: "password") }
            #expect(try NotePrivacy(store: library.store).envelope() == nil)
            try library.store.deletePermanently(["locked"])
            #expect(try await engine.recoverPendingNoteVault(password: "password"))
        } else {
            #expect(try await engine.recoverPendingNoteVault(password: "password"))
        }
    }
    @Test(arguments: [true, false]) @MainActor func sealedOrphanWithoutEnvelopeTriggersPrivateIntakeAndRecovery(matches: Bool) async throws {
        let library = try SyncMaterializerTests.Library(enabled: false); defer { library.cleanup() }
        let privacy = NotePrivacy(store: library.store)
        let access = try privacy.setPassword("password")
        let envelope = try JSONEncoder().encode(#require(try privacy.envelope()))
        do {
            let journal = try EditJournal(directory: library.paths.journal, noteId: "sealed-orphan", encryptionKey: access.journalKey())
            try journal.writeBase(JournalBase(storeRevision: 0, baseText: "Base"))
            try journal.append(JournalEntry(txId: "one", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: " saved")])))
        }
        access.revoke()
        try await library.db.pool.write { db in
            try db.execute(sql: "UPDATE sync_control SET applying=1 WHERE id=1")
            try db.execute(sql: "DELETE FROM crypto_envelope; DELETE FROM sync_dirty")
            try db.execute(sql: "UPDATE sync_control SET applying=0 WHERE id=1")
        }
        let before = try JournalRecoveryCoordinator.recover(store: library.store, access: nil, liveSessionIDs: [], dirtyLiveSessionIDs: [])
        #expect(before.keyState == .waitingForSyncKey && before.hasUncommittedRecovery)
        guard before.keyState == .waitingForSyncKey else { return }
        let remoteEnvelope = matches ? envelope : try JSONEncoder().encode(CryptoEnvelope.create(password: "password").0)
        let entity = try library.entity(SyncLockEnvelopePayload(envelope: remoteEnvelope), type: .keyBundle, id: "lock-vault")
        let engine = SyncEngine(database: library.db, paths: library.paths, accountID: "account", vaultKey: library.key,
                                transport: Transport([entity]), blobs: SyncPayloadReaderTests.Blobs())
        if !matches {
            #expect(try await engine.recoverPendingNoteVault(password: "password"))
            let wrongAccess = try privacy.unlock(password: "password"); defer { wrongAccess.revoke() }
            let report = try JournalRecoveryCoordinator.recover(store: library.store, access: wrongAccess, liveSessionIDs: [], dirtyLiveSessionIDs: [])
            #expect(report.quarantineFiles.contains("sealed-orphan.base"))
            return
        }
        #expect(try await engine.recoverPendingNoteVault(password: "password"))
        let recoveredAccess = try privacy.unlock(password: "password"); defer { recoveredAccess.revoke() }
        let result = try JournalRecoveryCoordinator.recover(store: library.store, access: recoveredAccess, liveSessionIDs: [], dirtyLiveSessionIDs: [])
        let note = try #require(result.singles.first?.note)
        #expect(try note.isLocked && recoveredAccess.note(id: note.id)?.text == "Base saved")
    }
    actor Transport: SyncTransport {
        let page: SyncPullResult
        var pushed = false, acknowledged = false
        init(_ changes: [SyncEntity]) { page = SyncPullResult(changes: changes, cursor: changes.last?.sequence ?? 0, hasMore: false) }
        func pull(after cursor: Int64) async throws -> SyncPullResult { page }
        func push(_ mutations: [SyncMutation]) async throws -> SyncPushResult { pushed = true; throw SyncProtocolError.invalidPayload }
        func acknowledge(_ cursor: Int64) async throws { acknowledged = true }
        func didWriteNetwork() -> Bool { pushed || acknowledged }
    }
    @Test func authenticatedVaultIntakeLeavesNotesQueuesAndCursorUnchanged() async throws {
        let library = try SyncMaterializerTests.Library(enabled: false); defer { library.cleanup() }
        let note = try library.store.create(text: "Keep exact note")
        let (envelope, _) = try CryptoEnvelope.create(password: "password")
        let entity = try library.entity(SyncLockEnvelopePayload(envelope: JSONEncoder().encode(envelope)), type: .keyBundle, id: "lock-vault")
        let transport = Transport([entity])
        let engine = SyncEngine(database: library.db, paths: library.paths, accountID: "account", vaultKey: library.key, transport: transport, blobs: SyncPayloadReaderTests.Blobs())
        #expect(try await !engine.pendingNoteVaultIsAbsent())
        let before = try await library.db.pool.read { try String.fetchAll($0, sql: "SELECT json_object('id',id,'text',text,'revision',revision) FROM note ORDER BY id") }
        let cursor = try library.inbox.cursor(), pending = try library.inbox.pending()
        #expect(try await engine.recoverPendingNoteVault(password: "password"))
        #expect(try NotePrivacy(store: library.store).envelope() == envelope)
        #expect(try library.store.note(id: note.id)?.text == note.text)
        let after = try await library.db.pool.read { try String.fetchAll($0, sql: "SELECT json_object('id',id,'text',text,'revision',revision) FROM note ORDER BY id") }
        #expect(after == before)
        #expect(try library.inbox.cursor() == cursor && library.inbox.pending() == pending)
        #expect(await !transport.didWriteNetwork())
    }
    @Test func installRechecksLocalStateAfterAnUnfencedScan() async throws {
        let library = try SyncMaterializerTests.Library(enabled: false); defer { library.cleanup() }
        let (envelope, _) = try CryptoEnvelope.create(password: "password")
        let entity = try library.entity(SyncLockEnvelopePayload(envelope: JSONEncoder().encode(envelope)), type: .keyBundle, id: "lock-vault")
        let engine = SyncEngine(database: library.db, paths: library.paths, accountID: "account", vaultKey: library.key, transport: Transport([entity]), blobs: SyncPayloadReaderTests.Blobs())
        let found = try #require(try await engine.scanPendingNoteVault(password: "password"))
        #expect(try NotePrivacy(store: library.store).envelope() == nil)
        let (local, _) = try CryptoEnvelope.create(password: "other")
        let localBytes = try JSONEncoder().encode(local)
        try await library.db.pool.write { try $0.execute(sql: "INSERT INTO crypto_envelope(id,envelope) VALUES(1,?)", arguments: [localBytes]) }
        await #expect(throws: (any Error).self) { try await engine.installPendingNoteVault(found) }
        #expect(try NotePrivacy(store: library.store).envelope() == local)
    }
    @Test func wrongPasswordCannotInstallEnvelope() async throws {
        let library = try SyncMaterializerTests.Library(enabled: false); defer { library.cleanup() }
        let (envelope, _) = try CryptoEnvelope.create(password: "right")
        let entity = try library.entity(SyncLockEnvelopePayload(envelope: JSONEncoder().encode(envelope)), type: .keyBundle, id: "lock-vault")
        let engine = SyncEngine(database: library.db, paths: library.paths, accountID: "account", vaultKey: library.key, transport: Transport([entity]), blobs: SyncPayloadReaderTests.Blobs())
        await #expect(throws: (any Error).self) { try await engine.recoverPendingNoteVault(password: "wrong") }
        #expect(try NotePrivacy(store: library.store).envelope() == nil)
        #expect(try library.inbox.cursor() == 0)
    }
    @Test func absentKeyReturnsFalseAndCursorRemainsUntouched() async throws {
        let library = try SyncMaterializerTests.Library(enabled: false); defer { library.cleanup() }
        let engine = SyncEngine(database: library.db, paths: library.paths, accountID: "account", vaultKey: library.key, transport: Transport([]), blobs: SyncPayloadReaderTests.Blobs())
        #expect(try await engine.pendingNoteVaultIsAbsent())
        #expect(try await engine.recoverPendingNoteVault(password: "password") == false)
        #expect(try library.inbox.cursor() == 0 && NotePrivacy(store: library.store).envelope() == nil)
    }
    @Test func staleEmptyPullIsNotAuthoritativeAbsence() async throws {
        let library = try SyncMaterializerTests.Library(enabled: false); defer { library.cleanup() }
        try await library.db.pool.write { try $0.execute(sql: "UPDATE sync_cursor SET sequence=2 WHERE id=1") }
        let engine = SyncEngine(database: library.db, paths: library.paths, accountID: "account", vaultKey: library.key, transport: Transport([]), blobs: SyncPayloadReaderTests.Blobs())
        await #expect(throws: (any Error).self) { try await engine.pendingNoteVaultIsAbsent() }
        #expect(try library.inbox.cursor() == 2)
    }
    @Test func enabledAccountMayFetchOnlyMissingVaultEnvelope() async throws {
        let library = try SyncMaterializerTests.Library(enabled: true); defer { library.cleanup() }
        let note = try library.store.create(text: "Unchanged")
        let (envelope, _) = try CryptoEnvelope.create(password: "password")
        let entity = try library.entity(SyncLockEnvelopePayload(envelope: JSONEncoder().encode(envelope)), type: .keyBundle, id: "lock-vault")
        let transport = Transport([entity])
        let engine = SyncEngine(database: library.db, paths: library.paths, accountID: "account", vaultKey: library.key, transport: transport, blobs: SyncPayloadReaderTests.Blobs())
        #expect(try await engine.recoverPendingNoteVault(password: "password"))
        #expect(try NotePrivacy(store: library.store).envelope() == envelope)
        #expect(try library.store.note(id: note.id)?.text == note.text && library.inbox.cursor() == 0)
        #expect(await !transport.didWriteNetwork())
    }
    @Test func staleRemoteHistoryCannotRollBackLocalCursor() async throws {
        let library = try SyncMaterializerTests.Library(enabled: false); defer { library.cleanup() }
        let (envelope, _) = try CryptoEnvelope.create(password: "password")
        let entity = try library.entity(SyncLockEnvelopePayload(envelope: JSONEncoder().encode(envelope)), type: .keyBundle, id: "lock-vault")
        try await library.db.pool.write { try $0.execute(sql: "UPDATE sync_cursor SET sequence=2 WHERE id=1") }
        let engine = SyncEngine(database: library.db, paths: library.paths, accountID: "account", vaultKey: library.key, transport: Transport([entity]), blobs: SyncPayloadReaderTests.Blobs())
        #expect(try await engine.recoverPendingNoteVault(password: "password") == false)
        #expect(try library.inbox.cursor() == 2 && NotePrivacy(store: library.store).envelope() == nil)
    }
    @Test func laterSequenceCannotRollBackKnownBundleRevision() async throws {
        let library = try SyncMaterializerTests.Library(enabled: false); defer { library.cleanup() }
        let (envelope, _) = try CryptoEnvelope.create(password: "password")
        let payload = SyncLockEnvelopePayload(envelope: try JSONEncoder().encode(envelope))
        let known = try library.entity(payload, type: .keyBundle, id: "lock-vault", revision: 9, sequence: 5)
        try library.receive([known])
        let stale = try library.entity(payload, type: .keyBundle, id: "lock-vault", revision: 2, sequence: 6)
        let engine = SyncEngine(database: library.db, paths: library.paths, accountID: "account", vaultKey: library.key, transport: Transport([stale]), blobs: SyncPayloadReaderTests.Blobs())
        #expect(try await engine.recoverPendingNoteVault(password: "password") == false)
        #expect(try NotePrivacy(store: library.store).envelope() == nil && library.inbox.cursor() == 5)
    }
    @Test func unauthenticatedOrAmbiguousBundlesCannotInstall() async throws {
        let library = try SyncMaterializerTests.Library(enabled: false); defer { library.cleanup() }
        let (envelope, _) = try CryptoEnvelope.create(password: "password")
        let entity = try library.entity(SyncLockEnvelopePayload(envelope: JSONEncoder().encode(envelope)), type: .keyBundle, id: "first")
        let other = try library.entity(SyncLockEnvelopePayload(envelope: JSONEncoder().encode(envelope)), type: .keyBundle, id: "second", sequence: 2)
        let blobs = SyncPayloadReaderTests.Blobs()
        let wrongKey = SyncEngine(database: library.db, paths: library.paths, accountID: "account", vaultKey: SymmetricKey(size: .bits256), transport: Transport([entity]), blobs: blobs)
        await #expect(throws: (any Error).self) { try await wrongKey.recoverPendingNoteVault(password: "password") }
        let ambiguous = SyncEngine(database: library.db, paths: library.paths, accountID: "account", vaultKey: library.key, transport: Transport([entity, other]), blobs: blobs)
        await #expect(throws: (any Error).self) { try await ambiguous.recoverPendingNoteVault(password: "password") }
        #expect(try NotePrivacy(store: library.store).envelope() == nil)
        #expect(try library.inbox.cursor() == 0)
    }
}
