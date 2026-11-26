// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// One test per row of the unknown-outcome table, run against the fake cloud and the real store and publisher.
@Suite struct CloudOutcomeResolverTests {
    /// Device A has published a note; device B has fetched and merged it, so both hold a base pair at version 1.
    static func synced(devices count: Int = 2, text: String = "# T\nbase\n") async throws -> (world: PublisherWorld, a: PublisherDevice, b: PublisherDevice, id: String) {
        let world = try await PublisherWorld.make(count)
        let a = world.devices[0], b = world.devices[1]
        let note = try a.noteStore.create(text: text)
        try await a.publish()
        try await b.sync()
        #expect(try b.note(note.id)?.text == text)
        return (world, a, b, note.id)
    }

    // MARK: row 3

    @Test func lostResponseSaveLandedSidMatches() async throws {
        let world = try await PublisherWorld.make(1); defer { world.cleanup() }
        let a = world.devices[0]
        let note = try a.noteStore.create(text: "# Lost\n")
        await a.gateway.loseNextResponseAfterCommit()
        let first = try await a.publish()
        #expect(first.submitted == 1 && first.saved == 0)
        let inflight = try #require(try a.store.inflight(for: a.ref(note.id)))
        #expect(inflight.state == .unknown)
        let second = try await a.publish()
        #expect(second.saved == 1)
        let record = try #require(await world.account.record(named: "e.note.\(note.id)"))
        let pair = try #require(try a.store.pair(for: a.ref(note.id)))
        #expect(pair.ver == 1 && pair.systemFields == record.systemFields && pair.ancestor == inflight.sealed && pair.sids == inflight.sids)
        #expect(await world.account.versionCount(of: record.name) == 1)      // never saved twice
        #expect(await a.gateway.sendLog.count == 1)
        #expect(try a.dirtyCount() == 0 && a.store.allInflight().isEmpty)
    }

    @Test func aSilentLossIsTreatedAsUnknownAtTheNextStartAndResolvesTheSame() async throws {
        let world = try await PublisherWorld.make(1); defer { world.cleanup() }
        let a = world.devices[0]
        let note = try a.noteStore.create(text: "# Silent\n")
        await a.gateway.loseNextResponseAfterCommit(report: .silence)
        try await a.publish()
        #expect(try a.store.inflight(for: a.ref(note.id))?.state == .sending)
        #expect(try a.store.sendResult(attemptId: a.store.allInflight()[0].attemptId) == nil)
        #expect(try a.publisher.treatSendingAsUnknown() == 1)
        let report = try await a.publish()
        #expect(report.saved == 1 && report.submitted == 0)
        #expect(await world.account.versionCount(of: "e.note.\(note.id)") == 1)
    }

    // MARK: row 4

    @Test func lostResponseThenOtherDeviceEditedSidsChainProvesAncestor() async throws {
        let (world, a, b, id) = try await Self.synced(); defer { world.cleanup() }
        try a.edit(id, "# T\nbase\nfrom A\n")
        await a.gateway.loseNextResponseAfterCommit()
        try await a.publish()                                        // landed as version 2, A does not know
        try await b.sync()                                           // B merges version 2 (its pair now carries A's attempt id)
        try b.edit(id, "# T\nbase\nfrom B\n")                        // overlaps A's line, based on A's version
        try await b.publish()                                        // version 3
        let attempt = try #require(try a.store.inflight(for: a.ref(id)))
        let report = try await a.publish()                           // resolve: row 4
        #expect(report.needsMerge == [a.ref(id)])
        let remote = try #require(try a.store.remote(recordName: "e.note.\(id)"))
        #expect(remote.ver == 3 && remote.sids.contains(attempt.attemptId) && remote.sid != attempt.attemptId)
        #expect(CloudOutcomeResolver.mergeBase(attempt: attempt, remote: remote) == attempt.sealed)    // the exact ancestor
        try await a.applyNotes()
        // With the exact ancestor B's edit applies cleanly: no conflict copy, B's text, nothing republished.
        #expect(try a.notes().count == 1 && a.note(id)?.text == "# T\nbase\nfrom B\n")
        #expect(try a.store.pair(for: a.ref(id))?.ver == 3 && a.store.allInflight().isEmpty && a.dirtyCount() == 0)
        try await a.sync(); try await b.sync()
        #expect(try a.note(id)?.text == b.note(id)?.text)
    }

    // MARK: row 6

    /// B made more than 8 writes after A's landed save, so A's attempt id left the chain: no evidence either way.
    private static func lostThenManyLaterWrites(overlapping: Bool) async throws -> (PublisherWorld, PublisherDevice, PublisherDevice, String, CloudInflight) {
        let (world, a, b, id) = try await Self.synced()
        try a.edit(id, "# T\nbase\nfrom A\n")
        await a.gateway.loseNextResponseAfterCommit()
        try await a.publish()
        try await b.sync()
        for n in 1...9 {
            try b.edit(id, overlapping ? "# T\nbase\nfrom B\(n)\n" : "# T\nbase\nfrom A\nB line \(n)\n")
            try await b.publish()
        }
        let attempt = try #require(try a.store.inflight(for: a.ref(id)))
        return (world, a, b, id, attempt)
    }

    @Test func lostResponseThenMoreThanEightLaterWritesMergesConservatively() async throws {
        let (world, a, b, id, attempt) = try await Self.lostThenManyLaterWrites(overlapping: false); defer { world.cleanup() }
        let report = try await a.publish()
        #expect(report.needsMerge == [a.ref(id)])
        let remote = try #require(try a.store.remote(recordName: "e.note.\(id)"))
        #expect(remote.ver == 11 && !remote.sids.contains(attempt.attemptId) && remote.sids.count == 8)
        #expect(CloudOutcomeResolver.mergeBase(attempt: attempt, remote: remote) == attempt.baseAncestor)   // the base we held, not the snapshot
        try await a.sync(); try await b.sync(); try await a.sync()
        #expect(try a.notes().map(\.text).sorted() == b.notes().map(\.text).sorted())
        let all = try a.notes().map(\.text).joined(separator: "\n")
        #expect(all.contains("from A") && all.contains("B line 9"))          // nothing lost
        #expect(try a.store.allInflight().isEmpty && a.dirtyCount() == 0)
    }

    @Test func ambiguousOverlapMakesOneDeterministicConflictCopy() async throws {
        let (world, a, b, id, attempt) = try await Self.lostThenManyLaterWrites(overlapping: true); defer { world.cleanup() }
        try await a.publish()
        let remote = try #require(try a.store.remote(recordName: "e.note.\(id)"))
        let copyID = SyncNoteMerge.conflictID(entityID: id, mutationID: attempt.attemptId, remoteRevision: remote.ver)
        try await a.applyNotes()
        #expect(try a.notes().count == 2)
        #expect(try a.note(id)?.text == "# T\nbase\nfrom A\n")                    // the local text stays at the id
        #expect(try a.note(copyID)?.text == "# T\nbase\nfrom B9\n")               // the cloud text is the one copy
        // Replaying the situation (a second apply of the same version, a restart, more rounds) makes no second copy.
        try await a.sync(); try await b.sync(); try await a.sync(); try await b.sync()
        #expect(try a.notes().count == 2 && b.notes().count == 2)
        #expect(try a.notes().map(\.text).sorted() == b.notes().map(\.text).sorted())
        let texts = try a.notes().map(\.text).joined()
        #expect(texts.contains("from A") && texts.contains("from B9"))
    }

    @Test func ambiguousOutcomeNeverDiscardsTheSnapshotOrADirtyGeneration() async throws {
        let (world, a, _, id, attempt) = try await Self.lostThenManyLaterWrites(overlapping: true); defer { world.cleanup() }
        let sendsBefore = await a.gateway.sendLog.count
        try a.edit(id, "# T\nbase\nfrom A again\n")                              // a newer generation on top of the snapshot
        let generation = try #require(try a.dirtyGeneration(id))
        let before = try #require(try a.store.inflight(for: a.ref(id)))
        for _ in 0..<3 { try await a.publish() }                                // resolve once, then wait for the merge
        let after = try #require(try a.store.inflight(for: a.ref(id)))
        #expect(after.sealed == before.sealed && after.attemptId == attempt.attemptId && after.generation == before.generation)
        #expect(try a.dirtyGeneration(id) == generation)
        #expect(try a.store.hasPendingRemote(a.ref(id)))
        #expect(await a.gateway.sendLog.count == sendsBefore)                    // nothing was sent in the meantime
        // Offline while resolving changes nothing either.
        try a.store.markInflight(attemptId: attempt.attemptId, state: .unknown)
        await a.gateway.failNext(.offline)
        try await a.publish()
        #expect(try a.store.inflight(for: a.ref(id))?.sealed == before.sealed)
    }

    // MARK: rows 1, 2 and 5

    @Test func saveDidNotLandResendsSameSnapshot() async throws {
        let (world, a, _, id) = try await Self.synced(); defer { world.cleanup() }
        try a.edit(id, "# T\nbase\nedit\n")
        await a.gateway.failNext(.offline)                                       // the send never reached the cloud
        try await a.publish()
        let inflight = try #require(try a.store.inflight(for: a.ref(id)))
        #expect(inflight.state == .unknown)
        let report = try await a.publish()                                       // resolve (row 5) and send the same snapshot
        #expect(report.requeued == 1 && report.saved == 1)
        let log = await a.gateway.sendLog          // the failed send never reached the cloud and is not logged there
        #expect(log.last?.attemptId == inflight.attemptId)                           // the same attempt id goes out again
        #expect(log.last?.hadSystemFields == true && log.last?.usedOfferedTag == false)
        let record = try #require(await world.account.record(named: "e.note.\(id)"))
        #expect(record.ver == 2 && record.sid == inflight.attemptId)
        #expect(try Self.sealedOf(record) == inflight.sealed)                       // byte for byte the snapshot
    }

    @Test func firstPublishLostResponseResendsCreate() async throws {
        let world = try await PublisherWorld.make(1); defer { world.cleanup() }
        let a = world.devices[0]
        let note = try a.noteStore.create(text: "# Create\n")
        await a.gateway.failNext(.offline)
        try await a.publish()
        let report = try await a.publish()
        #expect(report.requeued == 1 && report.saved == 1)
        let log = await a.gateway.sendLog
        #expect(log.count == 1 && !log[0].hadSystemFields)                       // a create, sent once to the cloud
        #expect(await world.account.record(named: "e.note.\(note.id)")?.ver == 1)
    }

    @Test func missingRecordWithBaseHeldPausesTheEntity() async throws {
        let (world, a, _, id) = try await Self.synced(); defer { world.cleanup() }
        try a.edit(id, "# T\nbase\nlocal only\n")
        await a.gateway.failNext(.offline)
        try await a.publish()
        await world.account.removeRecord("e.note.\(id)")                         // gone from the cloud behind our back
        let report = try await a.publish()
        #expect(report.paused == [a.ref(id)])
        #expect(try a.store.missing(entityType: "note", entityId: id) != nil)
        let inflight = try #require(try a.store.inflight(for: a.ref(id)))        // everything kept
        #expect(inflight.state == .unknown && inflight.baseSystemFields != nil)
        #expect(try a.dirtyGeneration(id) != nil && a.note(id)?.text == "# T\nbase\nlocal only\n")
        let sends = await a.gateway.sendLog.count
        for _ in 0..<5 { try await a.publish() }
        #expect(await a.gateway.sendLog.count == sends)                          // nothing republished, ever, on its own
        #expect(await world.account.record(named: "e.note.\(id)") == nil)
        // Other entities are not held up.
        let other = try a.noteStore.create(text: "# Other\n")
        try await a.publish()
        #expect(await world.account.record(named: "e.note.\(other.id)") != nil)
    }

    @Test func unknownItemOnSaveResultPausesTheEntityAndKeepsEverything() async throws {
        let (world, a, _, id) = try await Self.synced(); defer { world.cleanup() }
        await world.account.removeRecord("e.note.\(id)")
        try a.edit(id, "# T\nbase\nedit\n")
        let report = try await a.publish()
        #expect(report.paused == [a.ref(id)])
        #expect(try a.store.inflight(for: a.ref(id)) != nil && a.dirtyGeneration(id) != nil)
        #expect(try a.store.pair(for: a.ref(id))?.ver == 1)                      // the pair never moves on a pause
    }

    // MARK: pure decisions

    @Test func theDecisionTableOverValues() throws {
        let entity = CloudEntityRef(entityType: "note", entityId: "n")
        func attempt(base: Data? = Data("t1".utf8), ver: Int64 = 1) -> CloudInflight {
            CloudInflight(entity: entity, localId: "n", generation: 3, attemptId: "att-new", baseSystemFields: base,
                          baseAncestor: base == nil ? nil : Data("anc".utf8), baseVer: base == nil ? 0 : ver, inc: "inc-1",
                          sealed: Data("snap".utf8), state: .unknown, accountGeneration: 1, sids: ["att-new", "att-old"])
        }
        func header(sid: String, sids: [String], ver: Int64, inc: String = "inc-1") -> CloudEntityHeader {
            CloudEntityHeader(entityType: .note, entityId: "n", inc: inc, incs: [], ver: ver, sid: sid, sids: sids, payload: .inline(Data([1])), blobs: [])
        }
        let pair = CloudBasePair(entity: entity, systemFields: Data("t1".utf8), ancestor: Data("anc".utf8), ver: 1, inc: "inc-1", sids: ["att-old"])
        // 1 and 2
        #expect(CloudOutcomeResolver.decide(attempt: attempt(base: nil), pair: nil, server: nil, serverSystemFields: nil) == .resendSameSnapshot)
        #expect(CloudOutcomeResolver.decide(attempt: attempt(), pair: pair, server: nil, serverSystemFields: nil) == .pauseEntity)
        // 3
        #expect(CloudOutcomeResolver.decide(attempt: attempt(), pair: pair, server: header(sid: "att-new", sids: ["att-new", "att-old"], ver: 2),
                                            serverSystemFields: Data("t2".utf8)) == .saveLanded(systemFields: Data("t2".utf8)))
        // 4
        #expect(CloudOutcomeResolver.decide(attempt: attempt(), pair: pair, server: header(sid: "att-other", sids: ["att-other", "att-new", "att-old"], ver: 3),
                                            serverSystemFields: Data("t3".utf8)) == .landedThenOverwritten)
        // 5: byte-equal system fields, or the same incarnation, version and head of the chain
        #expect(CloudOutcomeResolver.decide(attempt: attempt(), pair: pair, server: header(sid: "att-old", sids: ["att-old"], ver: 1),
                                            serverSystemFields: Data("t1".utf8)) == .resendSameSnapshot)
        #expect(CloudOutcomeResolver.decide(attempt: attempt(), pair: pair, server: header(sid: "att-old", sids: ["att-old"], ver: 1),
                                            serverSystemFields: Data("re-encoded".utf8)) == .resendSameSnapshot)
        // 6: anything else, including a first publish that finds a record, a different incarnation and a stale answer
        #expect(CloudOutcomeResolver.decide(attempt: attempt(), pair: pair, server: header(sid: "att-x", sids: ["att-x"], ver: 12),
                                            serverSystemFields: Data("t9".utf8)) == .mergeConservatively)
        #expect(CloudOutcomeResolver.decide(attempt: attempt(base: nil), pair: nil, server: header(sid: "att-x", sids: ["att-x"], ver: 1),
                                            serverSystemFields: Data("t9".utf8)) == .mergeConservatively)
        #expect(CloudOutcomeResolver.decide(attempt: attempt(), pair: pair, server: header(sid: "att-x", sids: ["att-x"], ver: 1, inc: "inc-2"),
                                            serverSystemFields: Data("t9".utf8)) == .mergeConservatively)
        // The cloud itself said the base is stale: the base version cannot be the answer.
        #expect(CloudOutcomeResolver.decide(attempt: attempt(), pair: pair, server: header(sid: "att-old", sids: ["att-old"], ver: 1),
                                            serverSystemFields: Data("t1".utf8), serverChanged: true) == .mergeConservatively)
        // A record that carries our attempt id but not the version it must have is not trusted as ours.
        #expect(CloudOutcomeResolver.decide(attempt: attempt(), pair: pair, server: header(sid: "att-new", sids: ["att-new"], ver: 5),
                                            serverSystemFields: Data("t5".utf8)) == .mergeConservatively)
    }

    static func sealedOf(_ record: CloudRecord) throws -> Data {
        try record.cipher ?? Data(contentsOf: try #require(record.cipherAsset))
    }
}
