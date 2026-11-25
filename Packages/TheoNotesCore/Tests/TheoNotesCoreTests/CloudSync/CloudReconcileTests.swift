// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

extension PublisherDevice {
    var incarnation: CloudIncarnation { CloudIncarnation(database: db, store: store, accountID: accountID, vaultKey: key) }

    func text(_ id: String) throws -> String? { try note(id)?.text }

    /// Every note's `id|location|text`, for byte-for-byte comparisons.
    func snapshot() throws -> [String] { try notes().map { "\($0.id)|\($0.location.rawValue)|\($0.text)" }.sorted() }

    /// A fetch that returns the cloud's whole current picture (the token expired).
    func fullFetch() async throws {
        await gateway.expireTokenNextFetch()
        try await fetch()
    }

    /// The text a cloud record carries, opened with this device's key.
    func openedText(of record: CloudRecord) throws -> String? {
        guard case .entity(let header) = try CloudRecordCodec.decode(record), case .inline(let data) = header.payload else { return nil }
        guard case .live(let body) = try sealer.open(data, type: header.entityType, entityID: header.entityId) else { return nil }
        return try SyncPayloadCodec.decode(SyncNotePayload.self, from: body).text
    }
}

func cloudHeader(_ world: PublisherWorld, _ id: String) async throws -> CloudEntityHeader {
    try decodedEntity(try #require(await world.account.record(named: "e.note.\(id)")))
}

/// Missing-record pause, recovery and incarnations (CK-R5, CK-R21).
@Suite struct CloudReconcileTests {
    // MARK: absence pauses and preserves

    @Test func fullRefetchPausesEntitiesTheCloudNoLongerReturns() async throws {
        let world = try await PublisherWorld.make(1); defer { world.cleanup() }
        let a = world.devices[0]
        let one = try a.noteStore.create(text: "# One\nx\n"), two = try a.noteStore.create(text: "# Two\ny\n")
        try await a.sync()
        let before = try a.snapshot()
        let sends = await a.gateway.sendLog.count
        await world.account.removeRecord("e.note.\(one.id)")
        try await a.fullFetch()
        #expect(try a.store.missing(entityType: "note", entityId: one.id)?.reason == "notReturnedByFullRefetch")
        #expect(try a.store.missing(entityType: "note", entityId: two.id) == nil)
        try await a.sync()
        #expect(try a.snapshot() == before, "local content is byte-identical")
        #expect(await a.gateway.sendLog.count == sends, "nothing was republished")
        #expect(await world.account.record(named: "e.note.\(one.id)") == nil)
    }

    @Test func unknownItemOnSavePausesTheEntity() async throws {
        let world = try await PublisherWorld.make(1); defer { world.cleanup() }
        let a = world.devices[0]
        let note = try a.noteStore.create(text: "# Gone\nx\n")
        try await a.sync()
        await world.account.removeRecord("e.note.\(note.id)")
        try a.edit(note.id, "# Gone\nedited\n")
        let report = try await a.publish()
        _ = try await a.publish()
        #expect(try a.store.missing(entityType: "note", entityId: note.id)?.reason == "unknownItem" || report.paused.count == 1)
        #expect(try a.store.missing(entityType: "note", entityId: note.id) != nil)
        #expect(try a.text(note.id) == "# Gone\nedited\n")
        #expect(try a.dirtyGeneration(note.id) != nil, "the edit is still waiting")
        #expect(await world.account.record(named: "e.note.\(note.id)") == nil)
    }

    @Test func recordDeletedByHandIsPausedNotDeletedLocally() async throws {
        let world = try await PublisherWorld.make(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let note = try a.noteStore.create(text: "# Hand\nx\n")
        try await a.sync(); try await b.sync()
        await world.account.removeRecord("e.note.\(note.id)")
        try await b.fetch()                                                 // an incremental fetch reports the deletion
        #expect(try b.store.missing(entityType: "note", entityId: note.id)?.reason == "deletedInCloud")
        #expect(try b.text(note.id) == "# Hand\nx\n")
        #expect(try b.note(note.id)?.location == .notes)
        try await b.sync()
        #expect(await world.account.record(named: "e.note.\(note.id)") == nil)
    }

    @Test func noAutomaticRepublishEverHappens() async throws {
        let world = try await PublisherWorld.make(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let note = try a.noteStore.create(text: "# Never\nx\n")
        try await a.sync(); try await b.sync()
        await world.account.removeRecord("e.note.\(note.id)")
        try await a.fullFetch(); try await b.fullFetch()
        let sends = (await a.gateway.sendLog.count, await b.gateway.sendLog.count)
        for cycle in 0..<50 {
            for d in [a, b] {
                if cycle % 7 == 0 { try d.edit(note.id, (try d.text(note.id) ?? "") + "c\(cycle)\n") }   // edits keep raising the generation
                try await d.sync(rounds: 1)
                if cycle % 11 == 0 { try d.publisher.treatSendingAsUnknown() }
            }
        }
        #expect((await a.gateway.sendLog.count, await b.gateway.sendLog.count) == sends, "no save for the paused entity in 50 cycles")
        #expect(await world.account.record(named: "e.note.\(note.id)") == nil)
        #expect(await world.account.versionCount(of: "e.note.\(note.id)") == 0, "nothing was ever written again")
        #expect(try a.store.missing(entityType: "note", entityId: note.id) != nil && b.store.missing(entityType: "note", entityId: note.id) != nil)
    }

    @Test func pausedEntityDoesNotBlockOthers() async throws {
        let world = try await PublisherWorld.make(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let paused = try a.noteStore.create(text: "# Paused\nx\n"), live = try a.noteStore.create(text: "# Live\nx\n")
        try await a.sync(); try await b.sync()
        await world.account.removeRecord("e.note.\(paused.id)")
        try await a.fullFetch()
        try a.edit(live.id, "# Live\nchanged\n")
        try await a.sync(); try await b.sync()
        #expect(try b.text(live.id) == "# Live\nchanged\n")
        #expect(try a.store.missing(entityType: "note", entityId: paused.id) != nil)
    }

    @Test func fullRefetchNeverRunsAfterZoneRemoval() async throws {
        let world = try await PublisherWorld.make(1); defer { world.cleanup() }
        let a = world.devices[0]
        let note = try a.noteStore.create(text: "# Zone\nx\n")
        try await a.sync()
        await world.account.removeZone(reason: .userDeletedZone)
        try await a.fullFetch()
        try await a.fullFetch()
        #expect(try a.store.missing(entityType: "note", entityId: note.id) == nil, "a removed zone is not a list of missing records")
        if case .removed = try a.store.zoneState() {} else { Issue.record("the zone removal is recorded") }
        #expect(throws: CloudSinkError.zoneRemoved) { try a.sink.beginFullRefetch() }
        #expect(!a.sink.isInFullRefetch)
        #expect(try a.text(note.id) == "# Zone\nx\n")
    }

    // MARK: recovery

    @Test func recoveryCreatesANewIncarnationCreateOnlyFromCurrentLibraryContent() async throws {
        let world = try await PublisherWorld.make(1); defer { world.cleanup() }
        let a = world.devices[0]
        let note = try a.noteStore.create(text: "# Recover\nold\n")
        try await a.sync()
        let old = try await cloudHeader(world, note.id)
        await world.account.removeRecord("e.note.\(note.id)")
        try await a.fullFetch()
        try a.edit(note.id, "# Recover\nedited while paused\n")
        #expect(try a.incarnation.recover(entityType: "note", entityId: note.id) == .prepared(attemptId: try #require(try a.store.inflight(for: a.ref(note.id))?.attemptId),
                                                                                              inc: try #require(try a.store.inflight(for: a.ref(note.id))?.inc)))
        try await a.sync()
        let record = try #require(await world.account.record(named: "e.note.\(note.id)"))
        let header = try decodedEntity(record)
        #expect(header.ver == 1 && header.inc != old.inc)
        #expect(header.incs.first == old.inc, "the old incarnation is listed as superseded")
        #expect(try a.openedText(of: record) == "# Recover\nedited while paused\n")
        let sent = await a.gateway.sendLog.last
        #expect(sent?.hadSystemFields == false, "create-only: no change tag")
        #expect(try a.store.missing(entityType: "note", entityId: note.id) == nil)
        let pair = try #require(try a.store.pair(for: a.ref(note.id)))
        #expect(pair.inc == header.inc && pair.ver == 1 && pair.supersededIncs.contains(old.inc))
        #expect(try a.dirtyCount() == 0)
    }

    @Test func aRecordThatComesBackLiftsThePauseWithoutAnyRecovery() async throws {
        let world = try await PublisherWorld.make(1); defer { world.cleanup() }
        let a = world.devices[0]
        let note = try a.noteStore.create(text: "# Back\nv1\n")
        try await a.sync()
        let record = try #require(await world.account.record(named: "e.note.\(note.id)"))
        await world.account.removeRecord("e.note.\(note.id)")
        try await a.fullFetch()
        #expect(try a.store.missing(entityType: "note", entityId: note.id) != nil)
        // A Console action brings the same record back (a create: another change tag).
        let writer = try await Peer.make(world.account)
        var restored = record; restored.systemFields = nil
        try await writer.save(restored)
        try await a.fullFetch()
        _ = try await a.applyNotes()
        #expect(try a.store.missing(entityType: "note", entityId: note.id) == nil, "the record is back: the entity is no longer paused")
        try a.edit(note.id, "# Back\nv2\n")
        try await a.sync()
        let header = try await cloudHeader(world, note.id)
        let originalInc = try decodedEntity(record).inc
        #expect(header.ver == 2 && header.inc == originalInc, "the history continues in the same incarnation, no recovery was needed")
    }

    @Test func recoveryIsRefusedForAnEntityThatIsNotPaused() async throws {
        let world = try await PublisherWorld.make(1); defer { world.cleanup() }
        let a = world.devices[0]
        let note = try a.noteStore.create(text: "# Fine\nx\n")
        try await a.sync()
        #expect(try a.incarnation.recover(entityType: "note", entityId: note.id) == .notPaused)
    }

    @Test func offlineDeviceHoldingAHigherVerMergesTheNewIncarnationAgainstItsOwnAncestor() async throws {
        let world = try await PublisherWorld.make(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let base = "# Doc\nline one\nline two\nline three\n"
        let note = try a.noteStore.create(text: base)
        try await a.sync(); try await b.sync()
        // The history grows to version 10; both devices hold it.
        for i in 0..<9 { try a.edit(note.id, (try a.text(note.id) ?? "") + "a\(i)\n"); try await a.sync() }
        try await b.sync()
        #expect(try b.store.pair(for: b.ref(note.id))?.ver == 10)
        // A recovers at ver 1 of a new incarnation while B is away.
        await world.account.removeRecord("e.note.\(note.id)")
        try await a.fullFetch()
        _ = try a.incarnation.recover(entityType: "note", entityId: note.id)
        try await a.sync()
        // B edits offline, then returns holding ver 10 of the old incarnation.
        try b.edit(note.id, (try b.text(note.id) ?? "").replacingOccurrences(of: "line three", with: "line THREE from b"))
        try await b.sync(); try await a.sync(); try await b.sync()
        let merged = try #require(try a.text(note.id))
        let noteCount = try a.notes().count
        #expect(merged.contains("line THREE from b") && noteCount == 1, "the recovered record is exactly what B held: a clean merge, no copy")
        #expect(try a.snapshot() == b.snapshot())
        #expect(try b.store.pair(for: b.ref(note.id))?.inc == a.store.pair(for: a.ref(note.id))?.inc)
    }

    @Test(arguments: [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]])
    func concurrentRecoveryAttemptsExactlyOneWinsTheLoserMerges(order: [Int]) async throws {
        let world = try await PublisherWorld.make(3); defer { world.cleanup() }
        let ds = world.devices
        let note = try ds[0].noteStore.create(text: "# Race\nl1\nl2\nl3\nl4\nl5\n")
        for d in ds { try await d.sync() }
        for d in ds { try await d.sync() }
        await world.account.removeRecord("e.note.\(note.id)")
        for d in ds { try await d.fullFetch() }
        // Each device edits its own line while the entity is paused.
        for (i, d) in ds.enumerated() {
            try d.edit(note.id, (try d.text(note.id) ?? "").replacingOccurrences(of: "l\(i * 2 + 1)", with: "L\(i * 2 + 1)-from-\(i)"))
            #expect(try { if case .prepared = try d.incarnation.recover(entityType: "note", entityId: note.id) { return true } else { return false } }())
        }
        // Every interleaving: one device publishes first; the others' create-only saves meet its record.
        for i in order { _ = try await ds[i].publish() }
        let creates = await ds.asyncMap { await $0.gateway.sendLog.filter { !$0.hadSystemFields && $0.recordName == "e.note.\(note.id)" }.count }
        #expect(creates.reduce(0, +) >= 3, "all three tried a create")
        #expect(await world.account.versionCount(of: "e.note.\(note.id)") >= 1)
        for _ in 0..<4 { for d in ds { try await d.sync() } }
        let first = try ds[0].snapshot()
        for d in ds { #expect(try d.snapshot() == first, "all libraries converge") }
        let union = try ds[0].notes().map(\.text).joined(separator: "\n")
        for (i, _) in ds.enumerated() { #expect(union.contains("-from-\(i)"), "the edit of device \(i) survived") }
        for d in ds { #expect(try d.dirtyCount() == 0 && d.store.allInflight().isEmpty && d.store.allMissing().isEmpty) }
        let headers = try await cloudHeader(world, note.id)
        #expect(headers.ver >= 1)
    }

    @Test func aRecoveryRaceWonByALaggingDeviceNeverCostsTheOtherDeviceItsNewerContent() async throws {
        let world = try await PublisherWorld.make(2); defer { world.cleanup() }
        let lagging = world.devices[0], current = world.devices[1]
        let note = try lagging.noteStore.create(text: "# Lag\nl1\nl2\n")
        try await lagging.sync(); try await current.sync()
        try current.edit(note.id, "# Lag\nl1\nl2\nNEWER-EDIT-ONLY-ON-CURRENT\n")
        try await current.sync()                                           // the lagging device never fetches this
        await world.account.removeRecord("e.note.\(note.id)")
        try await lagging.fullFetch(); try await current.fullFetch()
        _ = try lagging.incarnation.recover(entityType: "note", entityId: note.id)
        try await lagging.publish()                                        // the lagging device wins the race
        _ = try current.incarnation.recover(entityType: "note", entityId: note.id)
        for _ in 0..<4 { try await current.sync(); try await lagging.sync() }
        for d in [lagging, current] {
            #expect(try d.snapshot().joined().contains("NEWER-EDIT-ONLY-ON-CURRENT"), "\(d.name) still has the newer edit")
        }
        #expect(try lagging.snapshot() == current.snapshot())
    }

    @Test func anEqualVersionUnderAnotherChangeTagIsStoredSoThePairTakesTheNewTag() throws {
        let d = try PublisherDevice("retag", account: nil); defer { d.cleanup() }
        let held = Rec.entity("n1", 2)
        try d.adopt(held)
        #expect(try d.sink.intake(held, delivery: .incremental) == .echo, "our own save coming back")
        var recreated = held
        recreated.systemFields = Data("another-tag".utf8)
        #expect(try d.sink.intake(recreated, delivery: .serverRecordChanged) == .stored, "the record was recreated: the new tag must reach the pair")
    }

    // MARK: ordering across incarnations (CK-R21)

    @Test func recoveryNeverComparesVerAcrossIncarnations() throws {
        let d = try PublisherDevice("cross", account: nil); defer { d.cleanup() }
        try d.adopt(Rec.entity("n1", 10, inc: "incA"))
        // A new incarnation starts at ver 1: lower than the 10 we hold, and still followed.
        #expect(try d.sink.intake(Rec.entity("n1", 1, inc: "incB", incs: ["incA"]), delivery: .incremental) == .stored)
        #expect(try d.store.remote(recordName: "e.note.n1")?.inc == "incB")
        // Within the incarnation the version still orders.
        #expect(try d.sink.intake(Rec.entity("n1", 1, inc: "incB", incs: ["incA"]), delivery: .incremental) == .echo)
    }

    @Test func lateDeliveryOfASupersededIncarnationInAnIncrementalFetchIsIgnored() throws {
        let d = try PublisherDevice("late", account: nil); defer { d.cleanup() }
        try d.adopt(Rec.entity("n1", 1, inc: "incB", incs: ["incA"]))
        #expect(try d.sink.intake(Rec.entity("n1", 20, inc: "incA"), delivery: .incremental) == .ignoredSupersededIncarnation)
        #expect(try d.rowCount("ck_remote") == 0)
    }

    @Test func supersededIncarnationInsideAFullRefetchIsFollowed() throws {
        let d = try PublisherDevice("full", account: nil); defer { d.cleanup() }
        try d.adopt(Rec.entity("n1", 1, inc: "incB", incs: ["incA"]))
        try d.sink.beginFullRefetch()
        try d.sink.commit(changed: [Rec.entity("n1", 20, inc: "incA")], deletedNames: [])
        try d.sink.endFullRefetch()
        #expect(try d.store.remote(recordName: "e.note.n1")?.inc == "incA", "an authoritative picture is followed")
        // And a serverRecordChanged is followed too.
        let other = try PublisherDevice("full2", account: nil); defer { other.cleanup() }
        try other.adopt(Rec.entity("n1", 1, inc: "incB", incs: ["incA"]))
        #expect(try other.sink.intake(Rec.entity("n1", 20, inc: "incA"), delivery: .serverRecordChanged) == .stored)
    }

    @Test func resurrectedOldRecordIsAdoptedByMergeNotIgnored() async throws {
        let world = try await PublisherWorld.make(1); defer { world.cleanup() }
        let a = world.devices[0]
        let note = try a.noteStore.create(text: "# Undo\nfirst\n")
        try await a.sync()
        let oldRecord = try #require(await world.account.record(named: "e.note.\(note.id)"))
        let oldInc = try decodedEntity(oldRecord).inc
        // The record vanishes and A recovers it as a new incarnation with newer content.
        await world.account.removeRecord("e.note.\(note.id)")
        try await a.fullFetch()
        try a.edit(note.id, "# Undo\nsecond\n")
        _ = try a.incarnation.recover(entityType: "note", entityId: note.id)
        try await a.sync()
        #expect(try a.store.pair(for: a.ref(note.id))?.supersededIncs.contains(oldInc) == true)
        // A Console action brings the old record back (a create of the old content under the old incarnation).
        await world.account.removeRecord("e.note.\(note.id)")
        let writer = try await Peer.make(world.account)
        var restored = oldRecord; restored.systemFields = nil
        try await writer.save(restored)
        try await a.fullFetch()                                              // an authoritative picture: followed, not ignored
        _ = try await a.applyNotes()
        #expect(try a.store.pair(for: a.ref(note.id))?.inc == oldInc, "the old history was adopted")
        let everything = try a.snapshot().joined()
        #expect(everything.contains("second") && everything.contains("first"), "the newer content stays, the resurrected one is kept (as a copy)")
        #expect(try a.store.missing(entityType: "note", entityId: note.id) == nil)
    }

    @Test func recoveredTwiceWhileADeviceWasOfflineStillMerges() async throws {
        let world = try await PublisherWorld.make(2); defer { world.cleanup() }
        let a = world.devices[0], d = world.devices[1]
        let note = try a.noteStore.create(text: "# Twice\nl1\nl2\nl3\n")
        try await a.sync(); try await d.sync()
        let first = try await cloudHeader(world, note.id).inc
        for round in 0..<2 {
            await world.account.removeRecord("e.note.\(note.id)")
            try await a.fullFetch()
            _ = try a.incarnation.recover(entityType: "note", entityId: note.id)
            try await a.sync()
            if round == 0 { try a.edit(note.id, (try a.text(note.id) ?? "").replacingOccurrences(of: "l1", with: "L1 from a")); try await a.sync() }
        }
        let header = try await cloudHeader(world, note.id)
        #expect(header.inc != first && header.incs.count == 2 && header.incs.contains(first))
        // D was offline throughout and edits another line against inc A.
        try d.edit(note.id, (try d.text(note.id) ?? "").replacingOccurrences(of: "l3", with: "L3 from d"))
        try await d.sync(); try await a.sync(); try await d.sync()
        let everything = try d.snapshot().joined()
        #expect(everything.contains("L1 from a") && everything.contains("L3 from d"), "both survive (the recovered content differs from D's, so it is kept as an independent copy)")
        #expect(try a.snapshot() == d.snapshot())
    }

    @Test func deviceEditingWhileThePausedEntityIsMissingThenRecovers() async throws {
        let world = try await PublisherWorld.make(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let note = try a.noteStore.create(text: "# Edit\nl1\nl2\n")
        try await a.sync(); try await b.sync()
        await world.account.removeRecord("e.note.\(note.id)")
        try await a.fullFetch()
        let sends = await a.gateway.sendLog.count
        for i in 0..<3 { try a.edit(note.id, (try a.text(note.id) ?? "") + "paused\(i)\n"); try await a.sync(rounds: 1) }
        #expect(await a.gateway.sendLog.count == sends, "edits while paused wait")
        let generation = try #require(try a.dirtyGeneration(note.id))
        #expect(generation >= 3)
        _ = try a.incarnation.recover(entityType: "note", entityId: note.id)
        try await a.sync()
        try await b.sync()
        #expect(try b.snapshot().joined().contains("paused2"))
        #expect(try a.dirtyCount() == 0)
    }

    @Test func forkedIncarnationsConverge() async throws {
        let world = try await PublisherWorld.make(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let note = try a.noteStore.create(text: "# Fork\nl1\nl2\nl3\n")
        try await a.sync(); try await b.sync()
        await world.account.removeRecord("e.note.\(note.id)")
        try await a.fullFetch(); try await b.fullFetch()                    // both pause
        try a.edit(note.id, (try a.text(note.id) ?? "").replacingOccurrences(of: "l1", with: "L1 from a"))
        try b.edit(note.id, (try b.text(note.id) ?? "").replacingOccurrences(of: "l3", with: "L3 from b"))
        _ = try a.incarnation.recover(entityType: "note", entityId: note.id)
        try await a.sync(rounds: 1)
        let first = try await cloudHeader(world, note.id).inc
        await world.account.removeRecord("e.note.\(note.id)")                // gone again before B recovers
        _ = try b.incarnation.recover(entityType: "note", entityId: note.id)
        try await b.publish()
        let second = try await cloudHeader(world, note.id)
        #expect(second.inc != first, "two histories grew from the same old incarnation")
        for _ in 0..<4 { try await a.sync(); try await b.sync() }
        let everything = try a.snapshot().joined()
        #expect(everything.contains("L1 from a") && everything.contains("L3 from b"), "both edits survive in the converged library")
        #expect(try a.snapshot() == b.snapshot())
        #expect(try a.store.pair(for: a.ref(note.id))?.inc == b.store.pair(for: b.ref(note.id))?.inc)
    }
}

extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var out: [T] = []
        for element in self { out.append(try await transform(element)) }
        return out
    }
}
