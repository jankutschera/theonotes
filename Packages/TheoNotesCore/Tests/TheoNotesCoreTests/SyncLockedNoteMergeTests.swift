// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct SyncLockedNoteMergeTests {
    @Test(arguments: [false, true]) func firstSyncConvertsAnIndependentVaultWithARecoverableBackupBeforePublishing(corruptFile: Bool) async throws {
        let library = try SyncMaterializerTests.Library(enabled: false)
        let restored = try SyncMaterializerTests.Library(enabled: false)
        defer { library.cleanup(); restored.cleanup() }
        let local = try library.store.create(text: "# Local secret\n![](missing.png)\n[kept](secret.txt)")
        let bytes = Data("retained private file".utf8)
        _ = try AttachmentStore(paths: library.paths, database: library.db).add(data: bytes, filename: "secret.txt", to: local.id)
        let access = try NotePrivacy(store: library.store).setPassword("local password"); defer { access.revoke() }
        try access.lock(noteId: local.id)
        let before = try #require(try await library.db.pool.read { try SyncNotePayload.capture(id: local.id, includeRetained: true, in: $0) })
        let originalEnvelope = try NotePrivacy(store: library.store).envelope()
        if corruptFile {
            let file = try #require(try FileManager.default.contentsOfDirectory(at: library.paths.attachments.appendingPathComponent(local.id), includingPropertiesForKeys: nil).first)
            var corrupted = try Data(contentsOf: file)
            corrupted[corrupted.count - 1] ^= 1
            try corrupted.write(to: file, options: .atomic)
        }
        let (envelope, key) = try CryptoEnvelope.create(password: "account password")
        let envelopeEntity = try library.entity(SyncLockEnvelopePayload(envelope: JSONEncoder().encode(envelope)), type: .keyBundle, id: "account-note-key")
        var incoming = library.payload("# Remote secret", id: "remote-note")
        incoming.isLocked = true; incoming.text = ""
        incoming.encryptedPayload = try NoteCipher.seal(JSONEncoder().encode(LockedNotePayload(text: "# Remote secret", attachments: [:])), vaultKey: key, context: incoming.id)
        let noteEntity = try library.entity(incoming, id: incoming.id, sequence: 2)
        let server = SyncEngineTests.Server()
        _ = try await server.push([envelopeEntity.mutation, noteEntity.mutation])
        let engine = SyncEngineTests().engine(library, server)
        if corruptFile {
            await #expect(throws: CryptoError.self) {
                try await engine.synchronize(noteAccess: access, remoteNotePassword: "account password")
            }
            #expect(try NotePrivacy(store: library.store).envelope() == originalEnvelope)
            #expect(try library.store.note(id: local.id)?.encryptedPayload == before.encryptedPayload)
            #expect(try library.inbox.pending().count == 2)
            #expect(try !library.queue.isEnabled())
            #expect(try await library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM staging_batch") } == 0)
            #expect(await server.count() == 2)
            await engine.shutdown()
            return
        }
        let first = try await engine.synchronize(noteAccess: access, remoteNotePassword: "account password")
        #expect(first.passwordRefreshRequired && first.uploaded == 0 && first.pendingDownloads == 1)
        #expect(try !library.queue.isEnabled())
        #expect(await server.count() == 2)
        #expect(try library.store.note(id: incoming.id) == nil)
        let reopened = try NotePrivacy(store: library.store).unlock(password: "account password"); defer { reopened.revoke() }
        #expect(try reopened.note(id: local.id)?.text == local.text)
        let after = try #require(try await library.db.pool.read { try SyncNotePayload.capture(id: local.id, includeRetained: true, in: $0) })
        #expect(after.attachmentIds == before.attachmentIds && after.attachmentNames == before.attachmentNames)
        #expect(after.modifiedAt == before.modifiedAt && after.text.isEmpty && after.encryptedPayload != before.encryptedPayload)
        let output = library.paths.root.appendingPathComponent("verified-converted")
        try reopened.decryptAttachment("secret.txt", noteId: local.id, to: output)
        #expect(try Data(contentsOf: output) == bytes)
        let second = try await engine.synchronize(noteAccess: reopened, remoteNotePassword: "account password")
        #expect(!second.passwordRefreshRequired && second.pendingDownloads == 0 && second.uploaded == 0)
        #expect(try reopened.note(id: incoming.id)?.text == "# Remote secret")
        let archives = try FileManager.default.contentsOfDirectory(at: library.paths.backups, includingPropertiesForKeys: nil).filter { $0.pathExtension == "baerchen-backup" }
        let archive = try #require(archives.first)
        #expect(try LibraryBackup(database: library.db, paths: library.paths).inspect(archive).missingAttachmentCount == 1)
        _ = try LibraryBackup(database: restored.db, paths: restored.paths).restore(archive)
        let oldAccess = try NotePrivacy(store: restored.store).unlock(password: "local password"); defer { oldAccess.revoke() }
        #expect(try oldAccess.note(id: local.id)?.text == local.text)
        let oldOutput = restored.paths.root.appendingPathComponent("verified-backup")
        try oldAccess.decryptAttachment("secret.txt", noteId: local.id, to: oldOutput)
        #expect(try Data(contentsOf: oldOutput) == bytes)
        await engine.shutdown()
    }

    @Test func remotePasswordRemovalCannotDiscardAnOfflineNotesKey() async throws {
        let library = try SyncMaterializerTests.Library(); defer { library.cleanup() }
        let privacy = NotePrivacy(store: library.store)
        let access = try privacy.setPassword("retained password"); defer { access.revoke() }
        let note = try library.store.create(text: "offline protected note")
        try access.lock(noteId: note.id)
        let envelope = try privacy.envelope()
        while try library.queue.prepareNext(vaultKey: library.key) != nil {}
        let pending = try #require(try library.queue.pendingMutations().first { $0.entityType == .keyBundle })
        let deletion = SyncEntity(mutation: SyncMutation(mutationId: "delete-password", entityType: .keyBundle,
            entityId: pending.entityId, parentRevision: 0, tombstone: true, ciphertext: nil, blobRefs: []), revision: 1, sequence: 1, receivedAt: 1)
        try library.receive([deletion])
        #expect(try await library.materializer().apply(deletion, rejectedMutationID: pending.mutationId) == .applied)
        #expect(try privacy.envelope() == envelope)
        #expect(try access.note(id: note.id)?.text == "offline protected note")
        let replacement = try #require(try library.queue.prepareNext(vaultKey: library.key))
        #expect(replacement.entityType == .keyBundle && !replacement.tombstone && replacement.parentRevision == 1)
        #expect(try library.inbox.pending().isEmpty)
    }

    @Test(arguments: [false, true]) func passwordChangeRequiresProofAndPreservesDifferentVaults(differentVault: Bool) async throws {
        let library = try SyncMaterializerTests.Library(); defer { library.cleanup() }
        let privacy = NotePrivacy(store: library.store)
        let access = try privacy.setPassword("old password"); defer { access.revoke() }
        let note = try library.store.create(text: "private text")
        try access.lock(noteId: note.id)
        let original = try #require(try privacy.envelope())
        let remote = try differentVault ? CryptoEnvelope.create(password: "new password").0 : original.rewrapped(oldPassword: "old password", newPassword: "new password")
        while try library.queue.prepareNext(vaultKey: library.key) != nil {}
        let pending = try #require(try library.queue.pendingMutations().first { $0.entityType == .keyBundle })
        let entity = try library.entity(SyncLockEnvelopePayload(envelope: JSONEncoder().encode(remote)), type: .keyBundle, id: pending.entityId)
        try library.receive([entity])
        let materializer = library.materializer()
        #expect(try await materializer.apply(entity) == .waitingForUpload)
        #expect(try await materializer.apply(entity, rejectedMutationID: pending.mutationId) == .waitingForUnlock)
        await #expect(throws: CryptoError.wrongPassword) {
            try await materializer.apply(entity, rejectedMutationID: pending.mutationId, noteAccess: access, remoteNotePassword: "incorrect")
        }
        #expect(try privacy.envelope() == original)
        if differentVault {
            await #expect(throws: SyncNotePasswordError.self) {
                try await materializer.apply(entity, rejectedMutationID: pending.mutationId, noteAccess: access, remoteNotePassword: "new password")
            }
            #expect(try privacy.envelope() == original)
            #expect(try library.inbox.pending().count == 1)
            #expect(try library.queue.pendingMutations().contains { $0.mutationId == pending.mutationId })
        } else {
            #expect(try await materializer.apply(entity, rejectedMutationID: pending.mutationId, noteAccess: access, remoteNotePassword: "new password") == .applied)
            #expect(try privacy.envelope() == remote)
            let reopened = try privacy.unlock(password: "new password"); defer { reopened.revoke() }
            #expect(try reopened.note(id: note.id)?.text == "private text")
            #expect(throws: CryptoError.wrongPassword) { try privacy.unlock(password: "old password") }
            #expect(try library.inbox.pending().isEmpty)
            #expect(try !library.queue.pendingMutations().contains { $0.mutationId == pending.mutationId })
            #expect(try await materializer.apply(entity) == .unchanged)
        }
    }

    @Test(arguments: [false, true]) func authorizedMergeKeepsBodiesAndCopiedFilesEncrypted(conflicting: Bool) async throws {
        let library = try SyncMaterializerTests.Library(); defer { library.cleanup() }
        let access = try NotePrivacy(store: library.store).setPassword("private password")
        defer { access.revoke() }
        let key = try access.journalKey(), asset = UUID().uuidString.lowercased()
        let bytes = Data("secret attachment bytes".utf8), opaque = asset + ".bch"
        let inner = library.paths.root.appendingPathComponent("inner"), outer = library.paths.root.appendingPathComponent("outer")
        try ChunkedCipher.encrypt(data: bytes, output: inner, keyEncryptionKey: key, context: opaque)
        try ChunkedCipher.encrypt(input: inner, output: outer, keyEncryptionKey: library.key,
            context: SyncWire.cipherContext(accountID: "account", type: .attachment, entityID: asset))
        let fileFacts = try SyncAttachmentPreparer.hashFile(inner), cipherFacts = try SyncAttachmentPreparer.hashFile(outer)
        let descriptor = SyncAttachmentPayload(id: asset, noteId: "note", filename: opaque, isLocked: true,
            blobHash: cipherFacts.hash, cipherBytes: cipherFacts.size, fileBytes: fileFacts.size, fileHash: fileFacts.hash,
            uti: nil, width: nil, height: nil, ocrText: nil, createdAt: 1, updatedAt: 1)
        func protected(_ text: String) throws -> SyncNotePayload {
            var note = library.payload(text, attachments: [asset])
            note.isLocked = true; note.text = ""; note.attachmentNames = [asset: opaque]
            note.encryptedPayload = try NoteCipher.seal(JSONEncoder().encode(LockedNotePayload(
                text: text, attachments: ["secret.txt": opaque], attachmentIDs: ["secret.txt": asset])), vaultKey: key, context: "note")
            return note
        }
        let first = try library.entity(protected("Title\n\na\n\nb\n[asset](secret.txt)"))
        let attachment = try library.entity(descriptor, type: .attachment, id: asset, sequence: 2, refs: [cipherFacts.hash])
        try library.receive([first, attachment])
        #expect(try await library.materializer(.init(files: [cipherFacts.hash: outer])).apply(first) == .applied)
        let current = try #require(try access.note(id: "note"))
        _ = try access.updateText(id: "note", text: "Title\n\nLOCAL\n\nb\n[asset](secret.txt)", expectedRevision: current.revision)
        // Upload the local attachment metadata first, as a real engine cycle does. The
        // note upload is rejected below; it must remain immutable until that rejection.
        _ = try await SyncAttachmentPreparer(database: library.db, paths: library.paths, accountID: "account", vaultKey: library.key).preparePending()
        var rejected: String?
        var receiptSequence: Int64 = 10
        while let mutation = try library.queue.prepareNext(vaultKey: library.key) {
            if mutation.entityType == .note { rejected = mutation.mutationId }
            else {
                try library.queue.accept(SyncEntity(mutation: mutation, revision: mutation.parentRevision + 1, sequence: receiptSequence, receivedAt: receiptSequence))
                receiptSequence += 1
            }
        }
        let rejectedID = try #require(rejected)
        var sources = try await library.db.pool.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT hash,localPath FROM sync_blob_state").map {
                ($0["hash"] as String, library.paths.root.appendingPathComponent(try SyncBlobLocation.relative($0["localPath"] as String)))
            })
        }
        sources[cipherFacts.hash] = outer
        let materializer = library.materializer(.init(files: sources))
        let remoteText = conflicting ? "Title\n\nREMOTE\n\nb\n[asset](secret.txt)" : "Title\n\na\n\nREMOTE\n[asset](secret.txt)"
        let next = try library.entity(protected(remoteText), revision: 2, sequence: 3)
        try library.receive([next])
        #expect(try await materializer.apply(next, rejectedMutationID: rejectedID) == .waitingForUnlock)
        let applied = try await materializer.apply(next, rejectedMutationID: rejectedID, noteAccess: access)
        #expect(applied == .applied)
        #expect(try library.store.note(id: "note")?.text.isEmpty == true)
        #expect(try await library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note_search_content") } == 0)
        if conflicting {
            let copyID = SyncNoteMerge.conflictID(entityID: "note", mutationID: rejectedID, remoteRevision: 2)
            #expect(try access.note(id: copyID)?.text == remoteText)
            #expect(try access.note(id: "note")?.text.contains("LOCAL") == true)
            let copyAsset = SyncMaterializer.copyAttachmentID(asset, noteID: copyID)
            let file = library.paths.attachments.appendingPathComponent(copyID + "/" + copyAsset + ".bch")
            #expect(try Data(contentsOf: file).range(of: bytes) == nil)
            let output = library.paths.root.appendingPathComponent("verified")
            try access.decryptAttachment("secret.txt", noteId: copyID, to: output)
            #expect(try Data(contentsOf: output) == bytes)
            #expect(try await library.db.pool.read { try String.fetchOne($0, sql: "SELECT id FROM attachment WHERE noteId=?", arguments: [copyID]) } == copyAsset)
            #expect(try await materializer.apply(next, noteAccess: access) == .unchanged)
            #expect(try await library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note") } == 2)
        } else {
            #expect(try access.note(id: "note")?.text == "Title\n\nLOCAL\n\nREMOTE\n[asset](secret.txt)")
            let output = library.paths.root.appendingPathComponent("verified")
            try access.decryptAttachment("secret.txt", noteId: "note", to: output)
            #expect(try Data(contentsOf: output) == bytes)
            try await checkAttachmentConflict(library: library, materializer: materializer, access: access,
                descriptor: descriptor, originalBytes: bytes)
        }
    }

    private func checkAttachmentConflict(library: SyncMaterializerTests.Library, materializer: SyncMaterializer,
                                         access: LockedNoteAccess, descriptor: SyncAttachmentPayload,
                                         originalBytes: Data) async throws {
        let changedBytes = Data("locally replaced private bytes".utf8)
        let replacement = library.paths.root.appendingPathComponent("replacement.bch")
        try ChunkedCipher.encrypt(data: changedBytes, output: replacement, keyEncryptionKey: access.journalKey(), context: descriptor.filename)
        let existing = library.paths.attachments.appendingPathComponent("note/" + descriptor.filename)
        try Data(contentsOf: replacement).write(to: existing, options: .atomic)
        let facts = try SyncAttachmentPreparer.hashFile(existing)
        try await library.db.pool.write { db in
            try db.execute(sql: "UPDATE attachment SET updatedAt=?,sha256=?,byteSize=? WHERE id=?", arguments: [Date(), facts.hash, facts.size, descriptor.id])
        }
        let entity = try library.entity(descriptor, type: .attachment, id: descriptor.id, revision: 3, sequence: 30, refs: [descriptor.blobHash])
        try library.receive([entity])
        #expect(try await materializer.apply(entity) == .waitingForUnlock)
        #expect(try await materializer.apply(entity, noteAccess: access) == .applied)
        let copyID = SyncNoteMerge.conflictID(entityID: descriptor.id, mutationID: entity.mutation.mutationId, remoteRevision: 3)
        #expect(try library.store.note(id: copyID)?.isLocked == true)
        #expect(try library.store.note(id: copyID)?.text.isEmpty == true)
        let copyOutput = library.paths.root.appendingPathComponent("verified-copy-file")
        try access.decryptAttachment("secret.txt", noteId: copyID, to: copyOutput)
        #expect(try Data(contentsOf: copyOutput) == originalBytes)
        let localOutput = library.paths.root.appendingPathComponent("verified-local-file")
        try access.decryptAttachment("secret.txt", noteId: "note", to: localOutput)
        #expect(try Data(contentsOf: localOutput) == changedBytes)
        #expect(try await library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM privacy_transition") } == 0)
        #expect(try await materializer.apply(entity, noteAccess: access) == .unchanged)
    }

    @Test func revokedAccessDoesNotApplyAnEncryptedConflict() async throws {
        let library = try SyncMaterializerTests.Library(); defer { library.cleanup() }
        let access = try NotePrivacy(store: library.store).setPassword("private password")
        let note = try library.store.create(text: "local")
        try access.lock(noteId: note.id)
        let payload = try #require(try await library.db.pool.read { try SyncNotePayload.capture(id: note.id, includeRetained: true, in: $0) })
        var remote = payload
        remote.encryptedPayload = try NoteCipher.seal(JSONEncoder().encode(LockedNotePayload(text: "remote", attachments: [:])),
            vaultKey: access.journalKey(), context: note.id)
        let entity = try library.entity(remote, id: note.id)
        try library.receive([entity]); access.revoke()
        await #expect(throws: NotePrivacyError.accessRevoked) { try await library.materializer().apply(entity, noteAccess: access) }
        #expect(try library.store.note(id: note.id)?.encryptedPayload == payload.encryptedPayload)
        #expect(try library.inbox.pending().count == 1)
    }
}
