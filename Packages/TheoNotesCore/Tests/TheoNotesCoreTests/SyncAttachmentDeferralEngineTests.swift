// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct SyncAttachmentDeferralEngineTests {
    @Test func unavailableRejectedAttachmentDoesNotBlockTheNextUploadBatch() async throws {
        let library = try SyncMaterializerTests.Library()
        defer { library.cleanup() }
        let note = try library.store.create(text: "# Local\n" + AttachmentMarkdown.link(for: "file.txt"))
        _ = try AttachmentStore(paths: library.paths, database: library.db).add(data: Data("local bytes".utf8), filename: "file.txt", to: note.id)
        let access = try NotePrivacy(store: library.store).setPassword("password")
        defer { access.revoke() }
        let id = try #require(try await library.db.pool.read {
            try String.fetchOne($0, sql: "SELECT id FROM attachment WHERE noteId=?", arguments: [note.id])
        })
        let preparer = SyncAttachmentPreparer(database: library.db, paths: library.paths, accountID: "account", vaultKey: library.key)
        _ = try await preparer.preparePending()
        // Keep only the attachment's immutable upload before adding the independent backlog.
        try await library.db.pool.write {
            try $0.execute(sql: "DELETE FROM sync_dirty WHERE entityType!='attachment'")
        }
        let stale = try #require(try library.queue.prepareNext(vaultKey: library.key))
        #expect(stale.entityType == .attachment)
        let localURL = library.paths.attachments.appendingPathComponent(note.id + "/file.txt")
        try FileManager.default.removeItem(at: localURL)
        for index in 0..<100 { _ = try library.store.create(text: "Independent upload \(index)") }
        for _ in 0..<100 { _ = try #require(try library.queue.prepareNext(vaultKey: library.key)) }
        let lastWire = try #require(try await library.db.pool.read {
            try Data.fetchOne($0, sql: "SELECT wireMutation FROM sync_outbox ORDER BY ordinal DESC LIMIT 1")
        })
        let lastMutation = try JSONDecoder().decode(SyncMutation.self, from: lastWire)
        #expect(lastMutation.entityType == .note)
        #expect(try await library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_outbox") } == 101)

        let name = id + ".bch"
        let inner = library.paths.root.appendingPathComponent("remote-inner.bch")
        try ChunkedCipher.encrypt(data: Data("remote bytes".utf8), output: inner, keyEncryptionKey: access.journalKey(), context: name)
        let source = try Data(contentsOf: inner)
        let cipher = library.paths.root.appendingPathComponent("remote.bch")
        try ChunkedCipher.encrypt(data: source, output: cipher, keyEncryptionKey: library.key,
            context: SyncWire.cipherContext(accountID: "account", type: .attachment, entityID: id))
        let facts = try SyncAttachmentPreparer.hashFile(cipher)
        let payload = SyncAttachmentPayload(id: id, noteId: note.id, filename: name, isLocked: true,
            blobHash: facts.hash, cipherBytes: facts.size, fileBytes: Int64(source.count), fileHash: SyncWire.hash(source),
            uti: nil, width: nil, height: nil, ocrText: nil, createdAt: 1, updatedAt: 2)
        let remote = try library.entity(payload, type: .attachment, id: id, revision: 2, sequence: 1, refs: [facts.hash])
        let server = SyncEngineTests.Server()
        _ = try await server.push([remote.mutation])
        let sync = SyncEngine(database: library.db, paths: library.paths, accountID: "account", vaultKey: library.key,
            transport: server, blobs: SyncPayloadReaderTests.Blobs(files: [facts.hash: cipher]))
        let summary = try await sync.synchronize(noteAccess: access)
        #expect(summary.uploaded == 100)
        #expect(await server.receipts[lastMutation.mutationId]?.mutation == lastMutation)
        #expect(try library.queue.pendingMutations() == [stale])
        #expect(try library.inbox.pending().contains { $0.mutation.entityId == id && $0.revision == 2 })
        #expect(try await library.db.pool.read {
            try String.fetchOne($0, sql: "SELECT noteId FROM attachment WHERE id=?", arguments: [id])
        } == note.id)
        #expect(!FileManager.default.fileExists(atPath: localURL.path))
        #expect(try library.store.note(id: note.id)?.isLocked == false)
        await sync.shutdown()
    }
}
