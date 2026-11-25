// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

@Suite struct CloudRemoteOCRAdoptionTests {
    @Test(arguments: [false, true])
    func failedOCRAdoptionWaitsAndRollsBackBeforeRetry(noteBundle: Bool) async throws {
        let world = try await PublisherWorld.make(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let note = try a.noteStore.create(text: "# Image\n![](image.png)\n")
        let original = Data("original image".utf8)
        _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: original, filename: "image.png", to: note.id)
        try a.publishAttachments(of: note.id)
        try await a.sync(); try b.copyBlobs(from: a); try await b.sync()
        let before = try b.text(note.id)
        let bytes = Data("updated remote image".utf8)
        try bytes.write(to: a.attachmentFile(note.id, "image.png"))
        try AttachmentTextStore(database: a.db).record(OCRJob(noteId: note.id, filename: "image.png"),
            result: .text("Remote words", sha256: SyncWire.hash(bytes), byteSize: bytes.count, modifiedAt: .now))
        try a.publishAttachments(of: note.id)
        if noteBundle { try a.edit(note.id, "# Changed image\n![](image.png)\n") }
        try await a.sync(); try b.copyBlobs(from: a)
        let attachmentName = try #require(await recordName(world, prefix: "e.attachment."))
        _ = try b.sink.intake(#require(await world.account.record(named: attachmentName)), delivery: .incremental)
        if noteBundle {
            _ = try b.sink.intake(#require(await world.account.record(named: "e.note.\(note.id)")), delivery: .incremental)
        }
        // Force the adoption guard to fail after staging and metadata writes in the real transaction.
        try b.sql("CREATE TRIGGER reject_ocr_adoption BEFORE UPDATE OF ocrVersion ON attachment BEGIN SELECT RAISE(IGNORE); END")
        let waiting = try await b.reconciler.applyPending()
        #expect(!waiting.waitingForDependency.isEmpty)
        #expect(waiting.applied.isEmpty)
        #expect(try b.text(note.id) == before)
        #expect(try Data(contentsOf: b.attachmentFile(note.id, "image.png")) == original)
        #expect(try b.rowCount("ck_remote") > 0)
        #expect(try b.rowCount("staging_batch") == 0)
        #expect(try b.string("SELECT ocrText FROM attachment WHERE noteId=?", [note.id]) == nil)
        try b.sql("DROP TRIGGER reject_ocr_adoption")
        #expect(try await b.applyNotes() > 0)
        #expect(try Data(contentsOf: b.attachmentFile(note.id, "image.png")) == bytes)
        #expect(try b.string("SELECT ocrText FROM attachment WHERE noteId=?", [note.id]) == "Remote words")
    }

    @Test(arguments: [false, true])
    func standaloneAttachmentAdoptsRemoteOCRAndPreservesItOnlyForUnchangedBytes(changedBytes: Bool) async throws {
        let world = try await PublisherWorld.make(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let note = try a.noteStore.create(text: "# Image\n")
        _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: Data("remote image".utf8), filename: "image.png", to: note.id)
        try a.edit(note.id, "# Image\n![](image.png)\n")
        try a.publishAttachments(of: note.id)
        try await a.sync(); try b.copyBlobs(from: a); try await b.sync()
        #expect(try AttachmentTextStore(database: b.db).pendingJobs(noteId: note.id) == [OCRJob(noteId: note.id, filename: "image.png")])
        #expect(try b.string("SELECT ocrText FROM attachment WHERE noteId=?", [note.id]) == nil)
        // Only the attachment changes, exercising CloudApplier's standalone adoption path.
        let bytes = Data("updated remote image".utf8)
        try bytes.write(to: a.attachmentFile(note.id, "image.png"))
        try AttachmentTextStore(database: a.db).record(OCRJob(noteId: note.id, filename: "image.png"),
            result: .text("Remote words", sha256: SyncWire.hash(bytes), byteSize: bytes.count, modifiedAt: .now))
        try a.publishAttachments(of: note.id)
        try await a.sync(); try b.copyBlobs(from: a)
        let attachmentName = try #require(await recordName(world, prefix: "e.attachment."))
        let record = try #require(await world.account.record(named: attachmentName))
        _ = try b.sink.intake(record, delivery: .incremental)
        #expect(try await b.applyNotes() == 1)

        let texts = AttachmentTextStore(database: b.db)
        #expect(try b.int("SELECT ocrVersion FROM attachment WHERE noteId=?", [note.id]) == -AttachmentTextStore.recognizerVersion)
        #expect(try b.int("SELECT COUNT(*) FROM attachment WHERE noteId=? AND fileModifiedAt IS NOT NULL AND ocrAt IS NOT NULL", [note.id]) == 1)
        #expect(try texts.pendingJobs(noteId: note.id).isEmpty)
        #expect(try texts.pendingJobs(limit: 10, now: Date().addingTimeInterval(7 * 24 * 60 * 60)).isEmpty)
        #expect(try texts.reusableText(sha256: SyncWire.hash(bytes)) == "Remote words")
        try b.sql("UPDATE attachment SET ocrVersion=0,ocrAt=? WHERE noteId=?", [Date().addingTimeInterval(-AttachmentTextStore.failedRetryInterval - 5), note.id])
        let url = b.attachmentFile(note.id, "image.png")
        if changedBytes { try Data("different image of different size".utf8).write(to: url, options: .atomic) }
        let facts = try #require(OCRFileFacts(url: url))
        try texts.record(OCRJob(noteId: note.id, filename: "image.png"), result: .failed, facts: facts)
        #expect(try b.string("SELECT ocrText FROM attachment WHERE noteId=?", [note.id]) == (changedBytes ? nil : "Remote words"))
    }
}
