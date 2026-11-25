// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Testing
@testable import TheoNotes

@MainActor
@Suite struct SortInboxModelTests {
    private let start = Date(timeIntervalSince1970: 1_792_670_400)

    private func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    private func makeUndoManager() -> UndoManager {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        return undoManager
    }

    /// One user action, as the app's event loop would group it.
    private func act(_ undoManager: UndoManager, _ body: () -> Void) {
        undoManager.beginUndoGrouping()
        body()
        undoManager.endUndoGrouping()
    }

    private func three(_ env: LibraryModelTests.Env) throws -> (a: String, b: String, c: String) {
        // Created out of order: the queue is oldest first, whatever the list's sort is.
        let b = try env.store.create(text: "Second", now: at(2)).id
        let c = try env.store.create(text: "Third", now: at(3)).id
        let a = try env.store.create(text: "First", now: at(1)).id
        env.model.refresh()
        return (a, b, c)
    }

    @Test func startsWithOldestUntypedNote() throws {
        let env = try LibraryModelTests.Env()
        let ids = try three(env)
        _ = try env.store.create(text: "Typed #idea", now: at(0))
        env.model.refresh()

        let sort = SortInboxModel(model: env.model)
        #expect(sort.current?.id == ids.a)
        #expect(sort.progress.done == 0)
        #expect(sort.progress.total == 3)
    }

    @Test func typingAdvances() throws {
        let env = try LibraryModelTests.Env()
        let ids = try three(env)
        let sort = SortInboxModel(model: env.model)

        sort.apply(.type(.idea), undoManager: nil)

        #expect(try env.store.note(id: ids.a)?.text == "First\n\n#idea")
        #expect(sort.current?.id == ids.b)
        #expect(sort.summary.typed == 1)
        #expect(sort.progress.done == 1)
        #expect(sort.progress.total == 3)
    }

    @Test func typingKeepsTheModifiedDate() throws {
        let env = try LibraryModelTests.Env()
        let ids = try three(env)
        let before = try #require(try env.store.note(id: ids.a)).modifiedAt
        let sort = SortInboxModel(model: env.model)

        sort.apply(.type(.idea), undoManager: nil)

        #expect(try env.store.note(id: ids.a)?.text == "First\n\n#idea")
        #expect(try env.store.note(id: ids.a)?.modifiedAt == before)
    }

    @Test func aNoteWhereTheTagWouldNotCountIsSkipped() throws {
        let env = try LibraryModelTests.Env()
        let fenced = try env.store.create(text: "First\n```\ncode", now: at(1)).id
        let next = try env.store.create(text: "Second", now: at(2)).id
        env.model.refresh()
        let sort = SortInboxModel(model: env.model)
        #expect(sort.current?.id == fenced)

        sort.apply(.type(.idea), undoManager: nil)

        #expect(try env.store.note(id: fenced)?.text == "First\n```\ncode")
        #expect(sort.summary == SortInboxSummary(typed: 0, archived: 0, trashed: 0, skipped: 1))
        #expect(sort.current?.id == next)
    }

    @Test func skipsReadOnlyAutomatically() throws {
        let env = try LibraryModelTests.Env()
        let ids = try three(env)
        try env.store.setReadOnly(ids.a, readOnly: true)
        env.model.refresh()

        let sort = SortInboxModel(model: env.model)
        #expect(sort.current?.id == ids.b)
        #expect(sort.summary.skipped == 1)

        sort.apply(.archive, undoManager: nil)
        sort.apply(.archive, undoManager: nil)
        #expect(sort.current == nil)
        #expect(sort.summary == SortInboxSummary(typed: 0, archived: 2, trashed: 0, skipped: 1))
        #expect(sort.progress.done == 3)
        #expect(try env.store.note(id: ids.a)?.location == .notes)
    }

    @Test func undoRevertsLastAction() throws {
        let env = try LibraryModelTests.Env()
        let ids = try three(env)
        let sort = SortInboxModel(model: env.model)
        let undoManager = makeUndoManager()

        act(undoManager) { sort.apply(.archive, undoManager: undoManager) }
        #expect(try env.store.note(id: ids.a)?.location == .archive)
        #expect(sort.current?.id == ids.b)
        #expect(undoManager.undoActionName == "Archive")

        undoManager.undo()
        #expect(try env.store.note(id: ids.a)?.location == .notes)
        #expect(sort.current?.id == ids.a)
        #expect(sort.summary.archived == 0)
        #expect(sort.progress.done == 0)

        undoManager.redo()
        #expect(try env.store.note(id: ids.a)?.location == .archive)
        #expect(sort.current?.id == ids.b)
        #expect(sort.summary.archived == 1)
    }

    @Test func undoRevertsTypeTrashAndSkip() throws {
        let env = try LibraryModelTests.Env()
        let ids = try three(env)
        let sort = SortInboxModel(model: env.model)
        let undoManager = makeUndoManager()

        act(undoManager) { sort.apply(.type(.log), undoManager: undoManager) }
        act(undoManager) { sort.apply(.trash, undoManager: undoManager) }
        act(undoManager) { sort.apply(.skip, undoManager: undoManager) }
        #expect(sort.current == nil)
        #expect(sort.summary == SortInboxSummary(typed: 1, archived: 0, trashed: 1, skipped: 1))
        #expect(try env.store.note(id: ids.b)?.location == .trash)

        undoManager.undo()
        #expect(sort.current?.id == ids.c)
        undoManager.undo()
        #expect(sort.current?.id == ids.b)
        #expect(try env.store.note(id: ids.b)?.location == .notes)
        undoManager.undo()
        #expect(sort.current?.id == ids.a)
        #expect(try env.store.note(id: ids.a)?.text == "First")
        #expect(sort.summary == SortInboxSummary())
    }

    @Test func dropsNoteThatLeftTheInbox() throws {
        let env = try LibraryModelTests.Env()
        let ids = try three(env)
        let sort = SortInboxModel(model: env.model)
        // Typed by hand (another window) while the sheet showed it.
        try env.store.setType(.reference, noteIds: [ids.a])

        sort.apply(.archive, undoManager: nil)

        // Nothing was done to the note the user never saw; the queue moved on.
        #expect(try env.store.note(id: ids.a)?.location == .notes)
        #expect(try env.store.note(id: ids.b)?.location == .notes)
        #expect(sort.current?.id == ids.b)
        #expect(sort.progress.total == 2)
        #expect(sort.summary == SortInboxSummary())
    }

    @Test func archiveRestRespectsWorkspace() throws {
        let env = try LibraryModelTests.Env()
        let first = try env.store.create(text: "One #work", now: at(1)).id
        let second = try env.store.create(text: "Two #work", now: at(2)).id
        let outside = try env.store.create(text: "Outside", now: at(3)).id
        env.model.enterWorkspace("work")
        let sort = SortInboxModel(model: env.model)
        #expect(sort.remaining == 2)

        #expect(sort.archiveRest(undoManager: nil) == 2)

        #expect(try env.store.note(id: first)?.location == .archive)
        #expect(try env.store.note(id: second)?.location == .archive)
        #expect(try env.store.note(id: outside)?.location == .notes)
        #expect(sort.current == nil)
        #expect(sort.summary.archived == 2)
    }

    @Test func archiveRestUndoRestoresAll() throws {
        let env = try LibraryModelTests.Env()
        let ids = try three(env)
        let sort = SortInboxModel(model: env.model)
        let undoManager = makeUndoManager()

        sort.apply(.skip, undoManager: nil)
        act(undoManager) { #expect(sort.archiveRest(undoManager: undoManager) == 2) }
        #expect(try env.store.note(id: ids.a)?.location == .notes)
        #expect(try env.store.note(id: ids.b)?.location == .archive)
        #expect(try env.store.note(id: ids.c)?.location == .archive)

        undoManager.undo()
        #expect(try env.store.note(id: ids.b)?.location == .notes)
        #expect(try env.store.note(id: ids.c)?.location == .notes)
        #expect(sort.current?.id == ids.b)
        #expect(sort.remaining == 2)
        #expect(sort.summary.archived == 0)
    }

    @Test func archiveRestLeavesNotesThatLeftTheInbox() throws {
        let env = try LibraryModelTests.Env()
        let ids = try three(env)
        let sort = SortInboxModel(model: env.model)
        try env.store.setType(.idea, noteIds: [ids.c])

        #expect(sort.archiveRest(undoManager: nil) == 2)
        #expect(try env.store.note(id: ids.c)?.location == .notes)
    }

    @Test func previewShowsTheLinesAfterTheTitle() throws {
        let env = try LibraryModelTests.Env()
        let id = try env.store.create(text: "Title line\n\nBody one\nBody two", now: at(1)).id
        env.model.refresh()
        let sort = SortInboxModel(model: env.model)
        #expect(sort.current?.id == id)
        #expect(sort.preview == "Body one\nBody two")
    }

    @Test func wordsAndMenuState() {
        #expect(SortInboxStrings.progress((done: 11, total: 242)) == "12 of 242")
        #expect(SortInboxStrings.progress((done: 3, total: 3)) == "3 of 3")
        #expect(SortInboxStrings.archiveRestTitle(230) == "Archive 230 notes?")
        #expect(SortInboxStrings.archiveRestTitle(1) == "Archive 1 note?")
        #expect(SortInboxStrings.summaryLines(SortInboxSummary(typed: 2, archived: 0, trashed: 1, skipped: 4))
            == ["2 typed", "1 moved to the Trash", "4 skipped"])
        let none = NoteCommandState(scope: .notes, items: [], selectedNoteIDs: [], counts: SidebarCounts())
        let some = NoteCommandState(scope: .notes, items: [], selectedNoteIDs: [], counts: SidebarCounts(inbox: 3))
        #expect(!none.canSortInbox)
        #expect(some.canSortInbox)
    }
}
