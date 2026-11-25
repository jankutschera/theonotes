// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct DeletedRecoveryPrivacyPolicyTests {
    @Test func cloudOutgoingVaultDeletionOnlyCountsWhenProvenAndUploadsEnabled() async throws {
        let lib = try SyncMaterializerTests.Library(); defer { lib.cleanup() }
        try await lib.db.pool.write { db in
            try db.execute(sql: "UPDATE sync_control SET enabled=1 WHERE id=1")
            try db.execute(sql: "INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('keyBundle','lock-vault',3,1)")
            try db.execute(sql: """
                INSERT INTO ck_inflight(entityType,entityId,localId,generation,attemptId,inc,sealed,generationOfAccount,preparedAt)
                VALUES('keyBundle','opaque','lock-vault',3,'attempt','inc',X'00',0,CURRENT_TIMESTAMP)
                """)
            #expect(try SyncDeletedRecoveryPolicy.hasNoVaultOrPendingVault(in: db, cloud: true))
            try db.execute(sql: "UPDATE sync_control SET enabled=0 WHERE id=1")
            #expect(try !SyncDeletedRecoveryPolicy.hasNoVaultOrPendingVault(in: db, cloud: true))
            try db.execute(sql: "UPDATE sync_control SET enabled=1 WHERE id=1")
            try db.execute(sql: "UPDATE ck_inflight SET generation=2")
            #expect(try !SyncDeletedRecoveryPolicy.hasNoVaultOrPendingVault(in: db, cloud: true))
            try db.execute(sql: "UPDATE ck_inflight SET generation=3")
            try db.execute(sql: "UPDATE ck_inflight SET generationOfAccount=1")
            #expect(try !SyncDeletedRecoveryPolicy.hasNoVaultOrPendingVault(in: db, cloud: true))
            try db.execute(sql: "UPDATE ck_inflight SET generationOfAccount=0")
            try db.execute(sql: "UPDATE sync_dirty SET tombstone=0")
            #expect(try !SyncDeletedRecoveryPolicy.hasNoVaultOrPendingVault(in: db, cloud: true))
        }
    }
    private actor UnexpectedDownload: SyncBlobTransport {
        private(set) var count = 0
        func ensureUploaded(_ hashes: [String]) async throws {}
        func download(hash: String) async throws -> URL { count += 1; throw SyncProtocolError.invalidPayload }
    }

    @Test func privateAttachmentBeforeParentDoesNotDownloadOrAcknowledge() async throws {
        let lib = try SyncMaterializerTests.Library(); defer { lib.cleanup() }
        let blobs = UnexpectedDownload(), hash = String(repeating: "a", count: 64)
        let payload = SyncAttachmentPayload(id: "asset", noteId: "not-yet-arrived", filename: "file.bin", isLocked: false,
            blobHash: hash, cipherBytes: 100, fileBytes: 3, fileHash: String(repeating: "b", count: 64),
            uti: nil, width: nil, height: nil, ocrText: nil, createdAt: 1, updatedAt: 1)
        let incoming = try lib.entity(payload, type: .attachment, id: payload.id, refs: [hash])
        try lib.receive([incoming])
        let materializer = SyncMaterializer(database: lib.db, paths: lib.paths, accountID: "account", vaultKey: lib.key, blobs: blobs)
        #expect(try await materializer.apply(incoming) == .waitingForDependencies)
        #expect(await blobs.count == 0)
        #expect(try lib.inbox.pending().count == 1 && lib.store.allNotes().isEmpty)
        #expect(try await lib.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM staging_batch") } == 0)
    }

    @Test func protectedDeletedNoteConflictMarksInboxWaitingThenUnlockRetryPreservesBody() async throws {
        let lib = try SyncMaterializerTests.Library(); defer { lib.cleanup() }
        let access = try NotePrivacy(store: lib.store).setPassword("local-vault")
        defer { access.revoke() }
        let first = try lib.entity(lib.payload("# Previously synced plain body"))
        try lib.receive([first]); _ = try await lib.materializer().apply(first)
        try lib.store.trash(["note"]); _ = try lib.store.emptyTrash(ids: ["note"])
        let text = "# Concurrent remote body\nretain exact bytes"
        let incoming = try lib.entity(lib.payload(text), revision: 2, sequence: 2)
        try lib.receive([incoming])
        #expect(try await lib.materializer().apply(incoming) == .waitingForUnlock)
        #expect(try await lib.db.pool.read { try Bool.fetchOne($0, sql: "SELECT waitingForUnlock FROM sync_inbox WHERE sequence=2") } == true)
        #expect(try lib.store.note(id: "note") == nil && lib.store.allNotes().isEmpty)
        #expect(try await lib.materializer().apply(incoming, noteAccess: access) == .applied)
        let copyID = SyncNoteMerge.conflictID(entityID: "note", mutationID: incoming.mutation.mutationId, remoteRevision: 2)
        #expect(try lib.store.note(id: copyID)?.isLocked == true)
        #expect(try access.note(id: copyID)?.text == text)
        #expect(try lib.inbox.pending().isEmpty)
    }

    @Test(arguments: ["none", "local", "remote"]) func privateNoVaultUnknownParentNoteRecoversPlainInsteadOfWaitingForPassword(pendingVault: String) async throws {
        let lib = try SyncMaterializerTests.Library(); defer { lib.cleanup() }
        let first = try lib.entity(lib.payload("# Initially plain"))
        try lib.receive([first]); _ = try await lib.materializer().apply(first)
        try lib.store.trash(["note"]); _ = try lib.store.emptyTrash(ids: ["note"])
        try await lib.db.pool.write { try $0.execute(sql: "DELETE FROM sync_shadow WHERE entityType='note' AND entityId='note'") }
        let remote = lib.payload("# Concurrent remote edit\nexact body")
        let next = try lib.entity(remote, revision: 2, sequence: 2)
        try lib.receive([next])
        if pendingVault == "local" {
            try await lib.db.pool.write { try $0.execute(sql: "INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('keyBundle','lock-vault',1,0)") }
        }
        if pendingVault == "remote" {
            let donor = try SyncMaterializerTests.Library(key: lib.key, enabled: false)
            defer { donor.cleanup() }
            let access = try NotePrivacy(store: donor.store).setPassword("incoming-vault")
            defer { access.revoke() }
            let envelope = try #require(try await donor.db.pool.read { try Data.fetchOne($0, sql: "SELECT envelope FROM crypto_envelope WHERE id=1") })
            let cipher = try NoteCipher.seal(envelope, vaultKey: lib.key,
                context: SyncWire.cipherContext(accountID: "account", type: .keyBundle, entityID: "lock-vault"))
            let pending = SyncEntity(mutation: SyncMutation(mutationId: "incoming-vault", entityType: .keyBundle,
                entityId: "lock-vault", parentRevision: 0, ciphertext: SyncWire.base64(cipher), blobRefs: []), revision: 1, sequence: 3, receivedAt: 3)
            try lib.receive([pending])
            #expect(try await lib.db.pool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM crypto_envelope") == 0
                    && Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_dirty WHERE entityType='keyBundle'") == 0
                    && Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_inbox WHERE entityType='keyBundle'") == 1
            })
            #expect(try await lib.db.pool.read { try SyncDeletedRecoveryPolicy.hasNoVaultOrPendingVault(in: $0, cloud: false) } == false)
        }
        let result = try await lib.materializer().apply(next)
        if pendingVault != "none" {
            #expect(result == .waitingForUnlock)
            #expect(try lib.store.allNotes().isEmpty && !lib.inbox.pending().isEmpty)
            return
        }
        #expect(result == .applied)
        let copyID = SyncNoteMerge.conflictID(entityID: "note", mutationID: next.mutation.mutationId, remoteRevision: 2)
        let copy = try #require(try lib.store.note(id: copyID))
        #expect(!copy.isLocked && copy.text == remote.text)
        #expect(try lib.store.note(id: "note") == nil)
        #expect(try lib.inbox.pending().isEmpty)
        #expect(try await lib.materializer().apply(next) == .unchanged)
        #expect(try lib.store.allNotes().map(\.id) == [copyID])
    }

    @Test(arguments: ["none", "local", "remote"]) func cloudNoVaultUnknownParentNoteRecoversPlainInsteadOfWaitingForPassword(pendingVault: String) async throws {
        try await withBlobWorld(2) { world in
            let a = world.devices[0], b = world.devices[1]
            let ra = BlobRig(a), rb = BlobRig(b)
            a.publishThrough(ra); b.publishThrough(rb)
            let note = try a.noteStore.create(text: "# Initially plain")
            try await a.publish(); try await b.fetchEntities(); _ = try await b.receiver(rb).applyPending()
            try b.noteStore.trash([note.id]); _ = try b.noteStore.emptyTrash(ids: [note.id])
            try await b.db.pool.write { try $0.execute(sql: "DELETE FROM ck_record WHERE entityType='note' AND entityId=?", arguments: [note.id]) }
            let text = "# Concurrent remote edit\nexact body"
            let current = try #require(try a.noteStore.note(id: note.id))
            _ = try a.noteStore.updateText(id: note.id, text: text, expectedRevision: current.revision)
            try await a.publish(); try await b.fetchEntities()
            if pendingVault == "local" {
                try await b.db.pool.write { try $0.execute(sql: "INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('keyBundle','lock-vault',1,0)") }
            }
            if pendingVault == "remote" {
                let incomingAccess = try NotePrivacy(store: a.noteStore).setPassword("incoming-vault")
                defer { incomingAccess.revoke() }
                try await a.publish(); try await b.fetchEntities()
                #expect(try b.int("SELECT COUNT(*) FROM crypto_envelope") == 0)
                #expect(try b.int("SELECT COUNT(*) FROM sync_dirty WHERE entityType='keyBundle'") == 0)
                #expect(try b.store.allRemote().contains { $0.entity.entityType == "keyBundle" })
                #expect(try await b.db.pool.read { try SyncDeletedRecoveryPolicy.hasNoVaultOrPendingVault(in: $0, cloud: true) } == false)
            }
            let receiver = b.receiver(rb)
            let report = try await receiver.applyPending()
            if pendingVault != "none" {
                #expect(report.waitingForUnlock.contains { $0.entityType == "note" && $0.entityId == note.id })
                #expect(try b.noteStore.allNotes().isEmpty && !b.store.allRemote().isEmpty)
                return
            }
            #expect(report.waitingForUnlock.isEmpty && report.waitingForDependency.isEmpty)
            #expect(try b.noteStore.note(id: note.id) == nil)
            let copies = try b.noteStore.allNotes()
            #expect(copies.count == 1)
            let copy = try #require(copies.first)
            #expect(!copy.isLocked && copy.text == text)
            #expect(try b.store.allRemote().isEmpty)
            _ = try await receiver.applyPending()
            #expect(try b.noteStore.allNotes().map(\.id) == [copy.id])
        }
    }
    @Test func cloudOCRMetadataOnlyAfterHardDeleteDoesNotRecoverUneditedBytes() async throws {
        try await withBlobWorld(2) { world in
            let a = world.devices[0], b = world.devices[1]
            let ra = BlobRig(a), rb = BlobRig(b)
            a.publishThrough(ra); b.publishThrough(rb)
            let bytes = Data("unchanged attachment content".utf8)
            let note = try a.noteStore.create(text: "# OCR only\n![](scan.png)")
            _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: bytes, filename: "scan.png", to: note.id)
            let aa = try NotePrivacy(store: a.noteStore).setPassword("fixture-password"); defer { aa.revoke() }
            try await a.publish(); try await b.fetchEntities(); _ = try await b.receiver(rb).applyPending()
            let ab = try NotePrivacy(store: b.noteStore).unlock(password: "fixture-password"); defer { ab.revoke() }
            let fetchesBefore = rb.gateway.assetFetches.count
            let id = try a.attachmentID(of: note.id)
            let initial = try #require(try await a.attachmentPayload(id, in: world.account).payload)
            try b.noteStore.trash([note.id]); _ = try b.noteStore.emptyTrash(ids: [note.id])
            let file = a.installed(noteID: note.id, filename: "scan.png")
            let facts = try #require(OCRFileFacts(url: file))
            try AttachmentTextStore(database: a.db).record(OCRJob(noteId: note.id, filename: "scan.png"),
                result: .text("new OCR metadata", sha256: SyncWire.hash(bytes), byteSize: bytes.count, modifiedAt: facts.modifiedAt), facts: facts)
            try await a.publish()
            let changed = try #require(try await a.attachmentPayload(id, in: world.account).payload)
            #expect(initial.fileHash == changed.fileHash && initial.isLocked == changed.isLocked && changed.ocrText == "new OCR metadata")
            try await b.fetchEntities()
            // Isolate standalone attachment delivery: note versions can eagerly prepare pins
            // before their merge is known. Restore that independent delivery after the ACK.
            let heldNote = try b.store.remote(recordName: "e.note.\(note.id)")
            let noteRecord = try #require(await world.account.record(named: "e.note.\(note.id)"))
            if let heldNote { _ = try b.store.deleteRemote(heldNote, accountGeneration: try b.store.generation()) }
            let receiver = CloudReconciler(database: b.db, paths: b.paths, store: b.store, accountID: b.accountID,
                vaultKey: b.key, pinner: CloudAssetPinner(directory: b.paths.cloudPinned), blobs: rb.transfer, noteAccess: { ab })
            let report = try await receiver.applyPending()
            #expect(report.waitingForDependency.isEmpty && report.waitingForUnlock.isEmpty)
            #expect(try b.noteStore.allNotes().isEmpty)
            #expect(try b.store.remote(recordName: "e.attachment.\(id)") == nil)
            #expect(rb.gateway.assetFetches.count == fetchesBefore, "New fetched record names: \(Array(rb.gateway.assetFetches.dropFirst(fetchesBefore)))")
            if heldNote != nil { _ = try b.sink.intake(noteRecord, delivery: .incremental) }
            let receiverA = CloudReconciler(database: a.db, paths: a.paths, store: a.store, accountID: a.accountID,
                vaultKey: a.key, pinner: CloudAssetPinner(directory: a.paths.cloudPinned), blobs: ra.transfer, noteAccess: { aa })
            for _ in 0..<5 {
                try await b.publish(); try await a.fetchEntities(); _ = try await receiverA.applyPending(); try await a.publish()
                try await b.fetchEntities(); _ = try await receiver.applyPending()
            }
            for device in [a, b] {
                #expect(try device.noteStore.allNotes().isEmpty)
                #expect(try device.store.allRemote().isEmpty && device.store.allInflight().isEmpty && device.dirtyCount() == 0)
            }
        }
    }

    @Test func privateOCRMetadataOnlyAfterHardDeleteDoesNotRecoverUneditedBytes() async throws {
        let key = SymmetricKey(size: .bits256)
        let a = try SyncMaterializerTests.Library(key: key, enabled: false), b = try SyncMaterializerTests.Library(key: key, enabled: false)
        defer { a.cleanup(); b.cleanup() }
        let bytes = Data("unchanged attachment content".utf8)
        let note = try a.store.create(text: "# OCR only\n![](scan.png)")
        _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: bytes, filename: "scan.png", to: note.id)
        let aa = try NotePrivacy(store: a.store).setPassword("fixture-password"); defer { aa.revoke() }
        let server = SyncEngineTests.Server()
        let blobs = SyncPrivacyTransitionTests.SharedBlobs(libraries: [(a.db, a.paths), (b.db, b.paths)])
        let left = SyncEngine(database: a.db, paths: a.paths, accountID: "account", vaultKey: key, transport: server, blobs: blobs)
        let right = SyncEngine(database: b.db, paths: b.paths, accountID: "account", vaultKey: key, transport: server, blobs: blobs)
        try a.queue.enable(accountID: "account"); _ = try await left.synchronize(); _ = try await right.synchronize()
        let ab = try NotePrivacy(store: b.store).unlock(password: "fixture-password"); defer { ab.revoke() }
        try b.queue.enable(accountID: "account"); _ = try await right.synchronize(); _ = try await left.synchronize()
        try b.store.trash([note.id]); _ = try b.store.emptyTrash(ids: [note.id])
        let file = AttachmentFiles(paths: a.paths, database: a.db).directory(for: note.id).appendingPathComponent("scan.png")
        let facts = try #require(OCRFileFacts(url: file))
        try AttachmentTextStore(database: a.db).record(OCRJob(noteId: note.id, filename: "scan.png"),
            result: .text("new OCR metadata", sha256: SyncWire.hash(bytes), byteSize: bytes.count, modifiedAt: facts.modifiedAt), facts: facts)
        _ = try await left.synchronize(noteAccess: aa)
        let summary = try await right.synchronize(noteAccess: ab)
        #expect(summary.pendingDownloads == 0 && summary.deferredConflicts == 0)
        #expect(try b.store.allNotes().isEmpty && b.inbox.pending().isEmpty)
        for _ in 0..<3 { _ = try await right.synchronize(noteAccess: ab); _ = try await left.synchronize(noteAccess: aa) }
        #expect(try b.store.allNotes().isEmpty)
        await left.shutdown(); await right.shutdown()
    }

}
