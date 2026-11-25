// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct AttachmentBatchTests {
    @Test func failedInstallThrowsAndKeepsCommittedBatchForRecovery() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "Original")
        let directory = library.paths.attachments.appendingPathComponent(note.id)
        try FileManager.default.createDirectory(at: library.paths.attachments, withIntermediateDirectories: true)
        try library.db.pool.write { db in
            db.trace { event in
                if event.description.contains("INSERT INTO staging_batch") { try? Data([0]).write(to: directory) }
            }
        }
        let attachments = AttachmentStore(paths: library.paths, database: library.db)
        #expect(throws: CocoaError.self) {
            _ = try attachments.addBatch([ImportedAttachment(filename: "photo.png", data: Data([7]))], to: note.id)
        }
        #expect(try library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM staging_batch WHERE noteId=?", arguments: [note.id]) } == 1)
        try library.db.pool.write { $0.trace(nil) }
        try FileManager.default.removeItem(at: directory)
        let files = AttachmentFiles(paths: library.paths, database: library.db)
        _ = try files.recover()
        #expect(try Data(contentsOf: directory.appendingPathComponent("photo.png")) == Data([7]))
        #expect(try attachments.addBatch([ImportedAttachment(filename: "photo.png", data: Data([9]))], to: note.id) == ["photo 2.png"])
        #expect(try Data(contentsOf: directory.appendingPathComponent("photo.png")) == Data([7]))
    }

    @Test(arguments: [false, true])
    func batchPreservesCollisionOrderAndRollsBackOnCommitFailure(locked: Bool) throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "Original")
        let access = try NotePrivacy(store: library.store).setPassword("fixture-password")
        defer { access.revoke() }
        if locked { try access.lock(noteId: note.id) }
        let plain = AttachmentStore(paths: library.paths, database: library.db)
        let items = [ImportedAttachment(filename: "photo.png", data: Data([1])), ImportedAttachment(filename: "photo.png", data: Data([2]))]
        try library.db.pool.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_media BEFORE INSERT ON staging_batch BEGIN SELECT RAISE(ABORT, 'batch commit failed'); END")
        }
        #expect(throws: DatabaseError.self) {
            if locked { _ = try access.addAttachments(items, to: note.id) }
            else { _ = try plain.addBatch(items, to: note.id) }
        }
        let directory = library.paths.attachments.appendingPathComponent(note.id)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).isEmpty)
        #expect(try library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM staging_batch") } == 0)
        try library.db.pool.write { try $0.execute(sql: "DROP TRIGGER reject_media") }
        let names = locked ? try access.addAttachments(items, to: note.id) : try plain.addBatch(items, to: note.id)
        #expect(names == ["photo.png", "photo 2.png"])
        for (name, expected) in zip(names, [Data([1]), Data([2])]) {
            if locked { #expect(try access.attachmentData(name, noteId: note.id, maximumBytes: 10) == expected) }
            else { #expect(try Data(contentsOf: #require(plain.url(for: name, noteId: note.id))) == expected) }
        }
        if locked {
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { $0.hasSuffix(".bch") })
            #expect(try library.store.note(id: note.id)?.text == "")
        }
    }
}
