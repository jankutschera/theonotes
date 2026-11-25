// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import PencilKit
import Testing
@testable import BaerchenIOS

private actor SketchRetryBarrier {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var attempts = 0
    func pauseFirst() async {
        attempts += 1
        if attempts == 1 { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private actor SketchAlwaysCancelledCheckpoint {
    private(set) var attempts = 0
    func fail() throws { attempts += 1; throw CancellationError() }
}

@Suite(.serialized) @MainActor struct MobileSketchCheckpointRetryTests {
    private func drawing() -> PKDrawing {
        let points = [CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 20)].enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.1,
                size: CGSize(width: 2, height: 2), opacity: 1, force: 0.5, azimuth: 0, altitude: .pi / 2)
        }
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .blue),
            path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0)))])
    }
    @Test func unrelatedEpochChangeRetriesFreshLiveCanvasOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let barrier = SketchRetryBarrier()
        let store = MobileSketchDraftStore(root: root, libraryID: "retry-fixture", beforeCheckpoint: { await barrier.pauseFirst() })
        let host = MobileSketchDraftHost(store: store, owner: UUID(), originalNoteID: UUID().uuidString,
            boundary: { true }, protection: { .plain })
        #expect(try await host.reserveFresh())
        let session = try MobileSketchSession(drawing: drawing(), canvasSize: .init(width: 64, height: 64),
            draftControl: host.control, onCheckpoint: { host.checkpoint($0) },
            checkpointPause: { try await Task.sleep(for: .seconds(3600)) })
        session.activateDraftHooks()
        _ = session.checkpointNow(force: true)
        for _ in 0..<200 { if await barrier.attempts == 1 { break }; try await Task.sleep(for: .milliseconds(10)) }
        try #require(await barrier.attempts == 1)
        // The original snapshot was 64 high. Retry must read the live 128-high canvas.
        session.moreRoom()
        await store.invalidatePendingWrites()
        await barrier.release()
        #expect(try await host.waitForCheckpoint())
        let saved = try #require(try await store.load(host.id))
        #expect(saved.canvasSize.height == 128)
        #expect(await barrier.attempts == 2)
        session.teardown()
    }

    @Test func forcedSuspendCapturesCleanCanvas() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MobileSketchDraftStore(root: root, libraryID: "retry-fixture")
        let host = MobileSketchDraftHost(store: store, owner: UUID(), originalNoteID: UUID().uuidString,
            boundary: { true }, protection: { .plain })
        #expect(try await host.reserveFresh())
        let session = try MobileSketchSession(drawing: drawing(), canvasSize: .init(width: 64, height: 64),
            draftControl: host.control, onCheckpoint: { host.checkpoint($0) },
            checkpointPause: { try await Task.sleep(for: .seconds(3600)) })
        session.activateDraftHooks()
        _ = session.checkpointNow()
        #expect(try await host.waitForCheckpoint())
        let baseline = try #require(try await store.load(host.id))
        // Model a final PencilKit update before its delegate delivery: dirty is still
        // false, but forced suspend must read the actual live nonempty canvas.
        session.canvas.delegate = nil
        session.canvas.drawing = drawing().transformed(using: CGAffineTransform(translationX: 5, y: 0))
        let final = session.canvas.drawing.dataRepresentation()
        host.suspend()
        #expect(try await host.waitForCheckpoint())
        let saved = try #require(try await store.load(host.id))
        #expect(saved.canvasSize == CGSize(width: 64, height: 64))
        #expect(saved.generation > baseline.generation && saved.drawingData == final)
        #expect(saved.drawingData != baseline.drawingData)
        session.teardown()
    }
    @Test func privacyBoundaryDoesNotRetryWithFreshAdmission() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let barrier = SketchRetryBarrier()
        let store = MobileSketchDraftStore(root: root, libraryID: "retry-fixture", beforeCheckpoint: { await barrier.pauseFirst() })
        var current = true
        let host = MobileSketchDraftHost(store: store, owner: UUID(), originalNoteID: UUID().uuidString,
            boundary: { current }, protection: { .plain })
        #expect(try await host.reserveFresh())
        let session = try MobileSketchSession(drawing: drawing(), canvasSize: .init(width: 64, height: 64),
            draftControl: host.control, onCheckpoint: { host.checkpoint($0) },
            checkpointPause: { try await Task.sleep(for: .seconds(3600)) })
        session.activateDraftHooks()
        _ = session.checkpointNow(force: true)
        for _ in 0..<200 { if await barrier.attempts == 1 { break }; try await Task.sleep(for: .milliseconds(10)) }
        try #require(await barrier.attempts == 1)
        current = false
        await store.invalidatePendingWrites()
        await barrier.release()
        await #expect(throws: CancellationError.self) { try await host.waitForCheckpoint() }
        #expect(await barrier.attempts == 1)
        #expect(try await store.discover().isEmpty)
        #expect(session.errorMessage != nil && session.requiresPreservation)
        session.teardown()
    }

    @Test func secondCancellationStopsAutomaticRetryAndLeavesCanvasDirty() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let failure = SketchAlwaysCancelledCheckpoint()
        let store = MobileSketchDraftStore(root: root, libraryID: "retry-fixture", beforeCheckpoint: { try await failure.fail() })
        let host = MobileSketchDraftHost(store: store, owner: UUID(), originalNoteID: UUID().uuidString,
            boundary: { true }, protection: { .plain })
        #expect(try await host.reserveFresh())
        let session = try MobileSketchSession(drawing: drawing(), canvasSize: .init(width: 64, height: 64),
            draftControl: host.control, onCheckpoint: { host.checkpoint($0) },
            checkpointPause: { try await Task.sleep(for: .seconds(3600)) })
        session.activateDraftHooks()
        _ = session.checkpointNow(force: true)
        await #expect(throws: CancellationError.self) { try await host.waitForCheckpoint() }
        #expect(await failure.attempts == 2)
        #expect(session.errorMessage != nil && session.requiresPreservation)
        // Dirty was restored even though neither attempted snapshot persisted.
        #expect(session.checkpointNow() != nil)
        session.teardown()
    }

}
