// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import TheoNotesCore
import UIKit
import WebKit
@testable import BaerchenIOS

@Suite(.serialized) @MainActor struct MobileSceneUnreadyDrainTests {
    @Test(arguments: [false, true])
    func freshLoadingOrTerminatedPageDoesNotBlockSyncOrSwitch(terminated: Bool) async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let note = try library.store.create(text: "# Native journal survives")
        let editor = MobileEditor(library: library), navigation = MobileSceneNavigation()
        navigation.selectedID = note.id
        editor.webView.configuration.userContentController.removeAllScriptMessageHandlers()
        try editor.open(note.id)
        let session = try #require(editor.session)
        if terminated {
            // Simulate the exact native process-termination delegate notification.
            // This is not proof that edits never sent by the killed process can be recovered.
            try editor.receive(.ready(version: EditorBridge.version), from: editor.webView)
            editor.webViewWebContentProcessDidTerminate(editor.webView)
        }
        try #require(!editor.ready)
        let expected = note.text + "\nNative acknowledged edit"
        let change = try JSONDecoder().decode(ChangeSet.self, from: JSONSerialization.data(withJSONObject: [[note.text.utf16.count] + expected.components(separatedBy: "\n")]))
        _ = session.apply(txId: UUID().uuidString, baseRevision: session.revision, changeSet: change, origin: nil)
        #expect(session.text == expected)
        try library.registerScene(id: navigation.id, editor: editor, navigation: navigation, observation: nil, activity: .background)
        let coordinator = MobileSyncCommitCoordinator(library: library)
        #expect(try await coordinator.commit(scope: .unknown) { .unchanged } == .unchanged)
        #expect(try await coordinator.commit(scope: .note(note.id)) { .unchanged } == .unchanged)
        #expect(editor.session === session)
        #expect(try library.store.note(id: note.id)?.text == expected)
        try library.claimSceneLibrarySwitch()
        try await library.closeAfterStopping()
        #expect(editor.isClosedForPrivacy && editor.session == nil && library.isClosed)
        let reopened = try MobileLibrary(paths: paths)
        #expect(try reopened.store.note(id: note.id)?.text == expected)
        try reopened.close()
    }

    @Test func loadingPageBecomingReadyDuringAnotherFreezeInvalidatesLease() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        let first = MobileEditor(library: library), second = MobileEditor(library: library)
        let note = try library.store.create(text: "# Never discard a changed page")
        first.webView.configuration.userContentController.removeAllScriptMessageHandlers()
        try first.open(note.id); try second.open(note.id)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        host.view = second.webView; window.rootViewController = host; window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            try? first.closeForPrivacy(); try? second.closeForPrivacy()
            try? library.close(); try? FileManager.default.removeItem(at: paths.root)
        }
        for _ in 0..<600 where !second.ready { try await Task.sleep(for: .milliseconds(10)) }
        try #require(second.ready)
        let held = UnreadyDrainHeldFreeze(second)
        let controller = second.webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "bridge", contentWorld: .page)
        controller.addScriptMessageHandler(held, contentWorld: .page, name: "bridge")
        defer { held.deliver() }
        let registry = MobileSceneRegistry()
        try registry.register(sceneID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, editor: first, activity: .active)
        try registry.register(sceneID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, editor: second, activity: .active)
        let operation = Task { try await registry.freezeAll() }
        defer { operation.cancel() }
        for _ in 0..<200 where !held.isHolding { try await Task.sleep(for: .milliseconds(10)) }
        try #require(held.isHolding)
        // The initially skippable page now owns a different load/possibly writable document.
        try first.receive(.ready(version: EditorBridge.version), from: first.webView)
        #expect(!first.canDrainUnreadyNativeSession)
        held.deliver()
        await #expect(throws: MobileEditorDrainError.busy) { _ = try await operation.value }
        let reply = try await second.prepareCaptureClose(note.id)
        second.endCaptureClose(reply)
        #expect(try library.store.note(id: note.id)?.text == note.text)
    }

    @Test func expiredDrainDeadlineDoesNotMutateOrLeaveAdmissionHeld() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let editor = MobileEditor(library: library), navigation = MobileSceneNavigation()
        try library.registerScene(id: navigation.id, editor: editor, navigation: navigation, observation: nil, activity: .active)
        var called = false
        await #expect(throws: MobileEditorDrainError.timeout) {
            try await library.withDrainedEditor(deadline: .distantPast) { called = true }
        }
        #expect(!called && !library.sceneEditorAdmissionBlocked)
        try await library.withDrainedEditor { called = true }
        #expect(called)
        try await library.detachScene(id: navigation.id)
    }
}

@MainActor private final class UnreadyDrainHeldFreeze: NSObject, WKScriptMessageHandlerWithReply {
    let editor: MobileEditor
    private var pending: (() -> Void)?
    private var didHold = false
    var isHolding: Bool { pending != nil }
    init(_ editor: MobileEditor) { self.editor = editor }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        if (message.body as? [String: Any])?["type"] as? String == "frozenForClose", !didHold {
            didHold = true
            pending = { self.editor.userContentController(controller, didReceive: message, replyHandler: replyHandler) }
        } else { editor.userContentController(controller, didReceive: message, replyHandler: replyHandler) }
    }
    func deliver() { let reply = pending; pending = nil; reply?() }
}
