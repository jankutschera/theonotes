// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import CryptoKit
import Observation
import SwiftUI
import WebKit
import ImageIO

enum MobileEditorDrainError: LocalizedError, Equatable {
    case unavailable, busy, timeout, composing, mismatch
    var errorDescription: String? { "The open note is still saving. Try again." }
}

struct MobileAttachmentInsertionOrigin {
    fileprivate let id = UUID()
    fileprivate let editor: ObjectIdentifier
    fileprivate let session: ObjectIdentifier
    let noteID: String
    fileprivate let documentLoad: Int
    fileprivate let libraryGeneration: Int
    fileprivate let revision: Int
    fileprivate let selection: SelectionRange
    let locked: Bool
    fileprivate let access: ObjectIdentifier?
}

struct MobileAttachmentEditOrigin: @unchecked Sendable {
    fileprivate let id: UUID
    fileprivate let binding: MobileAttachmentInsertionOrigin
    let target: MobileAttachmentTarget
    let plaintextSHA256: String
    fileprivate let persistedRevision: Int
    fileprivate let readGeneration: Int
    let isEditableSketch: Bool
    var noteID: String { binding.noteID }
}

struct MobileAttachmentEditInspection: Sendable {
    // Origin is main-actor-owned metadata; it never contains keys or temporary plaintext paths.
    let origin: MobileAttachmentEditOrigin
    let bytes: Data
    let drawingData: Data?
    let canvasSize: CGSize?
    var isEditableSketch: Bool { drawingData != nil }
}

enum MobileAttachmentEditMode: Equatable, Sendable { case sketch, crop }
enum MobileAttachmentEditFailure: Error, LocalizedError {
    case editableSketchCannotBeCropped, unconfirmed
    var errorDescription: String? {
        switch self {
        case .editableSketchCannotBeCropped: "This image contains an editable sketch. Open the sketch editor to preserve its drawing."
        case .unconfirmed: "The attachment change could not be confirmed. The original file is retained. Keep this draft open or explicitly cancel it before checking the note; another save with this origin is blocked to avoid duplicates."
        }
    }
}

private struct MobileAttachmentEditRead: Sendable {
    let bytes: Data
    let hash: String
    let drawingData: Data?
    let canvasSize: CGSize?
}

/// UIKit host for the shared editor. Only NoteSession may acknowledge a transaction.
@MainActor @Observable
final class MobileEditor: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    static let deliveryFailureMessage = "The editor could not receive an update. Unsaved text may still be in this note. Keep it open and tap Retry."
    static let recoveryBlockedMessage = "Unsaved editor text could not be preserved. Keep this note open, unlock your notes if needed, and tap Retry."
    static let recoveryLimitMessage = "Editing stopped after repeated errors. Unsaved text may still be in this note. Keep it open and tap Retry."
    static let invalidatedSessionMessage = "This editor session has closed. Your unsaved text remains visible. Select and copy it before closing this note."
    static let protectionMismatchMessage = "This note's protection changed. Editing is paused. Unlock it if needed, then tap Retry; keep this editor open until your text is saved."
    private(set) var webView: WKWebView
    private let library: MobileLibrary
    private let attachments: AttachmentStore
    private let completions: CompletionProvider
    private(set) var session: NoteSession?
    private(set) var ready = false
    private var pageHasOfferedEditing = false
    private var previousWebContentProcessTerminated = false
    /// An unready live page that once offered editing is NOT evidence of a clean page.
    /// Only a fresh never-editable page or an explicitly terminated process can be skipped.
    /// Termination cannot recover JS edits never sent before the crash; native journalled
    /// edits remain authoritative and must be flushed before any shared mutation.
    var canDrainUnreadyNativeSession: Bool {
        !ready && (!pageHasOfferedEditing || previousWebContentProcessTerminated) &&
        pending == 0 && pendingCommands == 0 && closeBarrier == nil && !closeGuardActive && deferredCloseChanges.isEmpty
    }
    func drainUnreadyNativeSession() throws {
        guard canDrainUnreadyNativeSession else { throw MobileEditorDrainError.unavailable }
        try session?.flush()
    }
    private(set) var editable = false
    private(set) var readOnlyReason: String?
    private(set) var canShare = false
    private(set) var canExport = false
    private var pageAllowsExport = true
    var attachmentTarget: MobileAttachmentTarget?
    var attachmentTapTarget: MobileAttachmentTarget?
    private(set) var formatState: FormatState?
    private(set) var hasSelection = false
    var previewURL: URL?
    /// The theme's page colour, so the editor column behind the bars matches the page.
    private(set) var pageBackground: Color?
    var linkRequest: EditLinkRequest?
    var headingMenu: HeadingMenuRequest?
    var tableMenu: TableMenuRequest?
    var calloutMenu: CalloutMenuRequest?
    var onOpenNote: ((String) -> Void)?
    var onOpenNoteInNewWindow: ((String) -> Void)?
    /// Bound once by the scene host. Standalone/automation editors retain legacy behavior.
    var sceneNavigation: MobileSceneNavigation?
    var isClosedForPrivacy: Bool { privacyClosed }
    private var selectedNoteID: String? {
        if let sceneNavigation { return sceneNavigation.selectedID }
        return library.selectedID
    }
    private var listener: NoteSession.ListenerToken?
    private var hasStarted = false
    private var privacyClosed = false
    private var pendingOpenRecordID: String?
    private var pending = 0
    private var pendingCommands = 0
    private var attachmentInsertionOriginID: UUID?
    private var attachmentEditOriginID: UUID?
    private var attachmentEditUnconfirmedID: UUID?
    private var attachmentEditCommandInFlight = false
    private var attachmentReadGeneration = 0
    private struct AttachmentWork {
        let barrier: Task<Void, Never>
        let cancel: @Sendable () -> Void
    }
    private var attachmentWork: [UUID: AttachmentWork] = [:]
    @ObservationIgnored var beforeAttachmentRead: (@Sendable () async throws -> Void)?
    private var retainedAttachmentNoteID: String?
    private var generation = 0
    @ObservationIgnored private(set) var documentLoadGeneration = 0
    private final class CloseBarrier {
        let requestId = UUID().uuidString
        let noteID: String
        var continuation: CheckedContinuation<FrozenForClose?, Never>?
        var timer: Task<Void, Never>?
        init(_ noteID: String) { self.noteID = noteID }
    }
    private var closeBarrier: CloseBarrier?
    private var closeGuardActive = false
    /// Set only after the page has frozen, acknowledged every edit, and matched the native hash.
    private var verifiedCloseNoteID: String?
    private var recoveredReplacementNoteID: String?
    private var privacyRecoveryPermit: (noteID: String, deadline: Date, switching: Bool)?
    /// The page's text was committed as a recovery copy for this note and loaded document (N16).
    private var committedRecovery: (noteID: String, generation: Int)?
    private var protectionTransitionInFlight = false
    static func privacyRecoveryCanStart(deadline: Date, now: Date = .now) -> Bool {
        now.addingTimeInterval(0.3) < deadline
    }
    private var canReplaceCurrentPage: Bool {
        guard let id = session?.noteId else { return true }
        if !ready { return canDrainUnreadyNativeSession }
        return (closeGuardActive && closeBarrier == nil && verifiedCloseNoteID == id) || recoveredReplacementNoteID == id
    }
    private var deferredCloseChanges: [(noteID: String, revision: Int, change: ChangeSet)] = []
    private var recoveryAttempts = 0
    private var checksumTask: Task<Void, Never>?
    private var checksum: (id: String, noteID: String, revision: Int)?
    // Caret offsets change on every keystroke. Only the empty/nonempty transition affects
    // native menu availability; observing the raw range would rebuild the entire shell.
    @ObservationIgnored private var selection: SelectionRange?
    private var scrollTop: Double?
    private var pendingHeading: (noteID: String, index: Int)?
    private static let indexURL = AssetSchemeHandler.indexURL.appending(queryItems: [URLQueryItem(name: "platform", value: "ios")])

    init(library: MobileLibrary) {
        self.library = library
        attachments = AttachmentStore(paths: library.paths, database: library.database)
        completions = CompletionProvider(db: library.database)
        webView = Self.makeWebView(library: library, attachments: attachments)
        super.init()
        library.registerEditor(self)
        bindPage()
        checksumTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
                guard let self, ready, pending == 0, let session else { continue }
                let id = UUID().uuidString
                checksum = (id, session.noteId, session.revision)
                send(.requestChecksum(requestId: id))
            }
        }
    }

    private static func makeWebView(library: MobileLibrary, attachments: AttachmentStore) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(AssetSchemeHandler(attachments: attachments, thumbnails: Thumbnails(paths: library.paths),
            privateAttachment: { [weak library] id, filename in try? library?.attachmentURL(filename, noteID: id) }),
                                  forURLScheme: AssetSchemeHandler.scheme)
        config.writingToolsBehavior = .complete
        let page = WKWebView(frame: .zero, configuration: config)
        page.isOpaque = false
        page.backgroundColor = .systemBackground
        page.scrollView.isScrollEnabled = false
        hideFormAccessoryBar(in: page)
        #if DEBUG
        page.isInspectable = true
        #endif
        return page
    }

    /// WebKit's form bar (previous, next, done) sat above the keyboard on top of our editor bar.
    /// The page's content view is the scroll view's text-input subview; a runtime subclass of it returns no
    /// accessory view. Public runtime calls only, no private class or selector names.
    private static func hideFormAccessoryBar(in page: WKWebView) {
        guard let content = page.scrollView.subviews.first(where: { $0 is any UITextInput }) else { return }
        let base: AnyClass = type(of: content)
        let name = "NoFormAccessory_" + NSStringFromClass(base)
        if let existing = NSClassFromString(name) { object_setClass(content, existing); return }
        guard let made = objc_allocateClassPair(base, name, 0),
              let getter = class_getInstanceMethod(UIResponder.self, #selector(getter: UIResponder.inputAccessoryView)) else { return }
        let none: @convention(block) (AnyObject) -> UIView? = { _ in nil }
        class_addMethod(made, #selector(getter: UIResponder.inputAccessoryView), imp_implementationWithBlock(none), method_getTypeEncoding(getter))
        objc_registerClassPair(made)
        object_setClass(content, made)
    }

    /// iPad: WebKit puts its previous/next field arrows at the trailing end of the keyboard's shortcut bar, dead in a one-field
    /// editor (design r3). WebKit sets them again whenever the page gains focus, so the keyboard notifications call this; the
    /// leading undo, redo and paste stay.
    func clearShortcutBarArrows() {
        webView.inputAssistantItem.trailingBarButtonGroups = []
    }

    private func bindPage() {
        webView.configuration.userContentController.addScriptMessageHandler(WeakMobileHandler(self), contentWorld: .page, name: "bridge")
        webView.navigationDelegate = self
    }

    /// copyText has no note ID. Retire its entire origin on note/protection changes so a
    /// queued callback from a protected page can never acquire a later note's permission.
    private func replacePage(allowsExport: Bool) {
        settleCloseBarrier(nil)
        let old = webView
        let host = old.superview as? MobileWebViewContainer
        old.endEditing(true); old.stopLoading()
        old.configuration.userContentController.removeAllScriptMessageHandlers()
        old.navigationDelegate = nil
        old.removeFromSuperview()
        old.loadHTMLString("", baseURL: nil)
        webView = Self.makeWebView(library: library, attachments: attachments)
        pageAllowsExport = allowsExport
        ready = false; editable = false; canShare = false; canExport = false
        pageHasOfferedEditing = false; previousWebContentProcessTerminated = false
        generation += 1; pending = 0; pendingCommands = 0; checksum = nil; hasStarted = false
        bindPage()
        host?.attach(self)
        start()
    }

    isolated deinit {
        for work in attachmentWork.values { work.cancel() }
        if let retainedAttachmentNoteID { library.store.retention.release(retainedAttachmentNoteID) }
        checksumTask?.cancel()
        if let listener { session?.removeListener(listener) }
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    /// Detach the old WebKit page before revoking access. The parent replaces this editor with
    /// a fresh nonpersistent WebView, so private text and undo history cannot be reopened.
    func closeForPrivacy(confirmedResetInvalidatedID: String? = nil) throws {
        cancelAttachmentReads()
        settleCloseBarrier(nil)
        defer {
            privacyClosed = true
            checksumTask?.cancel(); checksumTask = nil
            if let listener { session?.removeListener(listener) }
            if let retainedAttachmentNoteID { library.store.retention.release(retainedAttachmentNoteID) }
            retainedAttachmentNoteID = nil
            listener = nil; session = nil; ready = false; editable = false; canShare = false; canExport = false
            attachmentTarget = nil; attachmentTapTarget = nil; formatState = nil; hasSelection = false
            previewURL = nil; linkRequest = nil; headingMenu = nil; tableMenu = nil; calloutMenu = nil; selection = nil; checksum = nil
            completions.invalidateCaches()
            webView.endEditing(true)
            webView.stopLoading()
            webView.configuration.userContentController.removeAllScriptMessageHandlers()
            webView.navigationDelegate = nil
            webView.loadHTMLString("", baseURL: nil)
        }
        if let session, session.isInvalidated, confirmedResetInvalidatedID == session.noteId { return }
        try session?.flush()
    }

    /// Only called by the explicit destructive confirmation for this exact browser document.
    func discardBrowserTextAfterConfirmation(noteID: String, pageID: ObjectIdentifier, documentGeneration: Int) -> Bool {
        guard !privacyClosed, session?.noteId == noteID, ObjectIdentifier(webView) == pageID,
              documentLoadGeneration == documentGeneration else { return false }
        try? closeForPrivacy()
        return privacyClosed
    }

    /// Start the page only for the retained editor, when its first note/view is attached.
    /// SwiftUI may construct and discard initial @State values before mounting the view.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        let dark = webView.traitCollection.userInterfaceStyle == .dark
        let theme = library.preferences.theme(dark: dark, increasedContrast: UIAccessibility.isDarkerSystemColorsEnabled)
        installBoot(theme: theme)
        if !pageAllowsExport {
            // The shared Copy Code widget has no native command hook. Hide only that
            // app-owned affordance; leave native system text selection untouched.
            let script = "document.addEventListener('DOMContentLoaded',()=>{const s=document.createElement('style');s.textContent='.cm-bc-copy{display:none!important}';document.head.appendChild(s)},{once:true})"
            webView.configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        webView.load(URLRequest(url: Self.indexURL))
    }

    func open(_ id: String) throws {
        guard !privacyClosed else { throw CocoaError(.fileReadNoPermission) }
        if session?.noteId == id, attachmentEditCommandInFlight { return }
        if let current = session?.noteId, current != id, !canReplaceCurrentPage {
            throw MobileEditorDrainError.busy
        }
        attachmentTarget = nil; formatState = nil
        guard session?.noteId != id else { recoveryAttempts = 0; loadNote(); return }
        let next = try library.session(for: id)
        if recoveredReplacementNoteID != session?.noteId { try session?.flush() }
        if let listener { session?.removeListener(listener) }
        let replacingNote = session != nil
        library.store.retention.retain(id)
        if let retainedAttachmentNoteID { library.store.retention.release(retainedAttachmentNoteID) }
        retainedAttachmentNoteID = id
        session = next
        pendingOpenRecordID = id
        let allowsExport = try library.store.note(id: id)?.isLocked == false
        if replacingNote { replacePage(allowsExport: allowsExport) }
        else if hasStarted && pageAllowsExport != allowsExport { replacePage(allowsExport: allowsExport) }
        else { pageAllowsExport = allowsExport; start() }
        let state = try library.store.editorState(noteID: id)
        scrollTop = state.scrollTop
        let pendingCaret: Int?
        if let sceneNavigation { pendingCaret = sceneNavigation.pendingCaret.removeValue(forKey: id) }
        else { pendingCaret = library.pendingCaret.removeValue(forKey: id) }
        selection = pendingCaret.map { SelectionRange(anchor: $0, head: $0) } ?? state.selection
        hasSelection = selection.map { $0.anchor != $0.head } ?? false
        recoveryAttempts = 0
        listener = next.addTextListener { [weak self] _, change in
            guard let self, let session = self.session else { return }
            if self.closeGuardActive {
                self.deferredCloseChanges.append((session.noteId, session.revision, change))
                self.settleCloseBarrier(nil)
                return
            }
            send(.applyExternalChange(noteId: session.noteId, revision: session.revision, changeSet: change), guardsEdits: true)
        }
        loadNote()
    }

    func loadNote() {
        if stopForInvalidatedSession() { return }
        documentLoadGeneration &+= 1
        settleCloseBarrier(nil)
        guard ready, let session else { return }
        do {
            guard let note = try library.store.note(id: session.noteId) else { return }
            if pageAllowsExport != !note.isLocked || note.isLocked != session.wasOriginallyLocked {
                webView.isUserInteractionEnabled = false
                editable = false
                if note.isLocked != session.wasOriginallyLocked {
                    library.errorMessage = Self.protectionMismatchMessage
                    transitionPageForProtectionChange(noteID: session.noteId)
                    return
                }
                guard canReplaceCurrentPage else {
                    library.errorMessage = Self.protectionMismatchMessage
                    transitionPageForProtectionChange(noteID: session.noteId)
                    return
                }
                replacePage(allowsExport: !note.isLocked)
                return
            }
            webView.isUserInteractionEnabled = true
            canExport = library.canRead(note) && !note.isLocked && !library.appLocked
            editable = library.canRead(note) && !note.isReadOnly && note.location == .notes
            canShare = library.canRead(note)
            if editable { pageHasOfferedEditing = true }
            readOnlyReason = !library.canRead(note) ? "Unlock this note to read it."
                : note.location == .archive ? "Archived note · Restore it from Archive to edit."
                : note.location == .trash ? "Trashed note · Restore it from Trash to edit."
                : note.isReadOnly ? "Read-only note" : nil
            send(.loadNote(noteId: note.id, text: library.canRead(note) ? session.text : "",
                           revision: session.revision, readOnly: !editable, selection: selection, scrollTop: scrollTop, foldState: try library.store.foldState(noteId: note.id)), guardsEdits: true)
            if pendingOpenRecordID == note.id, library.canRead(note) {
                pendingOpenRecordID = nil
                library.recordEditorOpen(noteId: note.id)
            }
        } catch { library.errorMessage = error.localizedDescription }
    }

    private func transitionPageForProtectionChange(noteID: String) {
        guard !protectionTransitionInFlight, !library.appLocked else { return }
        protectionTransitionInFlight = true
        let page = webView
        Task { [weak self] in
            guard let self else { return }
            defer { self.protectionTransitionInFlight = false }
            var frozen: FrozenForClose?
            do { frozen = try await self.prepareCaptureClose(noteID, waitForBusyUntil: .now.addingTimeInterval(2)) }
            catch { /* The browser copy is the fallback when draining cannot finish. */ }
            defer { if let frozen { self.endCaptureClose(frozen) } }
            let preserved: Bool
            if frozen != nil { preserved = true }
            else { preserved = await self.preserveBrowserTextBeforePrivacyClose(deadline: .now.addingTimeInterval(3)) }
            guard preserved, !self.privacyClosed, !self.library.appLocked, !self.library.libraryOperationBusy,
                  self.webView === page, self.session?.noteId == noteID,
                  let current = try? self.library.store.note(id: noteID) else {
                self.library.errorMessage = Self.recoveryBlockedMessage
                return
            }
            // A page swap alone would leave the old session's store and journal bound to the
            // previous protection. Fail closed until a coordinated session rebind is available.
            guard current.isLocked == self.session?.wasOriginallyLocked else {
                self.editable = false
                self.library.errorMessage = Self.protectionMismatchMessage
                return
            }
            self.replacePage(allowsExport: !current.isLocked)
        }
    }

    /// Do not discard a capture until the editor's current document has reached
    /// its journalled session. A failed or unavailable barrier keeps the note.
    func prepareCaptureClose(_ noteID: String, waitForBusyUntil deadline: Date? = nil) async throws -> FrozenForClose {
        guard ready, !privacyClosed, session?.noteId == noteID else { throw MobileEditorDrainError.unavailable }
        while (closeBarrier != nil || closeGuardActive), let deadline, deadline > Date() {
            try await Task.sleep(for: .milliseconds(20))
            guard ready, !privacyClosed, session?.noteId == noteID else { throw MobileEditorDrainError.unavailable }
        }
        guard closeBarrier == nil, !closeGuardActive else { throw MobileEditorDrainError.busy }
        for _ in 0..<150 where pending != 0 || pendingCommands != 0 {
            guard ready, !privacyClosed, session?.noteId == noteID else { throw MobileEditorDrainError.unavailable }
            if let deadline, deadline <= Date() { throw MobileEditorDrainError.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
        if let deadline, deadline <= Date() { throw MobileEditorDrainError.timeout }
        guard pending == 0, pendingCommands == 0, ready, !privacyClosed, session?.noteId == noteID, closeBarrier == nil, !closeGuardActive else {
            throw MobileEditorDrainError.timeout
        }
        let barrier = CloseBarrier(noteID)
        closeGuardActive = true
        let reply: FrozenForClose? = await withCheckedContinuation { continuation in
            barrier.continuation = continuation
            closeBarrier = barrier
            barrier.timer = Task { [weak self] in
                let remaining = deadline.map { max(0, $0.timeIntervalSinceNow) } ?? 3
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled else { return }
                self?.settleCloseBarrier(nil, matching: barrier)
            }
            send(.freezeForClose(requestId: barrier.requestId, noteId: noteID))
        }
        guard let reply else {
            releaseCaptureClose(requestID: barrier.requestId, noteID: noteID)
            throw MobileEditorDrainError.timeout
        }
        guard reply.ok else {
            releaseCaptureClose(requestID: barrier.requestId, noteID: noteID)
            switch reply.reason {
            case .halted, .notShown: throw MobileEditorDrainError.unavailable
            case .composing: throw MobileEditorDrainError.composing
            default: throw MobileEditorDrainError.timeout
            }
        }
        guard let session, session.noteId == noteID, !privacyClosed, pending == 0 else {
            releaseCaptureClose(requestID: barrier.requestId, noteID: noteID)
            throw MobileEditorDrainError.unavailable
        }
        let hash = SHA256.hash(data: Data(session.text.utf8)).map { String(format: "%02x", $0) }.joined()
        guard reply.sha256 == hash else {
            releaseCaptureClose(requestID: barrier.requestId, noteID: noteID)
            throw MobileEditorDrainError.mismatch
        }
        do { try session.flush() }
        catch {
            releaseCaptureClose(requestID: barrier.requestId, noteID: noteID)
            throw error
        }
        verifiedCloseNoteID = noteID
        return reply
    }

    private func settleCloseBarrier(_ reply: FrozenForClose?, matching: CloseBarrier? = nil) {
        guard let barrier = closeBarrier, matching == nil || matching === barrier else { return }
        closeBarrier = nil
        barrier.timer?.cancel()
        barrier.continuation?.resume(returning: reply)
        barrier.continuation = nil
    }

    func endCaptureClose(_ reply: FrozenForClose) {
        releaseCaptureClose(requestID: reply.requestId, noteID: reply.noteId)
    }

    private func releaseCaptureClose(requestID: String, noteID: String) {
        verifiedCloseNoteID = nil
        send(.unfreeze(requestId: requestID, noteId: noteID))
        closeGuardActive = false
        let changes = deferredCloseChanges
        deferredCloseChanges.removeAll()
        for change in changes where session?.noteId == change.noteID {
            send(.applyExternalChange(noteId: change.noteID, revision: change.revision, changeSet: change.change), guardsEdits: true)
        }
    }

    func renderExport(source: String, attachments: [String: String], keepTags: Bool, foreground: String = "#000000") async throws -> MobileRenderedNote {
        guard ready, !privacyClosed, canExport, let id = session?.noteId,
              try library.store.note(id: id)?.isLocked == false else { throw CocoaError(.fileReadNoPermission) }
        let origin = webView
        let access = try MobileExportAccess(library: library, ids: [id])
        let rendered: MobileRenderedNote = try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript("return window.__baerchen.renderNote(source, {attachments, keepTags, foreground})",
                arguments: ["source": source, "attachments": attachments, "keepTags": keepTags, "foreground": foreground], in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    guard let object = value as? [String: String], let html = object["html"], let text = object["text"] else {
                        continuation.resume(throwing: CocoaError(.fileReadCorruptFile)); return
                    }
                    continuation.resume(returning: MobileRenderedNote(html: html, text: text))
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
        guard !privacyClosed, origin === webView else { throw CancellationError() }
        try access.validate()
        return rendered
    }

    /// Selection offsets are UTF-16, matching CodeMirror and the native bridge.
    var selectedText: String? {
        guard canShare, !privacyClosed, let session, let selection else { return nil }
        let source = session.text as NSString
        let lower = min(selection.anchor, selection.head), upper = max(selection.anchor, selection.head)
        guard lower >= 0, upper <= source.length, upper > lower else { return nil }
        return source.substring(with: NSRange(location: lower, length: upper - lower))
    }

    func applySearchHighlights(terms: [String], query: String) {
        guard canShare, !privacyClosed, let session else { return }
        send(.searchHighlight(noteId: session.noteId, query: query, terms: terms))
    }

    func command(_ name: EditorCommandName, args: [String: CommandArgument]? = nil) {
        guard ready, let session, let current = try? library.store.note(id: session.noteId),
              current.isLocked == session.wasOriginallyLocked else { return }
        switch name {
        case .copyTable, .selectAll, .find, .findNext, .findPrevious, .openLink, .toggleFold, .foldAll, .unfoldAll:
            break
        default:
            guard editable else { return }
        }
        if name == .copyTable {
            guard canExport, (try? library.store.note(id: session.noteId)?.isLocked) == false else { return }
        }
        send(.applyCommand(name: name, args: args), tracksCommand: true)
    }

    func setNoteType(_ type: NoteType?) async throws {
        guard !library.appLocked, !library.libraryOperationBusy, !library.isClosed, !library.isClosing,
              let id = session?.noteId, ready, editable,
              let note = try library.store.note(id: id), !note.isLocked, !note.isReadOnly else {
            throw NoteTypeChangeError.unavailable
        }
        let frozen = try await prepareCaptureClose(id)
        var released = false
        defer { if !released { endCaptureClose(frozen) } }
        guard !library.appLocked, !library.libraryOperationBusy, !library.isClosed, !library.isClosing,
              let session, session.noteId == id, ready, editable,
              let current = try library.store.note(id: id), !current.isLocked, !current.isReadOnly else {
            throw NoteTypeChangeError.unavailable
        }
        let old = TextNormalization.normalizeLineEndings(session.text)
        guard let result = NoteTypeText.settingIfEffective(type, in: session.text) else {
            throw NoteTypeChangeError.unfinishedCodeBlock
        }
        let new = TextNormalization.normalizeLineEndings(result)
        endCaptureClose(frozen)
        released = true
        guard let change = NoteTypeText.smallestChange(from: old, to: new) else { return }
        command(.replaceRange, args: ["from": .int(change.from), "to": .int(change.to),
                                       "expect": .string(change.expect), "text": .string(change.text), "keepSelection": .bool(true)])
        for _ in 0..<100 {
            guard self.session?.noteId == id else { throw NoteTypeChangeError.unavailable }
            if TextNormalization.normalizeLineEndings(self.session?.text ?? "") == new { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NoteTypeChangeError.notApplied
    }

    enum NoteTypeChangeError: LocalizedError {
        case unavailable, unfinishedCodeBlock, notApplied
        var errorDescription: String? {
            switch self {
            case .unavailable: "This note cannot be changed right now."
            case .unfinishedCodeBlock: "Close the code block before adding a type."
            case .notApplied: "The note changed while setting its type. Please try again."
            }
        }
    }

    func focusForCallback() {
        guard ready, !privacyClosed, canShare else { return }
        send(.focus)
    }

    func focusForHardwareEditing() {
        guard ready, !privacyClosed, editable else { return }
        webView.becomeFirstResponder()
        send(.focus)
    }

    func appearance(dark: Bool, increasedContrast: Bool = false) {
        let preferences = library.preferences
        let resolved = preferences.theme(dark: dark, increasedContrast: increasedContrast)
        installBoot(theme: resolved)
        let size = preferences.useDynamicType ? Double(UIFontMetrics.default.scaledValue(for: preferences.fontSize)) : preferences.fontSize
        let settings = library.settings
        send(.setSettings(EditorSettings(hideMarkdown: settings.hideMarkdown, autoSortTodos: settings.autoSortTodos,
            showHeadingLevels: settings.showHeadingLevels, autocomplete: settings.autocomplete, typewriterMode: settings.typewriterMode,
            typography: EditorTypography(fontSize: size, lineHeight: preferences.lineHeight,
                lineWidth: preferences.lineWidth, paragraphSpacing: preferences.paragraphSpacing,
                paragraphIndent: preferences.paragraphIndent, fontText: preferences.textFontFamily,
                fontHeading: preferences.headingFontFamily, fontCode: preferences.codeFontFamily), theme: resolved.editorVariables,
            appearance: resolved.appearance == .dark ? .dark : .light, reduceMotion: UIAccessibility.isReduceMotionEnabled)))
        let background = ThemeColor(hex: resolved.editorVariables["--bc-color-bg"] ?? "") ?? resolved.color(.background)
        webView.backgroundColor = UIColor(background.mobileColor)
        pageBackground = background.mobileColor
        if ready { webView.evaluateJavaScript(MobileEditorBoot.script(theme: resolved, boot: false), completionHandler: nil) }
    }

    private func installBoot(theme: Theme) {
        let controller = webView.configuration.userContentController
        let retained = controller.userScripts.filter { !$0.source.hasPrefix(MobileEditorBoot.marker) }
        controller.removeAllUserScripts()
        for script in retained { controller.addUserScript(script) }
        controller.addUserScript(WKUserScript(source: MobileEditorBoot.script(theme: theme, boot: true), injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    func scrollToHeading(_ index: Int) {
        guard let session else { return }
        if ready { send(.scrollToHeading(noteId: session.noteId, index: index)) }
        else { pendingHeading = (session.noteId, index) }
    }

    private func send(_ message: HostToEditorMessage, guardsEdits: Bool = false, tracksCommand: Bool = false) {
        guard ready else { return }
        let currentGeneration = generation
        if guardsEdits { pending += 1 }
        if tracksCommand { pendingCommands += 1 }
        do {
            let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(message))
            webView.callAsyncJavaScript("return await window.__baerchen.receive(msg)", arguments: ["msg": json], in: nil, in: .page) { [weak self] result in
                guard let self, generation == currentGeneration else { return }
                if guardsEdits { pending -= 1 }
                if tracksCommand { pendingCommands -= 1 }
                if case .failure = result {
                    if stopForInvalidatedSession() { return }
                    editable = false
                    library.errorMessage = Self.deliveryFailureMessage
                }
            }
        } catch {
            if guardsEdits { pending -= 1 }
            if tracksCommand { pendingCommands -= 1 }
            if stopForInvalidatedSession() { return }
            library.errorMessage = error.localizedDescription
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        guard !privacyClosed, message.webView === webView, message.frameInfo.isMainFrame,
              message.frameInfo.request.url?.host == AssetSchemeHandler.host,
              message.frameInfo.request.url?.scheme == AssetSchemeHandler.scheme else {
            replyHandler(nil, "Untrusted editor frame"); return
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: message.body)
            let incoming = try JSONDecoder().decode(EditorToHostMessage.self, from: data)
            if case let .recoveryText(id, base, text) = incoming {
                if stopForInvalidatedSession() { replyHandler(nil, "Editor session closed"); return }
                let reply = try preserveBrowserRecovery(noteId: id, baseRevision: base, text: text)
                replyHandler(try JSONSerialization.jsonObject(with: JSONEncoder().encode(reply)), nil)
                return
            }
            if case let .changes(id, tx, base, revision, changes) = incoming {
                committedRecovery = nil  // the page has text newer than any copy
                if stopForInvalidatedSession() { replyHandler(nil, "Editor session closed"); return }
                if let session, session.noteId == id, let current = try library.store.note(id: id),
                   current.isLocked != session.wasOriginallyLocked {
                    editable = false
                    webView.isUserInteractionEnabled = false
                    library.errorMessage = Self.protectionMismatchMessage  // N10: the alert offers Retry
                    replyHandler(nil, "Note protection changed"); return
                }
                guard let session, session.noteId == id, editable, pending == 0, revision == base + 1,
                      let note = try library.store.note(id: id), library.canRead(note),
                      note.isLocked == session.wasOriginallyLocked, !note.isReadOnly, note.location == .notes else {
                    replyHandler(nil, "The note is not ready for edits"); return
                }
                let result = session.apply(txId: tx, baseRevision: base, changeSet: changes, origin: listener)
                replyHandler(try JSONSerialization.jsonObject(with: JSONEncoder().encode(ChangesReply(result))), nil)
                if case .needsFullText = result { recover() } else { recoveryAttempts = 0 }
                return
            }
            try receive(incoming, from: message.webView)
            replyHandler(["ok": true], nil)
        } catch {
            if stopForInvalidatedSession() { replyHandler(nil, "Editor session closed"); return }
            library.errorMessage = "The editor could not complete that action: \(error.localizedDescription)"
            replyHandler(nil, "Editor action failed")
        }
    }

    /// Keep the source object through dispatch; copyText carries no note identity.
    func receive(_ message: EditorToHostMessage, from source: WKWebView?) throws {
        guard !privacyClosed, source === webView else { return }
        try handle(message)
    }

    private func handle(_ message: EditorToHostMessage) throws {
        switch message {
        case .ready(let version):
            guard version == EditorBridge.version else { throw CocoaError(.coderReadCorrupt) }
            ready = true
            previousWebContentProcessTerminated = false
            pending = 0
            loadNote()
            if let heading = pendingHeading, heading.noteID == session?.noteId {
                pendingHeading = nil
                send(.scrollToHeading(noteId: heading.noteID, index: heading.index))
            }
        case .scrollChanged(let id, let top):
            if session?.noteId == id { scrollTop = top }
            try library.store.saveEditorState(noteID: id, scrollTop: top)
        case .selectionChanged(let id, let anchor, let head):
            let selected = SelectionRange(anchor: anchor, head: head)
            if session?.noteId == id {
                selection = selected
                let nonempty = anchor != head
                if hasSelection != nonempty { hasSelection = nonempty }
            }
            try library.store.saveEditorState(noteID: id, selection: selected)
        case .checksum(let id, let noteID, let hash):
            if let checksum, checksum.id == id, checksum.noteID == noteID, let session,
               session.noteId == noteID, session.revision == checksum.revision, pending == 0 {
                let expected = SHA256.hash(data: Data(session.text.utf8)).map { String(format: "%02x", $0) }.joined()
                if expected != hash { recover() }
            }
            checksum = nil
        case let .error(message, _):
            if stopForInvalidatedSession() { return }
            if message.hasPrefix("Reload blocked:") {
                library.errorMessage = Self.recoveryBlockedMessage
            } else { recover() }
        case .copyText(let text, let html):
            guard ready, pageAllowsExport, canExport, !library.appLocked, let id = session?.noteId,
                  try library.store.note(id: id)?.isLocked == false else { return }
            if let html { UIPasteboard.general.items = [["public.utf8-plain-text": text, "public.html": Data(html.utf8)]] }
            else { UIPasteboard.general.string = text }
        case .requestCompletions(let request):
            guard request.noteId == session?.noteId else { return }
            completions.invalidateCaches()
            let items = try completions.items(kind: request.kind, query: request.query, noteTitle: request.noteTitle,
                sourceNoteId: request.noteId, sourceText: session?.text, sourceRevision: session?.revision)
            send(.completionResults(requestId: request.requestId, items: items))
        case .openLink(let request): try openLink(request)
        case .editLinkRequest(let request):
            if request.noteId == session?.noteId, editable { linkRequest = request }
        case .insertAttachments(let id, let insertID, let items):
            guard editable, id == session?.noteId else { return }
            guard items.allSatisfy({ $0.dataBase64.utf8.count <= 70_000_000 }),
                  items.reduce(0, { $0 + $1.dataBase64.utf8.count }) <= 140_000_000 else {
                throw CocoaError(.fileReadTooLarge)
            }
            var links: [String] = []
            for item in items {
                guard let data = Data(base64Encoded: item.dataBase64), data.count <= 50 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                links.append(AttachmentMarkdown.link(for: try library.addAttachment(data: data, filename: item.filename, noteID: id)))
            }
            command(.insertText, args: ["text": .string(links.joined(separator: "\n")), "insertId": .string(insertID)])
        case .pasteAttachments(let id, let insertID, let source, let text, let items):
            guard editable, id == session?.noteId else { return }
            var names: [String: String] = [:]
            for item in items where names[item.filename] == nil {
                guard let file = try library.attachmentURL(item.filename, noteID: source) else { throw CocoaError(.fileReadNoSuchFile) }
                names[item.filename] = try library.addAttachment(fileAt: file, noteID: id)
            }
            command(.insertText, args: ["text": .string(AttachmentMarkdown.rewriting(text, items: items, renamed: names)), "insertId": .string(insertID)])
        case .quickLook(let id, let filename):
            if id == session?.noteId, canExport, try library.store.note(id: id)?.isLocked == false { previewURL = try library.attachmentURL(filename, noteID: id) }
        case .attachmentMenu(let id, let filename, let from, let to, let source):
            let target = MobileAttachmentTarget(noteID: id, filename: filename, from: from, to: to, source: source)
            try validateAttachment(target, editing: false)
            attachmentTarget = target
        case .attachmentTap(let id, let filename, let from, let to, let source):
            let target = MobileAttachmentTarget(noteID: id, filename: filename, from: from, to: to, source: source)
            try validateAttachment(target, editing: false)
            attachmentTapTarget = target // Explicit user intent only; decoding belongs to the later async action.
        case .attachmentsRefused:
            library.errorMessage = "This attachment is too large. Please choose a file smaller than 50 MB."
        case .headingMenu(let request):
            if request.noteId == session?.noteId, canShare { headingMenu = request }
        case .tableMenu(let request):
            if request.noteId == session?.noteId, canShare { tableMenu = request }
        case .foldState(let id, let folds):
            if id == session?.noteId, canShare { try library.store.setFoldState(noteId: id, folds) }
        case .calloutMenu(let request):
            if request.noteId == session?.noteId, editable { calloutMenu = request }
        case .formatState(let id, let state):
            if id == session?.noteId, !privacyClosed { formatState = state }
        case .changes, .cutAttachments: break
        case .frozenForClose(let reply):
            if let barrier = closeBarrier, barrier.requestId == reply.requestId {
                settleCloseBarrier(reply.noteId == barrier.noteID ? reply : nil, matching: barrier)
            }
        default: break
        }
    }

    func preserveBrowserRecovery(noteId: String, baseRevision: Int, text: String) throws -> ChangesReply {
        guard !stopForInvalidatedSession() else { throw MobileEditorDrainError.unavailable }
        let privacyPermit = privacyRecoveryPermit.map { $0.noteID == noteId && Self.privacyRecoveryCanStart(deadline: $0.deadline) } ?? false
        if privacyRecoveryPermit != nil && !privacyPermit { throw MobileEditorDrainError.timeout }
        guard !privacyClosed, (!library.appLocked || privacyPermit), !library.isClosed, !library.isClosing,
              !library.libraryOperationBusy, (!library.sceneOperationPending || privacyPermit),
              let target = session, target.noteId == noteId else {
            throw MobileEditorDrainError.unavailable
        }
        let note = try library.store.note(id: noteId)
        if let note, !library.canRead(note) { throw MobileEditorDrainError.unavailable }
        let copy: BrowserRecoveryResult
        if (note == nil && library.privateAccess != nil) || (note?.isLocked == true && !target.wasOriginallyLocked) {
            guard let access = library.privateAccess else { throw MobileEditorDrainError.unavailable }
            copy = try access.preserveBrowserRecovery(noteId: noteId, text: text, baseRevision: baseRevision, now: .now)
        } else {
            copy = try target.preserveBrowserRecoveryResult(text: text, baseRevision: baseRevision)
        }
        committedRecovery = (noteId, documentLoadGeneration)
        if let permit = privacyRecoveryPermit, permit.noteID == noteId, !permit.switching, Date() >= permit.deadline {
            throw MobileEditorDrainError.timeout
        }
        if copy.created { library.errorMessage = "Unsaved editor text was preserved as a recovery copy in Notes." }
        return .acked(revision: baseRevision)
    }

    /// Best effort only inside the caller's deadline; a page that never answers ends at the deadline.
    /// The permit is scoped to this page and note; a late WebKit reply cannot extend it past the
    /// deadline or key revocation. A note switch (`switching`) keeps a copy committed late without
    /// answering it with an error (N16).
    func preserveBrowserTextBeforePrivacyClose(deadline: Date, switching: Bool = false) async -> Bool {
        guard Self.privacyRecoveryCanStart(deadline: deadline), ready, !privacyClosed, privacyRecoveryPermit == nil,
              let id = session?.noteId else { return false }
        let page = webView
        privacyRecoveryPermit = (id, deadline, switching)
        defer { privacyRecoveryPermit = nil }
        var value: Any?
        let answered = await MobileSketchPrivacyCloseBudget.wait(timeout: .seconds(max(0, deadline.timeIntervalSinceNow))) {
            value = try? await page.callAsyncJavaScript(
                "return await window.__baerchen.preserveForPrivacy(noteId)",
                arguments: ["noteId": id], in: nil, contentWorld: .page)
        }
        return answered && !Task.isCancelled && Date() < deadline && page === webView && session?.noteId == id && (value as? Bool == true)
    }

    /// The host committed this page's current text as a recovery copy, even if the page's answer was lost.
    func hasCommittedRecovery(for noteID: String) -> Bool {
        committedRecovery.map { $0.noteID == noteID && $0.generation == documentLoadGeneration } ?? false
    }

    /// Only call after a confirmed text-only recovery ACK for the still-current page.
    func withRecoveredBrowserText<T>(noteID: String, _ operation: () throws -> T) rethrows -> T {
        recoveredReplacementNoteID = noteID
        defer { recoveredReplacementNoteID = nil }
        return try operation()
    }

    private func recover() {
        if stopForInvalidatedSession() { return }
        recoveryAttempts += 1
        guard recoveryAttempts <= 5 else {
            editable = false
            library.errorMessage = Self.recoveryLimitMessage
            return
        }
        loadNote()
    }

    func retryBrowserRecovery() {
        if stopForInvalidatedSession() { return }
        guard !privacyClosed, session != nil else { return }
        recoveryAttempts = 0
        loadNote()
    }

    @discardableResult private func stopForInvalidatedSession() -> Bool {
        guard session?.isInvalidated == true else { return false }
        editable = false
        readOnlyReason = Self.invalidatedSessionMessage
        library.errorMessage = Self.invalidatedSessionMessage
        return true
    }

    private func openLink(_ request: OpenLinkRequest) throws {
        guard request.noteId == session?.noteId else { return }
        switch request.kind {
        case .url:
            if let url = URL(string: request.target), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                UIApplication.shared.open(url)
            }
        case .tag:
            if let sceneNavigation { sceneNavigation.scope = .tag(request.target); sceneNavigation.selectedID = nil }
            else { library.scope = .tag(request.target); library.selectedID = nil }
        case .attachment:
            guard canExport, try library.store.note(id: request.noteId)?.isLocked == false else { return }
            previewURL = try library.attachmentURL(request.target, noteID: request.noteId)
        case .wiki:
            try session?.flush()
            let link = WikiLinkRef(target: request.target, heading: request.heading)
            if let target = try library.store.resolveWikiLink(link, from: request.noteId) {
                let routedNewWindow = dispatchNoteLink(target.noteId, newWindow: request.newWindow, heading: request.heading)
                if !routedNewWindow, request.heading == nil, let ordinal = target.headingOrdinal { send(.scrollToHeading(noteId: target.noteId, index: ordinal)) }
            } else if !request.target.isEmpty {
                let note = try library.store.create(text: "# " + request.target)
                _ = dispatchNoteLink(note.id, newWindow: request.newWindow, heading: request.heading)
            }
        case .bearURL:
            guard let url = URLComponents(string: request.target), url.host == "x-callback-url", url.path == "/open-note",
                  let id = url.queryItems?.first(where: { $0.name == "id" })?.value,
                  let noteID = try library.store.externalRefs(source: "bear")[id]?.noteId else { return }
            onOpenNote?(noteID)
        }
    }

    /// Source-note identity is checked by openLink; repeat shared privacy admission at dispatch.
    /// An absent native-window callback preserves the ordinary single-window path.
    @discardableResult func dispatchNoteLink(_ noteID: String, newWindow: Bool, heading: String? = nil) -> Bool {
        guard !privacyClosed, !library.appLocked, !library.isClosed, !library.isClosing,
              !library.libraryOperationBusy, !library.sceneOperationPending else { return false }
        if let heading {
            // Keep private heading text process-local. The opaque persisted window address
            // intentionally carries no heading; same-scene deferred navigation preserves it.
            let pending = MobileCallbackNavigation(noteID: noteID, header: heading, find: nil, edit: false)
            if let sceneNavigation { sceneNavigation.pendingCallbackNavigation = pending }
            else { library.pendingCallbackNavigation = pending }
            if newWindow { library.errorMessage = "This heading link opened in this window. Opening headings in another window is not available." }
        } else if newWindow, let onOpenNoteInNewWindow { onOpenNoteInNewWindow(noteID); return true }
        onOpenNote?(noteID)
        return false
    }

    /// Covers all detached attachment reads/decodes AND guarded writer work through completion.
    /// Async callers retain this editor, so the library's existing weak registry still sees it.
    var hasAttachmentReads: Bool { !attachmentWork.isEmpty }

    func cancelAttachmentReads() {
        attachmentReadGeneration += 1
        attachmentEditOriginID = nil
        for work in attachmentWork.values { work.cancel() }
    }

    func waitForAttachmentReads() async {
        while !attachmentWork.isEmpty {
            let current = Array(attachmentWork.values)
            for work in current { await work.barrier.value }
            // Give suspended callers a chance to discard their task/results and deregister.
            await Task.yield()
        }
    }

    private func trackedAttachmentWork<Value: Sendable>(_ action: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        guard !library.isClosed, !library.isClosing, !library.libraryOperationBusy else { throw MobileAttachmentError.unavailable }
        let id = UUID(), epoch = attachmentReadGeneration
        let worker = Task.detached(priority: .userInitiated) { try await action() }
        attachmentWork[id] = AttachmentWork(barrier: Task { _ = await worker.result }, cancel: { worker.cancel() })
        defer { attachmentWork.removeValue(forKey: id) }
        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard epoch == attachmentReadGeneration else { throw CancellationError() }
        return result
    }

    /// Explicit user action only. A failed sketch decode always leaves an ordinary image path.
    func inspectAttachmentForEditing(_ target: MobileAttachmentTarget) async throws -> MobileAttachmentEditInspection {
        guard !library.isClosed, !library.isClosing, !library.libraryOperationBusy else { throw MobileAttachmentError.unavailable }
        try validateAttachment(target, editing: true)
        let binding = try await captureAttachmentInsertionOrigin()
        try validateAttachment(target, editing: true)
        let revision = try library.store.note(id: target.noteID)?.revision
        guard let revision else { throw MobileAttachmentError.stale }
        let epoch = attachmentReadGeneration
        let access = binding.locked ? library.privateAccess : nil
        guard !binding.locked || access != nil else { throw MobileAttachmentError.unavailable }
        let store = attachments, hook = beforeAttachmentRead
        let filename = target.filename, noteID = target.noteID
        let read = try await trackedAttachmentWork {
            try await hook?()
            try Task.checkCancellation()
            let bytes: Data
            if let access {
                bytes = try access.attachmentData(filename, noteId: noteID, maximumBytes: 64 * 1024 * 1024)
            } else {
                guard let url = store.url(for: filename, noteId: noteID),
                      let item = try MobileAttachmentFileReader.read([url], maximumBytes: 64 * 1024 * 1024).first
                else { throw MobileAttachmentError.unavailable }
                bytes = item.data
            }
            try Task.checkCancellation()
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let drawingData: Data?
            do {
                // Recognize only a fully decoded/validated PencilKit archive, never a marker alone.
                drawingData = try MobileSketchPNG.drawing(in: bytes) != nil ? MobileSketchPNG.drawingData(in: bytes) : nil
            }
            catch is CancellationError { throw CancellationError() }
            catch { try Task.checkCancellation(); drawingData = nil }
            var size: CGSize?
            if drawingData != nil, let source = CGImageSourceCreateWithData(bytes as CFData, nil),
               let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = info[kCGImagePropertyPixelWidth] as? Int, let height = info[kCGImagePropertyPixelHeight] as? Int {
                size = CGSize(width: width, height: height)
            }
            return MobileAttachmentEditRead(bytes: bytes, hash: hash, drawingData: drawingData, canvasSize: size)
        }
        _ = try validateAttachmentInsertion(binding)
        try validateAttachment(target, editing: true)
        guard epoch == attachmentReadGeneration, try library.store.note(id: target.noteID)?.revision == revision else { throw MobileAttachmentError.stale }
        let origin = MobileAttachmentEditOrigin(id: UUID(), binding: binding, target: target, plaintextSHA256: read.hash,
            persistedRevision: revision, readGeneration: epoch, isEditableSketch: read.drawingData != nil)
        attachmentEditOriginID = origin.id
        return MobileAttachmentEditInspection(origin: origin, bytes: read.bytes, drawingData: read.drawingData, canvasSize: read.canvasSize)
    }

    private func validateAttachmentEdit(_ origin: MobileAttachmentEditOrigin, token: Bool) throws -> NoteSession {
        if attachmentEditUnconfirmedID == origin.id { throw MobileAttachmentEditFailure.unconfirmed }
        guard !token || attachmentEditOriginID == origin.id,
              origin.readGeneration == attachmentReadGeneration else { throw MobileAttachmentError.stale }
        let session = try validateAttachmentInsertion(origin.binding)
        try validateAttachment(origin.target, editing: true)
        return session
    }

    /// Copy-on-write only: old file, old source and Undo history are retained. A writer/ACK
    /// failure consumes this origin permanently and never authorizes deletion or blind retry.
    func saveEditedAttachment(png: Data, origin: MobileAttachmentEditOrigin, mode: MobileAttachmentEditMode) async throws {
        let session = try validateAttachmentEdit(origin, token: true)
        if mode == .crop, origin.isEditableSketch { throw MobileAttachmentEditFailure.editableSketchCannotBeCropped }
        // Keep the existing argument label for callers; only crop may produce JPEG.
        let isPNG = png.starts(with: [137,80,78,71,13,10,26,10])
        let isJPEG = png.starts(with: [255,216,255])
        guard png.count <= 64 * 1024 * 1024, isPNG || (mode == .crop && isJPEG) else { throw MobileAttachmentError.unavailable }
        // Validate new pixels before attempting storage; this phase remains safely retryable.
        _ = try await trackedAttachmentWork {
            if mode == .sketch, try MobileSketchPNG.drawing(in: png) == nil { throw MobileAttachmentError.unavailable }
            return try await MobileImageCrop.prepare(data: png)
        }
        _ = try validateAttachmentEdit(origin, token: true)
        let source = AttachmentSourceGuard(filename: origin.target.filename, plaintextSHA256: origin.plaintextSHA256,
            maximumBytes: 64 * 1024 * 1024, expectedNoteRevision: origin.persistedRevision)
        let files = attachments, access = origin.binding.locked ? library.privateAccess : nil
        // Core's existing batch writer reserves/deduplicates this name under the
        // same source-validated transaction; never overwrite the old Undo attachment.
        let newName = Self.editedAttachmentFilename(original: origin.target.filename, jpeg: isJPEG)
        var writerAttempted = false
        do {
            let names = try await library.withDrainedShareEditorsAsync {
                _ = try validateAttachmentEdit(origin, token: true)
                attachmentEditOriginID = nil
                writerAttempted = true
                return try await trackedAttachmentWork {
                    try Task.checkCancellation()
                    let input = [ImportedAttachment(filename: newName, data: png)]
                    if let access { return try access.addAttachments(input, to: origin.noteID, validatingSource: source) }
                    guard !origin.binding.locked else { throw MobileAttachmentError.unavailable }
                    return try files.addBatch(input, to: origin.noteID, validatingSource: source)
                }
            }
            _ = try validateAttachmentEdit(origin, token: false)
            guard let name = names.first, names.count == 1 else { throw MobileAttachmentError.notApplied }
            try library.refreshSessions()
            _ = try validateAttachmentEdit(origin, token: false)
            let replacement = try Self.attachmentDestinationOnly(origin.target.source, filename: origin.target.filename, newName: name)
            let old = session.text as NSString
            let expected = old.replacingCharacters(in: NSRange(location: origin.target.from, length: origin.target.to - origin.target.from), with: replacement)
            var acknowledged = false
            let observer = session.addTextListener { value, _ in if value == expected { acknowledged = true } }
            defer { session.removeListener(observer) }
            attachmentInsertionOriginID = nil
            attachmentEditCommandInFlight = true
            defer { attachmentEditCommandInFlight = false }
            command(.replaceRange, args: ["from": .int(origin.target.from), "to": .int(origin.target.to),
                                         "expect": .string(origin.target.source), "text": .string(replacement)])
            for _ in 0..<100 {
                if acknowledged {
                    let frozen = try await prepareCaptureClose(origin.noteID)
                    defer { endCaptureClose(frozen) }
                    guard self.session === session, documentLoadGeneration == origin.binding.documentLoad else { throw MobileAttachmentError.stale }
                    return
                }
                try Task.checkCancellation()
                guard self.session === session, documentLoadGeneration == origin.binding.documentLoad,
                      !library.appLocked, !library.isClosed, !library.isClosing else { throw MobileAttachmentError.stale }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw MobileAttachmentError.notApplied
        } catch is AttachmentSourceGuard.Failure {
            throw MobileAttachmentError.stale // Core guarantees rejection before any staging/write.
        } catch {
            if writerAttempted { attachmentEditUnconfirmedID = origin.id; throw MobileAttachmentEditFailure.unconfirmed }
            throw error
        }
    }

    nonisolated static func editedAttachmentFilename(original: String, jpeg: Bool) -> String {
        let base = ((original as NSString).lastPathComponent as NSString).deletingPathExtension
        var stem = ""
        // Leave space for suffix, extension and Core's numeric collision discriminator.
        for character in base {
            guard stem.utf8.count + String(character).utf8.count <= 220 else { break }
            stem.append(character)
        }
        if stem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { stem = "Image" }
        return stem + " edited." + (jpeg ? "jpg" : "png")
    }

    /// Surgical UTF-8 destination replacement; alt/title, angle syntax and all metadata survive.
    nonisolated static func attachmentDestinationOnly(_ source: String, filename: String, newName: String) throws -> String {
        let links = NoteParser.attachmentLinkTargets(in: source)
        guard links.count == 1, links[0].filename == filename else { throw MobileAttachmentError.stale }
        let generated = AttachmentMarkdown.link(for: newName), targets = NoteParser.attachmentLinkTargets(in: AttachmentMarkdown.link(for: newName))
        guard targets.count == 1 else { throw MobileAttachmentError.stale }
        let encoded = Array(generated.utf8)[targets[0].bytes]
        var bytes = Array(source.utf8)
        let previous = bytes[links[0].bytes]
        let replacement = previous.first == 60 && previous.last == 62 ? [UInt8(60)] + encoded + [UInt8(62)] : Array(encoded)
        bytes.replaceSubrange(links[0].bytes, with: replacement)
        guard let result = String(bytes: bytes, encoding: .utf8) else { throw MobileAttachmentError.stale }
        return result
    }

    func captureAttachmentInsertionOrigin() async throws -> MobileAttachmentInsertionOrigin {
        try Task.checkCancellation()
        guard ready, editable, !library.appLocked, !library.libraryOperationBusy, !library.isClosed, !library.isClosing,
              let session, selectedNoteID == session.noteId, let note = try library.store.note(id: session.noteId),
              library.canRead(note), !note.isReadOnly, note.location == .notes else { throw MobileAttachmentError.unavailable }
        let page = webView, load = documentLoadGeneration, libraryGeneration = library.libraryGeneration
        let frozen = try await prepareCaptureClose(session.noteId)
        defer { endCaptureClose(frozen) }
        try Task.checkCancellation()
        guard webView === page, documentLoadGeneration == load, self.session === session else { throw MobileAttachmentError.stale }
        let origin = MobileAttachmentInsertionOrigin(editor: ObjectIdentifier(self), session: ObjectIdentifier(session),
            noteID: session.noteId, documentLoad: load, libraryGeneration: libraryGeneration, revision: session.revision,
            selection: Self.attachmentSelection(selection, text: session.text), locked: note.isLocked,
            access: note.isLocked ? library.privateAccess.map(ObjectIdentifier.init) : nil)
        attachmentInsertionOriginID = origin.id
        _ = try validateAttachmentInsertion(origin)
        return origin
    }

    private func validateAttachmentInsertion(_ origin: MobileAttachmentInsertionOrigin) throws -> NoteSession {
        guard attachmentInsertionOriginID == origin.id, origin.editor == ObjectIdentifier(self),
              origin.documentLoad == documentLoadGeneration, origin.libraryGeneration == library.libraryGeneration,
              let session, origin.session == ObjectIdentifier(session), origin.noteID == session.noteId,
              selectedNoteID == origin.noteID,
              origin.revision == session.revision, origin.selection == Self.attachmentSelection(selection, text: session.text),
              !library.appLocked, !library.libraryOperationBusy, !library.isClosed, !library.isClosing,
              let note = try library.store.note(id: origin.noteID), note.isLocked == origin.locked,
              library.canRead(note), !note.isReadOnly, note.location == .notes,
              !origin.locked || origin.access == library.privateAccess.map(ObjectIdentifier.init),
              library.cachedSession(for: origin.noteID) === session else { throw MobileAttachmentError.stale }
        guard ready, editable else { throw MobileAttachmentError.unavailable }
        return session
    }

    func insertFile(_ url: URL, origin: MobileAttachmentInsertionOrigin) async throws {
        try await insertFiles([url], origin: origin)
    }

    func insertFiles(_ urls: [URL], origin: MobileAttachmentInsertionOrigin) async throws {
        try Task.checkCancellation()
        _ = try validateAttachmentInsertion(origin)
        let reader = Task.detached(priority: .userInitiated) { try MobileAttachmentFileReader.read(urls) }
        let items = try await withTaskCancellationHandler {
            try await reader.value
        } onCancel: { reader.cancel() }
        try await insertAttachments(items, origin: origin)
    }

    func insertAttachments(_ items: [ImportedAttachment], origin: MobileAttachmentInsertionOrigin) async throws {
        try Task.checkCancellation()
        guard !items.isEmpty else { return }
        let session = try validateAttachmentInsertion(origin)
        var remaining = 250 * 1024 * 1024
        for item in items {
            guard item.data.count <= remaining else { throw CocoaError(.fileReadTooLarge) }
            remaining -= item.data.count
        }
        let from = min(origin.selection.anchor, origin.selection.head), to = max(origin.selection.anchor, origin.selection.head)
        let old = session.text as NSString
        guard from >= 0, to <= old.length else { throw MobileAttachmentError.stale }
        let selected = old.substring(with: NSRange(location: from, length: to - from))
        let names = try await library.withDrainedShareEditors {
            try Task.checkCancellation()
            _ = try validateAttachmentInsertion(origin)
            attachmentInsertionOriginID = nil
            let names: [String]
            if origin.locked {
                guard let access = library.privateAccess else { throw MobileAttachmentError.stale }
                names = try access.addAttachments(items, to: origin.noteID)
            } else {
                names = try attachments.addBatch(items, to: origin.noteID)
            }
            do { try library.refreshSessions() } catch { throw MobileAttachmentError.notApplied }
            return names
        }
        guard self.session === session, documentLoadGeneration == origin.documentLoad,
              selectedNoteID == origin.noteID, session.revision == origin.revision else { throw MobileAttachmentError.stale }
        let text = names.map(AttachmentMarkdown.link(for:)).joined(separator: "\n")
        let expected = old.replacingCharacters(in: NSRange(location: from, length: to - from), with: text)
        var acknowledged = false
        let observer = session.addTextListener { value, _ in if value == expected { acknowledged = true } }
        defer { session.removeListener(observer) }
        command(.replaceRange, args: ["from": .int(from), "to": .int(to), "expect": .string(selected), "text": .string(text)])
        for _ in 0..<100 {
            if acknowledged {
                let frozen = try await prepareCaptureClose(origin.noteID)
                defer { endCaptureClose(frozen) }
                guard self.session === session, documentLoadGeneration == origin.documentLoad else { throw MobileAttachmentError.stale }
                return
            }
            guard self.session === session, documentLoadGeneration == origin.documentLoad else { throw MobileAttachmentError.stale }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw MobileAttachmentError.notApplied
    }

    static func attachmentSelection(_ selection: SelectionRange?, text: String) -> SelectionRange {
        let end = (text as NSString).length
        return selection ?? SelectionRange(anchor: end, head: end)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        decisionHandler(url?.scheme == AssetSchemeHandler.scheme && url?.host == AssetSchemeHandler.host ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView, (error as NSError).code != NSURLErrorCancelled else { return }
        hasStarted = false
        library.errorMessage = "The editor could not open: " + error.localizedDescription
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        settleCloseBarrier(nil)
        ready = false; editable = false; generation += 1; pending = 0; pendingCommands = 0
        previousWebContentProcessTerminated = true
        webView.load(URLRequest(url: Self.indexURL))
    }
}

private final class WeakMobileHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var target: MobileEditor?
    init(_ target: MobileEditor) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        guard let target else { replyHandler(nil, "Editor closed"); return }
        target.userContentController(userContentController, didReceive: message, replyHandler: replyHandler)
    }
}

struct MobileWebView: UIViewRepresentable {
    let editor: MobileEditor
    func makeUIView(context: Context) -> MobileWebViewContainer {
        let container = MobileWebViewContainer()
        container.attach(editor)
        return container
    }
    func updateUIView(_ uiView: MobileWebViewContainer, context: Context) { uiView.attach(editor) }
}

/// Give each SwiftUI representation its own UIKit root, so navigation transitions do not ask
/// SwiftUI to manage the same retained WebView as two different representables' root view.
final class MobileWebViewContainer: UIView {
    private static let containers = NSHashTable<MobileWebViewContainer>.weakObjects()
    private var editor: MobileEditor?

    func attach(_ editor: MobileEditor) {
        self.editor = editor
        Self.containers.add(self)
        mountIfVisible()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil, let editor, editor.webView.superview === self {
            // Both detail hosts can be in the window during a navigation transition. Once the
            // owner leaves, wake the remaining host rather than relying on incidental layout.
            for container in Self.containers.allObjects where container.editor === editor && container.window != nil {
                container.setNeedsLayout()
            }
        }
        mountIfVisible()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Recover a detached page without competing with another visible transition host.
        if let editor, editor.webView.window == nil { mountIfVisible() }
    }

    private func mountIfVisible() {
        // SwiftUI also constructs offscreen detail representations. They must not take the
        // retained page away from the detail that is actually mounted in a window.
        guard window != nil, let editor else { return }
        editor.start()
        let webView = editor.webView
        guard webView.superview !== self else { return }
        for child in subviews { child.removeFromSuperview() }
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}


extension MobileEditor {
    private func validateAttachment(_ target: MobileAttachmentTarget, editing: Bool) throws {
        guard ready, !privacyClosed, !library.isClosed, !library.isClosing, !library.libraryOperationBusy,
              canShare, let session, session.noteId == target.noteID,
              let note = try library.store.note(id: target.noteID), library.canRead(note),
              !editing || (editable && !note.isReadOnly && note.location == .notes) else {
            throw MobileAttachmentError.unavailable
        }
        guard target.from >= 0, target.to >= target.from,
              target.to <= (session.text as NSString).length,
              let range = Range(NSRange(location: target.from, length: target.to - target.from), in: session.text),
              String(session.text[range]).utf8.elementsEqual(target.source.utf8),
              AttachmentMarkdown.renaming(target.source, to: target.filename) != nil,
              AttachmentMarkdown.isReferenced(target.filename, in: target.source) else { throw MobileAttachmentError.stale }
    }

    func canEditAttachment(_ target: MobileAttachmentTarget) -> Bool {
        (try? validateAttachment(target, editing: true)) != nil
    }

    func attachmentFile(_ target: MobileAttachmentTarget) throws -> URL {
        try validateAttachment(target, editing: false)
        guard canExport, try library.store.note(id: target.noteID)?.isLocked == false else { throw MobileAttachmentError.unavailable }
        guard let url = try library.attachmentURL(target.filename, noteID: target.noteID) else { throw MobileAttachmentError.unavailable }
        return url
    }

    func renameAttachment(_ target: MobileAttachmentTarget, to proposed: String) throws {
        try validateAttachment(target, editing: true)
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 200, !name.contains("/"), !name.contains("\\"),
              !name.contains("\0"), !name.contains("\n"), !name.contains("\r"), name != ".", name != "..",
              (name as NSString).pathExtension.lowercased() == (target.filename as NSString).pathExtension.lowercased() else {
            throw MobileAttachmentError.name
        }
        guard name != target.filename else { return }
        try session?.flush()
        let filename = try library.mobileRenameAttachment(target.filename, to: name, noteID: target.noteID)
        guard let source = AttachmentMarkdown.renaming(target.source, to: filename) else { throw MobileAttachmentError.stale }
        try replaceAttachment(target, with: source)
    }

    func removeAttachment(_ target: MobileAttachmentTarget) throws { try replaceAttachment(target, with: "") }

    func resizeAttachment(_ target: MobileAttachmentTarget, width: Int?) throws {
        guard AttachmentMarkdown.isImage(target.filename) else { throw MobileAttachmentError.unavailable }
        if let width, !(16...4096).contains(width) { throw MobileAttachmentError.width }
        guard let source = AttachmentMarkdown.settingMetadata(target.source, "width", width.map(String.init)) else {
            throw MobileAttachmentError.stale
        }
        try replaceAttachment(target, with: source)
    }

    func setAttachmentPreview(_ target: MobileAttachmentTarget, shown: Bool) throws {
        guard (target.filename as NSString).pathExtension.lowercased() == "pdf",
              let source = AttachmentMarkdown.settingMetadata(target.source, "preview", shown ? "true" : "false") else {
            throw MobileAttachmentError.unavailable
        }
        try replaceAttachment(target, with: source)
    }

    private func replaceAttachment(_ target: MobileAttachmentTarget, with source: String) throws {
        try validateAttachment(target, editing: true)
        command(.replaceRange, args: ["from": .int(target.from), "to": .int(target.to),
                                    "expect": .string(target.source), "text": .string(source)])
        attachmentTarget = nil
    }

    func pasteAsCode(_ text: String) {
        guard ready, editable, !privacyClosed else { return }
        command(.pasteCode, args: ["text": .string(text)])
    }
}
