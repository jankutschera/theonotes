// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import BaerchenIOS

@Suite @MainActor struct MobileNewSketchInsertionTests {
    private func fixture() throws -> (MobileMediaOperationGate, MobileNewSketchInsertion) {
        let gate = MobileMediaOperationGate()
        return (gate, MobileNewSketchInsertion(gate: gate, operationID: try #require(gate.begin())))
    }
    private func waitForStart(_ held: HeldSketchWork) async throws {
        for _ in 0..<1000 { if await held.started { return }; await Task.yield() }
        Issue.record("Held production pipeline did not reach its asynchronous boundary")
        throw CancellationError()
    }
    @Test func cancelledPendingOriginCannotReopenAfterReactivationOrClaimAnotherOperation() async throws {
        let (gate, operation) = try fixture(), held = HeldSketchWork()
        let capture = Task { try await operation.captureOrigin { await held.run() } }
        try await waitForStart(held)
        operation.cancel() // inactive before the origin reply
        let newer = try #require(gate.begin()) // active again
        await held.release()
        await #expect(throws: CancellationError.self) { _ = try await capture.value }
        #expect(!operation.requestPresentation())
        #expect(gate.isCurrent(newer))
    }
    @Test func cancellationFencesLateEncodingButKeepsModalLeaseUntilNativeDismissal() async throws {
        let (gate, operation) = try fixture(), held = HeldSketchWork()
        #expect(operation.requestPresentation())
        var inserted = 0
        let save = Task {
            try await operation.save(prepare: { await held.run() }, canInsert: { true }, insert: { _ in inserted += 1 })
        }
        try await waitForStart(held)
        operation.cancel() // also used synchronously by background/privacy hooks
        #expect(operation.hasModalLease && gate.begin() == nil)
        await held.release() // encoder deliberately ignores cancellation
        await #expect(throws: CancellationError.self) { try await save.value }
        #expect(inserted == 0 && operation.hasModalLease)
        #expect(operation.didDismiss())
        let newer = try #require(gate.begin())
        #expect(!operation.didDismiss())
        #expect(gate.isCurrent(newer))
    }
    @Test func preWriteFailureKeepsDraftOperationRetryableAndSuccessWaitsForDismissal() async throws {
        let (gate, operation) = try fixture()
        #expect(operation.requestPresentation())
        var inserted: [Data] = []
        await #expect(throws: CocoaError.self) {
            try await operation.save(prepare: { throw CocoaError(.fileWriteNoPermission) }, canInsert: { true }, insert: { inserted.append($0) })
        }
        #expect(inserted.isEmpty && operation.canPresent && !operation.isSaving && !operation.insertionUnconfirmed)
        let exactDraftBytes = Data("same retained draft".utf8)
        try await operation.save(prepare: { exactDraftBytes }, canInsert: { true }, insert: { inserted.append($0) })
        #expect(inserted == [exactDraftBytes] && operation.isFinished)
        #expect(operation.hasModalLease && gate.begin() == nil)
        #expect(operation.didDismiss() && gate.begin() != nil)
    }
    @Test func unknownWriterOutcomeKeepsDraftAndRejectsBlindRetry() async throws {
        let (_, operation) = try fixture()
        #expect(operation.requestPresentation())
        var writes = 0
        await #expect(throws: MobileNewSketchInsertion.Failure.self) {
            try await operation.save(prepare: { Data([1]) }, canInsert: { true }, insert: { _ in
                writes += 1
                throw CocoaError(.fileWriteUnknown) // models a throw after a possible write/uncertain bridge ACK
            })
        }
        #expect(operation.insertionUnconfirmed && !operation.isFinished && operation.hasModalLease)
        await #expect(throws: MobileNewSketchInsertion.Failure.self) {
            try await operation.save(prepare: { Data([1]) }, canInsert: { true }, insert: { _ in writes += 1 })
        }
        #expect(writes == 1 && operation.hasModalLease)
        operation.cancel()
        #expect(operation.hasModalLease) // user explicitly cancelled, native animation still owns the modal
        #expect(operation.didDismiss())
    }
    @Test func selectionOrPrivacyRecheckRejectsPreparedBytesBeforeWriter() async throws {
        let (_, operation) = try fixture()
        #expect(operation.requestPresentation())
        var writes = 0
        await #expect(throws: CancellationError.self) {
            try await operation.save(prepare: { Data([1]) }, canInsert: { false }, insert: { _ in writes += 1 })
        }
        #expect(writes == 0 && !operation.insertionUnconfirmed)
    }
}

private actor HeldSketchWork {
    private var continuation: CheckedContinuation<Data, Never>?
    var started: Bool { continuation != nil }
    func run() async -> Data { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(returning: Data([1])); continuation = nil }
}
