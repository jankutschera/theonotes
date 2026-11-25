// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Testing
@testable import TheoNotes

/// Workspaces in a main window (M4 Task 8, spec §3.5/§4.2): entering and leaving, what the
/// window lists, new notes, tag rename/delete, search and persistence.
@MainActor
@Suite struct WorkspaceModelTests {
    @MainActor
    final class Env {
        let root: URL
        let suiteName = "TheoNotesWorkspaceTests-\(UUID().uuidString)"
        let environment: AppEnvironment
        let page = FakeEditorPage()
        let editor: EditorBridgeController
        let defaults: UserDefaults
        private(set) var state: MainWindowState!

        init(setUp: (NoteStore, UserDefaults) throws -> Void = { _, _ in }) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("TheoNotesWorkspace-\(UUID().uuidString)", isDirectory: true)
            environment = try AppEnvironment(paths: AppPaths(root: root))
            defaults = UserDefaults(suiteName: suiteName)!
            try setUp(environment.store, defaults)
            editor = EditorBridgeController(environment: environment, page: page, openExternally: { _ in }, checksumInterval: nil)
            _ = editor.handle(.ready(version: 1))
            state = MainWindowState(environment: environment, defaults: defaults, editor: editor)
        }

        /// A second window on the same defaults (as a relaunch would restore it).
        func reopen() -> MainWindowState {
            MainWindowState(environment: environment, defaults: defaults)
        }

        deinit {
            UserDefaults().removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        var store: NoteStore { environment.store }
        var model: LibraryModel { state.model }
    }

    private let start = Date(timeIntervalSince1970: 1_792_670_400)

    private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("\(what): not within 2 s")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func paths(_ nodes: [TagNode]) -> [String] {
        nodes.flatMap { [$0.path] + paths($0.children) }
    }

    /// A (#work), B (#work/p), C (#home), Shop (#workshop), D (#work, archived).
    private func seed(_ store: NoteStore) throws -> [String: String] {
        var ids: [String: String] = [:]
        for (i, (key, text)) in [("a", "A #work"), ("b", "B #work/p"), ("c", "C #home"), ("shop", "Shop #workshop"), ("d", "D #work")]
            .enumerated() {
            ids[key] = try store.create(text: text, now: start.addingTimeInterval(-Double(i))).id
        }
        try store.archive([ids["d"]!])
        return ids
    }

    @Test func testEnteringAWorkspaceNarrowsTheWindow() throws {
        var ids: [String: String] = [:]
        let env = try Env { store, _ in ids = try seed(store) }
        env.model.selectScope(.tag("home"))

        env.model.enterWorkspace("work")
        #expect(env.model.workspace == Workspace(path: "work"))
        #expect(env.model.scope == .notes)
        #expect(env.model.items.map(\.id) == [ids["a"]!, ids["b"]!])
        #expect(paths(env.model.tagTree) == ["work", "work/p"])
        #expect(env.model.counts.notes == 2)
        #expect(env.model.counts.archive == 1)
        #expect(env.model.focusedNoteID == ids["a"])
        #expect(env.model.workspaceChoices.recent == [Workspace(path: "work")])

        env.model.selectScope(.archive)
        #expect(env.model.items.map(\.id) == [ids["d"]!])

        env.model.dismissWorkspace()
        #expect(env.model.workspace == nil)
        #expect(env.model.scope == .archive)
        env.model.selectScope(.notes)
        #expect(env.model.items.count == 4)
        #expect(paths(env.model.tagTree) == ["home", "work", "work/p", "workshop"])
    }

    @Test func testSwitchingDirectlyBetweenWorkspaces() throws {
        var ids: [String: String] = [:]
        let env = try Env { store, _ in ids = try seed(store) }
        env.model.enterWorkspace("work")
        env.model.enterWorkspace("home")
        #expect(env.model.items.map(\.id) == [ids["c"]!])
        #expect(env.model.workspaceChoices.recent.map(\.path) == ["home", "work"])
    }

    @Test func testSwitcherOffersPinnedRootTags() throws {
        let env = try Env { store, _ in
            _ = try seed(store)
            try store.setTagPinned("home", pinned: true)
        }
        env.model.enterWorkspace("work")
        // Pinned tags outside the workspace leave the tag tree but stay in the switcher.
        #expect(!paths(env.model.tagTree).contains("home"))
        #expect(env.model.workspaceChoices.pinned == [Workspace(path: "home")])
    }

    @Test func testNewNoteInAWorkspaceGetsItsTag() throws {
        let env = try Env { store, _ in
            _ = try seed(store)
            _ = try store.create(text: "Both #home #work")
        }
        env.model.enterWorkspace("work")

        let plain = try env.model.newNote()
        #expect(try env.store.note(id: plain)?.text == "\n\n#work")
        #expect(env.model.items.contains { $0.id == plain })

        // A tag inside the workspace already puts the note there.
        env.model.selectScope(.tag("work/p"))
        let sub = try env.model.newNote()
        #expect(try env.store.note(id: sub)?.text == "\n\n#work/p")

        // A tag of the workspace's notes outside it: the workspace tag is added too.
        env.model.selectScope(.tag("home"))
        let home = try env.model.newNote()
        #expect(try env.store.note(id: home)?.text == "\n\n#home #work")
        #expect(env.model.items.contains { $0.id == home })

        // ⌥⌘N (a note window) makes the same note.
        env.model.selectScope(.notes)
        let caret = try env.model.createNoteForScope()
        #expect(try env.store.note(id: caret.noteId)?.text == "\n\n#work")
    }

    @Test func testRenamingTheWorkspaceTagFollowsItAndDeletingItLeaves() throws {
        let env = try Env { store, _ in _ = try seed(store) }
        env.model.enterWorkspace("work")
        #expect(env.model.renameTag("work", to: "job", undoManager: nil))
        #expect(env.model.workspace?.path == "job")
        #expect(env.model.items.count == 2)

        env.model.enterWorkspace("job/p")
        #expect(env.model.renameTag("job", to: "career", undoManager: nil))
        #expect(env.model.workspace?.path == "career/p")

        env.model.deleteTag("career", undoManager: nil)
        #expect(env.model.workspace == nil)
    }

    @Test func testRevealingANoteOutsideTheWorkspaceLeavesIt() throws {
        var ids: [String: String] = [:]
        let env = try Env { store, _ in ids = try seed(store) }
        env.model.enterWorkspace("work")
        env.model.reveal(noteId: ids["b"]!)
        #expect(env.model.workspace != nil, "a note inside keeps the workspace")

        env.model.reveal(noteId: ids["c"]!)
        #expect(env.model.workspace == nil)
        #expect(env.model.focusedNoteID == ids["c"])
        #expect(env.model.items.contains { $0.id == ids["c"]! })
    }

    @Test func testSearchRunsWithinTheWorkspace() async throws {
        var ids: [String: String] = [:]
        let env = try Env { store, _ in ids = try seed(store) }
        env.model.search.query = "o"
        try await waitUntil("results everywhere") { env.model.items.count == 4 }

        env.model.enterWorkspace("home")
        try await waitUntil("results in the workspace") { env.model.items.map(\.id) == [ids["c"]!] }
        env.model.dismissWorkspace()
        try await waitUntil("results everywhere again") { env.model.items.count == 4 }
    }

    @Test func testSearchRequestCarriesTheWorkspace() async throws {
        let calls = RequestLog()
        let search = NoteSearch(debounce: .zero) { request in
            await calls.append(request)
            return SearchResult(items: [], terms: [])
        }
        search.update(scope: .notes, sort: .modifiedDescending, workspace: Workspace(path: "work"))
        search.query = "q"
        try await waitUntil("search") { calls.requests.count == 1 }
        #expect(calls.requests.first?.workspace == Workspace(path: "work"))

        search.update(scope: .notes, sort: .modifiedDescending, workspace: nil)
        #expect(search.isAwaitingNewResults, "a changed workspace is a new search")
        try await waitUntil("search again") { calls.requests.count == 2 }
        #expect(calls.requests.last?.workspace == nil)
    }

    @MainActor
    final class RequestLog {
        private(set) var requests: [NoteSearch.Request] = []
        func append(_ request: NoteSearch.Request) { requests.append(request) }
    }

    // MARK: - Persistence (shared restoration keys, ruling R13)

    @Test func testTheWorkspaceIsRestored() throws {
        var ids: [String: String] = [:]
        let env = try Env { store, _ in ids = try seed(store) }
        env.model.enterWorkspace("work")
        env.state.saveSelection()

        let restored = env.reopen()
        #expect(restored.model.workspace?.path == "work")
        #expect(restored.model.items.map(\.id) == [ids["a"]!, ids["b"]!])

        restored.model.dismissWorkspace()
        restored.saveSelection()
        #expect(env.reopen().model.workspace == nil)
    }

    // MARK: - Final fix wave (T8 carries)

    /// (2): another window in the renamed workspace (or on the renamed tag) follows the rename and
    /// its undo instead of being dismissed.
    @Test func testAnotherWindowFollowsARename() throws {
        let env = try Env { store, _ in _ = try seed(store) }
        let other = env.reopen()
        defer { other.close() }
        env.model.enterWorkspace("work")
        other.model.enterWorkspace("work")
        other.model.selectScope(.tag("work/p"))
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false

        undoManager.beginUndoGrouping()
        #expect(env.model.renameTag("work", to: "job", undoManager: undoManager))
        undoManager.endUndoGrouping()
        other.showNotesIfScopeHidden()
        #expect(other.model.workspace?.path == "job")
        #expect(other.model.scope == .tag("job/p"))
        #expect(other.model.items.count == 1)
        #expect(env.model.workspaceChoices.recent.map(\.path) == ["job"])

        undoManager.undo()
        other.showNotesIfScopeHidden()
        #expect(other.model.workspace?.path == "work")
        #expect(other.model.scope == .tag("work/p"))
        #expect(env.model.workspace?.path == "work")
        #expect(env.model.workspaceChoices.recent.map(\.path) == ["work"])
    }

    /// (5): undoing Delete Tag brings the workspace (and a selected tag) back.
    @Test func testUndoDeleteTagRestoresTheWorkspace() throws {
        let env = try Env { store, _ in _ = try seed(store) }
        env.model.enterWorkspace("work")
        env.model.selectScope(.tag("work/p"))
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        env.model.deleteTag("work", undoManager: undoManager)
        undoManager.endUndoGrouping()
        #expect(env.model.workspace == nil)
        #expect(env.model.scope == .notes)

        undoManager.undo()
        #expect(env.model.workspace == Workspace(path: "work"))
        #expect(env.model.scope == .tag("work/p"))
        #expect(env.model.items.count == 1)
        #expect(env.model.workspaceChoices.recent.map(\.path) == ["work"])

        undoManager.redo()
        #expect(env.model.workspace == nil)
    }

    /// (8): undoing a rename made while in the workspace returns to the old name.
    @Test func testUndoRenameWhileInTheWorkspace() throws {
        var ids: [String: String] = [:]
        let env = try Env { store, _ in ids = try seed(store) }
        env.model.enterWorkspace("work")
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        #expect(env.model.renameTag("work", to: "job", undoManager: undoManager))
        undoManager.endUndoGrouping()
        #expect(env.model.workspace?.path == "job")

        undoManager.undo()
        #expect(env.model.workspace?.path == "work")
        #expect(env.model.workspaceTagExists)
        // Both rewritten notes are listed again (the rewrite and its undo reorder them by time).
        #expect(Set(env.model.items.map(\.id)) == [ids["a"]!, ids["b"]!], "\(env.model.items.map(\.title))")
        #expect(try env.store.note(id: ids["a"]!)?.text == "A #work")
    }

    /// (6): the Notes row names the workspace as the tag tree does (a case-only rename shows).
    @Test func testTheHeaderShowsTheTreeNodesName() throws {
        let env = try Env { store, _ in _ = try seed(store) }
        env.model.enterWorkspace("WORK")
        #expect(env.model.workspace?.path == "WORK")
        #expect(env.model.workspaceTitle == "work")
        env.model.enterWorkspace("WORK/P")
        #expect(env.model.workspaceTitle == "work/p")
        // Renamed in another window (or the CLI): the row follows the tag's new spelling.
        env.model.enterWorkspace("work")
        _ = try env.store.renameTag("work", to: "Work")
        env.model.refresh()
        #expect(env.model.workspaceTitle == "Work")
        env.model.dismissWorkspace()
        #expect(env.model.workspaceTitle == nil)
    }

    /// (8): two main windows in different workspaces never see each other's notes.
    @Test func testTwoWindowsWithDifferentWorkspacesDoNotLeak() async throws {
        var ids: [String: String] = [:]
        let env = try Env { store, _ in ids = try seed(store) }
        let other = env.reopen()
        defer { other.close() }
        env.model.enterWorkspace("work")
        other.model.enterWorkspace("home")
        #expect(env.model.items.map(\.id) == [ids["a"]!, ids["b"]!])
        #expect(other.model.items.map(\.id) == [ids["c"]!])
        #expect(paths(other.model.tagTree) == ["home"])
        #expect(other.model.counts.archive == 0)

        // New notes, searches and the tag tree stay per window.
        let made = try other.model.newNote()
        #expect(try env.store.note(id: made)?.text == "\n\n#home")
        env.model.refresh()
        #expect(!env.model.items.contains { $0.id == made })
        env.model.search.query = "C"
        other.model.search.query = "C"
        try await waitUntil("searches") { env.model.search.resultIDs != nil && other.model.search.resultIDs == [ids["c"]!] }
        #expect(env.model.search.resultIDs == [])
        #expect(other.model.search.resultIDs == [ids["c"]!])
        #expect(env.model.workspace == Workspace(path: "work"))
        #expect(other.model.workspace == Workspace(path: "home"))
    }

    @Test func testARestoredWorkspaceWhoseTagIsGoneIsDismissed() throws {
        let env = try Env { store, defaults in
            _ = try seed(store)
            defaults.set("gone", forKey: "MainWindow.workspace")
        }
        #expect(env.model.workspace == nil)
        #expect(env.model.items.count == 4)
    }
}
