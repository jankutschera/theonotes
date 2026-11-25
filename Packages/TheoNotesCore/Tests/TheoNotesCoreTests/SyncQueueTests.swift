// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct SyncQueueTests {
    private struct Library {
        let paths: AppPaths
        let db: AppDatabase
        let store: NoteStore
        var queue: SyncQueue { SyncQueue(database: db) }
        init() throws {
            paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("sync-queue-\(UUID())"))
            try paths.createDirectories()
            db = try AppDatabase(path: paths.database)
            store = NoteStore(db: db, notifier: nil, paths: paths)
        }
        func cleanup() { try? db.pool.close(); try? FileManager.default.removeItem(at: paths.root) }
    }
    private func noteContent(_ db: Database, _ dirty: SyncDirty) throws -> SyncContent {
        guard dirty.type == .note, let note = try Note.fetchOne(db, key: dirty.localID) else { throw SyncQueueError.snapshotUnavailable }
        return SyncContent(payload: Data(note.text.utf8))
    }

    @Test func transactionRollbackCannotLeaveEditWithoutDirtyMarkerOrMarkerWithoutEdit() throws {
        let library = try Library(); defer { library.cleanup() }
        let note = try library.store.create(text: "original")
        #expect(try library.queue.pendingCount() == 0)
        try library.queue.enable(accountID: "account")
        let key = SymmetricKey(size: .bits256)
        let first = try #require(try library.queue.prepareNext(vaultKey: key, resolve: noteContent))
        try library.queue.accept(SyncEntity(mutation: first, revision: 1, sequence: 1, receivedAt: 1))
        #expect(try library.queue.pendingCount() == 0)
        enum SimulatedFailure: Error { case crash }
        #expect(throws: SimulatedFailure.crash) {
            try library.db.pool.write { db in
                try db.execute(sql: "UPDATE note SET text='rolled back',revision=revision+1 WHERE id=?", arguments: [note.id])
                throw SimulatedFailure.crash
            }
        }
        #expect(try library.store.note(id: note.id)?.text == "original")
        #expect(try library.queue.pendingCount() == 0)
        _ = try library.store.updateText(id: note.id, text: "saved", expectedRevision: note.revision)
        #expect(try library.queue.pendingCount() == 1)
    }

    @Test func newerEditSurvivesAcknowledgmentOfOlderEncryptedGenerationAndRestart() throws {
        let library = try Library(); defer { library.cleanup() }
        let note = try library.store.create(text: "first secret")
        try library.queue.enable(accountID: "account")
        let key = SymmetricKey(size: .bits256)
        let first = try #require(try library.queue.prepareNext(vaultKey: key, resolve: noteContent))
        _ = try library.store.updateText(id: note.id, text: "second secret", expectedRevision: note.revision)
        #expect(try library.queue.prepareNext(vaultKey: key, resolve: noteContent) == nil)
        let reopened = try AppDatabase(path: library.paths.database)
        defer { try? reopened.pool.close() }
        let resumed = SyncQueue(database: reopened)
        #expect(try resumed.pendingMutations() == [first])
        let accepted = SyncEntity(mutation: first, revision: 1, sequence: 1, receivedAt: 1)
        try resumed.accept(accepted)
        try resumed.accept(accepted)
        #expect(try resumed.pendingCount() == 1)
        let second = try #require(try resumed.prepareNext(vaultKey: key, resolve: noteContent))
        #expect(second.parentRevision == 1 && second.mutationId != first.mutationId)
        let context = try SyncWire.cipherContext(accountID: "account", type: .note, entityID: note.id)
        #expect(try NoteCipher.open(SyncWire.decode64(#require(first.ciphertext)), vaultKey: key, context: context) == Data("first secret".utf8))
        #expect(try NoteCipher.open(SyncWire.decode64(#require(second.ciphertext)), vaultKey: key, context: context) == Data("second secret".utf8))
        try resumed.accept(SyncEntity(mutation: second, revision: 2, sequence: 2, receivedAt: 2))
        #expect(try resumed.pendingCount() == 0)
        for table in ["sync_outbox", "sync_shadow"] {
            let column = table == "sync_outbox" ? "wireMutation" : "wireEntity"
            let data = try reopened.pool.read { try Data.fetchAll($0, sql: "SELECT \(column) FROM \(table)") }
            #expect(data.allSatisfy { $0.range(of: Data("secret".utf8)) == nil })
        }
    }

    @Test func failedPreparationAndForgedReceiptKeepDurableWork() throws {
        let library = try Library(); defer { library.cleanup() }
        _ = try library.store.create(text: "important")
        try library.queue.enable(accountID: "account")
        #expect(try library.queue.prepareNext(vaultKey: SymmetricKey(size: .bits256)) { _, _ in throw SyncQueueError.snapshotUnavailable } == nil)
        #expect(try library.queue.pendingCount() == 1)
        #expect(try library.queue.pendingMutations().isEmpty)
        let mutation = try #require(try library.queue.prepareNext(vaultKey: SymmetricKey(size: .bits256), resolve: noteContent))
        var forged = mutation; forged.ciphertext = "YWJj"
        #expect(throws: SyncQueueError.invalidReceipt) { try library.queue.accept(SyncEntity(mutation: forged, revision: 1, sequence: 1, receivedAt: 1)) }
        #expect(try library.queue.pendingMutations() == [mutation])
        #expect(throws: SyncQueueError.accountMismatch) { try library.queue.enable(accountID: "other") }
    }

    @Test func unavailableAttachmentDoesNotStarveReadyNotesAndRemainsDirty() throws {
        let library = try Library(); defer { library.cleanup() }
        let note = try library.store.create(text: "![](missing.png)\nSaved note")
        try library.queue.enable(accountID: "account")
        let mutation = try #require(try library.queue.prepareNext(vaultKey: SymmetricKey(size: .bits256)))
        #expect(mutation.entityType == .note && mutation.entityId == note.id)
        try library.queue.accept(SyncEntity(mutation: mutation, revision: 1, sequence: 1, receivedAt: 1))
        #expect(try library.queue.pendingCount() == 1)
        #expect(try library.queue.prepareNext(vaultKey: SymmetricKey(size: .bits256)) == nil)
    }

    @Test func largeEncryptedPayloadIsDurablyStagedBeforeMutationReferencesIt() throws {
        let library = try Library(); defer { library.cleanup() }
        let body = Data(String(repeating: "🐻", count: 100_000).utf8)
        let note = try library.store.create(text: String(decoding: body, as: UTF8.self))
        try library.queue.enable(accountID: "account")
        let key = SymmetricKey(size: .bits256)
        let mutation = try #require(try library.queue.prepareNext(vaultKey: key, resolve: noteContent))
        #expect(mutation.ciphertext == nil)
        let hash = try #require(mutation.payloadRef)
        #expect(mutation.blobRefs == [hash])
        let cipher = try #require(try library.db.pool.read { try Data.fetchOne($0, sql: "SELECT data FROM sync_blob_state WHERE hash=?", arguments: [hash]) })
        #expect(SyncWire.hash(cipher) == hash)
        #expect(try NoteCipher.open(cipher, vaultKey: key, context: SyncWire.cipherContext(accountID: "account", type: .note, entityID: note.id)) == body)
    }

    @Test func localPreferencesAndUIStateNeverQueueButPortableSettingsDo() throws {
        let library = try Library(); defer { library.cleanup() }
        let note = try library.store.create(text: "note")
        try library.queue.enable(accountID: "account")
        let first = try #require(try library.queue.prepareNext(vaultKey: SymmetricKey(size: .bits256), resolve: noteContent))
        try library.queue.accept(SyncEntity(mutation: first, revision: 1, sequence: 1, receivedAt: 1))
        let settings = Settings(db: library.db)
        try settings.set(SettingKey<Bool>("mobile.biometry", default: false), to: true)
        try settings.set(.bearCLIPath, to: "/private/local/path")
        try library.db.pool.write { db in
            try db.execute(sql: "INSERT INTO note_ui_state(noteId,selection,scrollTop) VALUES(?,'[1,2]',42)", arguments: [note.id])
        }
        #expect(try library.queue.pendingCount() == 0)
        try settings.set(.autoSortTodos, to: true)
        let dirty = try library.db.pool.read { try Row.fetchAll($0, sql: "SELECT entityType,localId FROM sync_dirty") }
        #expect(dirty.count == 1 && dirty[0]["entityType"] as String == "setting" && dirty[0]["localId"] as String == "autoSortTodos")
    }

    @Test func remoteApplyAndCursorAreAtomicAndDoNotEchoChanges() throws {
        let library = try Library(); defer { library.cleanup() }
        let note = try library.store.create(text: "local")
        try library.queue.enable(accountID: "account")
        let first = try #require(try library.queue.prepareNext(vaultKey: SymmetricKey(size: .bits256), resolve: noteContent))
        try library.queue.accept(SyncEntity(mutation: first, revision: 1, sequence: 1, receivedAt: 1))
        enum Failure: Error { case interrupted }
        #expect(throws: Failure.interrupted) {
            try library.queue.applyRemote(cursor: 2) { db in
                try db.execute(sql: "UPDATE note SET text='remote' WHERE id=?", arguments: [note.id])
                throw Failure.interrupted
            }
        }
        #expect(try library.store.note(id: note.id)?.text == "local")
        #expect(try library.db.pool.read { try Int.fetchOne($0, sql: "SELECT sequence FROM sync_cursor") } == 0)
        try library.queue.applyRemote(cursor: 2) { db in
            try db.execute(sql: "UPDATE note SET text='remote',revision=revision+1 WHERE id=?", arguments: [note.id])
        }
        #expect(try library.queue.pendingCount() == 0)
        #expect(try library.db.pool.read { try Int.fetchOne($0, sql: "SELECT sequence FROM sync_cursor") } == 2)
        let remote = try #require(try library.store.note(id: note.id))
        _ = try library.store.updateText(id: note.id, text: "local again", expectedRevision: remote.revision)
        #expect(try library.queue.pendingCount() == 1)
    }

    @Test func independentLibrariesUseTheSameOpaqueIDsForSharedMetadata() throws {
        let first = try Library(), second = try Library()
        defer { first.cleanup(); second.cleanup() }
        let key = SymmetricKey(size: .bits256)
        for library in [first, second] {
            try library.queue.configure(accountID: "account")
            let local = try library.store.create(text: "#Work/Things")
            try Settings(db: library.db).set(.hideMarkdown, to: false)
            // Configuration captures local writes immediately, while upload preparation still waits.
            let captured = try library.db.pool.read { db in
                try String.fetchAll(db, sql: "SELECT entityType || ':' || localId FROM sync_dirty ORDER BY entityType,localId")
            }
            let tagIDs = try library.db.pool.read { try String.fetchAll($0, sql: "SELECT id FROM tag") }
            let expected = ["note:" + local.id, "setting:hideMarkdown"] + tagIDs.map { "tagPreference:" + $0 }
            #expect(Set(captured) == Set(expected))
            #expect(try !library.queue.isEnabled())
            #expect(try library.queue.pendingMutations().isEmpty)
            try library.queue.enable(accountID: "account")
            while try library.queue.prepareNext(vaultKey: key) != nil {}
        }
        let a = try first.queue.pendingMutations(), b = try second.queue.pendingMutations()
        for type in [SyncEntityType.tagPreference, .setting] {
            let mine = Set(a.filter { $0.entityType == type }.map(\.entityId))
            let theirs = Set(b.filter { $0.entityType == type }.map(\.entityId))
            #expect(!mine.isEmpty && mine == theirs)
            #expect(mine.allSatisfy { $0.hasPrefix("m-") && !$0.contains("work") })
        }
        #expect(a.first(where: { $0.entityType == .note })?.entityId != b.first(where: { $0.entityType == .note })?.entityId)
        #expect(throws: SyncQueueError.accountMismatch) { try first.queue.configure(accountID: "other") }
    }
}
