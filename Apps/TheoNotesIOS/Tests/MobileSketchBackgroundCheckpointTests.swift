// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import PencilKit
import Testing
import TheoNotesCore
@testable import BaerchenIOS

@Suite(.serialized) @MainActor struct MobileSketchBackgroundCheckpointTests {
    private func stroke(_ x: CGFloat) -> PKStroke {
        let points = [CGPoint(x: x, y: 20), CGPoint(x: x + 10, y: 40)].enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.1, size: CGSize(width: 4, height: 4),
                opacity: 1, force: 0.5, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .blue),
            path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0)))
    }
    @Test func finalBackgroundStrokePersistsAfterActualApplicationLockBeforeQueuedWriter() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let note = try library.store.create(text: "# Original note remains unchanged")
        try await library.setAppLock(true, authenticate: {})
        let root = paths.root, generation = library.libraryGeneration, drafts = library.sketchDraftStore
        let host = MobileSketchDraftHost(store: drafts, owner: UUID(), originalNoteID: note.id,
            boundary: { MobileSketchDraftPersistenceBoundary.isCurrent(library, root: root, generation: generation) },
            protection: { MobileSketchDraftProtectionPolicy.resolve(requiresProtection: false, access: library.privateAccess) {
                try library.store.note(id: note.id)
            } })
        #expect(try await host.reserveFresh())
        let session = try MobileSketchSession(drawing: PKDrawing(strokes: [stroke(20)]),
            canvasSize: CGSize(width: 256, height: 256), draftControl: host.control,
            onCheckpoint: { host.checkpoint($0) }, checkpointPause: { try await Task.sleep(for: .seconds(3600)) })
        session.activateDraftHooks(); session.canvas.delegate = nil
        _ = host.control.checkpointNow()
        #expect(try await host.waitForCheckpoint())
        session.canvas.drawing = PKDrawing(strokes: [stroke(20), stroke(70)])
        session.canvasViewDrawingDidChange(session.canvas)
        let finalArchive = session.canvas.drawing.dataRepresentation()
        // The actual enterBackground ordering: final snapshot queues a writer, THEN
        // the shared app locks synchronously before that Task can run.
        host.suspend()
        library.lockApplication()
        session.teardown()
        #expect(library.appLockEnabled && library.appLocked)
        #expect(try await host.waitForCheckpoint())
        let durable = try #require(try await drafts.load(host.id))
        #expect(durable.drawingData == finalArchive)
        #expect(try PKDrawing(data: durable.drawingData).strokes.count == 2)
        #expect(try library.store.note(id: note.id)?.text == note.text)
        #expect(!MobileSketchDraftPersistenceBoundary.isCurrent(library, root: root, generation: generation + 1))
        try library.close()
        #expect(!MobileSketchDraftPersistenceBoundary.isCurrent(library, root: root, generation: generation))
    }
    @Test func revokedProtectedBackgroundWriteKeepsLastSealedSnapshotWithoutPlaintextFallback() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let note = try library.store.create(text: "")
        try await library.unlockNotes(password: "fixture password", createPassword: true)
        try library.lockNote(note.id)
        try await library.setAppLock(true, authenticate: {})
        let access = try #require(library.privateAccess), drafts = library.sketchDraftStore
        let root = paths.root, generation = library.libraryGeneration
        let host = MobileSketchDraftHost(store: drafts, owner: UUID(), originalNoteID: note.id,
            boundary: { MobileSketchDraftPersistenceBoundary.isCurrent(library, root: root, generation: generation) },
            protection: { MobileSketchDraftProtectionPolicy.resolve(requiresProtection: true, access: library.privateAccess) {
                try library.store.note(id: note.id)
            } })
        #expect(try await host.reserveFresh())
        let session = try MobileSketchSession(drawing: PKDrawing(strokes: [stroke(20)]),
            canvasSize: CGSize(width: 256, height: 256), draftControl: host.control,
            onCheckpoint: { host.checkpoint($0) }, checkpointPause: { try await Task.sleep(for: .seconds(3600)) })
        session.activateDraftHooks(); session.canvas.delegate = nil
        _ = host.control.checkpointNow(); #expect(try await host.waitForCheckpoint())
        let before = try #require(try await drafts.load(host.id, access: access))
        session.canvas.drawing = PKDrawing(strokes: [stroke(20), stroke(70)])
        session.canvasViewDrawingDidChange(session.canvas)
        host.suspend(); library.lockApplication(); try library.lockVault(); session.teardown()
        #expect(throws: NotePrivacyError.accessRevoked) { try access.journalKey() }
        await #expect(throws: MobileSketchDraftHost.Failure.self) { _ = try await host.waitForCheckpoint() }
        let reopened = try NotePrivacy(store: library.store).unlock(password: "fixture password")
        #expect(try await drafts.load(host.id, access: reopened) == before)
        #expect(try await drafts.discover().first(where: { $0.id == host.id })?.isProtected == true)
    }

}
