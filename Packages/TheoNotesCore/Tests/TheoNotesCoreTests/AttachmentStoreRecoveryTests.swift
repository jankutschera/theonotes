// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct AttachmentStoreRecoveryTests {
    @Test(arguments: ["add", "rename", "copy", "delete"])
    func unlockedCommittedBatchIsRecoveredBeforeMutation(operation: String) throws {
        let library = try PrivacyTestLibrary()
        defer { library.cleanup() }
        let note = try library.store.create(text: "![](source.png)")
        let attachments = AttachmentStore(paths: library.paths, database: library.db)
        _ = try attachments.add(data: Data([8]), filename: "source.png", to: note.id)
        let files = AttachmentFiles(paths: library.paths, database: library.db)
        let batch = try files.stage([ImportedAttachment(filename: "photo.png", data: Data([7]))], noteId: note.id)
        try library.db.pool.write { try AttachmentFiles.record(batch, in: $0) }
        batch.lock?.release()
        switch operation {
        case "add": #expect(try attachments.add(data: Data([9]), filename: "photo.png", to: note.id) == "photo 2.png")
        case "rename": #expect(try attachments.rename("source.png", to: "photo.png", in: note.id) == "photo 2.png")
        case "copy": #expect(try attachments.copy("source.png", from: note.id, to: note.id) == "source 2.png")
        default: try attachments.delete("source.png", from: note.id)
        }
        #expect(try Data(contentsOf: files.directory(for: note.id).appendingPathComponent("photo.png")) == Data([7]))
        #expect(try library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM staging_batch") } == 0)
    }

    @Test func heldBatchStillPreventsMutationAndSucceedsAfterRelease() throws {
        let library = try PrivacyTestLibrary()
        defer { library.cleanup() }
        let note = try library.store.create(text: "Original")
        let attachments = AttachmentStore(paths: library.paths, database: library.db)
        let files = AttachmentFiles(paths: library.paths, database: library.db)
        let batch = try files.stage([ImportedAttachment(filename: "photo.png", data: Data([7]))], noteId: note.id)
        defer { batch.lock?.release() }
        try library.db.pool.write { try AttachmentFiles.record(batch, in: $0) }
        #expect(throws: AttachmentFiles.FileError.batchLocked) {
            _ = try attachments.add(data: Data([9]), filename: "photo.png", to: note.id)
        }
        batch.lock?.release()
        #expect(try attachments.add(data: Data([9]), filename: "photo.png", to: note.id) == "photo 2.png")
        #expect(try Data(contentsOf: files.directory(for: note.id).appendingPathComponent("photo.png")) == Data([7]))
    }

    @Test func unresolvedInstallReportsFileFailureAndPreservesReservedBytes() throws {
        let library = try PrivacyTestLibrary()
        defer { library.cleanup() }
        let note = try library.store.create(text: "Original")
        let attachments = AttachmentStore(paths: library.paths, database: library.db)
        let files = AttachmentFiles(paths: library.paths, database: library.db)
        let batch = try files.stage([ImportedAttachment(filename: "photo.png", data: Data([7]))], noteId: note.id)
        try library.db.pool.write { try AttachmentFiles.record(batch, in: $0) }
        batch.lock?.release()
        let directory = files.directory(for: note.id)
        try Data([1]).write(to: directory)
        #expect(throws: CocoaError.self) { _ = try attachments.add(data: Data([9]), filename: "photo.png", to: note.id) }
        #expect(try library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM staging_batch") } == 1)
        try FileManager.default.removeItem(at: directory)
        #expect(try attachments.add(data: Data([9]), filename: "photo.png", to: note.id) == "photo 2.png")
        #expect(try Data(contentsOf: directory.appendingPathComponent("photo.png")) == Data([7]))
    }

}
