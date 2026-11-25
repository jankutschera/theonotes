// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct SyncRemoteOCRLoopTests {
    @Test func authenticatedRemoteOCRIsNotOfferedAgainAfterInitialImportOrLaterAdoption() async throws {
        let library = try SyncMaterializerTests.Library(enabled: false); defer { library.cleanup() }
        try await importParent(in: library)
        let bytes = Data("unchanged image bytes".utf8)
        let initial = try attachment(in: library, bytes: bytes, ocr: "Remote recognition", revision: 1)
        try library.receive([initial.entity])
        #expect(try await library.materializer(initial.blobs).apply(initial.entity) == .applied)
        let texts = AttachmentTextStore(database: library.db)
        #expect(try texts.pendingJobs(noteId: "note").isEmpty)
        #expect(try texts.reusableText(sha256: SyncWire.hash(bytes)) == "Remote recognition")
        #expect(try await library.db.pool.read { try Int.fetchOne($0, sql: "SELECT ocrVersion FROM attachment WHERE id='asset'") }
            == -AttachmentTextStore.recognizerVersion)
        #expect(try texts.pendingJobs(limit: 10).isEmpty)
        #expect(try texts.pendingJobs(limit: 10, now: Date().addingTimeInterval(7 * 24 * 60 * 60)).isEmpty)

        let updated = try attachment(in: library, bytes: bytes, ocr: "New remote recognition", revision: 2)
        try library.receive([updated.entity])
        #expect(try await library.materializer(updated.blobs).apply(updated.entity) == .applied)
        #expect(try texts.pendingJobs(limit: 10).isEmpty)
        #expect(try texts.pendingJobs(limit: 10, now: Date().addingTimeInterval(7 * 24 * 60 * 60)).isEmpty)
        #expect(try await library.db.pool.read {
            try String.fetchOne($0, sql: "SELECT ocrText FROM attachment WHERE id='asset'")
        } == "New remote recognition")
        #expect(try await library.materializer(updated.blobs).apply(updated.entity) == .unchanged)
        #expect(try texts.pendingJobs(limit: 10).isEmpty)
    }

    @Test func changedBytesWithoutRemoteOCRStillQueueAndLegitimateRecognizerUpgradeStillRuns() async throws {
        let library = try SyncMaterializerTests.Library(enabled: false); defer { library.cleanup() }
        try await importParent(in: library)
        let initial = try attachment(in: library, bytes: Data("old image".utf8), ocr: "Old recognition", revision: 1)
        try library.receive([initial.entity])
        #expect(try await library.materializer(initial.blobs).apply(initial.entity) == .applied)
        let replacementBytes = Data("new image requiring recognition".utf8)
        let replacement = try attachment(in: library, bytes: replacementBytes, ocr: nil, revision: 2)
        try library.receive([replacement.entity])
        #expect(try await library.materializer(replacement.blobs).apply(replacement.entity) == .applied)
        let texts = AttachmentTextStore(database: library.db)
        let job = OCRJob(noteId: "note", filename: "image.png")
        #expect(try texts.pendingJobs(limit: 10) == [job])
        let url = library.paths.attachments.appendingPathComponent("note/image.png")
        #expect(try Data(contentsOf: url) == replacementBytes)
        try texts.record(job, result: .text("Local legitimate recognition", sha256: SyncWire.hash(replacementBytes),
            byteSize: replacementBytes.count, modifiedAt: .now), recognizerVersion: AttachmentTextStore.recognizerVersion - 1)
        #expect(try texts.pendingJobs(limit: 10).isEmpty)
        #expect(try texts.pendingJobs(limit: 10, now: Date().addingTimeInterval(AttachmentTextStore.failedRetryInterval + 5)) == [job])
        try texts.record(job, result: .text("Upgraded local recognition", sha256: SyncWire.hash(replacementBytes),
            byteSize: replacementBytes.count, modifiedAt: .now))
        #expect(try texts.pendingJobs(limit: 10).isEmpty)
    }

    @Test func importedOCRWithAnOlderUpgradeBaselineCanBeRecognizedAgainWithoutBlankingText() async throws {
        let library = try SyncMaterializerTests.Library(enabled: false); defer { library.cleanup() }
        try await importParent(in: library)
        let bytes = Data("image with imported OCR".utf8)
        let remote = try attachment(in: library, bytes: bytes, ocr: "Retained remote text", revision: 1)
        try library.receive([remote.entity])
        #expect(try await library.materializer(remote.blobs).apply(remote.entity) == .applied)
        // Baseline zero predates the first recognizer, simulating an import followed by an upgrade.
        try await library.db.pool.write {
            try $0.execute(sql: "UPDATE attachment SET ocrVersion=0,ocrAt=? WHERE id='asset'",
                           arguments: [Date().addingTimeInterval(-AttachmentTextStore.failedRetryInterval - 5)])
        }
        let texts = AttachmentTextStore(database: library.db)
        let job = OCRJob(noteId: "note", filename: "image.png")
        #expect(try texts.pendingJobs(limit: 10) == [job])
        #expect(try texts.pendingJobs(noteId: "note") == [job])
        #expect(try texts.reusableText(sha256: SyncWire.hash(bytes)) == nil)
        #expect(try await library.db.pool.read {
            try String.fetchOne($0, sql: "SELECT ocrText FROM attachment WHERE id='asset'")
        } == "Retained remote text")
    }

    @Test(arguments: [false, true])
    func failedRecognizerUpgradeKeepsImportedTextOnlyForTheSameFile(changedBytes: Bool) async throws {
        let library = try SyncMaterializerTests.Library(enabled: false); defer { library.cleanup() }
        try await importParent(in: library)
        let remote = try attachment(in: library, bytes: Data("recognized remote image".utf8), ocr: "Remote words", revision: 1)
        try library.receive([remote.entity])
        #expect(try await library.materializer(remote.blobs).apply(remote.entity) == .applied)
        try await library.db.pool.write {
            try $0.execute(sql: "UPDATE attachment SET ocrVersion=0,ocrAt=? WHERE id='asset'",
                           arguments: [Date().addingTimeInterval(-AttachmentTextStore.failedRetryInterval - 5)])
        }
        let texts = AttachmentTextStore(database: library.db)
        let job = OCRJob(noteId: "note", filename: "image.png")
        #expect(try texts.pendingJobs(limit: 10) == [job])
        let url = library.paths.attachments.appendingPathComponent("note/image.png")
        if changedBytes { try Data("a different image with different size".utf8).write(to: url, options: .atomic) }
        let facts = try #require(OCRFileFacts(url: url))
        try texts.record(job, result: .failed, facts: facts)
        let retained = try await library.db.pool.read {
            try String.fetchOne($0, sql: "SELECT ocrText FROM attachment WHERE id='asset'")
        }
        #expect(retained == (changedBytes ? nil : "Remote words"))
        #expect(try texts.pendingJobs(limit: 10).isEmpty)
        #expect(try texts.pendingJobs(limit: 10, now: Date().addingTimeInterval(AttachmentTextStore.failedRetryInterval + 5)) == [job])
    }

    @Test(arguments: [false, true])
    func noteBundleAdoptsRemoteOCRAndFailedUpgradeChecksInstalledBytes(changedBytes: Bool) async throws {
        let library = try SyncMaterializerTests.Library(enabled: false); defer { library.cleanup() }
        let bytes = Data("note bundle recognized image".utf8)
        let remote = try attachment(in: library, bytes: bytes, ocr: "Bundle words", revision: 1)
        var payload = library.payload("# Image\n![](image.png)", attachments: ["asset"])
        payload.attachmentNames = ["asset": "image.png"]
        let note = try library.entity(payload)
        try library.receive([note, remote.entity])
        // Applying only the note exercises writeNote's downloaded-attachment adoption path.
        #expect(try await library.materializer(remote.blobs).apply(note) == .applied)
        let url = library.paths.attachments.appendingPathComponent("note/image.png")
        #expect(try Data(contentsOf: url) == bytes)
        let texts = AttachmentTextStore(database: library.db)
        #expect(try texts.pendingJobs(limit: 10, now: Date().addingTimeInterval(7 * 24 * 60 * 60)).isEmpty)
        #expect(try texts.reusableText(sha256: SyncWire.hash(bytes)) == "Bundle words")
        let stored = try await library.db.pool.read {
            let row = try #require(try Row.fetchOne($0, sql: "SELECT ocrVersion,fileModifiedAt FROM attachment WHERE id='asset'"))
            return (row["ocrVersion"] as Int, row["fileModifiedAt"] as Date?)
        }
        #expect(stored.0 == -AttachmentTextStore.recognizerVersion)
        let installedAt = try #require(OCRFileFacts(url: url)?.modifiedAt)
        #expect(stored.1 != nil)
        if let adoptedAt = stored.1 { #expect(abs(adoptedAt.timeIntervalSince(installedAt)) < 0.001) }
        try await library.db.pool.write {
            try $0.execute(sql: "UPDATE attachment SET ocrVersion=0,ocrAt=? WHERE id='asset'",
                           arguments: [Date().addingTimeInterval(-AttachmentTextStore.failedRetryInterval - 5)])
        }
        let job = OCRJob(noteId: "note", filename: "image.png")
        #expect(try texts.pendingJobs(limit: 10) == [job])
        if changedBytes { try Data("replacement image with new bytes and size".utf8).write(to: url, options: .atomic) }
        let facts = try #require(OCRFileFacts(url: url))
        try texts.record(job, result: .failed, facts: facts)
        #expect(try await library.db.pool.read {
            try String.fetchOne($0, sql: "SELECT ocrText FROM attachment WHERE id='asset'")
        } == (changedBytes ? nil : "Bundle words"))
    }

    @Test func cancellationDuringFailedAncestorProofDoesNotConsumeRejection() async throws {
        let library = try SyncMaterializerTests.Library(enabled: false); defer { library.cleanup() }
        try await importParent(in: library)
        // Empty files avoid later chunk-loop cancellation checks masking this catch regression.
        let bytes = Data()
        let initial = try attachment(in: library, bytes: bytes, ocr: nil, revision: 1)
        try library.receive([initial.entity])
        #expect(try await library.materializer(initial.blobs).apply(initial.entity) == .applied)
        try library.queue.enable(accountID: "account")
        try await library.db.pool.write {
            try $0.execute(sql: "INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('attachment','asset',2,0)")
        }
        let preparer = SyncAttachmentPreparer(database: library.db, paths: library.paths, accountID: "account", vaultKey: library.key)
        _ = try await preparer.prepare(id: "asset")
        let queued = try #require(try library.queue.prepareNext(vaultKey: library.key))
        #expect(queued.entityType == .attachment)
        // Malformed proof data throws a non-CancellationError after the first cancellation check.
        try await library.db.pool.write {
            try $0.execute(sql: "UPDATE sync_outbox SET wireMutation=? WHERE mutationId=?", arguments: [Data("invalid JSON".utf8), queued.mutationId])
        }
        let remote = try attachment(in: library, bytes: bytes, ocr: "Remote metadata", revision: 2)
        try library.receive([remote.entity])
        let ancestor = try #require(try await library.db.pool.read {
            try Data.fetchOne($0, sql: "SELECT wireEntity FROM sync_shadow WHERE entityType='attachment' AND entityId='asset'")
        })
        let reached = LibraryBackupTests.Reached()
        try await library.db.pool.write { db in
            db.trace { event in
                if "\(event)".contains("SELECT a.*,n.isLocked,d.generation,o.wireMutation") {
                    reached.set()
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        let materializer = library.materializer(remote.blobs)
        guard case .attachment(let descriptor) = try await SyncPayloadReader(accountID: "account", vaultKey: library.key, blobs: remote.blobs).read(remote.entity) else {
            Issue.record("Expected remote descriptor"); return
        }
        let cipher = try await materializer.preparedAttachmentCipher(descriptor)
        let task = Task.detached {
            try materializer.commitAttachment(remote.entity,
                download: .init(entity: remote.entity, payload: descriptor, cipher: cipher),
                ancestor: ancestor, rejectedMutationID: queued.mutationId, noteAccess: nil)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(reached.isSet)
        #expect(task.isCancelled)
        try await library.db.pool.write { $0.trace(nil) }
        #expect(try Data(contentsOf: library.paths.attachments.appendingPathComponent("note/image.png")) == bytes)
        #expect(try await library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note") } == 1)
        #expect(try await library.db.pool.read { try String.fetchAll($0, sql: "SELECT mutationId FROM sync_outbox") } == [queued.mutationId])
        #expect(try library.inbox.pending().map(\.sequence) == [remote.entity.sequence])
        #expect(try await library.db.pool.read {
            try Int64.fetchOne($0, sql: "SELECT serverRevision FROM sync_shadow WHERE entityType='attachment' AND entityId='asset'")
        } == initial.entity.revision)
    }

    private func importParent(in library: SyncMaterializerTests.Library) async throws {
        var payload = library.payload("# Image\n![](image.png)", attachments: ["asset"])
        payload.attachmentNames = ["asset": "image.png"]
        let entity = try library.entity(payload)
        try library.receive([entity])
        #expect(try await library.materializer().apply(entity) == .applied)
    }

    private func attachment(in library: SyncMaterializerTests.Library, bytes: Data, ocr: String?, revision: Int64) throws
        -> (entity: SyncEntity, blobs: SyncPayloadReaderTests.Blobs) {
        let cipher = library.paths.root.appendingPathComponent("remote-\(revision).bch")
        try ChunkedCipher.encrypt(data: bytes, output: cipher, keyEncryptionKey: library.key,
            context: SyncWire.cipherContext(accountID: "account", type: .attachment, entityID: "asset"))
        let facts = try SyncAttachmentPreparer.hashFile(cipher)
        let payload = SyncAttachmentPayload(id: "asset", noteId: "note", filename: "image.png", isLocked: false,
            blobHash: facts.hash, cipherBytes: facts.size, fileBytes: Int64(bytes.count), fileHash: SyncWire.hash(bytes),
            uti: "public.png", width: 10, height: 20, ocrText: ocr, createdAt: 1, updatedAt: revision)
        return (try library.entity(payload, type: .attachment, id: "asset", revision: revision,
                    sequence: revision + 1, refs: [facts.hash]), .init(files: [facts.hash: cipher]))
    }
}
