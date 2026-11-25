// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// Codex review of Task 5, fix round 1 (C1, I1, I2, I3).
@Suite struct CloudPublisherFixRound1Tests {
    // MARK: C1

    @Test func aDelayedSuccessNeverRegressesAPairThatAFetchedVersionAdvanced() async throws {
        let (world, a, b, id) = try await CloudOutcomeResolverTests.synced(); defer { world.cleanup() }
        await a.gateway.setAutoSend(false)
        try a.edit(id, "# T\nbase\nfrom A\n")
        try await a.publish()                                      // sending; the save is in the gateway's queue
        let attempt = try #require(try a.store.inflight(for: a.ref(id)))
        try await a.gateway.sendPending()                          // it lands as version 2; A has not consumed the result yet
        try await b.sync()                                         // B merges version 2 ...
        try b.edit(id, "# T\nbase\nfrom A\nfrom B\n")
        try await b.publish()                                      // ... and writes version 3 on top of it
        try await a.fetch()                                        // A stores version 3
        let remote = try #require(try a.store.remote(recordName: "e.note.\(id)"))
        #expect(remote.ver == 3 && remote.sids.contains(attempt.attemptId))
        try a.store.recordApplied(accountGeneration: try a.store.generation(), remote: remote, ancestor: try #require(remote.sealed))
        let advanced = try #require(try a.store.pair(for: a.ref(id)))
        #expect(advanced.ver == 3)
        let dirty = try #require(try a.dirtyGeneration(id))
        try a.publisher.consumeResults()                           // the delayed success of version 2 arrives now
        let after = try #require(try a.store.pair(for: a.ref(id)))
        #expect(after == advanced)                                 // never regressed to version 2
        #expect(try a.dirtyGeneration(id) == dirty)                // never cleared: the merge decides what is still owed
        #expect(try a.store.inflight(for: a.ref(id)) == nil)       // the snapshot's content is in the library and the pair is beyond it
    }

    @Test func recordSavedRefusesToMoveAPairThatIsNoLongerTheBaseOfTheSnapshot() throws {
        let store = CloudSyncStore(database: try AppDatabase.inMemory())
        let generation = try store.bind(accountId: "ck-1", containerId: "iCloud.test", zoneName: "TheoNotes", cloudUserHash: "u")
        let entity = CloudEntityRef(entityType: "note", entityId: "n1")
        try store.database.pool.write { try $0.execute(sql: "INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('note','n1',2,0)") }
        let base = CloudRemoteVersion(entity: entity, inc: "inc-a", ver: 1, sid: "s1", sids: ["s1"], systemFields: Data("t1".utf8), sealed: Data("v1".utf8))
        try store.recordApplied(accountGeneration: generation, remote: base, ancestor: Data("v1".utf8))
        let pair1 = try #require(try store.pair(for: entity))
        try store.insertInflight(CloudInflight(entity: entity, localId: "n1", generation: 2, attemptId: "att-2", baseSystemFields: pair1.systemFields,
                                               baseAncestor: pair1.ancestor, baseVer: 1, inc: "inc-a", sealed: Data("v2".utf8),
                                               state: .sending, accountGeneration: generation, sids: ["att-2", "s1"]))
        let newer = CloudRemoteVersion(entity: entity, inc: "inc-a", ver: 3, sid: "s3", sids: ["s3", "att-2", "s1"], systemFields: Data("t3".utf8), sealed: Data("v3".utf8))
        try store.recordApplied(accountGeneration: generation, remote: newer, ancestor: Data("v3".utf8))
        let before = try #require(try store.pair(for: entity))
        #expect(try store.recordSaved(attemptId: "att-2", newSystemFields: Data("t2".utf8)) == .pairAdvanced)
        #expect(try store.pair(for: entity) == before)
        #expect(try store.database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_dirty") } == 1)
    }

    // MARK: I1

    /// A prepared snapshot that names a blob, so the publisher awaits the upload hook between its early checks and the send.
    static func preparedWithBlob(_ a: PublisherDevice, _ id: String) async throws -> CloudInflight {
        try a.edit(id, "# T\nbase\nedited\n")
        let pair = try #require(try a.store.pair(for: a.ref(id)))
        let generation = try #require(try a.dirtyGeneration(id))
        let attempt = CloudInflight(entity: a.ref(id), localId: id, generation: generation, attemptId: "att-blob", baseSystemFields: pair.systemFields,
                                    baseAncestor: pair.ancestor, baseVer: pair.ver, inc: pair.inc, sealed: Data("sealed".utf8),
                                    blobRefs: [String(repeating: "ab", count: 32)], accountGeneration: try a.store.generation(),
                                    sids: ["att-blob"] + pair.sids)
        try a.store.insertInflight(attempt)
        return attempt
    }

    @Test func aQuarantineThatArrivesDuringTheBlobUploadStopsTheSend() async throws {
        let (world, a, _, id) = try await CloudOutcomeResolverTests.synced(); defer { world.cleanup() }
        let attempt = try await Self.preparedWithBlob(a, id)
        let sends = await a.gateway.sendLog.count
        a.blobs.onCall = { _ in try? CloudPublisherLifecycleTests.quarantine(a, id) }
        let report = try await a.publisher.submit()
        #expect(report.submitted == 0 && report.blocked == [a.ref(id)])
        #expect(await a.gateway.sendLog.count == sends)
        #expect(try a.store.inflight(attemptId: attempt.attemptId)?.state == .prepared)
        #expect(try a.dirtyGeneration(id) != nil)
    }

    @Test func aPauseThatArrivesDuringTheBlobUploadStopsTheSend() async throws {
        let (world, a, _, id) = try await CloudOutcomeResolverTests.synced(); defer { world.cleanup() }
        let attempt = try await Self.preparedWithBlob(a, id)
        let sends = await a.gateway.sendLog.count
        a.blobs.onCall = { _ in try? a.store.markMissing(entityType: "note", entityId: id, reason: "test") }
        let report = try await a.publisher.submit()
        #expect(report.submitted == 0 && report.blocked == [a.ref(id)])
        #expect(await a.gateway.sendLog.count == sends)
        #expect(try a.store.inflight(attemptId: attempt.attemptId)?.state == .prepared)
        #expect(try a.dirtyGeneration(id) != nil)
    }

    @Test func aFetchedVersionThatArrivesDuringTheBlobUploadStopsTheSend() async throws {
        let (world, a, b, id) = try await CloudOutcomeResolverTests.synced(); defer { world.cleanup() }
        try b.edit(id, "# T\nbase\nfrom B\n")
        try await b.publish()
        let theirs = try #require(await world.account.record(named: "e.note.\(id)"))
        let attempt = try await Self.preparedWithBlob(a, id)
        let sends = await a.gateway.sendLog.count
        let intake = a.intake
        a.blobs.onCall = { _ in _ = try? intake.intake(theirs, delivery: .incremental) }
        let report = try await a.publisher.submit()
        #expect(report.submitted == 0 && report.blocked == [a.ref(id)])
        #expect(try a.store.hasPendingRemote(a.ref(id)))
        #expect(await a.gateway.sendLog.count == sends)
        #expect(try a.store.inflight(attemptId: attempt.attemptId)?.state == .prepared)
        #expect(try a.dirtyGeneration(id) != nil)
    }

    // MARK: I2

    @Test func v17GivesExistingInflightRowsTheirAttemptIdAsTheChainAndKeepsTheirState() throws {
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue, upTo: "v16-cloudkit-native")
        try queue.write { db in
            for (id, state) in [("a", "prepared"), ("b", "sending"), ("c", "unknown")] {
                try db.execute(sql: """
                    INSERT INTO ck_inflight(entityType,entityId,localId,generation,attemptId,baseVer,inc,sealed,state,generationOfAccount,preparedAt)
                    VALUES('note',?,?,1,?,0,'inc-a',x'01',?,1,?)
                    """, arguments: [id, id, "att-\(id)", state, Date()])
            }
        }
        try Migrations.migrator.migrate(queue)
        let rows = try queue.read { db in try Row.fetchAll(db, sql: "SELECT attemptId, sids, state FROM ck_inflight ORDER BY entityId") }
        #expect(rows.map { $0["sids"] as String } == ["[\"att-a\"]", "[\"att-b\"]", "[\"att-c\"]"])
        #expect(rows.map { $0["state"] as String } == ["prepared", "sending", "unknown"])
        // The chain decodes the way the store reads it, and the record built from such a row passes the codec.
        #expect(CloudSyncStore.decode(rows[0]["sids"]) == ["att-a"])
    }

    // MARK: I3

    @Test func theDirectoryOfAPinnedAssetIsSyncedAfterTheFileAndBeforeTheRowIsStored() throws {
        let db = try AppDatabase.inMemory()
        let store = CloudSyncStore(database: db)
        _ = try store.bind(accountId: "ck-1", containerId: "iCloud.test", zoneName: "TheoNotes", cloudUserHash: "u")
        let pins = FileManager.default.temporaryDirectory.appendingPathComponent("pins-\(UUID())")
        defer { try? FileManager.default.removeItem(at: pins) }
        let synced = LockedBox<[(path: String, fileExists: Bool, rows: Int)]>([])
        let intake = CloudBasicRemoteIntake(store: store, pinDirectory: pins, syncDirectory: { url in
            let files = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            let rows = (try? store.allRemote().count) ?? -1
            synced.update { $0.append((url.path, !files.isEmpty, rows)) }
        })
        _ = try intake.intake(Self.assetRecord(), delivery: .incremental)
        let calls = synced.value
        #expect(!calls.isEmpty && calls.allSatisfy { $0.rows == 0 })                  // always before the row
        #expect(calls.contains { $0.fileExists })                                      // after the file was written
        #expect(calls.map(\.path).contains(pins.path))                                  // up to the pin folder itself
        #expect(calls.last?.path == pins.deletingLastPathComponent().path)             // and, because it was just created, its parent last
        // A pin folder that already exists needs no parent sync.
        synced.update { $0 = [] }
        _ = try intake.intake(Self.assetRecord(), delivery: .incremental)
        #expect(synced.value.last?.path == pins.path)
        #expect(try store.allRemote().count == 1)
    }

    @Test func aFailureWhileSyncingThePinDirectoryStoresNoRowAndLeavesNoPinnedFile() throws {
        let db = try AppDatabase.inMemory()
        let store = CloudSyncStore(database: db)
        _ = try store.bind(accountId: "ck-1", containerId: "iCloud.test", zoneName: "TheoNotes", cloudUserHash: "u")
        let pins = FileManager.default.temporaryDirectory.appendingPathComponent("pins-\(UUID())")
        defer { try? FileManager.default.removeItem(at: pins) }
        struct Boom: Error {}
        let intake = CloudBasicRemoteIntake(store: store, pinDirectory: pins, syncDirectory: { _ in throw Boom() })
        #expect(throws: Boom.self) { try intake.intake(Self.assetRecord(), delivery: .incremental) }
        #expect(try store.allRemote().isEmpty && store.quarantineRows().isEmpty)
        let leftovers = FileManager.default.enumerator(at: pins, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? []
        #expect(leftovers.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.isEmpty)
    }

    // MARK: round 2

    /// A saved result arrives after a version of another incarnation was applied: ancestry is not proven.
    @Test func aSaveThatLandedUnderAnotherIncarnationIsKeptAsAMergeInputAndReconciled() async throws {
        let (world, a, _, id) = try await CloudOutcomeResolverTests.synced(); defer { world.cleanup() }
        await a.gateway.setAutoSend(false)
        try a.edit(id, "# T\nbase\nfrom A\n")
        try await a.publish()
        let attempt = try #require(try a.store.inflight(for: a.ref(id)))
        try await a.gateway.sendPending()                                              // it lands; the result is stored, not consumed
        let other = CloudRemoteVersion(entity: a.ref(id), inc: "inc-other", ver: 1, sid: "other-1", sids: ["other-1"],
                                       systemFields: Data("tag-other".utf8), sealed: Data("other".utf8))
        try a.store.recordApplied(accountGeneration: try a.store.generation(), remote: other, ancestor: Data("other".utf8))
        let dirty = try #require(try a.dirtyGeneration(id))
        let report = try a.publisher.consumeResults()
        let pair = try #require(try a.store.pair(for: a.ref(id)))
        #expect(pair.inc == "inc-other" && pair.ver == 1)                               // never overwritten
        #expect(try a.dirtyGeneration(id) == dirty)                                     // never cleared
        #expect(report.needsMerge == [a.ref(id)] && report.advanced.isEmpty)
        let kept = try #require(try a.store.inflight(attemptId: attempt.attemptId))     // the snapshot is kept
        #expect(kept.state == .unknown)
        let landed = try #require(try a.store.remote(recordName: "e.note.\(id)"))       // the landed result is the merge input
        #expect(landed.inc == attempt.inc && landed.sid == attempt.attemptId && landed.sealed == attempt.sealed && landed.ver == attempt.baseVer + 1)
        #expect(CloudOutcomeResolver.mergeBase(attempt: kept, remote: landed) == kept.baseAncestor)
        // Reconciled through the existing merge path: the receiver merges, adopts, drops the snapshot.
        try await a.applyNotes()
        #expect(try a.store.remote(recordName: "e.note.\(id)") == nil && a.store.inflight(for: a.ref(id)) == nil)
        #expect(try a.note(id)?.text == "# T\nbase\nfrom A\n")
    }

    @Test func aSaveThatLandedUnderTheSameIncarnationButWithoutProofIsDroppedWithDirtyKept() async throws {
        // Same incarnation, the applied version is newer and its chain no longer names our attempt (more than 8 later writes).
        let (world, a, _, id) = try await CloudOutcomeResolverTests.synced(); defer { world.cleanup() }
        await a.gateway.setAutoSend(false)
        try a.edit(id, "# T\nbase\nfrom A\n")
        try await a.publish()
        let attempt = try #require(try a.store.inflight(for: a.ref(id)))
        try await a.gateway.sendPending()
        let pairBefore = try #require(try a.store.pair(for: a.ref(id)))
        let newer = CloudRemoteVersion(entity: a.ref(id), inc: pairBefore.inc, ver: 12, sid: "w12", sids: (1...8).map { "w\($0)" },
                                       systemFields: Data("tag-12".utf8), sealed: Data("newer".utf8))
        try a.store.recordApplied(accountGeneration: try a.store.generation(), remote: newer, ancestor: Data("newer".utf8))
        let dirty = try #require(try a.dirtyGeneration(id))
        let report = try a.publisher.consumeResults()
        #expect(try a.store.pair(for: a.ref(id))?.ver == 12)
        #expect(try a.dirtyGeneration(id) == dirty)                                     // kept: what is still owed goes out on the new pair
        #expect(try a.store.inflight(attemptId: attempt.attemptId) == nil && report.advanced == [a.ref(id)])
    }

    // MARK: I1 ruling CK-R78: every save carries the base's system fields, or is a create

    @Test func everySaveCarriesTheBaseSystemFieldsExceptACreateAndNoPolicyOverridesTheCheck() async throws {
        let world = try await PublisherWorld.make(1); defer { world.cleanup() }
        let a = world.devices[0]
        let note = try a.noteStore.create(text: "# One\n")
        // A create, an update on its base, a new incarnation (create-only), all through the same record builder.
        var seen: [(CloudInflight, CloudRecord)] = []
        for round in 0..<3 {
            if round == 1 { try a.edit(note.id, "# One\ntwo\n") }
            let made = try await a.publisher.prepare()
            for attempt in made { seen.append((attempt, try a.publisher.buildRecord(attempt))) }
            try await a.publish()
        }
        try a.edit(note.id, "# One\nthree\n")
        let pair = try #require(try a.store.pair(for: a.ref(note.id)))
        let recovery = CloudInflight(entity: a.ref(note.id), localId: note.id, generation: 1, attemptId: "att-recovery", baseSystemFields: nil,
                                     baseAncestor: nil, baseVer: 0, inc: "inc-new", sealed: Data("s".utf8), accountGeneration: try a.store.generation())
        seen.append((recovery, try a.publisher.buildRecord(recovery)))
        _ = pair
        #expect(seen.count >= 3)
        for (attempt, record) in seen {
            #expect(record.systemFields == attempt.baseSystemFields)                      // never anything else
            if attempt.baseSystemFields == nil { #expect(record.ver == 1 && attempt.baseVer == 0) }     // only a create has none
            else { #expect(record.ver == attempt.baseVer + 1) }
        }
        // The only way a save leaves the publisher is a `CloudSave` built from such a record; the gateway seam has no
        // save policy, no changed-keys-only mode and nothing that overwrites regardless of the change tag.
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/TheoNotesCore/CloudSync")
        for file in ["CloudPublisher.swift", "CloudKitGateway.swift", "CloudRecord.swift", "CloudOutcomeResolver.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for banned in ["savePolicy", "changedKeys", "allKeys", "ifServerRecordUnchanged", "changedKeysOnly", "overwrite"] {
                #expect(!text.contains(banned), "\(file) mentions \(banned)")
            }
        }
    }

    static func assetRecord() throws -> CloudRecord {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("asset-\(UUID())")
        try Data(repeating: 7, count: 300_000).write(to: file)
        let header = CloudEntityHeader(entityType: .note, entityId: "n1", inc: "inc-a", incs: [], ver: 1, sid: "s1", sids: ["s1"], payload: .asset(file), blobs: [])
        var record = CloudRecordCodec.encode(header)
        record.systemFields = Data("tag".utf8)
        return record
    }
}
