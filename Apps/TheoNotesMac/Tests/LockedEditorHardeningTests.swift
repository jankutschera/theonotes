// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import OSLog
import Testing
import WebKit
@testable import TheoNotes

/// A real `WKWebView` running the bundled editor on a `LockedFixture`'s library, offscreen.
@MainActor
final class LiveLockedEditor {
    let fixture: LockedFixture
    let controller: EditorBridgeController
    let window: NSWindow

    init(_ fixture: LockedFixture, clearTimeout: Duration = .seconds(5), commitTimeout: Duration = .seconds(5)) {
        self.fixture = fixture
        controller = EditorBridgeController(
            environment: fixture.environment, page: nil, openExternally: { _ in }, checksumInterval: nil,
            clearTimeout: clearTimeout, commitTimeout: commitTimeout)
        window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 640, height: 480),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let webView = controller.webView
        webView.frame = window.contentView!.bounds
        webView.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(webView)
        window.orderFront(nil)
    }

    func close() { window.close() }

    @discardableResult
    func js(_ body: String) async throws -> Any? {
        try await controller.webView.callAsyncJavaScript(LiveEditor.hooks + body, arguments: [:], contentWorld: .page)
    }

    func waitUntilShowing(_ text: String) async throws {
        try await waitUntil("editor shows the locked note") {
            guard controller.isEditorReady else { return false }
            return ((try? await js("return hooks.text()")) as? String) == text
        }
    }
}

@MainActor
@Suite(.serialized) struct LockedEditorHardeningTests {
    // MARK: 1. The editor page is cleared, and confirmed, before a relock finishes

    @Test func relockLeavesNoPlaintextInTheRealEditorPage() async throws {
        let fixture = try await LockedFixture()
        defer { fixture.destroy() }
        let live = LiveLockedEditor(fixture)
        defer { live.close() }
        try live.controller.open(noteId: fixture.noteId)
        try await live.waitUntilShowing(fixture.text)
        try await live.js("hooks.insert(' zqxtyped')")
        try await waitUntil("typed text acked") { fixture.environment.existingSession(for: fixture.noteId)?.text.contains("zqxtyped") == true }
        #expect(try await live.js("return hooks.undo()") as? Bool == true, "the page has an undo history to lose")
        try await live.js("hooks.insert(' zqxtyped')")

        await fixture.vault.relockAndFinishCleanup()

        #expect(live.controller.pendingClears == 0)
        #expect(live.controller.failClosedResets == 0)
        let dom = try #require(try await live.js("return document.documentElement.outerHTML + document.body.innerText") as? String)
        #expect(!dom.contains(LockedFixture.secret) && !dom.contains("zqxtyped") && !dom.contains("photo.png"))
        #expect(try await live.js("return hooks.text()") as? String == "")
        #expect(try await live.js("return hooks.undo()") as? Bool == false)
        #expect(try await live.js("return hooks.redo()") as? Bool == false)
        #expect(try await live.js("return hooks.text()") as? String == "")
    }

    @Test func relockWaitsForThePageToConfirmTheClear() async throws {
        let fixture = try await LockedFixture()
        defer { fixture.destroy() }
        let (controller, page) = fixture.makeController()
        try controller.open(noteId: fixture.noteId)
        page.autoComplete = false

        fixture.vault.relock()
        #expect(controller.pendingClears == 1)
        #expect(controller.paneContent == .locked(noteId: fixture.noteId))
        let finished = Flag()
        Task { await controller.waitUntilCleared(); finished.set() }
        await Task.yield()
        #expect(!finished.value)

        page.completeDeliveries()
        await controller.waitUntilCleared()
        #expect(controller.pendingClears == 0 && controller.failClosedResets == 0)
        #expect(page.bundleLoads == 1)
    }

    @Test func aMissingConfirmationFailsClosedByReloadingThePage() async throws {
        let fixture = try await LockedFixture()
        defer { fixture.destroy() }
        let page = FakeEditorPage()
        let controller = EditorBridgeController(
            environment: fixture.environment, page: page, openExternally: { _ in }, checksumInterval: nil,
            clearTimeout: .milliseconds(50))
        _ = controller.handle(.ready(version: EditorBridge.version))
        try controller.open(noteId: fixture.noteId)
        page.autoComplete = false

        await fixture.vault.relockAndFinishCleanup()

        #expect(controller.failClosedResets == 1)
        #expect(page.bundleLoads == 2)  // the document that held the note is replaced
        #expect(!controller.isEditorReady)
        #expect(controller.pendingClears == 0)
        // A late confirmation of the old page changes nothing.
        page.completeDeliveries()
        #expect(controller.failClosedResets == 1)
        // The new page boots empty: nothing is loaded for a locked note.
        let loadsBefore = page.loadNotes.count
        _ = controller.handle(.ready(version: EditorBridge.version))
        #expect(page.loadNotes.count == loadsBefore)
        #expect(controller.paneContent == .locked(noteId: fixture.noteId))
    }

    @Test func aFailedDeliveryFailsClosedAtOnce() async throws {
        let fixture = try await LockedFixture()
        defer { fixture.destroy() }
        let (controller, page) = fixture.makeController()
        try controller.open(noteId: fixture.noteId)
        page.deliveryError = URLError(.cannotConnectToHost)

        fixture.vault.relock()

        #expect(controller.failClosedResets == 1)
        #expect(page.bundleLoads == 2)
        #expect(controller.pendingClears == 0)
    }

    @Test func aSwitchToAnOrdinaryNoteNeedsNoConfirmation() async throws {
        let fixture = try await LockedFixture()
        defer { fixture.destroy() }
        let (controller, page) = fixture.makeController()
        let plain = try fixture.environment.store.create(text: "plain")
        try controller.open(noteId: fixture.noteId)
        page.autoComplete = false
        try controller.open(noteId: plain.id)
        #expect(controller.pendingClears == 0)
    }

    // MARK: 1b. The fallback is not finished before the new document exists

    /// A controller on a fake page whose bundle reloads only commit when the test says so, with its
    /// (real, never navigated) web view in a container view of an offscreen window.
    private func fallbackSetup(_ fixture: LockedFixture, commitTimeout: Duration)
        throws -> (EditorBridgeController, FakeEditorPage, NSView, NSWindow) {
        let page = FakeEditorPage()
        let controller = EditorBridgeController(
            environment: fixture.environment, page: page, openExternally: { _ in }, checksumInterval: nil,
            clearTimeout: .milliseconds(20), commitTimeout: commitTimeout)
        _ = controller.handle(.ready(version: EditorBridge.version))
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = container
        controller.webView.frame = NSRect(x: 5, y: 6, width: 300, height: 200)
        controller.webView.autoresizingMask = [.width, .height]
        container.addSubview(controller.webView)
        try controller.open(noteId: fixture.noteId)
        page.autoComplete = false   // the page never confirms the clear
        page.reloadsCommit = false  // and the reload has not committed yet
        return (controller, page, container, window)
    }

    @Test func theFallbackKeepsTheBarrierOpenUntilTheReloadedDocumentCommits() async throws {
        let fixture = try await LockedFixture()
        defer { fixture.destroy() }
        let (controller, page, _, window) = try fallbackSetup(fixture, commitTimeout: .seconds(30))
        defer { window.close() }

        fixture.vault.relock()
        try await waitUntil("the missing confirmation started the fallback") { controller.failClosedResets == 1 }
        let finished = Flag()
        Task { await controller.waitUntilCleared(); finished.set() }
        try await Task.sleep(for: .milliseconds(150))
        #expect(!finished.value, "the barrier settled with the old document still in the page")
        #expect(controller.pendingClears == 1)
        #expect(controller.webViewReplacements == 0)

        page.commitReloads()
        await controller.waitUntilCleared()
        #expect(controller.pendingClears == 0 && controller.webViewReplacements == 0)
    }

    @Test func aReloadThatNeverCommitsReplacesTheWebViewBeforeTheBarrierSettles() async throws {
        let fixture = try await LockedFixture()
        defer { fixture.destroy() }
        let (controller, page, container, window) = try fallbackSetup(fixture, commitTimeout: .milliseconds(80))
        defer { window.close() }
        let old = controller.webView
        var reported: (WKWebView, WKWebView)?
        controller.onWebViewReplaced = { reported = ($0, $1) }

        await fixture.vault.relockAndFinishCleanup()

        // Settled only after the replacement: the old view is out of the window, the new one is in its place.
        #expect(controller.webViewReplacements == 1)
        #expect(controller.webView !== old)
        #expect(old.superview == nil && old.window == nil)
        #expect(controller.webView.superview === container)
        #expect(controller.webView.frame == NSRect(x: 5, y: 6, width: 300, height: 200))
        #expect(controller.webView.autoresizingMask == [.width, .height])
        #expect(reported?.0 === old && reported?.1 === controller.webView)
        #expect(page.replacementWebViews.count == 1 && page.replacementWebViews[0] === controller.webView)
        #expect(page.bundleLoads == 3)  // boot, the reload that never committed, the new view's load
        #expect(controller.pendingClears == 0)
        #expect(!controller.isEditorReady)
        #expect(controller.paneContent == .locked(noteId: fixture.noteId))
        // A late commit of the abandoned reload changes nothing.
        page.commitReloads()
        #expect(controller.webViewReplacements == 1)
    }

    @Test func aFailedNavigationReplacesTheWebViewAtOnce() async throws {
        let fixture = try await LockedFixture()
        defer { fixture.destroy() }
        let (controller, page, _, window) = try fallbackSetup(fixture, commitTimeout: .seconds(30))
        defer { window.close() }
        fixture.vault.relock()
        try await waitUntil("the fallback started") { controller.failClosedResets == 1 }
        #expect(controller.webViewReplacements == 0)

        page.commitReloads(false)
        await controller.waitUntilCleared()

        #expect(controller.webViewReplacements == 1)
        #expect(controller.pendingClears == 0)
    }

    @Test func theFallbackInTheRealPageShowsAFreshDocumentBeforeTheBarrierSettles() async throws {
        let fixture = try await LockedFixture()
        defer { fixture.destroy() }
        // A zero wait makes the fallback win against the page's own confirmation.
        let live = LiveLockedEditor(fixture, clearTimeout: .zero)
        defer { live.close() }
        try live.controller.open(noteId: fixture.noteId)
        try await live.waitUntilShowing(fixture.text)
        try await live.js("hooks.insert(' zqxtyped')")
        try await waitUntil("typed text acked") { fixture.environment.existingSession(for: fixture.noteId)?.text.contains("zqxtyped") == true }
        #expect(try await live.js("return hooks.undo()") as? Bool == true, "the old page has an undo history")
        // The page never answers the placeholder load, so only the fallback can clear it: a zero
        // wait alone races the page's own confirmation (it can win under load). The fallback's
        // reload replaces this override along with the document.
        _ = try await live.js("const r=window.__baerchen.receive;window.__baerchen.receive=m=>m.noteId==='\(EditorBridgeController.placeholderNoteId)'?new Promise(()=>{}):r(m);return true")

        await fixture.vault.relockAndFinishCleanup()

        #expect(live.controller.failClosedResets == 1, "the fallback ran")
        #expect(live.controller.pendingClears == 0)
        let dom = try #require(try await live.js("return document.documentElement.outerHTML + document.body.innerText") as? String)
        #expect(!dom.contains(LockedFixture.secret) && !dom.contains("zqxtyped") && !dom.contains("photo.png"))
        let text = try await live.js("return hooks.text()") as? String
        #expect(text == nil || text == "", "the document is the placeholder or still booting, never the note")
        #expect(try await live.js("return hooks.view() ? hooks.undo() : false") as? Bool != true)
    }

    // MARK: 2. No persistent WebKit store, nothing under the app's WebKit or Caches folders

    @Test func theEditorUsesANonPersistentWebsiteDataStore() async throws {
        let fixture = try await LockedFixture()
        defer { fixture.destroy() }
        let (controller, _) = fixture.makeController()
        #expect(!controller.webView.configuration.websiteDataStore.isPersistent)
    }

    @Test func showingALockedNoteWithAnAttachmentLeavesNoPlaintextInWebKitFolders() async throws {
        let fixture = try await LockedFixture()
        defer { fixture.destroy() }
        let folders = Self.webKitFolders()
        let before = Self.fileStamps(in: folders)
        let live = LiveLockedEditor(fixture)
        defer { live.close() }
        try live.controller.open(noteId: fixture.noteId)
        try await live.waitUntilShowing(fixture.text)
        try await waitUntil("the attachment image was requested") {
            (try? await live.js("const i = document.querySelector('img'); return !!i && i.complete")) as? Bool == true
        }
        await fixture.vault.relockAndFinishCleanup()

        let after = Self.fileStamps(in: folders)
        for (path, stamp) in after where before[path] != stamp {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
            #expect(data.range(of: Data(LockedFixture.attachmentMarker.utf8)) == nil, "attachment bytes in \(path)")
            #expect(data.range(of: Data(LockedFixture.secret.utf8)) == nil, "note text in \(path)")
        }
    }

    private static func webKitFolders() -> [URL] {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let id = Bundle.main.bundleIdentifier ?? "com.truebrewbirdie.baerchen"
        return ["WebKit", "Caches", "HTTPStorages"].map { library.appendingPathComponent($0).appendingPathComponent(id) }
    }

    private static func fileStamps(in folders: [URL]) -> [String: Date] {
        var stamps: [String: Date] = [:]
        for folder in folders {
            let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey])
            while let url = enumerator?.nextObject() as? URL {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
                if values?.isRegularFile == true { stamps[url.path] = values?.contentModificationDate }
            }
        }
        return stamps
    }

    // MARK: 3. Bounded, off-main decryption

    private func memory(_ fixture: LockedFixture, attachment: Int, total: Int,
                        decrypt: (@Sendable (LockedNoteAccess, String, String, Int) throws -> Data)? = nil) -> LockedAttachmentMemory {
        LockedAttachmentMemory(
            store: fixture.environment.store, vault: fixture.vault, attachmentLimit: attachment, byteLimit: total,
            decrypt: decrypt ?? { try $0.attachmentData($1, noteId: $2, maximumBytes: $3) })
    }

    @Test func anOversizedAttachmentIsRefusedBeforeItIsDecrypted() async throws {
        let fixture = try await LockedFixture()
        defer { fixture.destroy() }
        let calls = CallCounter()
        let memory = memory(fixture, attachment: fixture.attachment.count - 1, total: 1 << 20) { access, name, note, limit in
            calls.increment()
            return try access.attachmentData(name, noteId: note, maximumBytes: limit)
        }
        #expect(await memory.data(noteId: fixture.noteId, filename: "photo.png") == nil)
        #expect(calls.value == 0, "the size check comes first")
        #expect(memory.cachedByteCount == 0)
        let handler = AssetSchemeHandler(
            attachments: AttachmentStore(paths: fixture.environment.paths, database: fixture.environment.database),
            thumbnails: Thumbnails(paths: fixture.environment.paths), lockedAttachments: memory)
        let response = await handler.fullResponse(for: URL(string: "baerchen-asset://attachment/\(fixture.noteId)/photo.png")!)
        #expect(response.statusCode == 404)
    }

    @Test func theCumulativeLimitEvictsOlderFilesAndRefusesWhatCannotFit() async throws {
        let fixture = try await LockedFixture()
        defer { fixture.destroy() }
        let access = try fixture.vault.requireAccess()
        let size = fixture.attachment.count
        _ = try access.addAttachment(data: Data(repeating: 1, count: size), filename: "b.bin", to: fixture.noteId)
        _ = try access.addAttachment(data: Data(repeating: 2, count: size), filename: "c.bin", to: fixture.noteId)
        let memory = memory(fixture, attachment: size, total: size * 2)

        #expect(await memory.data(noteId: fixture.noteId, filename: "photo.png") != nil)
        #expect(await memory.data(noteId: fixture.noteId, filename: "b.bin") != nil)
        #expect(memory.cachedByteCount == size * 2)
        #expect(await memory.data(noteId: fixture.noteId, filename: "c.bin") != nil)
        #expect(memory.cachedByteCount <= size * 2, "the oldest entry made room")
        // Two at once never exceed the total either.
        memory.clear()
        async let first = memory.data(noteId: fixture.noteId, filename: "photo.png")
        async let second = memory.data(noteId: fixture.noteId, filename: "b.bin")
        async let third = memory.data(noteId: fixture.noteId, filename: "c.bin")
        _ = await (first, second, third)
        #expect(memory.cachedByteCount <= size * 2)
        #expect(memory.peakByteCount <= size * 2)
    }

    @Test func decryptionRunsOffTheMainThread() async throws {
        let fixture = try await LockedFixture()
        defer { fixture.destroy() }
        let onMain = CallCounter()
        let memory = memory(fixture, attachment: 1 << 20, total: 1 << 22) { access, name, note, limit in
            if Thread.isMainThread { onMain.increment() }
            return try access.attachmentData(name, noteId: note, maximumBytes: limit)
        }
        #expect(await memory.data(noteId: fixture.noteId, filename: "photo.png") == fixture.attachment)
        #expect(onMain.value == 0)
    }

    @Test func aRelockDuringADecryptionDropsItsResult() async throws {
        let fixture = try await LockedFixture()
        defer { fixture.destroy() }
        let gate = DispatchSemaphore(value: 0)
        let memory = memory(fixture, attachment: 1 << 20, total: 1 << 22) { access, name, note, limit in
            gate.wait()
            return (try? access.attachmentData(name, noteId: note, maximumBytes: limit)) ?? Data("revoked".utf8)
        }
        async let pending = memory.data(noteId: fixture.noteId, filename: "photo.png")
        try await Task.sleep(for: .milliseconds(50))
        fixture.vault.relock()
        gate.signal()
        #expect(await pending == nil)
        #expect(memory.cachedByteCount == 0)
    }

    // MARK: 4. Sync locks the note shown in the main window

    /// A second store on the library, as the sync engine's writer: it holds none of the app's
    /// session retention.
    private static func remoteStore(_ fixture: LockedFixture) -> NoteStore {
        NoteStore(db: fixture.environment.database, notifier: nil, paths: fixture.environment.paths)
    }

    private func mainWindow(_ fixture: LockedFixture) -> (MainWindowState, EditorBridgeController, FakeEditorPage, String) {
        let (controller, page) = fixture.makeController()
        let suite = "TheoNotesLockedMain-\(UUID().uuidString)"
        let state = MainWindowState(
            environment: fixture.environment, defaults: UserDefaults(suiteName: suite)!, editor: controller)
        return (state, controller, page, suite)
    }

    @Test func syncLockingTheShownNoteReopensItKeyedWhileTheVaultIsUnlocked() async throws {
        let fixture = try await LockedFixture()
        defer { fixture.destroy() }
        let (state, controller, page, suite) = mainWindow(fixture)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let plain = try fixture.environment.store.create(text: "# Plain\nzqxplainbody")
        state.model.selectNotes([plain.id])
        state.showFocusedNote()
        #expect(controller.paneContent == .editor(noteId: plain.id))
        let remote = Self.remoteStore(fixture)
        let password = LockedFixture.password

        _ = try fixture.environment.commitSyncedChange {
            let access = try NotePrivacy(store: remote).unlock(password: password)
            defer { access.revoke() }
            try access.lock(noteId: plain.id)
            return .applied
        }

        #expect(controller.paneContent == .editor(noteId: plain.id))
        #expect(controller.session?.noteId == plain.id)
        #expect(controller.session?.text == "# Plain\nzqxplainbody")
        #expect(page.loadNotes.last == .loadNote(noteId: plain.id, text: "# Plain\nzqxplainbody", revision: 0, readOnly: false))
        #expect(fixture.environment.keyedSessionCount == 1)
    }

    @Test func syncLockingTheShownNoteShowsTheLockViewWhileTheVaultIsLocked() async throws {
        let fixture = try await LockedFixture()
        defer { fixture.destroy() }
        let (state, controller, page, suite) = mainWindow(fixture)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let plain = try fixture.environment.store.create(text: "# Plain\nzqxplainbody")
        state.model.selectNotes([plain.id])
        state.showFocusedNote()
        fixture.vault.relock()

        let remote = Self.remoteStore(fixture)
        let password = LockedFixture.password
        _ = try fixture.environment.commitSyncedChange {
            let access = try NotePrivacy(store: remote).unlock(password: password)
            defer { access.revoke() }
            try access.lock(noteId: plain.id)
            return .applied
        }

        #expect(controller.paneContent == .locked(noteId: plain.id))
        #expect(controller.session == nil)
        #expect(page.delivered.last == EditorBridgeController.placeholderLoad)
        #expect(fixture.environment.keyedSessionCount == 0)
    }

    // MARK: 5. Logs carry codes only

    @Test func keyedSessionFailuresLogOnlyTheCaseCode() async throws {
        let fixture = try await LockedFixture()
        defer { fixture.destroy() }
        let secretName = "zqx-secret-name-\(UUID().uuidString.prefix(6)).png"
        let started = Date()
        fixture.environment.logSessionFailure(
            "flush failed", noteId: fixture.noteId, keyed: true, error: NotePrivacyError.attachmentMissing(secretName))
        // A real failure on the keyed path: the key is gone while an edit is still to be committed.
        let (controller, _) = fixture.makeController()
        try controller.open(noteId: fixture.noteId)
        _ = fixture.append(" zqxlogged", to: controller, from: fixture.text, txId: "t1", base: 0)
        try fixture.vault.requireAccess().revoke()
        fixture.environment.flushAll()

        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(at: store.position(date: started.addingTimeInterval(-1)))
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.subsystem == "com.truebrewbirdie.baerchen" }
        #expect(entries.contains { $0.composedMessage.contains("attachmentMissing") })
        for entry in entries {
            #expect(!entry.composedMessage.contains(secretName), "file name in a log line")
            #expect(!entry.composedMessage.contains(LockedFixture.secret))
            #expect(!entry.composedMessage.contains("zqxlogged"))
        }
    }

    // MARK: 6. A failed sealed-journal replay leaves no bookkeeping behind

    @Test func aFailedReplayReleasesItsSession() async throws {
        let cache = FakeVaultKeyCache()
        let first = try await LockedFixture(cache: cache)
        defer { first.destroy() }
        let session = try first.environment.session(for: first.noteId)
        _ = session.apply(
            txId: "t1", baseRevision: 0,
            changeSet: ChangeSet(sections: [.retain(first.text.utf16.count), .replace(deleteLength: 0, insert: " zqxkilled")]),
            origin: nil)
        try first.environment.vault.requireAccess().revoke()

        let second = try await LockedFixture(root: first.root, cache: cache, relaunchingNote: first.noteId)
        second.environment.journalReplayFlush = { _ in throw URLError(.cannotWriteToFile) }
        try await second.vault.unlock(password: LockedFixture.password)

        #expect(second.environment.keyedSessionCount == 0)
        #expect(second.environment.existingSession(for: first.noteId) == nil)
        #expect(!second.environment.store.retention.contains(first.noteId))
    }
}

/// A thread-safe counter for closures that run off the main actor.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// A boolean a task sets.
@MainActor
final class Flag {
    private(set) var value = false
    func set() { value = true }
}
