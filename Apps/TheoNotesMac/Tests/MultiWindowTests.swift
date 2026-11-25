// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import Testing
@testable import TheoNotes

/// M4 Task 9: the same note in several windows, per-window state, history, note windows.
@MainActor
@Suite struct MultiWindowTests {
    @MainActor
    final class Env {
        let root: URL
        let suiteName = "TheoNotesMultiWindow-\(UUID().uuidString)"
        let defaults: UserDefaults
        let environment: AppEnvironment
        var conflictCopies: [String] = []

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("TheoNotesMultiWindow-\(UUID().uuidString)", isDirectory: true)
            defaults = UserDefaults(suiteName: suiteName)!
            environment = try AppEnvironment(paths: AppPaths(root: root))
            _ = environment.addConflictCopyObserver { [unowned self] in self.conflictCopies.append($0) }
        }

        deinit {
            UserDefaults().removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        var store: NoteStore { environment.store }

        /// A ready editor with a fake page.
        func editor(showing noteId: String? = nil) throws -> (EditorBridgeController, FakeEditorPage) {
            let page = FakeEditorPage()
            let controller = EditorBridgeController(
                environment: environment, page: page, openExternally: { _ in }, checksumInterval: nil
            )
            _ = controller.handle(.ready(version: EditorBridge.version))
            if let noteId { try controller.open(noteId: noteId) }
            return (controller, page)
        }
    }

    private func insert(_ s: String, at pos: Int, length: Int) -> ChangeSet {
        var sections: [ChangeSet.Section] = []
        if pos > 0 { sections.append(.retain(pos)) }
        sections.append(.replace(deleteLength: 0, insert: s))
        if length - pos > 0 { sections.append(.retain(length - pos)) }
        return ChangeSet(sections: sections)
    }

    private func typed(_ noteId: String, _ txId: String, base: Int, _ changeSet: ChangeSet) -> EditorToHostMessage {
        .changes(noteId: noteId, txId: txId, baseRevision: base, revision: base + 1, changeSet: changeSet)
    }

    // MARK: - Same note in two windows (Review Focus #5)

    @Test func typingInOneEditorUpdatesTheOtherWithoutConflictCopies() throws {
        let env = try Env()
        let noteId = try env.store.create(text: "hello").id
        let (a, pageA) = try env.editor(showing: noteId)
        let (b, pageB) = try env.editor(showing: noteId)
        let session = try env.environment.session(for: noteId)
        #expect(a.session === session && b.session === session)
        #expect(session.textListenerCount == 2)

        let first = insert(" world", at: 5, length: 5)
        #expect(a.handle(typed(noteId, "a1", base: 0, first)) == .acked(revision: 1))
        #expect(pageB.delivered.last == .applyExternalChange(noteId: noteId, revision: 1, changeSet: first))
        #expect(!pageA.delivered.contains { if case .applyExternalChange = $0 { true } else { false } })

        // B continues on revision 1 (its page applied the change) and A receives B's edit.
        let second = insert("!", at: 11, length: 11)
        #expect(b.handle(typed(noteId, "b1", base: 1, second)) == .acked(revision: 2))
        #expect(pageA.delivered.last == .applyExternalChange(noteId: noteId, revision: 2, changeSet: second))

        env.environment.flushAll()
        env.environment.databaseDidChange() // the echo of the commit
        #expect(session.text == "hello world!")
        #expect(try env.store.note(id: noteId)?.text == "hello world!")
        #expect(try env.store.allNotes().map(\.id) == [noteId])
        #expect(env.conflictCopies.isEmpty)
    }

    @Test func concurrentTypingReloadsTheOtherEditorInsteadOfMakingACopy() throws {
        let env = try Env()
        let noteId = try env.store.create(text: "abc").id
        let (a, _) = try env.editor(showing: noteId)
        let (b, pageB) = try env.editor(showing: noteId)
        pageB.autoComplete = false

        #expect(a.handle(typed(noteId, "a1", base: 0, insert("A", at: 3, length: 3))) == .acked(revision: 1))
        // B typed at revision 0 before its page handled A's change: the delivery guard refuses it
        // and B reloads the acked text; nothing is merged or copied.
        let loadsBefore = pageB.loadNotes.count
        #expect(b.handle(typed(noteId, "b1", base: 0, insert("B", at: 0, length: 3))) == .needsFullText(currentRevision: 1))
        pageB.completeDeliveries()
        #expect(pageB.loadNotes.count == loadsBefore + 1)
        #expect(pageB.loadNotes.last == .loadNote(noteId: noteId, text: "abcA", revision: 1, readOnly: false))

        env.environment.flushAll()
        env.environment.databaseDidChange()
        #expect(try env.store.note(id: noteId)?.text == "abcA")
        #expect(try env.store.allNotes().count == 1)
        #expect(env.conflictCopies.isEmpty)
    }

    @Test func externalChangeReachesEveryEditorShowingTheNote() throws {
        let env = try Env()
        let noteId = try env.store.create(text: "one").id
        let (a, pageA) = try env.editor(showing: noteId)
        let (b, pageB) = try env.editor(showing: noteId)
        let cli = NoteStore(db: try AppDatabase(path: env.environment.paths.database), notifier: nil, paths: env.environment.paths)
        _ = try cli.updateText(id: noteId, text: "one two", expectedRevision: 1)
        env.environment.databaseDidChange()
        for page in [pageA, pageB] {
            guard case .applyExternalChange(let id, let revision, let changeSet) = page.delivered.last else {
                Issue.record("expected applyExternalChange, got \(String(describing: page.delivered.last))")
                continue
            }
            #expect(id == noteId && revision == 1)
            #expect(try changeSet.apply(to: "one") == "one two")
        }
        withExtendedLifetime((a, b)) {} // a released controller stops listening
    }

    @Test func aSessionStaysCachedWhileAnyEditorShowsIt() throws {
        let env = try Env()
        let noteId = try env.store.create(text: "kept").id
        let (a, _) = try env.editor(showing: noteId)
        let (b, _) = try env.editor(showing: noteId)
        let session = try #require(a.session)

        a.showNoNote()
        #expect(session.textListenerCount == 1)
        env.environment.flushAll()
        #expect(env.environment.existingSession(for: noteId) === session)

        b.showNoNote()
        #expect(session.textListenerCount == 0)
        env.environment.flushAll()
        #expect(env.environment.existingSession(for: noteId) == nil)
    }

    @Test func switchingNotesDetachesOnlyThatEditor() throws {
        let env = try Env()
        let shared = try env.store.create(text: "shared").id
        let other = try env.store.create(text: "other").id
        let (a, _) = try env.editor(showing: shared)
        let (b, pageB) = try env.editor(showing: shared)
        try a.open(noteId: other)
        let session = try env.environment.session(for: shared)
        #expect(session.textListenerCount == 1)

        // A late transaction A typed into `shared` before switching still reaches B.
        let late = insert("!", at: 6, length: 6)
        #expect(a.handle(typed(shared, "late", base: 0, late)) == .acked(revision: 1))
        #expect(pageB.delivered.last == .applyExternalChange(noteId: shared, revision: 1, changeSet: late))
        withExtendedLifetime(b) {}
    }

    // MARK: - Per-window state

    @Test func openNoteIdsAreTrackedPerWindow() throws {
        let env = try Env()
        let a = try env.store.create(text: "a").id
        let b = try env.store.create(text: "b").id
        let first = LibraryModel(environment: env.environment)
        let second = LibraryModel(environment: env.environment)
        first.focusedNoteID = a
        second.focusedNoteID = b
        #expect(env.environment.openNoteIds == [a, b])
        first.focusedNoteID = b
        #expect(env.environment.openNoteIds == [b])
        second.close()
        #expect(env.environment.openNoteIds == [b])
        first.close()
        #expect(env.environment.openNoteIds.isEmpty)
    }

    @Test func eachWindowKeepsItsOwnScopeAndSelection() throws {
        let env = try Env()
        let work = try env.store.create(text: "Work #work").id
        let home = try env.store.create(text: "Home #home").id
        let first = MainWindowState(environment: env.environment, defaults: env.defaults, editor: try env.editor().0)
        let second = MainWindowState(environment: env.environment, defaults: env.defaults, editor: try env.editor().0)
        first.model.selectScope(.tag("work"))
        second.model.selectScope(.tag("home"))
        #expect(first.model.focusedNoteID == work)
        #expect(second.model.focusedNoteID == home)
        first.showFocusedNote()
        second.showFocusedNote()
        #expect(first.editor.session?.noteId == work)
        #expect(second.editor.session?.noteId == home)
    }

    @Test func conflictCopiesAreReportedToEveryWindow() throws {
        let env = try Env()
        let base = "line1\nline2\nline3"
        let noteId = try env.store.create(text: base).id
        let first = LibraryModel(environment: env.environment)
        let second = LibraryModel(environment: env.environment)
        let session = try env.environment.session(for: noteId)
        let local = ChangeSet(sections: [.retain(6), .replace(deleteLength: 5, insert: "local2"), .retain(6)])
        _ = session.apply(txId: "t1", baseRevision: 0, changeSet: local, origin: nil)
        let cli = NoteStore(db: try AppDatabase(path: env.environment.paths.database), notifier: nil, paths: env.environment.paths)
        _ = try cli.updateText(id: noteId, text: "line1\nremote2\nline3", expectedRevision: 1)
        try session.flush()

        let copy = try #require(try env.store.allNotes().first { $0.id != noteId }?.id)
        #expect(first.banner == .conflictCopiesCreated(noteIds: [copy]))
        #expect(second.banner == .conflictCopiesCreated(noteIds: [copy]))
        #expect(env.conflictCopies == [copy])
    }

    @Test func aClosedWindowNoLongerReceivesConflictCopies() throws {
        let env = try Env()
        let closed = LibraryModel(environment: env.environment)
        closed.close()
        let base = "x\ny\nz"
        let noteId = try env.store.create(text: base).id
        let session = try env.environment.session(for: noteId)
        _ = session.apply(txId: "t1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(2), .replace(deleteLength: 1, insert: "Y"), .retain(2)]), origin: nil)
        let cli = NoteStore(db: try AppDatabase(path: env.environment.paths.database), notifier: nil, paths: env.environment.paths)
        _ = try cli.updateText(id: noteId, text: "x\nyy\nz", expectedRevision: 1)
        try session.flush()
        #expect(closed.banner == nil)
        #expect(env.conflictCopies.count == 1)
    }

    // MARK: - History (⌘[ / ⌘])

    @Test func mainWindowHistoryGoesBackAndForwardThroughVisitedNotes() throws {
        let env = try Env()
        let ids = try ["a", "b", "c"].map { try env.store.create(text: $0).id }
        let model = LibraryModel(environment: env.environment)
        ids.forEach { model.selectNotes([$0]) }
        #expect(model.canGoBack && !model.canGoForward)

        model.goBack()
        #expect(model.focusedNoteID == ids[1])
        #expect(model.selectedNoteIDs == [ids[1]])
        model.goBack()
        #expect(model.focusedNoteID == ids[0])
        #expect(!model.canGoBack)
        model.goForward()
        #expect(model.focusedNoteID == ids[1])
        #expect(model.canGoForward)
        // A new visit drops the forward entries.
        model.selectNotes([ids[0]])
        #expect(!model.canGoForward)
    }

    @Test func historyRevealsANoteOutsideTheSelectedScopeAndSkipsDeletedOnes() throws {
        let env = try Env()
        let tagged = try env.store.create(text: "Tagged #t").id
        let doomed = try env.store.create(text: "Doomed").id
        let archived = try env.store.create(text: "Archived").id
        let model = LibraryModel(environment: env.environment)
        model.selectNotes([tagged])
        model.selectNotes([archived])
        model.selectNotes([doomed])
        try env.store.archive([archived])
        model.selectScope(.tag("t"))
        #expect(model.focusedNoteID == tagged)
        try env.store.trash([doomed])
        _ = try env.environment.closeSessions(ids: [doomed]) { try env.store.deletePermanently([doomed]) }

        // tagged (current, re-visited by the scope switch) ← doomed (gone) ← archived ← tagged.
        model.goBack()
        #expect(model.focusedNoteID == archived)
        #expect(model.scope == .archive)
        model.goBack()
        #expect(model.focusedNoteID == tagged)
        #expect(model.items.contains { $0.id == tagged })
    }

    // MARK: - Note windows

    @Test func noteWindowShowsItsNoteAndNavigatesWithItsOwnHistory() throws {
        let env = try Env()
        let first = try env.store.create(text: "First").id
        let second = try env.store.create(text: "Second").id
        let (editor, page) = try env.editor()
        let window = NoteWindowState(environment: env.environment, noteId: first, editor: editor)
        #expect(editor.session?.noteId == first)
        #expect(window.title == "First")
        #expect(env.environment.openNoteIds == [first])
        #expect(page.delivered.contains(.focus))

        window.show(noteId: second) // e.g. a wiki link clicked inside the window
        #expect(editor.session?.noteId == second)
        #expect(window.title == "Second")
        #expect(env.environment.openNoteIds == [second])
        window.goBack()
        #expect(window.noteId == first)
        #expect(editor.session?.noteId == first)
        window.goForward()
        #expect(window.noteId == second)

        window.close()
        #expect(editor.session == nil)
        #expect(env.environment.openNoteIds.isEmpty)
    }

    @Test func noteWindowAndMainWindowEditTheSameSession() throws {
        let env = try Env()
        let noteId = try env.store.create(text: "same").id
        let main = MainWindowState(environment: env.environment, defaults: env.defaults, editor: try env.editor().0)
        main.model.selectNotes([noteId])
        main.showFocusedNote()
        let (noteEditor, notePage) = try env.editor()
        let noteWindow = NoteWindowState(environment: env.environment, noteId: noteId, editor: noteEditor)
        #expect(main.editor.session === noteEditor.session)

        let edit = insert("!", at: 4, length: 4)
        #expect(main.editor.handle(typed(noteId, "m1", base: 0, edit)) == .acked(revision: 1))
        #expect(notePage.delivered.last == .applyExternalChange(noteId: noteId, revision: 1, changeSet: edit))
        #expect(noteWindow.noteId == noteId) // keeps the window (and its listener) alive
    }

    @Test func floatOnTopRaisesTheWindowLevel() throws {
        let env = try Env()
        let noteId = try env.store.create(text: "float").id
        let state = NoteWindowState(environment: env.environment, noteId: noteId, editor: try env.editor().0)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        state.attach(window: window)
        #expect(window.level == .normal)
        state.isFloating = true
        #expect(window.level == .floating)
        state.isFloating = false
        #expect(window.level == .normal)
    }

    @Test func noteWindowForAMissingNoteShowsNothing() throws {
        let env = try Env()
        let (editor, _) = try env.editor()
        let state = NoteWindowState(environment: env.environment, noteId: "missing", editor: editor)
        #expect(!state.noteExists)
        #expect(editor.session == nil)
    }

    // MARK: - Window routing (AppModel)

    @Test func openNoteInNewWindowRequestsANoteWindow() throws {
        let env = try Env()
        let app = AppModel(environment: env.environment, defaults: env.defaults)
        var requests: [WindowRequest] = []
        app.openWindowRequest = { requests.append($0) }
        app.openNoteInNewWindow(id: "n1")
        app.newMainWindow()
        #expect(requests == [.note(id: "n1"), .main])
    }

    @Test func newNoteInNewWindowCreatesATaggedNoteAndOpensIt() throws {
        let env = try Env()
        let app = AppModel(environment: env.environment, defaults: env.defaults)
        var requests: [WindowRequest] = []
        app.openWindowRequest = { requests.append($0) }
        let main = app.makeMainWindow(editor: try env.editor().0)
        _ = try env.store.create(text: "Seed #inbox")
        main.model.refresh()
        main.model.selectScope(.tag("inbox"))

        app.newNoteInNewWindow(from: main)
        guard case .note(let id) = requests.last else {
            Issue.record("expected a note window request, got \(requests)")
            return
        }
        #expect(try env.store.note(id: id)?.text == "\n\n#inbox")
        let (editor, page) = try env.editor()
        let window = app.makeNoteWindow(noteId: id, editor: editor)
        #expect(window.noteId == id)
        #expect(page.loadNotes.last == .loadNote(
            noteId: id, text: "\n\n#inbox", revision: 0, readOnly: false, selection: SelectionRange(anchor: 0, head: 0)
        ))
    }

    @Test func showMainWindowOpensOneWhenNoneIsOpen() throws {
        let env = try Env()
        let app = AppModel(environment: env.environment, defaults: env.defaults)
        var requests: [WindowRequest] = []
        app.openWindowRequest = { requests.append($0) }
        app.showMainWindow()
        #expect(requests == [.main])
    }

    @Test func doubleClickingNotesOpensEachInANewWindow() throws {
        let env = try Env()
        let app = AppModel(environment: env.environment, defaults: env.defaults)
        var requests: [WindowRequest] = []
        app.openWindowRequest = { requests.append($0) }
        let main = app.makeMainWindow(editor: try env.editor().0)
        let ids = try ["x", "y"].map { try env.store.create(text: $0).id }
        main.model.refresh()
        main.openInNewWindows(Set(ids))
        // In list order (newest first).
        #expect(requests == main.model.items.map(\.id).filter(ids.contains).map { .note(id: $0) })
    }

    // MARK: - Fix round 1

    private func cliStore(_ env: Env) throws -> NoteStore {
        NoteStore(db: try AppDatabase(path: env.environment.paths.database), notifier: nil, paths: env.environment.paths)
    }

    /// Another process changes note attributes behind the store's API (no store method sets them).
    private func writeRaw(_ env: Env, _ sql: String, _ noteId: String) throws {
        try AppDatabase(path: env.environment.paths.database).pool.write {
            try $0.execute(sql: "UPDATE note SET \(sql), revision = revision + 1 WHERE id = ?", arguments: [noteId])
        }
    }

    private func lastLoad(_ page: FakeEditorPage) -> (noteId: String, readOnly: Bool)? {
        guard case .loadNote(let id, _, _, let readOnly, _, _, _) = page.loadNotes.last else { return nil }
        return (id, readOnly)
    }

    /// I1: spec §4.9, Trash and Archive notes are read-only; the note window re-evaluates it.
    @Test func noteWindowReloadsReadOnlyWhenItsNoteIsTrashedArchivedOrRestored() throws {
        let env = try Env()
        let noteId = try env.store.create(text: "moving").id
        let (editor, page) = try env.editor()
        let window = NoteWindowState(environment: env.environment, noteId: noteId, editor: editor)
        #expect(lastLoad(page)?.readOnly == false)

        try env.store.trash([noteId])
        window.noteDidChange()
        #expect(lastLoad(page)?.noteId == noteId)
        #expect(lastLoad(page)?.readOnly == true)

        try env.store.restore([noteId])
        window.noteDidChange()
        #expect(lastLoad(page)?.readOnly == false)

        try env.store.archive([noteId])
        window.noteDidChange()
        #expect(lastLoad(page)?.readOnly == true)

        // A text-only change (e.g. typing in another window) is no reason to reload.
        let loads = page.loadNotes.count
        try env.store.restore([noteId])
        window.noteDidChange()
        _ = try env.store.updateText(id: noteId, text: "moving on", expectedRevision: try #require(try env.store.revision(id: noteId)))
        window.noteDidChange()
        #expect(page.loadNotes.count == loads + 1)
    }

    @Test func noteWindowReloadsReadOnlyWhenItsNoteIsLockedOrMadeReadOnlyElsewhere() throws {
        let env = try Env()
        let noteId = try env.store.create(text: "guarded").id
        let (editor, page) = try env.editor()
        let window = NoteWindowState(environment: env.environment, noteId: noteId, editor: editor)

        try writeRaw(env, "isReadOnly = 1", noteId)
        window.noteDidChange()
        #expect(lastLoad(page)?.readOnly == true)

        try writeRaw(env, "isReadOnly = 0", noteId)
        window.noteDidChange()
        #expect(lastLoad(page)?.readOnly == false)

        try writeRaw(env, "isLocked = 1", noteId)
        window.noteDidChange()
        #expect(lastLoad(page)?.readOnly == true)
    }

    /// I1: deleted by another process (not through `closeSessions`): the window lets go and no
    /// late edit is accepted, even when the window notices before the environment does.
    @Test func noteWindowLetsGoWhenItsNoteIsDeletedOutOfProcess() throws {
        let env = try Env()
        let noteId = try env.store.create(text: "doomed").id
        let (editor, page) = try env.editor()
        let window = NoteWindowState(environment: env.environment, noteId: noteId, editor: editor)
        #expect(editor.handle(typed(noteId, "t1", base: 0, insert("!", at: 6, length: 6))) == .acked(revision: 1))

        try cliStore(env).deletePermanently([noteId])
        window.noteDidChange()

        #expect(!window.noteExists)
        #expect(editor.session == nil)
        #expect(env.environment.existingSession(for: noteId) == nil)
        #expect(env.environment.openNoteIds.isEmpty)
        #expect(lastLoad(page)?.noteId == EditorBridgeController.placeholderNoteId)
        #expect(editor.handle(typed(noteId, "t2", base: 1, insert("?", at: 7, length: 7))) == .needsFullText(currentRevision: 0))
        #expect(env.environment.existingSession(for: noteId) == nil)
    }

    @Test func anOutOfProcessDeleteClosesTheSessionForEveryEditor() throws {
        let env = try Env()
        let noteId = try env.store.create(text: "doomed").id
        let (a, _) = try env.editor(showing: noteId)
        let (b, _) = try env.editor(showing: noteId)

        try cliStore(env).deletePermanently([noteId])
        env.environment.databaseDidChange()

        #expect(a.session == nil && b.session == nil)
        #expect(env.environment.existingSession(for: noteId) == nil)
        #expect(a.handle(typed(noteId, "late", base: 0, insert("!", at: 6, length: 6))) == .needsFullText(currentRevision: 0))
        #expect(env.environment.existingSession(for: noteId) == nil)
    }

    /// Minor 3: the delivery guard also holds for the note the editor just switched away from.
    @Test func changesForThePreviousNoteRacingAForwardedChangeAreRefused() throws {
        let env = try Env()
        let shared = try env.store.create(text: "shared").id
        let other = try env.store.create(text: "other").id
        let (a, pageA) = try env.editor(showing: shared)
        let (b, _) = try env.editor(showing: shared)
        pageA.autoComplete = false

        // B types; the forwarded change is still on its way to A's page when A switches notes.
        #expect(b.handle(typed(shared, "b1", base: 0, insert("B", at: 0, length: 6))) == .acked(revision: 1))
        try a.open(noteId: other)
        // A's page typed into `shared` before it handled either delivery: its own rejected edit
        // made it think it is at revision 1, which now names B's text.
        let stale = typed(shared, "a2", base: 1, insert("A", at: 7, length: 7))
        #expect(a.handle(stale) == .needsFullText(currentRevision: 1))
        #expect(try env.environment.session(for: shared).text == "Bshared")

        pageA.completeDeliveries()
        #expect(a.session?.noteId == other)
    }

    /// Minor 4: a main window released without a close notification still lets go of its note.
    @Test func aReleasedMainWindowIsForgottenAndClosed() throws {
        let env = try Env()
        let noteId = try env.store.create(text: "held").id
        let app = AppModel(environment: env.environment, defaults: env.defaults)
        weak var released: MainWindowState?
        do {
            let main = app.makeMainWindow(editor: try env.editor().0)
            main.model.selectNotes([noteId])
            main.showFocusedNote()
            #expect(env.environment.openNoteIds == [noteId])
            released = main
        }
        #expect(released == nil)
        #expect(app.frontmostMainWindow == nil)
        #expect(env.environment.openNoteIds.isEmpty)
        #expect(try env.environment.session(for: noteId).textListenerCount == 0)
    }

    /// Minor 5: in-window navigation reports the shown note (the host keeps the scene value in sync).
    @Test func noteWindowReportsEveryNoteItNavigatesTo() throws {
        let env = try Env()
        let first = try env.store.create(text: "First").id
        let second = try env.store.create(text: "Second").id
        let window = NoteWindowState(environment: env.environment, noteId: first, editor: try env.editor().0)
        var shown: [String] = []
        window.onNoteChange = { shown.append($0) }
        window.show(noteId: second)
        window.goBack()
        window.goForward()
        window.show(noteId: second) // already shown: no change
        #expect(shown == [second, first, second])
    }

    /// Minor 6: close() first stops listening, then flushes, then clears the window's open notes, so
    /// the session ends up committed and evicted.
    @Test func closingAMainWindowDetachesFlushesAndClearsItsOpenNote() throws {
        let env = try Env()
        let noteId = try env.store.create(text: "close").id
        let main = MainWindowState(environment: env.environment, defaults: env.defaults, editor: try env.editor().0)
        main.model.selectNotes([noteId])
        main.showFocusedNote()
        let session = try #require(main.editor.session)
        #expect(main.editor.handle(typed(noteId, "t1", base: 0, insert("d", at: 5, length: 5))) == .acked(revision: 1))

        main.close()
        #expect(session.textListenerCount == 0)
        #expect(main.editor.session == nil)
        #expect(try env.store.note(id: noteId)?.text == "closed")
        #expect(env.environment.openNoteIds.isEmpty)
        // Evicted: only possible once no editor listened and the text was committed.
        #expect(env.environment.existingSession(for: noteId) == nil)
    }

    /// Minor 10 and the merge with Task 5: Bear's titles, and no menu item shares a window shortcut.
    @Test func windowCommandsAreInTheMenuBarWithoutShortcutConflicts() throws {
        let mainMenu = try #require(NSApp.mainMenu)
        func items(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) }
        }
        let all = mainMenu.items.compactMap(\.submenu).flatMap(items)
        let note = try #require(mainMenu.items.first { $0.title == "Note" }?.submenu)
        #expect(note.items.contains { $0.title == "Open In New Window" })
        let expected: [(title: String, key: String, flags: NSEvent.ModifierFlags)] = [
            ("New Note in New Window", "n", [.command, .option]),
            ("Go Back", "[", [.command]),
            ("Go Forward", "]", [.command]),
            ("Main Window", "\\", [.command]),
        ]
        for (title, key, flags) in expected {
            let item = try #require(all.first { $0.title == title }, "\(title) missing")
            // AppKit remaps punctuation shortcuts to the keyboard layout (German: ⌘[ → ⌘ö,
            // ⌘] → ⌘ä, ⌘\ → ⌘#); letters stay.
            #expect(
                item.keyEquivalent == key || (item.allowsAutomaticKeyEquivalentLocalization && !key.first!.isLetter),
                "\(title): \(item.keyEquivalent.debugDescription)"
            )
            #expect(item.keyEquivalentModifierMask.intersection([.command, .option, .shift, .control]) == flags, "\(title)")
            let sharing = all.filter {
                $0.keyEquivalent == item.keyEquivalent
                    && $0.keyEquivalentModifierMask.intersection([.command, .option, .shift, .control]) == flags
            }
            #expect(sharing.map(\.title) == [title], "\(title) shares its shortcut")
        }
        #expect(all.contains { $0.title == "Float on Top" })
        #expect(all.contains { $0.title == "New Window" && $0.keyEquivalent.isEmpty })
    }

    // MARK: - Fix round 2: the Format menu in note windows

    private func commands(_ page: FakeEditorPage) -> [HostToEditorMessage] {
        page.delivered.filter { if case .applyCommand = $0 { true } else { false } }
    }

    /// A main window showing one note and a note window showing another, in a real window whose
    /// editor has keyboard focus.
    private func mainAndFocusedNoteWindow(_ env: Env) throws
        -> (main: MainWindowState, mainPage: FakeEditorPage, note: NoteWindowState, notePage: FakeEditorPage, window: NSWindow) {
        let x = try env.store.create(text: "Main note").id
        let y = try env.store.create(text: "Window note").id
        let (mainEditor, mainPage) = try env.editor()
        let main = MainWindowState(environment: env.environment, defaults: env.defaults, editor: mainEditor)
        main.model.selectNotes([x])
        main.showFocusedNote()
        let (noteEditor, notePage) = try env.editor()
        let note = NoteWindowState(environment: env.environment, noteId: y, editor: noteEditor)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = noteEditor.webView
        window.orderFront(nil)
        note.attach(window: window)
        #expect(window.makeFirstResponder(noteEditor.webView))
        return (main, mainPage, note, notePage, window)
    }

    private func commandKey(_ characters: String, _ keyCode: UInt16, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        )!
    }

    @Test func formatCommandsReachTheKeyNoteWindowsEditorNotTheMainWindows() throws {
        let env = try Env()
        let (main, mainPage, note, notePage, window) = try mainAndFocusedNoteWindow(env)
        defer { window.close() }
        let bold = try #require(FormatMenu.items.first { $0.title == "Bold" })

        // The note window is key: SwiftUI's focused main window is nil, the note window is set.
        let target = try #require(FormatRouting.target(mainWindow: nil, noteWindow: note))
        #expect(target === note)
        #expect(target.editorMenuState.enabled)
        target.perform(bold)
        #expect(commands(notePage) == [.applyCommand(name: .bold)])

        // ⌘B typed in the note window's editor: its own key monitor runs the command there.
        let event = commandKey("b", 11, in: window)
        #expect(!main.handleKeyDown(event))
        #expect(note.handleKeyDown(event))
        #expect(commands(notePage) == [.applyCommand(name: .bold), .applyCommand(name: .bold)])
        #expect(commands(mainPage).isEmpty)

        // No focused window, no target: the menu stays disabled (`EditorMenuState.unavailable`).
        #expect(FormatRouting.target(mainWindow: nil, noteWindow: nil) == nil)
        // The note window's editor lost focus: its items are off.
        #expect(window.makeFirstResponder(nil))
        #expect(!note.editorMenuState.enabled)
        #expect(!note.handleKeyDown(event))
    }

    @Test func findNextReachesTheKeyNoteWindowsEditorNotTheMainWindows() throws {
        let env = try Env()
        let (main, mainPage, note, notePage, window) = try mainAndFocusedNoteWindow(env)
        defer { window.close() }
        let next = try #require(FindMenu.items.first { $0.command == .findNext })

        // Edit ▸ Find ▸ Find Next with the note window key: enabled there and run in its editor.
        let target = try #require(FormatRouting.target(mainWindow: nil, noteWindow: note))
        #expect(target === note)
        #expect(next.isEnabled(in: target.editorMenuState))
        target.perform(next)
        #expect(commands(notePage) == [.applyCommand(name: .findNext)])

        // ⌘G typed in the note window's editor: its key monitor takes it before WebKit.
        let event = commandKey("g", 5, in: window)
        #expect(!main.handleKeyDown(event))
        #expect(note.handleKeyDown(event))
        #expect(commands(notePage) == [.applyCommand(name: .findNext), .applyCommand(name: .findNext)])
        #expect(commands(mainPage).isEmpty)
    }

    @Test func formatCheckmarksFollowTheKeyWindowsEditor() throws {
        let env = try Env()
        let (main, _, note, _, window) = try mainAndFocusedNoteWindow(env)
        defer { window.close() }
        let mainNote = try #require(main.editor.session?.noteId)
        let windowNote = try #require(note.editor.session?.noteId)
        let boldState = FormatState(active: [.bold], headingLevel: nil, inTodo: false, inCode: false, canIndent: false)
        let italicState = FormatState(active: [.italic], headingLevel: 2, inTodo: false, inCode: false, canIndent: false)
        _ = main.editor.handle(.formatState(noteId: mainNote, state: boldState))
        _ = note.editor.handle(.formatState(noteId: windowNote, state: italicState))
        let bold = try #require(FormatMenu.items.first { $0.title == "Bold" })
        let italic = try #require(FormatMenu.items.first { $0.title == "Italic" })

        let noteKey = try #require(FormatRouting.target(mainWindow: nil, noteWindow: note)).editorMenuState
        #expect(noteKey.format == italicState)
        #expect(bold.isChecked(in: noteKey.format) == false)
        #expect(italic.isChecked(in: noteKey.format) == true)

        let mainKey = try #require(FormatRouting.target(mainWindow: main, noteWindow: nil)).editorMenuState
        #expect(mainKey.format == boldState)
        #expect(bold.isChecked(in: mainKey.format) == true)
        #expect(italic.isChecked(in: mainKey.format) == false)
    }
}
