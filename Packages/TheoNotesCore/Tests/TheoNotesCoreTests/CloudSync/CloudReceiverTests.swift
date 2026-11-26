// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// Ordering and state safety of the receiver's sink: the latest valid version per record name, never a regression,
/// echoes are no-ops, divergent content is quarantined, and the engine state is never ahead of the data.
@Suite struct CloudReceiverTests {
    @Test(arguments: [[5, 3], [3, 5], [5, 3, 4]] as [[Int64]])
    func versionsDeliveredOutOfOrderNeverRegress(order: [Int64]) throws {
        let d = try PublisherDevice("order", account: nil); defer { d.cleanup() }
        for ver in order { _ = try d.sink.intake(Rec.entity("n1", ver), delivery: .incremental) }
        #expect(try d.remoteVersions() == ["e.note.n1": 5])
        // Against a base pair that already holds version 5 nothing older is ever stored.
        let applied = try PublisherDevice("order2", account: nil); defer { applied.cleanup() }
        try applied.adopt(Rec.entity("n1", 5))
        for ver in order where ver < 5 { #expect(try applied.sink.intake(Rec.entity("n1", ver), delivery: .incremental) == .ignoredStale) }
        #expect(try applied.remoteVersions().isEmpty)
    }

    @Test func staleVersionAfterNewerIsIgnored() throws {
        let d = try PublisherDevice("stale", account: nil); defer { d.cleanup() }
        #expect(try d.sink.intake(Rec.entity("n1", 4), delivery: .incremental) == .stored)
        #expect(try d.sink.intake(Rec.entity("n1", 2), delivery: .incremental) == .ignoredStale)
        #expect(try d.store.remote(recordName: "e.note.n1")?.sid == "sid-4")
    }

    @Test func echoOfOwnSaveIsANoOp() async throws {
        let world = try await PublisherWorld.make(1); defer { world.cleanup() }
        let a = world.devices[0]
        let note = try a.noteStore.create(text: "# Echo\nbody\n")
        try await a.sync()
        let name = "e.note.\(note.id)"
        let before = await world.account.versionCount(of: name)
        try await a.fetch()                                    // the own save comes back
        #expect(try a.rowCount("ck_remote") == 0)
        #expect(try await a.applyNotes() == 0)
        try await a.sync()
        #expect(try a.dirtyCount() == 0)
        #expect(await world.account.versionCount(of: name) == before, "an echo must not cause another save")
    }

    @Test func divergentEqualVerIsQuarantined() throws {
        let d = try PublisherDevice("divergent", account: nil); defer { d.cleanup() }
        #expect(try d.sink.intake(Rec.entity("n1", 2, sid: "sid-a", payload: Data([1])), delivery: .incremental) == .stored)
        #expect(try d.sink.intake(Rec.entity("n1", 2, sid: "sid-b", payload: Data([2])), delivery: .incremental) == .quarantined)
        #expect(try d.store.isFenced(entityType: "note", entityId: "n1"))
        // Against an applied pair, the same version with another payload is divergent too.
        let applied = try PublisherDevice("divergent2", account: nil); defer { applied.cleanup() }
        try applied.adopt(Rec.entity("n1", 2, payload: Data([1])))
        #expect(try applied.sink.intake(Rec.entity("n1", 2, payload: Data([7])), delivery: .incremental) == .quarantined)
    }

    @Test func crashBetweenCommitAndStateSaveRefetchesIdempotently() async throws {
        let crash = CrashPoint()
        let account = FakeCloudKitAccount()
        let a = try PublisherDevice("a", account: account), b = try PublisherDevice("b", account: account, crash: crash)
        defer { a.cleanup(); b.cleanup() }
        try await a.prepareGateway(); try await b.prepareGateway()
        let ids = try (0..<3).map { try a.noteStore.create(text: "# N\($0)\nx\n").id }
        try await a.sync()
        crash.arm("sink.beforeStateSave")
        await #expect(throws: CrashInjected.self) { try await b.fetch() }
        #expect(try b.store.engineState() == nil, "the commit happened, the state did not")
        #expect(try b.rowCount("ck_remote") == 3)
        try await b.fetch()                                     // redelivered: echoes of what is already stored
        #expect(try b.rowCount("ck_remote") == 3)
        #expect(try b.store.engineState() != nil)
        #expect(try await b.applyNotes() == 3)
        #expect(Set(try b.notes().map(\.id)) == Set(ids))
    }

    @Test func stateIsNeverSavedWhenACommitThrew() async throws {
        let crash = CrashPoint()
        let account = FakeCloudKitAccount()
        let a = try PublisherDevice("a", account: account), b = try PublisherDevice("b", account: account, crash: crash)
        defer { a.cleanup(); b.cleanup() }
        try await a.prepareGateway(); try await b.prepareGateway()
        _ = try a.noteStore.create(text: "# One\nx\n")
        try await a.sync()
        crash.arm("sink.afterRecord")
        await #expect(throws: CrashInjected.self) { try await b.fetch() }
        #expect(try b.store.engineState() == nil)
        // Even a caller that asks directly is refused until a commit succeeded.
        #expect(throws: CloudSinkError.stateWithheld) { try b.sink.saveEngineState(Data([1])) }
        #expect(try b.store.engineState() == nil)
        try await b.fetch()
        #expect(try b.store.engineState() != nil)
    }

    @Test func engineStateNeverAheadOfData() async throws {
        let crash = CrashPoint()
        let account = FakeCloudKitAccount()
        let a = try PublisherDevice("a", account: account), b = try PublisherDevice("b", account: account, crash: crash)
        defer { a.cleanup(); b.cleanup() }
        try await a.prepareGateway(); try await b.prepareGateway()
        try await b.fetch()                                     // a first (full) fetch of the empty zone: the state is saved
        let initial = try #require(try b.store.engineState())
        let ids = try (0..<3).map { try a.noteStore.create(text: "# N\($0)\nx\n").id }
        try await a.sync()
        await b.gateway.setFetchBatchSize(1)
        // The third batch never reaches the data: its state must not have been saved either.
        crash.arm("sink.beforeRecord", afterHits: 2)
        await #expect(throws: CrashInjected.self) { try await b.fetch() }
        #expect(try b.rowCount("ck_remote") == 2)
        let partial = try #require(try b.store.engineState())
        #expect(partial != initial, "the states after the two stored batches were saved")
        try await b.fetch()
        #expect(try b.rowCount("ck_remote") == 3, "the saved state did not skip the record that never reached the data")
        #expect(Set(try b.store.allRemote().map(\.entity.entityId)) == Set(ids))
    }

    @Test func aFetchBatchDeliveredAfterAnAccountChangeStoresAndAppliesNothing() async throws {
        let d = try PublisherDevice("fence", account: nil); defer { d.cleanup() }
        let started = try d.store.generation()
        let late = CloudFeedSink(store: d.store, pinner: CloudAssetPinner(directory: d.paths.cloudPinned), generation: { started })
        try d.store.bumpGeneration()                                     // the account changed while the fetch was running
        #expect(throws: CloudSyncStoreError.self) { try late.commit(changed: [Rec.entity("n1", 1)], deletedNames: []) }
        let lateState = CloudFeedSink(store: d.store, pinner: CloudAssetPinner(directory: d.paths.cloudPinned), generation: { started })
        #expect(throws: CloudSyncStoreError.self) { try lateState.saveEngineState(Data([1])) }
        #expect(try d.rowCount("ck_remote") == 0 && d.store.engineState() == nil)
        // The durable fence refuses a write of the current generation too.
        let current = CloudFeedSink(store: d.store, pinner: CloudAssetPinner(directory: d.paths.cloudPinned))
        try d.store.setAccountFenced(true)
        #expect(throws: CloudSyncStoreError.accountFenced) { try current.commit(changed: [Rec.entity("n1", 1)], deletedNames: []) }
        #expect(try d.rowCount("ck_remote") == 0)
        // A reconciler run that started before the change applies nothing.
        try d.store.setAccountFenced(false)
        _ = try current.intake(Rec.entity("n2", 1), delivery: .incremental)
        let stale = CloudReconciler(database: d.db, paths: d.paths, store: d.store, accountID: d.accountID, vaultKey: d.key,
                                    pinner: CloudAssetPinner(directory: d.paths.cloudPinned), generation: { started })
        await #expect(throws: (any Error).self) { try await stale.applyPending() }
        #expect(try d.notes().isEmpty)
    }
}
