// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import PencilKit
import Combine
import Testing
import UIKit
@testable import BaerchenIOS

@Suite @MainActor struct MobileSketchEditorTests {
    @Test func mountingCanvasDefersObservableChangesUntilAfterWindowInsertion() async throws {
        let session = try MobileSketchSession(drawing: PKDrawing(), canvasSize: CGSize(width: 256, height: 256))
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { session.teardown(); window.isHidden = true; window.rootViewController = nil }
        var changes = 0
        let observation = session.objectWillChange.sink { changes += 1 }
        host.view.addSubview(session.canvas)
        #expect(changes == 0)
        for _ in 0..<100 where changes == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(changes > 0)
        withExtendedLifetime(observation) {}
    }
    @Test func detachedCanvasDoesNotActivateOnTheNextMainQueuePass() async throws {
        let session = try MobileSketchSession(drawing: PKDrawing(), canvasSize: CGSize(width: 256, height: 256))
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { session.teardown(); window.isHidden = true; window.rootViewController = nil }
        var changes = 0
        let observation = session.objectWillChange.sink { changes += 1 }
        host.view.addSubview(session.canvas)
        session.canvas.removeFromSuperview()
        try await Task.sleep(for: .milliseconds(100))
        #expect(changes == 0)
        #expect(!session.canvas.isFirstResponder)
        withExtendedLifetime(observation) {}
    }
    private func drawing() -> PKDrawing {
        let points = [CGPoint(x: 20, y: 20), CGPoint(x: 40, y: 40)].enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.1,
                size: CGSize(width: 4, height: 4), opacity: 1, force: 0.5, azimuth: 0, altitude: .pi / 2)
        }
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .blue),
            path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0)))])
    }
    @Test func strokeEndLatePressureAndMoreRoomDebounceIntoLatestCheckpoint() async throws {
        let delay = HeldSketchCheckpointDelay(), control = MobileSketchDraftControl()
        var snapshots: [MobileSketchCheckpoint] = []
        let session = try MobileSketchSession(drawing: drawing(), canvasSize: CGSize(width: 256, height: 256),
            draftControl: control, onCheckpoint: { snapshots.append($0) }, checkpointPause: { await delay.wait() })
        session.activateDraftHooks()
        session.canvas.delegate = nil // Drive delegate events explicitly; avoid UIKit delivery timing.
        session.canvasViewDidEndUsingTool(session.canvas)
        await Task.yield()
        session.canvas.drawing = drawing().transformed(using: CGAffineTransform(translationX: 5, y: 0))
        session.canvasViewDrawingDidChange(session.canvas) // delayed pressure/update after stroke end
        await Task.yield()
        session.moreRoom()
        await Task.yield()
        delay.releaseAll()
        await session.waitForCheckpoint()
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.canvasSize == CGSize(width: 256, height: 512))
        #expect(snapshots.first?.drawingData == session.canvas.drawing.dataRepresentation())
        session.teardown()
    }
    @Test func immediateBackgroundCheckpointCancelsDebounceAndTeardownDetachesWeakControl() async throws {
        let delay = HeldSketchCheckpointDelay(), control = MobileSketchDraftControl()
        var snapshots: [MobileSketchCheckpoint] = []
        let session = try MobileSketchSession(drawing: drawing(), canvasSize: CGSize(width: 256, height: 256),
            draftControl: control, onCheckpoint: { snapshots.append($0) }, checkpointPause: { await delay.wait() })
        session.activateDraftHooks()
        session.canvas.delegate = nil // Drive delegate events explicitly; avoid UIKit delivery timing.
        session.canvasViewDrawingDidChange(session.canvas)
        await Task.yield()
        let immediate = try #require(control.checkpointNow())
        #expect(immediate.drawingData == session.canvas.drawing.dataRepresentation() && snapshots.count == 1)
        session.teardown() // best-effort checkpoint, not explicit discard
        let count = snapshots.count
        #expect(control.checkpointNow() == nil)
        delay.releaseAll()
        await Task.yield()
        #expect(snapshots.count == count)
    }
    @Test func explicitCancelConfirmationDoesNotDiscardOrCloseUntilConfirmed() throws {
        let control = MobileSketchDraftControl()
        var snapshots = 0
        let session = try MobileSketchSession(drawing: drawing(), canvasSize: CGSize(width: 256, height: 256),
            draftControl: control, onCheckpoint: { _ in snapshots += 1 })
        session.activateDraftHooks()
        #expect(!session.requestCancel() && session.confirmingCancel && !session.isFinished)
        session.keepEditing()
        #expect(control.checkpointNow() != nil && snapshots == 1)
        #expect(!session.requestCancel())
        session.confirmingCancel = false // SwiftUI can clear the binding before its action runs.
        #expect(session.confirmCancel() && session.isFinished)
        let before = snapshots
        session.teardown()
        #expect(snapshots == before && control.checkpointNow() == nil)
        let empty = try MobileSketchSession(drawing: PKDrawing(), canvasSize: CGSize(width: 256, height: 256))
        #expect(empty.requestCancel() && !empty.confirmingCancel)
    }
    @Test func edgeInkIsPreservedAndPhoneAcceptsFinger() async throws {
        let edge = drawing().transformed(using: CGAffineTransform(translationX: -20, y: -20))
        let session = try MobileSketchSession(drawing: edge, canvasSize: CGSize(width: 32, height: 32), interfaceIdiom: .phone)
        #expect(session.fingerDrawing && session.canvas.drawingPolicy == .anyInput)
        var saved = false
        session.save { value, size in
            #expect(value.dataRepresentation() == edge.dataRepresentation())
            #expect(size == CGSize(width: 32, height: 32))
            saved = true
        }
        await session.waitForSave()
        #expect(saved && session.isFinished)
    }
    @Test func tabletDefaultsToPencilAndToggleExplicitlyEnablesFinger() throws {
        let session = try MobileSketchSession(drawing: PKDrawing(), canvasSize: CGSize(width: 256, height: 256), interfaceIdiom: .pad)
        #expect(!session.fingerDrawing && session.canvas.drawingPolicy == .pencilOnly)
        session.fingerDrawing = true
        #expect(session.canvas.drawingPolicy == .anyInput)
        session.fingerDrawing = false
        #expect(session.canvas.drawingPolicy == .pencilOnly)
        session.teardown()
    }
    @Test func preservingCloseCannotDeliverLateTerminalCallbackAfterPrivacyTeardown() async throws {
        let session = try MobileSketchSession(drawing: drawing(), canvasSize: CGSize(width: 256, height: 256))
        session.activateDraftHooks()
        let held = HeldSketchSave()
        var closed = false
        session.preserveAndClose(using: { await held.run() }, completion: { closed = true })
        for _ in 0..<1000 { if held.started { break }; await Task.yield() }
        try #require(held.started)
        session.teardown()
        held.release()
        await session.waitForSave()
        #expect(!closed && session.isFinished)
    }
    @Test func erasingAnExistingDrawingStillCheckpointsTheEmptyResult() throws {
        var snapshots: [MobileSketchCheckpoint] = []
        let session = try MobileSketchSession(drawing: drawing(), canvasSize: CGSize(width: 256, height: 256), onCheckpoint: { snapshots.append($0) })
        session.activateDraftHooks()
        _ = session.checkpointNow()
        session.canvas.delegate = nil
        session.canvas.drawing = PKDrawing()
        session.canvasViewDrawingDidChange(session.canvas)
        _ = session.checkpointNow()
        #expect(snapshots.count == 2)
        #expect(try PKDrawing(data: #require(snapshots.last?.drawingData)).strokes.isEmpty)
        session.teardown()
    }
    @Test func untouchedBlankDoesNotCreateRecoveryDraft() throws {
        var snapshots = 0
        let session = try MobileSketchSession(drawing: PKDrawing(), canvasSize: CGSize(width: 256, height: 256), onCheckpoint: { _ in snapshots += 1 })
        session.activateDraftHooks()
        #expect(session.checkpointNow() == nil)
        #expect(session.checkpointNow(force: true) == nil, "Background force must not create an untouched blank draft")
        session.teardown()
        #expect(snapshots == 0)
    }
    @Test func recoveryManagementKeepsCurrentCanvasUndoAndAllowsSameDraftRetry() async throws {
        let control = MobileSketchDraftControl()
        let session = try MobileSketchSession(drawing: drawing(), canvasSize: CGSize(width: 256, height: 256), draftControl: control)
        session.activateDraftHooks()
        let canvas = session.canvas, undo = canvas.undoManager, bytes = canvas.drawing.dataRepresentation()
        var managementCalls = 0
        session.manageRecovery { managementCalls += 1 }
        #expect(managementCalls == 0) // No error: no capacity-recovery action.
        session.save { _, _ in throw SketchSaveFailure.failed }
        await session.waitForSave()
        session.manageRecovery { managementCalls += 1 }
        #expect(managementCalls == 1 && !session.isFinished && !session.isSaving)
        #expect(session.canvas === canvas && session.canvas.undoManager === undo)
        #expect(session.canvas.drawing.dataRepresentation() == bytes && canvas.isUserInteractionEnabled)
        #expect(control.checkpointNow()?.drawingData == bytes)
        #expect(!session.confirmingCancel)
        var retried = false
        session.save { drawing, _ in
            #expect(drawing.dataRepresentation() == bytes)
            retried = true
        }
        await session.waitForSave()
        #expect(retried && session.isFinished)
        session.manageRecovery { Issue.record("Management accepted after terminal save") }
        session.teardown()
    }
    @Test func localValidationFailureRequiresPreservingCancelWithoutDiscardDialog() async throws {
        let session = try MobileSketchSession(drawing: PKDrawing(), canvasSize: CGSize(width: 16, height: 16))
        session.canvas.drawing = drawing().transformed(using: CGAffineTransform(translationX: 100_000, y: 0))
        let bytes = session.canvas.drawing.dataRepresentation()
        var attemptedWriter = false
        session.save { _, _ in attemptedWriter = true }
        await session.waitForSave()
        #expect(!attemptedWriter && session.requiresPreservation && session.errorMessage != nil)
        #expect(!session.requestCancel() && !session.confirmingCancel && !session.isFinished)
        #expect(session.canvas.drawing.dataRepresentation() == bytes)
        session.teardown()
    }
    @Test func preservingCloseRefusesMissingFreshCheckpointEvenWhenHostAcceptsOldWrite() async throws {
        let session = try MobileSketchSession(drawing: drawing(), canvasSize: CGSize(width: 256, height: 256))
        // Without live hooks no fresh snapshot can reach the host. A successful stale host
        // acknowledgement must never be enough to close the only current canvas.
        var durabilityCalls = 0, closed = false
        session.preserveAndClose(using: { durabilityCalls += 1 }, completion: { closed = true })
        await session.waitForSave()
        #expect(durabilityCalls == 0 && !closed && !session.isFinished && session.errorMessage != nil)
        #expect(session.canvas.isUserInteractionEnabled)
        session.teardown()
    }
    @Test func overStrokeBudgetDoesNotPreserveByAcknowledgingOlderCheckpoint() async throws {
        var checkpoints = 0
        let initial = drawing()
        let session = try MobileSketchSession(drawing: initial, canvasSize: CGSize(width: 256, height: 256), onCheckpoint: { _ in checkpoints += 1 })
        session.activateDraftHooks()
        _ = session.checkpointNow()
        try #require(checkpoints == 1)
        session.canvas.delegate = nil
        session.canvas.drawing = PKDrawing(strokes: Array(repeating: try #require(initial.strokes.first), count: 10_001))
        var durabilityCalls = 0, closed = false
        session.preserveAndClose(using: { durabilityCalls += 1 }, completion: { closed = true })
        await session.waitForSave()
        #expect(checkpoints == 1 && durabilityCalls == 0 && !closed && !session.isFinished)
        #expect(session.errorMessage != nil && session.canvas.drawing.strokes.count == 10_001)
        session.teardown()
    }
    @Test func preservingCloseWaitsForDurabilityAndFailureKeepsCanvas() async throws {
        let session = try MobileSketchSession(drawing: drawing(), canvasSize: CGSize(width: 256, height: 256))
        session.activateDraftHooks()
        let canvas = session.canvas, bytes = canvas.drawing.dataRepresentation()
        var closed = false
        session.preserveAndClose(using: { throw SketchSaveFailure.failed }, completion: { closed = true })
        await session.waitForSave()
        #expect(!closed && !session.isFinished && session.errorMessage != nil)
        #expect(session.canvas === canvas && canvas.drawing.dataRepresentation() == bytes && canvas.isUserInteractionEnabled)
        let held = HeldSketchSave()
        session.preserveAndClose(using: { await held.run() }, completion: { closed = true })
        for _ in 0..<1000 { if held.started { break }; await Task.yield() }
        try #require(held.started)
        #expect(!closed && !session.isFinished && session.isSaving)
        held.release()
        await session.waitForSave()
        #expect(closed && session.isFinished)
    }
    @Test func rejectsUnboundedCanvas() throws {
        #expect(throws: MobileSketchSession.Failure.self) {
            try MobileSketchSession(drawing: PKDrawing(), canvasSize: CGSize(width: CGFloat.infinity, height: 100))
        }
        #expect(throws: MobileSketchSession.Failure.self) {
            try MobileSketchSession(drawing: PKDrawing(), canvasSize: CGSize(width: 5000, height: 100))
        }
    }
    @Test func moreRoomKeepsStrokesAndHasFiniteLimit() throws {
        let session = try MobileSketchSession(drawing: PKDrawing(), canvasSize: CGSize(width: 256, height: 300))
        session.canvas.drawing = drawing()
        let bytes = session.canvas.drawing.dataRepresentation()
        session.moreRoom()
        #expect(session.canvasSize == CGSize(width: 256, height: 600))
        #expect(session.canvas.drawing.dataRepresentation() == bytes)
        for _ in 0..<20 { session.moreRoom() }
        #expect(session.canvasSize.height == 4096)
        #expect(!session.canAddRoom)
    }
    @Test func failedSaveRetainsSameCanvasDrawingAndUndoThenAllowsRetry() async throws {
        let session = try MobileSketchSession(drawing: PKDrawing(), canvasSize: CGSize(width: 256, height: 256))
        session.canvas.drawing = drawing()
        let canvas = session.canvas, bytes = canvas.drawing.dataRepresentation(), undo = canvas.undoManager
        var calls = 0
        session.save { _, _ in calls += 1; throw SketchSaveFailure.failed }
        await session.waitForSave()
        #expect(!session.isSaving && !session.isFinished && session.errorMessage != nil)
        #expect(session.canvas === canvas && session.canvas.undoManager === undo)
        #expect(session.canvas.drawing.dataRepresentation() == bytes && session.original.strokes.isEmpty)
        #expect(session.canvas.isUserInteractionEnabled)
        session.save { submitted, size in
            calls += 1
            #expect(submitted.dataRepresentation() == bytes && size == CGSize(width: 256, height: 256))
        }
        await session.waitForSave()
        #expect(calls == 2 && session.isFinished && !session.isSaving)
        session.save { _, _ in calls += 1 }
        #expect(calls == 2)
    }
    @Test(arguments: [false, true])
    func heldSaveBlocksDuplicatesAndCancelOrPrivacyTeardownFencesLateSuccess(teardown: Bool) async throws {
        let session = try MobileSketchSession(drawing: drawing(), canvasSize: CGSize(width: 256, height: 256))
        let held = HeldSketchSave()
        session.save { _, _ in await held.run() }
        for _ in 0..<1000 { if held.started { break }; await Task.yield() }
        try #require(held.started)
        #expect(session.isSaving && !session.canvas.isUserInteractionEnabled)
        session.save { _, _ in Issue.record("Duplicate save accepted") }
        if teardown { session.teardown() } else { #expect(session.cancel()); #expect(!session.cancel()) }
        held.release()
        await session.waitForSave()
        #expect(session.isFinished && !session.isSaving && session.errorMessage == nil)
        #expect(held.calls == 1)
        session.save { _, _ in Issue.record("Save accepted after closure") }
    }
    @Test func wildlyDistantDrawingCannotBeSaved() async throws {
        let session = try MobileSketchSession(drawing: PKDrawing(), canvasSize: CGSize(width: 16, height: 16))
        session.canvas.drawing = drawing().transformed(using: CGAffineTransform(translationX: 100_000, y: 0))
        var calls = 0
        session.save { _, _ in calls += 1 }
        await session.waitForSave()
        #expect(calls == 0 && session.errorMessage != nil && !session.isFinished)
        session.canvas.drawing = PKDrawing()
        session.save { _, _ in calls += 1 }
        await session.waitForSave()
        #expect(calls == 1 && session.isFinished)
    }
}
private enum SketchSaveFailure: Error { case failed }
@MainActor private final class HeldSketchSave {
    var calls = 0
    var started: Bool { continuation != nil }
    private var continuation: CheckedContinuation<Void, Never>?
    func run() async {
        calls += 1
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor private final class HeldSketchCheckpointDelay {
    private var held: [CheckedContinuation<Void, Never>] = []
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { held.append($0) }
    }
    func releaseAll() { released = true; let pending = held; held.removeAll(); for continuation in pending { continuation.resume() } }
}
