// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import QuickLook
import PencilKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Claim the callback's own operation before checking library availability. A result refused
/// by an in-progress library operation must still release its picker gate.
@MainActor enum MobileFileImportCompletion {
    enum Decision: Equatable { case ready, busy, stale }
    static func claim(gate: MobileMediaOperationGate, operationID: UUID?, importingNotes: Bool,
                      libraryOperationBusy: Bool) -> Decision {
        if !importingNotes {
            guard let operationID, gate.finish(operationID) else { return .stale }
        }
        return libraryOperationBusy ? .busy : .ready
    }
}

/// Owns the pending capture, save attempt and native sheet lifetime separately.
/// Invalidation fences late work immediately; only native onDismiss releases a presented lease.
@MainActor @Observable final class MobileNewSketchInsertion {
    let operationID: UUID
    private let gate: MobileMediaOperationGate
    private(set) var hasModalLease = false
    private(set) var isInvalidated = false
    private(set) var isSaving = false
    private(set) var isFinished = false
    private(set) var insertionUnconfirmed = false
    enum Failure: Error, LocalizedError {
        case insertionUnconfirmed
        var errorDescription: String? {
            "Insertion could not be confirmed. Your drawing is still open here, and the note may already contain it. Another insertion is blocked to avoid duplicates. Keep this draft open, or choose Cancel to discard this open draft and return to the note."
        }
    }
    private var work: Task<Void, any Error>?
    init(gate: MobileMediaOperationGate, operationID: UUID) { self.gate = gate; self.operationID = operationID }
    var canPresent: Bool { !isInvalidated && !isFinished && gate.isCurrent(operationID) }
    func captureOrigin<Value>(_ capture: @MainActor () async throws -> Value) async throws -> Value {
        guard canPresent else { throw CancellationError() }
        let origin = try await capture()
        try Task.checkCancellation()
        guard canPresent else { throw CancellationError() }
        return origin
    }
    @discardableResult func requestPresentation() -> Bool {
        guard canPresent else { return false }
        hasModalLease = true
        return true
    }
    /// Releasing the old claim is an actor hop: privacy/navigation can change before
    /// it returns. Admit UI publication only after that last suspension point.
    func finishRecoveryHandoff(host: MobileSketchDraftHost,
                               releaseSource: @MainActor () async -> Void,
                               isCurrent: @MainActor () -> Bool) async throws {
        await releaseSource()
        guard !Task.isCancelled, canPresent, isCurrent() else {
            host.suspend()
            cancel()
            _ = didDismiss() // No native sheet was published; release its reserved lease now.
            throw CancellationError()
        }
    }
    func save(prepare: @escaping @Sendable () async throws -> Data,
              canInsert: @escaping @MainActor () -> Bool,
              insert: @escaping @MainActor (Data) async throws -> Void) async throws {
        guard !insertionUnconfirmed else { throw Failure.insertionUnconfirmed }
        guard canPresent, hasModalLease, !isSaving else { throw CancellationError() }
        isSaving = true
        let attempt = Task {
            let bytes = try await prepare()
            try Task.checkCancellation()
            guard self.canPresent, canInsert() else { throw CancellationError() }
            do { try await insert(bytes) }
            catch {
                // The writer consumes its origin before storage/bridge acknowledgement. A throw
                // cannot prove that nothing committed: retain the draft, never create it twice.
                self.insertionUnconfirmed = true
                throw Failure.insertionUnconfirmed
            }
        }
        work = attempt
        defer { work = nil; isSaving = false }
        try await withTaskCancellationHandler { try await attempt.value } onCancel: { attempt.cancel() }
        try Task.checkCancellation()
        guard !isInvalidated else { throw CancellationError() }
        isFinished = true
    }
    func cancel() {
        isInvalidated = true
        work?.cancel()
        if !hasModalLease { gate.finish(operationID) }
    }
    @discardableResult func didDismiss() -> Bool {
        guard hasModalLease else { return false }
        hasModalLease = false
        cancel()
        return true
    }
}

@MainActor @Observable private final class MobileAttachmentEditRequest {
    enum Content { case loading, sketch(PKDrawing, CGSize), crop(MobileImageCrop.Prepared), cropWarning(MobileImageCrop.Prepared), message(String) }
    let lease: MobileAttachmentEditLease
    let editor: MobileEditor
    let target: MobileAttachmentTarget
    let intent: MobileAttachmentEditIntent
    let expectedLocked: Bool
    let requiresEditable: Bool
    var inspection: MobileAttachmentEditInspection?
    var content: Content = .loading
    var waitingForMenu = false
    var fallback = false
    var work: Task<Void, Never>?
    var render: Task<Data, any Error>?
    var draftHost: MobileSketchDraftHost?
    init(lease: MobileAttachmentEditLease, editor: MobileEditor, target: MobileAttachmentTarget, intent: MobileAttachmentEditIntent, expectedLocked: Bool, requiresEditable: Bool) {
        self.lease = lease; self.editor = editor; self.target = target; self.intent = intent
        self.expectedLocked = expectedLocked; self.requiresEditable = requiresEditable
    }
    func cancel() {
        lease.cancel(); work?.cancel(); render?.cancel(); editor.cancelAttachmentReads()
    }
}

/// A task group would wait for a noncooperative child when leaving its scope.
/// This one-shot continuation instead lets privacy win at the deadline; late work
/// cannot complete the close twice and still observes vault-key revocation.
@MainActor enum MobileSketchPrivacyCloseBudget {
    @MainActor private final class Race {
        var continuation: CheckedContinuation<Bool, Never>?
        var worker: Task<Void, Never>?
        var timer: Task<Void, Never>?
        func complete(_ finished: Bool) {
            guard let continuation else { return }
            self.continuation = nil
            worker?.cancel(); timer?.cancel(); worker = nil; timer = nil
            continuation.resume(returning: finished)
        }
    }
    /// Checkpoints get the shared budget before a WebKit page can consume it. The
    /// same absolute deadline bounds every subsequent page, including other windows.
    @discardableResult static func checkpointBeforePages(deadline: Date,
                                      checkpoints: @MainActor () async -> Void,
                                      pages: @MainActor (Date) async -> Void) async -> Bool {
        await checkpoints()
        guard !Task.isCancelled, Date() < deadline else { return false }
        await pages(deadline)
        return true
    }
    /// The bounded async phase has finished. Revoke before any synchronous journal
    /// flush can overrun that deadline; a local scene close preserves another scene's key.
    static func revokeBeforeSynchronousClose(library: MobileLibrary, shared: Bool) {
        if shared { library.revokePrivateAccessForExpiredPrivacyClose() }
    }
    static func wait(timeout: Duration = .seconds(2), operation: @escaping @MainActor () async -> Void) async -> Bool {
        let race = Race()
        return await withCheckedContinuation { continuation in
            race.continuation = continuation
            race.worker = Task { await operation(); race.complete(true) }
            race.timer = Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                race.complete(false)
            }
        }
    }
}

struct MobileLibraryView: View {
    @Bindable var library: MobileLibrary
    @State private var sceneNavigation: MobileSceneNavigation
    @State private var sceneObservation: MobileSceneLibraryObservation
    @State private var sceneWindow = MobileSceneWindowReference()
    @State private var sceneReadGate: MobileSceneReadGate
    @State private var sceneRegistered = false
    @State private var sceneLifetime = UUID()
    @State private var sceneObservationGeneration: Int
    @State private var sceneAttachTask: Task<Void, Never>?
    @State private var sceneDetachTask: Task<Void, any Error>?
    @State private var privacyCloseRevokesSharedAccess = true
    @State private var scenePrivacyCloseToken: UUID?
    @Environment(\.openWindow) private var openWindow
    @State private var visibility: NavigationSplitViewVisibility = .all
    @State private var preferredColumn: NavigationSplitViewColumn = .content
    @State private var detailVisibilityGeneration = 0
    @State private var captureTransitionRunning = false
    @State private var captureTransitionGeneration = 0
    @State private var privacyCloseInFlight = false
    @State private var privacyClosePending = false
    @State private var privacyCloseGeneration = 0
    @State private var suspendedSketchHosts: [MobileSketchDraftHost] = []
    @State private var backgroundDrainInFlight = false
    private struct PendingJournalRetirement {
        let id: UUID
        let libraryGeneration: Int
        let sceneGeneration: Int
    }
    @State private var pendingJournalRetirement: PendingJournalRetirement?
    @State private var pendingVariantRetirement: PendingJournalRetirement?
    @State private var pendingQuarantine: MobileLibrary.JournalQuarantinePlan?
    private struct PendingBrowserDiscard {
        let target: String?
        let source: String
        let editorID: ObjectIdentifier
        let pageID: ObjectIdentifier
        let documentGeneration: Int
        let generation: Int
    }
    @State private var pendingBrowserDiscard: PendingBrowserDiscard?
    @State private var confirmDiscardUnrecoverable = false
    private struct DeferredSelection { let id: String? }
    @State private var deferredSelection: DeferredSelection?
    @State private var lifecycleSuspended = false
    @State private var sidebarFrame: CGRect = .null
    @State private var noteListFrame: CGRect = .null
    /// The on-screen keyboard in window coordinates and the window's height, from `keyboardWillChangeFrame`.
    @State private var keyboardInWindow: (frame: CGRect, windowHeight: CGFloat)?
    @State private var editor: MobileEditor
    @State private var pendingNewNoteFocus: String?
    @State private var sketchFocusReturn: (editor: MobileEditor, noteID: String)?
    private let applicationState: () -> UIApplication.State
    @FocusState private var searchFocused: Bool
    @State private var editorOwnsKeyboard = false
    @State private var importingFile = false
    @State private var attachmentOrigin: MobileAttachmentInsertionOrigin?
    @State private var preparingAttachment = false
    @State private var attachmentInFlight = false
    @State private var mediaGate = MobileMediaOperationGate()
    @State private var mediaLifecycleGeneration = 0
    private var mediaOperationID: UUID? { mediaGate.currentID }
    @State private var showingPhotos = false
    @State private var showingCamera = false
    @State private var showingDocumentScanner = false
    @State private var cameraSheetID: UUID?
    @State private var scannerSheetID: UUID?
    private struct NewSketchRequest {
        let operationID: UUID
        let generation: Int
        let origin: MobileAttachmentInsertionOrigin
        let editor: MobileEditor
        let drawing: PKDrawing
        let canvasSize: CGSize
        let draftHost: MobileSketchDraftHost
    }
    @State private var showingNewSketch = false
    @State private var newSketchRequest: NewSketchRequest?
    @State private var sketchSheetID: UUID?
    @State private var sketchOperation: MobileNewSketchInsertion?
    @State private var attachmentEditRequest: MobileAttachmentEditRequest?
    @State private var showingAttachmentEdit = false
    @State private var attachmentEditSheetID: UUID?
    @State private var recoverySummary: MobileSketchDraftStore.Summary?
    @State private var recoveringSketch = false
    @State private var recoveryDeferred = false
    @State private var recoveryFromSettings = false
    @State private var recoveryOwner = UUID()
    @State private var recoveryClaimID: UUID?
    @State private var recoveryEpoch = 0
    @State private var recoveryAfterUnlock = false
    private struct PendingSketchCopy { let id: UUID; let library: MobileLibrary; let generation: Int }
    @State private var recoveryCapacityModel: MobileSketchRecoveryCapacityModel?
    @State private var pendingSketchCopy: PendingSketchCopy?
    @State private var copyHandoffInFlight = false
    @State private var recoveryDiscoveryInFlight = false
    @State private var activeCapturePresentation: MobileCaptureRouter.Presentation?
    @State private var capturePresentationOwner = UUID()
    @State private var captureRoutingLease: (deliveryID: UUID, token: UUID)?
    @State private var voiceSheetRequest: MobileCaptureRouter.Presentation?
    @State private var voiceCaptureModel: MobileVoiceCaptureModel?
    @State private var showingVoice = false
    @State private var voiceTeardownInFlight = false
    @State private var voiceTeardownComplete = false
    @State private var voiceSheetDismissed = false
    @State private var externalCaptureSheets = MobileCaptureModalGate()
    @State private var importingNotes = false
    @State private var importBusy = false
    @State private var pendingNotesImport: MobilePendingImport?
    @State private var sharedMarkdown: MobileMarkdownShare?
    @State private var exportDocument: MobileExportDocument?
    @State private var exporting = false
    @State private var exportBusy = false
    @State private var exportGeneration = 0
    @State private var exportTask: Task<Void, Never>?
    @State private var exportType = UTType.plainText
    @State private var exportName = "Note.md"
    @State private var deleteID: String?
    @State private var pendingTrashDeletion: [String] = []
    @State private var trashDeletionTitle = "Delete Permanently?"
    @State private var selecting = false
    @State private var selectedNotes: Set<String> = []
    @State private var showingSettings = false
    @State private var showingQuickOpen = false
    @State private var showingTemplates = false
    @State private var templateID: String?
    @State private var pendingQuickOpenTemplateGeneration: Int?
    @State private var showingInfo = false
    @State private var sortInbox: MobileSortInboxModel?
    @State private var retainedSortInboxes: [MobileSortInboxModel] = []
    @State private var editingTag: TagNode?
    @State private var lockedSelection: String?
    @State private var passwordAction: MobilePasswordAction?
    @State private var pendingLockID: String?
    @State private var pendingRemoveLockID: String?
    @Environment(\.scenePhase) private var phase
    @Environment(MobileCaptureRouter.self) private var captureRouter: MobileCaptureRouter?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var linkTitle = ""
    @State private var linkURL = ""
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(library: MobileLibrary, editor: MobileEditor? = nil,
         sceneNavigation: MobileSceneNavigation? = nil,
         sceneObservation: MobileSceneLibraryObservation? = nil,
         applicationState: @escaping () -> UIApplication.State = { UIApplication.shared.applicationState }) {
        self.library = library
        self.applicationState = applicationState
        let navigation = sceneNavigation ?? MobileSceneNavigation(restoration: MobileRestoration(
            scope: library.scope, workspace: library.workspace?.path, noteID: library.selectedID))
        let readGate = MobileSceneReadGate()
        _sceneReadGate = State(initialValue: readGate)
        _sceneNavigation = State(initialValue: navigation)
        _sceneObservationGeneration = State(initialValue: library.libraryGeneration)
        _sceneObservation = State(initialValue: sceneObservation ?? Self.makeSceneObservation(library: library, navigation: navigation, readGate: readGate))
        let initialEditor = editor ?? MobileEditor(library: library)
        _editor = State(initialValue: initialEditor)
    }

    private static func makeSceneObservation(library: MobileLibrary, navigation: MobileSceneNavigation, readGate: MobileSceneReadGate) -> MobileSceneLibraryObservation {
        let generation = library.libraryGeneration
        return MobileSceneLibraryObservation(navigation: navigation, database: library.database, isCurrent: { [weak library] in
            guard let library else { return false }
            return readGate.allowed && library.libraryGeneration == generation && !library.isClosed && !library.isClosing &&
                !library.libraryOperationBusy && !library.sceneOperationPending && !library.appLocked
        })
    }

    private func reveal(_ id: String) throws { try library.reveal(id, in: sceneNavigation) }
    private func enterWorkspace(_ path: String?) throws { try library.enterWorkspace(path, in: sceneNavigation) }
    private func navigate(back: Bool) throws { try library.navigate(back: back, in: sceneNavigation) }
    private func togglePin(_ item: NoteListItem) throws { try library.togglePin(item, in: sceneNavigation) }

    private var sceneActivity: MobileSceneRegistry.Activity {
        phase == .active ? .active : phase == .background ? .background : .inactive
    }
    private func configureSceneEditor(_ value: MobileEditor) {
        value.sceneNavigation = sceneNavigation
        value.onOpenNote = { id in library.perform { try reveal(id) } }
        if MobileNoteSceneActivation.supportsMultipleWindows {
            value.onOpenNoteInNewWindow = { id in
                guard sceneRegistered, phase == .active, !library.appLocked,
                      !library.sceneOperationPending, !library.isClosing, !library.isClosed else { return }
                library.perform { openWindow(value: try MobileNoteSceneActivation.requestedAddress(noteID: id, library: library)) }
            }
        } else { value.onOpenNoteInNewWindow = nil }
    }
    private func attachScene() {
        guard !sceneRegistered else { return }
        let lifetime = UUID(); sceneLifetime = lifetime
        let previousDetach = sceneDetachTask
        sceneAttachTask?.cancel()
        sceneAttachTask = Task {
            do {
                try await previousDetach?.value
                guard !Task.isCancelled, sceneLifetime == lifetime,
                      !library.isClosed, !library.isClosing, !library.sceneOperationPending else { return }
                if editor.isClosedForPrivacy { editor = MobileEditor(library: library) }
                configureSceneEditor(editor)
                sceneReadGate.allowed = phase != .background
                try library.registerScene(id: sceneNavigation.id, editor: editor, navigation: sceneNavigation,
                    observation: sceneObservation, activity: sceneActivity)
                sceneRegistered = true
                sceneObservation.start()
                #if DEBUG && targetEnvironment(simulator)
                library.lockSelectedNoteForTesting = {
                    guard let id = sceneNavigation.selectedID else { return }
                    pendingLockID = id; completePasswordAction()
                }
                #endif
                if phase == .active, !library.appLocked {
                    if deferredSelection != nil { resumeDeferredSelection() }
                    else if let id = sceneNavigation.selectedID {
                        if editor.session?.noteId != id { requestSelection(id) }
                        preferredColumn = .detail
                    }
                }
                Task { await refreshSketchRecovery() }
            } catch {
                if sceneLifetime == lifetime, !Task.isCancelled { library.errorMessage = error.localizedDescription }
            }
        }
    }
    private func detachScene() {
        sceneLifetime = UUID()
        sceneRegistered = false
        sceneReadGate.allowed = false
        sceneObservation.stop()
        let attaching = sceneAttachTask, current = library, id = sceneNavigation.id, observation = sceneObservation
        let closingEditor = editor
        attaching?.cancel()
        sceneDetachTask = Task {
            defer { withExtendedLifetime(closingEditor) {} }
            await attaching?.value
            try await current.detachScene(id: id)
            if !current.isClosed { try await observation.stopAndWait() }
        }
    }
    private func replaceClosedEditor() throws {
        guard editor.isClosedForPrivacy else { return }
        let replacement = MobileEditor(library: library)
        configureSceneEditor(replacement)
        if sceneRegistered {
            try library.replaceClosedSceneEditor(id: sceneNavigation.id, editor: replacement, observation: sceneObservation)
        }
        editor = replacement
    }
    private func resumeSceneAfterOperation() {
        guard !library.sceneEditorAdmissionBlocked, !privacyCloseInFlight else { return }
        guard sceneRegistered else { attachScene(); return }
        library.perform {
            if sceneObservationGeneration != library.libraryGeneration {
                sceneObservation.stop() // The shared operation already awaited all prior readers.
                sceneObservation = Self.makeSceneObservation(library: library, navigation: sceneNavigation, readGate: sceneReadGate)
                sceneObservationGeneration = library.libraryGeneration
                try library.registerScene(id: sceneNavigation.id, editor: editor, navigation: sceneNavigation,
                    observation: sceneObservation, activity: sceneActivity)
            }
            if editor.isClosedForPrivacy { try replaceClosedEditor() }
            sceneReadGate.allowed = phase != .background
            if sceneReadGate.allowed { sceneObservation.start() }
            if phase == .active, !library.appLocked {
                // The displayed source may have been restored while backgrounding. The
                // deferred destination owns foreground admission, never that old source.
                if deferredSelection != nil { resumeDeferredSelection() }
                else if let id = sceneNavigation.selectedID,
                        attachmentEditRequest == nil || editor.session?.noteId != id { requestSelection(id) }
            }
        }
        uncoverActiveSceneIfSafe()
    }

    // Bound generic metadata and stack use per region. Composing all columns, lifecycle
    // observers and presentations into one type exhausted the physical iPhone launch stack.
    private var navigation: AnyView { AnyView(navigationLayout) }
    private var navigationLayout: some View {
        NavigationSplitView(columnVisibility: $visibility, preferredCompactColumn: $preferredColumn) {
            sidebar.modifier(PadKeyboardHandover(focusable: !editorOwnsKeyboard) { releaseEditorKeyboard() })
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { sidebarFrame = $0 }
        } content: {
            noteList.modifier(PadKeyboardHandover(focusable: !editorOwnsKeyboard) { releaseEditorKeyboard() })
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { noteListFrame = $0 }
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .disabled(!sceneRegistered || library.appLocked || library.libraryOperationBusy || library.sceneOperationPending)
        .accessibilityHidden(library.appLocked)
        .preferredColorScheme(library.preferences.colorScheme)
        .tint(library.preferences.theme(dark: colorScheme == .dark, increasedContrast: contrast == .increased).color(.accent).mobileColor)
        .onChange(of: library.preferences) { _, _ in editor.appearance(dark: colorScheme == .dark, increasedContrast: contrast == .increased) }
        .onChange(of: contrast) { _, _ in editor.appearance(dark: colorScheme == .dark, increasedContrast: contrast == .increased) }
        .onChange(of: reduceMotion) { _, _ in editor.appearance(dark: colorScheme == .dark, increasedContrast: contrast == .increased) }
        .onChange(of: dynamicTypeSize) { _, _ in editor.appearance(dark: colorScheme == .dark, increasedContrast: contrast == .increased) }
        // A tap into the page itself moves no UIKit focus; the keyboard showing or hiding is the signal then.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
            editor.clearShortcutBarArrows()
            refreshEditorKeyboardOwnership()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in refreshEditorKeyboardOwnership() }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            editor.clearShortcutBarArrows()
            guard let screenFrame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                  let window = editor.webView.window else { keyboardInWindow = nil; return }
            keyboardInWindow = (window.convert(screenFrame, from: window.screen.coordinateSpace), window.bounds.height)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardInWindow = nil }
        .onReceive(NotificationCenter.default.publisher(for: UIFocusSystem.didUpdateNotification)) { _ in
            Task { await Task.yield(); refreshEditorKeyboardOwnership() }
        }
        .background {
            // Separate keyboard ownership from the explicit visible menu action. This
            // command remains installed when rows are empty, but native text fields
            // must never turn a paste-style chord into an attachment insertion.
            VStack {
                Button("Focus Note Search") { focusSceneSearch() }
                    .accessibilityIdentifier("search-notes-keyboard-command")
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(!sceneRegistered || library.appLocked || library.sceneOperationPending)
                Button("Insert Attachment") { insertFileFromKeyboard() }
                    .accessibilityIdentifier("insert-file-keyboard-command")
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .disabled(searchFocused || !sceneRegistered || !formatCommandEnabled(.insertFile) || attachmentBusy || library.appLocked || library.sceneOperationPending)
                // Key commands registered once here, whatever columns are on screen.
                Group {
                    Button("Find") {
                        MobileShortcutRouter.find(responder: keyboardResponder, editorView: editor.webView,
                            editor: { editor.command(.find) }, library: { searchFocused = true })
                    }.keyboardShortcut("f")
                    Button("Quick Open") { showingQuickOpen = true }.keyboardShortcut("o")
                    Button("From Template") { showingTemplates = true }.keyboardShortcut("n", modifiers: [.command, .shift])
                    // A10: ⇧⌘C is Copy As ▸ Rich Text, as on the Mac. A shortcut on the item inside Note Actions never fired.
                    Button("Copy As Rich Text") { copyAs(.rtf) }.keyboardShortcut("c", modifiers: [.command, .shift])
                        .disabled(exportBusy || !editor.canExport)
                    // The Mac's section numbering (A12): 1–6, then 9 Archive and 0 Trash.
                    ForEach(Self.sectionKeys, id: \.title) { entry in
                        Button(entry.title) { selectScope(entry.scope) }.keyboardShortcut(entry.key, modifiers: [.command, .option])
                    }
                    Button("Editor Only") { visibility = .detailOnly; preferredColumn = .detail }.keyboardShortcut("1", modifiers: .control)
                    Button("Notes and Editor") { visibility = .doubleColumn }.keyboardShortcut("2", modifiers: .control)
                    Button("Tags, Notes and Editor") { visibility = .all }.keyboardShortcut("3", modifiers: .control)
                }.disabled(!sceneRegistered || library.appLocked || library.libraryOperationBusy || library.sceneOperationPending)
            }
            .frame(width: 0, height: 0).opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        }
        .onChange(of: sceneNavigation.selectionIntentGeneration) { _, _ in
            library.markSceneFrontmost(id: sceneNavigation.id)
            requestSelection(sceneNavigation.selectedID)
        }
    }

    private func requestSelection(_ id: String?) {
        if captureTransitionRunning { return }
        guard sceneRegistered, phase == .active, !lifecycleSuspended, !library.sceneEditorAdmissionBlocked else {
            deferredSelection = DeferredSelection(id: id)
            if let previous = editor.session?.noteId, previous != id { sceneNavigation.restoreDisplayedSelection(previous) }
            return
        }
        deferredSelection = nil
        if let previous = editor.session?.noteId, previous != id, library.isActiveCapture(previous) {
            captureTransitionRunning = true
            let generation = captureTransitionGeneration
            Task {
                do {
                    var switched = false
                    try await library.finishCapture(noteId: previous, editor: editor, mayFinish: {
                        captureTransitionGeneration == generation && phase == .active &&
                        !library.appLocked && !library.libraryOperationBusy && sceneNavigation.selectedID != previous
                    }, whileClosed: {
                        // The destination opens while the capture page is still verified-closed;
                        // a failed open falls back to the ordinary switch below (N15).
                        captureTransitionRunning = false
                        switched = applySelection(sceneNavigation.selectedID)
                    })
                    captureTransitionRunning = false
                    // The capture was finished elsewhere meanwhile: take the ordinary switch path.
                    if !switched { requestSelection(sceneNavigation.selectedID) }
                } catch {
                    captureTransitionRunning = false
                    if deferInterruptedSelection(previous: previous, generation: generation) { return }
                    let returnedToCapture = sceneNavigation.selectedID == previous
                    if editor.session?.noteId == previous, !library.isClosed, !library.isClosing {
                        sceneNavigation.selectedID = previous
                    }
                    if !returnedToCapture, captureTransitionGeneration == generation, phase == .active, !library.appLocked {
                        library.errorMessage = "The note is still saving. Please try leaving it again."
                    }
                }
            }
        } else if let previous = editor.session?.noteId, previous != id {
            if !editor.ready {
                do { try editor.drainUnreadyNativeSession(); applySelection(id) }
                catch {
                    sceneNavigation.restoreDisplayedSelection(previous)
                    library.errorMessage = "The editor isn't ready to switch notes. Wait, then select the destination again."
                }
                return
            }
            captureTransitionRunning = true
            let generation = captureTransitionGeneration
            Task {
                let closingEditor = editor
                do {
                    let frozen = try await closingEditor.prepareCaptureClose(previous, waitForBusyUntil: Date().addingTimeInterval(3))
                    defer { closingEditor.endCaptureClose(frozen) }
                    guard captureTransitionGeneration == generation, phase == .active,
                          !library.appLocked, !library.libraryOperationBusy,
                          editor === closingEditor, closingEditor.session?.noteId == previous else { throw CocoaError(.coderReadCorrupt) }
                    captureTransitionRunning = false
                    applySelection(sceneNavigation.selectedID)
                } catch {
                    captureTransitionRunning = false
                    if deferInterruptedSelection(previous: previous, generation: generation) { return }
                    captureTransitionRunning = true
                    let destination = sceneNavigation.selectedID
                    let page = closingEditor.webView
                    // A switch gets a generous deadline of its own, and a copy the host already
                    // committed counts as preserved even if the page's answer came late (N16).
                    let preserved = await closingEditor.preserveBrowserTextBeforePrivacyClose(deadline: .now.addingTimeInterval(10), switching: true)
                        || closingEditor.hasCommittedRecovery(for: previous)
                    captureTransitionRunning = false
                    guard captureTransitionGeneration == generation, phase == .active, !library.appLocked,
                          editor === closingEditor, closingEditor.webView === page,
                          closingEditor.session?.noteId == previous else { return }
                    // Another note was tapped during the wait: switch to that one instead.
                    guard sceneNavigation.selectedID == destination else { return requestSelection(sceneNavigation.selectedID) }
                    if preserved {
                        closingEditor.withRecoveredBrowserText(noteID: previous) {
                            applySelection(destination, recoveryPreserved: true)
                        }
                        return
                    }
                    if editor.session?.noteId == previous, !library.isClosed, !library.isClosing {
                        sceneNavigation.selectedID = previous
                    }
                    if library.privateAccess == nil, (try? library.store.canRecoverMissingJournalPlain()) != true {
                        // A locked vault or pending key offers only Unlock (ruling 7); the text stays in the open editor.
                        library.errorMessage = library.hasNotePassword ? MobileEditor.recoveryBlockedMessage
                            : MobileMissingJournalRecoveryError.waitingForSyncKey.localizedDescription
                    } else if captureTransitionGeneration == generation, phase == .active, !library.appLocked {
                        pendingBrowserDiscard = PendingBrowserDiscard(target: destination, source: previous,
                            editorID: ObjectIdentifier(closingEditor), pageID: ObjectIdentifier(closingEditor.webView),
                            documentGeneration: closingEditor.documentLoadGeneration, generation: generation)
                        confirmDiscardUnrecoverable = true
                    }
                }
            }
        } else {
            applySelection(id)
        }
    }

    private func deferInterruptedSelection(previous: String, generation: Int) -> Bool {
        guard captureTransitionGeneration != generation || phase != .active || lifecycleSuspended || library.appLocked || library.libraryOperationBusy else { return false }
        if sceneNavigation.selectedID != previous { deferredSelection = DeferredSelection(id: sceneNavigation.selectedID) }
        if editor.session?.noteId == previous, !library.isClosed, !library.isClosing { sceneNavigation.restoreDisplayedSelection(previous) }
        resumeDeferredSelection()
        return true
    }

    private func resumeDeferredSelection(requireApplicationActive: Bool = false) {
        guard phase == .active, !lifecycleSuspended, !library.appLocked, !library.libraryOperationBusy,
              !requireApplicationActive || applicationState() == .active,
              !privacyCloseInFlight, !backgroundDrainInFlight, !captureTransitionRunning,
              let deferred = deferredSelection else { return }
        deferredSelection = nil
        sceneNavigation.selectedID = deferred.id
        requestSelection(deferred.id)
    }

    /// False only when opening the selection failed (the error is shown).
    @discardableResult private func applySelection(_ id: String?, recoveryPreserved: Bool = false) -> Bool {
        guard sceneNavigation.selectedID == id else { return true }
        guard !library.sceneEditorAdmissionBlocked else {
            deferredSelection = DeferredSelection(id: id)
            return true
        }
        var applied = false
        library.perform {
            if !recoveryPreserved { try library.flush() }
            if let id { try openSelection(id); preferredColumn = .detail; highlightSearch(); applyCallbackNavigation() }
            else { lockedSelection = nil; preferredColumn = .content }
            applied = true
        }
        return applied
    }

    private var observedNavigation: AnyView { AnyView(mediaPresentations) }
    private var librarySetupLifecycle: some View {
        navigation.background(MobileSceneWindowProbe(reference: sceneWindow, onWindowAttached: { window in
            if phase != .active || (library.appLocked && (editor.session != nil || privacyClosePending || privacyCloseInFlight)) {
                MobilePrivacyShield.cover(in: window)
            }
        }).frame(width: 0, height: 0))
        .onAppear {
            attachScene()
            Task { try? await library.resumeConfirmedJournalQuarantines() }
        }
        .onChange(of: library.libraryGeneration) { _, _ in
            sceneObservation.stop()
            cancelNewSketch(); cancelAttachmentEdit(); suspendSketchRecoveryPrompt()
            retainedSortInboxes.forEach { $0.invalidate() }
            sortInbox = nil
            retainedSortInboxes.removeAll()
            if !library.libraryOperationBusy && !library.sceneOperationPending {
                resumeSceneAfterOperation()
                if deferredSelection != nil { resumeDeferredSelection() }
                else if let id = sceneNavigation.selectedID { requestSelection(id) }
            }
        }
        .onChange(of: library.appLocked) { _, locked in
            if locked {
                MobilePrivacyShield.cover(in: sceneWindow.window)
                resetMediaPresentations()
                closePrivateAccess()
                recoveryDeferred = false
                retainedSortInboxes.forEach { $0.invalidate() }
                sortInbox = nil
                retainedSortInboxes.removeAll()
            }
            if locked { sceneObservation.stop() }
            else { resumeSceneAfterOperation(); Task { await refreshSketchRecovery() } }
            if !locked, !privacyCloseInFlight {
                if deferredSelection != nil { resumeDeferredSelection() }
                else if let id = sceneNavigation.selectedID, editor.session?.noteId != id { requestSelection(id) }
            }
        }
        .onChange(of: library.libraryOperationBusy) { _, busy in
            if busy { sceneObservation.stop(); cancelNewSketch(); cancelAttachmentEdit(); suspendSketchRecoveryPrompt() }
            else { resumeSceneAfterOperation() }
        }
        .onChange(of: library.sceneOperationPending) { _, pending in
            if pending { sceneObservation.stop(); resetMediaPresentations() }
            else { resumeSceneAfterOperation() }
        }
        .onChange(of: library.sceneAdmissionGeneration) { _, _ in resumeSceneAfterOperation() }
        .onChange(of: editor.isClosedForPrivacy) { _, closed in if closed { resumeSceneAfterOperation() } }
        .onChange(of: library.privateAccess.map(ObjectIdentifier.init)) { _, access in
            cancelNewSketch(); cancelAttachmentEdit(); suspendSketchRecoveryPrompt()
            resumeSceneAfterOperation()
            if access != nil { Task { await upgradeSketchDraftsAfterUnlock(); await refreshSketchRecovery() } }
        }
        .onChange(of: attachmentDraftAccessState(newSketchRequest?.origin.noteID)) { _, state in
            if let request = newSketchRequest, !state.permitsDraft(expectedLocked: request.origin.locked) { cancelNewSketch() }
        }
    }

    private var libraryPrivacyLifecycle: some View {
        AnyView(librarySetupLifecycle)
        .onChange(of: phase) { _, value in
            if value != .active { editorOwnsKeyboard = false }
            sceneReadGate.allowed = value != .background
            _ = library.updateSceneActivity(id: sceneNavigation.id,
                activity: value == .active ? .active : value == .background ? .background : .inactive)
            if value != .active { MobilePrivacyShield.cover(in: sceneWindow.window) }
            if value == .background { enterBackground() }
            else if value == .active, applicationState() == .active {
                lifecycleSuspended = false
                library.retryMissingJournalRecovery()
                Task { try? await library.resumeConfirmedJournalQuarantines() }
                resumeSceneAfterOperation()
                resumeDeferredSelection()
                uncoverActiveSceneIfSafe()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            MobilePrivacyShield.cover(in: sceneWindow.window)
            _ = library.updateSceneActivity(id: sceneNavigation.id, activity: .inactive)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in enterBackground() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            guard phase == .active, applicationState() == .active else { return }
            _ = library.updateSceneActivity(id: sceneNavigation.id, activity: .active)
            lifecycleSuspended = false
            library.retryMissingJournalRecovery()
            if privacyClosePending {
                if !privacyCloseInFlight { closePrivateAccess(revokeSharedAccess: !library.hasActiveSceneWindows) }
            } else if !privacyCloseInFlight {
                resumeSceneAfterOperation()
                uncoverActiveSceneIfSafe()
            }
            resumeDeferredSelection()
            handleCapturePresentation()
            Task { await refreshSketchRecovery() }
        }
    }

    private var libraryLifecycle: some View {
        let retirementAtRender = pendingJournalRetirement
        let variantAtRender = pendingVariantRetirement
        let quarantineAtRender = pendingQuarantine
        let editorDialogs = AnyView(AnyView(libraryPrivacyLifecycle)
        .onChange(of: editor.attachmentTapTarget) { _, target in
            guard let target else { return }
            editor.attachmentTapTarget = nil
            beginAttachmentEdit(target, intent: .tap, fromMenu: false)
        }
        .onChange(of: attachmentDraftAccessState(attachmentEditRequest?.target.noteID)) { _, state in
            if let request = attachmentEditRequest, !state.permitsDraft(expectedLocked: request.expectedLocked, requiresEditable: request.requiresEditable) { cancelAttachmentEdit() }
        }
        .onChange(of: editor.ready) { _, ready in
            if ready { editor.appearance(dark: colorScheme == .dark, increasedContrast: contrast == .increased); highlightSearch(); applyCallbackNavigation(); focusNewNoteIfReady(); handleCapturePresentation() }
            else { editorOwnsKeyboard = false }
        }
        .onChange(of: editor.session?.noteId) { _, _ in focusNewNoteIfReady(); handleCapturePresentation() }
        .onChange(of: sceneNavigation.selectedID) { _, id in
            if pendingNewNoteFocus != id { pendingNewNoteFocus = nil }
            if id == nil { editorOwnsKeyboard = false }
            cancelNewSketch(); cancelAttachmentEdit(); handleCapturePresentation()
        }
        .onChange(of: captureRouter?.presentation) { _, _ in handleCapturePresentation() }
        .onChange(of: captureRouter?.presentationOwner) { _, _ in handleCapturePresentation() }
        .onChange(of: library.sceneRoutingGeneration) { _, _ in handleCapturePresentation() }
        .onDisappear {
            cancelNewSketch(); cancelAttachmentEdit(); suspendSketchRecoveryPrompt(); releaseCaptureForDisappearingScene()
            detachScene()
        }
        .onChange(of: sceneNavigation.query) { _, _ in highlightSearch() }
        .onChange(of: sceneNavigation.pendingCallbackNavigation?.id) { _, _ in applyCallbackNavigation() }
        .onChange(of: colorScheme) { _, value in editor.appearance(dark: value == .dark, increasedContrast: contrast == .increased) }
        .alert("Theo Notes", isPresented: Binding(get: { library.errorMessage != nil && !library.appLocked }, set: { if !$0 { library.errorMessage = nil } })) {
            if library.errorMessage == MobileEditor.recoveryLimitMessage || library.errorMessage == MobileEditor.protectionMismatchMessage ||
                library.errorMessage == MobileEditor.recoveryBlockedMessage || library.errorMessage == MobileEditor.deliveryFailureMessage {
                Button("Retry") { library.errorMessage = nil; editor.retryBrowserRecovery() }
                if library.privateAccess == nil && library.hasNotePassword {
                    Button("Unlock Notes") { library.errorMessage = nil; passwordAction = .unlock }
                }
            }
            Button("OK", role: .cancel) { library.errorMessage = nil }
        } message: { Text(library.errorMessage ?? "") }
        .confirmationDialog("Unsaved text could not be saved", isPresented: $confirmDiscardUnrecoverable, titleVisibility: .visible) {
            Button("Discard Unsaved Text and Leave", role: .destructive) {
                guard let pending = pendingBrowserDiscard else { return }
                pendingBrowserDiscard = nil
                guard !library.appLocked, !library.sceneEditorAdmissionBlocked, phase == .active,
                      ObjectIdentifier(editor) == pending.editorID, editor.session?.noteId == pending.source,
                      ObjectIdentifier(editor.webView) == pending.pageID,
                      editor.documentLoadGeneration == pending.documentGeneration,
                      captureTransitionGeneration == pending.generation else { return }
                let destination = pending.target
                do {
                    // Explicit confirmation permits discarding browser-only text even if flush fails.
                    guard editor.discardBrowserTextAfterConfirmation(noteID: pending.source, pageID: pending.pageID,
                                                                     documentGeneration: pending.documentGeneration) else { return }
                    try replaceClosedEditor()
                    sceneNavigation.selectedID = destination
                    if let destination { try openSelection(destination) }
                    else { lockedSelection = nil; preferredColumn = .content }
                } catch { library.errorMessage = "The note could not be opened. Try again." }
            }
            Button("Keep Note Open", role: .cancel) { pendingBrowserDiscard = nil }
        } message: { Text("The unsaved text cannot be saved right now. If you discard it, that text will be lost.") })
        let journalDialogs = AnyView(journalRetirementDialog(editorDialogs, retirementAtRender: retirementAtRender))
        let variantDialogs = AnyView(variantRetirementDialog(journalDialogs, variantAtRender: variantAtRender))
        return quarantineConfirmationDialog(variantDialogs, quarantineAtRender: quarantineAtRender)
        .onChange(of: phase) { (_: ScenePhase, newPhase: ScenePhase) in
            if newPhase != ScenePhase.active { pendingJournalRetirement = nil; pendingVariantRetirement = nil; pendingQuarantine = nil }
        }
    }

    private func journalRetirementDialog(_ content: AnyView, retirementAtRender: PendingJournalRetirement?) -> some View {
        content
        .confirmationDialog("Remove leftover recovery files?", isPresented: Binding(
            get: { pendingJournalRetirement != nil }, set: { presented in
                guard !presented, let id = retirementAtRender?.id else { return }
                Task { @MainActor in
                    await Task.yield()
                    if pendingJournalRetirement?.id == id { pendingJournalRetirement = nil }
                }
            }), titleVisibility: .visible) {
            Button("Remove Leftover", role: .destructive) {
                guard let pending = retirementAtRender, pendingJournalRetirement?.id == pending.id,
                      phase == .active, sceneRegistered,
                      pending.libraryGeneration == library.libraryGeneration,
                      pending.sceneGeneration == library.sceneRoutingGeneration else { return }
                pendingJournalRetirement = nil
                do { try library.removeRecoveredJournalAfterConfirmation(id: pending.id) }
                catch let error as MobileMissingJournalRecoveryError { library.errorMessage = error.localizedDescription }
                catch { library.errorMessage = "The recovery files changed or could not be removed. They were kept; review the recovery notice and try again." }
            }
            Button("Keep Files", role: .cancel) { pendingJournalRetirement = nil }
        } message: { Text("The recovered note is saved. Review it before removing its leftover recovery files. Other pending recovery may still block backup or sync.") }
    }

    private func variantRetirementDialog(_ content: AnyView, variantAtRender: PendingJournalRetirement?) -> some View {
        content
        .confirmationDialog("Remove recovered variant files?", isPresented: Binding(
            get: { pendingVariantRetirement != nil }, set: { presented in
                guard !presented, let pending = variantAtRender else { return }
                Task { @MainActor in
                    await Task.yield()
                    if pendingVariantRetirement?.id == pending.id { pendingVariantRetirement = nil }
                }
            }), titleVisibility: .visible) {
            Button("Remove Leftover Files", role: .destructive) {
                guard let pending = variantAtRender, pendingVariantRetirement?.id == pending.id,
                      phase == .active, sceneRegistered,
                      pending.libraryGeneration == library.libraryGeneration,
                      pending.sceneGeneration == library.sceneRoutingGeneration else { return }
                pendingVariantRetirement = nil
                Task {
                    do { try await library.removeRecoveredVariantAfterConfirmation(id: pending.id) }
                    catch { library.errorMessage = "The recovered files changed or could not be removed. Review the notes and try again." }
                }
            }
            Button("Keep Files", role: .cancel) { pendingVariantRetirement = nil }
        } message: { Text("Review every recovered variant first. Their original pairing is uncertain. The files are removed only after all variants are verified.") }
    }

    private func quarantineConfirmationDialog(_ content: AnyView, quarantineAtRender: MobileLibrary.JournalQuarantinePlan?) -> some View {
        content
        .confirmationDialog("Move recovery files aside?", isPresented: Binding(
            get: { pendingQuarantine != nil }, set: { presented in
                guard !presented, let plan = quarantineAtRender else { return }
                Task { @MainActor in
                    await Task.yield()
                    if pendingQuarantine?.id == plan.id { pendingQuarantine = nil }
                }
            }), titleVisibility: .visible) {
            Button("Move Files Aside", role: .destructive) {
                guard let plan = quarantineAtRender, pendingQuarantine?.id == plan.id,
                      phase == .active, sceneRegistered else { return }
                pendingQuarantine = nil
                Task {
                    do { try await library.moveJournalFilesAfterConfirmation(plan) }
                    catch { library.errorMessage = "The move could not finish. The files were not deleted; try again when the library is available." }
                }
            }
            Button("Keep Files", role: .cancel) { pendingQuarantine = nil }
        } message: {
            Text(JournalQuarantine.confirmationMessage(base: "The selected recovery files will be moved unchanged into this library's Recovery/Quarantine folder. Their edits may not appear in your notes until recovered. Encrypted files may still be recoverable with an older key or on another device. Back up these files separately; portable backups do not include them. Files: \(quarantineAtRender?.fileNames.joined(separator: ", ") ?? "")", includesUnavailableKeyFiles: quarantineAtRender?.includesUnavailableKeyFiles == true))
        }
    }

    private var mediaPresentations: some View {
        AnyView(libraryLifecycle).mobilePhotoPicker(isPresented: $showingPhotos) { [operationID = mediaOperationID] result in
            finishMediaCapture(result, operationID: operationID)
        }
        .sheet(isPresented: $showingCamera, onDismiss: { [operationID = cameraSheetID, generation = mediaLifecycleGeneration] in
            guard generation == mediaLifecycleGeneration, cameraSheetID == operationID else { return }
            cameraSheetID = nil
            cancelUnfinishedMedia(operationID: operationID)
            handleCapturePresentation()
        }) {
            let operationID = cameraSheetID
            MobileCameraCapture { result in finishMediaCapture(result, operationID: operationID) }
        }
        .sheet(isPresented: $showingNewSketch, onDismiss: { [operationID = sketchSheetID] in
            guard let operationID, sketchSheetID == operationID,
                  let operation = sketchOperation, operation.operationID == operationID else { return }
            _ = operation.didDismiss()
            sketchSheetID = nil; newSketchRequest = nil; sketchOperation = nil
            attachmentOrigin = nil; attachmentInFlight = false; preparingAttachment = false
            handleCapturePresentation()
            continueSketchCopyAfterDismissal()
            Task { await refreshSketchRecovery() }
            restoreSketchEditorFocus()
        }) {
            if let request = newSketchRequest {
                if let sketch = try? MobileSketchEditor(initialDrawing: request.drawing, canvasSize: request.canvasSize,
                    draftControl: request.draftHost.control, onCheckpoint: { request.draftHost.checkpoint($0) },
                    preserveOnCancel: { request.draftHost.keepsDraftOnCancel },
                    onPreserveDraft: { try await request.draftHost.prepareToKeepAfterSaveFailure() },
                    onRestoreCopy: { queueSketchCopy(request.draftHost); cancelNewSketch() },
                    onManageRecovery: { manageSketchRecovery(request.draftHost) },
                    onDone: { drawing, size in
                        do { try await finishNewSketch(drawing: drawing, size: size, request: request) }
                        catch {
                            request.draftHost.recordSaveFailure()
                            if error is CancellationError, phase != .background, !library.appLocked { throw MobileSketchDraftHost.Failure.stale }
                            throw error
                        }
                    },
                    onCancel: { discardNewSketch(); handleCapturePresentation() }) {
                    sketch.privacySensitive()
                        .sheet(item: $recoveryCapacityModel) { MobileSketchRecoveryCapacityView(model: $0) }
                } else {
                    ContentUnavailableView {
                        Label("Sketch unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("The drawing canvas could not be opened.")
                    } actions: { Button("Cancel") { cancelNewSketch() } }
                }
            }
        }
        .sheet(isPresented: $showingAttachmentEdit, onDismiss: { [operationID = attachmentEditSheetID] in
            finishAttachmentEditDismissal(operationID)
        }) {
            if let request = attachmentEditRequest {
                attachmentEditContent(request).privacySensitive().interactiveDismissDisabled()
            }
        }
        .sheet(isPresented: $showingVoice, onDismiss: { [request = voiceSheetRequest] in
            guard let request, voiceSheetRequest?.id == request.id else { return }
            voiceSheetDismissed = true
            finishVoicePresentation(request, suspend: false)
            completeVoiceDismissal(request)
        }) {
            if let model = voiceCaptureModel { MobileVoiceCaptureView(model: model).privacySensitive() }
        }
        .sheet(isPresented: $showingDocumentScanner, onDismiss: { [operationID = scannerSheetID, generation = mediaLifecycleGeneration] in
            guard generation == mediaLifecycleGeneration, scannerSheetID == operationID else { return }
            scannerSheetID = nil
            cancelUnfinishedMedia(operationID: operationID)
            handleCapturePresentation()
        }) {
            let operationID = scannerSheetID
            MobileDocumentCapture { result in finishMediaCapture(result, operationID: operationID) }
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.item], allowsMultipleSelection: true, onCompletion: { [operationID = mediaOperationID, isNotesImport = importingNotes, generation = mediaLifecycleGeneration] result in
            guard generation == mediaLifecycleGeneration, !library.appLocked else { return }
            switch MobileFileImportCompletion.claim(gate: mediaGate, operationID: operationID,
                importingNotes: isNotesImport, libraryOperationBusy: library.libraryOperationBusy) {
            case .stale: return
            case .busy:
                if isNotesImport { importingNotes = false }
                else { attachmentOrigin = nil; attachmentInFlight = false; handleCapturePresentation() }
                library.errorMessage = "Files could not be added while the library is busy. Wait for the current operation to finish, then choose the files again."
                return
            case .ready: break
            }
            defer { if !isNotesImport { handleCapturePresentation() } }
            if case .failure = result, !isNotesImport { attachmentOrigin = nil; attachmentInFlight = false }
            if case .failure(let error) = result, (error as NSError).domain == NSCocoaErrorDomain,
               (error as NSError).code == NSUserCancelledError { return }
            library.perform {
                let urls = try result.get()
                if isNotesImport {
                    pendingNotesImport = MobilePendingImport(urls: urls)
                } else if let origin = attachmentOrigin {
                    attachmentOrigin = nil
                    let granted = urls.filter { $0.startAccessingSecurityScopedResource() }
                    Task {
                        defer {
                            granted.forEach { $0.stopAccessingSecurityScopedResource() }
                            if generation == mediaLifecycleGeneration { attachmentInFlight = false; handleCapturePresentation() }
                        }
                        do { try await editor.insertFiles(urls, origin: origin) }
                        catch { if generation == mediaLifecycleGeneration { library.errorMessage = error.localizedDescription } }
                    }
                }
            }
        }, onCancellation: { [operationID = mediaOperationID, isNotesImport = importingNotes, generation = mediaLifecycleGeneration] in
            guard generation == mediaLifecycleGeneration else { return }
            if isNotesImport { importingNotes = false }
            else { cancelUnfinishedMedia(operationID: operationID) }
        })
        // A14: the options step between the file picker and the import.
        .sheet(item: $pendingNotesImport, onDismiss: { handleCapturePresentation() }) { pending in
            MobileImportOptionsSheet(urls: pending.urls) { options in
                pendingNotesImport = nil
                importNotes(pending.urls, options: options)
            } onCancel: { pendingNotesImport = nil }
        }
    }

    private func focusSceneSearch() {
        MobileShortcutRouter.searchNotes(canActivate: sceneRegistered && phase == .active && !lifecycleSuspended &&
            !library.appLocked && !library.libraryOperationBusy && !library.sceneOperationPending) {
            library.markSceneFrontmost(id: sceneNavigation.id)
            searchFocused = true
        }
    }
    private func insertFileFromKeyboard() {
        let responder = keyboardResponder, currentEditor = editor, generation = mediaLifecycleGeneration
        Task {
            await MobileShortcutRouter.insertFile(responder: responder, editorView: currentEditor.webView,
                stillCurrent: {
                    sceneRegistered && phase == .active && !lifecycleSuspended && !library.appLocked &&
                        !library.libraryOperationBusy && !library.sceneOperationPending &&
                        editor === currentEditor && mediaLifecycleGeneration == generation && keyboardResponder === responder
                }, action: { beginFileAttachment() })
        }
    }

    private func beginFileAttachment() {
        beginAttachment(.file)
    }

    private var attachmentBusy: Bool {
        pendingSketchCopy != nil || copyHandoffInFlight || recoverySummary != nil || recoveryFromSettings || recoveringSketch || attachmentEditRequest != nil || preparingAttachment || attachmentInFlight || cameraSheetID != nil || scannerSheetID != nil || sketchSheetID != nil ||
        library.libraryOperationBusy || importBusy || importingFile || voiceSheetRequest != nil
    }

    private enum AttachmentSource { case file, photos, camera, scan, sketch }

    private func beginAttachment(_ source: AttachmentSource) {
        guard !attachmentBusy, !privacyCloseInFlight, !library.appLocked, !library.libraryOperationBusy else { return }
        if case .sketch = source, phase != .active || lifecycleSuspended || applicationState() != .active { return }
        if source == .camera, let error = MobileMediaCapture.availabilityError(for: .camera) {
            library.errorMessage = error.localizedDescription; return
        }
        if source == .scan, let error = MobileMediaCapture.availabilityError(for: .scan) {
            library.errorMessage = error.localizedDescription; return
        }
        guard let operationID = mediaGate.begin() else { return }
        let pendingSketch: MobileNewSketchInsertion?
        if case .sketch = source {
            pendingSketch = MobileNewSketchInsertion(gate: mediaGate, operationID: operationID)
            sketchOperation = pendingSketch
        } else { pendingSketch = nil }
        preparingAttachment = true
        attachmentInFlight = true
        let generation = mediaLifecycleGeneration
        let captureEditor = editor
        Task {
            defer { if generation == mediaLifecycleGeneration { preparingAttachment = false; handleCapturePresentation() } }
            do {
                let origin: MobileAttachmentInsertionOrigin
                if let pendingSketch {
                    rememberSketchEditorFocus(captureEditor)
                    captureEditor.webView.endEditing(true)
                    origin = try await pendingSketch.captureOrigin { try await captureEditor.captureAttachmentInsertionOrigin() }
                } else { origin = try await captureEditor.captureAttachmentInsertionOrigin() }
                guard generation == mediaLifecycleGeneration, mediaGate.isCurrent(operationID),
                      !privacyCloseInFlight, !library.appLocked, !library.libraryOperationBusy else {
                    if generation == mediaLifecycleGeneration, mediaGate.finish(operationID) { attachmentInFlight = false }
                    return
                }
                attachmentOrigin = origin
                switch source {
                case .file: importingNotes = false; importingFile = true
                case .photos: showingPhotos = true
                case .camera: cameraSheetID = mediaOperationID; showingCamera = true
                case .scan: scannerSheetID = mediaOperationID; showingDocumentScanner = true
                case .sketch:
                    guard phase == .active, !lifecycleSuspended, applicationState() == .active, editor === captureEditor,
                          let pendingSketch, sketchOperation === pendingSketch, pendingSketch.requestPresentation() else {
                        cancelUnfinishedMedia(operationID: operationID); return
                    }
                    let draft = makeSketchDraftHost(noteID: origin.noteID)
                    guard try await draft.reserveFresh() else { throw MobileSketchDraftHost.Failure.stale }
                    guard generation == mediaLifecycleGeneration, mediaGate.isCurrent(operationID), !Task.isCancelled else {
                        draft.suspend(); throw CancellationError()
                    }
                    newSketchRequest = NewSketchRequest(operationID: operationID, generation: generation, origin: origin,
                        editor: captureEditor, drawing: PKDrawing(), canvasSize: CGSize(width: 768, height: 1024), draftHost: draft)
                    sketchSheetID = operationID; showingNewSketch = true
                }
            } catch {
                guard generation == mediaLifecycleGeneration, mediaGate.finish(operationID) else { return }
                if let pendingSketch, sketchOperation === pendingSketch { sketchOperation = nil; sketchFocusReturn = nil }
                attachmentInFlight = false
                if !(error is CancellationError) { library.errorMessage = error.localizedDescription }
            }
        }
    }

    /// The editor owns the unchanged drawing/Undo until this async save confirms success.
    private func finishNewSketch(drawing: PKDrawing, size: CGSize, request: NewSketchRequest) async throws {
        guard request.generation == mediaLifecycleGeneration, let operation = sketchOperation,
              operation.operationID == request.operationID, operation.canPresent,
              sketchSheetID == request.operationID,
              phase == .active, !lifecycleSuspended, applicationState() == .active,
              !privacyCloseInFlight, !library.appLocked, !library.libraryOperationBusy,
              editor === request.editor else { throw CancellationError() }
        guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1,
              size.width <= 4096, size.height <= 4096, size.width * size.height <= 16_777_216 else {
            throw MobileSketchPNG.Failure.tooLarge
        }
        let archive = drawing.dataRepresentation()
        guard archive.count <= MobileSketchPNG.maximumDrawingBytes else { throw MobileSketchPNG.Failure.tooLarge }
        let draftHost = request.draftHost
        draftHost.checkpoint(MobileSketchCheckpoint(drawingData: archive, canvasSize: size))
        try await operation.save(prepare: {
            let worker = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let snapshot = try PKDrawing(data: archive)
                let rendered = snapshot.image(from: CGRect(origin: .zero, size: size), scale: 1)
                try Task.checkCancellation()
                guard let pixels = rendered.cgImage else { throw MobileSketchPNG.Failure.invalidPNG }
                let png = try MobileSketchPNG.pngForNewSketch(from: pixels)
                try Task.checkCancellation()
                return try MobileSketchPNG.embed(drawingData: archive, in: png)
            }
            let png = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try await draftHost.prepareForWrite() // Checkpoint failure is still pre-writer and safely retryable.
            return png
        }, canInsert: {
            request.generation == mediaLifecycleGeneration && sketchOperation === operation &&
                phase == .active && !lifecycleSuspended && applicationState() == .active &&
                !privacyCloseInFlight && !library.appLocked && !library.libraryOperationBusy && editor === request.editor
        }, insert: { png in
            // Exact note/session/caret/revision/privacy are checked again after editor drain,
            // immediately before the existing atomic attachment write.
            try await request.editor.insertAttachments([ImportedAttachment(filename: "Sketch.png", data: png)], origin: request.origin)
        })
        try await request.draftHost.confirmedSave()
        // Keep the modal lease until native onDismiss, even after successful insertion.
        if sketchOperation === operation, !operation.isInvalidated { showingNewSketch = false }
    }

    private func cancelNewSketch() {
        guard let operation = sketchOperation else { return }
        newSketchRequest?.draftHost.suspend()
        operation.cancel()
        showingNewSketch = false; newSketchRequest = nil
        attachmentOrigin = nil; attachmentInFlight = false; preparingAttachment = false
        if !operation.hasModalLease {
            sketchOperation = nil; sketchSheetID = nil
        }
    }

    private func queueSketchCopy(_ host: MobileSketchDraftHost) {
        pendingSketchCopy = PendingSketchCopy(id: host.id, library: library, generation: library.libraryGeneration)
        recoveryDeferred = false
    }
    /// Native dismissal releases the current modal before an explicit new-note recovery starts.
    private func continueSketchCopyAfterDismissal() {
        guard let pending = pendingSketchCopy else { return }
        copyHandoffInFlight = true
        pendingSketchCopy = nil
        Task {
            defer { copyHandoffInFlight = false }
            do {
                guard pending.library === library, pending.library.libraryGeneration == pending.generation,
                      phase == .active, !library.appLocked, !library.libraryOperationBusy else { return }
                guard let summary = try await pending.library.sketchDraftStore.discover().first(where: { $0.id == pending.id }) else { throw MobileSketchDraftHost.Failure.checkpointFailed }
                guard pending.library === library, pending.library.libraryGeneration == pending.generation,
                      phase == .active, !library.appLocked, !library.libraryOperationBusy else { return }
                recoveryOwner = UUID()
                restoreSketchDraft(summary, inNewNote: true)
            } catch { library.errorMessage = error.localizedDescription }
        }
    }

    private func makeSketchDraftHost(noteID: String, filename: String? = nil, sourceHash: String? = nil,
                                     recovered: MobileSketchDraftStore.Draft? = nil,
                                     protected: Bool = false, explicitCopy: Bool = false) -> MobileSketchDraftHost {
        let current = library, generation = library.libraryGeneration, root = library.paths.root
        let mustProtect = protected || (try? library.store.note(id: noteID)?.isLocked) != false
        let host = MobileSketchDraftHost(store: current.sketchDraftStore, owner: recoveryOwner,
            id: recovered?.id ?? UUID(), generation: recovered?.generation ?? 0,
            originalNoteID: noteID, sourceFilename: filename, sourceSHA256: sourceHash,
            state: recovered?.state ?? .editing, explicitCopy: explicitCopy,
            boundary: {
                MobileSketchDraftPersistenceBoundary.isCurrent(current, root: root, generation: generation)
            }, protection: {
                MobileSketchDraftProtectionPolicy.resolve(requiresProtection: mustProtect, access: current.privateAccess) {
                    try current.store.note(id: noteID)
                }
            })
        current.registerSceneSketchHost(host, sceneID: sceneNavigation.id)
        return host
    }

    private func discardNewSketch() {
        let draft = newSketchRequest?.draftHost
        cancelNewSketch()
        if draft?.keepsDraftOnCancel == true { recoveryDeferred = false }
        if let draft { Task { do { try await draft.cancelByUser() } catch { library.errorMessage = error.localizedDescription } } }
    }
    private func discardAttachmentSketch() {
        let draft = attachmentEditRequest?.draftHost
        cancelAttachmentEdit()
        if draft?.keepsDraftOnCancel == true { recoveryDeferred = false }
        if let draft { Task { do { try await draft.cancelByUser() } catch { library.errorMessage = error.localizedDescription } } }
    }

    private var sketchRecoveryPresentations: some View {
        AnyView(observedNavigation)
            .onReceive(NotificationCenter.default.publisher(for: MobileSketchDraftNavigation.open)) { notification in
                guard let sender = notification.object as? MobileLibrary, sender === library else { return }
                recoveryFromSettings = true
                showingSettings = false // Settings onDismiss owns the handoff, never a competing sheet.
            }
            .confirmationDialog("Recovered Sketch Draft", isPresented: Binding(get: { recoverySummary != nil }, set: { if !$0 { recoverySummary = nil; recoveryDeferred = true } }), titleVisibility: .visible) {
                if let summary = recoverySummary {
                    if summary.isProtected && library.privateAccess == nil {
                        Button("Unlock Notes") { recoveryAfterUnlock = true; deferSketchRecovery(); passwordAction = .unlock }
                    } else {
                        if !summary.insertionUnconfirmed {
                            Button("Restore to Original Note") { restoreSketchDraft(summary, inNewNote: false) }
                        }
                        Button(summary.insertionUnconfirmed ? "Restore a Copy in New Note" : "Restore in New Note") {
                            restoreSketchDraft(summary, inNewNote: true)
                        }
                    }
                    Button("Discard Draft", role: .destructive) {
                        recoverySummary = nil; recoveryClaimID = nil; recoveryDeferred = true
                        Task {
                            do { try await library.sketchDraftStore.delete(summary.id) }
                            catch { library.errorMessage = error.localizedDescription }
                            await library.sketchDraftStore.release(summary.id, owner: recoveryOwner)
                            handleCapturePresentation()
                        }
                    }
                    Button("Not Now", role: .cancel) { deferSketchRecovery() }
                }
            } message: {
                Text(recoverySummary?.insertionUnconfirmed == true
                    ? "A previous save may already be in the note. Restore only an explicit new copy, or discard this recovery draft after checking your notes."
                    : "An unfinished drawing was kept on this device. Restore it to its unchanged original, or explicitly choose a new note. Locked drawings require the notes password.")
            }
    }

    /// Encryption-only recovery pass: no drawing decode or preview, and never blocks unlock/lock.
    private func upgradeSketchDraftsAfterUnlock() async {
        let current = library, generation = library.libraryGeneration, store = library.sketchDraftStore
        guard let access = current.privateAccess, !current.appLocked else { return }
        let identity = ObjectIdentifier(access), owner = UUID()
        do {
            for summary in try await store.discover() where !summary.isProtected {
                guard current.libraryGeneration == generation, !current.isClosing, !current.isClosed,
                      !current.libraryOperationBusy, current.privateAccess.map(ObjectIdentifier.init) == identity else { return }
                guard try await store.claim(summary.id, owner: owner) else { continue }
                do {
                    if let draft = try await store.load(summary.id), draft.generation < Int.max {
                        let admission = store.captureAdmission(for: draft.originalNoteID)
                        if MobileSketchDraftRestorePolicy.requiresProtection(storedProtected: false, hasVault: current.hasNotePassword, readOriginal: {
                               guard let id = draft.originalNoteID else { return nil }
                               return try current.store.note(id: id)
                           }) {
                            guard current.libraryGeneration == generation, !current.isClosing, !current.isClosed,
                                  !current.libraryOperationBusy, current.privateAccess.map(ObjectIdentifier.init) == identity else { throw CancellationError() }
                            let sealed = MobileSketchDraftStore.Draft(id: draft.id, generation: draft.generation + 1,
                                originalNoteID: draft.originalNoteID, sourceFilename: draft.sourceFilename, sourceSHA256: draft.sourceSHA256,
                                drawingData: draft.drawingData, canvasSize: draft.canvasSize, state: draft.state)
                            _ = try await store.checkpoint(sealed, protection: .sealed(access), admission: admission)
                        }
                    }
                    await store.release(summary.id, owner: owner)
                } catch {
                    await store.release(summary.id, owner: owner)
                    throw error
                }
            }
        } catch {
            // Last durable file-protected generation is retained; no plaintext preview is opened.
            if current.libraryGeneration == generation, !current.appLocked, !(error is CancellationError) {
                library.errorMessage = "A sketch recovery draft could not yet be encrypted. It is kept hidden until its protected recovery can complete."
            }
        }
    }

    private func refreshSketchRecovery(force: Bool = false) async {
        guard !recoveryDiscoveryInFlight else { return }
        guard phase == .active, !lifecycleSuspended, !library.appLocked, !privacyCloseInFlight,
              !library.libraryOperationBusy, !library.isClosed, !library.isClosing,
              !recoveryDeferred || force, recoverySummary == nil, !recoveringSketch,
              attachmentEditRequest == nil, newSketchRequest == nil, !attachmentBusy,
              !showingSettings, passwordAction == nil, !externalCaptureSheets.isPresented,
              captureRouter?.presentation == nil || force else { return }
        recoveryDiscoveryInFlight = true
        defer { recoveryDiscoveryInFlight = false }
        let epoch = recoveryEpoch
        let owner = UUID(); recoveryOwner = owner
        let current = library, generation = library.libraryGeneration, store = library.sketchDraftStore
        do {
            var hiddenProtected = false
            for discovered in try await store.discover() {
                var summary = discovered
                guard try await store.claim(summary.id, owner: owner) else { continue }
                guard current.libraryGeneration == generation, recoveryEpoch == epoch, phase == .active,
                      !current.appLocked, !current.isClosing, !current.isClosed, !current.libraryOperationBusy else {
                    await store.release(summary.id, owner: owner); return
                }
                if !summary.isProtected {
                    do {
                        guard let draft = try await store.load(summary.id) else {
                            await store.release(summary.id, owner: owner); continue
                        }
                        guard current.libraryGeneration == generation, recoveryEpoch == epoch, !current.appLocked,
                              !current.isClosing, !current.isClosed, !current.libraryOperationBusy else { throw CancellationError() }
                        let admission = store.captureAdmission(for: draft.originalNoteID)
                        let protect = MobileSketchDraftRestorePolicy.requiresProtection(storedProtected: false, hasVault: current.hasNotePassword) {
                            guard let id = draft.originalNoteID else { return nil }
                            return try current.store.note(id: id)
                        }
                        if protect {
                            guard let access = current.privateAccess else {
                                hiddenProtected = true
                                await store.release(summary.id, owner: owner); continue
                            }
                            guard draft.generation < Int.max else { throw MobileSketchDraftHost.Failure.stale }
                            let sealed = MobileSketchDraftStore.Draft(id: draft.id, generation: draft.generation + 1,
                                originalNoteID: draft.originalNoteID, sourceFilename: draft.sourceFilename, sourceSHA256: draft.sourceSHA256,
                                drawingData: draft.drawingData, canvasSize: draft.canvasSize, state: draft.state)
                            guard try await store.checkpoint(sealed, protection: .sealed(access), admission: admission) else { throw MobileSketchDraftHost.Failure.stale }
                            summary = .init(id: sealed.id, generation: sealed.generation, isProtected: true,
                                insertionUnconfirmed: sealed.state == .insertionUnconfirmed)
                        }
                    } catch {
                        await store.release(summary.id, owner: owner)
                        throw error
                    }
                }
                guard current === library, current.libraryGeneration == generation, recoveryEpoch == epoch, phase == .active,
                      !library.appLocked, !library.isClosed, !library.isClosing, !library.libraryOperationBusy,
                      !showingSettings, passwordAction == nil, (captureRouter?.presentation == nil || force),
                      !externalCaptureSheets.isPresented, recoverySummary == nil, !attachmentBusy else {
                    await store.release(summary.id, owner: owner); return
                }
                recoveryDeferred = false; recoveryClaimID = summary.id; recoverySummary = summary; return
            }
            if force {
                if hiddenProtected, current.hasNotePassword, current.privateAccess == nil {
                    recoveryAfterUnlock = true; passwordAction = .unlock
                } else {
                    library.errorMessage = hiddenProtected
                        ? "A protected recovery draft could not yet be opened. It has been kept."
                        : "There are no available recovered sketch drafts in this library. A draft open in another window must be closed there first."
                }
            }
        } catch { if current.libraryGeneration == generation { library.errorMessage = error.localizedDescription } }
    }
    private func deferSketchRecovery() {
        let id = recoveryClaimID ?? recoverySummary?.id
        recoverySummary = nil; recoveryClaimID = nil; recoveryDeferred = true
        if let id {
            let store = library.sketchDraftStore, owner = recoveryOwner
            Task { await store.release(id, owner: owner) }
        }
        handleCapturePresentation()
    }
    private func suspendSketchRecoveryPrompt() {
        let deferred = MobileSketchLifecyclePolicy.deferredAfterProgrammaticSuspend(wasDeferred: recoveryDeferred, hadPrompt: recoverySummary != nil)
        recoveryEpoch += 1
        deferSketchRecovery()
        // Programmatic dismissal must not masquerade as an explicit Not Now.
        recoveryDeferred = deferred
    }

    private func restoreSketchDraft(_ summary: MobileSketchDraftStore.Summary, inNewNote: Bool) {
        guard !recoveringSketch else { return }
        recoverySummary = nil; recoveryClaimID = nil; recoveryDeferred = true; recoveringSketch = true
        let epoch = recoveryEpoch
        let current = library, generation = library.libraryGeneration, store = library.sketchDraftStore, owner = recoveryOwner
        Task {
            var handedOff = false
            var targetMayRemain = false
            defer {
                recoveringSketch = false
                if !handedOff { Task { await store.release(summary.id, owner: owner) } }
                handleCapturePresentation()
            }
            do {
                guard try await store.claim(summary.id, owner: owner) else { throw MobileSketchDraftHost.Failure.stale }
                guard !summary.isProtected || current.privateAccess != nil else { throw MobileSketchDraftHost.Failure.keyRequired }
                let access = current.privateAccess
                guard let draft = try await store.load(summary.id, access: access),
                      let loadedSummary = try await store.discover().first(where: { $0.id == summary.id }),
                      loadedSummary.isProtected == summary.isProtected,
                      loadedSummary.generation == 0 || loadedSummary.generation == draft.generation else { throw MobileSketchDraftHost.Failure.stale }
                let requiresProtection = MobileSketchDraftRestorePolicy.requiresProtection(storedProtected: summary.isProtected, hasVault: current.hasNotePassword) {
                    guard let id = draft.originalNoteID else { return nil }
                    return try current.store.note(id: id)
                }
                guard !requiresProtection || (summary.isProtected && access != nil) else { throw MobileSketchDraftHost.Failure.keyRequired }
                @MainActor func stillCurrent() -> Bool {
                    let nowProtected = MobileSketchDraftRestorePolicy.requiresProtection(storedProtected: summary.isProtected, hasVault: current.hasNotePassword) {
                        guard let id = draft.originalNoteID else { return nil }
                        return try current.store.note(id: id)
                    }
                    return nowProtected == requiresProtection && current === library && current.libraryGeneration == generation && recoveryEpoch == epoch && phase == .active &&
                        !lifecycleSuspended && !current.appLocked && !current.isClosed && !current.isClosing && !current.libraryOperationBusy && !privacyCloseInFlight &&
                        (!summary.isProtected || (access != nil && current.privateAccess.map(ObjectIdentifier.init) == access.map(ObjectIdentifier.init)))
                }
                guard stillCurrent() else { throw CancellationError() }
                // The consent choice is made before creating a new target. No recovered pixels
                // or private title are written until a protected target has successfully locked.
                let decoder = Task.detached(priority: .userInitiated) { try Task.checkCancellation(); return try PKDrawing(data: draft.drawingData) }
                let drawing = try await withTaskCancellationHandler { try await decoder.value } onCancel: { decoder.cancel() }
                guard stillCurrent() else { throw CancellationError() }
                let noteID: String
                if inNewNote {
                    // Creation/locking may itself fail after creating the empty note.
                    targetMayRemain = true
                    noteID = try MobileSketchDraftRestorePolicy.createNewTarget(library: current, protected: summary.isProtected)
                } else {
                    guard let id = draft.originalNoteID, let note = try current.store.note(id: id),
                          note.deletedAt == nil, note.location == .notes, !note.isReadOnly, current.canRead(note),
                          !summary.isProtected || note.isLocked else {
                        throw MobileAttachmentError.stale
                    }
                    noteID = id
                }
                try current.reveal(noteID, in: sceneNavigation)
                for _ in 0..<150 {
                    guard stillCurrent() else { throw CancellationError() }
                    if editor.ready && editor.session?.noteId == noteID { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard stillCurrent(), editor.ready, editor.session?.noteId == noteID else { throw MobileAttachmentError.stale }
                editor.webView.endEditing(true)
                guard stillCurrent(), let operationID = mediaGate.begin() else { throw MobileAttachmentError.stale }
                if !inNewNote, let filename = draft.sourceFilename {
                    do {
                        guard let text = editor.session?.text,
                              let target = MobileSketchDraftRestorePolicy.freshTarget(filename: filename, text: text, noteID: noteID) else { throw MobileAttachmentError.stale }
                        let inspection = try await editor.inspectAttachmentForEditing(target)
                        guard stillCurrent(), MobileSketchDraftRestorePolicy.canUseOriginal(draft,
                            note: try current.store.note(id: noteID), canRead: true,
                            currentHash: inspection.origin.plaintextSHA256, protected: summary.isProtected) else { throw MobileAttachmentError.stale }
                        let storedNote = try current.store.note(id: noteID)
                        let request = MobileAttachmentEditRequest(lease: MobileAttachmentEditLease(gate: mediaGate, id: operationID),
                            editor: editor, target: target, intent: .sketch,
                            expectedLocked: summary.isProtected || storedNote?.isLocked == true, requiresEditable: true)
                        request.inspection = inspection
                        request.draftHost = makeSketchDraftHost(noteID: noteID, filename: filename, sourceHash: inspection.origin.plaintextSHA256,
                            recovered: draft, protected: summary.isProtected)
                        request.content = .sketch(drawing, draft.canvasSize)
                        guard request.lease.present() else { throw MobileAttachmentError.stale }
                        attachmentEditRequest = request; attachmentEditSheetID = operationID; showingAttachmentEdit = true
                    } catch { mediaGate.finish(operationID); throw error }
                } else {
                    do {
                        let origin = try await editor.captureAttachmentInsertionOrigin()
                        guard stillCurrent() else { throw CancellationError() }
                        let operation = MobileNewSketchInsertion(gate: mediaGate, operationID: operationID)
                        guard operation.requestPresentation() else { throw MobileAttachmentError.stale }
                        let host: MobileSketchDraftHost
                        if inNewNote {
                            host = makeSketchDraftHost(noteID: noteID, protected: summary.isProtected)
                            try await host.establishRecoveredCopy(from: draft)
                            guard stillCurrent() else { host.suspend(); throw CancellationError() }
                            try await operation.finishRecoveryHandoff(host: host,
                                releaseSource: { await store.release(draft.id, owner: owner) },
                                isCurrent: { stillCurrent() })
                        } else {
                            host = makeSketchDraftHost(noteID: noteID, recovered: draft, protected: summary.isProtected)
                        }
                        guard stillCurrent(), operation.canPresent, !Task.isCancelled else {
                            host.suspend(); operation.cancel(); _ = operation.didDismiss()
                            throw CancellationError()
                        }
                        sketchOperation = operation
                        newSketchRequest = NewSketchRequest(operationID: operationID, generation: mediaLifecycleGeneration, origin: origin,
                            editor: editor, drawing: drawing, canvasSize: draft.canvasSize, draftHost: host)
                        sketchSheetID = operationID; showingNewSketch = true
                    } catch { mediaGate.finish(operationID); throw error }
                }
                handedOff = true
            } catch {
                if current.libraryGeneration == generation, !(error is CancellationError) || targetMayRemain {
                    library.errorMessage = MobileSketchDraftRestorePolicy.copyFailureMessage(
                        targetMayRemain: targetMayRemain, detail: error is CancellationError ? "Recovery was interrupted." : error.localizedDescription)
                }
            }
        }
    }

    private func attachmentDraftAccessState(_ noteID: String?) -> MobileAttachmentDraftAccessState {
        // Observe refreshes, but never interpret absence from a search/tag result as deletion.
        _ = sceneObservation.items
        guard let noteID, let note = try? library.store.note(id: noteID) else {
            return MobileAttachmentDraftAccessState(note: nil, canRead: false)
        }
        return MobileAttachmentDraftAccessState(note: note, canRead: library.canRead(note))
    }

    private func beginAttachmentEdit(_ target: MobileAttachmentTarget, intent: MobileAttachmentEditIntent, fromMenu: Bool) {
        guard !attachmentBusy, !privacyCloseInFlight, !library.appLocked, phase == .active,
              !lifecycleSuspended, applicationState() == .active,
              !externalCaptureSheets.isPresented || fromMenu,
              let id = mediaGate.begin() else { return }
        guard let stored = try? library.store.note(id: target.noteID) else { mediaGate.finish(id); return }
        let request = MobileAttachmentEditRequest(lease: MobileAttachmentEditLease(gate: mediaGate, id: id),
            editor: editor, target: target, intent: intent,
            expectedLocked: stored.isLocked, requiresEditable: editor.canEditAttachment(target))
        attachmentEditRequest = request
        request.waitingForMenu = fromMenu
        if fromMenu { editor.attachmentTarget = nil }
        else { presentAttachmentEdit(request) }
    }

    private func startPendingAttachmentEdit() {
        guard let request = attachmentEditRequest, request.waitingForMenu, request.lease.canContinue else { return }
        request.waitingForMenu = false
        presentAttachmentEdit(request)
    }

    private func attachmentEditIsCurrent(_ request: MobileAttachmentEditRequest) -> Bool {
        attachmentEditRequest === request && request.lease.canContinue && editor === request.editor &&
            phase == .active && !lifecycleSuspended && applicationState() == .active &&
            !privacyCloseInFlight && !library.appLocked && !library.libraryOperationBusy &&
            sceneNavigation.selectedID == request.target.noteID
    }

    private func presentAttachmentEdit(_ request: MobileAttachmentEditRequest) {
        guard attachmentEditIsCurrent(request) else { cancelAttachmentEdit(); return }
        request.work = Task {
            guard !Task.isCancelled, attachmentEditIsCurrent(request) else { return }
            do {
                rememberSketchEditorFocus(request.editor)
                request.editor.webView.endEditing(true)
                // Read-only images retain their established preview/menu behavior.
                guard request.editor.canEditAttachment(request.target) else {
                    fallbackWithoutInspectionSheet(request); return
                }
                let inspection = try await request.editor.inspectAttachmentForEditing(request.target)
                try Task.checkCancellation()
                guard attachmentEditIsCurrent(request) else { throw CancellationError() }
                request.inspection = inspection
                let header = await Task.detached(priority: .userInitiated) { MobileAttachmentImagePresentation.inspect(inspection.bytes) }.value
                guard attachmentEditIsCurrent(request), !Task.isCancelled else { throw CancellationError() }
                guard header.isRaster else { fallbackWithoutInspectionSheet(request); return }
                if inspection.drawingData == nil, request.intent == .tap { fallbackWithoutInspectionSheet(request); return }
                guard request.lease.present() else { throw MobileAttachmentError.stale }
                attachmentEditSheetID = request.lease.id; showingAttachmentEdit = true
                if let archive = inspection.drawingData, let size = inspection.canvasSize {
                    if request.intent == .crop {
                        request.content = .message(MobileAttachmentEditFailure.editableSketchCannotBeCropped.localizedDescription)
                        return
                    }
                    guard size.width >= 1, size.height >= 1, size.width <= 4096, size.height <= 4096,
                          size.width * size.height <= 16_777_216 else {
                        request.content = .message("This sketch is larger than this editor supports. The original image has not changed.")
                        return
                    }
                    let decoder = Task.detached(priority: .userInitiated) { try Task.checkCancellation(); return try PKDrawing(data: archive) }
                    let drawing = try await withTaskCancellationHandler { try await decoder.value } onCancel: { decoder.cancel() }
                    guard attachmentEditIsCurrent(request), !Task.isCancelled else { throw CancellationError() }
                    let draft = makeSketchDraftHost(noteID: request.target.noteID,
                        filename: request.target.filename, sourceHash: inspection.origin.plaintextSHA256)
                    guard try await draft.reserveFresh() else { throw MobileSketchDraftHost.Failure.stale }
                    guard attachmentEditIsCurrent(request), !Task.isCancelled else { draft.suspend(); throw CancellationError() }
                    request.draftHost = draft
                    request.content = .sketch(drawing, size)
                } else if request.intent == .crop {
                    let prepared = try await MobileImageCrop.prepare(data: inspection.bytes)
                    guard attachmentEditIsCurrent(request), !Task.isCancelled else { throw CancellationError() }
                    request.content = header.hasSketchMetadata ? .cropWarning(prepared) : .crop(prepared)
                } else {
                    request.content = .message("This is an ordinary image without an editable sketch. View the image or choose Crop Image to edit a copy.")
                }
            } catch {
                guard attachmentEditIsCurrent(request), !(error is CancellationError) else {
                    if attachmentEditRequest === request { cancelAttachmentEdit() }
                    return
                }
                // A failed sketch decode is an ordinary image; backend already distinguishes
                // stale/privacy failures, so I/O errors remain visible without mutating bytes.
                if !request.lease.isPresented, request.lease.present() { attachmentEditSheetID = request.lease.id; showingAttachmentEdit = true }
                request.content = .message(error.localizedDescription)
            }
        }
    }

    private func manageSketchRecovery(_ host: MobileSketchDraftHost) {
        let current = library, generation = library.libraryGeneration
        recoveryCapacityModel = MobileSketchRecoveryCapacityModel(store: current.sketchDraftStore,
            currentDraftID: host.id, allowed: { [weak current] in
                guard let current else { return false }
                return current.libraryGeneration == generation && !current.appLocked &&
                    !current.isClosed && !current.isClosing && !current.libraryOperationBusy &&
                    UIApplication.shared.applicationState == .active
            })
    }

    private func fallbackWithoutInspectionSheet(_ request: MobileAttachmentEditRequest) {
        guard attachmentEditIsCurrent(request), !request.lease.isPresented else { return }
        request.lease.cancel()
        attachmentEditRequest = nil; attachmentEditSheetID = nil
        if request.editor.canExport, let url = try? request.editor.attachmentFile(request.target) { request.editor.previewURL = url }
        else { request.editor.attachmentTarget = request.target }
    }

    @ViewBuilder private func attachmentEditContent(_ request: MobileAttachmentEditRequest) -> some View {
        switch request.content {
        case .loading:
            VStack(spacing: 20) {
                Text("Attachment").font(.headline).accessibilityAddTraits(.isHeader)
                ProgressView("Opening image")
                Button("Cancel") { cancelAttachmentEdit() }
            }.padding()
        case .message(let message):
            VStack(spacing: 20) {
                Text("Attachment").font(.headline).accessibilityAddTraits(.isHeader)
                Text(message)
                Button("View Image") { request.fallback = true; showingAttachmentEdit = false }
                Button("Done") { cancelAttachmentEdit() }
            }.padding()
        case .sketch(let drawing, let size):
            if let view = try? MobileSketchEditor(initialDrawing: drawing, canvasSize: size,
                draftControl: request.draftHost?.control,
                onCheckpoint: { request.draftHost?.checkpoint($0) },
                preserveOnCancel: { request.draftHost?.keepsDraftOnCancel == true },
                onPreserveDraft: { try await request.draftHost?.prepareToKeepAfterSaveFailure() },
                onRestoreCopy: { if let host = request.draftHost { queueSketchCopy(host); cancelAttachmentEdit() } },
                onManageRecovery: { if let host = request.draftHost { manageSketchRecovery(host) } },
                onDone: { drawing, size in
                    do { try await saveAttachmentSketch(drawing, size: size, request: request) }
                    catch {
                        request.draftHost?.recordSaveFailure()
                        if error is CancellationError, phase != .background, !library.appLocked { throw MobileSketchDraftHost.Failure.stale }
                        throw error
                    }
                },
                onCancel: { discardAttachmentSketch(); }) {
                    view.sheet(item: $recoveryCapacityModel) { MobileSketchRecoveryCapacityView(model: $0) }
                }
            else {
                VStack(spacing: 20) {
                    Text("This sketch cannot be edited safely. The original image has not changed.")
                    Button("View Image") { request.fallback = true; showingAttachmentEdit = false }
                    Button("Done") { cancelAttachmentEdit() }
                }.padding()
            }
        case .cropWarning(let prepared):
            VStack(spacing: 20) {
                Text("Sketch Metadata").font(.headline).accessibilityAddTraits(.isHeader)
                Text("This PNG carries sketch metadata that could not be opened. Cropping a copy removes its editable strokes; the original attachment is kept for Undo.")
                Button("Crop Copy Anyway") { guard attachmentEditIsCurrent(request) else { return }; request.content = .crop(prepared) }
                Button("Keep Original", role: .cancel) { cancelAttachmentEdit() }
            }.padding()
        case .crop(let prepared):
            MobileImageCropView(prepared: prepared, onComplete: { png in
                try await saveAttachmentEdit(png, request: request, mode: .crop)
            }, onCancel: { cancelAttachmentEdit() })
        }
    }

    private func saveAttachmentSketch(_ drawing: PKDrawing, size: CGSize, request: MobileAttachmentEditRequest) async throws {
        guard attachmentEditIsCurrent(request), size.width.isFinite, size.height.isFinite,
              size.width >= 1, size.height >= 1, size.width <= 4096, size.height <= 4096,
              size.width * size.height <= 16_777_216 else { throw MobileAttachmentError.stale }
        let archive = drawing.dataRepresentation()
        guard archive.count <= MobileSketchPNG.maximumDrawingBytes else { throw MobileSketchPNG.Failure.tooLarge }
        request.draftHost?.checkpoint(MobileSketchCheckpoint(drawingData: archive, canvasSize: size))
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let drawing = try PKDrawing(data: archive)
            let image = drawing.image(from: CGRect(origin: .zero, size: size), scale: 1)
            try Task.checkCancellation()
            guard let pixels = image.cgImage else { throw MobileSketchPNG.Failure.invalidPNG }
            return try MobileSketchPNG.embed(drawingData: archive, in: MobileSketchPNG.pngForNewSketch(from: pixels))
        }
        request.render = worker
        defer { request.render = nil }
        let png = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try await saveAttachmentEdit(png, request: request, mode: .sketch)
    }

    private func saveAttachmentEdit(_ png: Data, request: MobileAttachmentEditRequest, mode: MobileAttachmentEditMode) async throws {
        try Task.checkCancellation()
        guard attachmentEditIsCurrent(request), let inspection = request.inspection else { throw MobileAttachmentError.stale }
        // Persist uncertainty before a writer can commit; subsequent autosaves cannot clear it.
        if let draft = request.draftHost { try await draft.prepareForWrite() }
        // Backend owns source fingerprint/operation checks and the uncertain-ACK retry latch.
        try await request.editor.saveEditedAttachment(png: png, origin: inspection.origin, mode: mode)
        try Task.checkCancellation()
        guard attachmentEditIsCurrent(request) else { throw CancellationError() }
        if let draft = request.draftHost { try await draft.confirmedSave() }
        showingAttachmentEdit = false
    }

    private func cancelAttachmentEdit() {
        guard let request = attachmentEditRequest else { return }
        request.draftHost?.suspend()
        request.cancel(); showingAttachmentEdit = false
        if !request.lease.isPresented {
            attachmentEditRequest = nil; attachmentEditSheetID = nil
        }
    }

    private func finishAttachmentEditDismissal(_ id: UUID?) {
        guard let id, let request = attachmentEditRequest, request.lease.id == id,
              attachmentEditSheetID == id else { return }
        let fallback = request.fallback && attachmentEditIsCurrent(request)
        _ = request.lease.didDismiss()
        request.work?.cancel(); request.render?.cancel()
        request.editor.cancelAttachmentReads()
        attachmentEditRequest = nil; attachmentEditSheetID = nil
        if fallback {
            // This executes only after the root edit sheet's native dismissal, never alongside it.
            if request.editor.canExport, let url = try? request.editor.attachmentFile(request.target) {
                request.editor.previewURL = url
            } else { request.editor.attachmentTarget = request.target }
        }
        handleCapturePresentation()
        continueSketchCopyAfterDismissal()
        Task { await refreshSketchRecovery() }
        restoreSketchEditorFocus()
    }

    private func finishMediaCapture(_ result: Result<MobileMediaBatch?, any Error>, operationID: UUID?) {
        guard let operationID, mediaGate.finish(operationID) else {
            if case .success(let batch?) = result { batch.remove() }
            return
        }
        defer { if !attachmentInFlight { handleCapturePresentation() } }
        showingCamera = false
        showingDocumentScanner = false
        let origin = attachmentOrigin
        let captureAllowed = activeCapturePresentation.map { captureRouter?.canAcceptScan($0, owner: capturePresentationOwner) == true } ?? true
        attachmentOrigin = nil
        switch result {
        case .failure(let error):
            attachmentInFlight = false; finishCapturePresentation(); library.errorMessage = error.localizedDescription
        case .success(nil): attachmentInFlight = false; finishCapturePresentation()
        case .success(let batch?):
            guard let origin, captureAllowed else {
                batch.remove()
                attachmentInFlight = false; finishCapturePresentation()
                if !captureAllowed { library.errorMessage = MobileAttachmentError.stale.localizedDescription }
                return
            }
            let generation = mediaLifecycleGeneration
            Task {
                defer {
                    batch.remove()
                    if generation == mediaLifecycleGeneration { attachmentInFlight = false; finishCapturePresentation(); handleCapturePresentation() }
                }
                do { try await editor.insertFiles(batch.files, origin: origin) }
                catch { if generation == mediaLifecycleGeneration { library.errorMessage = error.localizedDescription } }
            }
        }
    }

    private func cancelUnfinishedMedia(operationID: UUID?) {
        guard let operationID, attachmentOrigin != nil, mediaGate.finish(operationID) else { return }
        attachmentOrigin = nil
        attachmentInFlight = false
        finishCapturePresentation()
        handleCapturePresentation()
    }

    /// Invalidate ownership before dismissing native pickers: their late callbacks cannot
    /// clear a newer operation or reopen a sheet after the privacy boundary.
    private func resetMediaPresentations() {
        sketchFocusReturn = nil
        cancelAttachmentEdit()
        cancelNewSketch()
        suspendVoicePresentation()
        mediaLifecycleGeneration += 1
        mediaGate.invalidate()
        attachmentOrigin = nil
        preparingAttachment = false; attachmentInFlight = false
        importingFile = false; importingNotes = false
        showingPhotos = false; showingCamera = false; showingDocumentScanner = false
        cameraSheetID = nil; scannerSheetID = nil
        finishCapturePresentation()
        if let router = captureRouter, let request = router.presentation, request.action != .voice,
           router.presentationOwner == capturePresentationOwner {
            router.finishPresentation(deliveryID: request.id, owner: capturePresentationOwner)
            releaseCaptureRoutingLease(request.id)
        }
    }

    private func claimCapturePresentation(_ request: MobileCaptureRouter.Presentation, router: MobileCaptureRouter) -> Bool {
        guard sceneRegistered, phase == .active, !library.appLocked, !library.sceneOperationPending,
              let token = library.beginSceneRoutingLease(sceneID: sceneNavigation.id, deliveryID: request.id,
                  noteID: request.action == .scan ? request.noteID : nil) else { return false }
        guard router.claimPresentation(request, owner: capturePresentationOwner) else {
            library.releaseSceneRoutingLease(token); return false
        }
        captureRoutingLease = (request.id, token)
        library.prepareLegacyNavigationContext(for: sceneNavigation.id)
        return true
    }
    private func releaseCaptureRoutingLease(_ deliveryID: UUID) {
        guard let lease = captureRoutingLease, lease.deliveryID == deliveryID else { return }
        captureRoutingLease = nil
        library.releaseSceneRoutingLease(lease.token)
    }
    private func uncoverActiveSceneIfSafe() {
        guard phase == .active, applicationState() == .active, !privacyClosePending,
              !privacyCloseInFlight, !library.isClosed, !library.isClosing else { return }
        // App Lock's native screen must remain usable, after private pages and modal UI close.
        if library.appLocked { guard editor.session == nil, !editor.ready else { return } }
        MobilePrivacyShield.uncover(in: sceneWindow.window)
    }

    private func handleCapturePresentation() {
        if captureRouter?.presentation == nil { Task { await refreshSketchRecovery() } }
        guard sceneRegistered, phase == .active, !privacyCloseInFlight, !library.appLocked,
              !library.libraryOperationBusy, !library.sceneOperationPending,
              let router = captureRouter, let request = router.presentation,
              router.presentationOwner == capturePresentationOwner || library.isPreferredActiveScene(id: sceneNavigation.id,
                  noteID: request.action == .scan ? request.noteID : nil) else { return }
        if router.discardUnclaimedStaleScan() {
            library.errorMessage = MobileAttachmentError.stale.localizedDescription
            Task { do { try await router.drain() } catch { library.errorMessage = error.localizedDescription } }
            return
        }
        if request.action == .voice {
            guard voiceSheetRequest == nil, !voiceTeardownInFlight, !attachmentBusy,
                  !showingSettings, !showingQuickOpen, !showingTemplates, !showingInfo,
                  passwordAction == nil, sharedMarkdown == nil, editingTag == nil, sortInbox == nil,
                  editor.linkRequest == nil, !exporting, editor.previewURL == nil,
                  editor.attachmentTarget == nil, !externalCaptureSheets.isPresented, templateID == nil,
                  !library.voiceCapture.isBusy,
                  claimCapturePresentation(request, router: router) else { return }
            voiceSheetRequest = request
            voiceSheetDismissed = false; voiceTeardownComplete = false
            voiceCaptureModel = library.voiceCapture
            showingVoice = true
            return
        }
        if request.action == .search {
            guard claimCapturePresentation(request, router: router) else { return }
            searchFocused = true
            router.finishPresentation(deliveryID: request.id, owner: capturePresentationOwner)
            releaseCaptureRoutingLease(request.id)
            Task { do { try await router.drain() } catch { library.errorMessage = error.localizedDescription } }
            return
        }
        guard request.action == .scan, !preparingAttachment, !attachmentInFlight, attachmentOrigin == nil,
              cameraSheetID == nil, scannerSheetID == nil, sketchSheetID == nil,
              editor.ready, editor.session?.noteId == request.noteID, router.canAcceptScan(request) else { return }
        guard claimCapturePresentation(request, router: router) else { return }
        guard let operationID = mediaGate.begin() else {
            router.releasePresentation(deliveryID: request.id, owner: capturePresentationOwner)
            releaseCaptureRoutingLease(request.id)
            return
        }
        preparingAttachment = true
        attachmentInFlight = true
        let generation = mediaLifecycleGeneration
        Task {
            defer { if generation == mediaLifecycleGeneration { preparingAttachment = false; handleCapturePresentation() } }
            do {
                let origin = try await editor.captureAttachmentInsertionOrigin()
                guard generation == mediaLifecycleGeneration, mediaGate.isCurrent(operationID),
                      !library.appLocked, phase == .active, router.canAcceptScan(request, owner: capturePresentationOwner) else { throw MobileAttachmentError.stale }
                attachmentOrigin = origin
                activeCapturePresentation = request
                scannerSheetID = mediaOperationID
                showingDocumentScanner = true
            } catch {
                guard generation == mediaLifecycleGeneration, mediaGate.finish(operationID) else { return }
                attachmentInFlight = false
                library.errorMessage = error.localizedDescription
                router.finishPresentation(deliveryID: request.id, owner: capturePresentationOwner)
                releaseCaptureRoutingLease(request.id)
                do { try await router.drain() } catch { library.errorMessage = error.localizedDescription }
            }
        }
    }

    private func finishCapturePresentation() {
        guard let request = activeCapturePresentation, let router = captureRouter else { return }
        activeCapturePresentation = nil
        router.finishPresentation(deliveryID: request.id, owner: capturePresentationOwner)
        releaseCaptureRoutingLease(request.id)
        Task { do { try await router.drain() } catch { library.errorMessage = error.localizedDescription } }
    }

    /// Keep the single-owner claim until all microphone/preflight teardown has finished.
    /// A late onDismiss callback cannot finish or cancel a newer request.
    private func finishVoicePresentation(_ request: MobileCaptureRouter.Presentation, suspend: Bool) {
        guard voiceSheetRequest?.id == request.id, !voiceTeardownInFlight,
              let model = voiceCaptureModel else { return }
        voiceTeardownInFlight = true
        if suspend { model.prepareForBackground() } // Hide words synchronously before suspension.
        showingVoice = false
        Task { @MainActor in
            if suspend { await model.suspendForBackground() }
            else { await model.finishForDismissal() }
            guard voiceSheetRequest?.id == request.id else { return }
            voiceTeardownComplete = true
            completeVoiceDismissal(request)
        }
    }

    private func completeVoiceDismissal(_ request: MobileCaptureRouter.Presentation) {
        guard voiceSheetRequest?.id == request.id, voiceTeardownComplete, voiceSheetDismissed else { return }
        voiceCaptureModel = nil
        voiceSheetRequest = nil
        voiceTeardownInFlight = false; voiceTeardownComplete = false
        let router = captureRouter
        router?.finishPresentation(deliveryID: request.id, owner: capturePresentationOwner)
        releaseCaptureRoutingLease(request.id)
        if phase == .active, !library.appLocked {
            Task {
                do { try await router?.drain() } catch { library.errorMessage = error.localizedDescription }
                handleCapturePresentation()
            }
        }
    }

    private func suspendVoicePresentation() {
        if let request = voiceSheetRequest { finishVoicePresentation(request, suspend: true) }
    }

    private func releaseCaptureForDisappearingScene() {
        if let request = voiceSheetRequest {
            voiceSheetDismissed = true // The owning scene itself is gone; no sheet can remain.
            suspendVoicePresentation()
            completeVoiceDismissal(request)
            return
        }
        guard let router = captureRouter, let request = router.presentation,
              router.presentationOwner == capturePresentationOwner else { return }
        // Once bytes are being inserted, another window must not present the same request.
        if activeCapturePresentation?.id == request.id, attachmentInFlight, attachmentOrigin == nil, !preparingAttachment { return }
        if activeCapturePresentation?.id == request.id {
            if let operationID = mediaOperationID { mediaGate.finish(operationID) }
            activeCapturePresentation = nil
            attachmentOrigin = nil
            attachmentInFlight = false
            showingDocumentScanner = false
        }
        router.releasePresentation(deliveryID: request.id, owner: capturePresentationOwner)
        releaseCaptureRoutingLease(request.id)
    }

    var body: AnyView { AnyView(libraryPresentations) }
    private var libraryPresentations: some View {
        AnyView(sketchRecoveryPresentations).fileExporter(isPresented: $exporting, document: exportDocument, contentType: exportType, defaultFilename: exportName) { result in
            if case .failure(let error) = result { library.errorMessage = error.localizedDescription }
            exportDocument = nil
            handleCapturePresentation()
        }
        .confirmationDialog("Permanently delete this note? This cannot be undone.", isPresented: Binding(get: { deleteID != nil }, set: { if !$0 { deleteID = nil } })) {
            if let candidate = deleteID {
                Button("Delete Permanently", role: .destructive) {
                    deleteID = nil
                    Task {
                        do { _ = try await library.deleteTrashedNotesAfterDraining([candidate]) }
                        catch { library.errorMessage = error.localizedDescription }
                    }
                }
            }
        }
        .confirmationDialog(trashDeletionTitle, isPresented: Binding(get: { !pendingTrashDeletion.isEmpty }, set: { if !$0 { pendingTrashDeletion = [] } }), titleVisibility: .visible) {
            let candidates = pendingTrashDeletion
            Button(candidates.count == 1 ? "Delete 1 Note Permanently" : "Delete \(candidates.count) Notes Permanently", role: .destructive) {
                pendingTrashDeletion = []
                Task {
                    do {
                        let deleted = try await library.deleteTrashedNotesAfterDraining(candidates)
                        selectedNotes.subtract(deleted)
                        if selectedNotes.isEmpty { selecting = false }
                    } catch { library.errorMessage = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) { pendingTrashDeletion = [] }
        } message: {
            Text("These notes and their attachments will be permanently deleted. This cannot be undone.")
        }
        .sheet(item: $sharedMarkdown, onDismiss: { handleCapturePresentation() }) { item in MobileMarkdownShareView(text: item.text) }
        .mobileQuickLookPreview($editor.previewURL,
            onPresented: { externalCaptureSheets.presented($0) },
            onDismissed: { externalCaptureSheets.dismissed($0); handleCapturePresentation() })
        .mobileAttachmentActions(editor: editor,
            onEdit: { target, intent in beginAttachmentEdit(target, intent: intent, fromMenu: true) },
            onPresented: { externalCaptureSheets.presented($0) },
            onDismissed: {
                externalCaptureSheets.dismissed($0)
                startPendingAttachmentEdit()
                handleCapturePresentation()
            })
        .confirmationDialog("Table Cell", isPresented: Binding(get: { editor.tableMenu != nil }, set: { if !$0 { editor.tableMenu = nil } })) {
            if let request = editor.tableMenu {
                Button("Add Row Below") { tableCommand(.tableAddRow, request: request) }.disabled(!editor.editable)
                Button("Add Column After") { tableCommand(.tableAddColumn, request: request) }.disabled(!editor.editable)
                Button("Delete Row") { tableCommand(.tableDeleteRow, request: request) }.disabled(!editor.editable)
                Button("Delete Column") { tableCommand(.tableDeleteColumn, request: request) }.disabled(!editor.editable)
                Button("Move Row Up") { tableCommand(.tableMoveRow, request: request, direction: "up") }.disabled(!editor.editable || request.row == 0)
                Button("Move Row Down") { tableCommand(.tableMoveRow, request: request, direction: "down") }.disabled(!editor.editable || request.row + 1 >= request.rows)
                Button("Move Column Left") { tableCommand(.tableMoveColumn, request: request, direction: "left") }.disabled(!editor.editable || request.column == 0)
                Button("Move Column Right") { tableCommand(.tableMoveColumn, request: request, direction: "right") }.disabled(!editor.editable || request.column + 1 >= request.columns)
                ForEach(Self.tableCopyFormats, id: \.format) { entry in
                    Button(entry.label) {
                        editor.command(.copyTable, args: ["menuId": .string(request.menuId), "format": .string(entry.format)])
                        editor.tableMenu = nil
                    }.disabled(!editor.canExport)
                }
            }
        }
        .confirmationDialog("Callout Type", isPresented: Binding(get: { editor.calloutMenu != nil }, set: { if !$0 { editor.calloutMenu = nil } })) {
            if let request = editor.calloutMenu {
                ForEach(CalloutType.allCases, id: \.rawValue) { type in
                    Button(type.rawValue.capitalized) {
                        editor.command(.setCalloutType, args: ["type": .string(type.rawValue), "menuId": .string(request.menuId)])
                        editor.calloutMenu = nil
                    }
                }
            }
        }
        .confirmationDialog("Heading", isPresented: Binding(get: { editor.headingMenu != nil }, set: { if !$0 { editor.headingMenu = nil } })) {
            if let request = editor.headingMenu {
                Button("Copy Link to Here") {
                    library.perform {
                        if let link = try library.headingLink(for: request, in: sceneNavigation) { UIPasteboard.general.string = link }
                        editor.headingMenu = nil
                    }
                }.disabled((try? library.headingLink(for: request, in: sceneNavigation)) == nil)
                Button(request.folded ? "Unfold" : "Fold") {
                    editor.command(.toggleFold, args: ["menuId": .string(request.menuId)])
                    editor.headingMenu = nil
                }
                Button("Fold All Headings") { editor.command(.foldAll); editor.headingMenu = nil }
                Button("Unfold All Headings") { editor.command(.unfoldAll); editor.headingMenu = nil }
                ForEach(editor.editable ? Array(1...6) : [], id: \.self) { level in
                    Button("Heading \(level)") {
                        editor.command(.heading, args: ["level": .int(level), "menuId": .string(request.menuId)])
                        editor.headingMenu = nil
                    }
                }
            }
        }
        .sheet(item: $passwordAction, onDismiss: {
            pendingLockID = nil; pendingRemoveLockID = nil
            if recoveryAfterUnlock, library.privateAccess != nil {
                recoveryAfterUnlock = false; Task { await refreshSketchRecovery(force: true) }
            } else { recoveryAfterUnlock = false; handleCapturePresentation() }
        }) { action in
            MobilePasswordPrompt(library: library, action: action) { completePasswordAction() }
        }
        .sheet(isPresented: $showingSettings, onDismiss: {
            editor.appearance(dark: colorScheme == .dark, increasedContrast: contrast == .increased)
            dismissOverlappingSidebar()
            handleCapturePresentation()
            if recoveryFromSettings {
                recoveryFromSettings = false; Task { await refreshSketchRecovery(force: true) }
            }
        }) { MobileSettings(library: library, showTag: { selectScope(.tag($0)) }) }
        .sheet(isPresented: $showingQuickOpen, onDismiss: { [generation = captureTransitionGeneration] in
            guard generation == captureTransitionGeneration else {
                if pendingQuickOpenTemplateGeneration == generation {
                    templateID = nil; pendingQuickOpenTemplateGeneration = nil
                }
                handleCapturePresentation() // Re-evaluates current privacy/modal gates; never reopens an old template.
                return
            }
            guard phase == .active, !library.appLocked, !privacyCloseInFlight else {
                templateID = nil; pendingQuickOpenTemplateGeneration = nil; return
            }
            if pendingQuickOpenTemplateGeneration == generation, templateID != nil {
                pendingQuickOpenTemplateGeneration = nil
                showingTemplates = true
            } else { handleCapturePresentation() }
        }) {
            let generation = captureTransitionGeneration
            MobileQuickOpen(library: library, navigation: sceneNavigation) { id in
                guard generation == captureTransitionGeneration, phase == .active, !library.appLocked else { return }
                templateID = id; pendingQuickOpenTemplateGeneration = generation
            }
        }
        .sheet(isPresented: $showingTemplates, onDismiss: { templateID = nil; handleCapturePresentation() }) { MobileTemplatePicker(library: library, initialID: templateID, navigation: sceneNavigation) }
        .sheet(item: $editingTag, onDismiss: { handleCapturePresentation() }) { MobileTagEditor(library: library, tag: $0, navigation: sceneNavigation) }
        .sheet(isPresented: $showingInfo, onDismiss: { handleCapturePresentation() }) { MobileInfoPanel(library: library, editor: editor, navigation: sceneNavigation) }
        .sheet(item: $sortInbox, onDismiss: {
            retainedSortInboxes.last?.discardPendingQueue()
            retainedSortInboxes.removeAll { $0.historyCount == 0 && !$0.undoing }
            handleCapturePresentation()
        }) { model in
            MobileSortInboxSheet(model: model, library: library, navigation: sceneNavigation)
        }
        .sheet(isPresented: Binding(get: { editor.linkRequest != nil }, set: { if !$0 { editor.linkRequest = nil } }), onDismiss: { handleCapturePresentation() }) {
            MobileSheetChrome(title: "Link", leading: { Button("Cancel") { editor.linkRequest = nil } }, trailing: {
                Button("Save") {
                    if let request = editor.linkRequest {
                        editor.command(.setLink, args: ["requestId": .string(request.requestId), "title": .string(linkTitle), "url": .string(linkURL)])
                    }
                    editor.linkRequest = nil
                }
                // No empty link; the first empty field takes the keyboard.
                .buttonStyle(.glassProminent)
                .disabled(linkURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }) {
                MobileLinkFields(title: $linkTitle, url: $linkURL,
                                 initialTitle: editor.linkRequest?.title ?? "", initialURL: editor.linkRequest?.url ?? "")
            }.presentationDetents([.medium])
        }
        .overlay {
            if library.libraryOperationBusy && library.sync.syncing && !library.appLocked {
                MobileInitialSyncProgress(library: library, sync: library.sync)
            }
        }
        .overlay {
            if library.appLocked { MobileAppUnlockScreen(library: library).frame(maxWidth: .infinity, maxHeight: .infinity).background(.background) }
        }
    }

    private var sidebar: AnyView { AnyView(sidebarContent) }
    private var sidebarContent: some View {
        List(selection: Binding<SidebarScope?>(get: { sceneNavigation.scope }, set: { value in
            if let value { selectScope(value) }
        })) {
            if let workspace = sceneNavigation.workspace {
                // Leaving the workspace is "All Notes" in the Workspaces menu only.
                Section {
                    Label(workspace.path, systemImage: "rectangle.3.group").font(.headline)
                } header: { Text("Workspace") }
            }
            Section {
                scopeRow("Notes", "doc.text", .notes, sceneObservation.snapshot.counts.notes)
                scopeRow("Inbox", "tray", .inbox, sceneObservation.snapshot.counts.inbox)
                scopeRow("Ideas", "lightbulb", .type(.idea), sceneObservation.snapshot.counts.ideas)
                scopeRow("Logs", "clock", .type(.log), sceneObservation.snapshot.counts.logs)
                scopeRow("References", "bookmark", .type(.reference), sceneObservation.snapshot.counts.references)
                scopeRow("Pinned", "pin", .pinned, sceneObservation.snapshot.counts.pinned)
                scopeRow("Untagged", "tag.slash", .untagged, sceneObservation.snapshot.counts.untagged)
                scopeRow("To Do", "checkmark.circle", .todo, sceneObservation.snapshot.counts.todo)
                scopeRow("Today", "sun.max", .today, sceneObservation.snapshot.counts.today)
                if sceneObservation.snapshot.counts.locked > 0 { scopeRow("Locked", "lock", .locked, sceneObservation.snapshot.counts.locked) }
            }
            if !sceneObservation.snapshot.tagTree.isEmpty {
                Section("Tags") {
                    OutlineGroup(sceneObservation.snapshot.tagTree, children: \.optionalChildren) { tag in
                        Label(tag.name, systemImage: tag.iconName ?? "number")
                            .badge(library.settings.showNoteCounts ? tag.noteCount : 0).tag(SidebarScope.tag(tag.path))
                            .dropDestination(for: String.self) { ids, _ in
                                do {
                                    try library.flush()
                                    let editable = try ids.filter { id in
                                        guard let note = try library.store.note(id: id) else { return false }
                                        return !note.isLocked && !note.isReadOnly && note.location == .notes
                                    }
                                    guard !editable.isEmpty else { return false }
                                    try library.store.addTag(tag.path, to: editable, position: library.settings.tagPosition)
                                    try library.refreshSessions()
                                    return true
                                } catch { library.errorMessage = error.localizedDescription; return false }
                            }
                            .contextMenu {
                                Button("Edit Tag", systemImage: "pencil") { editingTag = tag }
                                Button("Use as Workspace", systemImage: "rectangle.3.group") { library.perform { try enterWorkspace(tag.path) } }
                                Menu("Export Tag Tree", systemImage: "square.and.arrow.up") {
                                    ForEach(MobileExportFormat.allCases, id: \.self) { format in
                                        Button(format.title) { exportTag(tag.path, format: format) }
                                    }
                                    MobileExportChoices(library: library)
                                }.disabled(exportBusy)
                            }
                    }
                }
            }
            Section {
                scopeRow("Archive", "archivebox", .archive, sceneObservation.snapshot.counts.archive)
                scopeRow("Trash", "trash", .trash, sceneObservation.snapshot.counts.trash)
            }
        }
        // The floating Library Options button never sits on the last row.
        .contentMargins(.bottom, Self.floatingBarClearance, for: .scrollContent)
        .navigationTitle("Theo Notes")
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Menu {
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                    Button("Recovered Sketches", systemImage: "arrow.counterclockwise") { Task { await refreshSketchRecovery(force: true) } }
                    Button("Import Notes", systemImage: "square.and.arrow.down") { importingNotes = true; importingFile = true }.disabled(importBusy)
                } label: { Label("Library Options", systemImage: "books.vertical") }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("All Notes") { library.perform { try enterWorkspace(nil) } }
                    ForEach(sceneObservation.snapshot.workspaceChoices.recent, id: \.key) { workspace in
                        Button(workspace.path) { library.perform { try enterWorkspace(workspace.path) } }
                    }
                    ForEach(sceneObservation.snapshot.workspaceChoices.pinned.filter { pin in !sceneObservation.snapshot.workspaceChoices.recent.contains(pin) }, id: \.key) { workspace in
                        Button(workspace.path) { library.perform { try enterWorkspace(workspace.path) } }
                    }
                } label: { Label("Workspaces", systemImage: "rectangle.3.group") }
            }
        }
    }

    private func dismissOverlappingSidebar() {
        // Preserve a side-by-side sidebar; dismiss only one covering the list.
        if horizontalSizeClass == .compact {
            preferredColumn = .content
        } else if !sidebarFrame.isNull, !noteListFrame.isNull, sidebarFrame.intersects(noteListFrame) {
            visibility = .doubleColumn
        }
    }

    private func selectScope(_ scope: SidebarScope) {
        sceneNavigation.scope = scope; sceneNavigation.query = ""; sceneNavigation.selectedID = nil; preferredColumn = .content
        dismissOverlappingSidebar()
    }

    /// Height of a floating bottom-bar pill (about 50 points) plus a margin.
    static let floatingBarClearance: CGFloat = 64
    /// One label form in Note Actions and in the table cell dialog.
    static let tableCopyFormats: [(format: String, label: String)] = [
        ("markdown", "Copy Table as Markdown"), ("html", "Copy Table as HTML"), ("csv", "Copy Table as CSV"),
    ]
    static let sectionKeys: [(key: KeyEquivalent, title: String, scope: SidebarScope)] = [
        ("1", "Notes", .notes), ("2", "Untagged", .untagged), ("3", "To Do", .todo), ("4", "Today", .today),
        ("5", "Locked", .locked), ("6", "Pinned", .pinned), ("9", "Archive", .archive), ("0", "Trash", .trash),
    ]

    private func scopeRow(_ title: String, _ icon: String, _ scope: SidebarScope, _ count: Int) -> some View {
        Label(title, systemImage: icon).badge(library.settings.showNoteCounts ? count : 0).tag(scope).accessibilityIdentifier("scope-\(title)")
    }

    private var noteList: AnyView { AnyView(noteListContent) }
    private var noteListContent: some View {
        List(selection: $sceneNavigation.selectedID) {
            if sceneNavigation.scope == .inbox && !sceneObservation.items.isEmpty {
                Button("Sort Inbox", systemImage: "tray.full") {
                    let generation = captureTransitionGeneration
                    Task {
                        do {
                            let model = try await library.withDrainedEditor {
                                try library.flush()
                                return try MobileSortInboxModel(library: library, navigation: sceneNavigation)
                            }
                            guard generation == captureTransitionGeneration, phase == .active, !library.appLocked, sceneNavigation.scope == .inbox else {
                                model.invalidate()
                                return
                            }
                            retainedSortInboxes.append(model)
                            sortInbox = model
                        } catch { library.errorMessage = error.localizedDescription }
                    }
                }.accessibilityIdentifier("sort-inbox")
            }
            if let message = library.recoveryMessage {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            if library.missingJournalRecoveryUnresolved {
                Button("Try Again", systemImage: "arrow.clockwise") {
                    library.retryMissingJournalRecovery()
                    Task { try? await library.resumeConfirmedJournalQuarantines() }
                }
            }
            if !library.quarantineOffer.isEmpty {
                Button("Move Recovery Files Aside", systemImage: "folder") {
                    do { pendingQuarantine = try library.prepareJournalQuarantine() }
                    catch { library.errorMessage = "The recovery files changed. Try again." }
                }
            }
            ForEach(library.recoveredVariantNotices) { notice in
                VStack(alignment: .leading) {
                    Text("Recovered variants: the original pairing is uncertain.").font(.callout)
                    ForEach(Array(notice.noteIDs.enumerated()), id: \.element) { index, noteID in
                        Button("Open Recovered Variant \(index + 1)", systemImage: "doc.text") {
                            library.perform { try reveal(noteID) }
                        }
                    }
                    Button("Remove Variant Recovery Files", systemImage: "doc.badge.ellipsis") {
                        pendingVariantRetirement = PendingJournalRetirement(id: notice.id,
                            libraryGeneration: library.libraryGeneration, sceneGeneration: library.sceneRoutingGeneration)
                    }
                }
            }
            ForEach(library.recoveredJournalNotices) { notice in
                VStack(alignment: .leading) {
                    Button("Open Recovered Note", systemImage: "doc.text") {
                        library.perform { try reveal(notice.noteID) }
                    }
                    Button("Remove Leftover Recovery Files", systemImage: "doc.badge.ellipsis") {
                        pendingJournalRetirement = PendingJournalRetirement(id: notice.id,
                            libraryGeneration: library.libraryGeneration, sceneGeneration: library.sceneRoutingGeneration)
                    }
                }
            }
            if library.tagUndo != nil {
                Button("Undo Tag Edit", systemImage: "arrow.uturn.backward") { library.perform { try library.undoTagEdit() } }
            }
            ForEach(sceneObservation.items) { note in
                Group {
                    if selecting {
                        Button {
                            if !selectedNotes.insert(note.id).inserted { selectedNotes.remove(note.id) }
                        } label: {
                            HStack {
                                Image(systemName: selectedNotes.contains(note.id) ? "checkmark.circle.fill" : "circle")
                                MobileNoteRow(note: note, preferences: library.preferences, paths: library.paths, searchTerms: searchTerms)
                            }
                        }
                        // A list with a selection binding swallows plain row buttons on iPad; borderless ones still fire.
                        .buttonStyle(.borderless).tint(.primary)
                        .accessibilityAddTraits(selectedNotes.contains(note.id) ? [.isSelected] : [])
                    } else {
                        NavigationLink(value: note.id) { MobileNoteRow(note: note, preferences: library.preferences, paths: library.paths, searchTerms: searchTerms) }
                            .onDrag { (try? MobileNoteSceneActivation.dragProvider(noteID: note.id, library: library)) ?? NSItemProvider() }
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if sceneNavigation.scope != .trash {
                        Button("Trash", systemImage: "trash", role: .destructive) { move(note.id, to: .trash) }
                    }
                    if sceneNavigation.scope == .trash || sceneNavigation.scope == .archive {
                        Button("Restore", systemImage: "arrow.uturn.backward") { move(note.id, to: .notes) }.tint(.green)
                    } else {
                        Button("Archive", systemImage: "archivebox") { move(note.id, to: .archive) }.tint(.orange)
                    }
                }
                .swipeActions(edge: .leading) {
                    Button(note.isPinned ? "Unpin" : "Pin", systemImage: note.isPinned ? "pin.slash" : "pin") {
                        library.perform { try togglePin(note) }
                    }.tint(Color.accentColor)
                }
                .contextMenu {
                    Button("Copy Link to Note", systemImage: "link") { UIPasteboard.general.string = MobileShortcutCapture.noteLink(id: note.id).absoluteString }
                    Button("Copy Identifier", systemImage: "number") { UIPasteboard.general.string = note.id }
                    if MobileNoteSceneActivation.supportsMultipleWindows {
                        Button("Open in New Window", systemImage: "macwindow.badge.plus") {
                            library.perform { openWindow(value: try MobileNoteSceneActivation.requestedAddress(noteID: note.id, library: library)) }
                        }
                    }
                    Button(note.isPinned ? "Unpin" : "Pin", systemImage: "pin") { library.perform { try togglePin(note) } }
                    Button("Duplicate", systemImage: "plus.square.on.square") {
                        library.perform { try library.flush(); let copy = try library.store.duplicate(id: note.id); try reveal(copy.id) }
                    }.disabled(note.isLocked)
                    if sceneNavigation.scope == .trash {
                        Button("Restore", systemImage: "arrow.uturn.backward") { move(note.id, to: .notes) }
                        Button("Delete Permanently", systemImage: "trash", role: .destructive) { deleteID = note.id }
                    } else { Button("Move to Trash", systemImage: "trash", role: .destructive) { move(note.id, to: .trash) } }
                }
            }
        }
        .listStyle(.plain)
        // The floating search and bottom-bar pill never covers the last row.
        .contentMargins(.bottom, Self.floatingBarClearance, for: .scrollContent)
        .overlay {
            if sceneObservation.items.isEmpty {
                if sceneNavigation.query.isEmpty && sceneNavigation.scope == .inbox {
                    ContentUnavailableView("Inbox is empty", systemImage: "tray", description: Text("Notes without a type appear here."))
                        .allowsHitTesting(false)
                } else {
                    ContentUnavailableView(sceneNavigation.query.isEmpty ? "No notes yet" : "No matching notes",
                        systemImage: sceneNavigation.query.isEmpty ? "square.and.pencil" : "magnifyingglass",
                        description: Text(sceneNavigation.query.isEmpty ? "Capture a thought with a new note." : "Try another word, tag, or search operator."))
                        .allowsHitTesting(false)
                }
            }
        }
        .navigationTitle(sceneNavigation.scope.title)
        .searchable(text: $sceneNavigation.query, prompt: "Search notes")
        .searchFocused($searchFocused)
        .onChange(of: selecting) { _, value in if value { editor.webView.endEditing(true) } }
        .onChange(of: sceneNavigation.scope) { _, _ in selectedNotes = []; selecting = false; pendingTrashDeletion = [] }
        .onChange(of: sceneNavigation.workspace) { _, _ in selectedNotes = []; selecting = false; pendingTrashDeletion = [] }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Note", systemImage: "square.and.pencil") {
                    library.perform {
                        if let id = try library.eligibleStartTemplateID() {
                            templateID = id; showingTemplates = true
                        } else { pendingNewNoteFocus = try library.createNote(in: sceneNavigation) }
                    }
                }.keyboardShortcut("n").accessibilityIdentifier("new-note")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Select All") {
                        MobileShortcutRouter.selectAll(responder: keyboardResponder, editorView: editor.webView,
                            editor: { Task { await MobileShortcutRouter.selectEditor(in: editor.webView) { editor.command(.selectAll) } } }, library: { selecting = true; selectedNotes = Set(sceneObservation.items.map(\.id)) })
                    }.keyboardShortcut("a")
                    Menu("Sort Notes") {
                        Picker("Sort Notes", selection: Binding(get: { sceneObservation.snapshot.sort }, set: { value in library.perform { try library.settings.set(.noteSort, to: value) } })) {
                            ForEach(NoteSort.allCases, id: \.self) { Text($0.mobileTitle).tag($0) }
                        }
                    }
                    Menu("Preview") {
                        Picker("Preview", selection: $library.preferences.previewLines) {
                            Text("None").tag(0); Text("Small").tag(1); Text("Medium").tag(2); Text("Large").tag(3)
                        }
                    }
                    Toggle("Show Thumbnails", isOn: $library.preferences.showThumbnails)
                    Menu("Export Listed Notes") {
                        ForEach(MobileExportFormat.allCases, id: \.self) { format in
                            Button(format.title) { exportBatch(ids: sceneObservation.items.map(\.id), format: format) }
                        }
                        MobileExportChoices(library: library, showsNoteLinks: true)
                    }.disabled(sceneObservation.items.isEmpty || exportBusy)
                    if sceneNavigation.scope == .trash {
                        Button(sceneNavigation.workspace == nil ? "Empty Trash…" : "Empty Trash in Workspace…", systemImage: "trash", role: .destructive) {
                            library.perform {
                                pendingTrashDeletion = try library.trashDeletionCandidates(in: sceneNavigation)
                                trashDeletionTitle = sceneNavigation.workspace.map { "Empty Trash in \($0.path)?" } ?? "Empty Trash?"
                            }
                        }.disabled(sceneObservation.snapshot.counts.trash == 0)
                    } else {
                        Button("Move to Trash", role: .destructive) {
                            if let id = sceneNavigation.selectedID { move(id, to: .trash) }
                        }.disabled(sceneNavigation.selectedID == nil)
                    }
                } label: { Label("List Options", systemImage: "line.3.horizontal.decrease") }
                .onChange(of: library.preferences) { _, _ in library.perform { try library.savePreferences() } }
            }
            ToolbarItem(placement: .topBarLeading) {
                if selecting {
                    Button("Done") { selecting = false; selectedNotes = [] }
                } else {
                    Button("Select", systemImage: "checkmark.rectangle.stack") { selecting = true }.accessibilityIdentifier("select-notes")
                }
            }
            ToolbarItem(placement: .bottomBar) {
                if selecting {
                    Menu("\(selectedNotes.count) Selected", systemImage: "ellipsis.circle") {
                        // A symbol on every entry, so the labels line up.
                        Button("Select All", systemImage: "checkmark.square") { selectedNotes = Set(sceneObservation.items.map(\.id)) }
                        Menu("Export Selected", systemImage: "square.and.arrow.up") {
                            ForEach(MobileExportFormat.allCases, id: \.self) { format in
                                Button(format.title) { exportBatch(ids: Array(selectedNotes), format: format) }
                            }
                            MobileExportChoices(library: library)
                        }.disabled(selectedNotes.isEmpty || exportBusy)
                        Button("Copy Links to Notes", systemImage: "link") { UIPasteboard.general.string = selectedNotes.sorted().map { MobileShortcutCapture.noteLink(id: $0).absoluteString }.joined(separator: "\n") }
                        // Only the entries that do something for this selection and scope.
                        let pin = selectionNeedsPin
                        // No Pin in the Trash; Archive's way back reads Unarchive.
                        if sceneNavigation.scope != .trash {
                            Button(pin ? "Pin" : "Unpin", systemImage: pin ? "pin" : "pin.slash") {
                                bulk { try library.store.setPinned($0, pinned: pin, inTag: selectedTag) }
                            }.accessibilityIdentifier(pin ? "selection-pin" : "selection-unpin")
                        }
                        if sceneNavigation.scope == .trash || sceneNavigation.scope == .archive {
                            Button(sceneNavigation.scope == .archive ? "Unarchive" : "Restore", systemImage: "arrow.uturn.backward") { moveSelected(to: .notes) }.accessibilityIdentifier("selection-restore")
                        } else {
                            Button("Archive", systemImage: "archivebox") { moveSelected(to: .archive) }.accessibilityIdentifier("selection-archive")
                        }
                        if sceneNavigation.scope == .trash {
                            Button("Delete…", systemImage: "trash", role: .destructive) {
                                pendingTrashDeletion = selectedNotes.sorted()
                                trashDeletionTitle = "Delete Selected Notes Permanently?"
                            }.disabled(selectedNotes.isEmpty)
                        } else {
                            Button("Move to Trash", systemImage: "trash", role: .destructive) {
                                MobileShortcutRouter.trashSelection(responder: keyboardResponder, editorView: editor.webView) {
                                    moveSelected(to: .trash)
                                }
                            }.keyboardShortcut(.delete).accessibilityIdentifier("selection-trash")
                        }
                        if case .tag(let path) = sceneNavigation.scope {
                            Button("Remove Tag", systemImage: "tag.slash") { bulk { try library.store.removeTag(path, from: $0) } }
                        }
                    }
                }
            }
            ToolbarItem(placement: .bottomBar) {
                Button("Quick Open", systemImage: "doc.text.magnifyingglass") { showingQuickOpen = true }.accessibilityIdentifier("list-quick-open")
            }
            ToolbarItem(placement: .bottomBar) {
                Button("From Template", systemImage: "doc.badge.plus") { showingTemplates = true }.accessibilityIdentifier("list-from-template")
            }
        }
    }

    private var detail: AnyView { AnyView(detailContent) }
    @ViewBuilder private var detailContent: some View {
        if let lockedSelection {
            ContentUnavailableView {
                Label("Locked Note", systemImage: "lock.fill")
            } description: {
                Text((try? library.store.note(id: lockedSelection))?.encryptedPayload == nil
                     ? "This note was locked in Bear. Unlock it in Bear and import it again to bring its contents here."
                     : "Enter your note password to read and edit this note.")
            } actions: {
                if (try? library.store.note(id: lockedSelection))?.encryptedPayload != nil {
                    Button("Unlock Note") { passwordAction = .unlock }.buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("unlock-note")
                    if library.biometryEnabled, let label = MobileBiometricKeychain.label() {
                        Button("Unlock with " + label) {
                            Task {
                                do { try await library.unlockWithBiometrics(); completePasswordAction() }
                                catch { passwordAction = .unlock }
                            }
                        }.disabled(library.authenticatingDevice)
                    }
                }
            }
            .navigationTitle((try? library.store.note(id: lockedSelection))?.title ?? "Locked Note")
        } else if sceneNavigation.selectedID != nil || captureTransitionRunning {
            MobileWebView(editor: editor)
                .id(ObjectIdentifier(editor))
                .modifier(PadKeyboardHandover { Task { await Task.yield(); refreshEditorKeyboardOwnership() } })
                .privacySensitive()
                .overlay { if !editor.ready { ProgressView("Opening note…") } }
                // One background colour behind the status bar, the page and the bar's edges.
                .background { (editor.pageBackground ?? Color(.systemBackground)).ignoresSafeArea() }
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let reason = editor.readOnlyReason {
                        Text(reason).font(.callout).foregroundStyle(.secondary).padding().frame(maxWidth: .infinity).background(.bar)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { formattingBar }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            // Side by side (regular width) the list's bottom bar is their one place; with the list column hidden
                            // it is off screen, and while the editor holds the keyboard on iPad the on-screen keyboard covers it.
                            // At most about ten top-level rows in sections; everything else in More.
                            // Not in a Section: SwiftUI drops the accessibility identifiers of menu items inside one (probe 2026-11-16);
                            // the following Section still draws the divider.
                            if horizontalSizeClass == .compact || visibility == .detailOnly || listBarCovered {
                                Button("Quick Open", systemImage: "doc.text.magnifyingglass") { showingQuickOpen = true }.accessibilityIdentifier("note-quick-open")
                                Button("From Template", systemImage: "doc.badge.plus") { showingTemplates = true }.accessibilityIdentifier("note-from-template")
                            }
                            if MobileNoteSceneActivation.supportsMultipleWindows {
                                Button("Open in New Window", systemImage: "macwindow.badge.plus") {
                                    guard phase == .active, !lifecycleSuspended, !privacyCloseInFlight,
                                          !library.sceneEditorAdmissionBlocked, !library.appLocked,
                                          let id = sceneNavigation.selectedID else { return }
                                    library.perform {
                                        openWindow(value: try MobileNoteSceneActivation.requestedAddress(noteID: id, library: library))
                                    }
                                }
                                .accessibilityIdentifier("open-note-window-menu-action")
                                .disabled(library.sceneEditorAdmissionBlocked || privacyCloseInFlight || library.appLocked)
                            }
                            Section {
                                let current = sceneObservation.items.first(where: { $0.id == sceneNavigation.selectedID })
                                Button(current?.isPinned == true ? "Unpin" : "Pin", systemImage: current?.isPinned == true ? "pin.slash" : "pin") {
                                    if let current { library.perform { try togglePin(current) } }
                                }.keyboardShortcut("p", modifiers: [.command, .shift]).disabled(current == nil)
                                if let id = sceneNavigation.selectedID, let note = try? library.store.note(id: id) {
                                    Button(note.isLocked ? "Remove Note Lock" : "Lock Note", systemImage: note.isLocked ? "lock.open" : "lock") {
                                        if note.isLocked { pendingRemoveLockID = id } else { pendingLockID = id }
                                        if library.privateAccess != nil { completePasswordAction() }
                                        else { passwordAction = library.hasNotePassword ? .unlock : .setup }
                                    }
                                }
                                Button("Note Info", systemImage: "info.circle") { showingInfo = true }.keyboardShortcut("i", modifiers: [.command, .shift])
                            }
                            Section {
                                Button("Copy Link to Note", systemImage: "link") {
                                    if let id = sceneNavigation.selectedID { UIPasteboard.general.string = MobileShortcutCapture.noteLink(id: id).absoluteString }
                                }.keyboardShortcut("l", modifiers: [.command, .shift, .option])
                                if editor.canShare {
                                    // A10: the selected text, else the whole note. Keep Tags is the Settings switch only.
                                    Menu("Copy As", systemImage: "doc.on.clipboard") {
                                        ForEach(MobileCopyAs.allCases, id: \.self) { kind in
                                            Button(kind.title) { copyAs(kind.format) }
                                        }
                                    }.disabled(exportBusy || !editor.canExport)
                                    Menu("Export", systemImage: "square.and.arrow.up") {
                                        ForEach(MobileExportFormat.allCases, id: \.self) { format in
                                            Button(format.title) { export(format: format) }
                                        }
                                        Button("Print") { export(format: .pdf, printDocument: true) }
                                            .keyboardShortcut("p")
                                        MobileExportChoices(library: library)
                                    }.disabled(exportBusy || !editor.canExport)
                                    if exportBusy { ProgressView().accessibilityLabel("Preparing export") }
                                }
                            }
                            Section {
                                Button("Find in Note", systemImage: "magnifyingglass") { editor.command(.find) }
                            }
                            // Copy Identifier and Find and Replace in More, so iPhone 17 shows More without scrolling.
                            Menu("More", systemImage: "ellipsis") {
                                Button("Copy Identifier", systemImage: "number") { UIPasteboard.general.string = sceneNavigation.selectedID }.keyboardShortcut("i", modifiers: [.command, .shift, .option])
                                Button("Find and Replace", systemImage: "text.magnifyingglass") { editor.command(.findAndReplace) }.disabled(!editor.editable)
                                Button("Go Back", systemImage: "arrow.uturn.backward") { library.perform { try navigate(back: true) } }.disabled(!sceneNavigation.history.canGoBack).keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                                Button("Go Forward", systemImage: "arrow.uturn.forward") { library.perform { try navigate(back: false) } }.disabled(!sceneNavigation.history.canGoForward).keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                                // Attachments, the camera and Dismiss Keyboard live on the bar;
                                // Recovered Sketches in Library Options.
                                Button("Paste as Code", systemImage: "curlybraces") {
                                    if let text = UIPasteboard.general.string { editor.pasteAsCode(text) }
                                }.disabled(!editor.editable)
                                Button("Copy to New Note", systemImage: "doc.on.doc") {
                                    library.perform {
                                        guard editor.canShare, let text = editor.selectedText, let id = editor.session?.noteId else { return }
                                        try library.copySelectionToNewNote(text, sourceID: id, in: sceneNavigation)
                                    }
                                }.disabled(!editor.canShare || !editor.hasSelection)
                                if editor.canShare {
                                    Menu("Folding", systemImage: "text.line.first.and.arrowtriangle.forward") {
                                        Button("Toggle Current Section") { editor.command(.toggleFold) }
                                        Button("Fold All Headings") { editor.command(.foldAll) }
                                        Button("Unfold All Headings") { editor.command(.unfoldAll) }
                                    }
                                    Menu("Copy Table", systemImage: "tablecells") {
                                        ForEach(Self.tableCopyFormats, id: \.format) { entry in
                                            Button(entry.label) { editor.command(.copyTable, args: ["format": .string(entry.format)]) }
                                        }
                                    }
                                    .disabled(!editor.canExport)
                                    Button(editor.readOnlyReason == "Read-only note" ? "Allow Editing" : "Make Read-Only", systemImage: "pencil.slash") {
                                        library.perform {
                                            guard let id = sceneNavigation.selectedID, let note = try library.store.note(id: id) else { return }
                                            try library.flush(); try library.store.setReadOnly(id, readOnly: !note.isReadOnly)
                                            try library.refreshSessions(); editor.loadNote()
                                        }
                                    }
                                }
                                if editor.canExport {
                                    Button("Share Markdown", systemImage: "square.and.arrow.up") {
                                        library.perform {
                                            try library.flush()
                                            guard let id = editor.session?.noteId else { return }
                                            let access = try MobileExportAccess(library: library, ids: [id])
                                            try access.publish { sharedMarkdown = MobileMarkdownShare(text: access.notes[0].text) }
                                        }
                                    }
                                }
                                if library.privateAccess != nil {
                                    Button("Close Locked Notes", systemImage: "lock.fill") { closePrivateAccess() }
                                }
                            }
                        } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("Note Actions") }
                    }
                }
                .onAppear { detailVisibilityGeneration += 1 }
                .onDisappear {
                    detailVisibilityGeneration += 1
                    let generation = detailVisibilityGeneration
                    library.perform {
                        try library.flush()
                        if phase == .active, !captureTransitionRunning, !library.appLocked, !library.libraryOperationBusy,
                           let id = sceneNavigation.selectedID, library.isActiveCapture(id) {
                            captureTransitionRunning = true
                            Task {
                                defer {
                                    captureTransitionRunning = false
                                    if sceneNavigation.selectedID != id { requestSelection(sceneNavigation.selectedID) }
                                }
                                do {
                                    try await library.finishCapture(noteId: id, editor: editor) {
                                        detailVisibilityGeneration == generation && phase == .active &&
                                        !library.appLocked && !library.libraryOperationBusy && sceneNavigation.selectedID == id
                                    }
                                } catch {
                                    if detailVisibilityGeneration == generation, phase == .active,
                                       !library.appLocked, sceneNavigation.selectedID == id {
                                        library.errorMessage = "The note is still saving. Please try leaving it again."
                                    }
                                }
                            }
                        }
                    }
                }
        } else {
            ContentUnavailableView("Your thoughts, at home", systemImage: "doc.text", description: Text("Select a note or start a new one."))
        }
    }

    private var formattingBar: some View {
        // Eight cells share the width evenly (no scrolling), so a 375-point phone shows the last one whole.
        HStack(spacing: 0) {
            // (Jan, 2026-11-10): one menu holds every text style; no separate Bold, Italic or Headings buttons.
            // Headings in a submenu, a symbol on every top-level entry, states as menu checkmarks.
            // Six top-level rows, so the whole menu fits above the keyboard of a 375-point phone.
            Menu {
                formatToggle("Bold", "bold", .bold)
                formatToggle("Italic", "italic", .italic)
                Menu {
                    ForEach(1...6, id: \.self) { level in formatToggle("Heading \(level)", nil, .heading, args: ["level": .int(level)]) }
                } label: { Label("Heading", systemImage: "textformat.size") }
                .disabled(!formatCommandEnabled(.heading))
                Menu {
                    formatToggle("Underline", "underline", .underline)
                    formatToggle("Strikethrough", "strikethrough", .strike)
                    formatToggle("Highlight", "highlighter", .highlight)
                    formatToggle("Inline Code", "ellipsis.curlybraces", .inlineCode)
                } label: { Label("More Styles", systemImage: "textformat") }
                Menu {
                    formatToggle("Numbered List", "list.number", .orderedList)
                    formatToggle("Quote", "text.quote", .quote)
                    formatMenuButton("Indent", "increase.indent", .indent)
                    formatMenuButton("Outdent", "decrease.indent", .outdent)
                    formatMenuButton("Sort To-Dos", "checklist.checked", .moveCheckedToBottom)
                } label: { Label("Paragraph", systemImage: "text.alignleft") }
                Menu {
                    formatMenuButton("Date", "calendar", .insertDate, args: ["style": .string("long")])
                    formatMenuButton("Wiki Link", "link.badge.plus", .wikiLink)
                    Menu {
                        formatMenuButton("Insert Table", nil, .createTable)
                        formatMenuButton("Add Row Below", nil, .tableAddRow)
                        formatMenuButton("Add Column After", nil, .tableAddColumn)
                        formatMenuButton("Delete Row", nil, .tableDeleteRow)
                        formatMenuButton("Delete Column", nil, .tableDeleteColumn)
                        formatMenuButton("Move Row Up", nil, .tableMoveRow, args: ["direction": .string("up")])
                        formatMenuButton("Move Row Down", nil, .tableMoveRow, args: ["direction": .string("down")])
                        formatMenuButton("Move Column Left", nil, .tableMoveColumn, args: ["direction": .string("left")])
                        formatMenuButton("Move Column Right", nil, .tableMoveColumn, args: ["direction": .string("right")])
                    } label: { Label("Table", systemImage: "tablecells") }
                    Menu {
                        ForEach(CalloutType.allCases, id: \.rawValue) { type in
                            formatMenuButton("Insert " + type.rawValue.capitalized, nil, .callout, args: ["type": .string(type.rawValue)])
                        }
                        Menu("Change Type") {
                            ForEach(CalloutType.allCases, id: \.rawValue) { type in
                                formatMenuButton(type.rawValue.capitalized, nil, .setCalloutType, args: ["type": .string(type.rawValue)])
                            }
                        }
                    } label: { Label("Callout", systemImage: "text.bubble") }
                    Menu {
                        formatMenuButton("Inline Formula", nil, .insertMath, args: ["display": .bool(false)])
                        formatMenuButton("Display Formula", nil, .insertMath, args: ["display": .bool(true)])
                    } label: { Label("Math", systemImage: "function") }
                    formatMenuButton("Footnote", "textformat.superscript", .footnote)
                    formatMenuButton("Horizontal Rule", "minus", .horizontalRule)
                } label: { Label("Insert", systemImage: "plus.square") }
            } label: { barIcon("textformat").accessibilityLabel("Formatting") }
                // One reading order whichever way the menu opens (Bold and Heading 1 first).
                .menuOrder(.fixed)
                .accessibilityIdentifier("toolbar-format").disabled(!editor.editable)
            // IOS-TOOLBAR (2026-11-08): attachments and the camera live on the bar only.
            Menu {
                Button("Photo Library", systemImage: "photo.on.rectangle") { beginAttachment(.photos) }
                    .accessibilityIdentifier("toolbar-attach-photos").disabled(attachmentDisabled(.photos))
                Button("Insert File", systemImage: "paperclip") { beginFileAttachment() }
                    .accessibilityIdentifier("toolbar-attach-file").disabled(attachmentDisabled(.file))
                Button("Scan Document", systemImage: "doc.viewfinder") { beginAttachment(.scan) }
                    .accessibilityIdentifier("toolbar-attach-scan").disabled(attachmentDisabled(.scan))
                Button("New Sketch", systemImage: "pencil.tip.crop.circle") { beginAttachment(.sketch) }
                    .accessibilityIdentifier("toolbar-attach-sketch").disabled(attachmentDisabled(.sketch))
            } label: { barIcon("plus.circle").accessibilityLabel("Attach") }
                .accessibilityIdentifier("toolbar-attach")
            Button { beginAttachment(.camera) } label: { barIcon("camera") }
                .accessibilityLabel("Take Photo").accessibilityIdentifier("toolbar-camera").disabled(attachmentDisabled(.camera))
            formatButton("To Do", "checklist", .todo)
            formatButton("Bullet List", "list.bullet", .bulletList)
            formatButton("Link", "link", .link)
            formatButton("Code Block", "chevron.left.forwardslash.chevron.right", .codeBlock)
            Button { editor.webView.endEditing(true) } label: { barIcon("keyboard.chevron.compact.down") }
                .accessibilityLabel("Dismiss Keyboard").accessibilityIdentifier("toolbar-dismiss-keyboard")
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    /// One bar cell: a 44-point symbol centred in an equal share of the bar's width.
    private func barIcon(_ name: String, active: Bool = false) -> some View {
        Image(systemName: name).font(.system(size: 20)).frame(width: 44, height: 44)
            .background(active ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
    }

    private func tableCommand(_ name: EditorCommandName, request: TableMenuRequest, direction: String? = nil) {
        var args: [String: CommandArgument] = ["menuId": .string(request.menuId)]
        if let direction { args["direction"] = .string(direction) }
        editor.command(name, args: args); editor.tableMenu = nil
    }

    /// One rule for the note menu and the formatting bar.
    private func attachmentDisabled(_ source: AttachmentSource) -> Bool {
        switch source {
        case .photos, .sketch: !editor.editable || attachmentBusy
        case .camera: !editor.editable || attachmentBusy || !MobileMediaCapture.cameraAvailable
        case .scan: !editor.editable || attachmentBusy || !MobileMediaCapture.scannerAvailable
        case .file: !formatCommandEnabled(.insertFile) || attachmentBusy
        }
    }

    private func formatCommandEnabled(_ command: EditorCommandName) -> Bool {
        guard editor.editable else { return false }
        let state = editor.formatState ?? .plain
        switch command {
        case .bold, .italic, .underline, .strike, .highlight, .link, .wikiLink, .footnote, .horizontalRule, .insertFile,
             .createTable, .tableAddRow, .tableAddColumn, .tableDeleteRow, .tableDeleteColumn, .tableMoveRow, .tableMoveColumn:
            return !state.inCode
        case .inlineCode: return !state.inCode || state.active.contains(.inlineCode)
        case .heading, .bulletList, .orderedList, .todo, .toggleTodo, .quote:
            return !state.active.contains(.codeBlock)
        default: return true
        }
    }

    private func formatCommandActive(_ command: EditorCommandName, args: [String: CommandArgument]?) -> Bool {
        guard let state = editor.formatState else { return false }
        if command == .heading, case .int(let level) = args?["level"] { return state.headingLevel == level }
        return state.active.contains(command)
    }

    private func formatMenuButton(_ title: String, _ icon: String?, _ command: EditorCommandName,
                                  args: [String: CommandArgument]? = nil) -> some View {
        Button { editor.command(command, args: args) } label: {
            if let icon { Label(title, systemImage: icon) } else { Text(title) }
        }
        .disabled(!formatCommandEnabled(command))
    }

    /// A style that can be on: the menu draws its checkmark in its own column, so the label never moves.
    private func formatToggle(_ title: String, _ icon: String?, _ command: EditorCommandName,
                              args: [String: CommandArgument]? = nil) -> some View {
        let active = formatCommandActive(command, args: args)
        return Toggle(isOn: Binding(get: { active }, set: { _ in editor.command(command, args: args) })) {
            if let icon { Label(title, systemImage: icon) } else { Text(title) }
        }
        .disabled(!formatCommandEnabled(command))
    }

    private func formatButton(_ title: String, _ icon: String, _ command: EditorCommandName,
                              args: [String: CommandArgument]? = nil) -> some View {
        let active = formatCommandActive(command, args: args)
        return Button { editor.command(command, args: args) } label: { barIcon(icon, active: active) }
        .accessibilityLabel(title).accessibilityIdentifier("toolbar-" + title)
        .accessibilityValue(active ? "On" : "Off")
        .accessibilityAddTraits(active ? .isSelected : [])
        .disabled(!formatCommandEnabled(command))
    }

    private func bulk(_ action: ([String]) throws -> Void) {
        library.perform {
            guard !selectedNotes.isEmpty else { return }
            try library.flush()
            try action(Array(selectedNotes))
            try library.refreshSessions()
            if let id = sceneNavigation.selectedID, selectedNotes.contains(id) { sceneNavigation.selectedID = nil }
            selectedNotes = []; selecting = false
        }
    }

    private func openSelection(_ id: String) throws {
        guard let note = try library.store.note(id: id) else { return }
        if !library.canRead(note) {
            try editor.closeForPrivacy()
            try replaceClosedEditor()
            lockedSelection = id
        } else {
            lockedSelection = nil
            if editor.isClosedForPrivacy { try replaceClosedEditor() }
            try editor.open(id)
        }
        editor.onOpenNote = { id in library.perform { try reveal(id) } }
    }

    private func completePasswordAction() {
        let lockID = pendingLockID, removeID = pendingRemoveLockID
        pendingLockID = nil; pendingRemoveLockID = nil
        guard lockID != nil || removeID != nil else {
            library.perform { if let id = sceneNavigation.selectedID { try openSelection(id) } }
            return
        }
        Task {
            do {
                try await library.withDrainedEditor {
                    try editor.closeForPrivacy()
                    if let id = lockID {
                        try library.lockNote(id)
                        try library.lockVault()
                        lockedSelection = id
                    } else if let id = removeID {
                        try library.removeNoteLock(id)
                    }
                }
                try replaceClosedEditor()
                if let id = removeID { try openSelection(id) }
            } catch { library.errorMessage = error.localizedDescription }
        }
    }

    /// UIKit and SwiftUI both report the same background transition. Fence once,
    /// synchronously, before any editor drain or privacy work can suspend.
    private func enterBackground() {
        MobilePrivacyShield.cover(in: sceneWindow.window)
        guard !lifecycleSuspended else { return }
        _ = library.updateSceneActivity(id: sceneNavigation.id, activity: .background)
        lifecycleSuspended = true
        sceneReadGate.allowed = false
        sceneObservation.stop()
        captureSketchCheckpointHosts()
        cancelNewSketch(); cancelAttachmentEdit(); suspendSketchRecoveryPrompt(); recoveryDeferred = false
        suspendVoicePresentation()
        captureTransitionGeneration += 1
        if library.hasActiveSceneWindows {
            // Only this scene leaves the foreground; another window keeps its key/session.
            if library.privateAccess != nil { closePrivateAccess(revokeSharedAccess: false) }
            else { suspendedSketchHosts.removeAll(); drainBackgroundEdits() }
        } else {
            library.cancelPendingUnlock()
            library.lockApplication()
            if library.privateAccess != nil || library.appLockEnabled { closePrivateAccess() }
            else { suspendedSketchHosts.removeAll(); drainBackgroundEdits() }
        }
    }

    private func captureSketchCheckpointHosts() {
        for host in [newSketchRequest?.draftHost, attachmentEditRequest?.draftHost].compactMap({ $0 }) {
            if !suspendedSketchHosts.contains(where: { $0.id == host.id }) { suspendedSketchHosts.append(host) }
        }
    }

    private func closePrivateAccess(revokeSharedAccess: Bool = true) {
        if revokeSharedAccess { MobilePrivacyShield.cover() }
        MobilePrivacyShield.cover(in: sceneWindow.window) // Cover before any snapshot/key work.
        captureSketchCheckpointHosts()
        resetMediaPresentations()
        if privacyCloseInFlight {
            if revokeSharedAccess, !privacyCloseRevokesSharedAccess,
               let token = library.beginScenePrivacyClose() {
                scenePrivacyCloseToken = token
                privacyCloseRevokesSharedAccess = true
            }
            return
        }
        if revokeSharedAccess {
            // Another shared transition owns closure if it refuses admission. Never revoke
            // its key or release its token; its final closed-page event resumes this scene.
            guard let token = library.beginScenePrivacyClose() else { return }
            scenePrivacyCloseToken = token
        }
        privacyCloseRevokesSharedAccess = revokeSharedAccess
        privacyCloseInFlight = true
        privacyClosePending = true
        privacyCloseGeneration += 1
        let generation = privacyCloseGeneration
        MobilePrivacyShield.cover(in: sceneWindow.window)
        showingSettings = false; editingTag = nil; passwordAction = nil
        pendingLockID = nil; pendingRemoveLockID = nil; importingFile = false
        showingInfo = false; showingQuickOpen = false; showingTemplates = false; templateID = nil; pendingQuickOpenTemplateGeneration = nil
        exportGeneration += 1; exportTask?.cancel(); exportTask = nil; exportBusy = false
        if privacyCloseRevokesSharedAccess {
            UIPrintInteractionController.shared.dismiss(animated: false)
            UIPrintInteractionController.shared.printingItem = nil
        }
        exportDocument = nil; exporting = false; sharedMarkdown = nil
        let closingEditor = editor
        let checkpointHosts = suspendedSketchHosts
        suspendedSketchHosts.removeAll()
        var taskID = UIBackgroundTaskIdentifier.invalid
        taskID = UIApplication.shared.beginBackgroundTask(withName: "Lock private notes") {
            if privacyClosePending, privacyCloseGeneration == generation {
                if privacyCloseRevokesSharedAccess { library.revokePrivateAccessForExpiredPrivacyClose() }
                finishPrivacyClose(closingEditor, generation: generation)
            }
            if taskID != .invalid {
                UIApplication.shared.endBackgroundTask(taskID)
                taskID = .invalid
            }
        }
        Task {
            defer {
                if taskID != .invalid { UIApplication.shared.endBackgroundTask(taskID); taskID = .invalid }
            }
            let deadline = Date().addingTimeInterval(2)
            var pagesDrained = false
            let completed = await MobileSketchPrivacyCloseBudget.wait {
                await MobileSketchPrivacyCloseBudget.checkpointBeforePages(deadline: deadline, checkpoints: {
                    if privacyCloseRevokesSharedAccess {
                        do { try await library.completeScenePrivacyCheckpoints() }
                        catch {
                            if privacyClosePending, privacyCloseGeneration == generation {
                                library.errorMessage = "The latest recovery checkpoint could not finish before locking. The last saved draft is kept."
                            }
                        }
                    }
                    // Host tasks may still be queued before entering the Store actor;
                    // store.waitForWrites alone cannot observe those final snapshots.
                    for host in checkpointHosts {
                        do {
                            try await host.completeSuspendedCheckpoint()
                        } catch {
                            if privacyClosePending, privacyCloseGeneration == generation {
                                library.errorMessage = "The latest recovery checkpoint could not finish before locking. The last saved draft is kept."
                            }
                        }
                    }
                }, pages: { deadline in
                    do {
                        let drainDeadline = deadline.addingTimeInterval(-0.5)
                        if privacyCloseRevokesSharedAccess {
                            try await library.prepareScenePrivacyClose(deadline: drainDeadline)
                        } else if let id = closingEditor.session?.noteId {
                            let frozen = try await closingEditor.prepareCaptureClose(id, waitForBusyUntil: drainDeadline)
                            defer { closingEditor.endCaptureClose(frozen) }
                            guard editor === closingEditor, closingEditor.session?.noteId == id else {
                                throw MobileEditorDrainError.unavailable
                            }
                        }
                        pagesDrained = true
                    } catch {
                        if !Task.isCancelled, Date() < deadline {
                            pagesDrained = privacyCloseRevokesSharedAccess
                                ? await library.preserveSceneBrowserTextBeforePrivacyClose(deadline: deadline)
                                : await closingEditor.preserveBrowserTextBeforePrivacyClose(deadline: deadline)
                        }
                        if !pagesDrained, privacyClosePending, privacyCloseGeneration == generation {
                            library.errorMessage = "Some recent edits may not have saved before the app locked."
                        }
                    }
                })
            }
            if !(completed && pagesDrained), privacyClosePending, privacyCloseGeneration == generation {
                // A checkpoint can consume the deadline without the timer winning its
                // scheduling race. Skipped/failed pages must never count as a successful drain.
                // Revoke BEFORE closeForPrivacy/lockVault can perform synchronous I/O.
                if privacyCloseRevokesSharedAccess { library.revokePrivateAccessForExpiredPrivacyClose() }
                library.errorMessage = "The app locked before every note finished saving. The last saved draft and recovery journals are kept."
            }
            finishPrivacyClose(closingEditor, generation: generation)
        }
    }

    private func finishPrivacyClose(_ closingEditor: MobileEditor, generation: Int) {
        guard privacyClosePending, privacyCloseGeneration == generation else { return }
        privacyClosePending = false
        privacyCloseInFlight = false
        let admission = scenePrivacyCloseToken
        defer {
            if let admission { library.finishScenePrivacyClose(admission) }
            if scenePrivacyCloseToken == admission { scenePrivacyCloseToken = nil }
        }
        MobileSketchPrivacyCloseBudget.revokeBeforeSynchronousClose(library: library, shared: privacyCloseRevokesSharedAccess)
        do { try closingEditor.closeForPrivacy() }
        catch { library.errorMessage = "Some recent edits may not have saved before the app locked." }
        if editor !== closingEditor {
            do { try editor.closeForPrivacy() }
            catch { library.errorMessage = "Some recent edits may not have saved before the app locked." }
        }
        if privacyCloseRevokesSharedAccess {
            do { try library.lockVault() }
            catch { library.errorMessage = "Some recent edits may not have saved before the app locked." }
        }
        // Reopen/adopt only AFTER the actual key revoke, never while the shared fence is held.
        if let admission { library.finishScenePrivacyClose(admission) }
        if scenePrivacyCloseToken == admission { scenePrivacyCloseToken = nil }
        library.perform { try replaceClosedEditor() }
        if !library.appLocked, !lifecycleSuspended, applicationState() == .active, let id = sceneNavigation.selectedID { library.perform { try openSelection(id) } }
        uncoverActiveSceneIfSafe()
        resumeDeferredSelection(requireApplicationActive: true)
    }

    private func drainBackgroundEdits() {
        guard !backgroundDrainInFlight, let id = editor.session?.noteId else { return }
        backgroundDrainInFlight = true
        let drainingEditor = editor
        var taskID = UIBackgroundTaskIdentifier.invalid
        taskID = UIApplication.shared.beginBackgroundTask(withName: "Save pending note edits") {
            if taskID != .invalid {
                UIApplication.shared.endBackgroundTask(taskID)
                taskID = .invalid
            }
        }
        Task {
            defer {
                backgroundDrainInFlight = false
                if taskID != .invalid { UIApplication.shared.endBackgroundTask(taskID) }
                resumeDeferredSelection(requireApplicationActive: true)
            }
            do {
                let frozen = try await drainingEditor.prepareCaptureClose(id)
                drainingEditor.endCaptureClose(frozen)
            } catch {
                library.errorMessage = "The note is still saving. Please keep the app open."
            }
        }
    }

    private func applyCallbackNavigation() {
        guard let request = sceneNavigation.pendingCallbackNavigation, editor.ready, editor.canShare,
              let session = editor.session, session.noteId == request.noteID else { return }
        sceneNavigation.pendingCallbackNavigation = nil
        if let header = request.header,
           let index = NoteParser.metadata(for: session.text).headings.firstIndex(where: { TitleKey.make($0.text) == TitleKey.make(header) }) {
            editor.scrollToHeading(index)
        }
        if let query = request.find {
            editor.command(.findAndReplace, args: ["query": .string(query)])
        } else if request.edit { editor.focusForCallback() }
    }

    /// The docked on-screen keyboard covers the list's bottom bar. A hardware keyboard's frame lies below the
    /// window's edge or is only the shortcut bar's height; the floating and split keyboards do not reach the bar. Measured
    /// against the window, not the list column: keyboard avoidance shrinks the column to end at the keyboard's top.
    private var listBarCovered: Bool {
        guard let keyboard = keyboardInWindow, !noteListFrame.isNull, keyboard.frame.height >= 120 else { return false }
        let bar = CGRect(x: noteListFrame.minX, y: keyboard.windowHeight - 80, width: noteListFrame.width, height: 80)
        return keyboard.frame.intersects(bar)
    }

    private var keyboardResponder: UIResponder? {
        MobileShortcutRouter.firstResponder(editorView: editor.webView)
    }

    private func focusNewNoteIfReady() {
        guard let id = pendingNewNoteFocus, editor.ready, editor.session?.noteId == id else { return }
        pendingNewNoteFocus = nil
        restoreEditorFocus(editor, noteID: id)
    }

    private func rememberSketchEditorFocus(_ target: MobileEditor) {
        guard let noteID = target.session?.noteId,
              MobileShortcutRouter.destination(responder: MobileShortcutRouter.firstResponder(editorView: target.webView), editorView: target.webView) == .editor else {
            sketchFocusReturn = nil; return
        }
        sketchFocusReturn = (target, noteID)
    }

    private func restoreSketchEditorFocus() {
        guard let target = sketchFocusReturn else { return }
        sketchFocusReturn = nil
        restoreEditorFocus(target.editor, noteID: target.noteID)
    }

    private func restoreEditorFocus(_ target: MobileEditor, noteID: String) {
        Task {
            await Task.yield()
            guard editor === target, sceneNavigation.selectedID == noteID, target.session?.noteId == noteID,
                  phase == .active, applicationState() == .active, !lifecycleSuspended, !privacyCloseInFlight,
                  !library.appLocked, !library.sceneEditorAdmissionBlocked, !attachmentBusy,
                  !showingSettings, !showingQuickOpen, !showingTemplates, passwordAction == nil,
                  !showingInfo, editingTag == nil, sortInbox == nil, !showingVoice,
                  target.previewURL == nil, target.attachmentTarget == nil, target.linkRequest == nil,
                  !externalCaptureSheets.isPresented else { return }
            if let responder = MobileShortcutRouter.firstResponder(editorView: target.webView),
               responder is any UITextInput,
               MobileShortcutRouter.destination(responder: responder, editorView: target.webView) != .editor { return }
            target.focusForHardwareEditing()
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, editor === target, target.session?.noteId == noteID else { return }
            refreshEditorKeyboardOwnership()
        }
    }

    private func refreshEditorKeyboardOwnership() {
        let ownsKeyboard = UIDevice.current.userInterfaceIdiom == .pad && phase == .active && !library.appLocked && editor.editable &&
            MobileShortcutRouter.destination(responder: keyboardResponder, editorView: editor.webView) == .editor
        if editorOwnsKeyboard != ownsKeyboard { editorOwnsKeyboard = ownsKeyboard }
    }

    private func releaseEditorKeyboard() {
        editorOwnsKeyboard = false
        editor.webView.endEditing(true)
    }
    /// Pin while any selected note is unpinned; Unpin once all of them are pinned.
    private var selectionNeedsPin: Bool {
        let chosen = sceneObservation.items.filter { selectedNotes.contains($0.id) }
        return chosen.isEmpty || chosen.contains { !$0.isPinned }
    }
    private var selectedTag: String? {
        if case .tag(let path) = sceneNavigation.scope { return path }
        return nil
    }
    private var searchTerms: [String] {
        sceneNavigation.query.isEmpty ? [] : SearchCompiler.highlightTerms(SearchParser.parse(sceneNavigation.query))
    }
    private func highlightSearch() {
        editor.applySearchHighlights(terms: searchTerms, query: sceneNavigation.query)
    }

    /// Copy As (A10): the selected text, else the whole note.
    private func copyAs(_ format: MobileExportFormat) {
        export(format: format, copyDocument: true, selection: editor.hasSelection ? editor.selectedText : nil)
    }

    private func importNotes(_ urls: [URL], options: FileImportOptions) {
        importBusy = true
        Task {
            defer { importBusy = false }
            let granted = urls.filter { $0.startAccessingSecurityScopedResource() }
            defer { granted.forEach { $0.stopAccessingSecurityScopedResource() } }
            do {
                let report = try await library.importNotes(urls, options: options)
                library.recoveryMessage = "Imported \(report.created) notes. \(report.skipped) skipped."
                if !report.errors.isEmpty || !report.warnings.isEmpty { library.errorMessage = (report.errors + report.warnings).joined(separator: "\n") }
            } catch { library.errorMessage = error.localizedDescription }
        }
    }

    private func exportTag(_ path: String, format: MobileExportFormat) {
        library.perform {
            let ids = try library.database.pool.read {
                try LibraryQueries.notes(in: .tag(path), sort: sceneObservation.snapshot.sort, workspace: sceneNavigation.workspace,
                    now: .now, calendar: .current, db: $0).map(\.id)
            }
            exportBatch(ids: ids, format: format, tagRoot: path)
        }
    }

    private func exportBatch(ids: [String], format: MobileExportFormat, tagRoot: String? = nil) {
        guard !exportBusy, !ids.isEmpty else { return }
        exportBusy = true; exportGeneration += 1
        let generation = exportGeneration
        exportTask = Task { @MainActor in
            defer { if generation == exportGeneration { exportBusy = false; exportTask = nil } }
            let stage = FileManager.default.temporaryDirectory.appendingPathComponent("BaerchenExport-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: stage) }
            do {
                try library.flush()
                let access = try MobileExportAccess(library: library, ids: ids)
                let notes = access.notes
                guard !notes.isEmpty else { return }
                var paths: [String: String] = [:]
                // The attachment choices (A9) shape Markdown and TextBundle only; a rendered format reads this Markdown as its source.
                let choices = format == .markdown || format == .textBundle
                    ? ExportOptions(includeAttachments: library.preferences.exportIncludeAttachments, embedImages: library.preferences.exportEmbedImages)
                    : ExportOptions()
                let wrapper = try NoteExport.batch(notes: notes, format: format == .textBundle ? .textBundle : .markdown, tagRoot: tagRoot, fileExtension: format == .textBundle ? nil : format.fileExtension, options: choices, paths: &paths) { id, name in
                    try library.attachmentURL(name, noteID: id)
                }
                if format != .markdown && format != .textBundle {
                    try await renderBatch(notes: notes, wrapper: wrapper, paths: paths, format: format, generation: generation)
                }
                try access.validate()
                // One note with nothing beside its text (no attachments, or all embedded) is a plain Markdown file, not a ZIP.
                if ids.count == 1, tagRoot == nil, format == .markdown, wrapper.fileWrappers?.count == 1,
                   let (name, file) = wrapper.fileWrappers?.first, file.isRegularFile {
                    guard generation == exportGeneration, !library.appLocked, !Task.isCancelled else { return }
                    exportDocument = try MobileExportDocument(wrapper: file)
                    exportName = name; exportType = .plainText; exporting = true
                    return
                }
                try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.complete])
                let directory = stage.appendingPathComponent("Notes")
                try wrapper.write(to: directory, options: .atomic, originalContentsURL: nil)
                let archive = stage.appendingPathComponent("Notes.zip")
                let work = Task.detached { try PortableZIP.create(from: directory, at: archive) }
                try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                try Task.checkCancellation()
                guard generation == exportGeneration, !library.appLocked,
                      !Task.isCancelled else { return }
                try access.validate()
                exportDocument = try MobileExportDocument(wrapper: FileWrapper(regularFileWithContents: Data(contentsOf: archive)))
                exportName = NoteExport.filename(title: tagRoot ?? "Notes") + ".zip"
                exportType = .zip; exporting = true
            } catch is CancellationError {} catch { library.errorMessage = error.localizedDescription }
        }
    }

    private func renderBatch(notes: [Note], wrapper: FileWrapper, paths: [String: String], format: MobileExportFormat, generation: Int) async throws {
        let appearance = MobileRenderedExport.appearance(format: format, preferences: library.preferences, dark: colorScheme == .dark)
        let renderer = MobileBatchRenderer()
        defer { renderer.cancel() }
        for note in notes {
            try Task.checkCancellation()
            guard generation == exportGeneration, !library.appLocked, try library.store.note(id: note.id)?.isLocked == false,
                  let path = paths[note.id] else { throw CancellationError() }
            let components = path.split(separator: "/").map(String.init)
            var directory = wrapper
            for component in components.dropLast() {
                guard let next = directory.fileWrappers?[component] else { throw CocoaError(.fileReadCorruptFile) }
                directory = next
            }
            guard let filename = components.last, let sourceFile = directory.fileWrappers?[filename],
                  let bytes = sourceFile.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
            let source = String(decoding: bytes, as: UTF8.self)
            let assetPrefix = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent + ".assets/"
            let images = format == .plainText ? [:] : try exportImages(note)
            let mappedImages = Dictionary(uniqueKeysWithValues: images.map { (assetPrefix + $0.key, $0.value) })
            var wikiLinks: [String: String] = [:]
            if format == .html, library.preferences.relativeWikiLinksOnExport {
                for link in NoteParser.metadata(for: note.text).wikiLinks {
                    if let target = try await library.database.pool.read({ try WikiLinkResolver.resolve(link, from: note.id, in: $0) }),
                       let destination = paths[target.noteId] {
                        let from = Array(components.dropLast()), to = destination.split(separator: "/").map(String.init)
                        var common = 0
                        while common < min(from.count, to.count), from[common] == to[common] { common += 1 }
                        let relative = Array(repeating: "..", count: from.count - common) + Array(to.dropFirst(common).dropLast()) + [to.last!]
                        var href = relative.map { $0.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? $0 }.joined(separator: "/")
                        var key = link.target
                        if let heading = link.heading {
                            guard let ordinal = target.headingOrdinal, let targetNote = notes.first(where: { $0.id == target.noteId }) else { continue }
                            let headings = NoteParser.metadata(for: targetNote.text).headings
                            guard headings.indices.contains(ordinal) else { continue }
                            href += "#h-line-" + String(headings[ordinal].line)
                            key += "/" + heading
                        }
                        wikiLinks[key] = href
                    }
                }
            }
            let rendered = try await renderer.render(source: source, attachments: mappedImages,
                keepTags: library.preferences.keepTagsOnExport, wikiLinks: wikiLinks, foreground: appearance.foreground)
            try Task.checkCancellation()
            guard generation == exportGeneration, !library.appLocked,
                  try notes.allSatisfy({ try library.store.note(id: $0.id)?.isLocked == false }) else { throw CancellationError() }
            let html = MobileRenderedExport.document(body: rendered.html, title: note.title, preferences: library.preferences, dark: appearance.dark)
            let data: Data
            switch format {
            case .html: data = Data(html.utf8)
            case .plainText: data = Data(rendered.text.utf8)
            case .rtf: data = try await MobileRenderedExport.rtf(html)
            case .pdf:
                let document = MobileRenderedExport(); try await document.load(html)
                data = try document.pdf(title: note.title)
            default: throw CocoaError(.fileWriteUnsupportedScheme)
            }
            directory.removeFileWrapper(sourceFile)
            let result = FileWrapper(regularFileWithContents: data)
            result.preferredFilename = filename
            directory.addFileWrapper(result)
        }
    }

    private func export(format: MobileExportFormat, printDocument: Bool = false, copyDocument: Bool = false, selection: String? = nil) {
        do { try library.flush() } catch { library.errorMessage = error.localizedDescription; return }
        guard !exportBusy, let id = sceneNavigation.selectedID else { return }
        if format == .markdown, !copyDocument, let note = try? library.store.note(id: id), !note.isLocked,
           !NoteParser.metadata(for: note.text).attachments.isEmpty {
            exportBatch(ids: [id], format: .markdown); return
        }
        exportBusy = true; exportGeneration += 1
        let generation = exportGeneration
        exportTask = Task { @MainActor in
            defer { if generation == exportGeneration { exportBusy = false; exportTask = nil } }
            do {
                let access = try MobileExportAccess(library: library, ids: [id])
                guard let note = access.notes.first else { return }
                let wrapper = try await access.document(format: format, preferences: library.preferences, dark: colorScheme == .dark,
                                                        selection: selection, copy: copyDocument)
                guard generation == exportGeneration else { return }
                try access.publish {
                    if printDocument, let bytes = wrapper.regularFileContents {
                        try MobileRenderedExport.printPDF(bytes, title: note.title, from: editor.webView) { error in
                            if let error { library.errorMessage = error.localizedDescription }
                        }
                    } else if copyDocument, let bytes = wrapper.regularFileContents {
                        MobileCopyAs.write(format, bytes: bytes, plainText: access.plainText)
                    } else {
                        exportDocument = try MobileExportDocument(wrapper: wrapper)
                        exportType = format.contentType
                        exportName = NoteExport.filename(title: note.title) + "." + format.fileExtension
                        exporting = true
                    }
                }
            } catch is CancellationError {} catch { library.errorMessage = error.localizedDescription }
        }
    }

    private func exportImages(_ note: Note) throws -> [String: String] {
        let access = try MobileExportAccess(library: library, ids: [note.id])
        try access.validate()
        return try access.exportImages(note)
    }

    private func move(_ id: String, to location: NoteLocation) {
        moveNotes([id], to: location)
    }
    private func moveSelected(to location: NoteLocation) {
        moveNotes(Array(selectedNotes), to: location)
    }
    private func moveNotes(_ ids: [String], to location: NoteLocation) {
        guard !ids.isEmpty else { return }
        let current = library, navigation = sceneNavigation, generation = library.libraryGeneration
        Task {
            do {
                try await current.moveNotesAfterDraining(ids, to: location, in: navigation)
                if current === library, current.libraryGeneration == generation {
                    selectedNotes.subtract(ids); selecting = !selectedNotes.isEmpty
                }
            } catch {
                if current === library, !current.isClosed { current.errorMessage = error.localizedDescription }
            }
        }
    }
}

private extension TagNode {
    var optionalChildren: [TagNode]? { children.isEmpty ? nil : children }
}

private extension SidebarScope {
    var title: String {
        switch self {
        case .notes: "Notes"
        case .inbox: "Inbox"
        case .type(let type): switch type { case .idea: "Ideas"; case .log: "Logs"; case .reference: "References" }
        case .pinned: "Pinned"
        case .today: "Today"
        case .todo: "To Do"
        case .untagged: "Untagged"
        case .locked: "Locked"
        case .archive: "Archive"
        case .trash: "Trash"
        case .tag(let path): "#" + path
        }
    }
}

/// Outside the disabled navigation so the first-sync safety gate always has an escape.
private struct MobileInitialSyncProgress: View {
    @Bindable var library: MobileLibrary
    @Bindable var sync: MobileSyncController

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(sync.status).font(.headline).multilineTextAlignment(.center)
            Text("Your first library merge temporarily keeps editing read-only so existing notes and incoming changes stay safe.")
                .multilineTextAlignment(.center)
            Text("Notes currently on this device: \(library.snapshot.counts.notes + library.snapshot.counts.archive + library.snapshot.counts.trash)")
                .font(.footnote).foregroundStyle(.secondary)
            Button("Pause and Use App") { Task { await sync.pauseCurrentSync() } }
                .buttonStyle(.borderedProminent).disabled(sync.paused)
            if sync.paused {
                Text("Finishing the current safe step before editing resumes.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(24).frame(maxWidth: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding()
    }
}

private struct MobileMarkdownShare: Identifiable {
    let id = UUID()
    let text: String
}
private struct MobileMarkdownShareView: UIViewControllerRepresentable {
    let text: String
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// The list/editor hardware-keyboard handover is iPad behaviour; iPhone keeps the plain views.
// A SwiftUI TapGesture on a List competes with its row selection and, on iPad, swallowed every row tap
// (store 1.0.0: sidebar and note list did not react). The lists are therefore watched by a UIKit
// recognizer that observes taps without taking part in touch delivery (`PadTapObserver`).
private struct PadKeyboardHandover: ViewModifier {
    var focusable: Bool?
    let onTap: () -> Void
    init(focusable: Bool? = nil, onTap: @escaping () -> Void) { self.focusable = focusable; self.onTap = onTap }
    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom != .pad {
            content
        } else if let focusable {
            content.focusable(focusable).background(PadTapObserver(onTap: onTap))
        } else {
            content.simultaneousGesture(TapGesture().onEnded { onTap() })
        }
    }
}

/// The Link sheet's fields. The focus state lives inside the sheet's own view: one held by the
/// presenting view does not reach a sheet, so the first version opened with no field focused (round 2 screenshot).
private struct MobileLinkFields: View {
    @Binding var title: String
    @Binding var url: String
    let initialTitle: String
    let initialURL: String
    private enum Field { case text, url }
    @FocusState private var field: Field?
    var body: some View {
        Form {
            TextField("Text", text: $title).focused($field, equals: .text)
            TextField("URL", text: $url).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                .focused($field, equals: .url)
        }
        .onAppear { title = initialTitle; url = initialURL }
        .task {
            // Focus once the sheet is on screen; set during its presentation the request is dropped.
            try? await Task.sleep(for: .milliseconds(350))
            field = initialTitle.isEmpty ? .text : .url
        }
    }
}

/// Calls `onTap` for every tap that lands inside the view it is the background of, without cancelling,
/// delaying or consuming any touch: the recognizer sits on the window and recognizes alongside all others.
private struct PadTapObserver: UIViewRepresentable {
    let onTap: () -> Void
    func makeUIView(context: Context) -> ObserverView { ObserverView() }
    func updateUIView(_ view: ObserverView, context: Context) { view.onTap = onTap }

    final class ObserverView: UIView, UIGestureRecognizerDelegate {
        var onTap: () -> Void = {}
        private let recognizer = UITapGestureRecognizer()
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            recognizer.addTarget(self, action: #selector(tapped(_:)))
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
        }
        required init?(coder: NSCoder) { fatalError("not used") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            recognizer.view?.removeGestureRecognizer(recognizer)
            window?.addGestureRecognizer(recognizer)
        }
        @objc private func tapped(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, bounds.contains(gesture.location(in: self)) else { return }
            onTap()
        }
        /// A menu or popover drawn over the column is not the column: a tap there (List Options ▸ Export Listed
        /// Notes) must not hand over the keyboard, which closed the submenu it was opening (T3, 2026-11-16).
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var responder: UIResponder? = self
            while let next = responder?.next, !(next is UIViewController) { responder = next }
            guard let column = (responder?.next as? UIViewController)?.view, let touched = touch.view else { return false }
            return touched.isDescendant(of: column)
        }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
