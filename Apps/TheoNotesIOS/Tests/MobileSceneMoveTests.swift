// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import TheoNotesCore
@testable import BaerchenIOS

@Suite(.serialized) @MainActor struct MobileSceneMoveTests {
    @Test(arguments: [NoteLocation.archive, .trash, .notes])
    func moveClearsEveryMatchingSceneWithoutBroadcastingLegacyContext(location: NoteLocation) async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let moved = try library.store.create(text: "Moved fixture"), other = try library.store.create(text: "Unrelated fixture")
        if location == .notes { try library.store.trash([moved.id]) }
        // Intentionally stale legacy values must never overwrite the frontmost scene.
        library.scope = .trash; library.query = "stale legacy query"; library.selectedID = moved.id
        let left = MobileSceneNavigation(), right = MobileSceneNavigation(), unrelated = MobileSceneNavigation()
        left.selectedID = moved.id; left.scope = .tag("Work"); left.query = "left query"
        right.selectedID = moved.id; right.scope = .notes; right.query = "right query"
        unrelated.selectedID = other.id; unrelated.scope = .pinned; unrelated.query = "unrelated query"
        unrelated.workspace = Workspace(path: "Projects")
        let editors = [MobileEditor(library: library), MobileEditor(library: library), MobileEditor(library: library)]
        for (navigation, editor) in zip([left, right, unrelated], editors) {
            editor.sceneNavigation = navigation
            try library.registerScene(id: navigation.id, editor: editor, navigation: navigation, observation: nil, activity: .active)
        }
        // Registering the first window legitimately consumes the queued legacy launch
        // delivery. Establish the user's independent scene context AFTER that delivery;
        // the stale global projection intentionally remains different for the move.
        left.selectedID = moved.id; left.scope = .tag("Work"); left.query = "left query"
        try #require(left.selectedID == moved.id && left.scope == .tag("Work") && left.query == "left query")
        try #require(right.selectedID == moved.id && right.scope == .notes && right.query == "right query")
        try #require(unrelated.selectedID == other.id && unrelated.scope == .pinned && unrelated.query == "unrelated query")
        library.markSceneFrontmost(id: unrelated.id)
        try await library.moveNotesAfterDraining([moved.id], to: location, in: left)
        #expect(try library.store.note(id: moved.id)?.location == location)
        #expect(left.selectedID == nil && right.selectedID == nil)
        #expect(left.scope == .tag("Work") && left.query == "left query")
        #expect(right.scope == .notes && right.query == "right query")
        #expect(unrelated.selectedID == other.id && unrelated.scope == .pinned && unrelated.query == "unrelated query")
        #expect(unrelated.workspace == Workspace(path: "Projects"))
        #expect(library.selectedID == nil)
        #expect(library.scope == .trash && library.query == "stale legacy query")
        #expect(try library.store.note(id: other.id)?.text == other.text)
        for navigation in [left, right, unrelated] { try await library.detachScene(id: navigation.id) }
        try await library.closeAfterStopping()
    }

    @Test func bulkMoveIsOneSceneActionAndRetainsUnrelatedPendingNavigation() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let first = try library.store.create(text: "First"), second = try library.store.create(text: "Second"), other = try library.store.create(text: "Other")
        let source = MobileSceneNavigation(), neighbor = MobileSceneNavigation()
        source.selectedID = first.id; neighbor.selectedID = other.id
        let callback = MobileCallbackNavigation(noteID: other.id, header: "Keep this", find: nil, edit: false)
        neighbor.pendingCallbackNavigation = callback
        let editors = [MobileEditor(library: library), MobileEditor(library: library)]
        for (navigation, editor) in zip([source, neighbor], editors) {
            editor.sceneNavigation = navigation
            try library.registerScene(id: navigation.id, editor: editor, navigation: navigation, observation: nil, activity: .active)
        }
        try await library.moveNotesAfterDraining([first.id, second.id], to: .trash, in: source)
        #expect(try library.store.note(id: first.id)?.location == .trash)
        #expect(try library.store.note(id: second.id)?.location == .trash)
        #expect(source.selectedID == nil && neighbor.selectedID == other.id)
        #expect(neighbor.pendingCallbackNavigation?.id == callback.id)
        for navigation in [source, neighbor] { try await library.detachScene(id: navigation.id) }
        try await library.closeAfterStopping()
    }
}
