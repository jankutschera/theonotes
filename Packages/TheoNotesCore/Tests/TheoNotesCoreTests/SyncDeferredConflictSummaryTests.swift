// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

@Suite struct SyncDeferredConflictSummaryTests {
    actor Coordinator: SyncCommitCoordinator {
        var remainingDeferrals: Int
        init(_ count: Int) { remainingDeferrals = count }
        func allowCommits() { remainingDeferrals = 0 }
        func commit(_ change: @Sendable () throws -> SyncApplyResult) async throws -> SyncApplyResult {
            if remainingDeferrals > 0 {
                remainingDeferrals -= 1
                return .waitingForDependencies
            }
            return try change()
        }
    }

    actor Transport: SyncTransport {
        let server = SyncEngineTests.Server()
        var attempts: [String] = []
        func seed(_ entity: SyncEntity) async throws { _ = try await server.push([entity.mutation]) }
        func push(_ mutations: [SyncMutation]) async throws -> SyncPushResult {
            attempts += mutations.map(\.mutationId)
            return try await server.push(mutations)
        }
        func pull(after cursor: Int64) async throws -> SyncPullResult { try await server.pull(after: cursor) }
        func acknowledge(_ cursor: Int64) async throws { try await server.acknowledge(cursor) }
        func attemptCount(_ id: String) -> Int { attempts.filter { $0 == id }.count }
    }

    @Test func repeatedConflictAcrossBothUploadPassesCountsOnceThenClearsAfterRecovery() async throws {
        let library = try SyncMaterializerTests.Library(); defer { library.cleanup() }
        let note = try library.store.create(text: "Local edit")
        let pending = try #require(try library.queue.prepareNext(vaultKey: library.key))
        let transport = Transport(), coordinator = Coordinator(.max)
        try await transport.seed(library.entity(library.payload("Remote edit", id: note.id), id: note.id))
        let engine = SyncEngine(database: library.db, paths: library.paths, accountID: "account", vaultKey: library.key,
                                transport: transport, blobs: SyncPayloadReaderTests.Blobs(), coordinator: coordinator)
        let blocked = try await engine.synchronize()
        #expect(await transport.attemptCount(pending.mutationId) == 2)
        #expect(blocked.deferredConflicts == 1)
        #expect(try library.queue.pendingMutations().contains { $0.mutationId == pending.mutationId })
        await coordinator.allowCommits()
        let recovered = try await engine.synchronize()
        #expect(recovered.deferredConflicts == 0)
        #expect(recovered.pendingUploads == 0 && recovered.pendingDownloads == 0)
        await engine.shutdown()
    }

    @Test func conflictResolvedInSecondUploadPassIsAbsentFromFinalSummary() async throws {
        let library = try SyncMaterializerTests.Library(); defer { library.cleanup() }
        let note = try library.store.create(text: "Local edit")
        let pending = try #require(try library.queue.prepareNext(vaultKey: library.key))
        let transport = Transport(), coordinator = Coordinator(2)
        try await transport.seed(library.entity(library.payload("Remote edit", id: note.id), id: note.id))
        let engine = SyncEngine(database: library.db, paths: library.paths, accountID: "account", vaultKey: library.key,
                                transport: transport, blobs: SyncPayloadReaderTests.Blobs(), coordinator: coordinator)
        let resolved = try await engine.synchronize()
        #expect(await transport.attemptCount(pending.mutationId) == 2)
        #expect(resolved.deferredConflicts == 0)
        #expect(resolved.pendingUploads == 0 && resolved.pendingDownloads == 0)
        await engine.shutdown()
    }
}
