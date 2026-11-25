// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// Review 2, Critical 1 (invariant I1): a save is built only from a base pair; a change tag found in a fetch is never
/// used to retry a send.
@Suite struct CloudStaleParentTests {
    /// A and B hold version 1 (tag t1). B publishes version 2 (tag t2). A has not fetched it. The fake hands out t2.
    static func staleA() async throws -> (PublisherWorld, PublisherDevice, PublisherDevice, String, offered: Data) {
        let (world, a, b, id) = try await CloudOutcomeResolverTests.synced()
        try b.edit(id, "# T\nbase\nB was here\n")
        try await b.publish()
        let offered = try #require(await a.gateway.offerFreshTag(for: "e.note.\(id)"))
        return (world, a, b, id, offered)
    }

    @Test func staleParentNeverOverwritesANewerRecord() async throws {
        let (world, a, b, id, offered) = try await Self.staleA(); defer { world.cleanup() }
        let t1 = try #require(try a.store.pair(for: a.ref(id))).systemFields
        #expect(t1 != offered)
        let sendsBefore = await a.gateway.sendLog.count
        try a.edit(id, "# T\nbase\nA was here\n")
        let first = try await a.publish()                                          // sent on t1: the cloud says it changed
        #expect(first.submitted == 1 && first.needsMerge == [a.ref(id)])
        // The trap is open for as long as A likes: A must not send again with the offered tag, with t1, or at all.
        for _ in 0..<4 { try await a.publish() }
        var log = Array(await a.gateway.sendLog.dropFirst(sendsBefore))
        #expect(log.count == 1 && log[0].hadSystemFields && !log[0].usedOfferedTag)
        #expect(try a.store.pair(for: a.ref(id))?.systemFields == t1)             // the pair did not move on a stale answer
        // The merge is what moves it: A merges against the ancestor it held and only then builds the next snapshot.
        let remote = try #require(try a.store.remote(recordName: "e.note.\(id)"))
        try await a.applyNotes()
        let afterMerge = try #require(try a.store.pair(for: a.ref(id)))
        #expect(afterMerge.ver == 2 && afterMerge.ancestor == remote.sealed)
        try a.publisher.consumeResults()
        let made = try await a.publisher.prepare()
        let next = try #require(made.first { $0.entity == a.ref(id) })     // a conflict copy, if any, is a new entity of its own
        #expect(next.baseAncestor == remote.sealed && next.baseVer == 2)           // the ancestor of the tag it will send
        _ = try await a.publisher.submit()
        log = Array(await a.gateway.sendLog.dropFirst(sendsBefore))
        #expect(log.count == 1 + made.count)                                     // the stale send, then the merged entities
        // The final record carries both edits (A merged B's), at version 3, with A's chain on top of B's.
        let record = try #require(await world.account.record(named: "e.note.\(id)"))
        #expect(record.ver == 3 && record.sids.count == 3)
        try await a.sync(); try await b.sync(); try await a.sync()
        let union = try a.notes().map(\.text).joined(separator: "\n")
        #expect(union.contains("A was here") && union.contains("B was here"))      // no edit lost
        #expect(try a.notes().map(\.text).sorted() == b.notes().map(\.text).sorted())
    }

    @Test func serverRecordChangedStoresTheServerVersionAndDoesNotResend() async throws {
        let (world, a, _, id, _) = try await Self.staleA(); defer { world.cleanup() }
        let pairBefore = try #require(try a.store.pair(for: a.ref(id)))
        let sendsBefore = await a.gateway.sendLog.count
        try a.edit(id, "# T\nbase\nA was here\n")
        let report = try await a.publish()
        #expect(report.needsMerge == [a.ref(id)] && report.saved == 0)
        let stored = try #require(try a.store.remote(recordName: "e.note.\(id)"))
        let server = try #require(await world.account.record(named: "e.note.\(id)"))
        #expect(stored.ver == 2 && stored.sid == server.sid && stored.systemFields == server.systemFields)
        #expect(try a.store.pair(for: a.ref(id)) == pairBefore)                    // unchanged until the merge
        #expect(try a.store.inflight(for: a.ref(id))?.state == .unknown)          // kept until the receiver merged
        #expect(try a.dirtyGeneration(id) != nil)
        #expect(await a.gateway.sendLog.count == sendsBefore + 1)
    }

    @Test func noCodePathReadsAChangeTagFromAFetchForSending() throws {
        // Structural: the only place a record gets system fields is the base the snapshot was built on.
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/TheoNotesCore/CloudSync")
        let publisher = try String(contentsOf: sources.appendingPathComponent("CloudPublisher.swift"), encoding: .utf8)
        let assignments = publisher.components(separatedBy: "\n").filter { $0.contains(".systemFields =") || $0.contains("systemFields:") && $0.contains("CloudSave") }
        #expect(assignments.count == 1)
        #expect(assignments.first?.trimmingCharacters(in: .whitespaces) == "record.systemFields = attempt.baseSystemFields")
        // A `CloudSave` is built from exactly one place, from the rows of `ck_inflight`.
        #expect(publisher.components(separatedBy: "CloudSave(").count - 1 == 1)
        // The resolver and the intake never produce a `CloudSave`.
        for file in ["CloudOutcomeResolver.swift", "CloudRemoteIntake.swift"] {
            #expect(try !String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8).contains("CloudSave("))
        }
    }

    @Test func aFetchedVersionWaitingForTheMergeBlocksANewSnapshot() async throws {
        let (world, a, _, id, _) = try await Self.staleA(); defer { world.cleanup() }
        let sendsBefore = await a.gateway.sendLog.count
        try a.edit(id, "# T\nbase\nA was here\n")
        try await a.fetch()                                                         // B's version 2 is stored, not merged
        #expect(try a.store.hasPendingRemote(a.ref(id)))
        for _ in 0..<3 { try await a.publish() }
        #expect(try a.store.allInflight().isEmpty)                                  // no snapshot on the stale base
        #expect(await a.gateway.sendLog.count == sendsBefore)
        try await a.applyNotes()
        try await a.sync()
        #expect(await world.account.record(named: "e.note.\(id)")?.ver ?? 0 >= 3)
    }

    @Test func aTagFoundByAFetchWhileResolvingBecomesAFetchedVersionNeverABase() async throws {
        let (world, a, _, id, offered) = try await Self.staleA(); defer { world.cleanup() }
        let t1 = try #require(try a.store.pair(for: a.ref(id))).systemFields
        try a.edit(id, "# T\nbase\nA was here\n")
        await a.gateway.failNext(.offline)                                         // outcome unknown: the resolver fetches by name
        try await a.publish()
        for _ in 0..<4 { try await a.publish() }
        let log = await a.gateway.sendLog
        #expect(log.allSatisfy { !$0.usedOfferedTag })
        #expect(try a.store.pair(for: a.ref(id))?.systemFields == t1)
        #expect(try a.store.remote(recordName: "e.note.\(id)")?.systemFields == offered)   // stored as a fetched version only
    }
}
