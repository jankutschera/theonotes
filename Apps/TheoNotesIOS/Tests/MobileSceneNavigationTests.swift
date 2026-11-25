// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import TheoNotesCore
@testable import BaerchenIOS

@Suite @MainActor struct MobileSceneNavigationTests {
    private func note(_ id: String, location: NoteLocation = .notes) -> Note {
        Note(id: id, text: "# \(id)", title: id, titleKey: id, createdAt: .now, modifiedAt: .now, location: location)
    }

    @Test func twoScenesKeepSelectionFiltersHistoryAndEphemeralRoutingIndependent() {
        let left = MobileSceneNavigation(), right = MobileSceneNavigation()
        left.selectedID = "left"
        left.scope = .tag("Work")
        left.query = "draft"
        left.workspace = Workspace(path: "Projects")
        left.pendingCaret["left"] = 42
        #expect(left.id != right.id)
        #expect(right.selectedID == nil && right.scope == .notes && right.query.isEmpty && right.workspace == nil)
        #expect(right.history.entries.isEmpty && right.pendingCaret.isEmpty && right.pendingCallbackNavigation == nil)
        right.selectedID = "right"
        #expect(left.selectedID == "left" && left.history.entries == ["left"])
        #expect(right.history.entries == ["right"])
    }

    @Test func selectionEchoStillRecordsIntentButDoesNotDuplicateHistoryAndPrivacyRestoreSuppressesIntent() {
        let scene = MobileSceneNavigation()
        scene.selectedID = "a"
        let first = scene.selectionIntentGeneration
        scene.selectedID = "a"
        #expect(scene.selectionIntentGeneration == first + 1 && scene.history.entries == ["a"])
        let beforeRestore = scene.selectionIntentGeneration
        scene.restoreDisplayedSelection("a")
        #expect(scene.selectionIntentGeneration == beforeRestore && scene.history.entries == ["a"])
        scene.selectedID = nil
        #expect(scene.selectionIntentGeneration == beforeRestore + 1 && scene.history.current == "a")
    }

    @Test func historyUsesExistingBrowserBranchAvailabilityAndCapacitySemantics() throws {
        let scene = MobileSceneNavigation(historyCapacity: 3)
        for id in ["a", "b", "c", "d"] { scene.selectedID = id }
        #expect(scene.history.entries == ["b", "c", "d"])
        #expect(scene.historyDestination(back: true, where: { $0 != "c" }) == "b")
        try scene.reveal(note("b"))
        #expect(scene.history.canGoForward && scene.history.entries == ["b", "c", "d"])
        #expect(scene.historyDestination(back: false, where: { $0 != "c" }) == "d")
        try scene.reveal(note("d"))
        #expect(scene.historyDestination(back: true) == "c")
        try scene.reveal(note("c"))
        scene.selectedID = "new"
        #expect(scene.history.entries == ["b", "c", "new"] && !scene.history.canGoForward)
        let unchanged = scene.history
        #expect(scene.historyDestination(back: true, where: { _ in false }) == nil)
        #expect(scene.history == unchanged)
    }

    @Test func revealRoutesLocationAndLeavesWorkspaceOnlyWhenCallerReportsOutsideIt() throws {
        let scene = MobileSceneNavigation()
        scene.workspace = Workspace(path: "Work"); scene.query = "old"; scene.scope = .pinned
        try scene.reveal(note("archived", location: .archive), containedInWorkspace: true)
        #expect(scene.selectedID == "archived" && scene.scope == .archive && scene.query.isEmpty)
        #expect(scene.workspace == Workspace(path: "Work"))
        try scene.reveal(note("trashed", location: .trash), containedInWorkspace: false)
        #expect(scene.workspace == nil && scene.scope == .trash && scene.selectedID == "trashed")
        try scene.reveal(note("live"))
        #expect(scene.scope == .notes)
        var deleted = note("deleted"); deleted.deletedAt = .now
        let selection = scene.selectedID, history = scene.history
        #expect(throws: StoreError.self) { try scene.reveal(deleted) }
        #expect(scene.selectedID == selection && scene.history == history)
    }

    @Test func workspaceEntryAndRestorationResetOnlyThisScene() {
        let initial = MobileRestoration(scope: .tag("Work"), workspace: "Projects", noteID: "restored")
        let scene = MobileSceneNavigation(restoration: initial, historyCapacity: 2), other = MobileSceneNavigation()
        #expect(scene.selectedID == "restored" && scene.history.current == "restored")
        #expect(scene.scope == .tag("Work") && scene.workspace == Workspace(path: "Projects"))
        scene.query = "query"; scene.enterWorkspace(Workspace(path: "Next"))
        #expect(scene.selectedID == nil && scene.scope == .notes && scene.query.isEmpty && scene.workspace?.path == "Next")
        #expect(scene.history.current == "restored")
        scene.pendingCaret["restored"] = 8
        let intent = scene.selectionIntentGeneration
        scene.reset()
        #expect(scene.selectedID == nil && scene.workspace == nil && scene.query.isEmpty && scene.scope == .notes)
        #expect(scene.history.entries.isEmpty && scene.history.capacity == 2 && scene.pendingCaret.isEmpty)
        #expect(scene.selectionIntentGeneration > intent)
        #expect(other.selectionIntentGeneration == 0 && other.history.entries.isEmpty)
    }

    @Test func queryContextGenerationIsSceneLocalAndCoversFilterAndSearchChanges() {
        let scene = MobileSceneNavigation(), other = MobileSceneNavigation()
        let start = scene.queryContextGeneration
        scene.scope = .todo
        scene.workspace = Workspace(path: "Work")
        scene.query = "needle"
        #expect(scene.queryContextGeneration == start + 3 && other.queryContextGeneration == 0)
        let current = scene.queryContextGeneration
        scene.scope = .todo
        scene.workspace = Workspace(path: "work") // Same canonical workspace, no observation restart.
        #expect(scene.queryContextGeneration == current)
        scene.query = "needle" // Preserve explicit repeated-search invalidation.
        #expect(scene.queryContextGeneration == current + 1)
    }
}
