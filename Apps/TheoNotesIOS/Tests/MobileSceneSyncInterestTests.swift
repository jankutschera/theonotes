// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Synchronization
import Testing
import TheoNotesCore
@testable import BaerchenIOS

@Suite(.serialized) @MainActor struct MobileSceneSyncInterestTests {
    @Test func unrelatedNoteSkipsUnreadySceneFreezeButRetainedEditorAndCacheStillProtectRelatedNote() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let note = try library.store.create(text: "# Open source"), unrelated = try library.store.create(text: "# Remote target")
        let navigation = MobileSceneNavigation(), editor = MobileEditor(library: library)
        try library.registerScene(id: navigation.id, editor: editor, navigation: navigation, observation: nil, activity: .active)
        navigation.selectedID = note.id
        editor.webView.configuration.userContentController.removeAllScriptMessageHandlers()
        try editor.open(note.id)
        // A fresh page has never offered editing. Related sync can flush native
        // content without waiting for a nonexistent JS edit queue.
        let called = Mutex(false), coordinator = MobileSyncCommitCoordinator(library: library)
        #expect(try await coordinator.commit(scope: .note(unrelated.id)) {
            called.withLock { $0 = true }; return .unchanged
        } == .unchanged)
        #expect(called.withLock { $0 })
        #expect(library.hasSyncInterest(in: note.id) && !library.hasSyncInterest(in: unrelated.id))
        try library.discardSession(note.id) // The real editor outlives the cache, retaining its listener.
        #expect(!library.hasCachedSession(for: note.id) && library.hasSyncInterest(in: note.id))
        called.withLock { $0 = false }
        #expect(try await coordinator.commit(scope: .note(note.id)) { called.withLock { $0 = true }; return .applied } == .applied)
        #expect(called.withLock { $0 })
        try editor.closeForPrivacy()
        _ = try library.session(for: unrelated.id)
        #expect(library.hasSyncInterest(in: unrelated.id), "Cached sessions still participate even with no displayed page")
        #expect(try library.store.note(id: note.id)?.text == note.text)
        try await library.detachScene(id: navigation.id)
        try await library.closeAfterStopping()
    }
}
