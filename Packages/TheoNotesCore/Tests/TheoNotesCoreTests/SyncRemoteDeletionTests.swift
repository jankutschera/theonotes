// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct SyncRemoteDeletionTests {
    typealias Library = SyncMaterializerTests.Library

    private func deletion(id: String = "note", revision: Int64 = 2, sequence: Int64 = 2) -> SyncEntity {
        SyncEntity(mutation: SyncMutation(mutationId: "delete-\(sequence)", entityType: .note,
            entityId: id, parentRevision: revision - 1, tombstone: true, ciphertext: nil, blobRefs: []),
            revision: revision, sequence: sequence, receivedAt: sequence)
    }

    @Test func remoteDeleteRetainsRecoverableNoteWithoutEchoAndRestoreRebases() async throws {
        let library = try Library(); defer { library.cleanup() }
        let original = library.payload("# Keep me\nExact body #tag\n")
        let first = try library.entity(original)
        try library.receive([first]); _ = try await library.materializer().apply(first)
        let before = try #require(try library.store.note(id: "note"))
        let tombstone = deletion()
        try library.receive([tombstone])
        #expect(try await library.materializer().apply(tombstone) == .applied)
        let retained = try #require(try library.store.note(id: "note"))
        #expect(retained.location == .trash && retained.trashedAt != nil)
        #expect(retained.text == before.text && retained.modifiedAt == before.modifiedAt)
        #expect(retained.revision == before.revision + 1)
        #expect(try library.queue.pendingCount() == 0)
        #expect(try library.inbox.pending().isEmpty)
        #expect(try await library.materializer().apply(tombstone) == .unchanged)
        let repeated = deletion(revision: 3, sequence: 3)
        try library.receive([repeated]); _ = try await library.materializer().apply(repeated)
        #expect(try library.store.note(id: "note") == retained)
        try library.store.restore(["note"])
        let upload = try #require(try library.queue.prepareNext(vaultKey: library.key))
        #expect(!upload.tombstone && upload.parentRevision == 3)
        #expect(try library.store.note(id: "note")?.text == original.text)
    }

    @Test(arguments: [false, true])
    func remoteDeletePreservesAttachmentBytesAndRestoreSnapshots(attachmentFirst: Bool) async throws {
        let library = try Library(); defer { library.cleanup() }
        let bytes = Data("precious attachment".utf8)
        let cipher = library.paths.root.appendingPathComponent("attachment.bch")
        try ChunkedCipher.encrypt(data: bytes, output: cipher, keyEncryptionKey: library.key,
            context: SyncWire.cipherContext(accountID: "account", type: .attachment, entityID: "asset"))
        let facts = try SyncAttachmentPreparer.hashFile(cipher)
        let attachment = SyncAttachmentPayload(id: "asset", noteId: "note", filename: "keep.png", isLocked: false,
            blobHash: facts.hash, cipherBytes: facts.size, fileBytes: Int64(bytes.count), fileHash: SyncWire.hash(bytes),
            uti: nil, width: nil, height: nil, ocrText: nil, createdAt: 1, updatedAt: 1)
        let first = try library.entity(library.payload("# Files\n![](keep.png)", attachments: ["asset"]))
        let file = try library.entity(attachment, type: .attachment, id: "asset", sequence: 2, refs: [facts.hash])
        let materializer = library.materializer(.init(files: [facts.hash: cipher]))
        try library.receive([first, file]); _ = try await materializer.apply(first)
        let directory = library.paths.attachments.appendingPathComponent("note")
        let noteDeletion = deletion(sequence: attachmentFirst ? 4 : 3)
        let fileDeletion = SyncEntity(mutation: SyncMutation(mutationId: "delete-file", entityType: .attachment,
            entityId: "asset", parentRevision: 1, tombstone: true, ciphertext: nil, blobRefs: []),
            revision: 2, sequence: attachmentFirst ? 3 : 4, receivedAt: 3)
        for entity in attachmentFirst ? [fileDeletion, noteDeletion] : [noteDeletion, fileDeletion] {
            try library.receive([entity]); _ = try await materializer.apply(entity)
        }
        #expect(try library.store.note(id: "note")?.location == .trash)
        #expect(try await library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM attachment WHERE noteId='note'") } == 1)
        #expect(try Data(contentsOf: directory.appendingPathComponent("keep.png")) == bytes)
        #expect(library.store.removeUnreferencedAttachments(noteId: "note", now: .distantFuture).isEmpty)
        #expect(try library.queue.pendingCount() == 0)
        try library.store.restore(["note"])
        let upload = try #require(try library.queue.prepareNext(vaultKey: library.key))
        #expect(!upload.tombstone && upload.parentRevision == 2 && upload.blobRefs.contains(facts.hash))
        let reader = SyncPayloadReader(accountID: "account", vaultKey: library.key, blobs: SyncPayloadReaderTests.Blobs())
        let restored = SyncEntity(mutation: upload, revision: 3, sequence: 5, receivedAt: 5)
        guard case .note(let payload) = try await reader.read(restored) else {
            Issue.record("Expected restored note payload"); return
        }
        #expect(payload.attachmentIds == ["asset"])
        #expect(payload.attachmentSnapshots?["asset"] == attachment)
        #expect(try Data(contentsOf: directory.appendingPathComponent("keep.png")) == bytes)
    }

    @Test func remoteDeleteDoesNotDiscardConcurrentLocalEdit() async throws {
        let library = try Library(); defer { library.cleanup() }
        let first = try library.entity(library.payload("Original"))
        try library.receive([first]); _ = try await library.materializer().apply(first)
        let before = try #require(try library.store.note(id: "note"))
        _ = try library.store.updateText(id: "note", text: "Unsynced local edit", expectedRevision: before.revision)
        let tombstone = deletion()
        try library.receive([tombstone]); _ = try await library.materializer().apply(tombstone)
        #expect(try library.store.note(id: "note")?.text == "Unsynced local edit")
        #expect(try library.store.note(id: "note")?.location == .notes)
        let upload = try #require(try library.queue.prepareNext(vaultKey: library.key))
        #expect(!upload.tombstone && upload.parentRevision == 2)
    }

    @Test func pendingUploadBlocksDeleteUntilCASResolutionAndKeepsLocalEdit() async throws {
        let library = try Library(); defer { library.cleanup() }
        let first = try library.entity(library.payload("Original"))
        try library.receive([first]); _ = try await library.materializer().apply(first)
        let before = try #require(try library.store.note(id: "note"))
        _ = try library.store.updateText(id: "note", text: "Queued local edit", expectedRevision: before.revision)
        let pending = try #require(try library.queue.prepareNext(vaultKey: library.key))
        let tombstone = deletion()
        try library.receive([tombstone])
        #expect(try await library.materializer().apply(tombstone) == .waitingForUpload)
        #expect(try library.store.note(id: "note")?.text == "Queued local edit")
        #expect(try await library.materializer().apply(tombstone, rejectedMutationID: pending.mutationId) == .applied)
        #expect(try library.store.note(id: "note")?.location == .notes)
        let replacement = try #require(try library.queue.prepareNext(vaultKey: library.key))
        #expect(!replacement.tombstone && replacement.parentRevision == 2)
        #expect(replacement.mutationId != pending.mutationId)
    }

    @Test func absentNoteIsNotInventedForRemoteDelete() async throws {
        let library = try Library(); defer { library.cleanup() }
        let tombstone = deletion(revision: 1, sequence: 1)
        try library.receive([tombstone]); _ = try await library.materializer().apply(tombstone)
        #expect(try library.store.note(id: "note") == nil)
        #expect(try library.queue.pendingCount() == 0)
        #expect(try library.inbox.pending().isEmpty)
    }

    @Test func lockedAttachmentsRemainDecryptableAfterRemoteDeleteAndRestore() async throws {
        let library = try Library(enabled: false); defer { library.cleanup() }
        let note = try library.store.create(text: "# Private\n[file](private.bin)")
        let bytes = Data("protected file content".utf8)
        _ = try AttachmentStore(paths: library.paths, database: library.db).add(data: bytes, filename: "private.bin", to: note.id)
        let access = try NotePrivacy(store: library.store).setPassword("test-password")
        defer { access.revoke() }
        try access.lock(noteId: note.id)
        let payload = try #require(try await library.db.pool.read { try SyncNotePayload.capture(id: note.id, includeRetained: true, in: $0) })
        let first = try library.entity(payload, id: note.id)
        try library.receive([first]); _ = try await library.materializer().apply(first)
        let tombstone = deletion(id: note.id)
        try library.receive([tombstone]); _ = try await library.materializer().apply(tombstone)
        #expect(try library.store.note(id: note.id)?.location == .trash)
        #expect(try library.store.note(id: note.id)?.encryptedPayload == payload.encryptedPayload)
        let output = library.paths.root.appendingPathComponent("restored-private.bin")
        try access.decryptAttachment("private.bin", noteId: note.id, to: output)
        #expect(try Data(contentsOf: output) == bytes)
        try library.store.restore([note.id])
        #expect(try access.note(id: note.id)?.text == note.text)
        #expect(try await library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM attachment WHERE noteId=?", arguments: [note.id]) } == 1)
    }

    @Test func lockedRemoteDeleteRetainsCiphertextWithoutPassword() async throws {
        let library = try Library(); defer { library.cleanup() }
        let (envelope, key) = try CryptoEnvelope.create(password: "test-password")
        let envelopeEntity = try library.entity(SyncLockEnvelopePayload(envelope: JSONEncoder().encode(envelope)),
            type: .keyBundle, id: "account-note-key")
        var payload = library.payload("", id: "secret")
        payload.isLocked = true
        payload.encryptedPayload = try NoteCipher.seal(JSONEncoder().encode(LockedNotePayload(text: "Secret body", attachments: [:])), vaultKey: key, context: payload.id)
        let first = try library.entity(payload, id: payload.id, sequence: 2)
        try library.receive([envelopeEntity, first])
        _ = try await library.materializer().apply(envelopeEntity)
        _ = try await library.materializer().apply(first)
        let before = try #require(try library.store.note(id: payload.id))
        let tombstone = deletion(id: payload.id, revision: 2, sequence: 3)
        try library.receive([tombstone]); _ = try await library.materializer().apply(tombstone)
        let retained = try #require(try library.store.note(id: payload.id))
        #expect(retained.location == .trash && retained.isLocked)
        #expect(retained.encryptedPayload == before.encryptedPayload && retained.text.isEmpty)
        let access = try NotePrivacy(store: library.store).unlock(password: "test-password")
        defer { access.revoke() }
        #expect(try access.note(id: payload.id)?.text == "Secret body")
        #expect(try library.queue.pendingCount() == 0)
    }
}
