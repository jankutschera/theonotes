// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import GRDB
@testable import TheoNotesCore

@Suite struct ImportNoteTests {
    let tmp: TempPaths
    let db: AppDatabase
    let store: NoteStore
    let created = Date(timeIntervalSince1970: 1_735_787_045)
    let modified = Date(timeIntervalSince1970: 1_738_555_506)

    init() throws {
        tmp = try TempPaths()
        db = try AppDatabase.inMemory()
        store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
    }

    private func draft(
        _ text: String, location: NoteLocation = .notes, tagPins: [String] = [],
        attachments: [ImportedAttachment] = []
    ) -> ImportedNoteDraft {
        ImportedNoteDraft(
            text: text, createdAt: created, modifiedAt: modified, location: location,
            isPinnedGlobal: true, tagPins: tagPins, isReadOnly: true, attachments: attachments)
    }

    private func pinnedTags(_ noteId: String) throws -> [String] {
        try db.pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT tag.displayPath FROM note_pin JOIN tag ON tag.id = note_pin.tagId
                WHERE note_pin.noteId = ? ORDER BY tag.pathKey
                """, arguments: [noteId])
        }
    }

    private var stagingLeftovers: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: AttachmentFiles(paths: tmp.paths, database: db).staging.path)) ?? []
    }

    @Test func testImportKeepsDatesFlagsPinsAndFiles() throws {
        let note = try store.importNote(draft(
            "# Title\n#work/sub #home\n[a b.pdf](a%20b.pdf)<!-- {\"embed\":\"true\"} -->",
            location: .archive, tagPins: ["work", "home", "absent"],
            attachments: [ImportedAttachment(filename: "a b.pdf", data: Data([0, 1, 255]))]))
        #expect(note.createdAt == created)
        #expect(note.modifiedAt == modified)
        #expect(note.location == .archive)
        #expect(note.archivedAt == modified)
        #expect(note.trashedAt == nil)
        #expect(note.isPinnedGlobal && note.isReadOnly)
        #expect(note.revision == 1)
        #expect(note.title == "Title")
        #expect(try pinnedTags(note.id) == ["home", "work"])
        let file = tmp.paths.attachments.appendingPathComponent("\(note.id)/a b.pdf")
        #expect(try Data(contentsOf: file) == Data([0, 1, 255]))
        #expect(stagingLeftovers.isEmpty)
    }

    @Test func testTrashedImportSetsTrashedAt() throws {
        let note = try store.importNote(draft("x", location: .trash))
        #expect(note.trashedAt == modified)
        #expect(note.archivedAt == nil)
    }

    @Test func testPinnableTagsSplitsPinsByCarriedTags() {
        let split = NoteStore.pinnableTags(["work", "Work/Sub", "nope", "#home"], text: "#work/sub #home")
        #expect(split.pinnable == ["work", "Work/Sub", "#home"])
        #expect(split.skipped == ["nope"])
    }

    @Test func testDatabaseFailureRemovesStagedFiles() throws {
        _ = try store.importNote(draft("one"))
        try db.pool.write { db in
            try db.execute(sql: "CREATE TEMP TRIGGER fail_insert BEFORE INSERT ON note BEGIN SELECT RAISE(ABORT, 'boom'); END")
        }
        #expect(throws: (any Error).self) {
            _ = try store.importNote(draft("two", attachments: [ImportedAttachment(filename: "f.bin", data: Data([1]))]))
        }
        #expect(try store.allNotes().count == 1)
        #expect(stagingLeftovers.isEmpty)
        let dirs = try FileManager.default.contentsOfDirectory(atPath: tmp.paths.attachments.path)
        #expect(dirs.filter { !$0.hasPrefix(".") }.isEmpty)
    }

    @Test func testStagedPathEncodesNoteAndFilename() throws {
        let files = AttachmentFiles(paths: tmp.paths, database: db)
        let staged = try files.stage(
            [ImportedAttachment(filename: "100% a b.pdf", data: Data([7])), ImportedAttachment(filename: "Ünï.jpg", data: Data())],
            noteId: "N1")
        let paths = staged.entries.map(\.path)
        #expect(paths.count == 2)
        let batch = try #require(paths.first.map { URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent() })
        #expect(batch.deletingLastPathComponent().lastPathComponent == ".staging")
        #expect(UUID(uuidString: batch.lastPathComponent) != nil)
        #expect(paths[0].hasSuffix("/N1/100%25 a b.pdf"))
        #expect(paths[1].utf8.elementsEqual((batch.path + "/N1/Ünï.jpg").utf8))
        #expect(AttachmentFiles.decodeStagedName("100%25 a b.pdf") == "100% a b.pdf")
        #expect(try Data(contentsOf: URL(fileURLWithPath: paths[0])) == Data([7]))
        files.discard(staged)
        #expect(stagingLeftovers.isEmpty)
    }

    @Test func testInstallKeepListIsCaseInsensitive() throws {
        let note = try store.importNote(draft("x", attachments: [ImportedAttachment(filename: "Photo.JPG", data: Data([1]))]))
        _ = try store.replaceImported(
            noteID: note.id, draft: draft("x", attachments: [ImportedAttachment(filename: "photo.jpg", data: Data([2]))]),
            expectedRevision: note.revision)
        let dir = tmp.paths.attachments.appendingPathComponent(note.id)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.count == 1)
        #expect(try Data(contentsOf: dir.appendingPathComponent("photo.jpg")) == Data([2]))
    }

    @Test func testInvalidAttachmentNamesAreRejected() throws {
        for name in ["", ".", "..", "a/b", "../x", "a\u{0}b"] {
            #expect(throws: AttachmentFiles.FileError.invalidFilename(name)) {
                _ = try store.importNote(draft("x", attachments: [ImportedAttachment(filename: name, data: Data())]))
            }
        }
        #expect(throws: AttachmentFiles.FileError.duplicateFilename("A.jpg")) {
            _ = try store.importNote(draft("x", attachments: [
                ImportedAttachment(filename: "a.jpg", data: Data()), ImportedAttachment(filename: "A.jpg", data: Data()),
            ]))
        }
        #expect(try store.allNotes().isEmpty)
        #expect(stagingLeftovers.isEmpty)
    }

    /// Files the draft no longer lists stay: the cleanup runs only in the app, on eviction and at
    /// launch (ruling R23; `AttachmentStoreTests` covers what it keeps).
    @Test func testReplaceImportedKeepsIdAndCreatedAndSwapsFiles() throws {
        let note = try store.importNote(draft(
            "# Old #work", tagPins: ["work"],
            attachments: [ImportedAttachment(filename: "old.jpg", data: Data([1])),
                          ImportedAttachment(filename: "keep.jpg", data: Data([2]))]))
        let later = modified.addingTimeInterval(3600)
        let replaced = try store.replaceImported(
            noteID: note.id,
            draft: ImportedNoteDraft(
                text: "# New #home", createdAt: later, modifiedAt: later, location: .trash,
                isPinnedGlobal: false, tagPins: ["home"], isReadOnly: false,
                attachments: [ImportedAttachment(filename: "keep.jpg", data: Data([3]))]),
            expectedRevision: note.revision)
        #expect(replaced.id == note.id)
        #expect(replaced.createdAt == created)
        #expect(replaced.modifiedAt == later)
        #expect(replaced.trashedAt == later)
        #expect(replaced.location == .trash)
        #expect(!replaced.isPinnedGlobal && !replaced.isReadOnly)
        #expect(replaced.revision == note.revision + 1)
        #expect(replaced.title == "New #home")
        #expect(try pinnedTags(note.id) == ["home"])
        let dir = tmp.paths.attachments.appendingPathComponent(note.id)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["keep.jpg", "old.jpg"])
        #expect(try Data(contentsOf: dir.appendingPathComponent("keep.jpg")) == Data([3]))
        #expect(throws: StoreError.revisionConflict(current: note.revision + 1)) {
            _ = try store.replaceImported(noteID: note.id, draft: draft("x"), expectedRevision: note.revision)
        }
    }

    private let meta = SourceMetadata(location: .notes, isPinnedGlobal: true, tagPins: ["a"], isReadOnly: false)

    private func refWrite(_ id: String, hash: String) -> ExternalRefWrite {
        ExternalRefWrite(source: "bear", externalId: id, lastSeenModified: modified, lastSeenHash: hash,
                         lastSeenTextHash: "t-" + hash, lastSeenMeta: meta)
    }

    @Test func testExternalRefsAreWrittenInTheSameTransaction() throws {
        let note = try store.importNote(draft("a"), externalRef: refWrite("B1", hash: "h1"))
        var refs = try store.externalRefs(source: "bear")
        #expect(refs["B1"] == ExternalRef(
            source: "bear", externalId: "B1", noteId: note.id, lastSeenModified: modified, lastSeenHash: "h1",
            lastSeenTextHash: "t-h1", lastSeenMeta: meta, importedRevision: note.revision,
            importedTextHash: NoteStore.textHash("a")))

        // A conflict copy takes over the ref.
        let copy = try store.importNote(draft("b"), externalRef: refWrite("B1", hash: "h2"))
        refs = try store.externalRefs(source: "bear")
        #expect(refs["B1"]?.noteId == copy.id)
        #expect(refs["B1"]?.importedTextHash == NoteStore.textHash("b"))

        let replaced = try store.replaceImported(
            noteID: copy.id, draft: draft("c"), expectedRevision: copy.revision, externalRef: refWrite("B1", hash: "h3"))
        refs = try store.externalRefs(source: "bear")
        #expect(refs["B1"]?.importedRevision == replaced.revision)
        #expect(refs["B1"]?.importedTextHash == NoteStore.textHash("c"))

        let meta = try store.applyImportedMetadata(
            noteID: copy.id, draft: draft("ignored", location: .trash), expectedRevision: replaced.revision,
            externalRef: refWrite("B1", hash: "h4"))
        refs = try store.externalRefs(source: "bear")
        #expect(meta.text == "c")
        #expect(refs["B1"]?.lastSeenHash == "h4")
        #expect(refs["B1"]?.importedRevision == meta.revision)
        #expect(refs["B1"]?.importedTextHash == NoteStore.textHash("c"))

        try store.deletePermanently([copy.id])
        refs = try store.externalRefs(source: "bear")
        #expect(refs["B1"] != nil)
        #expect(refs["B1"]?.noteId == nil)
    }

    @Test func testApplyImportedMetadataKeepsTextAndFiles() throws {
        let note = try store.importNote(draft(
            "# T #a #b", tagPins: ["a"], attachments: [ImportedAttachment(filename: "f.jpg", data: Data([1]))]))
        let later = modified.addingTimeInterval(60)
        let updated = try store.applyImportedMetadata(
            noteID: note.id,
            draft: ImportedNoteDraft(text: "other", createdAt: later, modifiedAt: later, location: .archive,
                                     isPinnedGlobal: false, tagPins: ["b", "zzz"], isReadOnly: false),
            expectedRevision: note.revision)
        #expect(updated.text == "# T #a #b")
        #expect(updated.createdAt == created)
        #expect(updated.modifiedAt == later)
        #expect(updated.location == .archive && updated.archivedAt == later)
        #expect(!updated.isPinnedGlobal && !updated.isReadOnly)
        #expect(updated.revision == note.revision + 1)
        #expect(try pinnedTags(note.id) == ["b"])
        #expect(FileManager.default.fileExists(atPath: tmp.paths.attachments.appendingPathComponent("\(note.id)/f.jpg").path))
    }

    // MARK: - Staging batches and recovery

    private var files: AttachmentFiles { AttachmentFiles(paths: tmp.paths, database: db) }

    private func batchRows() throws -> Int {
        try db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM staging_batch") ?? 0 }
    }

    private func attachmentNames(_ noteId: String) -> [String] {
        let dir = tmp.paths.attachments.appendingPathComponent(noteId)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    @Test func testBatchRowCommitsWithTheTransactionAndIsRemovedAfterInstall() throws {
        var rowsInside = -1
        let note = try store.importNote(draft("x", attachments: [ImportedAttachment(filename: "a.jpg", data: Data([1]))]))
        #expect(try batchRows() == 0)
        #expect(attachmentNames(note.id) == ["a.jpg"])

        // A failing transaction rolls the row back with it.
        #expect(throws: (any Error).self) {
            _ = try files.write([ImportedAttachment(filename: "b.jpg", data: Data([2]))], noteId: note.id, replacing: false) { db in
                rowsInside = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM staging_batch") ?? 0
                throw StoreError.noteNotFound(id: "boom")
            }
        }
        #expect(rowsInside == 1)
        #expect(try batchRows() == 0)
        #expect(stagingLeftovers.isEmpty)
        #expect(attachmentNames(note.id) == ["a.jpg"])
    }

    @Test func testRecoveryDiscardsBatchesThatNeverCommitted() throws {
        let note = try store.importNote(draft("x"))
        _ = try files.stage([ImportedAttachment(filename: "a.jpg", data: Data([1]))], noteId: note.id)
        #expect(!stagingLeftovers.isEmpty)
        let result = try files.recover()
        #expect(result == AttachmentFiles.Recovery(installed: 0, discarded: 1))
        #expect(stagingLeftovers.isEmpty)
        #expect(attachmentNames(note.id).isEmpty)
    }

    @Test func testRecoveryInstallsCommittedBatchesAndRemovesStaleFiles() throws {
        let note = try store.importNote(draft("x", attachments: [
            ImportedAttachment(filename: "old.jpg", data: Data([1])), ImportedAttachment(filename: "keep.jpg", data: Data([1])),
        ]))
        // Crash after the commit of a replacing write, before any rename.
        let staged = try files.stage([ImportedAttachment(filename: "keep.jpg", data: Data([9])),
                                      ImportedAttachment(filename: "new 100%.jpg", data: Data([8]))], noteId: note.id)
        try db.pool.write { db in try AttachmentFiles.record(staged, replacing: true, in: db) }
        staged.lock?.release() // the crashed writer's lock went with its process
        #expect(try batchRows() == 1)

        let result = try files.recover()
        #expect(result == AttachmentFiles.Recovery(installed: 1, discarded: 0))
        #expect(attachmentNames(note.id) == ["keep.jpg", "new 100%.jpg"])
        let dir = tmp.paths.attachments.appendingPathComponent(note.id)
        #expect(try Data(contentsOf: dir.appendingPathComponent("keep.jpg")) == Data([9]))
        #expect(try batchRows() == 0)
        #expect(stagingLeftovers.isEmpty)
        #expect(try files.recover() == AttachmentFiles.Recovery(installed: 0, discarded: 0))
    }

    @Test func testRecoveryDiscardsCommittedBatchOfADeletedNote() throws {
        let note = try store.importNote(draft("x"))
        let staged = try files.stage([ImportedAttachment(filename: "a.jpg", data: Data([1]))], noteId: note.id)
        try db.pool.write { db in try AttachmentFiles.record(staged, in: db) }
        staged.lock?.release()
        try store.deletePermanently([note.id])
        #expect(try files.recover() == AttachmentFiles.Recovery(installed: 0, discarded: 1))
        #expect(try batchRows() == 0)
        #expect(stagingLeftovers.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: tmp.paths.attachments.appendingPathComponent(note.id).path))
    }

    /// Any importer: a ref deleted permanently in Theo Notes is never pointed at a note again, even
    /// when the delete lands between the importer's read and its write.
    @Test func testTombstonedRefIsNeverRevived() throws {
        let note = try store.importNote(draft("a"), externalRef: refWrite("B1", hash: "h1"))
        try store.deletePermanently([note.id])
        #expect(throws: StoreError.externalRefTombstoned(source: "bear", externalId: "B1")) {
            _ = try store.importNote(
                draft("b", attachments: [ImportedAttachment(filename: "b.jpg", data: Data([1]))]),
                externalRef: refWrite("B1", hash: "h2"))
        }
        #expect(try store.allNotes().isEmpty)
        #expect(try store.externalRefs(source: "bear")["B1"]?.lastSeenHash == "h1")
        #expect(stagingLeftovers.isEmpty)
        #expect(try batchRows() == 0)
    }

    @Test func testConflictCopyCopiesFilesAndTakesTheRefOnlyForTheImportedText() throws {
        let note = try store.importNote(
            draft("# A\n![](a.jpg)", attachments: [ImportedAttachment(filename: "a.jpg", data: Data([7]))]),
            externalRef: refWrite("B1", hash: "h1"))
        let other = try store.createConflictCopy(of: note.id, text: "# A\n![](a.jpg) cli edit")
        #expect(try store.externalRefs(source: "bear")["B1"]?.noteId == note.id)
        let copy = try store.createConflictCopy(of: note.id, text: "# A\n![](a.jpg)")
        let ref = try #require(try store.externalRefs(source: "bear")["B1"])
        #expect(ref.noteId == copy.id)
        #expect(ref.importedRevision == copy.revision)
        #expect(ref.importedTextHash == NoteStore.textHash("# A\n![](a.jpg)"))
        for id in [other.id, copy.id] {
            let file = tmp.paths.attachments.appendingPathComponent(id).appendingPathComponent("a.jpg")
            #expect(try Data(contentsOf: file) == Data([7]))
        }
        #expect(try store.note(id: copy.id)?.location == .notes)
    }

    /// A stored date written back unchanged stays the same date: GRDB decodes `…SS.SSS` to a
    /// double that can sit just below its millisecond, and the store must not round that down.
    @Test func testStoredDateSurvivesARewrite() throws {
        for step in 0..<2_000 {
            let date = Date(timeIntervalSince1970: 1_761_000_000 + Double(step) * 0.0371)
            let created = try store.create(text: "n\(step)", now: date)
            let fetched = try #require(try store.note(id: created.id))
            var rewrite = draft("unused")
            rewrite.modifiedAt = fetched.modifiedAt
            rewrite.isPinnedGlobal = false
            rewrite.isReadOnly = false
            _ = try store.applyImportedMetadata(noteID: created.id, draft: rewrite, expectedRevision: fetched.revision)
            let again = try #require(try store.note(id: created.id))
            #expect(again.modifiedAt == fetched.modifiedAt, "step \(step)")
            let decoded = try db.pool.read { db in
                try #require(try Date.fetchOne(db, sql: "SELECT ?", arguments: [NoteStore.roundedToMillis(date)]))
            }
            #expect(NoteStore.roundedToMillis(decoded) == NoteStore.roundedToMillis(date), "step \(step)")
        }
    }
}
