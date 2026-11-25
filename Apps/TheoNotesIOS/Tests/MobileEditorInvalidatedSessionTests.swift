// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import TheoNotesCore
import UIKit
import WebKit
@testable import BaerchenIOS

@Suite(.serialized) @MainActor struct MobileEditorInvalidatedSessionTests {
    private final class HeldChanges: NSObject, WKScriptMessageHandlerWithReply {
        let editor: MobileEditor
        var release: (() -> Void)?
        var repliedWithACK = false
        init(_ editor: MobileEditor) { self.editor = editor }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
            if (message.body as? [String: Any])?["type"] as? String == "changes", release == nil {
                release = {
                    self.editor.userContentController(controller, didReceive: message) { value, error in
                        self.repliedWithACK = (value as? [String: Any])?["status"] as? String == "acked"
                        replyHandler(value, error)
                    }
                }
            } else { editor.userContentController(controller, didReceive: message, replyHandler: replyHandler) }
        }
    }

    @Test func invalidatedRetainedSessionNeverReloadsOrAcknowledgesLateEdit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let note = try library.store.create(text: "Original")
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        host.view = editor.webView; window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try editor.open(note.id)
        for _ in 0..<400 {
            if editor.ready, editor.editable,
               (try? await editor.webView.evaluateJavaScript("document.querySelector('.cm-content')?.cmTile?.root?.view?.state.doc.toString()")) as? String == "Original" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(editor.ready && editor.editable)
        let session = try #require(editor.session)
        let page = editor.webView
        _ = try await page.evaluateJavaScript("window.__invalidLoads=0;window.__invalidReceive=window.__baerchen.receive;window.__baerchen.receive=function(m){if(m.type==='loadNote')window.__invalidLoads++;return window.__invalidReceive(m)};true")
        let held = HeldChanges(editor), controller = page.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "bridge", contentWorld: .page)
        controller.addScriptMessageHandler(held, contentWorld: .page, name: "bridge")
        editor.command(.insertText, args: ["text": .string(" unsaved")])
        for _ in 0..<400 where held.release == nil { try await Task.sleep(for: .milliseconds(10)) }
        let release = try #require(held.release)
        let before = try await page.evaluateJavaScript("document.querySelector('.cm-content').cmTile.root.view.state.doc.toString()") as? String
        #expect(before?.contains("unsaved") == true)
        try session.invalidate()
        release()
        try editor.receive(.error(message: "late bridge failure", stack: nil), from: page)
        editor.retryBrowserRecovery()
        editor.loadNote()
        #expect(throws: (any Error).self) { try editor.preserveBrowserRecovery(noteId: note.id, baseRevision: session.revision, text: "unsaved") }
        try await Task.sleep(for: .milliseconds(200))
        let after = try await page.evaluateJavaScript("document.querySelector('.cm-content').cmTile.root.view.state.doc.toString()") as? String
        let loads = try await page.evaluateJavaScript("window.__invalidLoads") as? Int
        #expect(after == before && loads == 0 && !held.repliedWithACK)
        #expect(page.isUserInteractionEnabled)
        #expect(library.errorMessage?.contains("copy") == true)
        _ = try await page.evaluateJavaScript("(()=>{let v=document.querySelector('.cm-content').cmTile.root.view;v.dispatch({selection:{anchor:0,head:v.state.doc.length}});return true})()")
        #expect((try await page.evaluateJavaScript("document.querySelector('.cm-content').cmTile.root.view.state.selection.main.to")) as? Int == before?.utf16.count)
    }
}
