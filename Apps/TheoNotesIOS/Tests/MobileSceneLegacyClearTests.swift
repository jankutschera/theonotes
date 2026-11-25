// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import TheoNotesCore
import UIKit
@testable import BaerchenIOS

@Suite(.serialized) @MainActor struct MobileSceneLegacyClearTests {
    private func withLibrary(_ body: @MainActor (MobileLibrary) async throws -> Void) async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        var failure: (any Error)?
        do { try await body(library) } catch { failure = error }
        do {
            try await library.closeAfterStopping()
            try FileManager.default.removeItem(at: paths.root)
        } catch { if failure == nil { failure = error } }
        if let failure { throw failure }
    }
    @Test func emptyCaptureCompletionDoesNotBroadcastStaleLegacyContextIntoNewSelection() async throws {
        try await withLibrary { library in
            let id = try await library.captureThought(source: .lockscreen)
            let next = try library.store.create(text: "# Newly selected"), other = try library.store.create(text: "# Other scene")
            let source = MobileSceneNavigation(), matching = MobileSceneNavigation(), unrelated = MobileSceneNavigation()
            let editors = [MobileEditor(library: library), MobileEditor(library: library), MobileEditor(library: library)]
            for (navigation, editor) in zip([source, matching, unrelated], editors) {
                editor.sceneNavigation = navigation
                try library.registerScene(id: navigation.id, editor: editor, navigation: navigation, observation: nil, activity: .active)
            }
            source.selectedID = next.id; source.scope = .tag("Work"); source.query = "source query"
            source.workspace = Workspace(path: "Work")
            matching.selectedID = id; matching.scope = .pinned; matching.query = "matching query"
            unrelated.selectedID = other.id; unrelated.scope = .archive; unrelated.query = "other query"
            unrelated.workspace = Workspace(path: "Other")
            library.markSceneFrontmost(id: unrelated.id)
            let editor = editors[0]
            let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene), host = UIViewController()
            host.view = editor.webView; window.rootViewController = host; window.makeKeyAndVisible()
            defer { window.isHidden = true; previous?.makeKey() }
            try editor.open(id)
            for _ in 0..<600 where !editor.ready { try await Task.sleep(for: .milliseconds(10)) }
            try #require(editor.ready)
            try await library.finishCapture(noteId: id, editor: editor, mayFinish: { true })
            #expect(try library.store.note(id: id)?.location == .trash)
            #expect(source.selectedID == next.id && source.scope == .tag("Work") && source.query == "source query")
            #expect(source.workspace == Workspace(path: "Work"))
            #expect(matching.selectedID == nil && matching.scope == .pinned && matching.query == "matching query")
            #expect(unrelated.selectedID == other.id && unrelated.scope == .archive && unrelated.query == "other query")
            #expect(unrelated.workspace == Workspace(path: "Other"))
            #expect(library.selectedID == nil)
            for nav in [source, matching, unrelated] { try await library.detachScene(id: nav.id) }
        }
    }

    @Test(arguments: [BackupRestoreMode.merge, .replaceAll])
    func restoreClearsOnlyMissingSceneTargetsAndNeverBroadcastsLegacyFilters(mode: BackupRestoreMode) async throws {
        try await withLibrary { library in
            let keep = try library.store.create(text: "# In backup")
            let backup = try await library.makeBackup()
            let extra = try library.store.create(text: "# Created after backup")
            library.scope = .trash; library.query = "stale legacy query"; library.selectedID = extra.id
            let left = MobileSceneNavigation(), right = MobileSceneNavigation()
            let editors = [MobileEditor(library: library), MobileEditor(library: library)]
            for (nav, editor) in zip([left, right], editors) {
                try library.registerScene(id: nav.id, editor: editor, navigation: nav, observation: nil, activity: .active)
            }
            left.selectedID = keep.id; left.scope = .tag("Left"); left.query = "left query"; left.workspace = Workspace(path: "Left")
            right.selectedID = extra.id; right.scope = .pinned; right.query = "right query"; right.workspace = Workspace(path: "Right")
            library.markSceneFrontmost(id: left.id)
            _ = try await library.restoreBackup(backup, mode: mode, backupPassword: nil, currentPassword: nil)
            #expect(left.selectedID == keep.id && left.scope == .tag("Left") && left.query == "left query")
            #expect(left.workspace == Workspace(path: "Left"))
            #expect(right.selectedID == (mode == .replaceAll ? nil : extra.id))
            #expect(right.scope == .pinned && right.query == "right query" && right.workspace == Workspace(path: "Right"))
            #expect(try library.store.note(id: keep.id)?.text == keep.text)
            for nav in [left, right] { try await library.detachScene(id: nav.id) }
        }
    }

    @Test func restoreConsumesOldDeferredDeliveryButPreservesNewDelivery() async throws {
        try await withLibrary { library in
            let keep = try library.store.create(text: "# Keep")
            let other = try library.store.create(text: "# Other")
            let backup = try await library.makeBackup()
            let left = MobileSceneNavigation(), right = MobileSceneNavigation()
            let editors = [MobileEditor(library: library), MobileEditor(library: library)]
            // Register both identities first so inactive windows cannot use the single-window fallback.
            for nav in [left, right] { try library.registerScene(id: nav.id, activity: .background) }
            for (nav, editor) in zip([left, right], editors) {
                try library.registerScene(id: nav.id, editor: editor, navigation: nav, observation: nil, activity: .background)
            }
            left.selectedID = keep.id; left.scope = .pinned; left.query = "left query"
            right.selectedID = other.id; right.scope = .archive; right.query = "right query"
            library.scope = .trash; library.query = "stale delivery"; library.selectedID = other.id
            library.pendingCaret[other.id] = 12
            library.pendingCallbackNavigation = MobileCallbackNavigation(noteID: other.id, edit: false)
            _ = try await library.restoreBackup(backup, mode: .replaceAll, backupPassword: nil, currentPassword: nil)
            library.updateSceneActivity(id: left.id, activity: .active)
            #expect(left.selectedID == keep.id && left.scope == .pinned && left.query == "left query")
            #expect(right.selectedID == other.id && right.scope == .archive && right.query == "right query")
            #expect(left.pendingCaret.isEmpty && left.pendingCallbackNavigation == nil)

            library.updateSceneActivity(id: left.id, activity: .background)
            library.scope = .notes; library.query = "fresh delivery"; library.selectedID = other.id
            library.updateSceneActivity(id: left.id, activity: .active)
            #expect(left.selectedID == other.id && left.scope == .notes && left.query == "fresh delivery")
            #expect(left.pendingCaret.isEmpty && left.pendingCallbackNavigation == nil)
            #expect(right.selectedID == other.id && right.scope == .archive && right.query == "right query")
            for nav in [left, right] { try await library.detachScene(id: nav.id) }
        }
    }
}
