// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Synchronization
import Testing
import TheoNotesCore
import UIKit
import WebKit
@testable import BaerchenIOS

private final class SceneDetachHeldRead: Sendable {
    private let state = Mutex(false)
    private let releaseSignal = DispatchSemaphore(value: 0)
    var entered: Bool { state.withLock { $0 } }
    func hold() { state.withLock { $0 = true }; _ = releaseSignal.wait(timeout: .now() + 10) }
    func release() { releaseSignal.signal() }
}

@Suite(.serialized) @MainActor struct MobileSceneDetachLifetimeTests {
    @Test(arguments: ["ready", "unready", "cancelled"])
    func disappearingEditorSurvivesHeldObservationUntilDetachReturns(mode: String) async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths), held = SceneDetachHeldRead()
        defer { held.release(); try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let note = try library.store.create(text: "# Acknowledged source remains cached")
        let navigation = MobileSceneNavigation()
        var editor: MobileEditor? = MobileEditor(library: library)
        weak var weakEditor = editor
        var window: UIWindow?
        if mode == "unready" {
            editor!.webView.configuration.userContentController.removeAllScriptMessageHandlers()
        } else {
            let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let visible = UIWindow(windowScene: scene), host = UIViewController()
            host.view = editor!.webView; visible.rootViewController = host; visible.makeKeyAndVisible()
            window = visible
        }
        defer { window?.isHidden = true }
        try editor!.open(note.id)
        if mode != "unready" {
            for _ in 0..<600 where editor?.ready != true { try await Task.sleep(for: .milliseconds(10)) }
            try #require(editor?.ready == true)
        }
        let sharedSession = try #require(editor?.session)
        let observation = MobileSceneLibraryObservation(navigation: navigation, database: library.database,
            isCurrent: { !library.isClosed }, debounce: .zero,
            searchOperation: { _, database in
                try await database.pool.read { _ in
                    held.hold()
                    return SearchResult(items: [], terms: [])
                }
            })
        navigation.query = "held"
        try library.registerScene(id: navigation.id, editor: editor!, navigation: navigation, observation: observation, activity: .active)
        observation.start()
        defer { observation.stop() }
        try #require(!observation.snapshot.items.isEmpty)
        for _ in 0..<200 where !held.entered { try await Task.sleep(for: .milliseconds(10)) }
        try #require(held.entered)
        var returned = false
        let detaching = Task {
            defer { returned = true }
            try await library.detachScene(id: navigation.id)
        }
        defer { detaching.cancel() }
        // stop clears the snapshot synchronously BEFORE waiting for the held pool read.
        for _ in 0..<200 where !observation.snapshot.items.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try #require(observation.snapshot.items.isEmpty && !returned)
        editor = nil // The disappearing View relinquishes its sole ordinary editor owner.
        await Task.yield()
        #expect(weakEditor != nil && !returned)
        if mode == "cancelled" {
            detaching.cancel()
            await Task.yield()
            #expect(weakEditor != nil && !returned, "Cancellation must not bypass the active read barrier")
        }
        held.release()
        if mode == "cancelled" {
            await #expect(throws: CancellationError.self) { try await detaching.value }
        } else { try await detaching.value }
        #expect(returned)
        #expect(library.cachedSession(for: note.id) === sharedSession)
        #expect(try library.store.note(id: note.id)?.text == note.text)
        if mode == "cancelled" {
            #expect(weakEditor != nil && library.pendingSceneDetachCount == 1,
                "A cancelled close must retain the actual editor after the caller returns")
            // A later real admission release retries the failed detach; no polling loop
            // discards an undrained page or spins on the original failed attempt.
            try await library.withDrainedEditor {}
            for _ in 0..<600 where library.pendingSceneDetachCount != 0 { try await Task.sleep(for: .milliseconds(10)) }
            #expect(library.pendingSceneDetachCount == 0 && !library.hasRegisteredSceneWindows)
            #expect(weakEditor == nil || weakEditor?.isClosedForPrivacy == true)
        }
        try await library.closeAfterStopping()
    }

    @Test func repeatedlyRejectedCloseGetsOnlyOneAutomaticRetryAndKeepsRecoverablePage() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        let note = try library.store.create(text: "# Do not drop this live page")
        let navigation = MobileSceneNavigation(), editor = MobileEditor(library: library)
        navigation.selectedID = note.id
        try library.registerScene(id: navigation.id, editor: editor, navigation: navigation, observation: nil, activity: .active)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        host.view = editor.webView; window.rootViewController = host; window.makeKeyAndVisible()
        defer {
            window.isHidden = true; try? editor.closeForPrivacy()
            try? library.close(); try? FileManager.default.removeItem(at: paths.root); previous?.makeKey()
        }
        try editor.open(note.id)
        for _ in 0..<600 where !editor.ready { try await Task.sleep(for: .milliseconds(10)) }
        try #require(editor.ready)
        let rejected = SceneDetachRejectedFreeze(editor)
        let controller = editor.webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "bridge", contentWorld: .page)
        controller.addScriptMessageHandler(rejected, contentWorld: .page, name: "bridge")
        _ = try await editor.webView.evaluateJavaScript("window.__detachOriginalReceive=window.__baerchen.receive;window.__baerchen.receive=function(m){if(m.type==='freezeForClose'){window.webkit.messageHandlers.bridge.postMessage({type:'frozenForClose',requestId:m.requestId,noteId:m.noteId,ok:false,editedSinceLoad:true,reason:'halted'});return;}return window.__detachOriginalReceive(m)};true")
        await #expect(throws: MobileEditorDrainError.unavailable) { try await library.detachScene(id: navigation.id) }
        #expect(rejected.count == 1 && library.pendingSceneDetachCount == 1)
        await #expect(throws: MobileEditorDrainError.unavailable) { try await library.withDrainedEditor {} }
        for _ in 0..<300 where rejected.count < 3 || library.sceneEditorAdmissionBlocked { try await Task.sleep(for: .milliseconds(10)) }
        #expect(rejected.count == 3 && library.blockedSceneDetachCount == 1)
        #expect(library.errorMessage?.contains("remain blocked") == true)
        await #expect(throws: MobileEditorDrainError.unavailable) { try await library.withDrainedEditor {} }
        try await Task.sleep(for: .milliseconds(100))
        #expect(rejected.count == 4, "A further shared operation must not trigger another automatic retry")
        #expect(library.pendingSceneDetachCount == 1 && editor.session?.noteId == note.id && !editor.isClosedForPrivacy)
        #expect(try library.store.note(id: note.id)?.text == note.text)
        _ = try await editor.webView.evaluateJavaScript("window.__baerchen.receive=window.__detachOriginalReceive;true")
        try await library.detachScene(id: navigation.id) // Explicit successful recovery remains possible.
        #expect(library.pendingSceneDetachCount == 0 && library.blockedSceneDetachCount == 0)
        try await library.closeAfterStopping()
    }

}


@MainActor private final class SceneDetachRejectedFreeze: NSObject, WKScriptMessageHandlerWithReply {
    weak var editor: MobileEditor?
    private(set) var count = 0
    init(_ editor: MobileEditor) { self.editor = editor }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        if (message.body as? [String: Any])?["type"] as? String == "frozenForClose" { count += 1 }
        guard let editor else { replyHandler(nil, "Editor released"); return }
        editor.userContentController(controller, didReceive: message, replyHandler: replyHandler)
    }
}
