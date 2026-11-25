// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import SwiftUI
import Testing
import TheoNotesCore
import UIKit
import WebKit
@testable import BaerchenIOS

@Suite(.serialized) @MainActor struct MobileSceneCredentialDrainTests {
    private func wait(_ predicate: () throws -> Bool) async throws {
        for _ in 0..<400 { if try predicate() { return }; try await Task.sleep(for: .milliseconds(20)) }
        try #require(try predicate())
    }

    @Test func credentialRefreshCannotReloadSameNoteDuringStrictLockDrain() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        try await library.unlockNotes(password: "credential drain fixture", createPassword: true)
        let note = try library.store.create(text: "# Preserve this exact body")
        let navigation = MobileSceneNavigation(); navigation.selectedID = note.id
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView:
            MobileLibraryView(library: library, editor: editor, sceneNavigation: navigation, applicationState: { .active })
                .environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true; window.rootViewController = nil
            try? editor.closeForPrivacy(); try? library.close()
            try? FileManager.default.removeItem(at: paths.root); previous?.makeKey()
        }
        try await wait { editor.ready && library.lockSelectedNoteForTesting != nil }
        let held = CredentialHeldFreeze(editor)
        let controller = editor.webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "bridge", contentWorld: .page)
        controller.addScriptMessageHandler(held, contentWorld: .page, name: "bridge")
        defer { held.deliver() }
        library.lockSelectedNoteForTesting?()
        try await wait { held.isHolding }
        let generation = editor.documentLoadGeneration
        let admission = library.sceneAdmissionGeneration
        #expect(library.sceneEditorAdmissionBlocked)
        // This is the real observable credential event emitted by the password prompt.
        try await library.unlockNotes(password: "credential drain fixture")
        try await Task.sleep(for: .milliseconds(150))
        #expect(editor.documentLoadGeneration == generation)
        #expect(editor.session?.noteId == note.id)
        held.deliver()
        try await wait { try library.store.note(id: note.id)?.isLocked == true && library.privateAccess == nil }
        try await wait { !library.sceneEditorAdmissionBlocked && library.sceneAdmissionGeneration > admission }
        #expect(library.errorMessage == nil)
        #expect(navigation.selectedID == note.id)
        try await library.unlockNotes(password: "credential drain fixture")
        try await wait { library.cachedSession(for: note.id)?.text == note.text }
    }
}

@MainActor private final class CredentialHeldFreeze: NSObject, WKScriptMessageHandlerWithReply {
    let editor: MobileEditor
    var pending: (() -> Void)?
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
