// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import GRDB
@testable import TheoNotesCore

/// M8 Task 1: export file names and where notes go.
@Suite struct ExportPlanTests {
    private func candidate(
        _ id: String, _ title: String = "T", tags: [String] = [], location: NoteLocation = .notes, locked: Bool = false
    ) -> ExportCandidate {
        ExportCandidate(noteId: id, title: title, directTags: tags, location: location, isLocked: locked)
    }

    @Test func stemSanitizesTitles() {
        #expect(ExportNaming.stem(forTitle: "a/b:c") == "a-b-c")
        #expect(ExportNaming.stem(forTitle: "") == "Untitled")
        #expect(ExportNaming.stem(forTitle: "   ") == "Untitled")
        #expect(ExportNaming.stem(forTitle: "..hidden") == "hidden")
        #expect(ExportNaming.stem(forTitle: "  . x ") == "x")
        #expect(ExportNaming.stem(forTitle: "x\u{7}y") == "x-y")
        #expect(ExportNaming.stem(forTitle: "x\u{7F}y") == "x-y")

        let emoji = String(repeating: "👨‍👩‍👧‍👦", count: 20)
        #expect(emoji.utf8.count > 300)
        let cut = ExportNaming.stem(forTitle: emoji)
        #expect(cut.utf8.count <= 180)
        #expect(!cut.isEmpty)
        #expect(cut.allSatisfy { $0 == "👨‍👩‍👧‍👦" })
        #expect(String(decoding: Array(cut.utf8), as: UTF8.self) == cut)

        let nfc = ExportNaming.stem(forTitle: "Cafe\u{301}")
        #expect(nfc == "Caf\u{E9}")
        #expect(Array(nfc.unicodeScalars).count == 4)
    }

    @Test func allocatorNumbersCollisionsCaseInsensitively() {
        var allocator = StemAllocator()
        #expect(allocator.claim("Note") == "Note")
        #expect(allocator.claim("note") == "note 2")
        #expect(allocator.claim("NOTE") == "NOTE 3")
        #expect(allocator.claim("Other") == "Other")
        // A literal "Note 2" title does not collide with the number handed out above.
        #expect(allocator.claim("Note 2") == "Note 2 2")
        _ = allocator.claim("Cafe\u{301}")
        #expect(allocator.claim("Caf\u{E9}") == "Caf\u{E9} 2")
    }

    @Test func tagTreePlacesNotesInTheirDeepestDirectTag() {
        let notes = [
            candidate("n1", "One", tags: ["workout", "workout/cardio"]),
            candidate("n2", "Two", tags: ["workout/a", "workout/b"]),
            candidate("n3", "Three", tags: ["workout"]),
            candidate("n4", "Four", tags: ["other", "workout/x"]),
            candidate("n5", "Five", tags: ["other"]),
        ]
        let result = ExportPlan.tagTree(root: "workout", notes: notes)
        #expect(result.skippedLocked.isEmpty)
        #expect(result.items == [
            ExportItem(noteId: "n1", folder: ["workout", "cardio"], stem: "One"),
            ExportItem(noteId: "n2", folder: ["workout", "a"], stem: "Two"),
            ExportItem(noteId: "n2", folder: ["workout", "b"], stem: "Two"),
            ExportItem(noteId: "n3", folder: ["workout"], stem: "Three"),
            ExportItem(noteId: "n4", folder: ["workout", "x"], stem: "Four"),
        ])
    }

    @Test func tagTreeUsesTheLastComponentOfANestedRootAndMatchesCaseInsensitively() {
        let notes = [
            candidate("n1", "A", tags: ["Work/Meetings/2026"]),
            candidate("n2", "A", tags: ["work/meetings"]),
            candidate("n3", "B", tags: ["work/other"]),
        ]
        let result = ExportPlan.tagTree(root: "work/meetings", notes: notes)
        #expect(result.items == [
            ExportItem(noteId: "n1", folder: ["meetings", "2026"], stem: "A"),
            ExportItem(noteId: "n2", folder: ["meetings"], stem: "A"),
        ])
    }

    @Test func tagTreeNumbersTitleCollisionsPerFolder() {
        let notes = [
            candidate("n1", "Same", tags: ["t"]),
            candidate("n2", "same", tags: ["t"]),
            candidate("n3", "Same", tags: ["t/sub"]),
            candidate("n4", "", tags: ["t/Sub"]),
            candidate("n5", "Untitled", tags: ["t/sub"]),
        ]
        let result = ExportPlan.tagTree(root: "t", notes: notes)
        #expect(result.items.map(\.stem) == ["Same", "same 2", "Same", "Untitled", "Untitled 2"])
        // `t/sub` and `t/Sub` are one folder on a case-insensitive disk, so they share the numbering.
        #expect(result.items[3].folder.count == 2)
    }

    @Test func tagTreeSkipsLockedAndCountsThem() {
        let notes = [
            candidate("n1", tags: ["w"]),
            candidate("locked1", tags: ["w"], locked: true),
            candidate("n2", tags: ["w/x"]),
            candidate("locked2", tags: [], locked: true),
        ]
        let result = ExportPlan.tagTree(root: "w", notes: notes)
        #expect(result.items.map(\.noteId) == ["n1", "n2"])
        #expect(result.skippedLocked == ["locked1", "locked2"])
    }

    @Test func selectionIsFlatAndKeepsOrder() {
        let notes = [
            candidate("b", "Beta", tags: ["x/y"], location: .trash),
            candidate("l", "Secret", locked: true),
            candidate("a", "Alpha", location: .archive),
            candidate("c", "beta"),
        ]
        let result = ExportPlan.selection(notes)
        #expect(result.items == [
            ExportItem(noteId: "b", folder: [], stem: "Beta"),
            ExportItem(noteId: "a", folder: [], stem: "Alpha"),
            ExportItem(noteId: "c", folder: [], stem: "beta 2"),
        ])
        #expect(result.skippedLocked == ["l"])
    }

    @Test func exportCandidatesForTagTreeExcludeArchiveAndTrash() throws {
        let tmp = try TempPaths()
        let store = NoteStore(db: try .inMemory(), notifier: nil, paths: tmp.paths)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let direct = try store.create(text: "Direct\n#workout", now: t0)
        let nested = try store.create(text: "Nested\n#workout/cardio #other", now: t0.addingTimeInterval(10))
        let both = try store.create(text: "Both\n#workout #workout/cardio", now: t0.addingTimeInterval(20))
        let archived = try store.create(text: "Archived\n#workout", now: t0.addingTimeInterval(30))
        let trashed = try store.create(text: "Trashed\n#workout/cardio", now: t0.addingTimeInterval(40))
        _ = try store.create(text: "Elsewhere\n#other", now: t0.addingTimeInterval(50))
        try store.archive([archived.id])
        try store.trash([trashed.id])

        let tree = try store.exportCandidates(tagTree: "workout")
        #expect(tree.map(\.noteId) == [both.id, nested.id, direct.id])
        #expect(tree.map(\.title) == ["Both", "Nested", "Direct"])
        #expect(tree.map(\.directTags) == [["workout", "workout/cardio"], ["workout/cardio", "other"], ["workout"]])
        #expect(tree.allSatisfy { $0.location == .notes && !$0.isLocked })
        #expect(try store.exportCandidates(tagTree: "Workout/Cardio").map(\.noteId) == [both.id, nested.id])
        #expect(try store.exportCandidates(tagTree: "missing").isEmpty)

        // Ids keep the order given and reach Archive and Trash.
        let picked = try store.exportCandidates(ids: [trashed.id, direct.id, archived.id])
        #expect(picked.map(\.noteId) == [trashed.id, direct.id, archived.id])
        #expect(picked.map(\.location) == [.trash, .notes, .archive])
        #expect(throws: StoreError.noteNotFound(id: "nope")) { try store.exportCandidates(ids: [direct.id, "nope"]) }
    }

    /// APFS compares names by Unicode case folding, which maps `ß` to `ss`; `lowercased()` does not.
    @Test func allocatorTreatsFullCaseFoldedNamesAsCollisions() {
        var allocator = StemAllocator()
        #expect(allocator.claim("Straße") == "Straße")
        #expect(allocator.claim("STRASSE") == "STRASSE 2")
        let plan = ExportPlan.selection([candidate("a", "Straße"), candidate("b", "STRASSE")])
        #expect(plan.items.map(\.stem) == ["Straße", "STRASSE 2"])
        let tree = ExportPlan.tagTree(root: "t", notes: [
            candidate("a", "x", tags: ["t/Straße"]), candidate("b", "x", tags: ["t/STRASSE"]),
        ])
        #expect(tree.items.map(\.stem) == ["x", "x 2"])
    }

    /// A tag tree holds Notes only. The planner enforces it, whatever the provider returns.
    @Test func tagTreePlanIgnoresArchiveAndTrashCandidates() {
        let notes = [
            candidate("n", "N", tags: ["w"]),
            candidate("a", "A", tags: ["w"], location: .archive),
            candidate("t", "T", tags: ["w/x"], location: .trash),
        ]
        let result = ExportPlan.tagTree(root: "w", notes: notes)
        #expect(result.items.map(\.noteId) == ["n"])
        #expect(result.skippedLocked.isEmpty)
    }

    /// M9 keeps `note_tag` rows for locked notes (`indexLocked`), so a tag-tree export finds them
    /// through their tag rows and counts them. Before M9 no note can be locked, so the test builds
    /// the row state by SQL.
    @Test func aLockedNoteWithItsTagRowIsCountedNotExportedInATagTree() throws {
        let tmp = try TempPaths()
        let db = try AppDatabase.inMemory()
        let store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
        let open = try store.create(text: "Open\n#workout")
        let locked = try store.create(text: "Secret\n#workout/cardio")
        try db.pool.write {
            try $0.execute(
                sql: "UPDATE note SET isLocked = 1, text = '', encryptedPayload = ? WHERE id = ?",
                arguments: [Data([9, 9]), locked.id])
        }
        let tagRows = try db.pool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note_tag WHERE noteId = ?", arguments: [locked.id])
        }
        #expect(tagRows == 2)

        let candidates = try store.exportCandidates(tagTree: "workout")
        #expect(Set(candidates.map(\.noteId)) == [open.id, locked.id])
        let plan = ExportPlan.tagTree(root: "workout", notes: candidates)
        #expect(plan.items.map(\.noteId) == [open.id])
        #expect(plan.skippedLocked == [locked.id])
    }

    @Test func aLockedNoteIsFlaggedInTheCandidates() throws {
        let tmp = try TempPaths()
        let db = try AppDatabase.inMemory()
        let store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
        let note = try store.create(text: "Locked one\n#w")
        try db.pool.write {
            try $0.execute(
                sql: "UPDATE note SET isLocked = 1, text = '', encryptedPayload = ? WHERE id = ?",
                arguments: [Data([1, 2, 3]), note.id])
        }
        let candidates = try store.exportCandidates(ids: [note.id])
        #expect(candidates == [ExportCandidate(
            noteId: note.id, title: "Locked one", directTags: [], location: .notes, isLocked: true)])
        #expect(ExportPlan.selection(candidates).skippedLocked == [note.id])
    }
}
