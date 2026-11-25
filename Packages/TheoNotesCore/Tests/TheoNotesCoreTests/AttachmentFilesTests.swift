// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// The staging rule's recovery contract (M2 ruling R9): newer batches supersede older ones,
/// per-batch flock(2) locks keep recovery away from batches still being written, `write`
/// records its own batch, and recovery leaves foreign entries in `.staging` alone.
@Suite struct AttachmentFilesTests {
    let tmp: TempPaths
    let db: AppDatabase
    let store: NoteStore

    init() throws {
        tmp = try TempPaths()
        db = try AppDatabase.inMemory()
        store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
    }

    private var files: AttachmentFiles { AttachmentFiles(paths: tmp.paths, database: db) }

    private func batchRows() throws -> [String] {
        try db.pool.read { try String.fetchAll($0, sql: "SELECT id FROM staging_batch ORDER BY createdAt") }
    }

    private var stagingEntries: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: files.staging.path)) ?? []).sorted()
    }

    private func data(_ noteId: String, _ name: String) -> Data? {
        try? Data(contentsOf: tmp.paths.attachments.appendingPathComponent(noteId).appendingPathComponent(name))
    }

    private func names(_ noteId: String) -> [String] {
        let dir = tmp.paths.attachments.appendingPathComponent(noteId)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private func file(_ name: String, _ byte: UInt8) -> ImportedAttachment {
        ImportedAttachment(filename: name, data: Data([byte]))
    }

    @Test func testWriteRecordsItsBatchInTheTransaction() throws {
        let note = try store.create(text: "x")
        var rowsInside: [String] = []
        let result = try files.write([file("a.jpg", 1)], noteId: note.id, replacing: false) { db in
            rowsInside = try String.fetchAll(db, sql: "SELECT noteId FROM staging_batch")
            return 42
        }
        #expect(result == 42)
        #expect(rowsInside == [note.id])
        #expect(try batchRows().isEmpty)
        #expect(data(note.id, "a.jpg") == Data([1]))
        #expect(stagingEntries.isEmpty)
    }

    @Test func testANewerBatchSupersedesAnOlderOneOfTheSameNote() throws {
        let note = try store.create(text: "x")
        let other = try store.create(text: "y")
        // Both committed, neither installed (a crash, or a slow first writer).
        var older = try files.stage([file("a.jpg", 1), file("old.jpg", 1)], noteId: note.id)
        older.replacing = true
        try db.pool.write { try AttachmentFiles.record(older, in: $0) }
        let unrelated = try files.stage([file("u.jpg", 5)], noteId: other.id)
        try db.pool.write { try AttachmentFiles.record(unrelated, in: $0) }
        var newer = try files.stage([file("a.jpg", 2), file("b.jpg", 2)], noteId: note.id)
        newer.replacing = true
        try db.pool.write { try AttachmentFiles.record(newer, in: $0) }
        #expect(try Set(batchRows()) == [unrelated.batchID, newer.batchID])

        files.install(newer)
        // The older writer finishing late must not bring back its files.
        files.install(older)
        #expect(names(note.id) == ["a.jpg", "b.jpg"])
        #expect(data(note.id, "a.jpg") == Data([2]))

        // Recovery of the same situation after a crash: only the newest batch is installed.
        var crashOld = try files.stage([file("a.jpg", 3)], noteId: note.id)
        crashOld.replacing = true
        try db.pool.write { try AttachmentFiles.record(crashOld, in: $0) }
        var crashNew = try files.stage([file("a.jpg", 4), file("b.jpg", 4)], noteId: note.id)
        crashNew.replacing = true
        try db.pool.write { try AttachmentFiles.record(crashNew, in: $0) }
        crashOld.lock?.release()
        crashNew.lock?.release()
        unrelated.lock?.release()
        let result = try files.recover()
        #expect(result == AttachmentFiles.Recovery(installed: 2, discarded: 1))
        #expect(names(note.id) == ["a.jpg", "b.jpg"])
        #expect(data(note.id, "a.jpg") == Data([4]))
        #expect(data(other.id, "u.jpg") == Data([5]))
        #expect(try batchRows().isEmpty)
        #expect(stagingEntries.isEmpty)
    }

    @Test func testRecoverySkipsBatchesThatAreStillBeingWritten() throws {
        let note = try store.create(text: "x")
        // Another process (CLI, MCP) staged and committed but has not installed yet.
        let committed = try files.stage([file("a.jpg", 1)], noteId: note.id)
        try db.pool.write { try AttachmentFiles.record(committed, in: $0) }
        // And one that is still staging (no row yet).
        let staging = try files.stage([file("b.jpg", 2)], noteId: note.id)

        let result = try files.recover()
        #expect(result == AttachmentFiles.Recovery(installed: 0, discarded: 0, skipped: 2))
        #expect(stagingEntries.count == 2)
        #expect(names(note.id).isEmpty)

        // The writers finish normally.
        files.install(committed)
        files.discard(staging)
        #expect(names(note.id) == ["a.jpg"])
        #expect(stagingEntries.isEmpty)
        #expect(try batchRows().isEmpty)
    }

    @Test func testALapsedLockIsRecovered() throws {
        let note = try store.create(text: "x")
        var staged: AttachmentFiles.Staged? = try files.stage([file("a.jpg", 1)], noteId: note.id)
        try db.pool.write { try AttachmentFiles.record(staged!, in: $0) }
        #expect(try files.recover().skipped == 1)
        // The writer crashed: its lock goes with its process (here: the last reference).
        staged = nil
        #expect(try files.recover() == AttachmentFiles.Recovery(installed: 1, discarded: 0))
        #expect(data(note.id, "a.jpg") == Data([1]))
    }

    @Test func testRecoveryLeavesEntriesThatAreNotBatches() throws {
        try FileManager.default.createDirectory(at: files.staging.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try Data([1]).write(to: files.staging.appendingPathComponent(".DS_Store"))
        let uncommitted = UUID().uuidString
        try FileManager.default.createDirectory(
            at: files.staging.appendingPathComponent(uncommitted).appendingPathComponent("N1"), withIntermediateDirectories: true)

        #expect(try files.recover() == AttachmentFiles.Recovery(installed: 0, discarded: 1))
        #expect(stagingEntries == [".DS_Store", "notes"])
    }

    @Test func testFailedRenamesAreCountedAndRetried() throws {
        let note = try store.create(text: "x")
        let dir = tmp.paths.attachments.appendingPathComponent(note.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let staged = try files.stage([file("a.jpg", 1), file("b.jpg", 2)], noteId: note.id)
        try db.pool.write { try AttachmentFiles.record(staged, in: $0) }
        staged.lock?.release()

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        #expect(try files.recover() == AttachmentFiles.Recovery(installed: 1, discarded: 0, failedRenames: 2))
        #expect(try batchRows() == [staged.batchID])

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        #expect(try files.recover() == AttachmentFiles.Recovery(installed: 1, discarded: 0))
        #expect(names(note.id) == ["a.jpg", "b.jpg"])
        #expect(try batchRows().isEmpty)
        #expect(stagingEntries.isEmpty)
    }

    @Test func testAnEmptyBatchWritesNoRowAndNoDirectory() throws {
        let note = try store.create(text: "x")
        try db.pool.write { db in
            try db.execute(sql: "CREATE TEMP TRIGGER no_batch_delete BEFORE DELETE ON staging_batch BEGIN SELECT RAISE(ABORT, 'no row'); END")
        }
        var deletes = 0
        let staged = try files.stage([], noteId: note.id)
        #expect(staged.lock == nil)
        try db.pool.write { db in
            try AttachmentFiles.record(staged, in: db)
            deletes = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM staging_batch") ?? -1
        }
        files.install(staged)
        #expect(deletes == 0)
        #expect(stagingEntries.isEmpty)
    }
}
