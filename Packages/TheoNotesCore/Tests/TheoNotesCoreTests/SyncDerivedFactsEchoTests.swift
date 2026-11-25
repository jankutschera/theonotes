// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

struct SyncDerivedFactsEchoTests {
    @Test func identicalRemoteAttachmentAndOCRFactsDoNotCreateAnotherUpload() async throws {
        let source = try SyncMaterializerTests.Library(enabled: false)
        let target = try SyncMaterializerTests.Library(key: source.key)
        defer { source.cleanup(); target.cleanup() }
        let bytes = Data("unchanged attachment fixture".utf8)
        let note = try source.store.create(text: "# Fixture\n" + AttachmentMarkdown.link(for: "fixture.txt"))
        _ = try AttachmentStore(paths: source.paths, database: source.db)
            .add(data: bytes, filename: "fixture.txt", to: note.id)
        let text = "Already synchronized recognized text"
        let job = OCRJob(noteId: note.id, filename: "fixture.txt")
        let fileHash = SyncWire.hash(bytes)
        try AttachmentTextStore(database: source.db).record(job,
            result: .text(text, sha256: fileHash, byteSize: bytes.count, modifiedAt: Date(timeIntervalSince1970: 10)))
        try source.queue.enable(accountID: "account")
        let sourcePreparer = SyncAttachmentPreparer(database: source.db, paths: source.paths,
            accountID: "account", vaultKey: source.key)
        try #require(try await sourcePreparer.preparePending() == 1)
        var entities: [SyncEntity] = []
        while let mutation = try source.queue.prepareNext(vaultKey: source.key) {
            let entity = SyncEntity(mutation: mutation, revision: 1, sequence: Int64(entities.count + 1), receivedAt: 1)
            entities.append(entity)
            try source.queue.accept(entity)
        }
        let attachment = try #require(entities.first { $0.mutation.entityType == .attachment })
        let context = try SyncWire.cipherContext(accountID: "account", type: .attachment, entityID: attachment.mutation.entityId)
        let original = try SyncPayloadCodec.decode(SyncAttachmentPayload.self, from: NoteCipher.open(
            SyncWire.decode64(#require(attachment.mutation.ciphertext)), vaultKey: source.key, context: context))
        let pointer = try #require(try await source.db.pool.read {
            try String.fetchOne($0, sql: "SELECT localPath FROM sync_blob_state WHERE hash=?", arguments: [original.blobHash])
        })
        let cipher = source.paths.root.appendingPathComponent(try SyncBlobLocation.relative(pointer))
        let apply = target.materializer(.init(files: [original.blobHash: cipher]))
        try target.receive(entities)
        for entity in entities where entity.mutation.entityType == .note { _ = try await apply.apply(entity) }
        for entity in entities where entity.mutation.entityType != .note { _ = try await apply.apply(entity) }
        #expect(try target.queue.pendingCount() == 0)

        let preparer = SyncAttachmentPreparer(database: target.db, paths: target.paths,
            accountID: "account", vaultKey: source.key)
        for round in 0..<2 {
            if round > 0 {
                // Another device republishes the same attachment semantics. There is
                // deliberately no new text, file, or recognition result on either side.
                let next = try target.entity(original, type: .attachment, id: original.id,
                    revision: 3, sequence: 100, refs: [original.blobHash])
                try target.receive([next])
                #expect(try await apply.apply(next) == .applied)
            }
            let local = target.paths.attachments.appendingPathComponent(note.id + "/fixture.txt")
            #expect(try Data(contentsOf: local) == bytes)
            let before = try await target.db.pool.read { db -> (String?, String?, Int?) in
                let row = try #require(try Row.fetchOne(db, sql: "SELECT ocrText,sha256,byteSize FROM attachment WHERE id=?", arguments: [original.id]))
                return (row["ocrText"], row["sha256"], row["byteSize"])
            }
            #expect(before.0 == text)
            #expect(before.1 == fileHash)
            #expect(before.2 == bytes.count)
            // Real OCR persistence, not a hand-written UPDATE or synthetic dirty mark.
            try AttachmentTextStore(database: target.db).record(job,
                result: .text(text, sha256: fileHash, byteSize: bytes.count,
                              modifiedAt: Date(timeIntervalSince1970: 10)))
            #expect(try target.queue.pendingCount() == 0,
                "Identical OCR text and derived file facts must not echo a received attachment")

            // Drain any reproduced echo to prove the same condition recurs on the
            // next clean incoming version; retain checks on portable descriptor fields.
            _ = try await preparer.preparePending()
            var sequence: Int64 = 200
            while let mutation = try target.queue.prepareNext(vaultKey: source.key) {
                if mutation.entityType == .attachment {
                    let echoed = try SyncPayloadCodec.decode(SyncAttachmentPayload.self, from: NoteCipher.open(
                        SyncWire.decode64(#require(mutation.ciphertext)), vaultKey: source.key, context: context))
                    #expect(echoed.fileHash == original.fileHash && echoed.fileBytes == original.fileBytes)
                    #expect(echoed.ocrText == original.ocrText)
                    #expect(echoed.blobHash != original.blobHash)
                }
                sequence += 1
                try target.queue.accept(SyncEntity(mutation: mutation, revision: mutation.parentRevision + 1,
                    sequence: sequence, receivedAt: sequence))
            }
            #expect(try target.queue.pendingCount() == 0)
        }

        // Positive control: an actual external byte replacement must still be captured,
        // even when recognized text has not changed.
        let changedBytes = Data("genuinely replaced file contents".utf8)
        let local = target.paths.attachments.appendingPathComponent(note.id + "/fixture.txt")
        try changedBytes.write(to: local)
        try AttachmentTextStore(database: target.db).record(job,
            result: .text(text, sha256: SyncWire.hash(changedBytes), byteSize: changedBytes.count,
                          modifiedAt: Date(timeIntervalSince1970: 20)))
        #expect(try target.queue.pendingCount() == 1)
        _ = try await preparer.preparePending()
        var sequence: Int64 = 300
        while let mutation = try target.queue.prepareNext(vaultKey: source.key) {
            sequence += 1
            try target.queue.accept(SyncEntity(mutation: mutation, revision: mutation.parentRevision + 1,
                sequence: sequence, receivedAt: sequence))
        }
        #expect(try target.queue.pendingCount() == 0)
        // Independent positive control: genuine recognition text changes remain portable.
        try AttachmentTextStore(database: target.db).record(job,
            result: .text("New recognized text", sha256: SyncWire.hash(changedBytes), byteSize: changedBytes.count,
                          modifiedAt: Date(timeIntervalSince1970: 20)))
        #expect(try target.queue.pendingCount() == 1)
    }
}
