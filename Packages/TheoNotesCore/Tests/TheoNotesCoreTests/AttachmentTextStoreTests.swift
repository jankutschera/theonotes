// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import GRDB
@testable import TheoNotesCore

@Suite struct AttachmentTextStoreTests {
    let tmp: TempPaths
    let db: AppDatabase
    let store: NoteStore
    let texts: AttachmentTextStore

    init() throws {
        tmp = try TempPaths()
        db = try AppDatabase.inMemory()
        store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
        texts = AttachmentTextStore(database: db)
    }

    struct Entry: Equatable {
        var filename: String
        var state: String
        var text: String?
    }

    private func entries(_ noteId: String) throws -> [Entry] {
        try db.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT filename, ocrState, ocrText FROM attachment
                WHERE noteId = ? AND deletedAt IS NULL ORDER BY filename
                """, arguments: [noteId])
                .map { Entry(filename: $0["filename"], state: $0["ocrState"], text: $0["ocrText"]) }
        }
    }

    private func ocrColumn(_ noteId: String) throws -> String? {
        try db.pool.read {
            try String.fetchOne($0, sql: "SELECT ocrText FROM note_search_content WHERE noteId = ?", arguments: [noteId])
        }
    }

    private func edit(_ note: Note, to text: String) throws {
        let current = try #require(try store.note(id: note.id))
        _ = try store.updateText(id: note.id, text: text, expectedRevision: current.revision)
    }

    private func lock(_ noteId: String) throws {
        try db.pool.write { db in
            try db.execute(sql: "UPDATE note SET isLocked = 1, text = '' WHERE id = ?", arguments: [noteId])
            try NoteIndexer.index(noteId: noteId, text: "", in: db)
        }
    }

    private func found(_ text: String, sha: String = "sha") -> OCRResult {
        .text(text, sha256: sha, byteSize: 10, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func testIndexingCreatesPendingRowsAndRemovesDroppedOnes() throws {
        let note = try store.create(text: "# T\n![](a.png)\n[b.pdf](b.pdf)<!-- {\"embed\":\"true\"} -->")
        #expect(try entries(note.id) == [
            Entry(filename: "a.png", state: "pending", text: nil), Entry(filename: "b.pdf", state: "pending", text: nil),
        ])
        let ids = try db.pool.read {
            try String.fetchAll($0, sql: "SELECT id FROM attachment WHERE noteId = ? ORDER BY filename", arguments: [note.id])
        }
        // UUIDv7: 36 characters, version nibble 7.
        #expect(ids.count == 2 && ids.allSatisfy { $0.count == 36 && $0[$0.index($0.startIndex, offsetBy: 14)] == "7" })

        try texts.record(OCRJob(noteId: note.id, filename: "a.png"), result: found("hello"))
        try edit(note, to: "# T\n![](a.png)\n![](c.png)")
        #expect(try entries(note.id) == [
            Entry(filename: "a.png", state: "done", text: "hello"), Entry(filename: "c.png", state: "pending", text: nil),
        ])
        // A kept attachment keeps its id (stable identity for M9).
        let keptId = try db.pool.read { try String.fetchOne($0, sql: "SELECT id FROM attachment WHERE filename = 'a.png'") }
        #expect(keptId == ids[0])
    }

    @Test func testRecordWritesOcrTextIntoSearchContent() throws {
        let note = try store.create(text: "# T\n![](a.png)\n![](b.png)")
        try texts.record(OCRJob(noteId: note.id, filename: "b.png"), result: found("Second STRASSE"))
        #expect(try ocrColumn(note.id) == "second strasse")
        try texts.record(OCRJob(noteId: note.id, filename: "a.png"), result: found("First Äpfel"))
        // Text order of the attachments in the note, not recording order; folded.
        #expect(try ocrColumn(note.id) == "first apfel\nsecond strasse")
        let rows = try entries(note.id)
        #expect(rows.map(\.state) == ["done", "done"])
        #expect(rows.first?.text == "First Äpfel")
        // none / failed / skipped clear the text.
        try texts.record(OCRJob(noteId: note.id, filename: "a.png"), result: .none(sha256: "abc"))
        #expect(try ocrColumn(note.id) == "second strasse")
        try texts.record(OCRJob(noteId: note.id, filename: "b.png"), result: .failed)
        #expect(try ocrColumn(note.id) == "")
        #expect(try entries(note.id).map(\.state) == ["none", "failed"])
        try texts.record(OCRJob(noteId: note.id, filename: "b.png"), result: .skipped)
        #expect(try entries(note.id).map(\.state) == ["none", "skipped"])
    }

    @Test func testPendingJobsAreOldestFirstAndLimited() throws {
        let first = try store.create(text: "# One\n![](a.png)")
        let second = try store.create(text: "# Two\n![](b.png)")
        let jobs = try texts.pendingJobs(limit: 10)
        #expect(jobs == [OCRJob(noteId: first.id, filename: "a.png"), OCRJob(noteId: second.id, filename: "b.png")])
        #expect(try texts.pendingJobs(limit: 1) == [OCRJob(noteId: first.id, filename: "a.png")])
        try texts.record(jobs[0], result: .failed)
        #expect(try texts.pendingJobs(limit: 10) == [jobs[1]])
    }

    @Test func testLockedNotesAreNeverPendingAndRecordIsRefused() throws {
        let note = try store.create(text: "# T\n![](a.png)")
        try lock(note.id)
        #expect(try texts.pendingJobs(limit: 10).isEmpty)
        try texts.record(OCRJob(noteId: note.id, filename: "a.png"), result: found("secret invoice"))
        #expect(try entries(note.id) == [Entry(filename: "a.png", state: "locked", text: nil)])
        let content = try db.pool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note_search_content WHERE noteId = ?", arguments: [note.id])
        }
        #expect(content == 0)
    }

    @Test func testLockingClearsOcrText() throws {
        let note = try store.create(text: "# T\n![](a.png)")
        try texts.record(OCRJob(noteId: note.id, filename: "a.png"), result: found("invoice number 42", sha: "s1"))
        #expect(try ocrColumn(note.id) == "invoice number 42")
        try lock(note.id)
        #expect(try entries(note.id) == [Entry(filename: "a.png", state: "locked", text: nil)])
        #expect(try texts.reusableText(sha256: "s1") == nil)
        #expect(try ocrColumn(note.id) == nil)
        // Unlocking and re-indexing queues the attachment again.
        try db.pool.write { db in
            try db.execute(sql: "UPDATE note SET isLocked = 0, text = ? WHERE id = ?", arguments: ["# T\n![](a.png)", note.id])
            try NoteIndexer.index(noteId: note.id, text: "# T\n![](a.png)", in: db)
        }
        #expect(try entries(note.id) == [Entry(filename: "a.png", state: "pending", text: nil)])
    }

    @Test func testRemovingTheAttachmentRemovesItsTextFromSearch() throws {
        let note = try store.create(text: "# T\n![](a.png)")
        try texts.record(OCRJob(noteId: note.id, filename: "a.png"), result: found("invoice"))
        #expect(try ocrColumn(note.id) == "invoice")
        try edit(note, to: "# T\nnothing here")
        #expect(try entries(note.id).isEmpty)
        #expect(try ocrColumn(note.id) == "")
        // A late result for the removed attachment writes nothing.
        try texts.record(OCRJob(noteId: note.id, filename: "a.png"), result: found("invoice"))
        #expect(try entries(note.id).isEmpty)
        #expect(try ocrColumn(note.id) == "")
    }

    @Test func testReusableTextBySha256() throws {
        let one = try store.create(text: "# One\n![](a.png)")
        let two = try store.create(text: "# Two\n![](b.png)")
        #expect(try texts.reusableText(sha256: "same") == nil)
        try texts.record(OCRJob(noteId: one.id, filename: "a.png"), result: found("Receipt Total", sha: "same"))
        #expect(try texts.reusableText(sha256: "same") == "Receipt Total")
        #expect(try texts.reusableText(sha256: "other") == nil)
        try texts.record(OCRJob(noteId: two.id, filename: "b.png"), result: .none(sha256: "blank"))
        #expect(try texts.reusableText(sha256: "blank") == nil)
    }

    @Test func testOnlyParameterizedSQL() throws {
        let nasty = "'; DROP TABLE note; --.png"
        let note = try store.create(text: "# T\n![](\(nasty.replacingOccurrences(of: " ", with: "%20")))")
        let job = OCRJob(noteId: note.id, filename: nasty)
        #expect(try texts.pendingJobs(limit: 5) == [job])
        try texts.record(job, result: found("it's \"quoted\" ' OR 1=1", sha: "x'; --"))
        #expect(try ocrColumn(note.id) == "it's \"quoted\" ' or 1=1")
        #expect(try texts.reusableText(sha256: "x'; --") == "it's \"quoted\" ' OR 1=1")
        #expect(try store.note(id: note.id) != nil)
        #expect(try entries(note.id) == [Entry(filename: nasty, state: "done", text: "it's \"quoted\" ' OR 1=1")])
    }

    @Test func testMigrationV7BackfillsPendingRowsForUnlockedNotes() throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        try Migrations.migrator.migrate(queue, upTo: "v6")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO note (id, text, title, titleKey, createdAt, modifiedAt)
                VALUES ('n1', '# T' || char(10) || '![](a.png)' || char(10) || '[d.pdf](d.pdf)<!-- {"embed":"true"} -->' || char(10) || '![](a.png)',
                        'T', '', '2026-01-01 00:00:00.000', '2026-01-01 00:00:00.000');
                INSERT INTO note (id, text, title, titleKey, createdAt, modifiedAt, isLocked)
                VALUES ('locked', '', '', '', '2026-01-01 00:00:00.000', '2026-01-01 00:00:00.000', 1);
                """)
        }
        try Migrations.migrator.migrate(queue)
        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, noteId, filename, ocrState, ocrText, createdAt FROM attachment ORDER BY filename
                """)
            #expect(rows.map { $0["filename"] as String } == ["a.png", "d.pdf"])
            #expect(rows.allSatisfy { ($0["noteId"] as String) == "n1" && ($0["ocrState"] as String) == "pending" })
            #expect(rows.allSatisfy { ($0["id"] as String).count == 36 })
            // The note's creation time, so "oldest first" follows the notes.
            let created = ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")
            #expect(rows.allSatisfy { ($0["createdAt"] as Date?) == created })
            let keys = try String.fetchAll(db, sql: "SELECT filenameKey FROM attachment ORDER BY filename")
            #expect(keys == ["a.png", "d.pdf"])
        }
    }

    // MARK: fix round 1

    private func raw(_ noteId: String, _ tail: String = "") throws -> [Row] {
        try db.pool.read { try Row.fetchAll($0, sql: "SELECT * FROM attachment WHERE noteId = ? \(tail)", arguments: [noteId]) }
    }

    @Test func testRowsFollowDeletePermanentlyAndEmptyTrash() throws {
        let one = try store.create(text: "# One\n![](a.png)")
        let two = try store.create(text: "# Two\n![](b.png)")
        let count = { try self.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM attachment")! } }
        #expect(try count() == 2)
        try store.deletePermanently([one.id])
        #expect(try count() == 1)
        try store.trash([two.id])
        _ = try store.emptyTrash()
        #expect(try count() == 0)
    }

    @Test func testConflictCopyGetsItsOwnRows() throws {
        let note = try store.create(text: "# T\n![](a.png)")
        let copy = try store.createConflictCopy(of: note.id, text: "# T\n![](a.png)\n![](b.png)")
        #expect(try entries(copy.id).map(\.filename) == ["a.png", "b.png"])
        let ids = try db.pool.read { try String.fetchAll($0, sql: "SELECT id FROM attachment") }
        #expect(Set(ids).count == 3)
    }

    @Test func testTrashedNotesProduceNoJobs() throws {
        let note = try store.create(text: "# T\n![](a.png)")
        #expect(try texts.pendingJobs(limit: 5).count == 1)
        try store.trash([note.id])
        #expect(try texts.pendingJobs(limit: 5).isEmpty)
        try store.restore([note.id])
        #expect(try texts.pendingJobs(limit: 5).count == 1)
    }

    @Test func testUnlinkTombstonesAndRelinkRevivesWithSameIdAndText() throws {
        let note = try store.create(text: "# T\n![](a.png)")
        let id: String = try #require(try raw(note.id).first)["id"]
        try texts.record(OCRJob(noteId: note.id, filename: "a.png"), result: found("invoice 7"))
        try edit(note, to: "# T\nno image")
        var rows = try raw(note.id)
        #expect(rows.count == 1)
        #expect(rows[0]["id"] as String == id)
        #expect((rows[0]["deletedAt"] as Date?) != nil)
        #expect(try ocrColumn(note.id) == "")
        #expect(try texts.pendingJobs(limit: 5).isEmpty)
        // A result for the unlinked attachment writes nothing.
        try texts.record(OCRJob(noteId: note.id, filename: "a.png"), result: found("other"))
        #expect(try raw(note.id).first?["ocrText"] as String? == "invoice 7")

        try edit(note, to: "# T\n![](A.PNG)")
        rows = try raw(note.id)
        #expect(rows.count == 1)
        #expect(rows[0]["id"] as String == id)
        #expect((rows[0]["deletedAt"] as Date?) == nil)
        #expect(rows[0]["filename"] as String == "A.PNG")
        #expect(rows[0]["ocrState"] as String == "done")
        #expect(try ocrColumn(note.id) == "invoice 7")
    }

    @Test func testReplacedBytesRequeueTheRow() throws {
        let note = try store.create(text: "# T\n![](a.png)\n![](keep.png)")
        try texts.record(OCRJob(noteId: note.id, filename: "a.png"), result: found("old", sha: "s-old"))
        try texts.record(OCRJob(noteId: note.id, filename: "keep.png"), result: found("kept", sha: "s-keep"))
        let files = AttachmentFiles(paths: tmp.paths, database: db)
        try files.write([ImportedAttachment(filename: "A.png", data: Data([1]))], noteId: note.id, replacing: false) { _ in }
        let rows = try raw(note.id, "ORDER BY filename")
        #expect(rows.map { $0["ocrState"] as String } == ["pending", "done"])
        let a = rows[0]
        #expect((a["ocrText"] as String?) == nil && (a["sha256"] as String?) == nil)
        #expect((a["byteSize"] as Int?) == nil && (a["fileModifiedAt"] as Date?) == nil)
        #expect(rows[1]["ocrText"] as String? == "kept")
        #expect(try ocrColumn(note.id) == "kept")
    }

    @Test func testLockClearsPlaintextMetadataAndUnlockRequeuesOnlyLockedRows() throws {
        let note = try store.create(text: "# T\n![](a.png)\n![](b.png)")
        try texts.record(OCRJob(noteId: note.id, filename: "a.png"), result: found("secret", sha: "h1"))
        try texts.record(OCRJob(noteId: note.id, filename: "b.png"), result: .skipped)
        try db.pool.write {
            try $0.execute(sql: "UPDATE attachment SET uti = 'public.png', width = 3, height = 4 WHERE noteId = ?", arguments: [note.id])
        }
        try lock(note.id)
        for row in try raw(note.id) {
            #expect(row["ocrState"] as String == "locked")
            for column in ["sha256", "byteSize", "fileModifiedAt", "uti", "width", "height", "ocrText", "ocrAt", "ocrVersion"] {
                #expect((row[column] as DatabaseValue).isNull, "\(column) kept on lock")
            }
        }
        let text = "# T\n![](a.png)\n![](b.png)"
        try db.pool.write { db in
            try db.execute(sql: "UPDATE note SET isLocked = 0, text = ? WHERE id = ?", arguments: [text, note.id])
            try NoteIndexer.index(noteId: note.id, text: text, in: db)
        }
        #expect(try entries(note.id).map(\.state) == ["pending", "pending"])
        // A worker-skipped row is not a locked row: it stays skipped across re-indexing.
        try texts.record(OCRJob(noteId: note.id, filename: "b.png"), result: .skipped)
        try edit(note, to: text + "\nmore")
        #expect(try entries(note.id).map(\.state) == ["pending", "skipped"])
    }

    @Test func testNamesDifferingInCaseOrNormalizationShareOneRow() throws {
        let nfc = "caf\u{E9}.png"
        let nfd = "cafe\u{301}.png"
        let note = try store.create(text: "# T\n![](Foto.png)\n![](foto.png)\n![](\(nfc))\n![](\(nfd))")
        #expect(try entries(note.id).count == 2)
        #expect(try texts.pendingJobs(limit: 10).count == 2)
        // Results find the row whichever spelling the job carries.
        try texts.record(OCRJob(noteId: note.id, filename: "FOTO.PNG"), result: found("hi"))
        try texts.record(OCRJob(noteId: note.id, filename: nfd), result: found("cafe"))
        #expect(try entries(note.id).map(\.state) == ["done", "done"])
        let keys = try raw(note.id, "ORDER BY filenameKey").map { $0["filenameKey"] as String }
        #expect(keys == ["caf\u{E9}.png", "foto.png"])
        // The table itself refuses a second row for the same key.
        #expect(throws: DatabaseError.self) {
            try self.db.pool.write {
                try $0.execute(sql: """
                    INSERT INTO attachment (id, noteId, filename, filenameKey, createdAt, updatedAt)
                    VALUES ('x', ?, 'FOTO.png', 'foto.png', ?, ?)
                    """, arguments: [note.id, Date(), Date()])
            }
        }
    }

    @Test func testMissingFilesAreRetriedLaterAndNeverStarvePendingJobs() throws {
        let note = try store.create(text: "# T\n![](gone.png)\n![](there.png)")
        try texts.record(OCRJob(noteId: note.id, filename: "gone.png"), result: .missing)
        #expect(try entries(note.id).map(\.state) == ["missing", "pending"])
        // Within the backoff only the pending job is offered.
        #expect(try texts.pendingJobs(limit: 5).map(\.filename) == ["there.png"])
        // After the backoff the missing one comes back, after every pending job.
        let later = Date().addingTimeInterval(AttachmentTextStore.missingRetryInterval + 5)
        #expect(try texts.pendingJobs(limit: 5, now: later).map(\.filename) == ["there.png", "gone.png"])
        #expect(try texts.pendingJobs(limit: 1, now: later).map(\.filename) == ["there.png"])
        #expect(try ocrColumn(note.id) == "")
    }

    @Test func testReusableTextIgnoresDeletedNotes() throws {
        let note = try store.create(text: "# T\n![](a.png)")
        try texts.record(OCRJob(noteId: note.id, filename: "a.png"), result: found("text", sha: "dd"))
        #expect(try texts.reusableText(sha256: "dd") == "text")
        try db.pool.write { try $0.execute(sql: "UPDATE note SET deletedAt = ? WHERE id = ?", arguments: [Date(), note.id]) }
        #expect(try texts.reusableText(sha256: "dd") == nil)
    }

    @Test func testEveryRowWriteMovesUpdatedAt() throws {
        let note = try store.create(text: "# T\n![](a.png)")
        func updatedAt() throws -> Date { try #require(try raw(note.id).first)["updatedAt"] }
        let created = try updatedAt()
        Thread.sleep(forTimeInterval: 0.01)
        try texts.record(OCRJob(noteId: note.id, filename: "a.png"), result: found("x"))
        let recorded = try updatedAt()
        #expect(recorded > created)
        Thread.sleep(forTimeInterval: 0.01)
        try edit(note, to: "# T")
        #expect(try updatedAt() > recorded)
    }

    @Test func testUnreferencedFileCleanupPurgesItsTombstone() throws {
        let note = try store.create(text: "# T\n![](a.png)")
        let dir = tmp.paths.attachments.appendingPathComponent(note.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("a.png")
        try Data([1]).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: file.path)
        try edit(note, to: "# T")
        #expect(try raw(note.id).count == 1)
        // The file is too young for the grace period at that `now`, so its tombstone stays too.
        #expect(store.removeUnreferencedAttachments(noteId: note.id, now: Date(timeIntervalSinceNow: -3600)).isEmpty)
        #expect(try raw(note.id).count == 1)
        #expect(store.removeUnreferencedAttachments(noteId: note.id) == ["a.png"])
        #expect(try raw(note.id).isEmpty)
    }
    // MARK: Task 16 (carried from the Task 15 review)

    /// Makes every row's last result old, as after a recognizer upgrade between launches.
    private func backdate(_ noteId: String) throws {
        try db.pool.write {
            try $0.execute(sql: "UPDATE attachment SET ocrAt = ? WHERE noteId = ?", arguments: [Date(timeIntervalSince1970: 1_000_000), noteId])
        }
    }

    private func stage(_ noteId: String) throws {
        try db.pool.write {
            try $0.execute(
                sql: "INSERT INTO staging_batch (id, noteId, replacing, filenames, createdAt) VALUES (?, ?, 0, '[]', ?)",
                arguments: [UUID().uuidString, noteId, Date()])
        }
    }

    @Test func testNotesWithAStagedBatchAreSkippedUntilItIsInstalled() throws {
        let note = try store.create(text: "# T\n![](a.png)")
        let other = try store.create(text: "# U\n![](b.png)")
        try stage(note.id)
        let job = OCRJob(noteId: note.id, filename: "a.png")
        #expect(try texts.pendingJobs(limit: 5) == [OCRJob(noteId: other.id, filename: "b.png")])
        #expect(try texts.hasStagedBatch(noteId: note.id))
        #expect(try !texts.hasStagedBatch(noteId: other.id))
        // A result computed from the old bytes must not land while the replacement is on its way.
        try texts.record(job, result: found("old file text"))
        #expect(try entries(note.id) == [Entry(filename: "a.png", state: "pending", text: nil)])
        try db.pool.write { try $0.execute(sql: "DELETE FROM staging_batch") }
        #expect(try texts.pendingJobs(limit: 5).count == 2)
        try texts.record(job, result: found("new file text"))
        #expect(try entries(note.id) == [Entry(filename: "a.png", state: "done", text: "new file text")])
    }

    @Test func testTombstonesOfNotesWithoutAnAttachmentDirectoryArePurged() throws {
        let note = try store.create(text: "# T\n![](a.png)")
        try edit(note, to: "# T")
        #expect(try raw(note.id).count == 1)
        // No directory at all.
        store.removeUnreferencedAttachments(noteId: note.id)
        #expect(try raw(note.id).isEmpty)

        let empty = try store.create(text: "# E\n![](a.png)")
        try edit(empty, to: "# E")
        let dir = tmp.paths.attachments.appendingPathComponent(empty.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store.removeUnreferencedAttachments(noteId: empty.id)
        #expect(try raw(empty.id).isEmpty)
    }

    @Test func testTombstonesStayWhileTheNoteMayStillLinkTheFile() throws {
        let note = try store.create(text: "# T\n![](a.png)")
        try edit(note, to: "# T")
        store.retention.retain(note.id)
        store.removeUnreferencedAttachments(noteId: note.id)
        #expect(try raw(note.id).count == 1)
        store.retention.release(note.id)
        let batch = tmp.paths.attachments.appendingPathComponent(".staging/\(UUID().uuidString)/\(note.id)")
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        try Data([1]).write(to: batch.appendingPathComponent("a.png"))
        store.removeUnreferencedAttachments(noteId: note.id)
        #expect(try raw(note.id).count == 1)
    }

    @Test func testRowsRecognizedByAnOlderRecognizerAreRequeued() throws {
        let note = try store.create(text: "# T\n![](a.png)\n![](b.png)\n![](c.png)")
        let jobs = try texts.pendingJobs(limit: 5)
        try texts.record(jobs[0], result: found("old a", sha: "sa"), recognizerVersion: AttachmentTextStore.recognizerVersion - 1)
        try texts.record(jobs[1], result: .none(sha256: "sb"), recognizerVersion: AttachmentTextStore.recognizerVersion - 1)
        try texts.record(jobs[2], result: found("current c", sha: "sc"))
        try backdate(note.id)
        #expect(try texts.pendingJobs(limit: 5) == [jobs[0], jobs[1]])
        // The old text stays searchable until the new result replaces it ...
        #expect(try ocrColumn(note.id) == "old a\ncurrent c")
        // ... and is not offered as "reusable" for the same bytes.
        #expect(try texts.reusableText(sha256: "sa") == nil)
        try texts.record(jobs[0], result: found("new a", sha: "sa"))
        try texts.record(jobs[1], result: .none(sha256: "sb"))
        #expect(try texts.pendingJobs(limit: 5).isEmpty)
        #expect(try texts.reusableText(sha256: "sa") == "new a")
    }

    @Test func testStoredTextIsCapped() throws {
        let note = try store.create(text: "# T\n![](a.png)")
        let word = "lorem "
        let long = String(repeating: word, count: AttachmentTextStore.maxTextLength / word.count + 500)
        try texts.record(OCRJob(noteId: note.id, filename: "a.png"), result: found(long))
        let stored = try #require(try entries(note.id).first?.text)
        #expect(stored.count <= AttachmentTextStore.maxTextLength && stored.count > AttachmentTextStore.maxTextLength - 10)
        #expect(stored.hasSuffix("lorem"))
    }

    // MARK: Task 16 fix round 1

    private let facts = OCRFileFacts(size: 10, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))

    @Test func testFailedAndSkippedRowsAreRequeuedAfterAVersionBump() throws {
        let note = try store.create(text: "# T\n![](a.png)\n![](b.png)")
        let jobs = try texts.pendingJobs(limit: 5)
        let old = AttachmentTextStore.recognizerVersion - 1
        try texts.record(jobs[0], result: .failed, recognizerVersion: old, facts: facts)
        try texts.record(jobs[1], result: .skipped, recognizerVersion: old, facts: facts)
        // Written with the version, not NULL ...
        #expect(try raw(note.id, "ORDER BY filename").map { $0["ocrVersion"] as Int? } == [old, old])
        // ... so a recognizer upgrade offers them (once their backoff passed) ...
        #expect(try texts.pendingJobs(limit: 5).isEmpty)
        try backdate(note.id)
        #expect(try texts.pendingJobs(limit: 5) == jobs)
        // ... and a current failure is not offered before its backoff ends, a current skip never.
        try texts.record(jobs[0], result: .failed, facts: facts)
        try texts.record(jobs[1], result: .skipped, facts: facts)
        #expect(try texts.pendingJobs(limit: 5).isEmpty)
        let later = Date().addingTimeInterval(AttachmentTextStore.failedRetryInterval + 5)
        #expect(try texts.pendingJobs(limit: 5, now: later) == [jobs[0]])
        // A failed row whose file changed since can be told apart.
        let failed = try texts.failedJobsWithFacts(limit: 5)
        #expect(failed.count == 1 && failed[0].job == jobs[0] && failed[0].facts == facts)
    }

    @Test func testAFailedRerunKeepsTheOldText() throws {
        let note = try store.create(text: "# T\n![](a.png)")
        let job = OCRJob(noteId: note.id, filename: "a.png")
        let old = AttachmentTextStore.recognizerVersion - 1
        try texts.record(job, result: found("old words"), recognizerVersion: old)
        try backdate(note.id)
        #expect(try texts.pendingJobs(limit: 5) == [job])
        try texts.record(job, result: .failed, facts: facts)
        #expect(try ocrColumn(note.id) == "old words")
        #expect(try entries(note.id) == [Entry(filename: "a.png", state: "done", text: "old words")])
        // It waits out the backoff before the next try.
        #expect(try texts.pendingJobs(limit: 5).isEmpty)
        #expect(try texts.pendingJobs(limit: 5, now: Date().addingTimeInterval(AttachmentTextStore.failedRetryInterval + 5)) == [job])
        // A file that is late (syncing) keeps the text too.
        try texts.record(job, result: .missing, facts: nil)
        #expect(try ocrColumn(note.id) == "old words")
        // Text of another file version is not kept.
        let changed = OCRFileFacts(size: 11, modifiedAt: facts.modifiedAt)
        try texts.record(job, result: .failed, facts: changed)
        #expect(try ocrColumn(note.id) == "")
        #expect(try entries(note.id) == [Entry(filename: "a.png", state: "failed", text: nil)])
        #expect(try raw(note.id).first?["byteSize"] as Int? == 11)
    }

    @Test func testAResultForARowThatChangedMeanwhileIsDropped() throws {
        let note = try store.create(text: "# T\n![](a.png)")
        let job = OCRJob(noteId: note.id, filename: "a.png")
        let token = try #require(try texts.runnableToken(job))
        Thread.sleep(forTimeInterval: 0.01)
        // The bytes were replaced: the row went back to pending with a new `updatedAt`.
        try db.pool.write {
            try $0.execute(sql: "UPDATE attachment SET updatedAt = ? WHERE noteId = ?", arguments: [Date(), note.id])
        }
        try texts.record(job, result: found("old file"), expectingUpdatedAt: token)
        #expect(try entries(note.id) == [Entry(filename: "a.png", state: "pending", text: nil)])
        let fresh = try #require(try texts.runnableToken(job))
        try texts.record(job, result: found("new file"), expectingUpdatedAt: fresh)
        #expect(try entries(note.id) == [Entry(filename: "a.png", state: "done", text: "new file")])
    }

    @Test func testNothingIsRecordedForTrashedOrDeletedNotes() throws {
        let note = try store.create(text: "# T\n![](a.png)")
        let job = OCRJob(noteId: note.id, filename: "a.png")
        try store.trash([note.id])
        #expect(try texts.runnableToken(job) == nil)
        try texts.record(job, result: found("trashed"))
        #expect(try entries(note.id) == [Entry(filename: "a.png", state: "pending", text: nil)])
        try store.restore([note.id])
        try db.pool.write { try $0.execute(sql: "UPDATE note SET deletedAt = ? WHERE id = ?", arguments: [Date(), note.id]) }
        try texts.record(job, result: found("deleted"))
        #expect(try entries(note.id) == [Entry(filename: "a.png", state: "pending", text: nil)])
    }

    @Test func testTheLaunchSweepAlsoPurgesTombstonesOfNotesWithoutADirectory() throws {
        let note = try store.create(text: "# T\n![](a.png)")
        try edit(note, to: "# T")
        let other = try store.create(text: "# U\n![](b.png)")
        try edit(other, to: "# U")
        // `other` is open in an editor: its tombstone stays.
        store.retention.retain(other.id)
        #expect(store.removeUnreferencedAttachments() == 0)
        #expect(try raw(note.id).isEmpty)
        #expect(try raw(other.id).count == 1)
    }
}
