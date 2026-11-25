// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// The fence (CK-R5) and the lifecycle of a send: crashes, quota, account switches, batches.
@Suite struct CloudPublisherLifecycleTests {
    static func quarantine(_ a: PublisherDevice, _ id: String, reason: String = "version:2") throws {
        try a.store.quarantine(record: CloudQuarantineRecord(recordName: "e.note.\(id)", reason: reason, v: 2, rawFields: Data("{}".utf8)), pinned: [])
    }

    // MARK: fence

    @Test func localEditWhileANewerUnsupportedRecordIsQuarantinedStaysDirtyAndIsNotSent() async throws {
        let (world, a, b, id) = try await CloudOutcomeResolverTests.synced(); defer { world.cleanup() }
        let sendsBefore = await a.gateway.sendLog.count
        try b.edit(id, "# T\nbase\nfrom B\n")
        try await b.publish()
        await world.account.injectUnsupportedVersion(record: "e.note.\(id)")      // a newer app wrote it
        try await a.fetch()
        #expect(try a.store.isFenced(entityType: "note", entityId: id))
        let pair = try #require(try a.store.pair(for: a.ref(id)))
        try a.edit(id, "# T\nbase\nfrom A\n")
        let raised = try #require(try a.dirtyGeneration(id))
        for _ in 0..<4 { try await a.publish() }
        #expect(try a.store.allInflight().isEmpty)                                // nothing prepared
        #expect(await a.gateway.sendLog.count == sendsBefore)                     // nothing submitted
        #expect(try a.store.pair(for: a.ref(id)) == pair)                         // nothing paired
        #expect(try a.dirtyGeneration(id) == raised && a.note(id)?.text == "# T\nbase\nfrom A\n")
    }

    @Test func afterTheQuarantineIsClearedTheEditIsPublishedOnTheRightBase() async throws {
        let (world, a, _, id) = try await CloudOutcomeResolverTests.synced(); defer { world.cleanup() }
        let pair = try #require(try a.store.pair(for: a.ref(id)))
        let sendsBefore = await a.gateway.sendLog.count
        try Self.quarantine(a, id)
        try a.edit(id, "# T\nbase\nedit\n")
        try await a.publish()
        #expect(await a.gateway.sendLog.count == sendsBefore)
        try a.store.releaseQuarantine(recordName: "e.note.\(id)")
        let report = try await a.publish()
        #expect(report.saved == 1)
        let log = Array(await a.gateway.sendLog.dropFirst(sendsBefore))
        #expect(log.count == 1 && log[0].hadSystemFields && !log[0].usedOfferedTag)
        let record = try #require(await world.account.record(named: "e.note.\(id)"))
        #expect(record.ver == pair.ver + 1 && record.sids.dropFirst() == ArraySlice(pair.sids))   // the chain of the base it was built on
        #expect(try a.dirtyCount() == 0)
    }

    @Test func fenceDoesNotBlockOtherEntities() async throws {
        let (world, a, _, id) = try await CloudOutcomeResolverTests.synced(); defer { world.cleanup() }
        let other = try a.noteStore.create(text: "# Other\n")
        try Self.quarantine(a, id)
        try a.edit(id, "# T\nbase\nedit\n")
        let report = try await a.publish()
        #expect(report.saved == 1)
        #expect(await world.account.record(named: "e.note.\(other.id)") != nil)
        #expect(await world.account.record(named: "e.note.\(id)")?.ver == 1)
        #expect(try a.dirtyGeneration(id) != nil)
    }

    @Test func fencedEntityResumesAfterIgnoreItIsConfirmed() async throws {
        let (world, a, _, id) = try await CloudOutcomeResolverTests.synced(); defer { world.cleanup() }
        let sendsBefore = await a.gateway.sendLog.count
        try Self.quarantine(a, id)
        try a.edit(id, "# T\nbase\nedit\n")
        try await a.publish()
        #expect(await a.gateway.sendLog.count == sendsBefore)
        try a.store.ignoreQuarantine(recordName: "e.note.\(id)")
        try await a.publish()
        #expect(await world.account.record(named: "e.note.\(id)")?.ver == 2)
    }

    @Test func aFenceThatAppearsBetweenPrepareAndSubmitStopsTheSend() async throws {
        let (world, a, _, id) = try await CloudOutcomeResolverTests.synced(); defer { world.cleanup() }
        try a.edit(id, "# T\nbase\nedit\n")
        let sendsBefore = await a.gateway.sendLog.count
        #expect(try await a.publisher.prepare().count == 1)
        try Self.quarantine(a, id)
        let report = try await a.publisher.submit()
        #expect(report.submitted == 0 && report.blocked == [a.ref(id)])
        #expect(try a.store.inflight(for: a.ref(id))?.state == .prepared)
        #expect(await a.gateway.sendLog.count == sendsBefore)
        try a.store.releaseQuarantine(recordName: "e.note.\(id)")
        #expect(try await a.publisher.submit().submitted == 1)
    }

    @Test func aSaveThatLandsForAFencedEntityNeverMovesThePair() async throws {
        let (world, a, _, id) = try await CloudOutcomeResolverTests.synced(); defer { world.cleanup() }
        let pair = try #require(try a.store.pair(for: a.ref(id)))
        await a.gateway.setAutoSend(false)
        try a.edit(id, "# T\nbase\nedit\n")
        try await a.publish()
        try Self.quarantine(a, id)                                                 // a newer unreadable version shows up meanwhile
        try await a.gateway.sendPending()                                         // the save lands
        try a.publisher.consumeResults()
        #expect(try a.store.pair(for: a.ref(id)) == pair)
        #expect(try a.store.inflight(for: a.ref(id))?.state == .unknown)
        try a.store.releaseQuarantine(recordName: "e.note.\(id)")
        let report = try await a.publish()                                       // the outcome table: it is ours
        #expect(report.saved == 1)
        #expect(try a.store.pair(for: a.ref(id))?.ver == pair.ver + 1 && a.dirtyCount() == 0)
        #expect(await world.account.versionCount(of: "e.note.\(id)") == 2)
    }

    // MARK: crashes

    static let boundaries = ["publisher.afterPrepare", "publisher.afterSending", "publisher.afterSubmit", "afterSend",
                             "publisher.afterResultStored", "publisher.afterRecordSaved"]

    @Test(arguments: boundaries, [false, true])
    func crashAtEveryPublisherBoundary(boundary: String, existing: Bool) async throws {
        let crash = CrashPoint()
        let world = try await PublisherWorld.make(1, crash: crash); defer { world.cleanup() }
        let a = world.devices[0]
        let note = try a.noteStore.create(text: "# Crash\none\n")
        if existing { try await a.publish(); try a.edit(note.id, "# Crash\ntwo\n") }
        crash.arm(boundary)
        do { try await a.publish(); Issue.record("\(boundary) was not reached") } catch let injected as CrashInjected {
            #expect(injected.boundary == boundary)
        }
        // A new process: same library, same durable device queue, nothing in memory.
        a.restart(crash: crash)
        try a.publisher.treatSendingAsUnknown()
        try await a.gateway.sendPending()
        try await a.sync()
        let expectedText = existing ? "# Crash\ntwo\n" : "# Crash\none\n"
        let name = "e.note.\(note.id)"
        let record = try #require(await world.account.record(named: name))
        #expect(record.ver == (existing ? 2 : 1))
        #expect(await world.account.versionCount(of: name) == (existing ? 2 : 1))   // landed once, never twice
        #expect(try CloudPublisherTests.text(a.sealer, record, id: note.id) == expectedText)
        let pair = try #require(try a.store.pair(for: a.ref(note.id)))
        #expect(pair.ver == record.ver && pair.systemFields == record.systemFields && pair.sids == record.sids)
        #expect(try a.store.allInflight().isEmpty && a.dirtyCount() == 0)
        #expect(try a.rowCount("ck_send_result") == 0)
    }

    // MARK: quota, account, batches

    @Test func quotaFullKeepsInflightPreparedAndResumable() async throws {
        let world = try await PublisherWorld.make(1); defer { world.cleanup() }
        let a = world.devices[0]
        await world.account.setQuota(bytes: 1)
        let note = try a.noteStore.create(text: "# Quota\nbody\n")
        let first = try await a.publish()
        #expect(first.saved == 0 && first.requeued == 1)
        let held = try #require(try a.store.inflight(for: a.ref(note.id)))
        #expect(held.state == .prepared)
        for _ in 0..<2 { try await a.publish() }
        let stillHeld = try #require(try a.store.inflight(for: a.ref(note.id)))
        #expect(stillHeld.sealed == held.sealed && stillHeld.attemptId == held.attemptId && stillHeld.generation == held.generation)
        #expect(try a.dirtyGeneration(note.id) != nil)
        await world.account.setQuota(bytes: nil)                                  // the person freed some iCloud space
        let resumed = try await a.publish()
        #expect(resumed.saved == 1)
        #expect(await world.account.record(named: "e.note.\(note.id)")?.sid == held.attemptId)   // the same snapshot goes out
    }

    @Test func lateCompletionAfterAccountSwitchIsDiscardedByGeneration() async throws {
        let world = try await PublisherWorld.make(1); defer { world.cleanup() }
        let a = world.devices[0]
        let other = FakeCloudKitAccount(user: "someone-else")
        let note = try a.noteStore.create(text: "# Switch\n")
        await a.gateway.completeLateAfterCancel()
        try await a.publish()                                                     // still on the wire
        let inflight = try #require(try a.store.inflight(for: a.ref(note.id)))
        let generation = try a.store.generation()
        await a.gateway.switchAccount(to: other)                                   // the account changes
        #expect(try a.store.generation() > generation)
        await a.gateway.deliverLateCompletions()                                   // the old save completes after all
        // CK-R171: the store refuses the result of an older generation, so nothing is recorded for the late completion at all
        #expect(try a.store.sendResult(attemptId: inflight.attemptId) == nil)
        try a.publisher.treatSendingAsUnknown()
        let report = try a.publisher.consumeResults()
        #expect(report.saved == 0)
        #expect(try a.store.sendResult(attemptId: inflight.attemptId) == nil)
        #expect(try a.store.pair(for: a.ref(note.id)) == nil)                       // nothing recorded
        #expect(try a.dirtyGeneration(note.id) != nil)                               // nothing cleared
        #expect(try a.store.inflight(for: a.ref(note.id))?.sealed == inflight.sealed)   // the snapshot waits for its account
        for _ in 0..<3 { try await a.publish() }
        #expect(await other.recordNames.isEmpty)                                    // never resolved or written into the new account
        #expect(await world.account.record(named: "e.note.\(note.id)") != nil)      // the late save did land in the original one
    }

    @Test func independentRecordsInABatchDoNotFailTogether() async throws {
        let (world, a, b, id) = try await CloudOutcomeResolverTests.synced(); defer { world.cleanup() }
        try b.edit(id, "# T\nbase\nB\n")
        try await b.publish()
        let two = try a.noteStore.create(text: "# Two\n"), three = try a.noteStore.create(text: "# Three\n")
        try a.edit(id, "# T\nbase\nA\n")                                           // stale: the cloud has B's version
        let report = try await a.publish()
        #expect(report.submitted == 3 && report.saved == 2 && report.needsMerge == [a.ref(id)])
        #expect(await world.account.record(named: "e.note.\(two.id)") != nil)
        #expect(await world.account.record(named: "e.note.\(three.id)") != nil)
        let operations = await a.gateway.operationLog
        #expect(operations.contains("send:3:ok"))                                  // one batch of three
    }

    @Test func aRecordThatDoesNotFitDoesNotStopTheOnesThatDo() async throws {
        let world = try await PublisherWorld.make(1); defer { world.cleanup() }
        let a = world.devices[0]
        let seed = try a.noteStore.create(text: "# Seed\n")
        try await a.publish()
        let used = await world.account.usedBytes
        await world.account.setQuota(bytes: used + 3_000)
        var generator = SystemRandomNumberGenerator()
        let big = "# Big\n" + (0..<4_000).map { _ in String((0..<80).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement(using: &generator)! }) + "\n" }.joined()
        let large = try a.noteStore.create(text: big)
        let small = try a.noteStore.create(text: "# Small\n")
        let report = try await a.publish()
        #expect(report.saved == 1 && report.requeued == 1)
        #expect(await world.account.record(named: "e.note.\(small.id)") != nil)
        #expect(await world.account.record(named: "e.note.\(large.id)") == nil)
        #expect(try a.store.inflight(for: a.ref(large.id))?.state == .prepared)
        _ = seed
    }
}
