// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import GRDB
@testable import TheoNotesCore

@Suite struct TagManagementTests {
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

    private func text(_ note: Note) throws -> String {
        try #require(try store.note(id: note.id)).text
    }

    private struct TagMeta: Equatable {
        var path: String
        var icon: String?
        var pinned: Bool
    }

    private func tagMeta() throws -> [TagMeta] {
        try db.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT displayPath, iconName, isPinned FROM tag ORDER BY pathKey")
                .map { TagMeta(path: $0[0], icon: $0[1], pinned: $0[2]) }
        }
    }

    private func setReadOnly(_ note: Note) throws {
        try db.pool.write { try $0.execute(sql: "UPDATE note SET isReadOnly = 1 WHERE id = ?", arguments: [note.id]) }
    }

    private func lock(_ note: Note) throws {
        try db.pool.write { try $0.execute(sql: "UPDATE note SET isLocked = 1 WHERE id = ?", arguments: [note.id]) }
    }

    // MARK: - Rename (Review Focus #3)

    @Test func testRenameRewritesTagAndDescendantsButNotPrefixWords() throws {
        let note = try store.create(text: """
            ---
            tags: #work
            ---
            Title #work and #workshop
            #work/projects #Work/Projects/x (#work)
            Inline `#work` code
            ```
            #work
            ```
            <!-- #work -->
            $$
            #work
            $$
            end #work.
            """, now: t0)
        let result = try store.renameTag("work", to: "job", now: t1)
        #expect(try text(note) == """
            ---
            tags: #work
            ---
            Title #job and #workshop
            #job/projects #job/Projects/x (#job)
            Inline `#work` code
            ```
            #work
            ```
            <!-- #work -->
            $$
            #work
            $$
            end #job.
            """)
        #expect(result.changedNoteIds == [note.id])
        #expect(result.skippedLocked.isEmpty)
        let updated = try #require(try store.note(id: note.id))
        #expect(updated.modifiedAt == t1)
        #expect(try allTagPaths(db) == ["job", "job/projects", "job/Projects/x", "workshop"])
    }

    @Test func testRenameMultiWordAndClosedForms() throws {
        let note = try store.create(text: "T\n#my tag# here #my tag/sub# and #My  Tag#")
        try store.renameTag("my tag", to: "our tag")
        #expect(try text(note) == "T\n#our tag# here #our tag/sub# and #our tag#")

        // Closed → open when the new name allows it.
        try store.renameTag("our tag", to: "single")
        #expect(try text(note) == "T\n#single here #single/sub and #single")

        // Open → closed for multi-word and number-only names.
        try store.renameTag("single", to: "two words")
        #expect(try text(note) == "T\n#two words# here #two words/sub# and #two words#")
        try store.renameTag("two words", to: "2024")
        #expect(try text(note) == "T\n#2024# here #2024/sub and #2024#")
    }

    @Test func testRenameIntoNestedPathNests() throws {
        let note = try store.create(text: "A #tag2 and #tag2/deep")
        try store.renameTag("tag2", to: "tag1/tag2")
        #expect(try text(note) == "A #tag1/tag2 and #tag1/tag2/deep")
        #expect(try allTagPaths(db) == ["tag1", "tag1/tag2", "tag1/tag2/deep"])
    }

    @Test func testRenameMergesIntoExistingTag() throws {
        let a = try store.create(text: "A #work")
        let b = try store.create(text: "B #job")
        let result = try store.renameTag("work", to: "job")
        #expect(result.changedNoteIds == [a.id])
        #expect(try text(a) == "A #job")
        #expect(try text(b) == "B #job")
        #expect(try allTagPaths(db) == ["job"])
        let tree = try db.pool.read { try LibraryQueries.tagTree(db: $0) }
        #expect(tree.map(\.noteCount) == [2])
    }

    @Test func testRenameCaseOnlyUpdatesSpelling() throws {
        let note = try store.create(text: "A #work and #work/sub")
        try store.renameTag("work", to: "Work")
        #expect(try text(note) == "A #Work and #Work/sub")
        #expect(try allTagPaths(db) == ["Work", "Work/sub"])
    }

    @Test func testRenameAcrossNotesAndLocations() throws {
        let a = try store.create(text: "A #work")
        let b = try store.create(text: "B #work/x")
        let c = try store.create(text: "C #home")
        try store.archive([b.id])
        let result = try store.renameTag("work", to: "job")
        #expect(Set(result.changedNoteIds) == [a.id, b.id])
        #expect(result.previousTexts == [a.id: "A #work", b.id: "B #work/x"])
        #expect(try text(b) == "B #job/x")
        #expect(try text(c) == "C #home")
    }

    @Test func testRenameHandlesBOMAndCRLF() throws {
        let note = try store.create(text: "x")
        try db.pool.write { db in
            try db.execute(sql: "UPDATE note SET text = ? WHERE id = ?", arguments: ["\u{FEFF}#work title\r\nbody #work", note.id])
            try NoteIndexer.index(noteId: note.id, text: "\u{FEFF}#work title\r\nbody #work", in: db)
        }
        try store.renameTag("work", to: "job")
        #expect(try text(note) == "\u{FEFF}#job title\nbody #job")
    }

    @Test func testRenameMovesIconAndPin() throws {
        _ = try store.create(text: "A #work #work/child")
        try store.setTagIcon("work", symbol: "hammer")
        try store.setTagIcon("work/child", symbol: "leaf")
        try store.setTagPinned("work", pinned: true)
        try store.renameTag("work", to: "job")
        #expect(try tagMeta() == [
            TagMeta(path: "job", icon: "hammer", pinned: true),
            TagMeta(path: "job/child", icon: "leaf", pinned: false),
        ])

        // A nested target cannot be pinned: the pin is dropped, the icon kept.
        try store.renameTag("job", to: "area/job")
        #expect(try tagMeta() == [
            TagMeta(path: "area", icon: nil, pinned: false),
            TagMeta(path: "area/job", icon: "hammer", pinned: false),
            TagMeta(path: "area/job/child", icon: "leaf", pinned: false),
        ])
    }

    @Test func testRenameKeepsTargetIconOnMerge() throws {
        _ = try store.create(text: "A #work")
        _ = try store.create(text: "B #job")
        try store.setTagIcon("work", symbol: "hammer")
        try store.setTagIcon("job", symbol: "briefcase")
        try store.renameTag("work", to: "job")
        #expect(try tagMeta() == [TagMeta(path: "job", icon: "briefcase", pinned: false)])
    }

    @Test func testRenameMovesPerTagNotePins() throws {
        let a = try store.create(text: "A #work")
        try store.setPinned([a.id], pinned: true, inTag: "work")
        try store.renameTag("work", to: "job")
        let pinned = try db.pool.read {
            try LibraryQueries.notes(in: .tag("job"), sort: .modifiedDescending, now: t1, calendar: .current, db: $0)
        }
        #expect(pinned.map(\.isPinned) == [true])
    }

    @Test func testRenameSkipsLockedNotes() throws {
        let open = try store.create(text: "A #work")
        let locked = try store.create(text: "L #work")
        try lock(locked)
        try store.setTagIcon("work", symbol: "hammer")
        let result = try store.renameTag("work", to: "job")
        #expect(result.changedNoteIds == [open.id])
        #expect(result.skippedLocked == [locked.id])
        #expect(try text(locked) == "L #work")
        #expect(try text(open) == "A #job")
        // The old tag still has a (locked) note, so it keeps its icon; the new one gets a copy.
        #expect(try tagMeta() == [
            TagMeta(path: "job", icon: "hammer", pinned: false),
            TagMeta(path: "work", icon: "hammer", pinned: false),
        ])
    }

    @Test func testRenameErrors() throws {
        _ = try store.create(text: "A #work")
        #expect(throws: StoreError.tagNotFound(path: "absent")) { try store.renameTag("absent", to: "x") }
        #expect(throws: StoreError.invalidTag(path: " / ")) { try store.renameTag("work", to: " / ") }
        // Same name: nothing to do.
        let result = try store.renameTag("work", to: "work")
        #expect(result.changedNoteIds.isEmpty)
    }

    @Test func testRenamedTagPath() {
        #expect(NoteStore.renamedTagPath("work", from: "Work", to: "job") == "job")
        #expect(NoteStore.renamedTagPath("work/Sub/x", from: "work", to: "a/job") == "a/job/Sub/x")
        #expect(NoteStore.renamedTagPath("workshop", from: "work", to: "job") == nil)
        #expect(NoteStore.renamedTagPath("home", from: "work", to: "job") == nil)
    }

    // MARK: - Undo

    @Test func testUndoRenameRestoresTextsAndTagState() throws {
        let a = try store.create(text: "A #work #work/x")
        let b = try store.create(text: "B #work")
        try store.setTagIcon("work", symbol: "hammer")
        try store.setTagPinned("work", pinned: true)
        try store.setPinned([a.id], pinned: true, inTag: "work")
        let before = try tagMeta()
        let result = try store.renameTag("work", to: "job")

        let restored = try store.undoTagRewrite(result)
        #expect(Set(restored) == [a.id, b.id])
        #expect(try text(a) == "A #work #work/x")
        #expect(try text(b) == "B #work")
        #expect(try tagMeta() == before)
        let items = try db.pool.read {
            try LibraryQueries.notes(in: .tag("work"), sort: .modifiedDescending, now: t1, calendar: .current, db: $0)
        }
        #expect(items.first { $0.id == a.id }?.isPinned == true)
    }

    @Test func testUndoSkipsNotesEditedSinceTheRewrite() throws {
        let a = try store.create(text: "A #work")
        let b = try store.create(text: "B #work")
        let result = try store.renameTag("work", to: "job")
        let edited = try #require(try store.note(id: b.id))
        _ = try store.updateText(id: b.id, text: "B #job edited", expectedRevision: edited.revision)
        let restored = try store.undoTagRewrite(result)
        #expect(restored == [a.id])
        #expect(try text(a) == "A #work")
        #expect(try text(b) == "B #job edited")
    }

    // MARK: - Delete

    @Test func testDeleteRemovesTagAndDescendantsAndEmptyLines() throws {
        let note = try store.create(text: "Title\n#work\nbody #work/x more #workshop\n#home #Work\n`#work`")
        let other = try store.create(text: "Other #home")
        try store.setTagPinned("work", pinned: true)
        try store.setTagIcon("work", symbol: "hammer")
        let result = try store.deleteTag("work", now: t1)
        #expect(try text(note) == "Title\nbody more #workshop\n#home\n`#work`")
        #expect(try text(other) == "Other #home")
        #expect(result.changedNoteIds == [note.id])
        #expect(result.previousTexts[note.id] == "Title\n#work\nbody #work/x more #workshop\n#home #Work\n`#work`")
        #expect(try allTagPaths(db) == ["home", "workshop"])

        _ = try store.undoTagRewrite(result)
        #expect(try text(note).hasPrefix("Title\n#work\n"))
        #expect(try tagMeta().contains(TagMeta(path: "work", icon: "hammer", pinned: true)))
    }

    @Test func testDeleteSkipsLockedNotes() throws {
        let locked = try store.create(text: "L #work")
        try lock(locked)
        let result = try store.deleteTag("work")
        #expect(result.skippedLocked == [locked.id])
        #expect(result.changedNoteIds.isEmpty)
        #expect(try text(locked) == "L #work")
        #expect(throws: StoreError.tagNotFound(path: "nope")) { try store.deleteTag("nope") }
    }

    // MARK: - Icons and pins

    @Test func testSetTagPinnedRootOnly() throws {
        let note = try store.create(text: "A #work/sub")
        #expect(throws: StoreError.tagNotRoot(path: "work/sub")) { try store.setTagPinned("work/sub", pinned: true) }
        try store.setTagPinned("work", pinned: true)
        // A pinned tag stays when its notes leave it.
        try store.deletePermanently([note.id])
        #expect(try tagMeta() == [TagMeta(path: "work", icon: nil, pinned: true)])
        try store.setTagPinned("work", pinned: false)
        #expect(try tagMeta().isEmpty)
        #expect(throws: StoreError.tagNotFound(path: "work")) { try store.setTagPinned("work", pinned: true) }
    }

    @Test func testSetTagIcon() throws {
        _ = try store.create(text: "A #Work")
        try store.setTagIcon("work", symbol: "hammer")
        #expect(try tagMeta() == [TagMeta(path: "Work", icon: "hammer", pinned: false)])
        try store.setTagIcon("WORK", symbol: nil)
        #expect(try tagMeta() == [TagMeta(path: "Work", icon: nil, pinned: false)])
        #expect(throws: StoreError.tagNotFound(path: "nope")) { try store.setTagIcon("nope", symbol: "x") }
    }

    @Test func testNoteCountForTagCountsNotesARewriteChanges() throws {
        _ = try store.create(text: "A #work")
        _ = try store.create(text: "B #work/x")
        let locked = try store.create(text: "L #work")
        try lock(locked)
        let readOnly = try store.create(text: "R #work")
        try setReadOnly(readOnly)
        let trashed = try store.create(text: "T #work")
        try store.trash([trashed.id])
        let archived = try store.create(text: "Ar #work")
        try store.archive([archived.id])
        _ = try store.create(text: "C #workshop")
        #expect(try store.noteCount(forTag: "work") == 3)
    }

    // MARK: - Fix round 1

    @Test func testRenameIntoOwnSubtreeIsRefused() throws {
        let note = try store.create(text: "A #work")
        try store.setTagIcon("work", symbol: "hammer")
        #expect(throws: StoreError.tagIntoOwnSubtree(path: "work", target: "Work/sub")) {
            try store.renameTag("work", to: "Work/sub")
        }
        #expect(try text(note) == "A #work")
        #expect(try tagMeta() == [TagMeta(path: "work", icon: "hammer", pinned: false)])
        #expect(NoteStore.isRenameIntoOwnSubtree("work", to: "Work/sub"))
        #expect(!NoteStore.isRenameIntoOwnSubtree("work", to: "workshop/sub"))
        #expect(!NoteStore.isRenameIntoOwnSubtree("work", to: "WORK"))
        #expect(!NoteStore.isRenameIntoOwnSubtree("a/work", to: "a"))
    }

    @Test func testUndoAfterEveryNoteWasEditedLeavesNoEmptyPinnedTag() throws {
        let a = try store.create(text: "A #work")
        try store.setTagPinned("work", pinned: true)
        let result = try store.renameTag("work", to: "job")
        let renamed = try #require(try store.note(id: a.id))
        _ = try store.updateText(id: a.id, text: "A #job edited", expectedRevision: renamed.revision)
        #expect(try store.undoTagRewrite(result).isEmpty)
        // The pin stays where the notes are.
        #expect(try tagMeta() == [TagMeta(path: "job", icon: nil, pinned: true)])
    }

    @Test func testUndoKeepsAPinnedTagThatHadNoNotes() throws {
        let a = try store.create(text: "A #work")
        _ = try store.create(text: "B #home")
        try store.setTagPinned("work", pinned: true)
        try store.deletePermanently([a.id])
        let result = try store.renameTag("work", to: "job")
        #expect(try tagMeta().contains(TagMeta(path: "job", icon: nil, pinned: true)))
        try store.undoTagRewrite(result)
        #expect(try tagMeta() == [
            TagMeta(path: "home", icon: nil, pinned: false),
            TagMeta(path: "work", icon: nil, pinned: true),
        ])
    }

    @Test func testDidChange() throws {
        _ = try store.create(text: "A #work")
        #expect(try store.renameTag("work", to: "work").didChange == false)
        #expect(try store.renameTag("work", to: "job").didChange)

        // Metadata only: a pinned tag without notes.
        let empty = try store.create(text: "E #empty")
        try store.setTagPinned("empty", pinned: true)
        try store.deletePermanently([empty.id])
        #expect(try store.renameTag("empty", to: "vacant").didChange)

        // Only locked notes, no icon or pin: nothing changes.
        let locked = try store.create(text: "L #secret")
        try lock(locked)
        #expect(try store.deleteTag("secret").didChange == false)
    }

    @Test func testReadOnlyNotesAreSkippedLikeLockedOnes() throws {
        let open = try store.create(text: "A #work")
        let readOnly = try store.create(text: "R #work")
        try setReadOnly(readOnly)
        let renamed = try store.renameTag("work", to: "job")
        #expect(renamed.changedNoteIds == [open.id])
        #expect(renamed.skippedReadOnly == [readOnly.id])
        #expect(renamed.skippedLocked.isEmpty)
        #expect(try text(readOnly) == "R #work")

        let deleted = try store.deleteTag("work")
        #expect(deleted.skippedReadOnly == [readOnly.id])
        #expect(try text(readOnly) == "R #work")
    }

    @Test func testDeleteDropsLinesLeftWithOnlyAListMarker() throws {
        let note = try store.create(text: "T\n- #work\n* [ ] #work\n1. #work\n  - [x] #work\n+ #work\n2) #work\n- keep #work\n-#work")
        try store.deleteTag("work")
        #expect(try text(note) == "T\n- keep\n-#work")
    }
}
