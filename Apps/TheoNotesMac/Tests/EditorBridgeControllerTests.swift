// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import Synchronization
import Testing
import WebKit
@testable import TheoNotes

@Suite @MainActor struct EditorWebKitDeliveryTests {
    @Test func deliveryWaitsForRecoveryPromise() async throws {
        let webView = WKWebView()
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        try await waiter.load("<script>window.__baerchen = { receive: () => new Promise(resolve => { window.finishRecovery = resolve }) };</script>", in: webView)
        let page = WebKitEditorPage(webView: webView)
        var completed = false
        page.deliver(.loadNote(noteId: "note", text: "saved", revision: 0, readOnly: false)) { error in
            #expect(error == nil)
            completed = true
        }
        for _ in 0..<100 {
            if (try await webView.evaluateJavaScript("typeof window.finishRecovery === 'function'")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!completed)
        _ = try await webView.evaluateJavaScript("window.finishRecovery()")
        for _ in 0..<100 where !completed { try await Task.sleep(for: .milliseconds(10)) }
        #expect(completed)
    }
}

@MainActor
final class FakeEditorPage: EditorPage {
    var bundleLoads = 0
    var delivered: [HostToEditorMessage] = []
    /// When false, deliveries stay pending until `completeDeliveries()`.
    var autoComplete = true
    /// When set, every delivery fails with it.
    var deliveryError: Error?
    private var pending: [@MainActor (Error?) -> Void] = []

    var loadNotes: [HostToEditorMessage] {
        delivered.filter { if case .loadNote = $0 { true } else { false } }
    }

    func loadBundle() { bundleLoads += 1 }

    /// The looks `settleChrome` was called with (page root + boot style, M7 Task 7).
    var settledLooks: [EditorLook] = []
    func settleChrome(_ look: EditorLook) { settledLooks.append(look) }

    func deliver(_ message: HostToEditorMessage, completion: @escaping @MainActor (Error?) -> Void) {
        delivered.append(message)
        if let deliveryError { completion(deliveryError) } else if autoComplete { completion(nil) } else { pending.append(completion) }
    }

    /// Reloads of the bundle: when false, `reloadBundle` never reports a commit until `commitReloads()`.
    var reloadsCommit = true
    private var pendingCommits: [@MainActor (Bool) -> Void] = []
    /// The web views the controller handed the page over to (after a replacement).
    var replacementWebViews: [WKWebView] = []

    func reloadBundle(committed: @escaping @MainActor (Bool) -> Void) {
        loadBundle()
        if reloadsCommit { committed(true) } else { pendingCommits.append(committed) }
    }

    func use(webView: WKWebView) { replacementWebViews.append(webView) }

    func commitReloads(_ committed: Bool = true) {
        let waiting = pendingCommits
        pendingCommits = []
        waiting.forEach { $0(committed) }
    }

    func completeDeliveries() {
        let completions = pending
        pending = []
        completions.forEach { $0(nil) }
    }

    /// Completes only the oldest pending delivery (WebKit completes them in order).
    func completeNextDelivery() {
        guard !pending.isEmpty else { return }
        pending.removeFirst()(nil)
    }

    var checksumRequestIds: [String] {
        delivered.compactMap { if case .requestChecksum(let id) = $0 { id } else { nil } }
    }

    /// The `freezeForClose` questions the controller asked the page (W1).
    var freezeRequests: [(requestId: String, noteId: String)] {
        delivered.compactMap { if case .freezeForClose(let requestId, let noteId) = $0 { (requestId, noteId) } else { nil } }
    }
}

/// `-[WKFrameInfo dealloc]` crashes for instances not created by WebKit, so the fakes are
/// process-lifetime singletons that are never deallocated.
final class FakeFrameInfo: WKFrameInfo {
    @MainActor static let main = FakeFrameInfo(main: true)
    @MainActor static let sub = FakeFrameInfo(main: false)
    private let main: Bool
    private init(main: Bool) {
        self.main = main
        super.init()
    }
    override var isMainFrame: Bool { main }
}

final class FakeNavigationAction: WKNavigationAction {
    enum Target { case mainFrame, subframe, newWindow }
    private let fakeRequest: URLRequest
    private let fakeType: WKNavigationType
    private let fakeTarget: WKFrameInfo?

    init(url: String, type: WKNavigationType = .other, target: Target = .mainFrame) {
        fakeRequest = URLRequest(url: URL(string: url)!)
        fakeType = type
        switch target {
        case .mainFrame: fakeTarget = FakeFrameInfo.main
        case .subframe: fakeTarget = FakeFrameInfo.sub
        case .newWindow: fakeTarget = nil
        }
        super.init()
    }
    override var request: URLRequest { fakeRequest }
    override var navigationType: WKNavigationType { fakeType }
    override var targetFrame: WKFrameInfo? { fakeTarget }
}

@MainActor
@Suite struct EditorBridgeControllerTests {
    let root: URL
    let environment: AppEnvironment
    let page = FakeEditorPage()
    var opened: [URL] { openedBox.urls }
    let openedBox = URLBox()
    let controller: EditorBridgeController
    let noteId: String

    final class URLBox { var urls: [URL] = [] }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("TheoNotesMacTests-\(UUID().uuidString)")
        environment = try AppEnvironment(paths: AppPaths(root: root))
        noteId = try environment.store.create(text: "hello").id
        let box = openedBox
        controller = EditorBridgeController(
            environment: environment, page: page, openExternally: { box.urls.append($0) }, checksumInterval: nil
        )
    }

    private func insert(_ s: String, at pos: Int, length: Int, txId: String, base: Int) -> EditorToHostMessage {
        .changes(
            noteId: noteId, txId: txId, baseRevision: base, revision: base + 1,
            changeSet: ChangeSet(sections: [.retain(pos), .replace(deleteLength: 0, insert: s), .retain(length - pos)])
        )
    }

    @Test func foldStateLoadsPersistsAndIgnoresAnotherNote() throws {
        let folds = [try #require(FoldEntry(line: 1, hash: "12345678"))]
        try environment.store.setFoldState(noteId: noteId, folds)
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: EditorBridge.version))
        guard case let .loadNote(_, _, _, _, _, _, saved) = page.loadNotes.last else {
            Issue.record("missing load"); return
        }
        #expect(saved == folds)
        let other = try environment.store.create(text: "# Other\nBody")
        _ = controller.handle(.foldState(noteId: other.id, folds: folds))
        #expect(try environment.store.foldState(noteId: other.id).isEmpty)
        _ = controller.handle(.foldState(noteId: noteId, folds: []))
        #expect(try environment.store.foldState(noteId: noteId).isEmpty)
    }

    @Test func loadNoteIsSentOnReadyAndChangesAreAcked() throws {
        try controller.open(noteId: noteId)
        #expect(page.delivered.isEmpty) // editor not ready yet
        _ = controller.handle(.ready(version: 1))
        #expect(page.loadNotes == [.loadNote(noteId: noteId, text: "hello", revision: 0, readOnly: false)])
        let reply = controller.handle(insert("!", at: 5, length: 5, txId: "t1", base: 0))
        #expect(reply == .acked(revision: 1))
        #expect(try environment.session(for: noteId).text == "hello!")
    }

    /// The editor loads the placeholder locked by its id; both sides pin that message to the shared
    /// fixture `messages-loadNote-placeholder.json` (the editor's client.test.ts reads it too).
    @Test func thePlaceholderIsTheSharedFixture() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/bridge/messages-loadNote-placeholder.json")
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? NSDictionary
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(EditorBridgeController.placeholderLoad)) as? NSDictionary
        #expect(expected != nil && encoded == expected)
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: EditorBridge.version))
        controller.showNoNote()
        #expect(page.loadNotes.last == EditorBridgeController.placeholderLoad)
    }

    // MARK: - Read-only notes

    @Test func changesForANoteLoadedReadOnlyAreRefusedAndTheNoteReloads() throws {
        try environment.store.trash([noteId])
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: EditorBridge.version))
        let session = try environment.session(for: noteId)
        let revision = session.revision
        #expect(page.loadNotes == [.loadNote(noteId: noteId, text: "hello", revision: revision, readOnly: true)])
        let reply = controller.handle(insert("!", at: 5, length: 5, txId: "t1", base: revision))
        #expect(reply == .needsFullText(currentRevision: revision))
        #expect(session.text == "hello")
        #expect(session.revision == revision)
        #expect(page.loadNotes.count == 2) // reloaded with the unchanged text

        // Restored and shown again editable: changes apply.
        try environment.store.restore([noteId])
        controller.reloadShownNote()
        guard case let .loadNote(_, _, current, readOnly, _, _, _) = page.loadNotes.last else {
            Issue.record("no reload")
            return
        }
        #expect(readOnly == false)
        #expect(controller.handle(insert("!", at: 5, length: 5, txId: "t2", base: current)) == .acked(revision: current + 1))
        #expect(session.text == "hello!")
    }

    // MARK: - Editor settings (setSettings)

    private var settingsMessages: [EditorSettings] {
        page.delivered.compactMap { if case .setSettings(let s) = $0 { s } else { nil } }
    }

    @Test func defaultSettingsAreNotSentOnReady() throws {
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: EditorBridge.version))
        #expect(settingsMessages.isEmpty)
        #expect(page.loadNotes.count == 1)
    }

    @Test func settingsThatDifferFromTheEditorDefaultsGoBeforeTheNote() throws {
        let settings = TheoNotesCore.Settings(db: environment.database)
        settings.hideMarkdown = false
        settings.autoSortTodos = true
        settings.showHeadingLevels = false
        let page = FakeEditorPage()
        let controller = EditorBridgeController(environment: environment, page: page, openExternally: { _ in }, checksumInterval: nil)
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: EditorBridge.version))
        guard page.delivered.count >= 2, case .setSettings(let sent) = page.delivered[0], case .loadNote = page.delivered[1] else {
            Issue.record("expected setSettings then loadNote: \(page.delivered)")
            return
        }
        #expect(sent == EditorSettings(hideMarkdown: false, autoSortTodos: true, showHeadingLevels: false))
        // A new page (WebContent restart) starts from the defaults again.
        controller.simulateWebContentTermination()
        _ = controller.handle(.ready(version: EditorBridge.version))
        #expect(page.delivered.filter { if case .setSettings = $0 { true } else { false } }.count == 2)
    }

    /// M6 Task 14: Typewriter Mode is app-wide; the menu and Settings write the same key.
    @Test func typewriterModeGoesBeforeTheNoteAndFollowsTheSetting() async throws {
        let settings = TheoNotesCore.Settings(db: environment.database)
        settings.typewriterMode = true
        let page = FakeEditorPage()
        let controller = EditorBridgeController(environment: environment, page: page, openExternally: { _ in }, checksumInterval: nil)
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: EditorBridge.version))
        guard page.delivered.count >= 2, case .setSettings(let sent) = page.delivered[0], case .loadNote = page.delivered[1] else {
            Issue.record("expected setSettings then loadNote: \(page.delivered)")
            return
        }
        #expect(sent == EditorSettings(typewriterMode: true))
        let sentCount = { page.delivered.compactMap { if case .setSettings(let s) = $0 { s } else { nil } } }
        settings.typewriterMode = false
        try await waitUntil("typewriterMode off sent") { sentCount().last == EditorSettings(typewriterMode: false) }
    }

    @Test func changingASettingReachesTheOpenEditorWithoutReloadingIt() async throws {
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: EditorBridge.version))
        let settings = TheoNotesCore.Settings(db: environment.database)
        settings.hideMarkdown = false
        try await waitUntil("hideMarkdown sent") { settingsMessages == [EditorSettings(hideMarkdown: false)] }
        settings.autoSortTodos = true
        try await waitUntil("autoSortTodos sent") { settingsMessages.last == EditorSettings(autoSortTodos: true) }
        settings.hideMarkdown = true
        try await waitUntil("hideMarkdown back on") { settingsMessages.last == EditorSettings(hideMarkdown: true) }
        settings.showHeadingLevels = false
        try await waitUntil("heading levels hidden") { settingsMessages.last == EditorSettings(showHeadingLevels: false) }
        // Other settings change nothing in the editor.
        let seen = controller.settingsSnapshotsSeen
        settings.showNoteCounts = false
        try await waitUntil("showNoteCounts observed") { controller.settingsSnapshotsSeen > seen }
        #expect(settingsMessages.count == 4)
        #expect(page.loadNotes.count == 1)
    }

    /// M7 Task 6: the editor's look goes out as `setSettings` when it differs from the page's, the
    /// settings snapshots do not undo it, and the theme map on the wire is the sanitized one.
    @Test func theEditorLookIsSentOnceAndNeverUnsanitized() async throws {
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: EditorBridge.version))
        let dark = try #require(ThemeCatalog.theme(id: ThemeCatalog.defaultDarkId))
        // `editorVariables` is built once per theme; a stray variable must still be dropped on the way out.
        let theme = dark.editorVariables.merging(["--bc-nonsense": "#ffffff", "--bc-color-link": "red"]) { _, new in new }
        let typography = EditorTypography(paragraphIndent: 1.5, fontText: "Iowan Old Style")
        controller.setEditorLook(typography: typography, theme: theme, appearance: .dark, reduceMotion: true)
        #expect(settingsMessages.count == 1)
        let wire = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(HostToEditorMessage.setSettings(settingsMessages[0]))) as? [String: Any]
        #expect(wire?["theme"] as? [String: String] == ThemeSchema.sanitize(variables: theme))
        #expect((wire?["theme"] as? [String: String])?["--bc-nonsense"] == nil)
        #expect(wire?["appearance"] as? String == "dark")
        #expect(wire?["reduceMotion"] as? Bool == true)
        #expect((wire?["typography"] as? [String: Any])?["fontText"] as? String == "Iowan Old Style")

        // The same look again sends nothing; neither does a snapshot of the stored toggles.
        controller.setEditorLook(typography: typography, theme: theme, appearance: .dark, reduceMotion: true)
        #expect(settingsMessages.count == 1)
        let settings = TheoNotesCore.Settings(db: environment.database)
        settings.hideMarkdown = false
        try await waitUntil("hideMarkdown sent") { settingsMessages.last == EditorSettings(hideMarkdown: false) }
        #expect(settingsMessages.count == 2, "the snapshot did not touch the look")

        // Back to the defaults resets the page.
        controller.setEditorLook(typography: nil, theme: nil, appearance: nil, reduceMotion: nil)
        #expect(settingsMessages.last == EditorSettings(typography: EditorTypography(), theme: [:], appearance: .light, reduceMotion: false))
    }

    @Test func webContentTerminationReloadsFromSession() throws {
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: 1))
        #expect(controller.handle(insert(" world", at: 5, length: 5, txId: "t1", base: 0)) == .acked(revision: 1))
        #expect(page.bundleLoads == 1)

        controller.simulateWebContentTermination()
        #expect(page.bundleLoads == 2)
        #expect(page.loadNotes.count == 1) // nothing is sent before the new page is ready

        _ = controller.handle(.ready(version: 1))
        let session = try environment.session(for: noteId)
        #expect(page.loadNotes.last == .loadNote(noteId: noteId, text: session.text, revision: session.revision, readOnly: false))
        #expect(session.text == "hello world")
    }

    private func decide(
        _ url: String, type: WKNavigationType = .other, target: FakeNavigationAction.Target = .mainFrame
    ) -> WKNavigationActionPolicy {
        var policy: WKNavigationActionPolicy?
        controller.webView(controller.webView, decidePolicyFor: FakeNavigationAction(url: url, type: type, target: target)) {
            policy = $0
        }
        return policy!
    }

    @Test func nonAssetNavigationIsCancelled() {
        #expect(decide("baerchen-asset://editor/index.html") == .allow)
        #expect(decide("baerchen-asset://elsewhere/index.html") == .cancel)
        #expect(decide("file:///etc/passwd", type: .linkActivated) == .cancel)
        #expect(decide("about:blank") == .cancel)
        // Script-driven, meta-refresh, form and subframe navigations are cancelled and not opened.
        #expect(decide("https://example.com/script") == .cancel)
        #expect(decide("https://example.com/form", type: .formSubmitted) == .cancel)
        #expect(decide("https://example.com/frame", type: .linkActivated, target: .subframe) == .cancel)
        #expect(opened.isEmpty)
    }

    /// An SVG attachment can be an image in the page, never a page: navigation to any attachment URL
    /// is cancelled (also if `navigationPolicy` is widened later this pins the SVG case) and not opened.
    @Test func navigatingToAnSVGAttachmentIsCancelledEverywhere() {
        let url = "baerchen-asset://attachment/\(noteId)/a.svg"
        for type: WKNavigationType in [.linkActivated, .other] {
            for target: FakeNavigationAction.Target in [.mainFrame, .subframe, .newWindow] {
                #expect(decide(url, type: type, target: target) == .cancel, "\(type.rawValue) \(target)")
            }
        }
        #expect(opened.isEmpty)
    }

    @Test func clickedHttpLinksOpenExternally() {
        #expect(decide("https://example.com/page", type: .linkActivated) == .cancel)
        #expect(decide("http://example.com/", type: .linkActivated, target: .newWindow) == .cancel)
        #expect(opened.map(\.absoluteString) == ["https://example.com/page", "http://example.com/"])
    }

    @Test func changesPostedBeforePendingReloadAreNotApplied() throws {
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: 1))
        page.autoComplete = false
        _ = controller.handle(.error(message: "halted", stack: nil))
        #expect(page.loadNotes.count == 2)

        // Base revision matches the host, but the page has not handled the reload yet.
        #expect(controller.handle(insert("!", at: 5, length: 5, txId: "late", base: 0)) == .needsFullText(currentRevision: 0))
        let session = try environment.session(for: noteId)
        #expect(session.text == "hello")
        #expect(session.revision == 0)
        #expect(page.loadNotes.count == 2)

        page.completeDeliveries()
        #expect(controller.handle(insert("!", at: 5, length: 5, txId: "fresh", base: 0)) == .acked(revision: 1))
        #expect(session.text == "hello!")
    }

    @Test func failedOpenKeepsCurrentNoteAttached() throws {
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: 1))
        #expect(throws: (any Error).self) { try controller.open(noteId: "missing-note") }
        #expect(controller.session?.noteId == noteId)

        let note = try #require(try environment.store.note(id: noteId))
        _ = try environment.store.updateText(id: noteId, text: "hello there", expectedRevision: note.revision)
        environment.databaseDidChange()
        guard case .applyExternalChange(let id, _, _)? = page.delivered.last else {
            Issue.record("external change not forwarded after failed open: \(page.delivered)")
            return
        }
        #expect(id == noteId)
    }

    @Test func readyResetsReloadCap() throws {
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: 1))
        for _ in 0..<(EditorBridgeController.maxReloadsWithoutAck + 2) {
            _ = controller.handle(.error(message: "boom", stack: nil))
        }
        let capped = page.loadNotes.count
        controller.simulateWebContentTermination()
        _ = controller.handle(.ready(version: 1))
        _ = controller.handle(.error(message: "boom", stack: nil))
        #expect(page.loadNotes.count == capped + 2) // loadNote on ready, then one reload
    }

    @Test func recoveryTextIsSavedToItsOriginalCachedSessionAndReplayIsIdempotent() throws {
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: 1))
        let other = try environment.store.create(text: "Other note")
        try controller.open(noteId: other.id)
        let message = EditorToHostMessage.recoveryText(noteId: noteId, baseRevision: 0, text: "Unacknowledged browser text")
        #expect(controller.handle(message) == .acked(revision: 0))
        #expect(controller.handle(message) == .acked(revision: 0))
        #expect(try environment.store.note(id: noteId)?.text == "hello")
        #expect(try environment.store.note(id: other.id)?.text == "Other note")
        #expect(try environment.store.allNotes().filter { $0.text == "Unacknowledged browser text" }.count == 1)
        #expect(page.loadNotes.last == .loadNote(noteId: other.id, text: "Other note", revision: 0, readOnly: false))
        #expect(controller.handle(.recoveryText(noteId: UUID().uuidString, baseRevision: 0, text: "Wrong destination")) == .needsFullText(currentRevision: 0))
    }

    @Test func deletedSourceRetainsRecoverySessionAfterUncache() throws {
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: 1))
        try environment.database.pool.write { db in try db.execute(sql: "DELETE FROM note WHERE id = ?", arguments: [noteId]) }
        environment.closeSessionsOfDeletedNotes()
        #expect(environment.existingSession(for: noteId) == nil)
        #expect(controller.handle(.recoveryText(noteId: noteId, baseRevision: 0, text: "Recovered after deletion")) == .acked(revision: 0))
        #expect(try environment.store.allNotes().filter { $0.text == "Recovered after deletion" }.count == 1)
    }

    @Test func discardConfirmationCannotReplaceAChangedDocument() throws {
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: 1))
        _ = controller.handle(.recoveryText(noteId: UUID().uuidString, baseRevision: 0, text: "unavailable"))
        let token = try #require(controller.browserDiscardToken)
        let pageBefore = controller.webViewReplacements
        controller.reloadShownNote()
        controller.discardBrowserTextAfterConfirmation(token)
        #expect(controller.webViewReplacements == pageBefore)
    }

    @Test func protectedBrowserRecoveryCannotFallbackToPlaintextAfterRevocation() async throws {
        try await environment.vault.createPassword("browser-recovery-test")
        let access = try #require(environment.vault.access)
        try access.lock(noteId: noteId)
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: 1))
        #expect(controller.handle(.recoveryText(noteId: noteId, baseRevision: 0, text: "Protected browser recovery")) == .acked(revision: 0))
        let copies = try environment.store.allNotes().filter { $0.id != noteId }
        let copy = try #require(copies.first)
        #expect(copies.count == 1 && copy.isLocked && copy.text.isEmpty)
        #expect(try access.note(id: copy.id)?.text == "Protected browser recovery")
        access.revoke()
        guard case .needsFullText = controller.handle(.recoveryText(noteId: noteId, baseRevision: 0, text: "Do not persist without a key")) else {
            Issue.record("Revoked recovery must never be acknowledged"); return
        }
        #expect(controller.status.recoveryError != nil)
        #expect(try environment.store.allNotes().count == 2)
    }

    @Test func needsFullTextSendsSingleLoadNote() throws {
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: 1))
        #expect(page.loadNotes.count == 1)
        page.autoComplete = false

        // Several in-flight transactions built on a stale document all come back needsFullText.
        let stale = ChangeSet(sections: [.retain(3), .replace(deleteLength: 0, insert: "x")])
        for i in 0..<3 {
            let reply = controller.handle(.changes(noteId: noteId, txId: "s\(i)", baseRevision: 0, revision: 1, changeSet: stale))
            #expect(reply == .needsFullText(currentRevision: 0))
        }
        _ = controller.handle(.error(message: "host needs full text", stack: nil))
        #expect(page.loadNotes.count == 2)
        #expect(page.loadNotes.last == .loadNote(noteId: noteId, text: "hello", revision: 0, readOnly: false))

        // Once the reload was handled, a new failure triggers a new reload.
        page.completeDeliveries()
        _ = controller.handle(.changes(noteId: noteId, txId: "s9", baseRevision: 0, revision: 1, changeSet: stale))
        #expect(page.loadNotes.count == 3)
    }

    @Test func needsFullTextWhileHostIsBehindLeavesRetryToEditor() throws {
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: 1))
        let reply = controller.handle(insert("!", at: 5, length: 5, txId: "t2", base: 3))
        #expect(reply == .needsFullText(currentRevision: 0))
        #expect(page.loadNotes.count == 1)
    }

    @Test func editorErrorSendsLoadNote() throws {
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: 1))
        #expect(controller.handle(insert("!", at: 5, length: 5, txId: "t1", base: 0)) == .acked(revision: 1))
        _ = controller.handle(.error(message: "boom", stack: "Error: boom"))
        #expect(page.loadNotes.last == .loadNote(noteId: noteId, text: "hello!", revision: 1, readOnly: false))
        #expect(page.loadNotes.count == 2)
    }

    @Test func repeatedErrorsStopReloadingAfterLimit() throws {
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: 1))
        for _ in 0..<(EditorBridgeController.maxReloadsWithoutAck + 3) {
            _ = controller.handle(.error(message: "boom", stack: nil))
        }
        #expect(page.loadNotes.count == 1 + EditorBridgeController.maxReloadsWithoutAck)
    }

    @Test func externalChangeIsForwardedWithSessionRevision() throws {
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: 1))
        let note = try #require(try environment.store.note(id: noteId))
        _ = try environment.store.updateText(id: noteId, text: "hello there", expectedRevision: note.revision)
        environment.databaseDidChange()
        let session = try environment.session(for: noteId)
        #expect(session.revision == 1)
        guard case let .applyExternalChange(id, revision, changeSet)? = page.delivered.last else {
            Issue.record("no applyExternalChange sent: \(page.delivered)")
            return
        }
        #expect(id == noteId && revision == 1)
        #expect(try changeSet.apply(to: "hello") == "hello there")
    }

    @Test func openFlushesPreviousSessionAndRoutesLateChanges() throws {
        let otherId = try environment.store.create(text: "other").id
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: 1))
        #expect(controller.handle(insert("!", at: 5, length: 5, txId: "t1", base: 0)) == .acked(revision: 1))

        try controller.open(noteId: otherId)
        #expect(try environment.store.note(id: noteId)?.text == "hello!")
        #expect(page.loadNotes.last == .loadNote(noteId: otherId, text: "other", revision: 0, readOnly: false))

        // A transaction for the previous note that was in flight during the switch is not lost.
        #expect(controller.handle(insert("?", at: 6, length: 6, txId: "t2", base: 1)) == .acked(revision: 2))
        #expect(try environment.session(for: noteId).text == "hello!?")
    }

    @Test func checksumRoundTripCompletesOnceAndTerminationCancels() throws {
        try controller.open(noteId: noteId)
        var results: [(String?, String?)] = []
        controller.requestChecksum { results.append(($0, $1)) }
        #expect(results.count == 1 && results[0].1 == nil) // editor not ready

        _ = controller.handle(.ready(version: 1))
        controller.requestChecksum { results.append(($0, $1)) }
        guard case .requestChecksum(let requestId)? = page.delivered.last else {
            Issue.record("no requestChecksum sent: \(page.delivered)")
            return
        }
        let sha = String(repeating: "a", count: 64)
        _ = controller.handle(.checksum(requestId: requestId, noteId: noteId, sha256: sha))
        _ = controller.handle(.checksum(requestId: requestId, noteId: noteId, sha256: sha))
        #expect(results.count == 2 && results[1].0 == noteId && results[1].1 == sha)

        controller.requestChecksum { results.append(($0, $1)) }
        controller.simulateWebContentTermination()
        #expect(results.count == 3 && results[2].1 == nil)
    }

    @Test func rawBodyRepliesWithJSON() throws {
        try controller.open(noteId: noteId)
        _ = controller.handle(body: ["type": "ready", "version": 1])
        let body: [String: Any] = [
            "type": "changes", "noteId": noteId, "txId": "t1", "baseRevision": 0, "revision": 1,
            "changeSet": [5, [0, "!"]],
        ]
        let (reply, error) = controller.handle(body: body)
        #expect(error == nil)
        #expect((reply as? NSDictionary) == ["status": "acked", "revision": 1])
        let (bad, badError) = controller.handle(body: ["type": "nope"])
        #expect(bad == nil && badError != nil)
    }

    // MARK: - Delivery guard (I2)

    private func writeExternally(_ text: String) throws {
        let note = try #require(try environment.store.note(id: noteId))
        _ = try environment.store.updateText(id: noteId, text: text, expectedRevision: note.revision)
        environment.databaseDidChange()
    }

    @Test func changesDuringExternalChangeDeliveryAreRejected() throws {
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: 1))
        page.autoComplete = false
        try writeExternally("hello there")
        let session = try environment.session(for: noteId)
        #expect(session.revision == 1)
        guard case .applyExternalChange? = page.delivered.last else {
            Issue.record("no applyExternalChange sent: \(page.delivered)")
            return
        }

        // The editor's own edit r0 -> r1 collides with the adopted external change r0 -> r1: its
        // next edit (base 1) names the editor's document, not the host's.
        let collided = controller.handle(insert("!", at: 5, length: 11, txId: "collided", base: 1))
        #expect(collided == .needsFullText(currentRevision: 1))
        #expect(session.text == "hello there")
        #expect(session.revision == 1)
        #expect(page.loadNotes.last == .loadNote(noteId: noteId, text: "hello there", revision: 1, readOnly: false))
        #expect(page.loadNotes.count == 2) // one reload, queued behind the external change

        page.completeDeliveries()
        #expect(controller.handle(insert("!", at: 11, length: 11, txId: "fresh", base: 1)) == .acked(revision: 2))
        #expect(session.text == "hello there!")
    }

    @Test func overlappingLoadNotesKeepGuardUntilLastCompletes() throws {
        let otherId = try environment.store.create(text: "other").id
        page.autoComplete = false
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: 1)) // loadNote(note) pending
        try controller.open(noteId: otherId)       // loadNote(other) pending
        try controller.open(noteId: noteId)        // second loadNote(note) pending
        #expect(page.loadNotes.count == 3)

        page.completeNextDelivery() // the first loadNote(note) only
        #expect(controller.handle(insert("!", at: 5, length: 5, txId: "early", base: 0)) == .needsFullText(currentRevision: 0))
        page.completeNextDelivery()
        #expect(controller.handle(insert("!", at: 5, length: 5, txId: "early2", base: 0)) == .needsFullText(currentRevision: 0))
        #expect(try environment.session(for: noteId).text == "hello")

        page.completeNextDelivery() // the last loadNote(note)
        #expect(controller.handle(insert("!", at: 5, length: 5, txId: "late", base: 0)) == .acked(revision: 1))
    }

    // MARK: - Three-pane UI hooks

    @Test func openWithCaretPlacesTheSelection() throws {
        _ = controller.handle(.ready(version: 1))
        try controller.open(noteId: noteId, caret: 3)
        #expect(page.loadNotes.last == .loadNote(
            noteId: noteId, text: "hello", revision: 0, readOnly: false, selection: SelectionRange(anchor: 3, head: 3)
        ))
    }

    @Test func trashedAndArchivedNotesOpenReadOnly() throws {
        let archived = try environment.store.create(text: "old").id
        try environment.store.trash([noteId])
        try environment.store.archive([archived])
        _ = controller.handle(.ready(version: 1))
        try controller.open(noteId: noteId)
        #expect(page.loadNotes.last == .loadNote(noteId: noteId, text: "hello", revision: 0, readOnly: true))
        try controller.open(noteId: archived)
        #expect(page.loadNotes.last == .loadNote(noteId: archived, text: "old", revision: 0, readOnly: true))
    }

    @Test func focusEditorIsDeliveredOnceTheEditorIsReady() throws {
        try controller.open(noteId: noteId)
        controller.focusEditor()
        #expect(!page.delivered.contains(.focus))
        _ = controller.handle(.ready(version: 1))
        #expect(page.delivered.suffix(2) == [
            .loadNote(noteId: noteId, text: "hello", revision: 0, readOnly: false), .focus,
        ])
        controller.focusEditor()
        #expect(page.delivered.last == .focus)
        #expect(page.delivered.filter { $0 == .focus }.count == 2)
    }

    // MARK: - Caret restore (F1)

    @Test func reloadLoadNoteCarriesLastSelection() throws {
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: 1))
        _ = controller.handle(.selectionChanged(noteId: noteId, anchor: 2, head: 4))
        _ = controller.handle(.error(message: "boom", stack: nil))
        let expected = HostToEditorMessage.loadNote(
            noteId: noteId, text: "hello", revision: 0, readOnly: false, selection: SelectionRange(anchor: 2, head: 4)
        )
        #expect(page.loadNotes.last == expected)

        _ = controller.handle(.selectionChanged(noteId: noteId, anchor: 5, head: 5))
        controller.simulateWebContentTermination()
        _ = controller.handle(.ready(version: 1))
        #expect(page.loadNotes.last == .loadNote(
            noteId: noteId, text: "hello", revision: 0, readOnly: false, selection: SelectionRange(anchor: 5, head: 5)
        ))
    }

    // MARK: - Periodic checksum (I1 safety net)

    @Test func periodicChecksumMismatchReloads() throws {
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: 1))
        controller.checksumTick()
        #expect(page.checksumRequestIds.isEmpty) // no activity yet

        #expect(controller.handle(insert("!", at: 5, length: 5, txId: "t1", base: 0)) == .acked(revision: 1))
        controller.checksumTick()
        let first = try #require(page.checksumRequestIds.last)
        _ = controller.handle(.checksum(requestId: first, noteId: noteId, sha256: sha256Hex("hello!")))
        #expect(page.loadNotes.count == 1) // equal: nothing to do

        controller.checksumTick()
        #expect(page.checksumRequestIds.count == 1) // no activity since the last check

        #expect(controller.handle(insert("?", at: 6, length: 6, txId: "t2", base: 1)) == .acked(revision: 2))
        controller.checksumTick()
        let second = try #require(page.checksumRequestIds.last)
        _ = controller.handle(.checksum(requestId: second, noteId: noteId, sha256: sha256Hex("hello")))
        #expect(page.loadNotes.count == 2)
        #expect(page.loadNotes.last == .loadNote(noteId: noteId, text: "hello!?", revision: 2, readOnly: false))
    }

    @Test func checksumReplyIsIgnoredWhenRevisionMovedOn() throws {
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: 1))
        #expect(controller.handle(insert("!", at: 5, length: 5, txId: "t1", base: 0)) == .acked(revision: 1))
        controller.checksumTick()
        let requestId = try #require(page.checksumRequestIds.last)
        // Typed after the editor hashed its document: the hash names revision 1, the host is at 2.
        #expect(controller.handle(insert("?", at: 6, length: 6, txId: "t2", base: 1)) == .acked(revision: 2))
        _ = controller.handle(.checksum(requestId: requestId, noteId: noteId, sha256: sha256Hex("hello!")))
        #expect(page.loadNotes.count == 1)
    }

    @Test func applyCommandIsDeliveredForAnEditableShownNoteOnly() throws {
        controller.apply(.bold) // nothing shown, editor not ready
        try controller.open(noteId: noteId)
        controller.apply(.bold) // not ready yet
        #expect(!controller.status.isEditable)
        _ = controller.handle(.ready(version: EditorBridge.version))
        #expect(controller.status.isEditable)
        controller.apply(.heading, args: ["level": .int(2)])
        let commands = page.delivered.filter { if case .applyCommand = $0 { true } else { false } }
        #expect(commands == [.applyCommand(name: .heading, args: ["level": .int(2)])])

        controller.showNoNote()
        #expect(!controller.status.isEditable)
        controller.apply(.bold)
        #expect(page.delivered.filter { if case .applyCommand = $0 { true } else { false } }.count == 1)
    }

    @Test func copyTextPutsPlainTextOnThePasteboard() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TheoNotesTest-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("old", forType: .string)
        controller.pasteboard = pasteboard
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: EditorBridge.version))
        #expect(controller.handle(.copyText(text: "let a = 1\n\tb 👋", html: nil)) == nil)
        #expect(pasteboard.string(forType: .string) == "let a = 1\n\tb 👋")
        // Plain text only: no rich flavors a paste target would prefer.
        let types = pasteboard.types ?? []
        #expect(types.contains(.string))
        #expect(!types.contains(.rtf) && !types.contains(.html) && !types.contains(.rtfd))
        // The raw postMessage body (what the page sends).
        let (reply, error) = controller.handle(body: ["type": "copyText", "text": "x"])
        #expect(reply == nil && error == nil)
        #expect(pasteboard.string(forType: .string) == "x")
    }

    /// M6 Task 8: the stored folds go out with the note; no stored folds, no `foldState`.
    @Test func loadNoteCarriesTheStoredFoldState() throws {
        let folds = [FoldEntry(line: 1, hash: "0a1b2c3d")!, FoldEntry(line: 3, hash: "ffffffff")!]
        let revision = try environment.store.note(id: noteId)?.revision
        try environment.store.setFoldState(noteId: noteId, folds)
        let other = try environment.store.create(text: "other").id
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: EditorBridge.version))
        #expect(page.loadNotes.last == .loadNote(noteId: noteId, text: "hello", revision: 0, readOnly: false, foldState: folds))
        try controller.open(noteId: other)
        #expect(page.loadNotes.last == .loadNote(noteId: other, text: "other", revision: 0, readOnly: false))
        // Folding is not an edit: the note keeps its revision.
        #expect(try environment.store.note(id: noteId)?.revision == revision)
    }

    @Test func aFoldStateMessageForAnotherNoteIsIgnored() throws {
        let other = try environment.store.create(text: "# other\nbody").id
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: EditorBridge.version))
        let fold = [FoldEntry(line: 1, hash: "0a1b2c3d")!]
        #expect(controller.handle(.foldState(noteId: other, folds: fold)) == nil)
        #expect(try environment.store.foldState(noteId: other).isEmpty)
        _ = controller.handle(.foldState(noteId: noteId, folds: fold))
        #expect(try environment.store.foldState(noteId: noteId) == fold)
    }

    /// v3 menu messages are logging stubs until their tasks land, and a fold message is stored
    /// (M6 Task 8): accepted, no reply, nothing sent back to the page.
    @Test func v3MenuAndFoldMessagesAreAcceptedWithoutEffect() throws {
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: EditorBridge.version))
        let before = page.delivered.count
        let rect = CaretRect(x: 1, y: 2, width: 3, height: 4)
        #expect(controller.handle(.headingMenu(HeadingMenuRequest(
            noteId: noteId, menuId: "m", line: 1, level: 2, folded: false, rect: rect))) == nil)
        #expect(controller.handle(.tableMenu(TableMenuRequest(
            noteId: noteId, menuId: "m", row: 0, column: 0, rows: 2, columns: 2, rect: rect))) == nil)
        #expect(controller.handle(.calloutMenu(CalloutMenuRequest(
            noteId: noteId, menuId: "m", calloutType: .tip, rect: rect))) == nil)
        #expect(controller.handle(.foldState(noteId: noteId, folds: [FoldEntry(line: 1, hash: "0a1b2c3d")!])) == nil)
        #expect(page.delivered.count == before)
        // The raw postMessage bodies the page sends.
        let body: [String: Any] = [
            "type": "tableMenu", "noteId": noteId, "menuId": "m", "row": 0, "column": 1, "rows": 2, "columns": 2,
            "rect": ["x": 0, "y": 0, "width": 1, "height": 1],
        ]
        let (reply, error) = controller.handle(body: body)
        #expect(reply == nil && error == nil)
    }

    @Test func selectRangeIsDeliveredForTheShownNote() throws {
        controller.selectRange(anchor: 1, head: 3) // no note shown: ignored for good
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: EditorBridge.version))
        #expect(!page.delivered.contains { if case .selectRange = $0 { true } else { false } })
        controller.selectRange(anchor: 1, head: 3)
        #expect(page.delivered.last == .selectRange(noteId: noteId, anchor: 1, head: 3))
    }

    /// Like a heading scroll: asked for before the page is ready, it goes out right after the
    /// note's loadNote (the latest request wins), and a note switch drops it.
    @Test func selectRangeWaitsForTheEditorAndFollowsTheLoadNote() throws {
        try controller.open(noteId: noteId)
        controller.selectRange(anchor: 1, head: 3)
        controller.selectRange(anchor: 2, head: 4)
        #expect(page.delivered.isEmpty) // editor not ready yet
        _ = controller.handle(.ready(version: EditorBridge.version))
        let kinds = page.delivered.map { message -> String in
            switch message {
            case .loadNote: "loadNote"
            case .selectRange: "selectRange"
            default: "other"
            }
        }
        #expect(kinds.filter { $0 != "other" } == ["loadNote", "selectRange"], "\(kinds)")
        #expect(page.delivered.last == .selectRange(noteId: noteId, anchor: 2, head: 4))
        // Delivered once: a reload does not select again.
        _ = controller.handle(.ready(version: EditorBridge.version))
        #expect(page.delivered.filter { if case .selectRange = $0 { true } else { false } }.count == 1)
    }

    @Test func aPendingSelectRangeIsDroppedWhenTheNoteIsClosedAndOpenedAgain() throws {
        try controller.open(noteId: noteId)
        controller.selectRange(anchor: 1, head: 3)
        controller.showNoNote()
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: EditorBridge.version))
        #expect(!page.delivered.contains { if case .selectRange = $0 { true } else { false } })
    }

    @Test func selectRangeAlsoWorksInReadOnlyNotes() throws {
        try environment.store.trash([noteId])
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: EditorBridge.version))
        #expect(!controller.status.isEditable)
        controller.selectRange(anchor: 0, head: 5)
        #expect(page.delivered.last == .selectRange(noteId: noteId, anchor: 0, head: 5))
    }

    @Test func formatStateIsKeptForTheShownNoteOnly() throws {
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: EditorBridge.version))
        #expect(controller.status.formatState == nil)
        let bold = FormatState(active: [.bold], headingLevel: nil, inTodo: false, inCode: false, canIndent: false)
        _ = controller.handle(.formatState(noteId: "other", state: bold))
        #expect(controller.status.formatState == nil)
        _ = controller.handle(.formatState(noteId: noteId, state: bold))
        #expect(controller.status.formatState == bold)

        // Another note: the old state is gone until the editor reports the new one.
        let other = try environment.store.create(text: "other").id
        try controller.open(noteId: other)
        #expect(controller.status.formatState == nil)
    }

    @Test func checksumTimerRequestsWhileActive() async throws {
        let timed = EditorBridgeController(
            environment: environment, page: page, openExternally: { _ in }, checksumInterval: .milliseconds(20)
        )
        try timed.open(noteId: noteId)
        _ = timed.handle(.ready(version: 1))
        #expect(timed.handle(insert("!", at: 5, length: 5, txId: "t1", base: 0)) == .acked(revision: 1))
        try await waitUntil("periodic requestChecksum", timeout: .seconds(5)) { !page.checksumRequestIds.isEmpty }
    }

    // MARK: - Attachments (M3 Task 9)

    private var commands: [HostToEditorMessage] {
        page.delivered.filter { if case .applyCommand = $0 { true } else { false } }
    }

    private func attachmentFile(_ name: String, of note: String? = nil) -> URL {
        root.appendingPathComponent("Attachments/\(note ?? noteId)/\(name)")
    }

    @Test func droppedFilesAreStoredAndTheirMarkdownInsertedAtTheDropPoint() async throws {
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: EditorBridge.version))
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        _ = controller.handle(.insertAttachments(noteId: noteId, insertId: "d1", items: [
            AttachmentUpload(filename: "image.png", dataBase64: png.base64EncodedString()),
            AttachmentUpload(filename: "notes.txt", dataBase64: "not base64!"),
            AttachmentUpload(filename: "Report.pdf", dataBase64: Data([1]).base64EncodedString()),
        ]))
        await controller.attachments.pendingWork?.value
        #expect(try Data(contentsOf: attachmentFile("image.png")) == png)
        #expect(!FileManager.default.fileExists(atPath: attachmentFile("notes.txt").path))
        #expect(commands == [.applyCommand(name: .insertText, args: [
            "text": .string(#"![](image.png)"# + "\n" + #"[Report.pdf](Report.pdf)<!-- {"preview":"true","embed":"true"} -->"#),
            "insertId": .string("d1"),
        ])])

        // The same name again gets Bear's collision name.
        _ = controller.handle(.insertAttachments(noteId: noteId, insertId: "d2", items: [
            AttachmentUpload(filename: "image.png", dataBase64: png.base64EncodedString()),
        ]))
        await controller.attachments.pendingWork?.value
        #expect(commands.last == .applyCommand(name: .insertText, args: ["text": .string("![](image%202.png)"), "insertId": .string("d2")]))
        #expect(FileManager.default.fileExists(atPath: attachmentFile("image 2.png").path))
    }

    /// A link copied in note A and pasted into B: the file is copied into B (Bear behavior), the
    /// link renamed when B has that name already. Within the same note the text goes in as is.
    @Test func pastedLinksFromAnotherNoteCopyTheirFiles() async throws {
        let store = AttachmentStore(paths: environment.paths, database: environment.database)
        let source = try environment.store.create(text: "![](p.png)").id
        _ = try store.add(data: Data([1]), filename: "p.png", to: source)
        _ = try store.add(data: Data([2]), filename: "p.png", to: noteId)
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: EditorBridge.version))

        _ = controller.handle(.pasteAttachments(noteId: noteId, insertId: "p1", sourceNoteId: source, text: "x ![](p.png)",
                                                items: [PastedAttachment(from: 2, to: 12, filename: "p.png")]))
        await controller.attachments.pendingWork?.value
        #expect(commands.last == .applyCommand(name: .insertText, args: ["text": .string("x ![](p%202.png)"), "insertId": .string("p1")]))
        #expect(try Data(contentsOf: attachmentFile("p 2.png")) == Data([1]))

        _ = controller.handle(.pasteAttachments(noteId: noteId, insertId: "p2", sourceNoteId: noteId, text: "![](p.png)",
                                                items: [PastedAttachment(from: 0, to: 10, filename: "p.png")]))
        await controller.attachments.pendingWork?.value
        #expect(commands.last == .applyCommand(name: .insertText, args: ["text": .string("![](p.png)"), "insertId": .string("p2")]))
        #expect(!FileManager.default.fileExists(atPath: attachmentFile("p 3.png").path))
    }

    /// Ruling R30: cut in A, select B (A's session is evicted and cleaned), paste in B. The file is
    /// copied into B, and A keeps it until the pasteboard changes.
    @Test func aCutLinkKeepsItsFileForThePasteInAnotherNote() async throws {
        let store = AttachmentStore(paths: environment.paths, database: environment.database)
        let a = try environment.store.create(text: "![](p.png)").id
        let b = try environment.store.create(text: "").id
        _ = try store.add(data: Data([5]), filename: "p.png", to: a)
        let aged = Date().addingTimeInterval(-NoteStore.attachmentGracePeriod - 60)
        try FileManager.default.setAttributes([.modificationDate: aged], ofItemAtPath: attachmentFile("p.png", of: a).path)
        let token = Mutex(41)
        environment.store.retention.setPasteboardToken { token.withLock { $0 } }
        controller.attachments.settleHeldFiles = { $0() }
        try controller.open(noteId: a)
        _ = controller.handle(.ready(version: EditorBridge.version))

        // The cut: the page reports the links, then removes them.
        _ = controller.handle(.cutAttachments(noteId: a, filenames: ["p.png"]))
        let touched = try #require(try FileManager.default.attributesOfItem(atPath: attachmentFile("p.png", of: a).path)[.modificationDate] as? Date)
        #expect(touched > Date().addingTimeInterval(-60))
        let session = try environment.session(for: a)
        _ = session.apply(txId: "cut", baseRevision: 0, changeSet: ChangeSet(sections: [.replace(deleteLength: 10, insert: "")]), origin: nil)
        try session.flush()
        // Long after the grace period, B is selected: A is evicted and cleaned.
        try FileManager.default.setAttributes([.modificationDate: aged], ofItemAtPath: attachmentFile("p.png", of: a).path)
        try controller.open(noteId: b)
        environment.setOpenNoteIds([b], for: ObjectIdentifier(controller))
        #expect(environment.existingSession(for: a) == nil)
        #expect(FileManager.default.fileExists(atPath: attachmentFile("p.png", of: a).path))

        _ = controller.handle(.pasteAttachments(noteId: b, insertId: "p", sourceNoteId: a, text: "![](p.png)",
                                                items: [PastedAttachment(from: 0, to: 10, filename: "p.png")]))
        await controller.attachments.pendingWork?.value
        #expect(try Data(contentsOf: attachmentFile("p.png", of: b)) == Data([5]))
        #expect(commands.last == .applyCommand(name: .insertText, args: ["text": .string("![](p.png)"), "insertId": .string("p")]))

        // Something else is copied: A's file goes with the next cleanup.
        token.withLock { $0 = 42 }
        #expect(await environment.sweepAttachments().value == 1)
        #expect(!FileManager.default.fileExists(atPath: attachmentFile("p.png", of: a).path))
    }

    @Test func pastesFromLockedOrMissingNotesCopyNothingAndSameNotePastesQueue() async throws {
        let store = AttachmentStore(paths: environment.paths, database: environment.database)
        let locked = try environment.store.create(text: "![](s.png)").id
        _ = try store.add(data: Data([1]), filename: "s.png", to: locked)
        try await environment.database.pool.write { try $0.execute(sql: "UPDATE note SET isLocked = 1 WHERE id = ?", arguments: [locked]) }
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: EditorBridge.version))
        let item = [PastedAttachment(from: 0, to: 10, filename: "s.png")]
        for source in [locked, "0192f3a4-5b6c-7d8e-9f01-999999999999"] {
            _ = controller.handle(.pasteAttachments(noteId: noteId, insertId: "x", sourceNoteId: source, text: "![](s.png)", items: item))
            await controller.attachments.pendingWork?.value
            #expect(commands.last == .applyCommand(name: .insertText, args: ["text": .string(""), "insertId": .string("x")]))
        }
        #expect(!FileManager.default.fileExists(atPath: attachmentFile("s.png").path))

        // An insert still being stored, then a paste within the note: in that order.
        _ = controller.handle(.insertAttachments(noteId: noteId, insertId: "first", items: [
            AttachmentUpload(filename: "f.png", dataBase64: Data(repeating: 1, count: 4_000_000).base64EncodedString()),
        ]))
        _ = controller.handle(.pasteAttachments(noteId: noteId, insertId: "second", sourceNoteId: noteId, text: "![](f.png)",
                                                items: [PastedAttachment(from: 0, to: 10, filename: "f.png")]))
        await controller.attachments.pendingWork?.value
        let ids = commands.suffix(2).compactMap { message -> String? in
            if case .applyCommand(_, let args) = message, case .string(let id)? = args?["insertId"] { return id }
            return nil
        }
        #expect(ids == ["first", "second"])

        // Every item failed: the pending insert is dropped.
        _ = controller.handle(.insertAttachments(noteId: noteId, insertId: "bad", items: [AttachmentUpload(filename: "a", dataBase64: "@@")]))
        await controller.attachments.pendingWork?.value
        #expect(commands.last == .applyCommand(name: .insertText, args: ["text": .string(""), "insertId": .string("bad")]))
    }

    @Test func oversizedDropsAreExplained() throws {
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: EditorBridge.version))
        var explained: [[String]] = []
        controller.attachments.tooLarge = { explained.append($0) }
        _ = controller.handle(.attachmentsRefused(noteId: noteId, filenames: ["Holiday.mov"]))
        _ = controller.handle(.attachmentsRefused(noteId: "other", filenames: ["x"]))
        #expect(explained == [["Holiday.mov"]])
    }

    @Test func attachmentsForAnotherOrReadOnlyNoteAreIgnored() async throws {
        let other = try environment.store.create(text: "other").id
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: EditorBridge.version))
        let item = AttachmentUpload(filename: "a.png", dataBase64: Data([1]).base64EncodedString())
        _ = controller.handle(.insertAttachments(noteId: other, insertId: "i", items: [item]))
        #expect(!FileManager.default.fileExists(atPath: attachmentFile("a.png", of: other).path))

        try environment.store.trash([noteId])
        let trashed = EditorBridgeController(environment: environment, page: page, openExternally: { _ in }, checksumInterval: nil)
        try trashed.open(noteId: noteId)
        _ = trashed.handle(.ready(version: EditorBridge.version))
        let before = commands.count
        _ = trashed.handle(.insertAttachments(noteId: noteId, insertId: "i", items: [item]))
        #expect(commands.count == before)
        #expect(!FileManager.default.fileExists(atPath: attachmentFile("a.png").path))
        // Links pasted from another note copy nothing into a read-only note either.
        _ = try AttachmentStore(paths: environment.paths, database: environment.database)
            .add(data: Data([3]), filename: "q.png", to: other)
        _ = trashed.handle(.pasteAttachments(noteId: noteId, insertId: "p", sourceNoteId: other, text: "![](q.png)",
                                             items: [PastedAttachment(from: 0, to: 10, filename: "q.png")]))
        await trashed.attachments.pendingWork?.value
        #expect(commands.count == before)
        #expect(!FileManager.default.fileExists(atPath: attachmentFile("q.png").path))
    }

    private func openWithAttachment(_ text: String, file: String) throws -> AttachmentController.Target {
        let id = try environment.store.create(text: text).id
        _ = try AttachmentStore(paths: environment.paths, database: environment.database).add(data: Data([7]), filename: file, to: id)
        try controller.open(noteId: id)
        _ = controller.handle(.ready(version: EditorBridge.version))
        let source = text.trimmingCharacters(in: .whitespaces)
        return .init(noteId: id, filename: file, from: 0, to: source.utf16.count, source: source)
    }

    @Test func spaceShowsQuickLookForTheAttachmentFile() throws {
        let target = try openWithAttachment("![](a%20b.png)", file: "a b.png")
        var previewed: [URL] = []
        controller.attachments.preview = { previewed.append($0) }
        _ = controller.handle(.quickLook(noteId: target.noteId, filename: "a b.png"))
        _ = controller.handle(.quickLook(noteId: target.noteId, filename: "../a b.png"))
        _ = controller.handle(.quickLook(noteId: "other", filename: "a b.png"))
        #expect(previewed.map(\.lastPathComponent) == ["a b.png"])
    }

    @Test func theContextMenuOpensRenamesSavesAndDeletes() throws {
        let pdf = #"[r.pdf](r.pdf)<!-- {"preview":"true","embed":"true"} -->"#
        let target = try openWithAttachment(pdf, file: "r.pdf")
        let attachments = controller.attachments
        var popped: [NSMenu] = []
        attachments.popUp = { popped.append($0) }
        _ = controller.handle(.attachmentMenu(noteId: target.noteId, filename: target.filename, from: target.from, to: target.to, source: target.source))
        let titles = try #require(popped.first).items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles.contains("Open") && titles.contains("Show in Finder") && titles.contains("Save As…"))
        #expect(titles.suffix(3) == ["Rename…", "Hide Preview", "Delete"])

        var opened: [URL] = [], revealed: [URL] = []
        attachments.open = { opened.append($0) }
        attachments.reveal = { revealed.append($0) }
        attachments.perform(.open, on: target)
        attachments.perform(.reveal, on: target)
        #expect(opened.map(\.lastPathComponent) == ["r.pdf"] && revealed == opened)

        let destination = root.appendingPathComponent("Saved.pdf")
        attachments.chooseDestination = { _ in destination }
        attachments.perform(.saveAs, on: target)
        #expect(try Data(contentsOf: destination) == Data([7]))

        attachments.askForName = { _ in "Final report.pdf" }
        attachments.perform(.rename, on: target)
        #expect(commands.last == .applyCommand(name: .replaceRange, args: [
            "from": .int(0), "to": .int(target.to), "expect": .string(pdf),
            "text": .string(#"[Final report.pdf](Final%20report.pdf)<!-- {"preview":"true","embed":"true"} -->"#),
        ]))
        // The old name stays until the cleanup (undo of the rewrite keeps working).
        #expect(FileManager.default.fileExists(atPath: attachmentFile("r.pdf", of: target.noteId).path))
        #expect(FileManager.default.fileExists(atPath: attachmentFile("Final report.pdf", of: target.noteId).path))

        attachments.perform(.setPreview(false), on: target)
        #expect(commands.last == .applyCommand(name: .replaceRange, args: [
            "from": .int(0), "to": .int(target.to), "expect": .string(pdf),
            "text": .string(#"[r.pdf](r.pdf)<!-- {"preview":"false","embed":"true"} -->"#),
        ]))
        attachments.perform(.delete, on: target)
        #expect(commands.last == .applyCommand(name: .replaceRange, args: [
            "from": .int(0), "to": .int(target.to), "expect": .string(pdf), "text": .string(""),
        ]))
        // Delete removes the link only; the file goes with the cleanup.
        #expect(FileManager.default.fileExists(atPath: attachmentFile("r.pdf", of: target.noteId).path))
    }

    /// Opening an attachment never runs code (attachments carry no download quarantine of
    /// their own): apps, scripts, installers, shortcuts and executables go to Finder instead.
    @Test func openRefusesFilesThatRunCode() throws {
        let target = try openWithAttachment("[run.command](run.command)<!-- {\"embed\":\"true\"} -->", file: "run.command")
        let attachments = controller.attachments
        var opened: [URL] = [], revealed: [URL] = [], refused: [String] = []
        attachments.open = { opened.append($0) }
        attachments.openWith = { file, _ in opened.append(file) }
        attachments.reveal = { revealed.append($0) }
        attachments.refuseOpening = { refused.append($0) }
        attachments.perform(.open, on: target)
        attachments.perform(.openWith(URL(fileURLWithPath: "/System/Applications/TextEdit.app")), on: target)
        #expect(opened.isEmpty)
        #expect(refused == ["run.command", "run.command"])
        #expect(revealed.map(\.lastPathComponent) == ["run.command", "run.command"])

        let dir = root.appendingPathComponent("open-guard")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func file(_ name: String, _ data: Data = Data([1]), executable: Bool = false) throws -> URL {
            let url = dir.appendingPathComponent(name)
            try data.write(to: url)
            if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
            return url
        }
        #expect(!AttachmentController.isSafeToOpen(try file("run.command")))
        #expect(!AttachmentController.isSafeToOpen(try file("notes", executable: true)))
        #expect(!AttachmentController.isSafeToOpen(try file("script.txt", Data("#!/bin/sh".utf8), executable: true)))
        #expect(!AttachmentController.isSafeToOpen(try file("x.webloc")))
        #expect(!AttachmentController.isSafeToOpen(try file("install.pkg")))
        let app = dir.appendingPathComponent("Tool.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        #expect(!AttachmentController.isSafeToOpen(dir.appendingPathComponent("Tool.app")))
        let link = dir.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: try file("target.png"))
        #expect(!AttachmentController.isSafeToOpen(link))

        for name in ["x.mobileconfig", "server.afploc", "s.ftploc", "screen.vncloc"] {
            #expect(!AttachmentController.isSafeToOpen(try file(name)), "\(name)")
        }
        // A Finder alias.
        let alias = dir.appendingPathComponent("Alias to target")
        try URL.writeBookmarkData(try dir.appendingPathComponent("target.png").bookmarkData(options: .suitableForBookmarkFile), to: alias)
        #expect(!AttachmentController.isSafeToOpen(alias))

        #expect(AttachmentController.isSafeToOpen(try file("photo.png")))
        #expect(AttachmentController.isSafeToOpen(try file("report.pdf", Data("%PDF-1.4".utf8))))
        // Web documents open only in Quick Look (a browser would run their scripts).
        #expect(AttachmentController.openDecision(for: try file("page.html")) == .quickLook)
        #expect(AttachmentController.openDecision(for: try file("a.webarchive")) == .quickLook)
        #expect(AttachmentController.openDecision(for: try file("i.svg")) == .quickLook)
        #expect(AttachmentController.openDecision(for: try file("photo2.png")) == .open)
        #expect(AttachmentController.openDecision(for: try file("run2.command")) == .reveal)

        // A PNG attachment opens normally.
        let image = try openWithAttachment("![](a.png)", file: "a.png")
        attachments.perform(.open, on: image)
        #expect(opened.map(\.lastPathComponent) == ["a.png"])
        #expect(refused.count == 2)
    }

    /// Ruling R25b: Open is an allowlist; the extension's type and the content type must both be
    /// on it, and the executable bit off.
    @Test func openIsAnAllowlistOfDocumentTypes() throws {
        let dir = root.appendingPathComponent("allowlist")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func file(_ name: String, _ text: String = "x", executable: Bool = false) throws -> URL {
            let url = dir.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
            return url
        }
        // One per allowed category.
        for name in ["a.png", "b.jpg", "c.pdf", "d.mp3", "e.m4a", "f.mov", "g.mp4", "h.txt", "i.md", "j.csv", "k.rtf",
                     "l.docx", "m.xlsx", "n.pptx", "o.doc", "p.xls", "q.epub", "r.zip", "s.numbers", "t.pages", "u.key"] {
            #expect(AttachmentController.openDecision(for: try file(name)) == .open, "\(name)")
        }
        // Markup and feeds: previewed, never opened in a browser.
        for name in ["a.xml", "b.xslt", "c.rss", "d.mhtml", "e.svg", "f.html", "g.atom", "h.webarchive"] {
            #expect(AttachmentController.openDecision(for: try file(name)) == .quickLook, "\(name)")
        }
        // A .txt holding HTML: contentType reports public.plain-text (it goes by the extension),
        // so both type checks pass; the content sniff refuses it.
        let disguised = try file("page.txt", "<!DOCTYPE html><html><script>alert(1)</script></html>")
        #expect(try disguised.resourceValues(forKeys: [.contentTypeKey]).contentType == .plainText)
        #expect(AttachmentController.openDecision(for: disguised) == .quickLook)
        // Sniff bypasses: a BOM, UTF-16, text or a comment before the tag, an event handler, Markdown.
        let bypasses: [(String, Data)] = [
            ("bom.txt", Data([0xEF, 0xBB, 0xBF]) + Data("<html><script>x()</script>".utf8)),
            ("utf16.txt", "<html><script>x()</script>".data(using: .utf16)!),
            ("text.txt", Data("hello there\n<script>x()</script>".utf8)),
            ("comment.txt", Data("<!-- note --><html>".utf8)),
            ("img.txt", Data("look <img src=x onerror=alert(1)>".utf8)),
            ("notes.md", Data("# Notes\n<img src=x onerror=alert(1)>".utf8)),
            ("page.markdown", Data("Intro <a href=\"javascript:x()\">here</a>".utf8)),
        ]
        for (name, data) in bypasses {
            let url = dir.appendingPathComponent(name)
            try data.write(to: url)
            #expect(AttachmentController.openDecision(for: url) == .quickLook, "\(name)")
        }
        // Markdown with Bear's metadata comment and no tags still opens.
        #expect(AttachmentController.openDecision(for: try file("plain.md", "# T\n[a](a.pdf)<!-- {\"embed\":\"true\"} --> a < b")) == .open)
        // Prose with `<`, autolinks and empty files are not markup; any real tag is.
        #expect(AttachmentController.openDecision(for: try file("prose.txt", "x < a and n < base case <https://b.c> <a@b.c>")) == .open)
        #expect(AttachmentController.openDecision(for: try file("empty.md", "")) == .open)
        for (name, text) in [("div.md", "hi <div onmouseover=x>"), ("p.txt", "</p>"), ("br.md", "a<br/>b")] {
            #expect(AttachmentController.openDecision(for: try file(name, text)) == .quickLook, "\(name)")
        }

        // Executable bit, unknown types, installers: Finder only.
        #expect(AttachmentController.openDecision(for: try file("x.png", executable: true)) == .reveal)
        for name in ["y.bin", "z.dmg", "w.pkg", "v.json", "u.js", "t.sh"] {
            #expect(AttachmentController.openDecision(for: try file(name)) != .open, "\(name)")
        }
    }

    @Test func aCommandClickedAttachmentLinkGoesThroughTheGuard() throws {
        let target = try openWithAttachment("[run.command](run.command)<!-- {\"embed\":\"true\"} -->", file: "run.command")
        var opened: [URL] = [], revealed: [URL] = []
        controller.attachments.open = { opened.append($0) }
        controller.attachments.reveal = { revealed.append($0) }
        controller.attachments.refuseOpening = { _ in }
        let router = LinkRouter(environment: environment, editor: controller)
        router.open(OpenLinkRequest(noteId: target.noteId, kind: .attachment, target: "run.command", heading: nil, newWindow: false))
        #expect(opened.isEmpty)
        #expect(revealed.map(\.lastPathComponent) == ["run.command"])
        _ = try AttachmentStore(paths: environment.paths, database: environment.database).add(data: Data([1]), filename: "p 2.png", to: target.noteId)
        router.open(OpenLinkRequest(noteId: target.noteId, kind: .attachment, target: "p%202.png", heading: nil, newWindow: false))
        #expect(opened.map(\.lastPathComponent) == ["p 2.png"])
    }

    @Test func aReadOnlyNoteOffersNoAttachmentEdits() throws {
        let target = try openWithAttachment("![](a.png)", file: "a.png")
        try environment.store.trash([target.noteId])
        let viewer = EditorBridgeController(environment: environment, page: page, openExternally: { _ in }, checksumInterval: nil)
        try viewer.open(noteId: target.noteId)
        _ = viewer.handle(.ready(version: EditorBridge.version))
        #expect(viewer.attachments.menuItems(for: target).map(\.title).filter { $0 != "Open With" } == ["Open", "Show in Finder", "Save As…"])
        let before = commands.count
        viewer.attachments.askForName = { _ in "b.png" }
        viewer.attachments.perform(.rename, on: target)
        viewer.attachments.perform(.delete, on: target)
        #expect(commands.count == before)
    }
}

@MainActor
@Suite struct AssetSchemeHandlerTests {
    @Test func servesBundleFilesWithHeadersAnd404s() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Assets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try Data("<html></html>".utf8).write(to: root.appendingPathComponent("index.html"))
        try Data("export {}".utf8).write(to: root.appendingPathComponent("assets/main.js"))
        try Data("secret".utf8).write(to: root.deletingLastPathComponent().appendingPathComponent("outside-\(root.lastPathComponent).txt"))
        let handler = AssetSchemeHandler(root: root)

        let index = handler.response(for: URL(string: "baerchen-asset://editor/index.html")!)
        #expect(index.statusCode == 200)
        #expect(index.headers["Content-Type"] == "text/html; charset=utf-8")
        #expect(index.headers["Content-Security-Policy"] == AssetSchemeHandler.contentSecurityPolicy)
        let js = handler.response(for: URL(string: "baerchen-asset://editor/assets/main.js")!)
        #expect(js.statusCode == 200 && js.headers["Content-Type"] == "text/javascript; charset=utf-8")
        #expect(js.headers["Access-Control-Allow-Origin"] != nil)

        for bad in [
            "baerchen-asset://editor/missing.js",
            "baerchen-asset://editor/assets",
            "baerchen-asset://other/index.html",
            "baerchen-asset://editor/../outside-\(root.lastPathComponent).txt",
            "baerchen-asset://editor/%2E%2E/outside-\(root.lastPathComponent).txt",
            "https://editor/index.html",
        ] {
            #expect(handler.response(for: URL(string: bad)!).statusCode == 404, "\(bad)")
        }
    }

    /// `baerchen-asset://attachment/<noteId>/<name>`: the file's bytes with its MIME type, size
    /// and date; HEAD without a body; traversal, other notes' files and symlinks out are 404s.
    @Test func servesAttachmentsOfTheNoteOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Attachments-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        try paths.createDirectories()
        let database = try AppDatabase(path: paths.database)
        let store = AttachmentStore(paths: paths, database: database)
        let notes = NoteStore(db: database, notifier: nil, paths: paths)
        let note = try notes.create(text: "Attachments").id
        let other = try notes.create(text: "Other attachments").id
        _ = try store.add(data: Data([1, 2, 3]), filename: "photo 2.png", to: note)
        _ = try store.add(data: Data("%PDF".utf8), filename: "r.pdf", to: note)
        _ = try store.add(data: Data("<script>alert(1)</script>".utf8), filename: "page.html", to: note)
        _ = try store.add(data: Data([9]), filename: "unknown.zzqx", to: note)
        _ = try store.add(data: Data("secret".utf8), filename: "secret.png", to: other)
        let dir = paths.attachments.appendingPathComponent(note)
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("link.png").path, withDestinationPath: "../\(other)/secret.png")
        let handler = AssetSchemeHandler(root: root, attachments: store)

        let png = handler.response(for: URL(string: "baerchen-asset://attachment/\(note)/photo%202.png")!)
        #expect(png.statusCode == 200 && png.body == Data([1, 2, 3]))
        #expect(png.headers["Content-Type"] == "image/png")
        #expect(png.headers["Content-Length"] == "3")
        #expect(png.headers["Last-Modified"]?.hasSuffix(" GMT") == true)
        #expect(png.headers["X-Content-Type-Options"] == "nosniff")
        #expect(png.headers["Content-Security-Policy"] == AssetSchemeHandler.attachmentSecurityPolicy)
        let head = handler.response(for: URL(string: "baerchen-asset://attachment/\(note)/photo%202.png")!, method: "HEAD")
        #expect(head.statusCode == 200 && head.body.isEmpty && head.headers["Content-Length"] == "3")
        #expect(handler.response(for: URL(string: "baerchen-asset://attachment/\(note)/r.pdf")!).headers["Content-Type"] == "application/pdf")
        // Markup and script are served as inert text.
        #expect(handler.response(for: URL(string: "baerchen-asset://attachment/\(note)/page.html")!).headers["Content-Type"]
            == "text/plain; charset=utf-8")
        #expect(handler.response(for: URL(string: "baerchen-asset://attachment/\(note)/unknown.zzqx")!).headers["Content-Type"]
            == "application/octet-stream")

        for bad in [
            "baerchen-asset://attachment/\(note)/missing.png",
            "baerchen-asset://attachment/\(note)/../\(other)/secret.png",
            "baerchen-asset://attachment/\(note)/%2E%2E/\(other)/secret.png",
            "baerchen-asset://attachment/\(note)/%2E%2E%2F\(other)%2Fsecret.png",
            "baerchen-asset://attachment/%2E%2E/\(other)/secret.png",
            "baerchen-asset://attachment/../\(other)/secret.png",
            "baerchen-asset://attachment/\(note)/link.png",
            "baerchen-asset://attachment//etc/hosts",
            "baerchen-asset://attachment/%2Fetc/hosts",
            "baerchen-asset://attachment/\(note)/%2Fetc%2Fhosts",
            "baerchen-asset://attachment/\(note)",
            "baerchen-asset://attachment/\(note)/",
            "baerchen-asset://attachment/.staging/x",
            "baerchen-asset://attachment/\(note)/photo%202.png/x",
        ] {
            #expect(handler.response(for: URL(string: bad)!).statusCode == 404, "\(bad)")
        }
    }

    /// SVG is shown only through `<img>` (no script runs there): served as an image, still under the
    /// sandbox CSP and `nosniff`, so a page that loaded it directly would be inert too. Other markup stays text.
    @Test func svgAttachmentIsServedAsImageUnderTheSandboxCSP() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Svg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        try paths.createDirectories()
        let database = try AppDatabase(path: paths.database)
        let store = AttachmentStore(paths: paths, database: database)
        let notes = NoteStore(db: database, notifier: nil, paths: paths)
        let note = try notes.create(text: "Attachments").id
        let svg = Data("<svg xmlns='http://www.w3.org/2000/svg' onload='x()'><script>x()</script></svg>".utf8)
        _ = try store.add(data: svg, filename: "Vector.SVG", to: note)
        _ = try store.add(data: svg, filename: "packed.svgz", to: note)
        let handler = AssetSchemeHandler(root: root, attachments: store)

        for (name, method) in [("Vector.SVG", "GET"), ("Vector.SVG", "HEAD")] {
            let response = handler.response(for: URL(string: "baerchen-asset://attachment/\(note)/\(name)")!, method: method)
            #expect(response.statusCode == 200)
            #expect(response.headers["Content-Type"] == "image/svg+xml")
            #expect(response.headers["Content-Security-Policy"] == AssetSchemeHandler.attachmentSecurityPolicy)
            #expect(response.headers["Content-Security-Policy"]?.contains("sandbox") == true)
            #expect(response.headers["X-Content-Type-Options"] == "nosniff")
            #expect(response.headers["Content-Length"] == String(svg.count))
            #expect(response.body == (method == "HEAD" ? Data() : svg))
        }
        // Compressed SVG cannot be shown as an image without Content-Encoding: stays inert text.
        #expect(handler.response(for: URL(string: "baerchen-asset://attachment/\(note)/packed.svgz")!).headers["Content-Type"]
            == "text/plain; charset=utf-8")
    }

    @Test func thumbnailsArePNGsOfPDFsAndIcons() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Thumbs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        try paths.createDirectories()
        let database = try AppDatabase(path: paths.database)
        let store = AttachmentStore(paths: paths, database: database)
        let notes = NoteStore(db: database, notifier: nil, paths: paths)
        let note = try notes.create(text: "Attachments").id
        // A one-page PDF.
        let pdf = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 300)
        let consumer = try #require(CGDataConsumer(data: pdf as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 20, y: 20, width: 100, height: 100))
        context.endPDFPage()
        context.closePDF()
        _ = try store.add(data: pdf as Data, filename: "doc.pdf", to: note)
        _ = try store.add(data: Data([1]), filename: "data.zip", to: note)
        let handler = AssetSchemeHandler(root: root, attachments: store, thumbnails: Thumbnails(paths: paths))

        let page = await handler.thumbnailResponse(for: URL(string: "baerchen-asset://thumbnail/\(note)/doc.pdf")!)
        #expect(page.statusCode == 200 && page.headers["Content-Type"] == "image/png")
        let image = try #require(NSBitmapImageRep(data: page.body))
        #expect(image.pixelsHigh > image.pixelsWide) // portrait, like the page
        #expect(FileManager.default.fileExists(atPath: paths.thumbnails.appendingPathComponent(note).path))
        let icon = await handler.thumbnailResponse(for: URL(string: "baerchen-asset://thumbnail/\(note)/data.zip?icon")!)
        #expect(icon.statusCode == 200 && NSBitmapImageRep(data: icon.body) != nil)
        let missing = await handler.thumbnailResponse(for: URL(string: "baerchen-asset://thumbnail/\(note)/../x.pdf")!)
        #expect(missing.statusCode == 404)
    }
}
