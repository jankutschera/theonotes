// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct SyncRecoveryLibraryTests {
    @Test func publishedProtectedSourceAndItsOutboxStayIntactWhileSeparateCopyConverts() async throws {
        let original = try SyncMaterializerTests.Library()
        defer { original.cleanup() }
        let exact = try original.store.create(text: "# Exact e\u{301}\r\n#Work\n")
        let note = try original.store.create(text: "# Local secret\n[file](private.txt)")
        let bytes = Data("protected file".utf8)
        _ = try AttachmentStore(paths: original.paths, database: original.db).add(data: bytes, filename: "private.txt", to: note.id)
        let access = try NotePrivacy(store: original.store).setPassword("local password"); defer { access.revoke() }
        try access.lock(noteId: note.id)
        let published = try original.store.create(text: "published ancestor")
        while try original.queue.prepareNext(vaultKey: original.key) != nil {}
        let ancestor = try #require(try original.queue.pendingMutations().first { $0.entityType == .note && $0.entityId == published.id })
        try original.queue.accept(SyncEntity(mutation: ancestor, revision: 1, sequence: 1, receivedAt: 1))
        _ = try original.store.updateText(id: published.id, text: "pending published edit", expectedRevision: published.revision)
        while try original.queue.prepareNext(vaultKey: original.key) != nil {}
        let shadows = try await original.db.pool.read { try Data.fetchAll($0, sql: "SELECT wireEntity FROM sync_shadow ORDER BY entityType,entityId") }
        let outbox = try original.queue.pendingMutations(), originalCipher = try original.store.note(id: note.id)?.encryptedPayload
        let envelope = try NotePrivacy(store: original.store).envelope()
        let archive = try LibraryBackup(database: original.db, paths: original.paths).createRolling()
        let prepared = try SyncRecoveryLibrary.prepare(source: original.paths, archive: archive)
        defer { try? FileManager.default.removeItem(at: prepared.paths.root) }
        #expect(try original.queue.pendingMutations() == outbox)
        #expect(try original.queue.isEnabled())
        #expect(try original.store.note(id: note.id)?.encryptedPayload == originalCipher)
        #expect(try NotePrivacy(store: original.store).envelope() == envelope)
        #expect(AppPaths.isSameDirectory(try SyncRecoveryLibrary.activePaths(base: original.paths).root, original.paths.root))
        let copy = try AppDatabase(path: prepared.paths.database); defer { try? copy.pool.close() }
        let copyStore = NoteStore(db: copy, notifier: nil, paths: prepared.paths)
        #expect(try copyStore.note(id: exact.id).map { Data($0.text.utf8) } == Data(exact.text.utf8))
        #expect(try !SyncQueue(database: copy).isEnabled())
        #expect(try !SyncQueue(database: copy).hasRemoteState())
        let localAccess = try NotePrivacy(store: copyStore).unlock(password: "local password"); defer { localAccess.revoke() }
        let (remoteEnvelope, remoteKey) = try CryptoEnvelope.create(password: "remote password")
        let entity = try original.entity(SyncLockEnvelopePayload(envelope: JSONEncoder().encode(remoteEnvelope)), type: .keyBundle, id: "remote-vault")
        let server = SyncEngineTests.Server()
        _ = try await server.push([entity.mutation])
        try SyncQueue(database: copy).configure(accountID: "account")
        let engine = SyncEngine(database: copy, paths: prepared.paths, accountID: "account", vaultKey: original.key, transport: server, blobs: SyncPayloadReaderTests.Blobs())
        let summary = try await engine.synchronize(noteAccess: localAccess, remoteNotePassword: "remote password")
        #expect(summary.passwordRefreshRequired && summary.uploaded == 0)
        #expect(await server.count() == 1)
        let converted = try NotePrivacy(store: copyStore).unlock(password: "remote password"); defer { converted.revoke() }
        #expect(try converted.note(id: note.id)?.text == note.text)
        let convertedCipher = try #require(try copyStore.note(id: note.id)?.encryptedPayload)
        let body = try JSONDecoder().decode(LockedNotePayload.self, from: NoteCipher.open(convertedCipher, vaultKey: remoteKey, context: note.id))
        let opaque = try #require(body.attachments["private.txt"])
        let clearFile = prepared.paths.root.appendingPathComponent("test-decrypted-file")
        try ChunkedCipher.decrypt(input: prepared.paths.attachments.appendingPathComponent(note.id).appendingPathComponent(opaque), output: clearFile, keyEncryptionKey: remoteKey, context: opaque)
        #expect(try Data(contentsOf: clearFile) == bytes)
        try FileManager.default.removeItem(at: clearFile)
        #expect(try await original.db.pool.read { try Data.fetchAll($0, sql: "SELECT wireEntity FROM sync_shadow ORDER BY entityType,entityId") } == shadows)
        #expect(try original.store.note(id: note.id)?.encryptedPayload == originalCipher)
        #expect(try original.queue.pendingMutations() == outbox)
        try SyncRecoveryLibrary.select(prepared)
        #expect(AppPaths.isSameDirectory(try SyncRecoveryLibrary.activePaths(base: original.paths).root, prepared.paths.root))
        #expect(try SyncRecoveryLibrary.identity(paths: prepared.paths) == prepared.id)
        #expect(AppPaths.isSameDirectory(try AppPaths.resolve(arguments: ["test"], environment: [:], production: original.paths).root, prepared.paths.root))
        try SyncRecoveryLibrary.selectOriginal(for: prepared.paths)
        #expect(AppPaths.isSameDirectory(try SyncRecoveryLibrary.activePaths(base: original.paths).root, original.paths.root))
        #expect(try SyncRecoveryLibrary.preparedCopy(source: original.paths)?.id == prepared.id)
        await engine.shutdown()
    }

    @Test func selectionRejectsTraversalAndSymlinkTargets() throws {
        let original = try SyncMaterializerTests.Library(enabled: false); defer { original.cleanup() }
        let selection = original.paths.root.appendingPathComponent(".active-recovery-library.json")
        try Data("{\"version\":1,\"name\":\"../elsewhere\"}".utf8).write(to: selection)
        #expect(throws: RecoveryLibraryError.self) { try SyncRecoveryLibrary.activePaths(base: original.paths) }
        try FileManager.default.removeItem(at: selection)
        _ = try original.store.create(text: "kept")
        let archive = try LibraryBackup(database: original.db, paths: original.paths).createRolling()
        let prepared = try SyncRecoveryLibrary.prepare(source: original.paths, archive: archive)
        defer { try? FileManager.default.removeItem(at: prepared.paths.root) }
        try FileManager.default.removeItem(at: prepared.paths.root)
        try FileManager.default.createSymbolicLink(at: prepared.paths.root, withDestinationURL: original.paths.root)
        #expect(throws: RecoveryLibraryError.self) { try SyncRecoveryLibrary.select(prepared) }
        #expect(try original.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note") } == 1)
    }
}
