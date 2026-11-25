// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import PencilKit
import SwiftUI
import UIKit

/// Bounded value snapshot; the host owns encryption, durability, retention and recovery UI.
struct MobileSketchCheckpoint: Sendable {
    let drawingData: Data
    let canvasSize: CGSize
}

/// Persistence-only lifetime boundary. App Lock hides/dismisses UI immediately, but
/// must not invalidate the final already-captured background snapshot. Insertion and
/// presentation keep their own strict App-Lock gates; protected snapshots still need
/// a currently valid vault access and never fall back to plaintext.
@MainActor enum MobileSketchDraftPersistenceBoundary {
    static func isCurrent(_ library: MobileLibrary, root: URL, generation: Int) -> Bool {
        library.paths.root == root && library.libraryGeneration == generation &&
            !library.isClosed && !library.isClosing && !library.libraryOperationBusy
    }
}

/// The host can checkpoint before privacy teardown without retaining the session or canvas.
@MainActor final class MobileSketchDraftControl {
    private weak var session: MobileSketchSession?
    fileprivate func attach(_ session: MobileSketchSession) { self.session = session }
    fileprivate func detach(_ session: MobileSketchSession) {
        if self.session === session { self.session = nil }
    }
    var hasUntouchedBlankCanvas: Bool { session?.hasUntouchedBlankCanvas == true }
    @discardableResult func checkpointNow(force: Bool = false) -> MobileSketchCheckpoint? { session?.checkpointNow(force: force) }
    @discardableResult func checkpointFailed(retry: Bool) -> Bool {
        session?.checkpointFailed(retry: retry) ?? false
    }
}

/// Storage-independent editor. The host owns presentation, privacy dismissal and durable save.
/// Canvas coordinates are origin-zero points; render at scale 1 using the returned explicit size.
@MainActor struct MobileSketchEditor: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var session: MobileSketchSession
    private let onDone: @MainActor (PKDrawing, CGSize) async throws -> Void
    private let onCancel: @MainActor () -> Void
    private let preserveOnCancel: @MainActor () -> Bool
    private let onPreserveDraft: (@MainActor () async throws -> Void)?
    private let onRestoreCopy: (@MainActor () -> Void)?
    private let onManageRecovery: (@MainActor () -> Void)?

    init(initialDrawing: PKDrawing, canvasSize: CGSize,
         draftControl: MobileSketchDraftControl? = nil,
         onCheckpoint: @escaping @MainActor (MobileSketchCheckpoint) -> Void = { _ in },
         preserveOnCancel: @escaping @MainActor () -> Bool = { false },
         onPreserveDraft: (@MainActor () async throws -> Void)? = nil,
         onRestoreCopy: (@MainActor () -> Void)? = nil,
         onManageRecovery: (@MainActor () -> Void)? = nil,
         onDone: @escaping @MainActor (PKDrawing, CGSize) async throws -> Void,
         onCancel: @escaping @MainActor () -> Void) throws {
        let session = try MobileSketchSession(drawing: initialDrawing, canvasSize: canvasSize,
            draftControl: draftControl, onCheckpoint: onCheckpoint)
        _session = StateObject(wrappedValue: session)
        self.onDone = onDone
        self.onCancel = onCancel
        self.preserveOnCancel = preserveOnCancel
        self.onPreserveDraft = onPreserveDraft
        self.onRestoreCopy = onRestoreCopy
        self.onManageRecovery = onManageRecovery
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") {
                    if preserveOnCancel() || session.requiresPreservation {
                        session.preserveAndClose(using: onPreserveDraft, completion: onCancel)
                    } else if session.requestCancel() { onCancel() }
                }.disabled(session.isSaving)
                Spacer()
                Text("Sketch").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { session.save(using: onDone) }.disabled(session.isSaving || session.isFinished)
            }.padding()
                ScrollView {
                    VStack(spacing: 12) {
                        Toggle("Draw with Finger", isOn: $session.fingerDrawing)
                            .accessibilityHint("When enabled, a finger draws instead of scrolling the canvas.")
                        ViewThatFits(in: .horizontal) {
                            HStack { historyButtons }
                            VStack { historyButtons }
                        }.buttonStyle(.bordered)
                        Button("More Room", systemImage: "arrow.down.to.line") { session.moreRoom() }
                            .disabled(!session.canAddRoom)
                            .accessibilityHint("Adds space below the drawing without changing existing strokes.")
                        if preserveOnCancel() || session.requiresPreservation, let onRestoreCopy {
                            Button("Restore a Copy in New Note") {
                                session.preserveAndClose(using: onPreserveDraft, completion: onRestoreCopy)
                            }.disabled(session.isSaving || session.isFinished)
                        }
                        if session.isSaving { ProgressView("Saving sketch") }
                        if let message = session.errorMessage {
                            Text(message).foregroundStyle(.red).accessibilityAddTraits(.updatesFrequently)
                            if let onManageRecovery {
                                Button("Manage Recovery Drafts") { session.manageRecovery(using: onManageRecovery) }
                                    .accessibilityHint("Opens saved drafts while keeping this drawing open. Return here to retry saving.")
                            }
                        }
                    }.padding()
                }
                .frame(maxHeight: dynamicTypeSize.isAccessibilitySize ? 280 : 190)
                .disabled(session.isSaving || session.isFinished)
                SketchCanvas(session: session)
                    .frame(minWidth: 1, maxWidth: session.canvasSize.width,
                           minHeight: min(120, session.canvasSize.height), maxHeight: session.canvasSize.height)
                    .clipped()
                    .accessibilityLabel("Sketch canvas")
                    .accessibilityHint("Draw using Pencil or enable Draw with Finger. Drawing tools appear in the tool palette.")

        }
        .interactiveDismissDisabled()
        .onAppear { session.activateDraftHooks() }
        .confirmationDialog("Discard this drawing?", isPresented: $session.confirmingCancel, titleVisibility: .visible) {
            Button("Discard Drawing", role: .destructive) { if session.confirmCancel() { onCancel() } }
            Button("Keep Editing", role: .cancel) { session.keepEditing() }
        } message: { Text("Discarding removes this open recovery draft. Any content already saved to the note is kept.") }
        .onDisappear { session.teardown() }
    }
    @ViewBuilder private var historyButtons: some View {
        Button("Undo", systemImage: "arrow.uturn.backward") { session.undo() }.disabled(!session.canUndo)
        Button("Redo", systemImage: "arrow.uturn.forward") { session.redo() }.disabled(!session.canRedo)
    }

}

@MainActor final class MobileSketchSession: NSObject, ObservableObject, PKCanvasViewDelegate {
    static let maximumDimension: CGFloat = 4096
    static let maximumPixels: CGFloat = 16_777_216
    enum Failure: Error { case invalidCanvas, invalidDrawing }
    let original: PKDrawing
    let canvas: PKCanvasView
    let picker = PKToolPicker()
    @Published private(set) var canvasSize: CGSize
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var isFinished = false
    @Published private(set) var isSaving = false
    private var saveGeneration = 0
    private var saveTask: Task<Void, Never>?
    @Published var confirmingCancel = false
    private let draftControl: MobileSketchDraftControl?
    private let onCheckpoint: @MainActor (MobileSketchCheckpoint) -> Void
    private let checkpointPause: @MainActor () async throws -> Void
    private var checkpointTask: Task<Void, Never>?
    private var checkpointGeneration = 0
    private var draftHooksActive = false
    private var checkpointDirty = true
    private var hasCheckpoint = false
    private var cancelConfirmationPending = false
    // Sticky after a failed attempt: Cancel may preserve, never silently discard this draft.
    @Published private(set) var requiresPreservation = false
    @Published private(set) var errorMessage: String?
    @Published var fingerDrawing = false {
        didSet { canvas.drawingPolicy = fingerDrawing ? .anyInput : .pencilOnly }
    }

    init(drawing: PKDrawing, canvasSize: CGSize,
         interfaceIdiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom,
         draftControl: MobileSketchDraftControl? = nil,
         onCheckpoint: @escaping @MainActor (MobileSketchCheckpoint) -> Void = { _ in },
         checkpointPause: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) throws {
        guard canvasSize.width.isFinite, canvasSize.height.isFinite,
              canvasSize.width >= 1, canvasSize.height >= 1,
              canvasSize.width <= Self.maximumDimension, canvasSize.height <= Self.maximumDimension,
              canvasSize.width * canvasSize.height <= Self.maximumPixels else { throw Failure.invalidCanvas }
        guard Self.valid(drawing, size: canvasSize) else { throw Failure.invalidDrawing }
        original = drawing
        checkpointDirty = !drawing.strokes.isEmpty
        self.canvasSize = canvasSize
        self.draftControl = draftControl; self.onCheckpoint = onCheckpoint; self.checkpointPause = checkpointPause
        canvas = SketchCanvasView()
        super.init()
        canvas.drawing = drawing
        canvas.delegate = self
        canvas.contentSize = canvasSize
        // Shrinking/rubber-banding reveals drawable coordinates outside the explicit
        // canvas. Keep useful zoom-in/panning without exposing that extra surface.
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 2
        canvas.bounces = false
        canvas.bouncesZoom = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.backgroundColor = .systemBackground
        fingerDrawing = interfaceIdiom == .phone
        canvas.drawingPolicy = fingerDrawing ? .anyInput : .pencilOnly
        canvas.accessibilityIdentifier = "mobile.sketch.canvas"
        picker.addObserver(canvas)
        (canvas as? SketchCanvasView)?.attached = { [weak self] in
            guard let self, !self.isFinished else { return }
            self.picker.setVisible(true, forFirstResponder: self.canvas)
            self.canvas.becomeFirstResponder()
            self.refreshUndo()
        }
    }
    var canAddRoom: Bool { !isFinished && !isSaving && canvasSize.height < min(Self.maximumDimension, Self.maximumPixels / canvasSize.width) }
    func moreRoom() {
        guard canAddRoom else { return }
        canvasSize.height = min(canvasSize.height * 2, Self.maximumDimension, Self.maximumPixels / canvasSize.width)
        canvas.contentSize = canvasSize
        scheduleCheckpoint()
    }
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) { refreshUndo(); scheduleCheckpoint() }
    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) { scheduleCheckpoint() }
    func activateDraftHooks() {
        guard !isFinished else { return }
        draftHooksActive = true
        draftControl?.attach(self)
    }
    private func stopDraftHooks() {
        draftHooksActive = false; checkpointGeneration += 1
        checkpointTask?.cancel(); checkpointTask = nil
        draftControl?.detach(self)
    }
    private func scheduleCheckpoint() {
        guard draftHooksActive, !isFinished, !isSaving else { return }
        checkpointDirty = true
        checkpointTask?.cancel(); checkpointGeneration += 1
        let generation = checkpointGeneration, pause = checkpointPause
        checkpointTask = Task { [weak self] in
            do {
                try await pause()
                try Task.checkCancellation()
                guard let self, self.draftHooksActive, !self.isFinished, self.checkpointGeneration == generation else { return }
                self.checkpointTask = nil // Do not cancel the task delivering this checkpoint.
                _ = self.checkpointNow()
            } catch { /* A newer stroke, explicit discard or privacy boundary owns the next checkpoint. */ }
        }
    }
    var hasUntouchedBlankCanvas: Bool {
        draftHooksActive && !isFinished && !requiresPreservation && !checkpointDirty && !hasCheckpoint && canvas.drawing.strokes.isEmpty
    }
    /// Synchronous snapshot only: it neither obtains keys nor waits for persistence.
    @discardableResult func checkpointNow(force: Bool = false) -> MobileSketchCheckpoint? {
        guard draftHooksActive, !isFinished else { return nil }
        checkpointTask?.cancel(); checkpointTask = nil; checkpointGeneration += 1
        let drawing = canvas.drawing
        // A fresh untouched blank sheet has nothing to recover. A later erase or explicit
        // resize remains meaningful and must replace its previous checkpoint.
        guard checkpointDirty || hasCheckpoint || !drawing.strokes.isEmpty else { return nil }
        // Serialize once: use the exact same archive for validation and persistence.
        // force skips debounce/unchanged checks, not the untouched-empty decision above.
        guard drawing.strokes.count <= 10_000,
              drawing.strokes.reduce(0, { $0 + $1.path.count }) <= 500_000 else {
            checkpointDirty = true
            showError("This drawing cannot be checkpointed safely. Keep the canvas open and undo the last change before leaving.")
            return nil
        }
        let archive = drawing.dataRepresentation()
        guard Self.valid(drawing, size: canvasSize, archive: archive) else {
            checkpointDirty = true
            showError("This drawing cannot be checkpointed safely. Keep the canvas open and undo the last change before leaving.")
            return nil
        }
        let snapshot = MobileSketchCheckpoint(drawingData: archive, canvasSize: canvasSize)
        if checkpointDirty || force || !hasCheckpoint {
            checkpointDirty = false; hasCheckpoint = true
            onCheckpoint(snapshot)
        }
        return snapshot
    }
    /// Persistence failed after taking the snapshot. Keep the live canvas dirty; a
    /// permitted retry must snapshot that canvas again, never replay stale host bytes.
    @discardableResult func checkpointFailed(retry: Bool) -> Bool {
        guard draftHooksActive, !isFinished else { return false }
        checkpointDirty = true
        if retry { return checkpointNow(force: true) != nil }
        showError("The recovery draft could not be saved. Your drawing is still open; try Done again before leaving.")
        return false
    }
    func waitForCheckpoint() async { await checkpointTask?.value }
    @discardableResult func requestCancel() -> Bool {
        guard !isFinished, !requiresPreservation else { return false }
        if !canvas.drawing.strokes.isEmpty {
            cancelConfirmationPending = true; confirmingCancel = true; return false
        }
        return cancel()
    }
    @discardableResult func confirmCancel() -> Bool {
        // SwiftUI may clear the presentation binding before invoking the selected action.
        guard cancelConfirmationPending else { return false }
        cancelConfirmationPending = false; confirmingCancel = false
        return cancel()
    }
    func keepEditing() { cancelConfirmationPending = false; confirmingCancel = false }
    func refreshUndo() {
        canUndo = canvas.undoManager?.canUndo == true
        canRedo = canvas.undoManager?.canRedo == true
    }
    func undo() { guard !isFinished, !isSaving else { return }; canvas.undoManager?.undo(); refreshUndo(); scheduleCheckpoint() }
    func redo() { guard !isFinished, !isSaving else { return }; canvas.undoManager?.redo(); refreshUndo(); scheduleCheckpoint() }
    /// Save a value snapshot while retaining the exact canvas and its undo manager for retry.
    /// Host work must honor Task cancellation and revalidate its own operation/privacy origin.
    func save(using operation: @escaping @MainActor (PKDrawing, CGSize) async throws -> Void) {
        guard !isFinished, !isSaving else { return }
        let drawing = canvas.drawing, size = canvasSize
        guard Self.valid(drawing, size: size) else {
            showError("This drawing exceeds the canvas or sketch size limit. Undo the last change or add more room.")
            return
        }
        _ = checkpointNow()
        saveGeneration += 1
        let generation = saveGeneration
        isSaving = true; errorMessage = nil; canvas.isUserInteractionEnabled = false
        UIAccessibility.post(notification: .announcement, argument: "Saving sketch")
        saveTask = Task { [weak self] in
            do {
                try await operation(drawing, size)
                guard let self, !Task.isCancelled, !self.isFinished, self.saveGeneration == generation else { return }
                self.isFinished = true
                self.stopDraftHooks()
                self.isSaving = false
                self.picker.setVisible(false, forFirstResponder: self.canvas)
            } catch {
                guard let self, !self.isFinished, self.saveGeneration == generation else { return }
                self.isSaving = false
                self.requiresPreservation = true
                self.canvas.isUserInteractionEnabled = true
                if !(error is CancellationError) { self.showError(error.localizedDescription) }
            }
        }
    }
    /// The host presents a nested manager; this is not a terminal editor action.
    func manageRecovery(using operation: @MainActor () -> Void) {
        guard !isFinished, !isSaving, errorMessage != nil else { return }
        operation()
    }
    /// A failed/uncertain write must not discard the only editable recovery copy.
    func preserveAndClose(using operation: (@MainActor () async throws -> Void)?,
                          completion: @escaping @MainActor () -> Void) {
        guard !isFinished, !isSaving else { return }
        guard let operation else { showError("The drawing could not be preserved. Keep this editor open and try again."); return }
        guard checkpointNow(force: true) != nil else {
            showError("The current drawing could not be preserved. Keep this editor open, undo the last change, and try again.")
            return
        }
        save { _, _ in
            try await operation()
            try Task.checkCancellation()
            completion()
        }
    }
    func waitForSave() async { await saveTask?.value }
    private func showError(_ message: String) {
        requiresPreservation = true
        errorMessage = message
        UIAccessibility.post(notification: .announcement, argument: message)
    }
    @discardableResult func cancel() -> Bool {
        guard !isFinished else { return false }
        isFinished = true; isSaving = false; saveGeneration += 1
        stopDraftHooks()
        saveTask?.cancel()
        canvas.isUserInteractionEnabled = false
        return true
    }
    func teardown() {
        if !isFinished, checkpointDirty { _ = checkpointNow() }
        cancel()
        picker.setVisible(false, forFirstResponder: canvas)
        picker.removeObserver(canvas)
        canvas.resignFirstResponder()
        canvas.delegate = nil
        (canvas as? SketchCanvasView)?.attached = nil
    }
    private static func valid(_ drawing: PKDrawing, size: CGSize, archive: Data? = nil) -> Bool {
        guard drawing.strokes.count <= 10_000,
              drawing.strokes.reduce(0, { $0 + $1.path.count }) <= 500_000,
              (archive?.count ?? drawing.dataRepresentation().count) <= MobileSketchPNG.maximumDrawingBytes else { return false }
        if drawing.strokes.isEmpty { return true }
        let bounds = drawing.bounds
        guard !bounds.isNull, !bounds.isInfinite,
              bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.width.isFinite, bounds.height.isFinite else { return false }
        // An already-captured touch can continue outside the viewport. Preserve those
        // strokes losslessly; both preview and export clip to the explicit canvas. Bound
        // geometry independently from raster size and retain the codec's per-stroke cap.
        let margin = Self.maximumDimension
        guard bounds.minX >= -margin, bounds.minY >= -margin,
              bounds.maxX <= size.width + margin, bounds.maxY <= size.height + margin else { return false }
        return drawing.strokes.allSatisfy {
            let ink = $0.renderBounds
            return !ink.isNull && !ink.isInfinite && ink.origin.x.isFinite && ink.origin.y.isFinite
                && ink.width.isFinite && ink.height.isFinite && ink.width <= 8192 && ink.height <= 8192
        }
    }
}

private struct SketchCanvas: UIViewRepresentable {
    @ObservedObject var session: MobileSketchSession
    func makeUIView(context: Context) -> PKCanvasView { session.canvas }
    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        canvas.contentSize = session.canvasSize
    }
}

/// Window attachment is the reliable point at which PencilKit can show its palette.
@MainActor private final class SketchCanvasView: PKCanvasView {
    var attached: (() -> Void)?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let target = window else { return }
        DispatchQueue.main.async { [weak self, weak target] in
            guard let self, let target, self.window === target else { return }
            self.attached?()
        }
    }
}
