// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Testing
import TheoNotesCore
import UIKit
import WebKit
@testable import BaerchenIOS

@Suite(.serialized) @MainActor struct MobileScenePermanentDeleteTests {
    private func wait(stage: String = "page readiness", diagnostics: () -> String = { "" },
                      _ condition: () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition(), "\(stage): \(diagnostics())")
    }
    private enum FixtureCleanup: Error { case databaseStillOpen }
    /// Every exit (including a failed readiness assertion) awaits database users. Never
    /// unlink an open SQLite pool just because a synchronous close reported busy.
    private func withLibrary(_ body: @MainActor (MobileLibrary, AppPaths) async throws -> Void) async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        var bodyError: (any Error)?
        do { try await body(library, paths) } catch { bodyError = error }
        library.beforePermanentDeleteTransactionForTesting = nil
        do {
            if !library.isClosed { try await library.closeAfterStopping() }
            guard library.isClosed else { throw FixtureCleanup.databaseStillOpen }
            try FileManager.default.removeItem(at: paths.root)
        } catch {
            Issue.record("Fixture database retained at \(paths.root.path); cleanup failed: \(error)")
            if let bodyError { throw bodyError }
            throw error
        }
        if let bodyError { throw bodyError }
    }
    @Test func permanentDeleteClosesEveryProtectedPageAndPreservesRestoredOtherScene() async throws {
        try await withLibrary {     library, paths in
            try await library.unlockNotes(password: "isolated deletion fixture", createPassword: true)
            let deleted = try library.store.create(text: "# Private note permanently deleted")
            try library.lockNote(deleted.id)
            try library.store.trash([deleted.id])
            let restored = try library.store.create(text: "# Restored after confirmation")
            library.selectedID = deleted.id
            let leftNav = MobileSceneNavigation(), rightNav = MobileSceneNavigation(), otherNav = MobileSceneNavigation()
            leftNav.selectedID = deleted.id; rightNav.selectedID = deleted.id; otherNav.selectedID = restored.id
            leftNav.pendingCaret[deleted.id] = 12
            rightNav.pendingCallbackNavigation = MobileCallbackNavigation(noteID: deleted.id, header: "Private heading", find: nil, edit: false)
            let left = MobileEditor(library: library), right = MobileEditor(library: library), other = MobileEditor(library: library)
            left.sceneNavigation = leftNav; right.sceneNavigation = rightNav; other.sceneNavigation = otherNav
            try library.registerScene(id: leftNav.id, editor: left, navigation: leftNav, observation: nil, activity: .active)
            try library.registerScene(id: rightNav.id, editor: right, navigation: rightNav, observation: nil, activity: .active)
            try library.registerScene(id: otherNav.id, editor: other, navigation: otherNav, observation: nil, activity: .active)
            let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let previousKey = scene.windows.first(where: \.isKeyWindow)
            let leftWindow = UIWindow(windowScene: scene), rightWindow = UIWindow(windowScene: scene)
            let leftHost = UIViewController(), rightHost = UIViewController()
            leftHost.view = left.webView; rightHost.view = right.webView
            leftWindow.rootViewController = leftHost; rightWindow.rootViewController = rightHost
            leftWindow.makeKeyAndVisible(); rightWindow.makeKeyAndVisible()
            defer { leftWindow.isHidden = true; rightWindow.isHidden = true; previousKey?.makeKey() }
            try left.open(deleted.id); try right.open(deleted.id)
            try await wait { left.ready && right.ready }
            #expect(left.session === right.session)
            leftNav.pendingCaret[deleted.id] = 99
            rightNav.pendingCallbackNavigation = MobileCallbackNavigation(noteID: deleted.id, header: "Private heading", find: nil, edit: false)
            let result = try await library.deleteTrashedNotesAfterDraining([deleted.id, restored.id])
            #expect(result == [deleted.id])
            #expect(try library.store.note(id: deleted.id) == nil)
            #expect(try library.store.note(id: restored.id)?.text == restored.text)
            #expect(left.isClosedForPrivacy && right.isClosedForPrivacy && left.session == nil && right.session == nil)
            #expect(left.webView.isHidden && right.webView.isHidden)
            #expect(!library.hasCachedSession(for: deleted.id) && library.privateAccess != nil)
            #expect(leftNav.selectedID == nil && rightNav.selectedID == nil)
            #expect(leftNav.pendingCaret[deleted.id] == nil && rightNav.pendingCallbackNavigation == nil)
            #expect(otherNav.selectedID == restored.id && !other.isClosedForPrivacy)
            try await library.detachScene(id: leftNav.id); try await library.detachScene(id: rightNav.id)
            try await library.detachScene(id: otherNav.id)
            try await library.closeAfterStopping()
        }
    }
    @Test(arguments: [false, true])
    func restoredCandidateIsFencedBeforeFinalTrashRecheck(retrash: Bool) async throws {
        try await withLibrary {     library, paths in
            try await library.unlockNotes(password: "isolated restore-race fixture", createPassword: true)
            let text = "# Private restored candidate"
            let note = try library.store.create(text: text)
            try library.lockNote(note.id)
            try library.store.trash([note.id])
            let candidates = [note.id] // Exact IDs captured by the earlier confirmation.
            try library.store.restore([note.id])
            let nav = MobileSceneNavigation(), editor = MobileEditor(library: library)
            nav.selectedID = note.id; editor.sceneNavigation = nav
            try library.registerScene(id: nav.id, editor: editor, navigation: nav, observation: nil, activity: .active)
            let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let previousKey = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene), host = UIViewController()
            host.view = editor.webView; window.rootViewController = host; window.makeKeyAndVisible()
            defer { window.isHidden = true; previousKey?.makeKey() }
            try editor.open(note.id)
            try await wait(stage: "restored candidate initial ready/editable (retrash=\(retrash))", diagnostics: {
                let stored = try? library.store.note(id: note.id)
                return "ready=\(editor.ready), editable=\(editor.editable), closed=\(editor.isClosedForPrivacy), mounted=\(editor.webView.window != nil), url=\(editor.webView.url?.absoluteString ?? "nil"), appState=\(UIApplication.shared.applicationState.rawValue), appLocked=\(library.appLocked), pending=\(library.sceneOperationPending), key=\(library.privateAccess != nil), location=\(String(describing: stored?.location)), locked=\(String(describing: stored?.isLocked)), error=\(library.errorMessage ?? "nil")"
            }) { editor.ready && editor.editable }
            var reachedTransaction = false
            library.beforePermanentDeleteTransactionForTesting = {
                reachedTransaction = true
                // This hook runs exactly where a restored candidate could become Trash again.
                // Every originally-confirmed live page must ALREADY be fenced, regardless of
                // the location read before the final Core transaction.
                #expect(editor.isClosedForPrivacy && editor.session == nil && editor.webView.isHidden)
                if retrash { try library.store.trash([note.id]) }
            }
            let deleted = try await library.deleteTrashedNotesAfterDraining(candidates)
            library.beforePermanentDeleteTransactionForTesting = nil
            #expect(reachedTransaction)
            if retrash {
                #expect(deleted == [note.id] && nav.selectedID == nil)
                #expect(try library.store.note(id: note.id) == nil)
            } else {
                #expect(deleted.isEmpty && nav.selectedID == note.id)
                #expect(try library.privateAccess?.note(id: note.id)?.text == text)
                let reopened = MobileEditor(library: library)
                reopened.sceneNavigation = nav
                try library.replaceClosedSceneEditor(id: nav.id, editor: reopened)
                host.view = reopened.webView
                try reopened.open(note.id)
                try await wait(stage: "restored candidate reopen ready/same text", diagnostics: {
                    "ready=\(reopened.ready), closed=\(reopened.isClosedForPrivacy), mounted=\(reopened.webView.window != nil), sessionMatches=\(reopened.session?.text == text), error=\(library.errorMessage ?? "nil")"
                }) { reopened.ready && reopened.session?.text == text }
                #expect(!reopened.webView.isHidden)
                try reopened.closeForPrivacy()
            }
            try await library.detachScene(id: nav.id)
            try await library.closeAfterStopping()
        }
    }

    @Test func freshNeverEditablePageAllowsSafeAsyncDeletionAfterSyncRefusal() async throws {
        try await withLibrary {     library, paths in
            let note = try library.store.create(text: "# Kept while page is not ready")
            try library.store.trash([note.id])
            let nav = MobileSceneNavigation(), editor = MobileEditor(library: library)
            nav.selectedID = note.id; editor.sceneNavigation = nav
            try library.registerScene(id: nav.id, editor: editor, navigation: nav, observation: nil, activity: .active)
            editor.webView.configuration.userContentController.removeAllScriptMessageHandlers()
            try editor.open(note.id)
            #expect(throws: MobileEditorDrainError.self) { try library.deleteTrashedNotes([note.id]) }
            #expect(!editor.ready && editor.canDrainUnreadyNativeSession)
            #expect(try library.store.note(id: note.id) != nil && nav.selectedID == note.id)
            let deleted = try await library.deleteTrashedNotesAfterDraining([note.id])
            #expect(deleted == [note.id])
            #expect(try library.store.note(id: note.id) == nil)
            #expect(nav.selectedID == nil && editor.session == nil && editor.isClosedForPrivacy && editor.webView.isHidden)
            try await library.detachScene(id: nav.id)
            try await library.closeAfterStopping()
        }
    }

    @Test func cancelledDeletionWithActualUnacknowledgedBrowserEditPreservesNoteAndSession() async throws {
        try await withLibrary { library, _ in
            let note = try library.store.create(text: "# Keep actual pending edit\n")
            let nav = MobileSceneNavigation(), editor = MobileEditor(library: library)
            nav.selectedID = note.id; editor.sceneNavigation = nav
            try library.registerScene(id: nav.id, editor: editor, navigation: nav, observation: nil, activity: .active)
            let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene), host = UIViewController()
            host.view = editor.webView; window.rootViewController = host; window.makeKeyAndVisible()
            defer { window.isHidden = true; previous?.makeKey() }
            try editor.open(note.id)
            try await wait { editor.ready && editor.editable }
            let session = try #require(editor.session)
            let held = PermanentDeleteHeldChanges(editor)
            let controller = editor.webView.configuration.userContentController
            controller.removeScriptMessageHandler(forName: "bridge", contentWorld: .page)
            controller.addScriptMessageHandler(held, contentWorld: .page, name: "bridge")
            defer { held.release() }
            _ = try await editor.webView.evaluateJavaScript("(()=>{const v=document.querySelector('.cm-content').cmTile.root.view;v.dispatch({changes:{from:v.state.doc.length,insert:'retain this browser transaction'}})})()")
            try await wait { held.isHolding }
            let expected = note.text + "retain this browser transaction"
            #expect(session.text == expected)
            // A remote/other-process location change can arrive while the browser still
            // awaits its ACK. The page remains a live, previously editable source.
            try library.store.trash([note.id])
            #expect(!editor.canDrainUnreadyNativeSession)
            #expect(throws: MobileEditorDrainError.self) { try library.deleteTrashedNotes([note.id]) }
            let deleting = Task { try await library.deleteTrashedNotesAfterDraining([note.id]) }
            defer { deleting.cancel() }
            try await wait { library.sceneEditorAdmissionBlocked }
            #expect(held.isHolding && editor.session === session && !editor.isClosedForPrivacy)
            #expect(try library.store.note(id: note.id) != nil && nav.selectedID == note.id)
            deleting.cancel()
            held.release()
            await #expect(throws: CancellationError.self) { _ = try await deleting.value }
            #expect(editor.session === session && session.text == expected && !editor.isClosedForPrivacy)
            #expect(nav.selectedID == note.id)
            #expect(try library.store.note(id: note.id)?.location == .trash)
            try await library.detachScene(id: nav.id) // Actual close flushes the preserved journal.
            #expect(try library.store.note(id: note.id)?.text == expected)
        }
    }

}


@MainActor private final class PermanentDeleteHeldChanges: NSObject, WKScriptMessageHandlerWithReply {
    weak var editor: MobileEditor?
    private var pending: (() -> Void)?
    private var didHold = false
    var isHolding: Bool { pending != nil }
    init(_ editor: MobileEditor) { self.editor = editor }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        guard let editor else { replyHandler(nil, "Editor released"); return }
        if !didHold, (message.body as? [String: Any])?["type"] as? String == "changes" {
            editor.userContentController(controller, didReceive: message) { result, error in
                // Hold only the ack of an edit the session applied. Right after `editable` turns true
                // the host may still refuse edits (its loadNote send is pending); that refusal goes
                // back at once so the page resends, as in the app. `isHolding` then means "applied".
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
