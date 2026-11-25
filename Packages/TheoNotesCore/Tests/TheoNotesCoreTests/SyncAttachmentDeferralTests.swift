// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct SyncAttachmentDeferralTests {
    @Test(arguments: ["missing", "staging", "privacy", "compare", "recovery"])
    func unavailableLocalRecoveryDefersWithoutConsumingRejection(failure: String) async throws {
        let library = try SyncMaterializerTests.Library()
        defer { library.cleanup() }
        let note = try library.store.create(text: "# Local\n" + AttachmentMarkdown.link(for: "file.txt"))
        let original = Data("local bytes".utf8)
        _ = try AttachmentStore(paths: library.paths, database: library.db).add(data: original, filename: "file.txt", to: note.id)
        let access = try NotePrivacy(store: library.store).setPassword("password")
        defer { access.revoke() }
        let id = try #require(try await library.db.pool.read {
            try String.fetchOne($0, sql: "SELECT id FROM attachment WHERE noteId=?", arguments: [note.id])
        })
        let preparer = SyncAttachmentPreparer(database: library.db, paths: library.paths, accountID: "account", vaultKey: library.key)
        _ = try await preparer.preparePending()
        var pending: SyncMutation?
        for _ in 0..<10 {
            guard let next = try library.queue.prepareNext(vaultKey: library.key) else { break }
            if next.entityType == .attachment { pending = next; break }
        }
        let stale = try #require(pending)
        let localURL = library.paths.attachments.appendingPathComponent(note.id + "/file.txt")
        if failure == "missing" { try FileManager.default.removeItem(at: localURL) }
        try await library.db.pool.write { db in
            if failure == "staging" {
                try db.execute(sql: "INSERT INTO staging_batch(id,noteId,replacing,filenames,createdAt) VALUES('batch',?,0,'[]',0)", arguments: [note.id])
            }
            if failure == "privacy" {
                try db.execute(sql: "INSERT INTO privacy_transition(noteId,targetLocked,filenames) VALUES(?,1,'[]')", arguments: [note.id])
            }
            if failure == "recovery" {
                try db.execute(sql: "DELETE FROM sync_attachment_cache WHERE attachmentId=?", arguments: [id])
                try db.execute(sql: "DELETE FROM sync_dirty WHERE entityType='attachment' AND localId=?", arguments: [id])
            }
        }
        let name = id + ".bch"
        let inner = library.paths.root.appendingPathComponent("remote-inner.bch")
        if failure == "compare" { try Data("invalid protected content".utf8).write(to: inner) }
        else { try ChunkedCipher.encrypt(data: Data("remote bytes".utf8), output: inner, keyEncryptionKey: access.journalKey(), context: name) }
        let source = try Data(contentsOf: inner)
        let cipher = library.paths.root.appendingPathComponent("remote.bch")
        try ChunkedCipher.encrypt(data: source, output: cipher, keyEncryptionKey: library.key,
            context: SyncWire.cipherContext(accountID: "account", type: .attachment, entityID: id))
        let facts = try SyncAttachmentPreparer.hashFile(cipher)
        let payload = SyncAttachmentPayload(id: id, noteId: note.id, filename: name, isLocked: true,
            blobHash: facts.hash, cipherBytes: facts.size, fileBytes: Int64(source.count), fileHash: SyncWire.hash(source),
            uti: nil, width: nil, height: nil, ocrText: nil, createdAt: 1, updatedAt: 2)
        let remote = try library.entity(payload, type: .attachment, id: id, revision: 2, sequence: 20, refs: [facts.hash])
        try library.receive([remote])
        #expect(try await library.materializer(.init(files: [facts.hash: cipher])).apply(
            remote, rejectedMutationID: stale.mutationId, noteAccess: access) == .waitingForDependencies)
        #expect(try library.queue.pendingMutations().contains(stale))
        #expect(try library.inbox.pending().contains { $0 == remote })
        #expect(try await library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note") } == 1)
        #expect(try await library.db.pool.read { try Int.fetchOne($0, sql: "SELECT applying FROM sync_control WHERE id=1") } == 0)
        if failure != "missing" { #expect(try Data(contentsOf: localURL) == original) }
    }
}
