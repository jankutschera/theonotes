// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import UIKit
import WebKit
import TheoNotesCore
@testable import BaerchenIOS

@Suite(.serialized) @MainActor struct MobileSceneRegistryTests {
    private func library() throws -> MobileLibrary {
        try MobileLibrary(paths: AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    }
    private func cleanup(_ value: MobileLibrary) { try? value.close(); try? FileManager.default.removeItem(at: value.paths.root) }

    @Test func oneInactiveSceneDoesNotDeactivateAnotherAndRegistryDoesNotRetainEditors() async throws {
        let library = try library(); defer { cleanup(library) }
        let registry = MobileSceneRegistry(), a = UUID(), b = UUID()
        let second = MobileEditor(library: library)
        // Keep construction/weak-load autoreleases and macro temporaries out of the
        // asserting async scope. The registry must not become an ordinary editor owner.
        let weakFirst = try autoreleasepool {
            let first = MobileEditor(library: library)
            return try withExtendedLifetime(first) {
                try registry.register(sceneID: a, editor: first, activity: .active)
                try registry.register(sceneID: b, editor: second, activity: .active)
                #expect(!registry.updateActivity(sceneID: a, activity: .background).becameInactive)
                #expect(registry.hasActiveScenes)
                #expect(registry.updateActivity(sceneID: b, activity: .inactive).becameInactive)
                return SceneRegistryWeakEditor(first)
            }
        }
        for _ in 0..<200 where weakFirst.value != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(weakFirst.value == nil)
        withExtendedLifetime(second) { #expect(registry.sceneCount == 1) }
    }

    @Test func emptyFreezeBlocksRegistrationUntilIdempotentReleaseAndDetachKeepsOtherScene() async throws {
        let library = try library(); defer { cleanup(library) }
        let registry = MobileSceneRegistry(), a = UUID(), b = UUID()
        let first = MobileEditor(library: library), second = MobileEditor(library: library)
        try registry.register(sceneID: a, editor: first, activity: .active)
        let lease = try await registry.freezeAll()
        #expect(throws: MobileEditorDrainError.busy) { try registry.register(sceneID: b, editor: second, activity: .active) }
        try lease.validate()
        lease.release(); lease.release()
        try registry.register(sceneID: b, editor: second, activity: .active)
        let change = try await registry.detach(sceneID: a)
        #expect(!change.becameInactive && registry.hasActiveScenes && registry.sceneCount == 1)
        #expect(!library.isClosed)
    }

    @Test func freshUnreadyPageFlushesNativeSessionWithoutDiscardingSharedSession() async throws {
        let library = try library(); defer { cleanup(library) }
        let note = try library.store.create(text: "# Keep pending text")
        let first = MobileEditor(library: library), second = MobileEditor(library: library)
        try first.open(note.id); try second.open(note.id)
        #expect(first.session === second.session)
        #expect(first.webView !== second.webView)
        let cached = try #require(first.session)
        let registry = MobileSceneRegistry(), a = UUID(), b = UUID()
        try registry.register(sceneID: a, editor: first, activity: .active)
        // No page has ever offered editing; its native session is the entire content.
        let initialLease = try await registry.freezeAll(); try initialLease.validate(); initialLease.release()
        try registry.register(sceneID: b, editor: second, activity: .active)
        #expect(library.cachedSession(for: note.id) === cached)
        #expect(first.session === cached && second.session === cached)
        #expect(try library.store.note(id: note.id)?.text == note.text)
        try first.closeForPrivacy(); try second.closeForPrivacy()
        #expect(library.cachedSession(for: note.id) === cached)
        let lease = try await registry.freezeAll(); lease.release()
    }

    @Test func loadingSecondPageDoesNotBlockFirstAndLeaseReleasesBoth() async throws {
        let library = try library(); defer { cleanup(library) }
        let note = try library.store.create(text: "# Shared exact text")
        let first = MobileEditor(library: library), second = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        host.view = first.webView; window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; try? first.closeForPrivacy(); try? second.closeForPrivacy() }
        // Suppress only the second page's bridge-ready delivery, deterministically
        // representing a real loading/unavailable second scene.
        second.webView.configuration.userContentController.removeAllScriptMessageHandlers()
        try first.open(note.id); try second.open(note.id)
        for _ in 0..<600 where !first.ready { try await Task.sleep(for: .milliseconds(10)) }
        try #require(first.ready)
        let registry = MobileSceneRegistry()
        // Sorted registration IDs force the mounted editor to freeze first.
        try registry.register(sceneID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, editor: first, activity: .active)
        try registry.register(sceneID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, editor: second, activity: .active)
        let initialLease = try await registry.freezeAll(); try initialLease.validate(); initialLease.release()
        // A leaked first guard makes this fail busy; real bridge handshake proves release.
        let reply = try await first.prepareCaptureClose(note.id)
        first.endCaptureClose(reply)
        #expect(first.session === second.session)
        #expect(try library.store.note(id: note.id)?.text == note.text)
        try second.closeForPrivacy()
        let lease = try await registry.freezeAll(); try lease.validate(); lease.release()
    }

    @Test func closingOneSceneIgnoresAnotherSceneSelectionChangeDuringHeldFreeze() async throws {
        let library = try library(); defer { cleanup(library) }
        let note = try library.store.create(text: "# Closing window"), old = try library.store.create(text: "# Other old"), next = try library.store.create(text: "# Other new")
        let first = MobileEditor(library: library), second = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        host.view = first.webView; window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; try? first.closeForPrivacy(); try? second.closeForPrivacy() }
        try first.open(note.id); try second.open(old.id)
        for _ in 0..<600 where !first.ready { try await Task.sleep(for: .milliseconds(10)) }
        try #require(first.ready)
        let held = SceneRegistryHeldFreeze(first)
        let controller = first.webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "bridge", contentWorld: .page)
        controller.addScriptMessageHandler(held, contentWorld: .page, name: "bridge")
        defer { held.deliver() }
        let registry = MobileSceneRegistry(), a = UUID(), b = UUID()
        try registry.register(sceneID: a, editor: first, activity: .active)
        try registry.register(sceneID: b, editor: second, activity: .active)
        let closing = Task { try await registry.detach(sceneID: a) }
        defer { closing.cancel() }
        for _ in 0..<200 where !held.isHolding { try await Task.sleep(for: .milliseconds(10)) }
        try #require(held.isHolding)
        if second.ready {  // Switch like the app: a ready page is replaced only inside a verified close (P1, e3268f62).
            let frozen = try await second.prepareCaptureClose(old.id)
            defer { second.endCaptureClose(frozen) }
            try second.open(next.id)
        } else { try second.open(next.id) }
        held.deliver()
        let result = try await closing.value
        #expect(!result.becameInactive && registry.sceneCount == 1)
        #expect(first.isClosedForPrivacy && first.session == nil)
        #expect(second.session?.noteId == next.id && !second.isClosedForPrivacy)
        #expect(try library.store.note(id: note.id)?.text == note.text)
    }

    @Test func synchronousReplacementRejectsUnreadyPageUntilExplicitPrivacyClose() throws {
        let library = try library(); defer { cleanup(library) }
        let first = MobileEditor(library: library), replacement = MobileEditor(library: library)
        let registry = MobileSceneRegistry(), id = UUID()
        try registry.register(sceneID: id, editor: first, activity: .active)
        #expect(first.session == nil && !first.ready && !first.isClosedForPrivacy)
        #expect(throws: MobileEditorDrainError.busy) { try registry.replaceClosedEditor(sceneID: id, editor: replacement) }
        try first.closeForPrivacy()
        try registry.replaceClosedEditor(sceneID: id, editor: replacement)
        #expect(registry.sceneCount == 1 && registry.hasActiveScenes)
    }

    @Test func cancellationDoesNotLeaveRegistryBusy() async throws {
        let registry = MobileSceneRegistry()
        let task = Task { try await registry.freezeAll() }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let lease = try await registry.freezeAll(); lease.release()
    }
}

@MainActor private final class SceneRegistryWeakEditor {
    weak var value: MobileEditor?
    init(_ editor: MobileEditor) { value = editor }
}

@MainActor private final class SceneRegistryHeldFreeze: NSObject, WKScriptMessageHandlerWithReply {
    private let editor: MobileEditor
    private var pending: (() -> Void)?
    var isHolding: Bool { pending != nil }
    init(_ editor: MobileEditor) { self.editor = editor }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        if (message.body as? [String: Any])?["type"] as? String == "frozenForClose" {
            pending = { self.editor.userContentController(controller, didReceive: message, replyHandler: replyHandler) }
        } else { editor.userContentController(controller, didReceive: message, replyHandler: replyHandler) }
    }
    func deliver() { let reply = pending; pending = nil; reply?() }
}
