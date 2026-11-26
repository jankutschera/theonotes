// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import GRDB
@testable import TheoNotesCore

@Suite struct NoteStoreTests {
    let tmp: TempPaths
    init() throws { tmp = try TempPaths() }

    private func tempDB() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("baerchen-store-\(UUID().uuidString).sqlite")
    }

    @Test func testCreateAndFetch() throws {
        let store = NoteStore(db: try .inMemory(), notifier: nil, paths: tmp.paths)
        let note = try store.create(text: "## Hello\nbody")
        #expect(note.revision == 1)
        #expect(note.title == "Hello")
        #expect(note.titleKey == "hello")
        #expect(note.location == .notes)
        let uuid = try #require(UUID(uuidString: note.id))
        #expect(uuid.uuid.6 >> 4 == 7)
        let fetched = try #require(try store.note(id: note.id)); #expect(fetched == note)
        #expect(try store.allNotes().count == 1)
        #expect(try store.allNotes(location: .trash).isEmpty)
    }

    @Test func testUpdateIncrementsRevision() throws {
        let store = NoteStore(db: try .inMemory(), notifier: nil, paths: tmp.paths)
        let note = try store.create(text: "a")
        let updated = try store.updateText(id: note.id, text: "# Äpfel\nx", expectedRevision: 1)
        #expect(updated.revision == 2)
        #expect(updated.text == "# Äpfel\nx")
        #expect(updated.title == "Äpfel")
        #expect(try store.note(id: note.id)?.revision == 2)
    }

    @Test func testCreateAndUpdateNormalizeLineEndings() throws {
        let store = NoteStore(db: try .inMemory(), notifier: nil, paths: tmp.paths)
        let note = try store.create(text: "# Title\r\nbody\rmore")
        #expect(note.text == "# Title\nbody\nmore")
        #expect(note.title == "Title")
        let updated = try store.updateText(id: note.id, text: "New\r\n漢字\r\n", expectedRevision: note.revision)
        #expect(updated.text == "New\n漢字\n")
        #expect(updated.title == "New")
    }

    @Test func testOptimisticConcurrencyRejectsStaleRevision() throws {
        let store = NoteStore(db: try .inMemory(), notifier: nil, paths: tmp.paths)
        let note = try store.create(text: "a")
        _ = try store.updateText(id: note.id, text: "b", expectedRevision: 1)
        #expect(throws: StoreError.revisionConflict(current: 2)) {
            try store.updateText(id: note.id, text: "c", expectedRevision: 1)
        }
        #expect(try store.note(id: note.id)?.text == "b")
    }

    @Test func testTwoPoolsSeeEachOthersWrites() throws {
        let url = tempDB()
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
        let storeA = NoteStore(db: try AppDatabase(path: url), notifier: nil, paths: tmp.paths)
        let storeB = NoteStore(db: try AppDatabase(path: url), notifier: nil, paths: tmp.paths)
        let note = try storeA.create(text: "one")
        #expect(try storeB.note(id: note.id)?.text == "one")
        _ = try storeA.updateText(id: note.id, text: "two", expectedRevision: 1)
        #expect(try storeB.note(id: note.id)?.text == "two")
        #expect(throws: StoreError.revisionConflict(current: 2)) {
            try storeB.updateText(id: note.id, text: "x", expectedRevision: 1)
        }
    }

    @Test func testUUIDv7Sortable() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let a = UUIDv7.make(now: t0)
        let b = UUIDv7.make(now: t0.addingTimeInterval(0.002))
        #expect(a < b)
        #expect(a.count == 36)
        #expect(a == a.lowercased())
    }

    @Test func testPragmas() throws {
        let url = tempDB()
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
        let db = try AppDatabase(path: url)
        let (mode, fk, secure) = try db.pool.read { d in
            (try String.fetchOne(d, sql: "PRAGMA journal_mode"),
             try Int.fetchOne(d, sql: "PRAGMA foreign_keys"),
             try Int.fetchOne(d, sql: "PRAGMA secure_delete"))
        }
        #expect(mode == "wal")
        #expect(fk == 1)
        #expect(secure == 1)
    }
}

@Suite struct NoteStoreObservationTests {
    let tmp: TempPaths
    init() throws { tmp = try TempPaths() }

    @Test func testNotesObservationEmitsNewestModifiedFirst() async throws {
        let db = try AppDatabase.inMemory()
        let store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
        let older = try store.create(text: "older", now: Date(timeIntervalSince1970: 1_000))
        let newer = try store.create(text: "newer", now: Date(timeIntervalSince1970: 2_000))
        var iterator = store.notesObservation(location: .notes).values(in: db.pool).makeAsyncIterator()
        let first = try #require(try await iterator.next())
        #expect(first.map(\.id) == [newer.id, older.id])
        _ = try store.updateText(id: older.id, text: "older edited", expectedRevision: 1, now: Date(timeIntervalSince1970: 3_000))
        let second = try #require(try await iterator.next())
        #expect(second.map(\.id) == [older.id, newer.id])
    }

    @Test func testRevisionReadsCurrentRevision() throws {
        let store = NoteStore(db: try .inMemory(), notifier: nil, paths: tmp.paths)
        let note = try store.create(text: "a")
        #expect(try store.revision(id: note.id) == 1)
        try store.trash([note.id])
        #expect(try store.revision(id: note.id) == 2)
        #expect(try store.revision(id: "missing") == nil)
    }

    // MARK: - preservingModifiedDate (CLI/MCP `--no-update-modified`)

    @Test func testUpdateTextPreservingModifiedDateKeepsDateButBumpsRevisionAndIndex() throws {
        let store = NoteStore(db: try .inMemory(), notifier: nil, paths: tmp.paths)
        let t0 = Date(timeIntervalSince1970: 1_000), t1 = Date(timeIntervalSince1970: 2_000)
        let note = try store.create(text: "old", now: t0)
        let kept = try store.updateText(
            id: note.id, text: "# New title\n#fresh", expectedRevision: 1, now: t1, preservingModifiedDate: true)
        #expect(kept.revision == 2 && kept.modifiedAt == t0 && kept.title == "New title")
        let tags = try store.db.pool.read { try String.fetchAll($0, sql: "SELECT t.pathKey FROM note_tag nt JOIN tag t ON t.id = nt.tagId WHERE nt.noteId = ?", arguments: [note.id]) }
        #expect(tags == ["fresh"])
        let moved = try store.updateText(id: note.id, text: "again", expectedRevision: 2, now: t1)
        #expect(moved.modifiedAt == t1)
    }

    @Test func testTagOperationsPreservingModifiedDate() throws {
        let store = NoteStore(db: try .inMemory(), notifier: nil, paths: tmp.paths)
        let t0 = Date(timeIntervalSince1970: 1_000), t1 = Date(timeIntervalSince1970: 2_000)
        let note = try store.create(text: "# T\n#a", now: t0)
        try store.addTag("b", to: [note.id], position: .bottom, now: t1, preservingModifiedDate: true)
        #expect(try store.note(id: note.id)?.modifiedAt == t0)
        try store.removeTag("b", from: [note.id], now: t1, preservingModifiedDate: true)
        #expect(try store.note(id: note.id)?.modifiedAt == t0)
        try store.renameTag("a", to: "c", now: t1, preservingModifiedDate: true)
        let renamed = try #require(try store.note(id: note.id))
        #expect(renamed.modifiedAt == t0 && renamed.text.contains("#c"))
        try store.deleteTag("c", now: t1, preservingModifiedDate: true)
        let deleted = try #require(try store.note(id: note.id))
        #expect(deleted.modifiedAt == t0 && !deleted.text.contains("#c") && deleted.revision == 5)
        // Without the flag the date moves, as before.
        try store.addTag("d", to: [note.id], position: .bottom, now: t1)
        #expect(try store.note(id: note.id)?.modifiedAt == t1)
    }
}
