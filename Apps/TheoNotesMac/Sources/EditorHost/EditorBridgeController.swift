// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import CryptoKit
import Foundation
import WebKit
import os

let editorLogger = Logger(subsystem: "com.truebrewbirdie.baerchen", category: "editor")

/// The editor page as seen by the controller; the WebKit implementation drives the real web view,
/// tests substitute a recorder.
@MainActor
protocol EditorPage: AnyObject {
    /// (Re)loads the bundled editor; it answers with `ready` once booted.
    func loadBundle()
    /// Delivers a message to `window.__baerchen.receive`; completes after the page handled it.
    func deliver(_ message: HostToEditorMessage, completion: @escaping @MainActor (Error?) -> Void)
    /// Debug-only environment checks (secure context, crypto.subtle).
    func logDiagnostics()
    /// Brings the page root (background, `color-scheme`) in step with `look` and removes the boot style of
    /// `EditorBoot`; runs after the page is ready and after each later change of the look.
    func settleChrome(_ look: EditorLook)
    /// Loads the bundle again: the new document replaces the old one (DOM, undo history, JS heap).
    /// `committed` is called with true once that document committed, with false if the
    /// navigation failed; it may never be called (the controller then times out).
    func reloadBundle(committed: @escaping @MainActor (Bool) -> Void)
    /// The editor's web view was replaced by `webView`.
    func use(webView: WKWebView)
}

extension EditorPage {
    func logDiagnostics() {}
    func settleChrome(_ look: EditorLook) {}
    func reloadBundle(committed: @escaping @MainActor (Bool) -> Void) {
        loadBundle()
        committed(true)
    }
    func use(webView: WKWebView) {}
}

/// What the menus need of the editor (observed by SwiftUI).
@MainActor
@Observable
final class EditorStatus {
    /// An editable note is shown in a booted editor (not read-only, not the placeholder).
    fileprivate(set) var isEditable = false
    /// A note is shown in a booted editor, read-only included (not the placeholder).
    fileprivate(set) var showsNote = false
    /// The shown note's Format menu state; nil until the editor reported it.
    fileprivate(set) var formatState: FormatState?
    /// The shown note's selection as the editor last reported it (UTF-16 offsets; Info panel).
    fileprivate(set) var selection: SelectionRange?
    /// The locked note this editor is asked to show while the vault is locked: the pane shows
    /// the lock view for it and the editor holds no session and no text.
    fileprivate(set) var lockedNoteId: String?
    fileprivate(set) var recoveryError: String?
}

/// Connects one window's editor web view to the `NoteSession` of the note it shows.
@MainActor
final class EditorBridgeController: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    static let messageHandlerName = "bridge"
    /// Error- or needsFullText-triggered reloads allowed without an ack in between (loop breaker).
    static let maxReloadsWithoutAck = 5
    /// The id of the empty read-only document shown after the visible note was deleted.
    static let placeholderNoteId = ""
    /// The placeholder's loadNote. The editor loads it locked by its id; both sides pin it to
    /// `Fixtures/bridge/messages-loadNote-placeholder.json`.
    static let placeholderLoad = HostToEditorMessage.loadNote(noteId: placeholderNoteId, text: "", revision: 0, readOnly: true)

    /// Replaced by a new instance when the page cannot be made to drop a locked note (fail closed).
    private(set) var webView: WKWebView
    /// Called after the web view was replaced, with the old and the new one, so a host can follow.
    var onWebViewReplaced: ((_ old: WKWebView, _ new: WKWebView) -> Void)?
    /// Times the web view itself was replaced (the page's reload did not commit in time or failed).
    private(set) var webViewReplacements = 0
    let status = EditorStatus()
    /// Drop/paste/⇧⌘V storage, Quick Look and the attachment context menu.
    let attachments: AttachmentController
    /// The native menus of the rich blocks (heading menu; table and callout menus follow).
    let blockMenus = BlockMenus()
    private let environment: AppEnvironment
    private let page: any EditorPage
    /// Opens a URL outside the app (NSWorkspace); callers check `LinkRouting` first.
    let openExternally: (URL) -> Void
    /// A link the shown note opened (⌘-click, link icon, ⇧⌘K); set by the window.
    var onOpenLink: ((OpenLinkRequest) -> Void)?
    /// ⌘K in an editable shown note; set by the window (the link panel).
    var onEditLink: ((EditLinkRequest) -> Void)?
    /// Where Copy Code (`copyText`) writes; tests substitute a private pasteboard.
    var pasteboard: NSPasteboard = .general

    /// How long a relock waits for the page to confirm that it dropped a locked note before the
    /// page is replaced instead.
    private let clearTimeout: Duration
    /// How long the fallback waits for the reloaded document to commit before the web view itself is replaced.
    private let commitTimeout: Duration
    /// Clears of the page (after a locked note's session closed) not yet confirmed.
    private(set) var pendingClears = 0
    /// Times a missing or failed confirmation made this editor replace its page (fail closed).
    private(set) var failClosedResets = 0
    private var clearWatchdogs: [Int: Task<Void, Never>] = [:]
    private var nextClearId = 0
    private var clearWaiters: [CheckedContinuation<Void, Never>] = []

    private(set) var session: NoteSession?
    private var recoverySourceSession: NoteSession?
    private var discardDocumentGeneration: UInt64 = 0
    /// What this editor's column shows: the editor, the lock view or nothing.
    var paneContent: EditorPaneContent {
        if let id = status.lockedNoteId { return .locked(noteId: id) }
        if let session { return .editor(noteId: session.noteId) }
        return .empty
    }
    /// The shown note's headings for the VoiceOver rotor, parsed once per session revision.
    let headingsCache = HeadingsCache()
    /// This editor's listener on `session` (the note may be open in other windows too).
    private var listenerToken: NoteSession.ListenerToken?
    private(set) var isEditorReady = false
    /// Per note, the `loadNote` and `applyExternalChange` deliveries the page has not handled yet.
    /// While any is pending, `changes` for that note may name a document the host no longer has
    /// (WebKit delivers in order), so they are rejected. Reload requests are dropped only while a
    /// `loadNote` is pending (R2/R14).
    private var pendingDeliveries: [String: PendingDeliveries] = [:]
    /// Bumped when the page is replaced, so completions from the old page are ignored.
    private var deliveryGeneration = 0
    private var reloadsWithoutAck = 0
    /// `requestChecksum` round-trips in flight, keyed by request id.
    private var checksumRequests: [String: @MainActor (_ noteId: String?, _ sha256: String?) -> Void] = [:]
    /// The editor's last reported selection per note, restored by every `loadNote` (F1).
    private var lastSelection: [String: SelectionRange] = [:]
    /// Edits applied or external changes sent since the last periodic checksum.
    private var changedSinceChecksum = false
    private var checksumTask: Task<Void, Never>?
    private var focusWhenReady = false
    /// A search highlight for the shown note, delivered right after its next `loadNote`.
    private var pendingFind: (noteId: String, query: String, terms: [String])?
    private let completions: CompletionProvider
    private var editorTagIcons: [String: String] = [:]
    /// The answer being computed for the latest `requestCompletions` (cancelled by the next one).
    private(set) var completionAnswer: Task<Void, Never>?
    /// The editor settings (Settings ▸ General) and what the page has; a new page has the editor's
    /// defaults, so only what differs is sent (`setSettings`, before the note on `ready`).
    private var editorSettings: EditorSettings
    private var pageSettings = EditorBridgeController.editorDefaults
    private var settingsObservation: Task<Void, Never>?
    /// The look the page boots in and is settled to (`EditorBoot`).
    private var currentLook: EditorLook
    /// The `autocomplete` setting (M3 Task 7): completion requests get empty answers while off.
    private var autocomplete: Bool { editorSettings.autocomplete ?? true }
    /// Settings snapshots handled so far (tests wait for the next one).
    private(set) var settingsSnapshotsSeen = 0
    /// Notes last loaded read-only into this page (Trash, Archive, read-only, locked): their
    /// `changes` are never applied (the editor refuses edits too; defense in depth).
    private var readOnlyLoaded: Set<String> = []

    /// The settings a freshly booted editor starts with (settings.ts `DEFAULT_SETTINGS`, and the
    /// completion bridge's `autocomplete` default).
    static let editorDefaults = EditorSettings(
        hideMarkdown: true, autoSortTodos: false, showHeadingLevels: true, autocomplete: true, typewriterMode: false,
        typography: EditorTypography(), theme: [:], appearance: .light, reduceMotion: false)

    private struct PendingDeliveries: Equatable {
        var loads = 0
        var externalChanges = 0
    }

    convenience init(environment: AppEnvironment) {
        self.init(environment: environment, page: nil, openExternally: { NSWorkspace.shared.open($0) })
    }

    init(
        environment: AppEnvironment, page: (any EditorPage)?, openExternally: @escaping (URL) -> Void,
        checksumInterval: Duration? = .seconds(5), clearTimeout: Duration = .seconds(2),
        commitTimeout: Duration = .seconds(2)
    ) {
        self.environment = environment
        self.clearTimeout = clearTimeout
        self.commitTimeout = commitTimeout
        self.openExternally = openExternally
        let store = AttachmentStore(paths: environment.paths, database: environment.database)
        attachments = AttachmentController(store: store)
        completions = CompletionProvider(db: environment.database)
        let settings = TheoNotesCore.Settings(db: environment.database)
        let initialSnapshot = (try? settings.snapshot()) ?? TheoNotesCore.Settings.Snapshot()
        var initialSettings = Self.editorSettings(from: initialSnapshot)
        // A new editor starts with the current look; the page boots with the defaults, so `ready` sends the difference.
        let look = environment.appearance.editorLook
        initialSettings.typography = look.typography
        initialSettings.theme = look.theme
        initialSettings.appearance = look.appearance
        initialSettings.reduceMotion = look.reduceMotion
        editorSettings = initialSettings
        currentLook = look
        let webView = Self.makeWebView(
            environment: environment, quickLook: attachments.quickLook, look: look,
            zoom: EditorZoom.snap(initialSnapshot.editorZoom))
        self.webView = webView
        self.page = page ?? WebKitEditorPage(webView: webView)
        super.init()
        wire(webView)
        attachments.editor = self
        attachments.notes = environment.store
        attachments.lockedAttachments = environment.lockedAttachments
        attachments.stored = { [weak environment] noteId, names in
            environment?.ocr?.attachmentsInserted(noteId: noteId, filenames: names)
        }
        blockMenus.editor = self
        blockMenus.isTrashed = { [weak environment] id in
            guard let environment, let note = try? environment.store.note(id: id) else { return false }
            return note.location == .trash
        }
        environment.registerEditor(self)
        settingsObservation = Task { [weak self] in
            do {
                for try await snapshot in settings.observe() {
                    self?.settingsChanged(Self.editorSettings(from: snapshot))
                    self?.zoomChanged(snapshot.editorZoom)
                    self?.settingsSnapshotsSeen += 1
                }
            } catch {
                editorLogger.error("settings observation failed: \(error)")
            }
        }
        self.page.loadBundle()
        if let checksumInterval {
            // Spec §3.3 safety net: compare both copies every few seconds while edits flow.
            checksumTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: checksumInterval)
                    self?.checksumTick()
                }
            }
        }
    }

    /// A new editor web view: the bundled editor's scheme handler, an in-memory website data
    /// store (nothing a locked note shows may reach WebKit's disk caches or storage), the boot look.
    private static func makeWebView(
        environment: AppEnvironment, quickLook: QuickLookController, look: EditorLook, zoom: Double
    ) -> TheoNotesWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            AssetSchemeHandler(
                attachments: AttachmentStore(paths: environment.paths, database: environment.database),
                thumbnails: Thumbnails(paths: environment.paths),
                lockedAttachments: environment.lockedAttachments),
            forURLScheme: AssetSchemeHandler.scheme)
        configuration.writingToolsBehavior = .complete
        configuration.websiteDataStore = .nonPersistent()
        let webView = TheoNotesWebView(frame: .zero, configuration: configuration)
        webView.quickLook = quickLook
        webView.underPageBackgroundColor = NSColor(look.background)
        // View ▸ Zoom (M7 Task 10): one app-wide zoom for every editor.
        webView.pageZoom = zoom
        installBootScript(look, in: webView)
        #if DEBUG
        webView.isInspectable = true
        #endif
        return webView
    }

    /// Connects `webView` to this controller: rotor, Format menu, pop-ups, navigation and bridge.
    private func wire(_ webView: TheoNotesWebView) {
        let rotor = EditorHeadingsRotor(
            headings: { [weak self] in
                guard let self else { return [] }
                return self.headingsCache.entries(for: self.session)
            },
            choose: { [weak self] index in self?.scrollToHeading(index) })
        rotor.target = webView
        webView.headingsRotor = rotor
        webView.formatHost = self
        blockMenus.popUp = { [weak webView] menu, rect in
            guard let webView else { return }
            BlockMenus.present(menu, at: rect, in: webView)
        }
        attachments.popUp = { [weak webView] menu in
            guard let webView, let window = webView.window else { return }
            menu.popUp(positioning: nil, at: webView.convert(window.mouseLocationOutsideOfEventStream, from: nil), in: webView)
        }
        webView.navigationDelegate = self
        webView.configuration.userContentController.addScriptMessageHandler(
            WeakScriptMessageHandler(self), contentWorld: .page, name: Self.messageHandlerName
        )
    }

    /// Takes the web view that held a locked note out of its window at once and puts a new one in
    /// its place (same superview, frame and resizing), then loads the bundle into it.
    private func replaceWebView() {
        discardDocumentGeneration &+= 1
        recoverySourceSession = nil
        editorLogger.fault("the editor page did not commit a fresh document; replacing the web view")
        webViewReplacements += 1
        let old = webView
        let parent = old.superview
        let frame = old.frame
        let mask = old.autoresizingMask
        old.navigationDelegate = nil
        old.stopLoading()
        old.configuration.userContentController.removeAllScriptMessageHandlers()
        old.isHidden = true
        old.removeFromSuperview()
        let new = Self.makeWebView(
            environment: environment, quickLook: attachments.quickLook, look: currentLook,
            zoom: old.pageZoom)
        webView = new
        wire(new)
        page.use(webView: new)
        new.frame = frame
        new.autoresizingMask = mask
        parent?.addSubview(new)
        onWebViewReplaced?(old, new)
        isEditorReady = false
        page.loadBundle()
    }

    isolated deinit {
        checksumTask?.cancel()
        settingsObservation?.cancel()
        completionAnswer?.cancel()
        settleFreeze(nil)
        stopListening()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    // MARK: - Public

    /// Shows `noteId`, flushing the previously shown note first. A `caret` (UTF-16 offset) replaces
    /// the note's remembered selection, e.g. for a new note made in a tag scope.
    func open(noteId: String, caret: Int? = nil) throws {
        if let caret { lastSelection[noteId] = SelectionRange(anchor: caret, head: caret) }
        if session?.noteId == noteId { return }
        // A locked note while the vault is locked has no session: the pane shows the lock view.
        if environment.isLockedBehindVault(noteId) { return showLockedNote(noteId) }
        // Resolve first: if this throws, the visible note keeps receiving external changes.
        let next = try environment.session(for: noteId)
        status.lockedNoteId = nil
        if let previous = session {
            if recoverySourceSession == nil && !environment.isKeyedSession(previous) { recoverySourceSession = previous }
            stopListening()
            flush(previous)
        }
        session = next
        status.formatState = nil
        status.selection = lastSelection[noteId]
        reloadsWithoutAck = 0
        pendingHeadingScroll = nil
        pendingSelectRange = nil
        // External changes and other windows' edits of this note arrive here.
        listenerToken = next.addTextListener { [weak self, weak next] _, changeSet in
            guard let self, let next, self.session === next else { return }
            self.sendExternalChange(changeSet, for: next)
        }
        // Once per note this editor starts showing, not for a reload of the one it shows; the load
        // that directly follows a capture is not an open (FOC-R3, FOC-R250).
        if !environment.consumeOpenRecordSuppression(noteId) { environment.recordOpened(noteId: noteId) }
        sendLoadNote()
    }

    /// Loads the shown note again, e.g. after it moved to the Trash or was locked elsewhere, so
    /// the editor re-evaluates read-only (spec §4.9).
    func reloadShownNote() {
        sendLoadNote()
    }

    private func stopListening() {
        if let listenerToken { session?.removeListener(listenerToken) }
        listenerToken = nil
    }

    func flush() {
        if let session { flush(session) }
    }

    /// Highlights the note-list search's `terms` in the shown note and scrolls to the first match,
    /// without moving the selection (bridge `searchHighlight`); empty `terms` clear. Before the
    /// editor is ready it follows the first `loadNote`; later reloads (errors, checksum
    /// mismatches) do not repeat it.
    func highlightSearch(query: String, terms: [String]) {
        guard let session else { return }
        pendingFind = (session.noteId, query, terms)
        deliverPendingFind()
    }

    private func deliverPendingFind() {
        guard isEditorReady, let find = pendingFind else { return }
        pendingFind = nil
        guard find.noteId == session?.noteId else { return }
        page.deliver(.searchHighlight(noteId: find.noteId, query: find.query, terms: find.terms)) { error in
            if let error { editorLogger.error("searchHighlight failed: \(error)") }
        }
    }

    /// Makes the web view first responder and puts the caret into the editor; before the editor
    /// is ready, it is focused right after the first `loadNote`.
    func focusEditor() {
        webView.window?.makeFirstResponder(webView)
        guard isEditorReady else {
            focusWhenReady = true
            return
        }
        page.deliver(.focus) { error in
            if let error { editorLogger.error("focus failed: \(error)") }
        }
    }

    /// No note is shown (e.g. the last note left the list): flushes and lets go of the current
    /// session, shows the empty read-only placeholder and gives up keyboard focus, so typing can't
    /// reach a note that is hidden (or now in Trash/Archive). Its remembered selection is kept.
    func showNoNote() {
        status.lockedNoteId = nil
        // Also when a deleted note's session was closed already: the hidden page keeps no focus.
        resignKeyboardFocus()
        guard let current = session else { return }
        stopListening()
        flush(current)
        detach(current)
    }

    struct BrowserDiscardToken: Equatable {
        let page: ObjectIdentifier
        let noteID: String?
        let error: String
        let documentGeneration: UInt64
    }
    var browserDiscardToken: BrowserDiscardToken? {
        guard let error = status.recoveryError else { return nil }
        return BrowserDiscardToken(page: ObjectIdentifier(webView), noteID: session?.noteId, error: error,
                                   documentGeneration: discardDocumentGeneration)
    }

    /// Call only after the user explicitly accepts losing browser-only text on this exact page.
    func discardBrowserTextAfterConfirmation(_ token: BrowserDiscardToken) {
        guard browserDiscardToken == token else { return }
        status.recoveryError = nil
        resetDeliveries()
        replaceWebView()
    }

    func retryBrowserRecovery() {
        guard status.recoveryError != nil else { return }
        status.recoveryError = nil
        reloadsWithoutAck = 0
        if session != nil { sendLoadNote() }
        else if isEditorReady {
            discardDocumentGeneration &+= 1
            page.deliver(Self.placeholderLoad) { _ in }
        }
    }

    /// An edit arrived while a restore held all writes; the page's copy may be ahead of the host.
    private var refusedWhileFrozen = false

    /// The restore is over: an editor whose edit was refused shows the note as the host has it now.
    func editsUnfrozen() {
        guard refusedWhileFrozen else { return }
        refusedWhileFrozen = false
        reloadsWithoutAck = 0
        requestReload(reason: "edit refused during a restore")
    }

    /// The environment closed `closed` (its note is deleted): stop showing it and leave an empty
    /// read-only placeholder. Later `changes` for that note find no session and get needsFullText.
    func sessionClosed(_ closed: NoteSession) {
        guard session === closed else { return }
        stopListening()
        // A keyed session held a locked note's text in the page: the clear must be confirmed.
        detach(closed, confirmedClear: environment.isKeyedSession(closed))
        showAfterSessionClosed(noteId: closed.noteId)
    }

    /// Phase 1 of a lock change (M9M-R54): this editor lets go of `closed` and its page drops the
    /// note's text through the same confirmed clear as a relock (`waitUntilCleared()` completes
    /// once the page confirmed it, a fresh document committed, or the web view was replaced).
    /// Nothing is reopened yet. False when this editor shows another note.
    @discardableResult
    func suspendForLockChange(_ closed: NoteSession) -> Bool {
        guard session === closed else { return false }
        stopListening()
        flush(closed)
        detach(closed, confirmedClear: true)
        return true
    }

    /// Phase 2: the note has its new lock state; show it again (see `showAfterSessionClosed`).
    func resumeAfterLockChange(noteId: String) {
        showAfterSessionClosed(noteId: noteId)
    }

    private func showAfterSessionClosed(noteId: String) {
        let note = (try? environment.store.note(id: noteId)) ?? nil
        guard let note else {
            lastSelection[noteId] = nil
            return
        }
        // The note still exists. A relock (or a sync that locked it) closed the session: with the
        // vault locked the lock view takes its place, with it unlocked the note reopens keyed. A
        // note that is not locked (its lock was removed, or a lock failed) reopens plain (M9M-R47).
        if !note.isLocked || environment.vault.isUnlocked {
            do {
                try open(noteId: noteId)
            } catch {
                editorLogger.error("could not reopen note \(noteId, privacy: .public): \(PrivacyErrorCode.code(for: error), privacy: .public)")
            }
        } else {
            status.lockedNoteId = noteId
        }
    }

    /// Completes once every clear of the page that was started is confirmed (or the page was
    /// replaced because it was not).
    func waitUntilCleared() async {
        guard pendingClears > 0 else { return }
        await withCheckedContinuation { clearWaiters.append($0) }
    }

    /// Replaces the page's document by the placeholder and waits for the page to say it did:
    /// the load drops the DOM and the undo history. No answer in `clearTimeout`, or a failed
    /// delivery, replaces the page itself (fail closed).
    private func clearPageConfirmed() {
        discardDocumentGeneration &+= 1
        guard isEditorReady else { return }
        nextClearId += 1
        let id = nextClearId
        pendingClears += 1
        clearWatchdogs[id] = Task { [weak self, clearTimeout] in
            try? await Task.sleep(for: clearTimeout)
            guard !Task.isCancelled else { return }
            self?.settleClear(id, confirmed: false)
        }
        page.deliver(Self.placeholderLoad) { [weak self] error in
            self?.settleClear(id, confirmed: error == nil)
        }
    }

    private func settleClear(_ id: Int, confirmed: Bool) {
        guard let watchdog = clearWatchdogs.removeValue(forKey: id) else { return }  // settled already
        watchdog.cancel()
        guard confirmed else {
            // The clear stays pending until the replacement document committed (or the web view
            // itself was replaced): the relock is not finished before.
            return replacePageFailClosed { [weak self] in self?.finishClear() }
        }
        finishClear()
    }

    private func finishClear() {
        pendingClears -= 1
        guard pendingClears == 0 else { return }
        let waiters = clearWaiters
        clearWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// The page did not confirm that it dropped a locked note: load the editor again, which
    /// replaces the document (DOM, undo history, JS heap). `ready` then loads whatever is shown.
    /// `finished` runs once the new document committed; if that does not happen within
    /// `commitTimeout`, or the navigation fails, the web view itself is replaced first.
    private func replacePageFailClosed(finished: @escaping @MainActor () -> Void) {
        editorLogger.fault("the editor page did not confirm clearing a locked note; replacing the page")
        failClosedResets += 1
        isEditorReady = false
        resetDeliveries()
        let unanswered = checksumRequests.values
        checksumRequests.removeAll()
        unanswered.forEach { $0(nil, nil) }
        webView.stopLoading()
        let attempt = CommitAttempt()
        let settle: @MainActor (Bool) -> Void = { [weak self] committed in
            guard !attempt.settled else { return }
            attempt.settled = true
            attempt.watchdog?.cancel()
            if !committed { self?.replaceWebView() }
            finished()
        }
        attempt.watchdog = Task { [commitTimeout] in
            try? await Task.sleep(for: commitTimeout)
            guard !Task.isCancelled else { return }
            settle(false)
        }
        discardDocumentGeneration &+= 1
        page.reloadBundle(committed: settle)
    }

    /// One fallback in flight: settled once, by the commit, a failure or the timeout.
    private final class CommitAttempt {
        var settled = false
        var watchdog: Task<Void, Never>?
    }

    /// Replaces the shown note (flushed first) by the lock view for `noteId`.
    private func showLockedNote(_ noteId: String) {
        if let current = session {
            stopListening()
            flush(current)
            detach(current)
        }
        status.lockedNoteId = noteId
        pendingHeadingScroll = nil
        pendingSelectRange = nil
    }

    /// The vault was unlocked: an editor waiting behind a lock view opens its note and takes focus.
    func vaultDidUnlock() {
        guard let noteId = status.lockedNoteId else { return }
        status.lockedNoteId = nil
        do {
            try open(noteId: noteId)
            focusEditor()
        } catch {
            editorLogger.error("could not open note \(noteId, privacy: .public) after the unlock: \(PrivacyErrorCode.code(for: error), privacy: .public)")
        }
    }

    private func detach(_ shown: NoteSession, confirmedClear: Bool = false) {
        discardDocumentGeneration &+= 1
        if confirmedClear { recoverySourceSession = nil }
        else if recoverySourceSession == nil && !environment.isKeyedSession(shown) { recoverySourceSession = shown }
        settleFreeze(nil)
        session = nil
        status.isEditable = false
        status.showsNote = false
        status.formatState = nil
        status.selection = nil
        headingsCache.reset()
        pendingDeliveries[shown.noteId] = nil
        if confirmedClear { return clearPageConfirmed() }
        guard isEditorReady else { return }
        page.deliver(Self.placeholderLoad) { error in
            if let error { editorLogger.error("placeholder loadNote failed: \(error)") }
        }
    }

    private func resignKeyboardFocus() {
        focusWhenReady = false
        guard let window = webView.window, let responder = window.firstResponder as? NSView,
              responder === webView || responder.isDescendant(of: webView) else { return }
        window.makeFirstResponder(nil)
    }

    /// One periodic check: if the note changed since the last one, asks the editor for its
    /// checksum and reloads the note on a mismatch. A reply is only compared when the host is
    /// still at the revision the request was sent at and nothing is pending for the note.
    func checksumTick() {
        guard changedSinceChecksum, isEditorReady, let session else { return }
        changedSinceChecksum = false
        let noteId = session.noteId
        let revision = session.revision
        requestChecksum { [weak self, weak session] replyNoteId, sha256 in
            guard let self, let session, let sha256, self.session === session, replyNoteId == noteId,
                  session.revision == revision, self.pendingDeliveries[noteId] == nil else { return }
            let expected = SHA256.hash(data: Data(session.text.utf8)).map { String(format: "%02x", $0) }.joined()
            guard sha256 != expected else { return }
            // Hashes of note text are content-revealing: log only the note and revision.
            editorLogger.error("checksum mismatch for note \(noteId, privacy: .public) at revision \(revision); reloading")
            self.requestReload(reason: "checksum mismatch")
        }
    }

    /// How long `confirmInSync` waits for the page.
    var syncTimeout: Duration = .seconds(2)

    @MainActor private final class Once {
        private var done = false
        func run(_ body: () -> Void) {
            guard !done else { return }
            done = true
            body()
        }
    }

    /// A sync point with the page: true when the page's document is exactly the session's text once
    /// everything the page sent before the answer has been applied (the bridge delivers in order).
    /// An editor that is not showing the note yet cannot hold typed text, so it counts as in sync.
    /// False when the page differs (a transaction is still unacknowledged), cannot answer in time,
    /// or went away.
    func confirmInSync() async -> Bool {
        guard let session, isEditorReady else { return true }
        guard pendingDeliveries[session.noteId] == nil, status.recoveryError == nil else { return false }
        let noteId = session.noteId
        let timeout = syncTimeout
        return await withCheckedContinuation { continuation in
            let once = Once()
            let timer = Task { @MainActor in
                try? await Task.sleep(for: timeout)
                once.run { continuation.resume(returning: false) }
            }
            requestChecksum { [weak self] replyNoteId, sha256 in
                once.run {
                    timer.cancel()
                    guard let self, let current = self.session, current === session, replyNoteId == noteId, let sha256 else {
                        return continuation.resume(returning: false)
                    }
                    let expected = SHA256.hash(data: Data(current.text.utf8)).map { String(format: "%02x", $0) }.joined()
                    continuation.resume(returning: sha256 == expected)
                }
            }
        }
    }

    // MARK: - Capture close (W1, FOC-R343 … FOC-R349)

    /// How long `freezeForClose` waits for the page. The page gives up itself after 2 s and says so;
    /// this is the backstop for a page that cannot answer at all.
    var freezeTimeout: Duration = .seconds(3)

    /// The one `freezeForClose` in flight: its request id, the note, and who waits for the answer.
    private final class FreezeBarrier {
        let requestId = UUID().uuidString
        let noteId: String
        var continuation: CheckedContinuation<FrozenForClose?, Never>?
        var timer: Task<Void, Never>?
        init(noteId: String) { self.noteId = noteId }
    }
    private var freezeBarrier: FreezeBarrier?

    /// Freezes the editor showing `noteId` and drains it: the page ends a running composition, goes
    /// read-only, waits until every transaction it sent is acknowledged by this host (the bridge
    /// delivers in order, so those have all been applied to the session by the time it answers),
    /// then reports its document hash and whether the document was ever edited. Returns that answer
    /// only when it is ok. Nil in every other case, and a caller must then keep the note: the editor
    /// is not ready or shows another note, the page answered not ok, answered for another note,
    /// did not answer in `freezeTimeout`, or was loaded, replaced or detached while the question
    /// was open. A newer request replaces an older one (its caller gets nil).
    func freezeForClose(noteId: String) async -> FrozenForClose? {
        guard isEditorReady, let session, session.noteId == noteId else { return nil }
        settleFreeze(nil)
        let barrier = FreezeBarrier(noteId: noteId)
        return await withCheckedContinuation { continuation in
            barrier.continuation = continuation
            freezeBarrier = barrier
            barrier.timer = Task { [weak self, freezeTimeout] in
                try? await Task.sleep(for: freezeTimeout)
                guard !Task.isCancelled else { return }
                self?.settleFreeze(nil, ifCurrent: barrier)
            }
            page.deliver(.freezeForClose(requestId: barrier.requestId, noteId: noteId)) { [weak self] error in
                guard let error else { return }
                editorLogger.error("freezeForClose failed: \(error)")
                self?.settleFreeze(nil, ifCurrent: barrier)
            }
        }
    }

    /// Ends the open `freezeForClose` question with `answer`; a barrier given by `ifCurrent` only if it is still the open one.
    private func settleFreeze(_ answer: FrozenForClose?, ifCurrent barrier: FreezeBarrier? = nil) {
        guard let open = freezeBarrier, barrier == nil || open === barrier else { return }
        freezeBarrier = nil
        open.timer?.cancel()
        open.continuation?.resume(returning: answer)
        open.continuation = nil
    }

    /// `frozenForClose`: answers the open question, if it is the one the reply names. An unknown or
    /// late request id is ignored; a reply for another note is an error and counts as no answer.
    private func frozenForClose(_ reply: FrozenForClose) {
        guard let open = freezeBarrier, open.requestId == reply.requestId else { return }
        guard reply.noteId == open.noteId else {
            editorLogger.error("frozenForClose for note \(reply.noteId, privacy: .public) answers a question about \(open.noteId, privacy: .public)")
            return settleFreeze(nil, ifCurrent: open)
        }
        settleFreeze(reply.ok && reply.sha256 != nil ? reply : nil, ifCurrent: open)
    }

    /// Asks the editor for the SHA-256 of its document; completes with nils if it cannot answer.
    func requestChecksum(completion: @escaping @MainActor (_ noteId: String?, _ sha256: String?) -> Void) {
        guard isEditorReady, session != nil else { return completion(nil, nil) }
        let requestId = UUID().uuidString
        checksumRequests[requestId] = completion
        page.deliver(.requestChecksum(requestId: requestId)) { [weak self] error in
            guard let error else { return }
            editorLogger.error("requestChecksum failed: \(error)")
            self?.checksumRequests.removeValue(forKey: requestId)?(nil, nil)
        }
    }

    /// Runs an editor command (Format menu, shortcut) on the shown note; ignored while the editor
    /// is not ready or the note is read-only (the Find commands and Open Link also run in read-only
    /// notes: they find or open, the editor refuses replacing).
    func apply(_ command: EditorCommandName, args: [String: CommandArgument]? = nil) {
        guard isEditorReady, session != nil, status.isEditable || command.runsInReadOnly else { return }
        page.deliver(.applyCommand(name: command, args: args)) { error in
            if let error { editorLogger.error("applyCommand \(command.rawValue, privacy: .public) failed: \(error)") }
        }
    }

    /// Selects the UTF-16 range `anchor`...`head` of the shown note and scrolls it into view
    /// (`app open` with a selection, M5 Task 12). Not an edit, so read-only notes too; asked for
    /// before the editor is ready it is sent right after the note loads, and it is ignored while
    /// no note is shown. The page drops a range outside the document.
    func selectRange(anchor: Int, head: Int) {
        guard let session else { return }
        guard isEditorReady else {
            pendingSelectRange = (session.noteId, anchor, head)
            return
        }
        page.deliver(.selectRange(noteId: session.noteId, anchor: anchor, head: head)) { error in
            if let error { editorLogger.error("selectRange failed: \(error)") }
        }
    }

    /// Format ▸ File… (⇧⌘V).
    func presentInsertFilePanel() {
        guard isEditorReady, status.isEditable else { return }
        attachments.presentInsertFilePanel()
    }

    /// Edit ▸ Paste From ▸ Code: the pasteboard's text as a fenced code block in the shown note.
    func pasteAsCode(_ source: NSPasteboard = .general) {
        guard let text = source.string(forType: .string), !text.isEmpty else { return }
        apply(.pasteCode, args: ["text": .string(text)])
    }

    /// Format ▸ Copy Link to Here: the link of the heading at the caret (the heading badge menu's item).
    @discardableResult
    func copyHeadingLinkAtCaret() -> Bool {
        blockMenus.copyLinkToHereAtCaret()
    }

    /// Puts the caret on the shown note's `index`-th heading (`NoteParser` order) and scrolls it to
    /// the top: wiki links to a heading and the Info panel's table of contents, also in read-only
    /// notes. Before the page is ready (a new window) it is queued and delivered right after the
    /// first `loadNote`.
    func scrollToHeading(_ index: Int) {
        guard let session else { return }
        guard isEditorReady else {
            pendingHeadingScroll = (session.noteId, index)
            return
        }
        page.deliver(.scrollToHeading(noteId: session.noteId, index: index)) { error in
            if let error { editorLogger.error("scrollToHeading failed: \(error)") }
        }
    }

    /// A heading scroll asked for before the page was ready.
    private var pendingHeadingScroll: (noteId: String, index: Int)?

    /// A `selectRange` asked for before the page was ready (the latest wins); sent after its loadNote.
    private var pendingSelectRange: (noteId: String, anchor: Int, head: Int)?

    private func deliverPendingSelectRange() {
        guard let pending = pendingSelectRange else { return }
        pendingSelectRange = nil
        if session?.noteId == pending.noteId { selectRange(anchor: pending.anchor, head: pending.head) }
    }

    private func deliverPendingHeadingScroll() {
        guard let pending = pendingHeadingScroll else { return }
        pendingHeadingScroll = nil
        if session?.noteId == pending.noteId { scrollToHeading(pending.index) }
    }

    // MARK: - Editor → host

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor (Any?, String?) -> Void
    ) {
        let (reply, error) = handle(body: message.body)
        replyHandler(reply, error)
    }

    /// Decodes a raw `postMessage` body and returns the reply for the JS promise.
    func handle(body: Any) -> (Any?, String?) {
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body),
              let message = try? JSONDecoder().decode(EditorToHostMessage.self, from: data) else {
            editorLogger.error("invalid bridge message: \(String(describing: body), privacy: .private)")
            return (nil, "invalid bridge message")
        }
        guard let reply = handle(message) else { return (nil, nil) }
        do {
            return (try JSONSerialization.jsonObject(with: JSONEncoder().encode(reply)), nil)
        } catch {
            editorLogger.error("could not encode reply: \(error)")
            return (nil, "could not encode reply")
        }
    }

    /// Handles one editor message; returns a reply for `changes`, nil otherwise.
    func handle(_ message: EditorToHostMessage) -> ChangesReply? {
        switch message {
        case .ready(let version):
            if version != EditorBridge.version {
                editorLogger.error("editor bridge version \(version) != host \(EditorBridge.version)")
            }
            isEditorReady = true
            resetDeliveries()
            reloadsWithoutAck = 0
            page.logDiagnostics()
            // A new page has the editor defaults; what differs goes before the note.
            pageSettings = Self.editorDefaults
            editorTagIcons = [:]
            sendEditorSettings()
            page.settleChrome(currentLook)
            refreshTagIcons()
            sendLoadNote()
            deliverPendingHeadingScroll()
            deliverPendingSelectRange()
            if focusWhenReady {
                focusWhenReady = false
                focusEditor()
            }
            return nil

        case let .recoveryText(noteId, baseRevision, text):
            guard !environment.editsFrozen else {
                refusedWhileFrozen = true
                return .needsFullText(currentRevision: 0)
            }
            let retained = recoverySourceSession?.noteId == noteId ? recoverySourceSession : nil
            guard let target = session?.noteId == noteId ? session : (retained ?? environment.existingSession(for: noteId)) else {
                status.recoveryError = "Unsaved text could not be saved. Keep this note open, retry, or choose to discard the text."
                return .needsFullText(currentRevision: 0)
            }
            do {
                let source = try environment.store.note(id: noteId)
                if source == nil, let access = environment.vault.access {
                    let result = try access.preserveBrowserRecovery(noteId: noteId, text: text, baseRevision: baseRevision, now: .now)
                    if result.created { environment.reportConflictCopy(result.note.id) }
                } else {
                    let result = try target.preserveBrowserRecoveryResult(text: text, baseRevision: baseRevision)
                    if result.created, environment.existingSession(for: noteId) !== target {
                        environment.reportConflictCopy(result.note.id)
                    }
                }
                status.recoveryError = nil
                return .acked(revision: baseRevision)
            } catch {
                status.isEditable = false
                status.recoveryError = "Editing paused because unsaved text could not be preserved. Keep this note open and retry after resolving the storage or unlock problem."
                environment.logSessionFailure("browser recovery could not be preserved; reload blocked", noteId: noteId,
                                              keyed: environment.isKeyedSession(target), error: error)
                return .needsFullText(currentRevision: target.revision)
            }

        case let .changes(noteId, txId, baseRevision, _, changeSet):
            // Changes typed just before a note switch still reach that note's (cached) session.
            let target = session?.noteId == noteId ? session : environment.existingSession(for: noteId)
            guard let target else {
                editorLogger.error("changes for unknown note \(noteId, privacy: .public)")
                return .needsFullText(currentRevision: 0)
            }
            // A restore holds all writes of all windows: nothing reaches a session or a journal.
            if environment.editsFrozen {
                refusedWhileFrozen = true
                return .needsFullText(currentRevision: target.revision)
            }
            // A note loaded read-only is never edited from the page, whatever the page sends.
            if readOnlyLoaded.contains(noteId) {
                editorLogger.error("changes \(txId, privacy: .public) for read-only note \(noteId, privacy: .public) refused")
                if target === session { requestReload(reason: "changes for a read-only note") }
                return .needsFullText(currentRevision: target.revision)
            }
            // Posted before the page handled a pending loadNote/applyExternalChange: its base
            // revision may name a different document (e.g. the editor's own edit r -> r+1 vs. an
            // adopted external change r -> r+1), so never apply it.
            // Also for the note this editor just switched away from: its deliveries stay counted
            // until the page handled them.
            if let pending = pendingDeliveries[noteId] {
                if target === session, pending.loads == 0 {
                    // The editor will reject the external change (its revision moved on); reload now.
                    requestReload(reason: "changes \(txId) raced an external change")
                }
                return .needsFullText(currentRevision: target.revision)
            }
            // Applied, then forwarded to every other editor showing the note (never back to this one).
            let result = target.apply(
                txId: txId, baseRevision: baseRevision, changeSet: changeSet,
                origin: target === session ? listenerToken : nil
            )
            guard target === session else { return ChangesReply(result) }
            switch result {
            case .acked:
                reloadsWithoutAck = 0
                changedSinceChecksum = true
            case .duplicate:
                break
            case .needsFullText(let current):
                // current < baseRevision means the host is behind (an earlier tx will be resent);
                // the client retries that case itself and reports an error if it gives up.
                if current >= baseRevision {
                    requestReload(reason: "needsFullText for tx \(txId) (host \(current), base \(baseRevision))")
                }
            }
            return ChangesReply(result)

        case let .checksum(requestId, noteId, sha256):
            checksumRequests.removeValue(forKey: requestId)?(noteId, sha256)
            return nil

        case .frozenForClose(let reply):
            frozenForClose(reply)
            return nil

        case .scrollChanged: return nil

        case let .selectionChanged(noteId, anchor, head):
            lastSelection[noteId] = SelectionRange(anchor: anchor, head: head)
            if session?.noteId == noteId { status.selection = lastSelection[noteId] }
            return nil

        case let .error(message, stack):
            if message.hasPrefix("Reload blocked:") {
                status.recoveryError = "Editing paused because unsaved text could not be preserved. Keep this note open and retry after resolving the storage or unlock problem."
                return nil
            }
            editorLogger.error("editor error: \(message, privacy: .private)\n\(stack ?? "", privacy: .private)")
            requestReload(reason: "editor error")
            return nil

        case .headingMenu(let request):
            blockMenus.showHeadingMenu(request)
            return nil

        case .tableMenu(let request):
            blockMenus.showTableMenu(request)
            return nil

        case .calloutMenu(let request):
            blockMenus.showCalloutMenu(request)
            return nil

        case let .foldState(noteId, folds):
            // Only the shown note's folds: a post that raced a note switch is dropped.
            guard session?.noteId == noteId else { return nil }
            do {
                try environment.store.setFoldState(noteId: noteId, folds)
            } catch {
                editorLogger.error("could not store folds of \(noteId, privacy: .public): \(error)")
            }
            return nil

        case let .formatState(noteId, state):
            if session?.noteId == noteId { status.formatState = state }
            return nil

        case .openLink(let request):
            // Only links of the note this editor shows (not the placeholder, not a stale page).
            if let session, session.noteId == request.noteId { onOpenLink?(request) }
            return nil

        case .editLinkRequest(let request):
            if let session, session.noteId == request.noteId, status.isEditable { onEditLink?(request) }
            return nil

        case let .insertAttachments(noteId, insertId, items):
            attachments.insert(items, insertId: insertId, noteId: noteId)
            return nil

        case let .pasteAttachments(noteId, insertId, sourceNoteId, text, items):
            attachments.paste(text: text, items: items, from: sourceNoteId, insertId: insertId, noteId: noteId)
            return nil

        case let .attachmentsRefused(noteId, filenames):
            attachments.refused(filenames, noteId: noteId)
            return nil

        case let .cutAttachments(noteId, filenames):
            attachments.copied(filenames, noteId: noteId)
            return nil

        case let .quickLook(noteId, filename):
            attachments.showQuickLook(noteId: noteId, filename: filename)
            return nil

        case let .attachmentTap(noteId, filename, _, _, _):
            attachments.showQuickLook(noteId: noteId, filename: filename)
            return nil

        case let .attachmentMenu(noteId, filename, from, to, source):
            attachments.showMenu(for: .init(noteId: noteId, filename: filename, from: from, to: to, source: source))
            return nil

        case .copyText(let text, let html):
            // Copy Code (plain text) and Copy Table As; also from read-only notes. Copy Table As
            // HTML adds the `html` flavour, so a plain paste gets the source and a rich paste the
            // table. clearContents drops whatever flavours the last copy left.
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            if let html { pasteboard.setString(html, forType: .html) }
            return nil

        case .requestCompletions(let request):
            answerCompletions(request)
            return nil
        }
    }

    // MARK: - Autocomplete (M3 Task 7)

    /// Answers off the main actor (note titles are scored in Swift); a newer request cancels the
    /// pending answer, and the editor ignores any answer but its latest anyway. Requests for a
    /// note this editor does not show, or with the setting off, get an empty answer.
    private func answerCompletions(_ request: CompletionRequest) {
        completionAnswer?.cancel()
        guard autocomplete, let session, session.noteId == request.noteId else {
            completionAnswer = nil
            deliverCompletions(request.requestId, [])
            return
        }
        let provider = completions
        // The live text: the note's own headings (`[[/`) as typed, not as last committed.
        let text = request.kind == .heading ? session.text : nil
        let revision = session.revision
        completionAnswer = Task { [weak self] in
            // A child task off the main actor: cancelling the answer stops the scoring loop.
            let items = await withTaskGroup(of: [CompletionItem].self) { group in
                group.addTask(priority: .userInitiated) {
                    do {
                        return try provider.items(
                            kind: request.kind, query: request.query, noteTitle: request.noteTitle,
                            sourceNoteId: request.noteId, sourceText: text, sourceRevision: revision
                        )
                    } catch is CancellationError {
                        return []
                    } catch {
                        editorLogger.error("completions (\(request.kind.rawValue, privacy: .public)) failed: \(error)")
                        return []
                    }
                }
                return await group.next() ?? []
            }
            guard let self, !Task.isCancelled else { return }
            self.deliverCompletions(request.requestId, items)
        }
    }

    /// A database change notification: cached note titles may be stale, TagCons may differ.
    func databaseDidChange() {
        completions.invalidateCaches()
        refreshTagIcons()
    }

    private func deliverCompletions(_ requestId: String, _ items: [CompletionItem]) {
        guard isEditorReady else { return }
        page.deliver(.completionResults(requestId: requestId, items: items)) { error in
            if let error { editorLogger.error("completionResults failed: \(error)") }
        }
    }

    /// Sends the TagCon map when it differs from the page's (on `ready` and after database
    /// changes: tags added, renamed, icons picked).
    func refreshTagIcons() {
        guard isEditorReady else { return }
        let icons: [String: String]
        do {
            icons = try completions.tagIconMap()
        } catch {
            editorLogger.error("tag icons unreadable: \(error)")
            return
        }
        guard icons != editorTagIcons else { return }
        editorTagIcons = icons
        page.deliver(.tagIcons(icons)) { error in
            if let error { editorLogger.error("tagIcons failed: \(error)") }
        }
    }

    // MARK: - Host → editor

    private static func editorSettings(from snapshot: TheoNotesCore.Settings.Snapshot) -> EditorSettings {
        EditorSettings(
            hideMarkdown: snapshot.hideMarkdown, autoSortTodos: snapshot.autoSortTodos,
            showHeadingLevels: snapshot.showHeadingLevels, autocomplete: snapshot.autocomplete,
            typewriterMode: snapshot.typewriterMode
        )
    }

    /// A settings snapshot: the stored toggles. The editor's look (typography, theme, appearance,
    /// Reduce Motion; `setEditorLook`) is not in the snapshot and stays as it is.
    private func settingsChanged(_ settings: EditorSettings) {
        var next = settings
        next.typography = editorSettings.typography
        next.theme = editorSettings.theme
        next.appearance = editorSettings.appearance
        next.reduceMotion = editorSettings.reduceMotion
        guard next != editorSettings else { return }
        editorSettings = next
        sendEditorSettings()
    }

    /// The stored editor zoom (View ▸ Zoom), snapped to a step, as the web view's page zoom.
    private func zoomChanged(_ zoom: Double) {
        let next = EditorZoom.snap(zoom)
        if webView.pageZoom != next { webView.pageZoom = next }
    }

    /// The resolved look (`AppearanceController`): the editor's look plus the web view's under-page colour (the
    /// theme's background, so overscroll and the moment before the page paints are not white).
    func setEditorLook(_ look: EditorLook) {
        webView.underPageBackgroundColor = NSColor(look.background)
        currentLook = look
        // The next load (a new window's page, a reload after the web process ended) boots in this look.
        Self.installBootScript(look, in: webView)
        setEditorLook(
            typography: look.typography, theme: look.theme, appearance: look.appearance, reduceMotion: look.reduceMotion)
        if isEditorReady { page.settleChrome(look) }
    }

    /// The document-start script that paints the page in `look` before the editor has its `setSettings`
    /// (`EditorBoot`). Replaced on every change of the look; this web view has no other user scripts.
    static func installBootScript(_ look: EditorLook, in webView: WKWebView) {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(
            WKUserScript(
                source: EditorBoot.bootScript(for: look), injectionTime: .atDocumentStart, forMainFrameOnly: true,
                in: .page))
    }

    /// The editor's look (M7 Task 7 feeds it from the resolved theme and the system): sent as
    /// `setSettings` when it differs from the page's. `theme` is `Theme.editorVariables` (built
    /// once per theme); the bridge encoding passes it through `ThemeSchema.sanitize`.
    func setEditorLook(
        typography: EditorTypography?, theme: [String: String]?, appearance: EditorAppearance?, reduceMotion: Bool?
    ) {
        var next = editorSettings
        next.typography = typography
        next.theme = theme
        next.appearance = appearance
        next.reduceMotion = reduceMotion
        guard next != editorSettings else { return }
        editorSettings = next
        sendEditorSettings()
    }

    /// Sends the settings that differ from the page's; applied in place (no reload).
    private func sendEditorSettings() {
        guard isEditorReady else { return }
        var diff = EditorSettings()
        if editorSettings.hideMarkdown != pageSettings.hideMarkdown { diff.hideMarkdown = editorSettings.hideMarkdown }
        if editorSettings.autoSortTodos != pageSettings.autoSortTodos { diff.autoSortTodos = editorSettings.autoSortTodos }
        if editorSettings.showHeadingLevels != pageSettings.showHeadingLevels {
            diff.showHeadingLevels = editorSettings.showHeadingLevels
        }
        if editorSettings.autocomplete != pageSettings.autocomplete { diff.autocomplete = editorSettings.autocomplete }
        if editorSettings.typewriterMode != pageSettings.typewriterMode { diff.typewriterMode = editorSettings.typewriterMode }
        // The look: nil is the editor's default (light, motion on, default typography and theme).
        if editorSettings.typography != pageSettings.typography {
            diff.typography = editorSettings.typography ?? EditorTypography()
            // The bridge encoding drops these (the editor would reject the whole message).
            for font in diff.typography?.invalidFonts ?? [] {
                editorLogger.error("font dropped: \(font.field, privacy: .public) is not a valid family name (\(font.length) UTF-16 units)")
            }
        }
        if editorSettings.theme != pageSettings.theme { diff.theme = editorSettings.theme ?? [:] }
        let appearance = editorSettings.appearance ?? .light
        if appearance != (pageSettings.appearance ?? .light) { diff.appearance = appearance }
        let reduceMotion = editorSettings.reduceMotion ?? false
        if reduceMotion != (pageSettings.reduceMotion ?? false) { diff.reduceMotion = reduceMotion }
        guard diff != EditorSettings() else { return }
        pageSettings = editorSettings
        page.deliver(.setSettings(diff)) { error in
            if let error { editorLogger.error("setSettings failed: \(error)") }
        }
    }

    private func sendLoadNote() {
        discardDocumentGeneration &+= 1
        guard isEditorReady, let session else { return }
        // A loadNote replaces the document the freeze was about.
        settleFreeze(nil)
        let noteId = session.noteId
        let readOnly: Bool
        do {
            let note = try environment.store.note(id: noteId)
            // Trash and Archive notes are not editable (spec §4.9). A locked note has a session only
            // while the vault is unlocked, and then it edits like any other.
            readOnly = note.map { $0.isReadOnly || ($0.isLocked && !environment.vault.isUnlocked) || $0.location != .notes } ?? false
        } catch {
            editorLogger.error("could not read note \(noteId, privacy: .public): \(error)")
            readOnly = false
        }
        status.isEditable = !readOnly
        status.showsNote = true
        if readOnly { readOnlyLoaded.insert(noteId) } else { readOnlyLoaded.remove(noteId) }
        let folds: [FoldEntry]
        do {
            folds = try environment.store.foldState(noteId: noteId)
        } catch {
            editorLogger.error("could not read folds of \(noteId, privacy: .public): \(error)")
            folds = []
        }
        let message = HostToEditorMessage.loadNote(
            noteId: noteId, text: session.text, revision: session.revision, readOnly: readOnly,
            selection: lastSelection[noteId], foldState: folds.isEmpty ? nil : folds
        )
        deliver(message, noteId: noteId, counter: \.loads) { error in
            editorLogger.error("loadNote failed: \(error)")
        }
        deliverPendingFind()
    }

    /// Delivers a message counted in `pendingDeliveries` until the page handled it.
    private func deliver(
        _ message: HostToEditorMessage, noteId: String, counter: WritableKeyPath<PendingDeliveries, Int>,
        onError: @escaping @MainActor (Error) -> Void
    ) {
        pendingDeliveries[noteId, default: PendingDeliveries()][keyPath: counter] += 1
        let generation = deliveryGeneration
        page.deliver(message) { [weak self] error in
            guard let self else { return }
            if generation == self.deliveryGeneration, var pending = self.pendingDeliveries[noteId] {
                pending[keyPath: counter] -= 1
                self.pendingDeliveries[noteId] = pending == PendingDeliveries() ? nil : pending
            }
            if error == nil, generation == self.deliveryGeneration, case .loadNote = message {
                self.recoverySourceSession = nil
            }
            if let error { onError(error) }
        }
    }

    private func resetDeliveries() {
        // Every caller is about to load or has replaced the page: the freeze is gone with it.
        settleFreeze(nil)
        pendingDeliveries.removeAll()
        deliveryGeneration += 1
    }

    private func requestReload(reason: String) {
        guard isEditorReady, let session, (pendingDeliveries[session.noteId]?.loads ?? 0) == 0 else { return }
        guard reloadsWithoutAck < Self.maxReloadsWithoutAck else {
            editorLogger.fault("not reloading note \(session.noteId, privacy: .public) again (\(reason, privacy: .public)): \(self.reloadsWithoutAck) reloads without an ack")
            return
        }
        reloadsWithoutAck += 1
        editorLogger.notice("reloading note \(session.noteId, privacy: .public): \(reason, privacy: .public)")
        sendLoadNote()
    }

    private func sendExternalChange(_ changeSet: ChangeSet, for session: NoteSession) {
        guard isEditorReady else { return } // the loadNote sent on ready carries the new text
        changedSinceChecksum = true
        let message = HostToEditorMessage.applyExternalChange(
            noteId: session.noteId, revision: session.revision, changeSet: changeSet
        )
        deliver(message, noteId: session.noteId, counter: \.externalChanges) { [weak self] error in
            editorLogger.error("applyExternalChange failed: \(error)")
            self?.requestReload(reason: "applyExternalChange failed")
        }
    }

    private func flush(_ session: NoteSession) {
        do {
            try session.flush()
        } catch {
            environment.logSessionFailure(
                "flush failed", noteId: session.noteId, keyed: environment.isKeyedSession(session), error: error)
        }
    }

    // MARK: - Navigation

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(navigationPolicy(
            for: navigationAction.request.url,
            isUserLinkInMainFrame: navigationAction.navigationType == .linkActivated
                && navigationAction.targetFrame?.isMainFrame != false
        ))
    }

    /// Only the bundled editor loads. A clicked http(s) link (main frame or new window) opens in
    /// the browser; script-driven, refresh and subframe navigations are cancelled silently.
    private func navigationPolicy(for url: URL?, isUserLinkInMainFrame: Bool) -> WKNavigationActionPolicy {
        guard let url else { return .cancel }
        let scheme = url.scheme?.lowercased()
        // Only the editor page itself; attachment URLs never load as a page or frame.
        if scheme == AssetSchemeHandler.scheme, url.host?.lowercased() == AssetSchemeHandler.host {
            return .allow
        }
        if isUserLinkInMainFrame, scheme == "http" || scheme == "https" {
            openExternally(url)
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        (page as? WebKitEditorPage)?.navigationEnded(navigation, committed: true)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        (page as? WebKitEditorPage)?.navigationEnded(navigation, committed: false)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        (page as? WebKitEditorPage)?.navigationEnded(navigation, committed: false)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        handleWebContentTermination()
    }

    /// Test hook: what the web view's process-termination callback does.
    func simulateWebContentTermination() {
        handleWebContentTermination()
    }

    private func handleWebContentTermination() {
        discardDocumentGeneration &+= 1
        editorLogger.error("editor web content process terminated; reloading")
        isEditorReady = false
        status.isEditable = false
        status.showsNote = false
        resetDeliveries()
        let unanswered = checksumRequests.values
        checksumRequests.removeAll()
        unanswered.forEach { $0(nil, nil) }
        page.loadBundle() // `ready` then re-sends loadNote with the session's acked text
    }
}

/// Breaks the retain cycle userContentController → handler → web view.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var target: EditorBridgeController?

    init(_ target: EditorBridgeController) {
        self.target = target
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor (Any?, String?) -> Void
    ) {
        guard let target else { return replyHandler(nil, "editor host is gone") }
        target.userContentController(userContentController, didReceive: message, replyHandler: replyHandler)
    }
}

@MainActor
final class WebKitEditorPage: EditorPage {
    private unowned var webView: WKWebView
    /// The navigation of the latest `reloadBundle` and who waits for its outcome.
    private var reloadNavigation: WKNavigation?
    private var reloadWaiters: [@MainActor (Bool) -> Void] = []

    init(webView: WKWebView) {
        self.webView = webView
    }

    func loadBundle() {
        webView.load(URLRequest(url: AssetSchemeHandler.indexURL))
    }

    func reloadBundle(committed: @escaping @MainActor (Bool) -> Void) {
        // A newer reload supersedes an older one: its document is as clean, so both wait on it.
        reloadWaiters.append(committed)
        reloadNavigation = webView.load(URLRequest(url: AssetSchemeHandler.indexURL))
    }

    func use(webView: WKWebView) {
        self.webView = webView
        reloadNavigation = nil
        reloadWaiters = []
    }

    func navigationEnded(_ navigation: WKNavigation?, committed: Bool) {
        guard let navigation, navigation === reloadNavigation else { return }
        reloadNavigation = nil
        let waiters = reloadWaiters
        reloadWaiters = []
        waiters.forEach { $0(committed) }
    }

    func deliver(_ message: HostToEditorMessage, completion: @escaping @MainActor (Error?) -> Void) {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(message))
        } catch {
            return completion(error)
        }
        webView.callAsyncJavaScript(
            "return await window.__baerchen.receive(msg)", arguments: ["msg": json], in: nil, in: .page
        ) { result in
            if case .failure(let error) = result { completion(error) } else { completion(nil) }
        }
    }

    func settleChrome(_ look: EditorLook) {
        webView.evaluateJavaScript(EditorBoot.settleScript(for: look)) { _, error in
            if let error { editorLogger.error("settleChrome failed: \(error)") }
        }
    }

    func logDiagnostics() {
        #if DEBUG
        webView.evaluateJavaScript(
            "JSON.stringify({ isSecureContext: window.isSecureContext, subtle: typeof crypto.subtle, origin: location.origin })"
        ) { result, error in
            let detail = error.map { "\($0)" } ?? String(describing: result ?? "nil")
            editorLogger.notice("editor environment: \(detail, privacy: .public)")
        }
        #endif
    }
}
