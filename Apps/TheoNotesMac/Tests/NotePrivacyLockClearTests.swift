// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import Testing
import WebKit
@testable import TheoNotes

/// An editor page on a real `WKWebView` that can drop the placeholder deliveries a clear needs.
@MainActor
final class FaultyLivePage: EditorPage {
    /// What a reload of the bundle (the fail-closed fallback) does.
    enum Reload { case commits, neverCommits, failsNavigation }

    weak var webView: WKWebView?
    var dropsClears = false
    var reload = Reload.commits

    func loadBundle() { webView?.load(URLRequest(url: AssetSchemeHandler.indexURL)) }

    func use(webView: WKWebView) { self.webView = webView }

    func reloadBundle(committed: @escaping @MainActor (Bool) -> Void) {
        switch reload {
        case .neverCommits:
            break  // the navigation hangs: no document is ever replaced, nothing reports back
        case .failsNavigation:
            Task { committed(false) }
        case .commits:
            loadBundle()
            Task { [weak self] in
                // Stands in for didCommit: the load has started and has been answered.
                while self?.webView?.isLoading == true { try? await Task.sleep(for: .milliseconds(10)) }
                committed(true)
            }
        }
    }

    func deliver(_ message: HostToEditorMessage, completion: @escaping @MainActor (Error?) -> Void) {
        if dropsClears, message == EditorBridgeController.placeholderLoad {
            return completion(URLError(.cannotConnectToHost))
        }
        guard let webView else { return completion(URLError(.badURL)) }
        let json: Any
        do { json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) } catch { return completion(error) }
        webView.callAsyncJavaScript("window.__baerchen.receive(msg)", arguments: ["msg": json], in: nil, in: .page) { result in
            if case .failure(let error) = result { completion(error) } else { completion(nil) }
        }
    }
}

/// A real editor page on a `PrivacyFixture`'s library, offscreen.
@MainActor
final class LivePrivacyEditor {
    let controller: EditorBridgeController
    let page = FaultyLivePage()
    let window: NSWindow

    init(_ fixture: PrivacyFixture, commitTimeout: Duration = .seconds(5)) {
        controller = EditorBridgeController(
            environment: fixture.environment, page: page, openExternally: { _ in }, checksumInterval: nil,
            clearTimeout: .seconds(5), commitTimeout: commitTimeout)
        window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 640, height: 480),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let webView = controller.webView
        webView.frame = window.contentView!.bounds
        webView.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(webView)
        window.orderFront(nil)
        page.webView = webView
        page.loadBundle()
    }

    func close() { window.close() }

    @discardableResult
    func js(_ body: String) async throws -> Any? {
        try await controller.webView.callAsyncJavaScript(LiveEditor.hooks + body, arguments: [:], contentWorld: .page)
    }

    func waitUntilShowing(_ text: String) async throws {
        try await waitUntil("editor shows the note") {
            guard controller.isEditorReady else { return false }
            return ((try? await js("return hooks.text()")) as? String) == text
        }
    }

    func dom() async throws -> String {
        try #require(try await js("return document.documentElement.outerHTML + document.body.innerText") as? String)
    }
}

/// M9 Mac task 5, fix round 1: Lock Note is two-phase. Every editor showing the note goes to the
/// placeholder, and the page confirms it dropped the text (or is replaced), before the session is
/// dropped and the note is locked.
@MainActor
@Suite(.serialized) struct NotePrivacyLockClearTests {
    @Test func lockWaitsForTheEditorPagesToConfirmTheClearBeforeItLocks() async throws {
        let fx = try PrivacyFixture()
        defer { fx.destroy() }
        try await fx.makePassword()
        let id = try fx.addNote()
        let (editor, page) = fx.makeEditor()
        try editor.open(noteId: id)
        fx.select([id])
        page.autoComplete = false

        let lock = Task { await fx.controller.lockSelectedNotes() }
        for _ in 0..<50 where editor.pendingClears == 0 { await Task.yield() }

        #expect(editor.pendingClears == 1)
        #expect(editor.session == nil, "the editor let go of the note first")
        #expect(try !fx.note(id).isLocked, "locked only after the clear is confirmed")

        page.completeDeliveries()
        await lock.value

        #expect(try fx.note(id).isLocked)
        #expect(editor.pendingClears == 0 && editor.failClosedResets == 0)
        let session = try #require(editor.session)
        #expect(fx.environment.isKeyedSession(session))
    }

    @Test func aClearThatCannotBeDeliveredReplacesThePageBeforeTheLock() async throws {
        let fx = try PrivacyFixture()
        defer { fx.destroy() }
        try await fx.makePassword()
        let id = try fx.addNote()
        let (editor, page) = fx.makeEditor()
        try editor.open(noteId: id)
        fx.select([id])
        page.deliveryError = URLError(.cannotConnectToHost)
        let loadsBefore = page.bundleLoads

        await fx.controller.lockSelectedNotes()

        #expect(editor.failClosedResets >= 1)
        #expect(page.bundleLoads > loadsBefore, "the page that held the text is replaced")
        #expect(try fx.note(id).isLocked)
    }

    @Test func aFallbackThatNeverCommitsReplacesTheWebViewBeforeTheLock() async throws {
        let fx = try PrivacyFixture()
        defer { fx.destroy() }
        try await fx.makePassword()
        let id = try fx.addNote()
        let page = FakeEditorPage()
        let editor = EditorBridgeController(
            environment: fx.environment, page: page, openExternally: { _ in }, checksumInterval: nil,
            clearTimeout: .milliseconds(20), commitTimeout: .milliseconds(60))
        _ = editor.handle(.ready(version: EditorBridge.version))
        try editor.open(noteId: id)
        fx.select([id])
        page.autoComplete = false
        page.reloadsCommit = false

        await fx.controller.lockSelectedNotes()

        #expect(editor.failClosedResets == 1)
        #expect(editor.webViewReplacements == 1)
        #expect(editor.pendingClears == 0)
        #expect(try fx.note(id).isLocked)
    }

    @Test func aFailedNavigationDuringTheLockReplacesTheWebViewAtOnce() async throws {
        let fx = try PrivacyFixture()
        defer { fx.destroy() }
        try await fx.makePassword()
        let id = try fx.addNote()
        let page = FakeEditorPage()
        let editor = EditorBridgeController(
            environment: fx.environment, page: page, openExternally: { _ in }, checksumInterval: nil,
            clearTimeout: .milliseconds(20), commitTimeout: .seconds(30))
        _ = editor.handle(.ready(version: EditorBridge.version))
        try editor.open(noteId: id)
        fx.select([id])
        page.autoComplete = false
        page.reloadsCommit = false

        let lock = Task { await fx.controller.lockSelectedNotes() }
        try await waitUntil("the fallback started") { editor.failClosedResets == 1 }
        #expect(try !fx.note(id).isLocked, "not locked while the old document may still be in the page")
        #expect(editor.webViewReplacements == 0)
        page.commitReloads(false)
        await lock.value

        #expect(editor.webViewReplacements == 1)
        #expect(try fx.note(id).isLocked)
    }

    @Test func everyWindowShowingTheNoteIsClearedFirst() async throws {
        let fx = try PrivacyFixture()
        defer { fx.destroy() }
        try await fx.makePassword()
        let id = try fx.addNote()
        let (first, firstPage) = fx.makeEditor()
        let (second, secondPage) = fx.makeEditor()
        try first.open(noteId: id)
        try second.open(noteId: id)
        fx.select([id])
        firstPage.autoComplete = false
        secondPage.autoComplete = false

        let lock = Task { await fx.controller.lockSelectedNotes() }
        for _ in 0..<50 where first.pendingClears + second.pendingClears < 2 { await Task.yield() }
        #expect(first.pendingClears == 1 && second.pendingClears == 1)
        #expect(try !fx.note(id).isLocked)
        firstPage.completeDeliveries()
        await Task.yield()
        #expect(try !fx.note(id).isLocked, "one confirmation is not enough")
        secondPage.completeDeliveries()
        await lock.value

        #expect(try fx.note(id).isLocked)
        #expect(first.session != nil && second.session != nil)
    }

    @Test func aFailedClearAndAFailedReopenLeaveNoPlaintextInARealPage() async throws {
        let fx = try PrivacyFixture()
        defer { fx.destroy() }
        try await fx.makePassword()
        let text = "# Open\n\n\(PrivacyFixture.secret)"
        let id = try fx.addNote(text)
        let live = LivePrivacyEditor(fx)
        defer { live.close() }
        try live.controller.open(noteId: id)
        try await live.waitUntilShowing(text)
        #expect(try await live.dom().contains(PrivacyFixture.secret), "the page shows the plaintext before the lock")
        fx.select([id])
        live.page.dropsClears = true
        fx.environment.sessionOpenFault = { _ in URLError(.cannotOpenFile) }

        await fx.controller.lockSelectedNotes()

        #expect(try fx.note(id).isLocked)
        #expect(live.controller.failClosedResets == 1)
        #expect(live.controller.webViewReplacements == 0, "the reload committed, the web view stays")
        #expect(live.controller.session == nil, "the reopen failed, nothing is shown")
        let dom = try await live.dom()
        #expect(!dom.contains(PrivacyFixture.secret))
        // The replacement page boots with nothing to show: still no text once it is ready.
        try await waitUntil("replacement page booted") { live.controller.isEditorReady }
        #expect(try await !live.dom().contains(PrivacyFixture.secret))
        #expect(live.controller.session == nil)
    }

    @Test func aReloadThatNeverCommitsReplacesTheWebViewAndLeavesNoPlaintext() async throws {
        try await replacementScenario(.neverCommits)
    }

    @Test func aFailedNavigationReplacesTheWebViewAndLeavesNoPlaintext() async throws {
        try await replacementScenario(.failsNavigation)
    }

    private func replacementScenario(_ reload: FaultyLivePage.Reload) async throws {
        let fx = try PrivacyFixture()
        defer { fx.destroy() }
        try await fx.makePassword()
        let text = "# Open\n\n\(PrivacyFixture.secret)"
        let id = try fx.addNote(text)
        let live = LivePrivacyEditor(fx, commitTimeout: .milliseconds(150))
        defer { live.close() }
        try live.controller.open(noteId: id)
        try await live.waitUntilShowing(text)
        let old = live.controller.webView
        fx.select([id])
        live.page.dropsClears = true
        live.page.reload = reload
        fx.environment.sessionOpenFault = { _ in URLError(.cannotOpenFile) }

        await fx.controller.lockSelectedNotes()

        #expect(try fx.note(id).isLocked)
        #expect(live.controller.webViewReplacements == 1)
        #expect(live.controller.webView !== old)
        #expect(old.superview == nil && old.window == nil, "the web view that held the text is out of the window")
        #expect(live.controller.session == nil, "the reopen failed, nothing is shown")
        try await waitUntil("replacement page booted") { live.controller.isEditorReady }
        #expect(try await !live.dom().contains(PrivacyFixture.secret))
        #expect(try await live.js("return hooks.undo()") as? Bool != true)
    }

    @Test func aWorkingClearEmptiesARealPageBeforeTheLockAndTheNoteComesBackKeyed() async throws {
        let fx = try PrivacyFixture()
        defer { fx.destroy() }
        try await fx.makePassword()
        let text = "# Open\n\n\(PrivacyFixture.secret)"
        let id = try fx.addNote(text)
        let live = LivePrivacyEditor(fx)
        defer { live.close() }
        try live.controller.open(noteId: id)
        try await live.waitUntilShowing(text)
        fx.select([id])

        await fx.controller.lockSelectedNotes()

        #expect(live.controller.failClosedResets == 0)
        #expect(try fx.note(id).isLocked)
        try await live.waitUntilShowing(text)
        let session = try #require(live.controller.session)
        #expect(fx.environment.isKeyedSession(session))
    }
}
