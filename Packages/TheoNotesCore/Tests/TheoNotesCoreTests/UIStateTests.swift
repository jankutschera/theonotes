// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// M6 Task 8: fold state in `note_ui_state`, never note content.
@Suite struct UIStateTests {
    let tmp: TempPaths
    let db: AppDatabase
    let store: NoteStore
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        tmp = try TempPaths()
        db = try AppDatabase.inMemory()
        store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
    }

    private func entry(_ line: Int, _ hash: String) throws -> FoldEntry { try #require(FoldEntry(line: line, hash: hash)) }

    @Test func testFoldStateRoundTrip() throws {
        let note = try store.create(text: "# A\ntext\n# B\nmore", now: t0)
        #expect(try store.foldState(noteId: note.id).isEmpty)
        let folds = [try entry(1, "0a1b2c3d"), try entry(3, "ffffffff")]
        try store.setFoldState(noteId: note.id, folds)
        #expect(try store.foldState(noteId: note.id) == folds)
        // Replaced, not appended; an empty list clears.
        try store.setFoldState(noteId: note.id, [try entry(3, "ffffffff")])
        #expect(try store.foldState(noteId: note.id) == [try entry(3, "ffffffff")])
        try store.setFoldState(noteId: note.id, [])
        #expect(try store.foldState(noteId: note.id).isEmpty)
        // Hashes and lines only: no note text in the row.
        try store.setFoldState(noteId: note.id, folds)
        let stored = try db.pool.read { try String.fetchOne($0, sql: "SELECT foldState FROM note_ui_state WHERE noteId = ?", arguments: [note.id]) }
        #expect(stored?.contains("text") == false && stored?.contains("# A") == false)
    }

    /// Review Focus 5: folding is not an edit.
    @Test func testFoldingNeverBumpsRevisionOrModifiedAt() async throws {
        // A private channel: the shared one also carries other tests' (and a running app's) posts.
        let notifier = ChangeNotifier(name: "com.truebrewbirdie.baerchen.test.\(UUID().uuidString)")
        let observed = NoteStore(db: db, notifier: notifier, paths: tmp.paths)
        let note = try observed.create(text: "# A\ntext", now: t0)
        let before = try #require(try observed.note(id: note.id))
        let posts = Posts()
        let token = notifier.observe { posts.add() }
        defer { token.cancel() }
        try observed.setFoldState(noteId: note.id, [try entry(1, "0a1b2c3d")])
        let after = try #require(try observed.note(id: note.id))
        #expect(after.revision == before.revision)
        #expect(after.modifiedAt == before.modifiedAt)
        #expect(after.text == before.text)
        // Darwin notifications arrive asynchronously: give a stray one time to show up.
        try await Task.sleep(for: .milliseconds(300))
        #expect(posts.count == 0)
    }

    @Test func testFoldStateIsDeletedWithTheNote() throws {
        let note = try store.create(text: "# A\ntext", now: t0)
        try store.setFoldState(noteId: note.id, [try entry(1, "0a1b2c3d")])
        try store.trash([note.id])
        try store.deletePermanently([note.id])
        let rows = try db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note_ui_state WHERE noteId = ?", arguments: [note.id]) }
        #expect(rows == 0)
        // A note that is gone stores nothing.
        try store.setFoldState(noteId: note.id, [try entry(1, "0a1b2c3d")])
        #expect(try store.foldState(noteId: note.id).isEmpty)
    }

    /// Final review M3: line hashes of a locked note's headings are metadata about its
    /// text, so a locked note keeps no fold state: a write stores nothing and clears an older row,
    /// a read returns none.
    @Test func testLockedNotesKeepNoFoldState() throws {
        let note = try store.create(text: "# Secret plan\ntext", now: t0)
        try store.setFoldState(noteId: note.id, [try entry(1, "0a1b2c3d")])
        try db.pool.write { try $0.execute(sql: "UPDATE note SET isLocked = 1 WHERE id = ?", arguments: [note.id]) }
        let rows = { try self.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note_ui_state WHERE noteId = ?", arguments: [note.id]) } }
        // A row written before the lock is never handed out.
        #expect(try store.foldState(noteId: note.id).isEmpty)
        // A write while locked stores nothing and removes the old row.
        try store.setFoldState(noteId: note.id, [try entry(1, "ffffffff")])
        #expect(try rows() == 0)
        #expect(try store.foldState(noteId: note.id).isEmpty)
        // Unlocked again, folds are stored as before.
        try db.pool.write { try $0.execute(sql: "UPDATE note SET isLocked = 0 WHERE id = ?", arguments: [note.id]) }
        try store.setFoldState(noteId: note.id, [try entry(1, "ffffffff")])
        #expect(try store.foldState(noteId: note.id) == [try entry(1, "ffffffff")])
    }

    @Test func testInvalidJSONReadsAsEmpty() throws {
        let note = try store.create(text: "# A", now: t0)
        for json in ["not json", "{}", "[{\"line\":0,\"hash\":\"zz\"}]", "null"] {
            try db.pool.write {
                try $0.execute(
                    sql: "INSERT INTO note_ui_state (noteId, foldState) VALUES (?, ?) ON CONFLICT(noteId) DO UPDATE SET foldState = excluded.foldState",
                    arguments: [note.id, json])
            }
            #expect(try store.foldState(noteId: note.id).isEmpty, "\(json)")
        }
        // Valid entries survive next to invalid ones.
        try db.pool.write {
            try $0.execute(
                sql: "UPDATE note_ui_state SET foldState = ? WHERE noteId = ?",
                arguments: ["[{\"line\":0,\"hash\":\"zz\"},{\"line\":2,\"hash\":\"0a1b2c3d\"}]", note.id])
        }
        #expect(try store.foldState(noteId: note.id) == [try entry(2, "0a1b2c3d")])
    }
}

private final class Posts: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}
