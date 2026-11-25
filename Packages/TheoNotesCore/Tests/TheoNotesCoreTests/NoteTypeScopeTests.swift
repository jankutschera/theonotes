// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import GRDB
@testable import TheoNotesCore

@Suite struct NoteTypeScopeTests {
    let tmp: TempPaths
    let db: AppDatabase
    let store: NoteStore
    let calendar = Calendar(identifier: .gregorian)
    let now = Date(timeIntervalSince1970: 1_792_670_400)

    init() throws {
        tmp = try TempPaths()
        db = try AppDatabase.inMemory()
        store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
    }

    @discardableResult
    private func seed(_ text: String) throws -> Note { try store.create(text: text, now: now) }

    private func flag(_ column: String, _ note: Note) throws {
        try db.pool.write { try $0.execute(sql: "UPDATE note SET \(column) = 1 WHERE id = ?", arguments: [note.id]) }
    }

    private func titles(_ scope: SidebarScope, workspace: Workspace? = nil) throws -> [String] {
        try db.pool.read {
            try LibraryQueries.notes(in: scope, sort: .titleAscending, workspace: workspace, now: now, calendar: calendar, db: $0)
        }.map(\.title)
    }

    private func counts(workspace: Workspace? = nil) throws -> SidebarCounts {
        try db.pool.read { try LibraryQueries.counts(workspace: workspace, now: now, calendar: calendar, db: $0) }
    }

    private func text(_ note: Note) throws -> String? {
        try db.pool.read { try String.fetchOne($0, sql: "SELECT text FROM note WHERE id = ?", arguments: [note.id]) }
    }

    @Test func inboxListsUntypedNotesOnly() throws {
        try seed("A\n#idea")
        try seed("B")
        try seed("C\n#template")
        try flag("isLocked", try seed("D"))
        try store.archive([try seed("E").id])
        #expect(try titles(.inbox) == ["B"])
        #expect(try counts().inbox == 1)
    }

    @Test func typeScopesListByType() throws {
        try seed("A\n#idea")
        let archived = try seed("Z\n#idea")
        try store.archive([archived.id])
        try seed("Plain")
        #expect(try titles(.type(.idea)) == ["A"])
        let c = try counts()
        #expect((c.ideas, c.logs, c.references) == (1, 0, 0))
    }

    @Test func scopesRespectWorkspace() throws {
        try seed("In\n#work")
        try seed("Typed\n#work #log")
        try seed("Out")
        let work = Workspace(path: "work")
        #expect(try titles(.inbox, workspace: work) == ["In"])
        #expect(try counts(workspace: work).inbox == 1)
        #expect(try counts(workspace: work).logs == 1)
        #expect(try counts().inbox == 2)
    }

    @Test func untaggedIgnoresReservedTags() throws {
        try seed("A\n#idea")
        try seed("B\n#idea #x")
        try seed("C\n#ref/recipes")
        #expect(try titles(.untagged) == ["A"])
        #expect(try counts().untagged == 1)
        let found = try db.pool.read {
            try LibraryQueries.search("@untagged", in: .notes, sort: .titleAscending, now: now, calendar: calendar, db: $0)
        }.items.map(\.title)
        #expect(found == ["A"])
    }

    @Test func tagTreeHidesReservedLeaves() throws {
        try seed("A\n#idea")
        try seed("B\n#work")
        var tree = try db.pool.read { try LibraryQueries.tagTree(db: $0) }
        #expect(tree.map(\.id) == ["work"])
        try seed("C\n#ref/recipes")
        tree = try db.pool.read { try LibraryQueries.tagTree(db: $0) }
        #expect(tree.map(\.id) == ["ref", "work"])
        #expect(tree.first { $0.id == "ref" }?.children.map(\.id) == ["ref/recipes"])
    }

    @Test func renameIntoReservedIsRefused() throws {
        let work = try seed("W\n#work")
        let x = try seed("X\n#x")
        let ref = try seed("R\n#ref")
        #expect(throws: StoreError.reservedTagName("Idea")) { try store.renameTag("work", to: "Idea") }
        #expect(throws: StoreError.reservedTagName("ref")) { try store.renameTag("x", to: "ref") }
        #expect(try text(work) == "W\n#work")
        #expect(try text(x) == "X\n#x")
        #expect(try text(ref) == "R\n#ref")
    }

    @Test func setTypeSkipsLockedAndReadOnly() throws {
        let plain = try seed("P")
        let locked = try seed("L")
        let readOnly = try seed("O")
        try flag("isLocked", locked)
        try flag("isReadOnly", readOnly)
        let result = try store.setType(.log, noteIds: [plain.id, locked.id, readOnly.id], now: now)
        #expect(result.changedNoteIds == [plain.id])
        #expect(result.skippedLocked == [locked.id])
        #expect(result.skippedReadOnly == [readOnly.id])
        #expect(try text(plain) == "P\n\n#log")
        #expect(try text(locked) == "L")
        #expect(try text(readOnly) == "O")
    }

    @Test func setTypeRefusesWhenTheTagWouldSitInsideAFence() throws {
        let fenced = try seed("# T\n```\ncode")
        let plain = try seed("P")
        for _ in 0..<2 {
            let result = try store.setType(.idea, noteIds: [fenced.id, plain.id], now: now)
            #expect(result.skippedNotApplied == [fenced.id])
            #expect(result.changedNoteIds.filter { $0 == fenced.id }.isEmpty)
        }
        #expect(try text(fenced) == "# T\n```\ncode")
        #expect(try text(plain) == "P\n\n#idea")
    }

    @Test func setTypeKeepsTheModifiedDate() throws {
        let note = try seed("Old")
        let later = now.addingTimeInterval(86_400)
        let before = try #require(try store.note(id: note.id)).modifiedAt
        _ = try store.setType(.log, noteIds: [note.id], now: later)
        let after = try #require(try store.note(id: note.id))
        #expect(after.text == "Old\n\n#log")
        #expect(after.modifiedAt == before)
    }

    @Test func setTypeNilClearsTheType() throws {
        let note = try seed("Recipe\n\n#ref")
        let result = try store.setType(nil, noteIds: [note.id], now: now)
        #expect(result.changedNoteIds == [note.id])
        #expect(try text(note) == "Recipe")
        #expect(try titles(.type(.reference)) == [])
    }

    @Test func referenceScopeListsAndCounts() throws {
        try seed("R\n#ref")
        try seed("I\n#idea")
        #expect(try titles(.type(.reference)) == ["R"])
        let c = try counts()
        #expect((c.ideas, c.logs, c.references) == (1, 0, 1))
    }

    @Test func setTypeUndoRestoresText() throws {
        let a = try seed("A\n#idea")
        let b = try seed("B")
        let result = try store.setType(.reference, noteIds: [a.id, b.id], now: now)
        #expect(try text(a) == "A\n#ref")
        #expect(try text(b) == "B\n\n#ref")
        #expect(try store.undoTagRewrite(result, now: now).sorted() == [a.id, b.id].sorted())
        #expect(try text(a) == "A\n#idea")
        #expect(try text(b) == "B")
    }

    @Test func reservedWorkspacePaths() {
        #expect(NoteType.isReservedWorkspace(path: "Idea"))
        #expect(NoteType.isReservedWorkspace(path: "ref"))
        #expect(!NoteType.isReservedWorkspace(path: "ref/recipes"))
    }
}
