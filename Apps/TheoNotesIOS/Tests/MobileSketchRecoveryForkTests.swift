// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import PencilKit
import Testing
import TheoNotesCore
@testable import BaerchenIOS

private actor SketchSourceReleaseBarrier {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func hold() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@Suite(.serialized) @MainActor struct MobileSketchRecoveryForkTests {
    @Test(arguments: [false, true]) func newTargetForkKeepsAuthenticatedUncertainOriginalAndCanSave(protected: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = AppPaths(root: root); try paths.createDirectories()
        let db = try AppDatabase(path: paths.database)
        defer { try? db.pool.close(); try? FileManager.default.removeItem(at: root) }
        let notes = NoteStore(db: db, notifier: nil, paths: paths)
        let access = try NotePrivacy(store: notes).setPassword("fixture-password")
        defer { access.revoke() }
        let store = MobileSketchDraftStore(root: root, libraryID: "fork-fixture")
        let oldNote = UUID().uuidString, newNote = UUID().uuidString, owner = UUID()
        let bytes = PKDrawing().dataRepresentation()
        let source = MobileSketchDraftStore.Draft(generation: 7, originalNoteID: oldNote,
            sourceFilename: "Original.png", sourceSHA256: String(repeating: "a", count: 64),
            drawingData: bytes, canvasSize: .init(width: 64, height: 64), state: .insertionUnconfirmed)
        let protection: MobileSketchDraftStore.Protection = protected ? .sealed(access) : .plain
        try await store.checkpoint(source, protection: protection)
        #expect(try await store.claim(source.id, owner: owner))
        let authenticated = try #require(try await store.load(source.id, access: protected ? access : nil))
        let host = MobileSketchDraftHost(store: store, owner: owner, originalNoteID: newNote,
            boundary: { true }, protection: { protection })
        try await host.establishRecoveredCopy(from: authenticated)
        #expect(host.id != source.id)
        let fork = try #require(try await store.load(host.id, access: protected ? access : nil))
        #expect(fork.originalNoteID == newNote && fork.state == .editing)
        #expect(fork.sourceFilename == nil && fork.sourceSHA256 == nil)
        #expect(fork.drawingData == bytes)
        try await host.prepareForWrite()
        try await host.confirmedSave()
        #expect(try await store.load(host.id, access: protected ? access : nil) == nil)
        let retained = try #require(try await store.load(source.id, access: protected ? access : nil))
        #expect(retained.originalNoteID == oldNote && retained.state == .insertionUnconfirmed)
        #expect(retained.drawingData == bytes)
        if protected { await #expect(throws: (any Error).self) { _ = try await store.load(source.id) } }
    }

    @Test func staleCopyAdmissionCannotReplaceOrDeleteOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MobileSketchDraftStore(root: root, libraryID: "fork-fixture")
        let source = MobileSketchDraftStore.Draft(generation: 1, originalNoteID: UUID().uuidString,
            drawingData: PKDrawing().dataRepresentation(), canvasSize: .init(width: 64, height: 64))
        try await store.checkpoint(source, protection: .plain)
        let host = MobileSketchDraftHost(store: store, owner: UUID(), originalNoteID: UUID().uuidString,
            boundary: { false }, protection: { .plain })
        await #expect(throws: (any Error).self) { try await host.establishRecoveredCopy(from: source) }
        #expect(try await store.load(source.id)?.drawingData == source.drawingData)
        #expect(try await store.discover().count == 1)
    }
    @Test func failedCopyExplainsPossibleEmptyTargetWithoutClaimingDeletion() {
        let message = MobileSketchDraftRestorePolicy.copyFailureMessage(targetMayRemain: true, detail: "Recovery was interrupted.")
        #expect(message.contains("new empty note may have been left behind"))
        #expect(message.contains("after checking it"))
        #expect(message.contains("original recovery draft is unchanged"))
        #expect(!MobileSketchDraftRestorePolicy.copyFailureMessage(targetMayRemain: false, detail: "Unavailable").contains("empty note"))
    }

    @Test(arguments: [false, true]) func boundaryDuringSourceReleaseNeverPresentsAndKeepsBothDrafts(cancelTask: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MobileSketchDraftStore(root: root, libraryID: "fork-fixture")
        let owner = UUID(), bytes = PKDrawing().dataRepresentation()
        let source = MobileSketchDraftStore.Draft(generation: 1, originalNoteID: UUID().uuidString,
            drawingData: bytes, canvasSize: .init(width: 64, height: 64), state: .insertionUnconfirmed)
        try await store.checkpoint(source, protection: .plain)
        #expect(try await store.claim(source.id, owner: owner))
        let host = MobileSketchDraftHost(store: store, owner: owner, originalNoteID: UUID().uuidString,
            boundary: { true }, protection: { .plain })
        try await host.establishRecoveredCopy(from: source)
        let gate = MobileMediaOperationGate()
        let operationID = try #require(gate.begin())
        let operation = MobileNewSketchInsertion(gate: gate, operationID: operationID)
        #expect(operation.requestPresentation())
        let held = SketchSourceReleaseBarrier()
        var current = true, presented = false
        let handoff = Task {
            try await operation.finishRecoveryHandoff(host: host, releaseSource: {
                await held.hold()
                await store.release(source.id, owner: owner)
            }, isCurrent: { current })
            presented = true
        }
        for _ in 0..<1000 { if await held.entered { break }; await Task.yield() }
        try #require(await held.entered)
        if cancelTask { handoff.cancel() } else { current = false }
        await held.release()
        await #expect(throws: CancellationError.self) { try await handoff.value }
        #expect(!presented && operation.isInvalidated && !operation.hasModalLease)
        #expect(!gate.isCurrent(operationID))
        #expect(gate.begin() != nil)
        #expect(try await store.load(source.id)?.drawingData == bytes)
        #expect(try await store.load(host.id)?.drawingData == bytes)
        #expect(try await store.discover().count == 2)
    }

}
