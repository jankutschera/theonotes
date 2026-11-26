// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import GRDB
@testable import TheoNotesCore

@Suite struct NoteOperationsTests {
    let tmp: TempPaths
    let db: AppDatabase
    let store: NoteStore
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let t1 = Date(timeIntervalSince1970: 1_800_000_100)

    init() throws {
        tmp = try TempPaths()
        db = try AppDatabase.inMemory()
        store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
    }

    private func reload(_ note: Note) throws -> Note {
        try #require(try store.note(id: note.id))
    }

    @Test func testTrashDoesNotChangeModifiedAt() throws {
        let note = try store.create(text: "One", now: t0)
        try store.trash([note.id], now: t1)
        let trashed = try reload(note)
        #expect(trashed.location == .trash)
        #expect(trashed.trashedAt == t1)
        #expect(trashed.modifiedAt == t0)
        #expect(trashed.revision == note.revision + 1)
        #expect(try store.allNotes(location: .trash).map(\.id) == [note.id])
        try store.restore([note.id])
        let restored = try reload(note)
        #expect(restored.location == .notes)
        #expect(restored.trashedAt == nil)
        #expect(restored.modifiedAt == t0)
        #expect(restored.revision == note.revision + 2)
    }

    @Test func testUnknownIdFailsWholeBatch() throws {
        let note = try store.create(text: "One")
        #expect(throws: StoreError.noteNotFound(id: "missing")) {
            try store.trash([note.id, "missing"])
        }
        #expect(try reload(note).location == .notes)
        #expect(try reload(note).revision == note.revision)
    }

    @Test func testRestoreFromArchive() throws {
        let a = try store.create(text: "A", now: t0)
        let b = try store.create(text: "B", now: t0)
        try store.archive([a.id, b.id], now: t1)
        #expect(try reload(a).location == .archive)
        #expect(try reload(a).archivedAt == t1)
        #expect(try reload(a).modifiedAt == t0)
        try store.restore([a.id])
        #expect(try reload(a).location == .notes)
        #expect(try reload(a).archivedAt == nil)
        #expect(try reload(b).location == .archive)
    }

    @Test func testGlobalAndTagPins() throws {
        let a = try store.create(text: "A\n#work/projects")
        let b = try store.create(text: "B\n#home")
        try store.setPinned([a.id, b.id], pinned: true, inTag: nil)
        #expect(try reload(a).isPinnedGlobal)
        #expect(try reload(b).isPinnedGlobal)
        #expect(try reload(a).revision == a.revision + 1)
        #expect(try reload(a).modifiedAt == a.modifiedAt)
        try store.setPinned([b.id], pinned: false, inTag: nil)
        #expect(try !reload(b).isPinnedGlobal)

        // Pin within a tag (ancestor rows count: a note tagged `work/projects` shows under `work`).
        try store.setPinned([a.id], pinned: true, inTag: "Work")
        let pins = try db.pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT tag.pathKey FROM note_pin JOIN tag ON tag.id = note_pin.tagId WHERE note_pin.noteId = ?
                """, arguments: [a.id])
        }
        #expect(pins == ["work"])
        #expect(try reload(a).isPinnedGlobal)
        #expect(throws: StoreError.tagNotFound(path: "nope")) {
            try store.setPinned([a.id], pinned: true, inTag: "nope")
        }
        #expect(throws: StoreError.noteNotTagged(id: b.id, tagPath: "work")) {
            try store.setPinned([b.id], pinned: true, inTag: "work")
        }
        try store.setPinned([a.id], pinned: false, inTag: "work")
        #expect(try db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note_pin") } == 0)
    }

    @Test func testEmptyTrashDeletesOnlyTrash() throws {
        let fm = FileManager.default
        let kept = try store.create(text: "Kept\n#keep")
        let gone = try store.create(text: "Gone\n#gone")
        let archived = try store.create(text: "Archived")
        for id in [kept.id, gone.id] {
            let dir = tmp.paths.attachments.appendingPathComponent(id, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("photo.jpg"))
            for name in ["\(id).jsonl", "\(id).base", "\(id).jsonl.unreplayed"] {
                try Data().write(to: tmp.paths.journal.appendingPathComponent(name))
            }
        }
        try store.archive([archived.id])
        try store.trash([gone.id])
        #expect(try store.emptyTrash() == 1)
        #expect(try store.note(id: gone.id) == nil)
        #expect(try store.note(id: kept.id) != nil)
        #expect(try store.note(id: archived.id) != nil)
        #expect(try allTagPaths(db) == ["keep"])
        #expect(!fm.fileExists(atPath: tmp.paths.attachments.appendingPathComponent(gone.id).path))
        #expect(fm.fileExists(atPath: tmp.paths.attachments.appendingPathComponent(kept.id).path))
        let journals = try fm.contentsOfDirectory(atPath: tmp.paths.journal.path).sorted()
        #expect(journals == ["\(kept.id).base", "\(kept.id).jsonl", "\(kept.id).jsonl.unreplayed"])
        #expect(try store.emptyTrash() == 0)
    }

    /// Empty Trash deletes what the user saw in the trash, never a note trashed after the list
    /// was read (its open session would be left behind), nor one restored meanwhile.
    @Test func testEmptyTrashDeletesOnlyListedNotesStillInTheTrash() throws {
        let listed = try store.create(text: "Listed")
        let restored = try store.create(text: "Restored")
        let late = try store.create(text: "Late")
        try store.trash([listed.id, restored.id])
        let ids = try store.allNotes(location: .trash).map(\.id)
        try store.restore([restored.id])
        try store.trash([late.id])
        #expect(try store.emptyTrash(ids: ids + ["unknown"]) == [listed.id])
        #expect(try store.note(id: listed.id) == nil)
        #expect(try store.note(id: restored.id)?.location == .notes)
        #expect(try store.note(id: late.id)?.location == .trash)
    }

    @Test func testDeletePermanently() throws {
        let a = try store.create(text: "A\n#x")
        let b = try store.create(text: "B")
        try store.deletePermanently([a.id])
        #expect(try store.note(id: a.id) == nil)
        #expect(try store.note(id: b.id) != nil)
        #expect(try allTagPaths(db).isEmpty)
        #expect(throws: StoreError.noteNotFound(id: a.id)) { try store.deletePermanently([b.id, a.id]) }
        #expect(try store.note(id: b.id) != nil)
    }

    @Test func testDuplicateCopiesText() throws {
        let fm = FileManager.default
        let source = try store.create(text: "Recipe\n#food\n![](photo.jpg)", now: t0)
        try store.setPinned([source.id], pinned: true, inTag: nil)
        let dir = tmp.paths.attachments.appendingPathComponent(source.id, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("img".utf8).write(to: dir.appendingPathComponent("photo.jpg"))

        let copy = try store.duplicate(id: source.id, now: t1)
        #expect(copy.id != source.id)
        #expect(copy.text == source.text)
        #expect(copy.title == "Recipe")
        #expect(copy.createdAt == t1)
        #expect(copy.revision == 1)
        #expect(copy.location == .notes)
        #expect(!copy.isPinnedGlobal)
        #expect(try tagRows(db, copy.id) == [TagRow(path: "food", isDirect: true)])
        let copied = tmp.paths.attachments.appendingPathComponent(copy.id).appendingPathComponent("photo.jpg")
        #expect(try Data(contentsOf: copied) == Data("img".utf8))
        #expect(throws: StoreError.noteNotFound(id: "missing")) { try store.duplicate(id: "missing") }
    }

    @Test func testAddTagBottomAndTop() throws {
        let a = try store.create(text: "Title\nbody", now: t0)
        let b = try store.create(text: "Other", now: t0)
        try store.addTag("work", to: [a.id, b.id], position: .bottom, now: t1)
        let aBottom = try reload(a)
        #expect(aBottom.text == "Title\nbody\n#work")
        #expect(aBottom.modifiedAt == t1)
        #expect(aBottom.revision == a.revision + 1)
        #expect(try reload(b).text == "Other\n#work")
        #expect(try tagRows(db, a.id) == [TagRow(path: "work", isDirect: true)])

        // Already present (any spelling): no rewrite, no revision bump.
        try store.addTag("WORK", to: [a.id], position: .bottom)
        #expect(try reload(a).revision == aBottom.revision)

        try store.addTag("home", to: [a.id], position: .top)
        #expect(try reload(a).text == "Title\n#home\nbody\n#work")

        // Top insertion goes after the title line, which is below YAML front matter.
        let fm = try store.create(text: "---\nkey: v\n---\nTitle")
        try store.addTag("x", to: [fm.id], position: .top)
        #expect(try reload(fm).text == "---\nkey: v\n---\nTitle\n#x")
        // Only a title line, an empty note, a BOM, front matter without a title line.
        let only = try store.create(text: "Only")
        try store.addTag("x", to: [only.id], position: .top)
        #expect(try reload(only).text == "Only\n#x")
        let empty = try store.create(text: "")
        try store.addTag("x", to: [empty.id], position: .top)
        #expect(try reload(empty).text == "\n#x")
        let bom = try store.create(text: "\u{FEFF}Title\nbody")
        try store.addTag("x", to: [bom.id], position: .top)
        #expect(try reload(bom).text == "\u{FEFF}Title\n#x\nbody")
        let bare = try store.create(text: "---\nkey: v\n---")
        try store.addTag("x", to: [bare.id], position: .top)
        #expect(try reload(bare).text == "---\nkey: v\n---\n#x")
        // The title stays the title.
        #expect(try reload(a).title == "Title")
    }

    @Test func testAddMultiWordTag() throws {
        let note = try store.create(text: "Title")
        try store.addTag("my tag", to: [note.id], position: .bottom)
        #expect(try reload(note).text == "Title\n#my tag#")
        try store.addTag("2021", to: [note.id], position: .bottom)
        #expect(try reload(note).text == "Title\n#my tag#\n#2021#")
        #expect(try tagRows(db, note.id).map(\.path) == ["2021", "my tag"])
        #expect(throws: StoreError.invalidTag(path: "  ")) {
            try store.addTag("  ", to: [note.id], position: .bottom)
        }
    }

    @Test func testRemoveTag() throws {
        let note = try store.create(text: "Title #work here\nbody\n#Work\n#home #work\n```\n#work in code\n```", now: t0)
        try store.removeTag("work", from: [note.id], now: t1)
        let updated = try reload(note)
        #expect(updated.text == "Title here\nbody\n#home\n```\n#work in code\n```")
        #expect(updated.modifiedAt == t1)
        #expect(try tagRows(db, note.id).map(\.path) == ["home"])
        #expect(try allTagPaths(db) == ["home"])

        let multi = try store.create(text: "T\n#my tag# rest")
        try store.removeTag("my tag", from: [multi.id])
        #expect(try reload(multi).text == "T\nrest")

        // Not present: untouched.
        let revision = try reload(multi).revision
        try store.removeTag("absent", from: [multi.id])
        #expect(try reload(multi).revision == revision)
    }

    /// Stored text may hold CRs (external writers bypass NoteStore normalisation).
    private func writeRaw(_ id: String, _ text: String) throws {
        try db.pool.write { db in
            try db.execute(sql: "UPDATE note SET text = ?, revision = revision + 1 WHERE id = ?", arguments: [text, id])
        }
    }

    @Test func testRemoveTagOnCRLFText() throws {
        let note = try store.create(text: "a\n#work")
        try writeRaw(note.id, "a\r\n#work\r\nend #work")
        try store.removeTag("work", from: [note.id])
        #expect(try reload(note).text == "a\nend")
    }

    @Test func testAddTagTopOnCRLFFrontMatter() throws {
        let note = try store.create(text: "Title")
        try writeRaw(note.id, "---\r\nkey: v\r\n---\r\nTitle")
        try store.addTag("x", to: [note.id], position: .top)
        #expect(try reload(note).text == "---\nkey: v\n---\nTitle\n#x")
    }
}
