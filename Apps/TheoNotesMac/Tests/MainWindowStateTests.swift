// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import Testing
@testable import TheoNotes

/// `MainWindowState` with a fake editor page: what the editor shows when focus changes, scope
/// fallback, and focus after ⌘N.
@MainActor
@Suite struct MainWindowStateTests {
    @MainActor
    final class Env {
        let root: URL
        let suiteName = "TheoNotesMainWindowTests-\(UUID().uuidString)"
        let environment: AppEnvironment
        let page = FakeEditorPage()
        let editor: EditorBridgeController
        let state: MainWindowState

        /// `setUp` runs before the window state restores its selection.
        init(setUp: (NoteStore) throws -> Void = { _ in }) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("TheoNotesMainWindow-\(UUID().uuidString)", isDirectory: true)
            environment = try AppEnvironment(paths: AppPaths(root: root))
            try setUp(environment.store)
            editor = EditorBridgeController(
                environment: environment, page: page, openExternally: { _ in }, checksumInterval: nil
            )
            _ = editor.handle(.ready(version: 1))
            state = MainWindowState(
                environment: environment, defaults: UserDefaults(suiteName: suiteName)!, editor: editor
            )
        }

        deinit {
            UserDefaults().removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        var store: NoteStore { environment.store }
        var model: LibraryModel { state.model }
    }

    private static let placeholder = HostToEditorMessage.loadNote(
        noteId: EditorBridgeController.placeholderNoteId, text: "", revision: 0, readOnly: true
    )

    @Test func trashingTheLastListedNoteDetachesTheEditor() throws {
        var noteId = ""
        let env = try Env { noteId = try $0.create(text: "Solo #solo").id }
        env.model.selectScope(.tag("solo"))
        env.state.showFocusedNote()
        #expect(env.editor.session?.noteId == noteId)

        let edit = ChangeSet(sections: [.retain(10), .replace(deleteLength: 0, insert: "!")])
        let typed = EditorToHostMessage.changes(noteId: noteId, txId: "t1", baseRevision: 0, revision: 1, changeSet: edit)
        #expect(env.editor.handle(typed) == .acked(revision: 1))

        env.model.trashSelected()
        #expect(env.model.focusedNoteID == nil)
        env.state.showFocusedNote() // what EditorPane does on the focus change

        #expect(env.editor.session == nil)
        #expect(env.page.loadNotes.last == Self.placeholder)
        #expect(try env.store.note(id: noteId)?.text == "Solo #solo!") // flushed before letting go
        // Typing into the placeholder reaches no note.
        let late = EditorToHostMessage.changes(
            noteId: EditorBridgeController.placeholderNoteId, txId: "t2", baseRevision: 0, revision: 1, changeSet: edit
        )
        #expect(env.editor.handle(late) == .needsFullText(currentRevision: 0))

        // Showing a note again loads it normally.
        env.model.selectScope(.trash)
        env.state.showFocusedNote()
        guard case .loadNote(let shown, let text, _, let readOnly, _, _, _) = env.page.loadNotes.last else {
            Issue.record("no loadNote")
            return
        }
        #expect(shown == noteId && text == "Solo #solo!" && readOnly)
    }

    @Test func showingNoNoteResignsTheWebViewsKeyboardFocus() throws {
        var noteId = ""
        let env = try Env { noteId = try $0.create(text: "Focus").id }
        env.state.showFocusedNote()
        #expect(env.editor.session?.noteId == noteId)

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.contentView = nil
            window.close()
        }
        window.contentView = env.editor.webView
        #expect(window.makeFirstResponder(env.editor.webView))

        env.model.selectNotes([])
        env.state.showFocusedNote()
        #expect(env.editor.session == nil)
        #expect(window.firstResponder !== env.editor.webView)
    }

    /// Deleting permanently closes the session first (`sessionClosed`), so `showNoNote()` finds no
    /// session; it must still take keyboard focus away from the hidden web view.
    @Test func deletingTheShownNotePermanentlyResignsKeyboardFocus() throws {
        var noteId = ""
        let env = try Env { store in
            noteId = try store.create(text: "Doomed").id
            try store.trash([noteId])
        }
        env.model.selectScope(.trash)
        env.state.showFocusedNote()
        #expect(env.editor.session?.noteId == noteId)

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.contentView = nil
            window.close()
        }
        window.contentView = env.editor.webView
        #expect(window.makeFirstResponder(env.editor.webView))

        env.model.deleteSelectedPermanently()
        #expect(env.editor.session == nil) // closed by the environment, before the view reacts
        #expect(window.firstResponder === env.editor.webView)
        #expect(env.model.focusedNoteID == nil)

        env.state.showFocusedNote() // what EditorPane does on the focus change
        #expect(window.firstResponder !== env.editor.webView)
        #expect(env.page.loadNotes.last == Self.placeholder)
        #expect(try env.store.note(id: noteId) == nil)
    }

    @Test func restoredArchiveScopeWithNotesStaysOnArchive() throws {
        let suiteName = "TheoNotesMainWindowTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TheoNotesMainWindow-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = try AppEnvironment(paths: AppPaths(root: root))
        _ = try environment.store.create(text: "Current")
        let archived = try environment.store.create(text: "Archived")
        try environment.store.archive([archived.id])
        defaults.set("archive", forKey: "MainWindow.scope")
        defaults.set(archived.id, forKey: "MainWindow.note")

        let state = MainWindowState(environment: environment, defaults: defaults)
        #expect(state.model.scope == .archive)
        #expect(state.isScopeInSidebar)
        #expect(state.model.focusedNoteID == archived.id)
        state.showNotesIfScopeHidden()
        #expect(state.model.scope == .archive)
    }

    @Test func hiddenScopesFallBackToNotes() throws {
        var ids: [String] = []
        let env = try Env { store in
            ids = try ["Archived", "Pinned", "Tagged #gone"].map { try store.create(text: $0).id }
            try store.archive([ids[0]])
            try store.setPinned([ids[1]], pinned: true)
        }

        env.model.selectScope(.archive)
        #expect(env.state.isScopeInSidebar)
        env.model.restoreSelected()
        #expect(!env.state.isScopeInSidebar)
        env.state.showNotesIfScopeHidden()
        #expect(env.model.scope == .notes)
        #expect(env.model.focusedNoteID != nil)

        env.model.selectScope(.pinned)
        env.model.togglePinSelected()
        env.state.showNotesIfScopeHidden()
        #expect(env.model.scope == .notes)

        env.model.selectScope(.tag("gone"))
        #expect(env.state.isScopeInSidebar)
        env.model.removeScopeTagFromSelected()
        env.state.showNotesIfScopeHidden()
        #expect(env.model.scope == .notes)

        // Always-shown sections stay selected even when empty.
        env.model.selectScope(.trash)
        env.state.showNotesIfScopeHidden()
        #expect(env.model.scope == .trash)
    }

    @Test func restoredScopeThatIsGoneFallsBackToNotes() throws {
        let suiteName = "TheoNotesMainWindowTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("archive", forKey: "MainWindow.scope")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TheoNotesMainWindow-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = try AppEnvironment(paths: AppPaths(root: root))
        let note = try environment.store.create(text: "Only")

        let state = MainWindowState(environment: environment, defaults: defaults)
        #expect(state.model.scope == .notes)
        #expect(state.model.focusedNoteID == note.id)
    }

    /// GUI-gate F5: after ⌘N the editor gets keyboard focus, also once SwiftUI applied the update.
    @Test func newNoteFocusesTheEditorAfterLoadingIt() async throws {
        let env = try Env()
        env.state.newNote()
        let id = try #require(env.model.focusedNoteID)
        let loadIndex = try #require(env.page.delivered.lastIndex {
            if case .loadNote(let noteId, _, _, _, _, _, _) = $0 { noteId == id } else { false }
        })
        #expect(env.page.delivered[(loadIndex + 1)...].contains(.focus))

        let focusCount = env.page.delivered.filter { $0 == .focus }.count
        try await Task.sleep(for: .milliseconds(50))
        #expect(env.page.delivered.filter { $0 == .focus }.count == focusCount + 1)
    }

    /// With no split view to collapse the note list in, ⌃1 doesn't claim editor only.
    @Test func editorOnlyWithoutAWindowStaysNotesAndEditor() throws {
        let env = try Env()
        env.state.setLayout(.editorOnly)
        #expect(env.state.layout == .notesAndEditor)
        #expect(env.state.columnVisibility == .doubleColumn)
        #expect(UserDefaults(suiteName: env.suiteName)?.string(forKey: "MainWindow.layout") == "notesAndEditor")
    }
}
