// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct SyncAttachmentAncestorConflictTests {
    @Test(arguments: [false, true])
    func rejectedJoinCopyDoesNotOverwriteNewerMacBytes(newerPhoneEdit: Bool) async throws {
        try await exerciseConflict(newerPhoneEdit: newerPhoneEdit)
    }

    @Test(arguments: ["unknown-json", "missing-ancestor", "changed-source", "invalid-proof-auth"])
    func incompleteEqualityProofPreservesBothVersions(failure: String) async throws {
        try await exerciseConflict(newerPhoneEdit: false, proofFailure: failure)
    }

    @Test(arguments: [false, true])
    func derivedJoinMetadataDoesNotOverwriteRemoteOrLoseAuthoredBytes(newerPhoneEdit: Bool) async throws {
        try await exerciseConflict(newerPhoneEdit: newerPhoneEdit, derivedMetadata: true)
    }

    private func exerciseConflict(newerPhoneEdit: Bool, proofFailure: String? = nil,
                                  derivedMetadata: Bool = false) async throws {
        let key = SymmetricKey(size: .bits256)
        let mac = try SyncMaterializerTests.Library(key: key)
        let phone = try SyncMaterializerTests.Library(key: key)
        defer { mac.cleanup(); phone.cleanup() }
        let fixtures = SyncInitialCaptureRegressionTests()
        let blobs = SyncInitialCaptureRegressionTests.BlobStore(directory: mac.paths.root.appendingPathComponent("shared-blobs"))
        let server = SyncEngineTests.Server()
        let macEngine = fixtures.engine(mac, server: server, blobs: blobs)
        let phoneEngine = fixtures.engine(phone, server: server, blobs: blobs)
        let note = try mac.store.create(text: "# File\n" + AttachmentMarkdown.link(for: "file.txt"))
        _ = try AttachmentStore(paths: mac.paths, database: mac.db).add(data: Data("revision 1".utf8), filename: "file.txt", to: note.id)
        _ = try await macEngine.synchronize()
        let attachmentID = try #require(try await mac.db.pool.read {
            try String.fetchOne($0, sql: "SELECT id FROM attachment WHERE noteId=?", arguments: [note.id])
        })
        // Build real accepted history, so the conflict proves this exact mutation was never accepted.
        for revision in 2...11 {
            try replace(Data("revision \(revision)".utf8), in: mac, noteID: note.id)
            _ = try await macEngine.synchronize()
        }
        _ = try await phoneEngine.synchronize()
        let ancestor = try #require(await server.entities["attachment:" + attachmentID])
        #expect(ancestor.revision == 11)
        let phoneBlobs = SyncInitialCaptureRegressionTests.Blobs(database: phone.db, paths: phone.paths, remote: blobs)
        let reader = SyncPayloadReader(accountID: "account", vaultKey: key, blobs: phoneBlobs)
        guard case .attachment(let base) = try await reader.read(ancestor) else {
            Issue.record("Expected authenticated attachment ancestor"); return
        }
        // Reproduce a join-time generation; derived metadata can differ without a file edit.
        try await phone.db.pool.write {
            if derivedMetadata {
                try $0.execute(sql: "UPDATE sync_control SET applying=1 WHERE id=1")
                try setDerivedMetadata(100, attachmentID: attachmentID, in: $0)
                try $0.execute(sql: "UPDATE sync_control SET applying=0 WHERE id=1")
            }
            try $0.execute(sql: "INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('attachment',?,2,0)", arguments: [attachmentID])
        }
        let preparer = SyncAttachmentPreparer(database: phone.db, paths: phone.paths, accountID: "account", vaultKey: key)
        _ = try await preparer.preparePending()
        var queued: SyncMutation
        if proofFailure == "unknown-json" {
            let prepared = try phone.queue.prepareNext(vaultKey: key) { db, dirty in
                let content = try SyncAttachmentPreparer.capture(dirty, accountID: "account", vaultKey: key, in: db)
                let bytes = try #require(content.payload)
                var object = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                object["futurePortableMetadata"] = "preserve conservatively"
                return SyncContent(payload: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), blobRefs: content.blobRefs)
            }
            queued = try #require(prepared)
        } else {
            queued = try #require(try phone.queue.prepareNext(vaultKey: key))
        }
        #expect(queued.entityType == .attachment && queued.entityId == attachmentID)
        #expect(queued.parentRevision == 11)
        let queuedEntity = SyncEntity(mutation: queued, revision: 12, sequence: ancestor.sequence + 1, receivedAt: 1)
        guard case .attachment(let captured) = try await reader.read(queuedEntity) else {
            Issue.record("Expected queued attachment payload"); return
        }
        let semanticBase = SyncAttachmentPayload(id: base.id, noteId: base.noteId,
            filename: base.filename, isLocked: base.isLocked, blobHash: captured.blobHash,
            cipherBytes: captured.cipherBytes, fileBytes: base.fileBytes, fileHash: base.fileHash,
            uti: base.uti, width: base.width, height: base.height, ocrText: base.ocrText,
            createdAt: base.createdAt, updatedAt: base.updatedAt)
        #expect(captured.version == base.version)
        if derivedMetadata {
            #expect(captured.fileHash == base.fileHash && captured.fileBytes == base.fileBytes)
            #expect(captured.id == base.id && captured.noteId == base.noteId && captured.filename == base.filename)
            #expect(captured.isLocked == base.isLocked && captured.createdAt == base.createdAt)
            #expect(captured.ocrText != base.ocrText && captured.updatedAt != base.updatedAt)
            #expect(captured.uti != base.uti && captured.width != base.width && captured.height != base.height)
        } else { #expect(captured == semanticBase) }
        if proofFailure == "invalid-proof-auth" {
            var invalid = try SyncWire.decode64(#require(queued.ciphertext))
            invalid[invalid.count - 1] ^= 1
            queued.ciphertext = SyncWire.base64(invalid)
            let wire = try JSONEncoder().encode(queued), mutationID = queued.mutationId
            try await phone.db.pool.write {
                try $0.execute(sql: "UPDATE sync_outbox SET wireMutation=? WHERE mutationId=?", arguments: [wire, mutationID])
            }
        }
        let macBytes = derivedMetadata ? Data("revision 11".utf8) : Data("Mac authored revision 12".utf8)
        if derivedMetadata {
            try await mac.db.pool.write {
                try setDerivedMetadata(200, attachmentID: attachmentID, in: $0)
                // Avoid reusing an older generation-1 cache while seeding the remote descriptor.
                try $0.execute(sql: "UPDATE sync_dirty SET generation=3 WHERE entityType='attachment' AND localId=?", arguments: [attachmentID])
            }
        } else { try replace(macBytes, in: mac, noteID: note.id) }
        _ = try await macEngine.synchronize()
        let remote = try #require(await server.entities["attachment:" + attachmentID])
        #expect(remote.revision == 12)
        if derivedMetadata {
            guard case .attachment(let remoteDescriptor) = try await reader.read(remote) else {
                Issue.record("Expected authenticated remote metadata"); return
            }
            #expect(remoteDescriptor.ocrText == "derived 200")
            #expect(remoteDescriptor.fileHash == base.fileHash && remoteDescriptor.fileBytes == base.fileBytes)
            #expect(remoteDescriptor.updatedAt != captured.updatedAt && remoteDescriptor.uti != captured.uti)
            #expect(remoteDescriptor.width != captured.width && remoteDescriptor.height != captured.height)
        }
        let phoneBytes = Data("Phone authored after queued generation 2".utf8)
        if newerPhoneEdit {
            try replace(phoneBytes, in: phone, noteID: note.id)
            let generation = try #require(try await phone.db.pool.read {
                try Int64.fetchOne($0, sql: "SELECT generation FROM sync_dirty WHERE entityType='attachment' AND localId=?", arguments: [attachmentID])
            })
            #expect(generation > 2)
        }
        if proofFailure == "missing-ancestor" {
            try await phone.db.pool.write {
                try $0.execute(sql: "DELETE FROM sync_shadow WHERE entityType='attachment' AND entityId=?", arguments: [attachmentID])
            }
        }
        if proofFailure == "changed-source" {
            // An out-of-band source replacement must also invalidate the staged equality proof.
            try phoneBytes.write(to: phone.paths.attachments.appendingPathComponent(note.id + "/file.txt"), options: [.atomic])
            #expect(try await phone.db.pool.read {
                try Int64.fetchOne($0, sql: "SELECT generation FROM sync_dirty WHERE entityType='attachment' AND localId=?", arguments: [attachmentID])
            } == 2)
        }
        let authoredNote = try phone.store.create(text: "Independent phone user edit")
        let rejection = try #require(try await server.push([queued]).results.first)
        #expect(rejection.status == .conflict && rejection.current == remote)
        #expect(await server.receipts[queued.mutationId] == nil)
        for _ in 0..<4 {
            _ = try await phoneEngine.synchronize()
            _ = try await macEngine.synchronize()
        }
        let macFiles = try attachmentBytes(in: mac)
        let phoneFiles = try attachmentBytes(in: phone)
        #expect(macFiles == phoneFiles)
        #expect(macFiles.contains(macBytes))
        #expect(try mac.store.note(id: authoredNote.id)?.text == "Independent phone user edit")
        #expect(try phone.store.note(id: authoredNote.id)?.text == "Independent phone user edit")
        if newerPhoneEdit || proofFailure != nil {
            let retainedLocal = newerPhoneEdit || proofFailure == "changed-source" ? phoneBytes : Data("revision 11".utf8)
            #expect(macFiles.contains(retainedLocal))
            #expect(macFiles.count == 2)
        } else {
            // The join copy is not an authored edit: revision 12 must remain the original file.
            for library in [mac, phone] {
                #expect(try Data(contentsOf: library.paths.attachments.appendingPathComponent(note.id + "/file.txt")) == macBytes)
            }
            #expect(macFiles == [macBytes])
            let finalRemote = try #require(await server.entities["attachment:" + attachmentID])
            #expect(finalRemote.revision == 12)
            if derivedMetadata {
                #expect(finalRemote == remote)
                for library in [mac, phone] {
                    let ocr = try await library.db.pool.read {
                        try String.fetchOne($0, sql: "SELECT ocrText FROM attachment WHERE id=?", arguments: [attachmentID])
                    }
                    #expect(ocr == "derived 200")
                }
            }
        }
        #expect(try phone.queue.pendingMutations().isEmpty)
        await phoneEngine.shutdown()
        await macEngine.shutdown()
    }

    private func setDerivedMetadata(_ value: Int, attachmentID: String, in db: Database) throws {
        try db.execute(sql: """
            UPDATE attachment SET ocrText=?,updatedAt=?,uti=?,width=?,height=? WHERE id=?
            """, arguments: ["derived \(value)", Date(timeIntervalSince1970: Double(value)),
                              "public.derived-\(value)", value, value + 1, attachmentID])
    }

    private func replace(_ bytes: Data, in library: SyncMaterializerTests.Library, noteID: String) throws {
        try AttachmentFiles(paths: library.paths, database: library.db).write(
            [ImportedAttachment(filename: "file.txt", data: bytes)], noteId: noteID, replacing: true) { _ in }
    }

    private func attachmentBytes(in library: SyncMaterializerTests.Library) throws -> Set<Data> {
        let files = try library.db.pool.read { try Row.fetchAll($0, sql: "SELECT noteId,filename FROM attachment WHERE deletedAt IS NULL") }
        return try Set(files.map { row in
            let noteID: String = row["noteId"], filename: String = row["filename"]
            return try Data(contentsOf: library.paths.attachments.appendingPathComponent(noteID + "/" + filename))
        })
    }
}
