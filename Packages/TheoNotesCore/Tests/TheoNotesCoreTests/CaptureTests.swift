// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct CaptureTests {
    private static func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + seconds) }

    @Test func createRecordsTheSource() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        for source in CaptureSource.allCases {
            let note = try library.store.create(text: "# \(source.rawValue)", captureSource: source)
            #expect(try library.store.captureSource(noteId: note.id) == source)
        }
    }

    @Test func ordinaryCreateLeavesItNull() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Plain")
        let explicit = try library.store.create(text: "# Plain", captureSource: nil)
        #expect(try library.store.captureSource(noteId: note.id) == nil)
        #expect(try library.store.captureSource(noteId: explicit.id) == nil)
        #expect(try library.store.captureSource(noteId: "missing") == nil)
    }

    @Test func recordOpenedNeverTouchesTheNote() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Plan", now: Self.at(0), captureSource: .share)
        let before = try #require(try library.store.note(id: note.id))
        #expect(try library.store.lastOpenedAt(noteId: note.id) == nil)

        try library.store.recordOpened(noteId: note.id, now: Self.at(100))
        #expect(try library.store.lastOpenedAt(noteId: note.id) == Self.at(100))
        try library.store.recordOpened(noteId: note.id, now: Self.at(200))
        #expect(try library.store.lastOpenedAt(noteId: note.id) == Self.at(200))

        #expect(try library.store.note(id: note.id) == before)
        #expect(try library.store.captureSource(noteId: note.id) == .share)
        // Writing the other editor state keeps the timestamp, and the other way round.
        try library.store.saveEditorState(noteID: note.id, scrollTop: 40)
        try library.store.setFoldState(noteId: note.id, [])
        #expect(try library.store.lastOpenedAt(noteId: note.id) == Self.at(200))
        try library.store.recordOpened(noteId: note.id, now: Self.at(300))
        #expect(try library.store.editorState(noteID: note.id).scrollTop == 40)
    }

    @Test func recordOpenedIgnoresLockedNotes() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Secret")
        try library.store.recordOpened(noteId: note.id, now: Self.at(1))
        let access = try library.access(); defer { access.revoke() }

        try access.lock(noteId: note.id)
        #expect(try library.store.lastOpenedAt(noteId: note.id) == nil)
        try library.store.recordOpened(noteId: note.id, now: Self.at(2))
        #expect(try library.store.lastOpenedAt(noteId: note.id) == nil)
        let rows = try library.db.pool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note_ui_state WHERE noteId = ?", arguments: [note.id])
        }
        #expect(rows == 0)

        try library.store.recordOpened(noteId: "missing", now: Self.at(3))
        #expect(try library.store.lastOpenedAt(noteId: "missing") == nil)
    }

    @Test func recordOpenedAndCancelIgnoreDeletedNotes() throws {
        let library = try SyncMaterializerTests.Library(); defer { library.cleanup() }
        func uiStateRows(_ id: String) throws -> Int {
            try library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note_ui_state WHERE noteId = ?", arguments: [id]) ?? 0 }
        }
        func wire(_ id: String) throws -> Data? {
            try library.db.pool.read { try SyncNotePayload.capture(id: id, includeRetained: true, in: $0) }
                .map { try SyncPayloadCodec.encoder().encode($0) }
        }

        // A tombstoned note: the row is still there, `deletedAt` is set.
        let tombstoned = try library.store.create(text: "# Gone", captureSource: .share)
        try library.db.pool.write {
            try $0.execute(sql: "UPDATE note SET deletedAt = ? WHERE id = ?", arguments: [Self.at(1), tombstoned.id])
            try $0.execute(sql: "DELETE FROM sync_dirty")
        }
        let rowBefore = try #require(try library.store.note(id: tombstoned.id))
        let wireBefore = try wire(tombstoned.id)

        try library.store.recordOpened(noteId: tombstoned.id, now: Self.at(2))
        #expect(try library.store.cancelCapture(noteId: tombstoned.id, createdText: "# Gone", now: Self.at(3)) == false)

        #expect(try uiStateRows(tombstoned.id) == 0)
        #expect(try library.store.lastOpenedAt(noteId: tombstoned.id) == nil)
        #expect(try library.store.note(id: tombstoned.id) == rowBefore)
        #expect(try wire(tombstoned.id) == wireBefore)
        #expect(try library.queue.pendingCount() == 0)

        // A note deleted through the store: the row is gone.
        let deleted = try library.store.create(text: "# Deleted", captureSource: .voice)
        try library.store.deletePermanently([deleted.id])
        try library.db.pool.write { try $0.execute(sql: "DELETE FROM sync_dirty") }

        try library.store.recordOpened(noteId: deleted.id, now: Self.at(4))
        #expect(try library.store.cancelCapture(noteId: deleted.id, createdText: "# Deleted", now: Self.at(5)) == false)

        #expect(try library.store.note(id: deleted.id) == nil)
        #expect(try uiStateRows(deleted.id) == 0)
        #expect(try library.queue.pendingCount() == 0)
    }

    @Test func cancelTrashesAnUntouchedCapture() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "", captureSource: .lockscreen)

        #expect(try library.store.cancelCapture(noteId: note.id, createdText: "", now: Self.at(5)))

        let trashed = try #require(try library.store.note(id: note.id))
        #expect(trashed.location == .trash && trashed.trashedAt != nil)
        #expect(trashed.revision == note.revision + 1)
        // Already in the Trash: nothing more to do.
        #expect(try library.store.cancelCapture(noteId: note.id, createdText: "", now: Self.at(6)) == false)
    }

    @Test func cancelKeepsAnEditedCapture() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Voice", captureSource: .voice)
        let edited = try library.store.updateText(id: note.id, text: "# Voice\nmore", expectedRevision: note.revision)

        #expect(try library.store.cancelCapture(noteId: note.id, createdText: "# Voice") == false)

        #expect(try library.store.note(id: note.id) == edited)
        // CRLF in `createdText` is compared the way the store wrote it.
        let crlf = try library.store.create(text: "a\r\nb", captureSource: .share)
        #expect(try library.store.cancelCapture(noteId: crlf.id, createdText: "a\r\nb"))
    }

    @Test func cancelNeverTrashesAnOrdinaryNote() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Mine")

        #expect(try library.store.cancelCapture(noteId: note.id, createdText: "# Mine") == false)
        #expect(try library.store.cancelCapture(noteId: "missing", createdText: "") == false)

        #expect(try library.store.note(id: note.id) == note)
    }

    @Test func listItemsCarryTheSource() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let captured = try library.store.create(text: "# Zebra capture", captureSource: .mcp)
        let plain = try library.store.create(text: "# Zebra plain")
        let (items, found) = try library.db.pool.read { db -> ([NoteListItem], SearchResult) in
            let items = try LibraryQueries.notes(
                in: .notes, sort: .modifiedDescending, now: .now, calendar: .current, db: db)
            let found = try LibraryQueries.search(
                "zebra", in: .notes, sort: .modifiedDescending, now: .now, calendar: .current, db: db)
            return (items, found)
        }
        #expect(items.first { $0.id == captured.id }?.captureSource == .mcp)
        #expect(items.first { $0.id == plain.id }?.captureSource == nil)
        #expect(found.items.first { $0.id == captured.id }?.captureSource == .mcp)
        #expect(found.items.first { $0.id == plain.id }?.captureSource == nil)
    }

    @Test func remoteUpdateKeepsTheLocalCaptureSource() throws {
        let library = try SyncMaterializerTests.Library(enabled: false); defer { library.cleanup() }
        let note = try library.store.create(text: "# Local", captureSource: .shortcut)
        try library.store.recordOpened(noteId: note.id, now: Self.at(7))
        var incoming = library.payload("# Remote edit", id: note.id)
        incoming.modifiedAt = Int64(Self.at(50).timeIntervalSince1970 * 1000)

        let files = AttachmentFiles(paths: library.paths, database: library.db)
        var staged: [AttachmentFiles.Staged] = []
        try library.db.pool.write { db in
            try library.materializer().writeNote(incoming, downloads: [], copying: false, files: files, staged: &staged, in: db)
        }
        for batch in staged { files.install(batch) }

        #expect(try library.store.note(id: note.id)?.text == "# Remote edit")
        #expect(try library.store.captureSource(noteId: note.id) == .shortcut)
        #expect(try library.store.lastOpenedAt(noteId: note.id) == Self.at(7))
    }
}
