// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import TheoNotesCore
import UIKit
import WebKit
@testable import BaerchenIOS

@Suite(.serialized) @MainActor struct MobileSceneVaultCloseTests {
    @Test(arguments: [false, true])
    func asyncNonViewCloseDrainsOrRevokesAtBoundedDeadline(holdReply: Bool) async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        try await library.unlockNotes(password: "bounded close fixture", createPassword: true)
        let note = try library.store.create(text: "# Exact protected body")
        try library.lockNote(note.id)
        let access = try #require(library.privateAccess)
        let editor = MobileEditor(library: library), navigation = MobileSceneNavigation()
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        host.view = editor.webView; window.rootViewController = host; window.makeKeyAndVisible()
        defer {
            window.isHidden = true; MobilePrivacyShield.uncover()
            try? editor.closeForPrivacy()
            try? library.close(); try? FileManager.default.removeItem(at: paths.root); previous?.makeKey()
        }
        navigation.selectedID = note.id
        try library.registerScene(id: navigation.id, editor: editor, navigation: navigation, observation: nil, activity: .active)
        try editor.open(note.id)
        for _ in 0..<600 where !editor.ready { try await Task.sleep(for: .milliseconds(10)) }
        try #require(editor.ready)
        // Settle the host's loadNote send first: a freeze is sent only when nothing is pending.
        let settle = try await editor.prepareCaptureClose(note.id)
        editor.endCaptureClose(settle)
        let held = VaultCloseHeldFreeze(editor, hold: holdReply)
        let controller = editor.webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "bridge", contentWorld: .page)
        controller.addScriptMessageHandler(held, contentWorld: .page, name: "bridge")
        defer { held.deliver() }
        let start = Date()
        // The close keeps its last 0.5 s for the text-preservation fallback (e3268f62), so the
        // freeze needs a budget above that; 2 s is what the app passes.
        let closing = Task { try await library.lockVaultAfterDraining(timeout: 2) }
        if holdReply {
            for _ in 0..<150 where !held.isHolding { try await Task.sleep(for: .milliseconds(10)) }
            try #require(held.isHolding)
            #expect(library.privateAccess === access && library.sceneOperationPending)
            #expect(MobilePrivacyShield.isCovered(window))
            await #expect(throws: MobileEditorDrainError.timeout) { try await closing.value }
            #expect(Date().timeIntervalSince(start) < 3.5)
            #expect(library.errorMessage != nil)
        } else { try await closing.value }
        #expect(library.privateAccess == nil && editor.isClosedForPrivacy)
        #expect(!library.sceneOperationPending)
        #expect(throws: NotePrivacyError.accessRevoked) { try access.journalKey() }
        held.deliver() // Late native reply cannot reacquire access or reopen the editor.
        #expect(library.privateAccess == nil && editor.session == nil)
        try await library.unlockNotes(password: "bounded close fixture")
        #expect(try library.readableNote(note.id)?.text == note.text)
        try await library.detachScene(id: navigation.id)
        try await library.closeAfterStopping()
    }
}

/// A silent page: holds the freeze reply and the text-preservation fallback's recoveryText.
@MainActor private final class VaultCloseHeldFreeze: NSObject, WKScriptMessageHandlerWithReply {
    let editor: MobileEditor
    let hold: Bool
    var pending: [() -> Void] = []
    private(set) var isHolding = false
    init(_ editor: MobileEditor, hold: Bool) { self.editor = editor; self.hold = hold }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        let type = (message.body as? [String: Any])?["type"] as? String
        if hold, type == "frozenForClose" || type == "recoveryText" {
            if type == "frozenForClose" { isHolding = true }
            pending.append { self.editor.userContentController(controller, didReceive: message, replyHandler: replyHandler) }
        } else { editor.userContentController(controller, didReceive: message, replyHandler: replyHandler) }
    }
    func deliver() { let replies = pending; pending = []; isHolding = false; replies.forEach { $0() } }
}
