// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import SwiftUI
import Testing
@testable import TheoNotes

/// The three-pane UI's testable logic: command enablement, banner copy, selection and scope
/// handling, drag-to-tag and the persisted window state.
@MainActor
@Suite struct LibraryUITests {
    @MainActor
    final class Env {
        let root: URL
        let environment: AppEnvironment
        let model: LibraryModel

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("TheoNotesUI-\(UUID().uuidString)", isDirectory: true)
            environment = try AppEnvironment(paths: AppPaths(root: root))
            model = LibraryModel(environment: environment)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        var store: NoteStore { environment.store }
    }

    private let start = Date(timeIntervalSince1970: 1_792_670_400)

    // MARK: - Command enablement

    @Test func commandsNeedAListedSelection() throws {
        let env = try Env()
        let note = try env.store.create(text: "A")
        env.model.refresh()

        var state = env.model.commandState
        #expect(!state.canPin && !state.canArchive && !state.canTrash && !state.canDuplicate)
        #expect(!state.canRestore && !state.canDeletePermanently && !state.canEmptyTrash)
        #expect(state.removableTag == nil)

        // A selected id that is not listed (stale) enables nothing.
        env.model.selectedNoteIDs = ["missing"]
        #expect(!env.model.commandState.canTrash)

        env.model.selectedNoteIDs = [note.id]
        state = env.model.commandState
        #expect(state.canPin && state.canArchive && state.canTrash && state.canDuplicate)
        #expect(!state.canRestore && !state.canDeletePermanently)
        #expect(state.pinTitle == "Pin")

        env.model.togglePinSelected()
        #expect(env.model.commandState.pinTitle == "Unpin")
    }

    @Test func trashAndArchiveCommands() throws {
        let env = try Env()
        let a = try env.store.create(text: "A")
        let b = try env.store.create(text: "B")
        try env.store.trash([a.id])
        try env.store.archive([b.id])

        env.model.selectScope(.trash)
        env.model.selectedNoteIDs = [a.id]
        var state = env.model.commandState
        #expect(state.canRestore && state.canDeletePermanently && state.canEmptyTrash && state.canPin)
        #expect(!state.canArchive && !state.canTrash && !state.canDuplicate)

        env.model.selectScope(.archive)
        env.model.selectedNoteIDs = [b.id]
        state = env.model.commandState
        #expect(state.canRestore && state.canTrash && state.canDuplicate && state.canEmptyTrash)
        #expect(!state.canArchive && !state.canDeletePermanently)

        env.model.selectScope(.trash)
        env.model.emptyTrash()
        #expect(!env.model.commandState.canEmptyTrash)
    }

    @Test func removeTagIsOfferedInTagScopeAndRemovesTheTag() throws {
        let env = try Env()
        let a = try env.store.create(text: "A #work", now: start)
        let b = try env.store.create(text: "B #work", now: start.addingTimeInterval(1))
        env.model.selectScope(.tag("work"))
        #expect(env.model.items.map(\.id) == [b.id, a.id])
        env.model.selectNotes([b.id])
        #expect(env.model.commandState.removableTag == "work")

        env.model.removeScopeTagFromSelected()
        #expect(try env.store.note(id: b.id)?.text == "B")
        #expect(env.model.items.map(\.id) == [a.id])
        #expect(env.model.focusedNoteID == a.id)

        env.model.selectScope(.notes)
        env.model.selectNotes([a.id])
        #expect(env.model.commandState.removableTag == nil)
    }

    // MARK: - Selection and scope

    @Test func selectingNotesMovesEditorFocus() throws {
        let env = try Env()
        let a = try env.store.create(text: "A", now: start)
        let b = try env.store.create(text: "B", now: start.addingTimeInterval(1))
        let c = try env.store.create(text: "C", now: start.addingTimeInterval(2))
        env.model.refresh()

        env.model.selectNotes([b.id])
        #expect(env.model.focusedNoteID == b.id)
        // Extending the selection keeps the focused note in the editor.
        env.model.selectNotes([a.id, b.id])
        #expect(env.model.focusedNoteID == b.id)
        // A multi-selection without the focused note focuses its first note in list order.
        env.model.selectNotes([a.id, c.id])
        #expect(env.model.focusedNoteID == c.id)
        env.model.selectNotes([])
        #expect(env.model.focusedNoteID == nil)
    }

    @Test func changingScopeKeepsAListedFocusOrFocusesTheFirstNote() throws {
        let env = try Env()
        let home = try env.store.create(text: "Home #home", now: start)
        let work1 = try env.store.create(text: "Work 1 #work", now: start.addingTimeInterval(1))
        let work2 = try env.store.create(text: "Work 2 #work", now: start.addingTimeInterval(2))
        env.model.refresh()
        env.model.selectNotes([work1.id])

        env.model.selectScope(.tag("work"))
        #expect(env.model.items.map(\.id) == [work2.id, work1.id])
        #expect(env.model.focusedNoteID == work1.id)
        #expect(env.model.selectedNoteIDs == [work1.id])

        env.model.selectScope(.tag("home"))
        #expect(env.model.focusedNoteID == home.id)
        #expect(env.model.selectedNoteIDs == [home.id])

        env.model.selectScope(.trash)
        #expect(env.model.focusedNoteID == nil)
        #expect(env.model.selectedNoteIDs.isEmpty)
    }

    @Test func newNoteCaretIsTakenOnce() throws {
        let env = try Env()
        _ = try env.store.create(text: "#work")
        env.model.selectScope(.tag("work"))
        Settings(db: env.environment.database).tagPosition = .top
        let id = try env.model.newNote()

        #expect(env.model.takeNewNoteCaret(for: "other") == nil)
        #expect(env.model.takeNewNoteCaret(for: id) == "#work\n\n".utf16.count)
        #expect(env.model.takeNewNoteCaret(for: id) == nil)
    }

    // MARK: - Drag to tag

    @Test func droppingNotesOnATagAddsTheTag() throws {
        let env = try Env()
        let a = try env.store.create(text: "Alpha", now: start)
        let b = try env.store.create(text: "Beta #home", now: start.addingTimeInterval(1))
        env.model.refresh()

        let payload = NoteDragItem(noteIDs: [a.id, b.id])
        let decoded = try JSONDecoder().decode(NoteDragItem.self, from: JSONEncoder().encode(payload))
        #expect(decoded == payload)

        env.model.addTag("work/projects", toNoteIDs: decoded.noteIDs)
        #expect(try env.store.note(id: a.id)?.text == "Alpha\n#work/projects")
        #expect(try env.store.note(id: b.id)?.text == "Beta #home\n#work/projects")
        let work = try #require(env.model.tagTree.first { $0.path == "work" })
        #expect(work.children.map(\.path) == ["work/projects"])
        #expect(work.children.first?.noteCount == 2)

        Settings(db: env.environment.database).tagPosition = .top
        env.model.addTag("my tag", toNoteIDs: [a.id])
        #expect(try env.store.note(id: a.id)?.text == "Alpha\n#my tag#\n#work/projects")
    }

    @Test func droppingOnATagCommitsPendingEditsFirst() throws {
        let env = try Env()
        let note = try env.store.create(text: "Draft")
        env.model.refresh()
        let session = try env.environment.session(for: note.id)
        let edit = ChangeSet(sections: [.retain(5), .replace(deleteLength: 0, insert: " text")])
        #expect(session.apply(txId: "t1", baseRevision: 0, changeSet: edit, origin: nil) == .acked(revision: 1))

        env.model.addTag("inbox", toNoteIDs: [note.id])
        #expect(try env.store.note(id: note.id)?.text == "Draft text\n#inbox")
        #expect(try env.store.allNotes().count == 1) // no conflict copy
    }

    // MARK: - Banner

    @Test func bannerCopy() {
        let one = LibraryBanner.conflictCopiesCreated(noteIds: ["a"])
        #expect(one.message == "Conflict copy created")
        #expect(one.actionTitle == "Show")
        #expect(LibraryBanner.conflictCopiesCreated(noteIds: ["a", "b"]).message == "2 conflict copies created")
        #expect(LibraryBanner.journalsMovedAside(count: 1).message == "1 edit journal was recovered")
        #expect(LibraryBanner.journalsMovedAside(count: 3).message == "3 edit journals were recovered")
        #expect(LibraryBanner.journalsMovedAside(count: 3).actionTitle == "Show in Settings")
        #expect(LibraryBanner.commandFailed(action: "empty trash").message == "Empty trash failed")
        #expect(LibraryBanner.commandFailed(action: "trash").actionTitle == "OK")
    }

    // MARK: - Persisted window state and settings

    @Test func scopeStorageRoundTrips() {
        let scopes: [SidebarScope] = [
            .notes, .pinned, .untagged, .todo, .today, .locked, .archive, .trash, .tag("work/projects"), .tag("my tag"),
        ]
        for scope in scopes {
            #expect(SidebarScope(storageValue: scope.storageValue) == scope)
        }
        #expect(SidebarScope(storageValue: "bogus") == nil)
        #expect(SidebarScope(storageValue: "tag:") == nil)
    }

    @Test func layoutPresetsMapToColumnVisibility() {
        #expect(LayoutPreset.editorOnly.columnVisibility == .doubleColumn) // the note list collapses through AppKit
        #expect(LayoutPreset.notesAndEditor.columnVisibility == .doubleColumn)
        #expect(LayoutPreset.all.columnVisibility == .all)
        #expect(LayoutPreset(.detailOnly) == .editorOnly)
        #expect(LayoutPreset(.doubleColumn) == .notesAndEditor)
        #expect(LayoutPreset(.all) == .all)
    }

    @Test func sortSettingSplitsIntoFieldAndDirection() {
        for sort in NoteSort.allCases {
            #expect(NoteSort(field: sort.field, ascending: sort.isAscending) == sort)
        }
        #expect(NoteSort.modifiedDescending.field == .modified)
        #expect(!NoteSort.modifiedDescending.isAscending)
        #expect(NoteSort.titleAscending.field == .title)
        #expect(NoteSort.titleAscending.isAscending)
    }

    @Test func scopeNamesAndIcons() {
        #expect(SidebarScope.notes.displayName == "Notes")
        #expect(SidebarScope.tag("work/projects").displayName == "work/projects")
        #expect(SidebarScope.trash.systemImage == "trash")
        #expect(SidebarScope.tag("x").systemImage == "number")
    }
}
