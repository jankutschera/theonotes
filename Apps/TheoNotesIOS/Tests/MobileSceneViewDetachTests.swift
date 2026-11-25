// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import SwiftUI
import Synchronization
import Testing
import TheoNotesCore
import UIKit
import WebKit
@testable import BaerchenIOS

private final class ViewDetachReadBarrier: Sendable {
    private let state = Mutex(false)
    private let signal = DispatchSemaphore(value: 0)
    var entered: Bool { state.withLock { $0 } }
    func hold() { state.withLock { $0 = true }; _ = signal.wait(timeout: .now() + 15) }
    func release() { signal.signal() }
}

/// Owns only the WebKit reply continuation, never the editor. Native journal receipt
/// may finish, but the browser's transaction remains unacknowledged until release.
@MainActor private final class ViewDetachHeldChanges: NSObject, WKScriptMessageHandlerWithReply {
    weak var editor: MobileEditor?
    private var pending: (() -> Void)?
    private var didHold = false
    var isHolding: Bool { pending != nil }
    init(_ editor: MobileEditor) { self.editor = editor }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        guard let editor else { replyHandler(nil, "Editor released before pending ACK"); return }
        if !didHold, (message.body as? [String: Any])?["type"] as? String == "changes" {
            editor.userContentController(controller, didReceive: message) { result, error in
                // Hold only the ack of an applied edit; a refusal (host still busy) goes back
                // at once so the page resends, as in the app (same rule as the delete test).
                guard error == nil, (result as? [String: Any])?["status"] as? String == "acked" else {
                    replyHandler(result, error); return
                }
                self.didHold = true
                self.pending = { replyHandler(result, error) }
            }
        } else { editor.userContentController(controller, didReceive: message, replyHandler: replyHandler) }
    }
    func release() { let reply = pending; pending = nil; reply?() }
}

@Suite(.serialized) @MainActor struct MobileSceneViewDetachTests {
    private func wait(_ label: String, _ condition: @MainActor () throws -> Bool) async throws {
        for _ in 0..<1500 {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(try condition(), Comment(rawValue: label))
    }

    @Test func actualViewDisappearanceRetainsItsEditorWhileObservationDrains() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths), barrier = ViewDetachReadBarrier()
        let note = try library.store.create(text: "# View-owned pending edit\n")
        let navigation = MobileSceneNavigation()
        navigation.selectedID = note.id
        var editor: MobileEditor? = MobileEditor(library: library)
        weak var disappearingEditor = editor
        let observation = MobileSceneLibraryObservation(navigation: navigation, database: library.database,
            isCurrent: { !library.isClosed }, debounce: .zero, searchOperation: { _, database in
                try await database.pool.read { _ in
                    barrier.hold()
                    return SearchResult(items: [], terms: [])
                }
            })
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            barrier.release(); observation.stop()
            window.isHidden = true; window.rootViewController = nil
            try? library.close(); try? FileManager.default.removeItem(at: paths.root)
            previous?.makeKey()
        }
        window.rootViewController = UIHostingController(rootView:
            MobileLibraryView(library: library, editor: editor, sceneNavigation: navigation,
                sceneObservation: observation, applicationState: { .active }).environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        try await wait("mounted editor ready and scene registered") { editor?.ready == true && library.sceneRegistry.sceneCount == 1 }
        let heldACK = ViewDetachHeldChanges(editor!)
        let controller = editor!.webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "bridge", contentWorld: .page)
        controller.addScriptMessageHandler(heldACK, contentWorld: .page, name: "bridge")
        defer { heldACK.release() }
        try #require(!observation.snapshot.items.isEmpty)
        navigation.query = "held observation"
        try await wait("observation worker held before disappearance") { barrier.entered }
        // Hold the actual browser transaction's ACK across disappearance. Native
        // receipt is not sufficient: detach must wait for the browser's pending queue.
        _ = try await editor!.webView.evaluateJavaScript("(()=>{const v=document.querySelector('.cm-content').cmTile.root.view;v.dispatch({changes:{from:v.state.doc.length,insert:'pending from disappearing view'}})})()")
        try await wait("actual changes reply held before disappearance") { heldACK.isHolding }
        editor = nil // From here onward the fixture has no strong MobileEditor owner.
        window.isHidden = true
        window.rootViewController = nil // Calls the real View.onDisappear -> detachScene Task.
        try await wait("View detach stopped observation before its held read returns") { observation.snapshot.items.isEmpty }
        #expect(disappearingEditor != nil, "The disappearing View must retain its bridge through the observation barrier")
        #expect(library.sceneRegistry.sceneCount == 1)
        barrier.release()
        try await wait("actual detach entered strict drain with browser ACK still held") { library.sceneEditorAdmissionBlocked }
        #expect(heldACK.isHolding && disappearingEditor != nil && library.sceneRegistry.sceneCount == 1)
        heldACK.release()
        try await wait("actual View detach completed") { library.sceneRegistry.sceneCount == 0 }
        #expect(try library.store.note(id: note.id)?.text == note.text + "pending from disappearing view")
        try await library.closeAfterStopping()
    }
}
