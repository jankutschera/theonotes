// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import PencilKit
import Testing
import TheoNotesCore
@testable import BaerchenIOS

private actor PrivacyCheckpointHold {
    private var continuation: CheckedContinuation<Void, Never>?
    private var armed = false
    private(set) var entered = false
    func arm() { armed = true }
    func pause() async {
        if armed { entered = true; await withCheckedContinuation { continuation = $0 } }
    }
    func release() { continuation?.resume(); continuation = nil; armed = false }
}

@Suite(.serialized) @MainActor struct MobileSketchPrivacyCloseBudgetTests {
    private func drawing(_ two: Bool) -> PKDrawing {
        let strokes = (two ? [20.0, 70.0] : [20.0]).map { x in
            let points = [CGPoint(x: x, y: 20), CGPoint(x: x + 10, y: 40)].enumerated().map { index, point in
                PKStrokePoint(location: point, timeOffset: Double(index) * 0.1, size: .init(width: 4, height: 4),
                    opacity: 1, force: 0.5, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: PKInk(.pen, color: .blue), path: PKStrokePath(controlPoints: points, creationDate: .distantPast))
        }
        return PKDrawing(strokes: strokes)
    }
    @Test(arguments: [false, true]) func sealedFinalCheckpointPrecedesRevocationUnlessBudgetExpires(slow: Bool) async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let note = try library.store.create(text: "")
        try await library.unlockNotes(password: "fixture-password", createPassword: true)
        try library.lockNote(note.id)
        try await library.setAppLock(true, authenticate: {})
        let access = try #require(library.privateAccess)
        let held = PrivacyCheckpointHold()
        let store = MobileSketchDraftStore(root: paths.root, libraryID: MobileCardPublication.libraryID(for: paths),
            beforeCheckpoint: { await held.pause() })
        let root = paths.root, generation = library.libraryGeneration
        let host = MobileSketchDraftHost(store: store, owner: UUID(), originalNoteID: note.id,
            boundary: { MobileSketchDraftPersistenceBoundary.isCurrent(library, root: root, generation: generation) },
            protection: { MobileSketchDraftProtectionPolicy.resolve(requiresProtection: true, access: library.privateAccess) {
                try library.store.note(id: note.id)
            } })
        #expect(try await host.reserveFresh())
        let session = try MobileSketchSession(drawing: drawing(false), canvasSize: .init(width: 256, height: 256),
            draftControl: host.control, onCheckpoint: { host.checkpoint($0) },
            checkpointPause: { try await Task.sleep(for: .seconds(3600)) })
        session.activateDraftHooks(); session.canvas.delegate = nil
        _ = host.control.checkpointNow(); #expect(try await host.waitForCheckpoint())
        let before = try #require(try await store.load(host.id, access: access))
        session.canvas.drawing = drawing(true)
        session.canvasViewDrawingDidChange(session.canvas)
        let latest = session.canvas.drawing.dataRepresentation()
        if slow { await held.arm() }
        host.suspend(); library.lockApplication(); session.teardown()
        #expect(library.appLocked)
        if slow {
            for _ in 0..<100 { if await held.entered { break }; try await Task.sleep(for: .milliseconds(10)) }
            try #require(await held.entered)
        }
        // This is the same bounded wait used by the real privacy-close path. A held
        // writer must not delay revocation until that writer cooperates.
        let completed = await MobileSketchPrivacyCloseBudget.wait(timeout: slow ? .milliseconds(30) : .seconds(2)) {
            _ = try? await host.waitForCheckpoint()
        }
        #expect(completed == !slow)
        #expect(library.privateAccess != nil) // Wait itself does not revoke early.
        if !completed {
            library.revokePrivateAccessForExpiredPrivacyClose()
            // The writer is still held: revocation cannot wait for its flush or release.
            #expect(await held.entered)
            #expect(throws: NotePrivacyError.accessRevoked) { try access.journalKey() }
        }
        try library.lockVault()
        #expect(throws: NotePrivacyError.accessRevoked) { try access.journalKey() }
        if slow {
            #expect(await held.entered)
            await held.release()
            _ = try? await host.waitForCheckpoint()
        }
        let reopened = try NotePrivacy(store: library.store).unlock(password: "fixture-password")
        defer { reopened.revoke() }
        let durable = try #require(try await store.load(host.id, access: reopened))
        #expect(durable.drawingData == (slow ? before.drawingData : latest))
        #expect(try await store.discover().first?.isProtected == true)
        await #expect(throws: (any Error).self) { _ = try await store.load(host.id) }
    }
    @Test func untouchedBlankSkipsSuspendedCheckpointButDetachedUnknownDoesNot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MobileSketchDraftStore(root: root, libraryID: "blank-fixture")
        let host = MobileSketchDraftHost(store: store, owner: UUID(), originalNoteID: UUID().uuidString,
            boundary: { true }, protection: { .plain })
        #expect(try await host.reserveFresh())
        let session = try MobileSketchSession(drawing: PKDrawing(), canvasSize: .init(width: 64, height: 64),
            draftControl: host.control, onCheckpoint: { host.checkpoint($0) })
        session.activateDraftHooks()
        host.suspend()
        try await host.completeSuspendedCheckpoint()
        #expect(try await store.discover().isEmpty)
        session.teardown()
        host.suspend() // Duplicate lifecycle dismissal retains the proven empty result.
        try await host.completeSuspendedCheckpoint()
        let unknown = MobileSketchDraftHost(store: store, owner: UUID(), originalNoteID: UUID().uuidString,
            boundary: { true }, protection: { .plain })
        // A missing editor is not proof of intentionally empty content.
        unknown.suspend()
        await #expect(throws: MobileSketchDraftHost.Failure.self) { try await unknown.completeSuspendedCheckpoint() }
    }

    @Test func modifiedBlankResizeStillPersistsAndNeverUsesUntouchedExemption() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MobileSketchDraftStore(root: root, libraryID: "blank-fixture", beforeCheckpoint: { throw CocoaError(.fileWriteOutOfSpace) })
        let host = MobileSketchDraftHost(store: store, owner: UUID(), originalNoteID: UUID().uuidString,
            boundary: { true }, protection: { .plain })
        #expect(try await host.reserveFresh())
        let session = try MobileSketchSession(drawing: PKDrawing(), canvasSize: .init(width: 64, height: 64),
            draftControl: host.control, onCheckpoint: { host.checkpoint($0) })
        session.activateDraftHooks(); session.moreRoom()
        host.suspend()
        await #expect(throws: (any Error).self) { try await host.completeSuspendedCheckpoint() }
        #expect(try await store.discover().isEmpty)
        session.teardown()
    }

    @Test func exhaustedCheckpointBudgetCannotReportPagesDrainedEvenIfWorkerWinsTimer() async {
        var checkpointCompleted = false, pagesCalled = false, pagesAttempted = true
        // Already exhausted, deterministically: reproduces a synchronous checkpoint
        // consuming the deadline before the MainActor timer gets its scheduling turn.
        let deadline = Date().addingTimeInterval(-1)
        let workerCompleted = await MobileSketchPrivacyCloseBudget.wait(timeout: .seconds(1)) {
            pagesAttempted = await MobileSketchPrivacyCloseBudget.checkpointBeforePages(deadline: deadline,
                checkpoints: { checkpointCompleted = true }, pages: { _ in pagesCalled = true })
        }
        #expect(workerCompleted && checkpointCompleted)
        #expect(!pagesAttempted && !pagesCalled)
        #expect(!(workerCompleted && pagesAttempted))
    }

    @Test(arguments: [false, true])
    func finalSynchronousCleanupRevokesOnlySharedPrivacyAccess(shared: Bool) async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        try await library.unlockNotes(password: "final revoke fixture", createPassword: true)
        let access = try #require(library.privateAccess)
        _ = try access.journalKey()
        // This is the production fence at the start of finishPrivacyClose, before
        // closeForPrivacy or lockVault can synchronously flush a journal.
        MobileSketchPrivacyCloseBudget.revokeBeforeSynchronousClose(library: library, shared: shared)
        if shared { #expect(throws: NotePrivacyError.accessRevoked) { try access.journalKey() } }
        else { _ = try access.journalKey() }
        try library.lockVault()
        #expect(library.privateAccess == nil)
        try await library.closeAfterStopping()
        try FileManager.default.removeItem(at: paths.root)
    }

}
