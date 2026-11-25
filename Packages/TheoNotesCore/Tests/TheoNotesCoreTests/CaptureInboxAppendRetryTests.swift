// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct CaptureInboxAppendRetryTests {
    @Test func failedAppendRetriesWithoutDuplicatingPlacedAttachment() throws {
        let library = try PrivacyTestLibrary()
        defer { library.cleanup() }
        let attachments = AttachmentStore(paths: library.paths, database: library.db)
        let target = try library.store.create(text: "Original")
        let source = library.paths.root.appendingPathComponent("photo.png")
        try Data([1, 2, 3]).write(to: source)
        let inbox = CaptureInbox(directory: library.paths.root.appendingPathComponent("CaptureInbox"))
        let request = CaptureRequest(itemId: UUIDv7.make(), mode: .append, targetNoteId: target.id,
            text: "Shared", files: ["photo.png"])
        try inbox.enqueue(request, files: [source])
        try library.db.pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER interrupt_capture_append BEFORE UPDATE OF text ON note
                BEGIN SELECT RAISE(ABORT, 'injected append interruption'); END
                """)
        }
        #expect(try inbox.drain(into: library.store, attachments: attachments).isEmpty)
        #expect(try library.store.note(id: target.id)?.text == "Original")
        let directory = library.paths.attachments.appendingPathComponent(target.id)
        try library.db.pool.write { try $0.execute(sql: "DROP TRIGGER interrupt_capture_append") }
        #expect(try inbox.drain(into: library.store, attachments: attachments) == [target.id])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
        #expect(try library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM attachment WHERE noteId=?", arguments: [target.id]) } == 1)
        #expect(try library.store.note(id: target.id)?.text == "Original\n\nShared\n\n![](photo.png)")
    }

    @Test func appendWaitsForAnExistingStagedBatch() throws {
        let library = try PrivacyTestLibrary()
        defer { library.cleanup() }
        let target = try library.store.create(text: "![](photo.png)")
        let files = AttachmentFiles(paths: library.paths, database: library.db)
        let batch = try files.stage([ImportedAttachment(filename: "photo.png", data: Data([7]))], noteId: target.id)
        try library.db.pool.write { try AttachmentFiles.record(batch, in: $0) }
        let source = library.paths.root.appendingPathComponent("photo.png")
        try Data([8]).write(to: source)
        let inbox = CaptureInbox(directory: library.paths.root.appendingPathComponent("CaptureInbox"))
        try inbox.enqueue(CaptureRequest(itemId: UUIDv7.make(), mode: .append, targetNoteId: target.id,
            text: "", files: ["photo.png"]), files: [source])
        let attachments = AttachmentStore(paths: library.paths, database: library.db)
        #expect(try inbox.drain(into: library.store, attachments: attachments).isEmpty)
        #expect(try library.db.pool.read { try String.fetchOne($0, sql: "SELECT id FROM staging_batch") } == batch.batchID)
        batch.lock?.release()
        _ = try files.recover()
        #expect(try inbox.drain(into: library.store, attachments: attachments) == [target.id])
        #expect(try Data(contentsOf: files.directory(for: target.id).appendingPathComponent("photo.png")) == Data([7]))
        #expect(try Data(contentsOf: files.directory(for: target.id).appendingPathComponent("photo 2.png")) == Data([8]))
    }


    @Test(arguments: ["add", "rename"])
    func normalAttachmentMutationWaitsForCommittedStaging(operation: String) throws {
        let library = try PrivacyTestLibrary()
        defer { library.cleanup() }
        let note = try library.store.create(text: "![](photo.png)")
        let files = AttachmentFiles(paths: library.paths, database: library.db)
        let attachments = AttachmentStore(paths: library.paths, database: library.db)
        _ = try attachments.add(data: Data([8]), filename: "source.png", to: note.id)
        let batch = try files.stage([ImportedAttachment(filename: "photo.png", data: Data([7]))], noteId: note.id)
        defer { batch.lock?.release() }
        try library.db.pool.write { try AttachmentFiles.record(batch, in: $0) }
        #expect(throws: AttachmentFiles.FileError.batchLocked) {
            if operation == "add" { _ = try attachments.add(data: Data([8]), filename: "photo.png", to: note.id) }
            else { _ = try attachments.rename("source.png", to: "photo.png", in: note.id) }
        }
        batch.lock?.release()
        _ = try files.recover()
        let added = operation == "add"
            ? try attachments.add(data: Data([8]), filename: "photo.png", to: note.id)
            : try attachments.rename("source.png", to: "photo.png", in: note.id)
        #expect(added == "photo 2.png")
        #expect(try Data(contentsOf: files.directory(for: note.id).appendingPathComponent(added)) == Data([8]))
        #expect(try Data(contentsOf: files.directory(for: note.id).appendingPathComponent("photo.png")) == Data([7]))
    }

    @Test func failedInstallRecoversAfterReopenAndReceiptPreventsAnotherAppend() throws {
        let library = try PrivacyTestLibrary()
        defer { library.cleanup() }
        let note = try library.store.create(text: "Original")
        let source = library.paths.root.appendingPathComponent("photo.png")
        try Data([7]).write(to: source)
        let request = CaptureRequest(itemId: UUIDv7.make(), mode: .append, targetNoteId: note.id,
            text: "Shared", files: ["photo.png"])
        let inbox = CaptureInbox(directory: library.paths.root.appendingPathComponent("CaptureInbox"))
        try inbox.enqueue(request, files: [source])
        let directory = library.paths.attachments.appendingPathComponent(note.id)
        #expect(try inbox.drain(into: library.store,
            attachments: AttachmentStore(paths: library.paths, database: library.db), now: .now,
            afterNoteWrite: { _ in try Data([9]).write(to: directory) }) == [note.id])
        #expect(try library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM staging_batch") } == 1)
        try library.db.pool.close()
        try FileManager.default.removeItem(at: directory)
        let reopened = try AppDatabase(path: library.paths.database)
        defer { try? reopened.pool.close() }
        _ = try AttachmentFiles(paths: library.paths, database: reopened).recover()
        let store = NoteStore(db: reopened, notifier: nil, paths: library.paths)
        try inbox.enqueue(request, files: [source])
        #expect(try inbox.drain(into: store,
            attachments: AttachmentStore(paths: library.paths, database: reopened)) == [note.id])
        #expect(try store.note(id: note.id)?.text == "Original\n\nShared\n\n![](photo.png)")
        #expect(try Data(contentsOf: directory.appendingPathComponent("photo.png")) == Data([7]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["photo.png"])
        #expect(try reopened.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM capture_receipt") } == 1)
        #expect(try reopened.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM staging_batch") } == 0)
    }
}
