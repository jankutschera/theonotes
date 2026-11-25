// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// `v16-cloudkit-native` and `CloudSyncStore` (CK-R4, CK-R5, CK-R15, CK-R21). The store is where
/// the invariants live: I1 (the base pair moves only through a successful save or an applied
/// merge), I3 (a success clears only what it covered) and the fence on quarantined entities.
@Suite struct CloudSyncStoreTests {
    let db: AppDatabase
    let store: CloudSyncStore
    let note = CloudEntityRef(entityType: "note", entityId: "n1")
    let other = CloudEntityRef(entityType: "note", entityId: "n2")

    init() throws {
        db = try AppDatabase.inMemory()
        store = CloudSyncStore(database: db)
    }

    // MARK: helpers

    private func count(_ table: String) throws -> Int {
        try db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)")! }
    }

    private func seedDirty(_ entity: CloudEntityRef, generation: Int64, localId: String? = nil) throws {
        try db.pool.write {
            try $0.execute(sql: "INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES(?,?,?,0)",
                           arguments: [entity.entityType, localId ?? entity.entityId, generation])
        }
    }

    private func dirtyGenerations() throws -> [String: Int64] {
        try db.pool.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT localId, generation FROM sync_dirty").map { ($0["localId"] as String, $0["generation"] as Int64) })
        }
    }

    private func seedPair(_ entity: CloudEntityRef, ver: Int64 = 3, inc: String = "inc-a", ancestor: String = "ancestor-3",
                          superseded: [String] = []) throws {
        try db.pool.write {
            try $0.execute(sql: "INSERT INTO ck_record(entityType,entityId,systemFields,ancestor,ver,inc,supersededIncs) VALUES(?,?,?,?,?,?,?)",
                           arguments: [entity.entityType, entity.entityId, Data("tag-\(ver)".utf8), Data(ancestor.utf8), ver, inc, CloudSyncStore.json(superseded)])
        }
    }

    private func pairRows() throws -> [Row] {
        try db.pool.read { try Row.fetchAll($0, sql: "SELECT * FROM ck_record ORDER BY entityType, entityId") }
    }

    private func attempt(_ entity: CloudEntityRef? = nil, generation: Int64 = 2, attemptId: String = "att-1", baseVer: Int64 = 3,
                         inc: String = "inc-a", base: Bool = true, accountGeneration: Int64? = nil) throws -> CloudInflight {
        CloudInflight(entity: entity ?? note, localId: (entity ?? note).entityId, generation: generation, attemptId: attemptId,
                      baseSystemFields: base ? Data("tag-\(baseVer)".utf8) : nil, baseAncestor: base ? Data("ancestor-\(baseVer)".utf8) : nil,
                      baseVer: base ? baseVer : 0, inc: inc, sealed: Data("sealed-\(attemptId)".utf8), blobRefs: ["h1"],
                      accountGeneration: try accountGeneration ?? store.generation())
    }

    private func remote(_ entity: CloudEntityRef? = nil, ver: Int64, inc: String = "inc-a", sid: String? = nil, sealed: String? = nil,
                        incs: [String] = [], tag: String? = nil) -> CloudRemoteVersion {
        CloudRemoteVersion(entity: entity ?? note, inc: inc, incs: incs, ver: ver, sid: sid ?? "sid-\(ver)", sids: [sid ?? "sid-\(ver)"],
                           systemFields: Data((tag ?? "rtag-\(ver)").utf8), sealed: Data((sealed ?? "remote-\(ver)").utf8),
                           blobRefs: ["h2"], rawFields: Data("raw-\(ver)".utf8),
                           pinnedAssets: [CloudPinnedAsset(field: "cipherAsset", path: "/tmp/pinned-\(ver)", size: 4, sha256: "abcd")])
    }

    private func quarantineUnsupported(_ entity: CloudEntityRef? = nil) throws {
        let name = (entity ?? note).recordName
        try store.quarantine(record: CloudQuarantineRecord(recordName: name, reason: "unsupported-version", v: 9, rawFields: Data("raw".utf8)),
                             pinned: [CloudPinnedAsset(field: "cipherAsset", path: "/tmp/pin-1", size: 3, sha256: "aa")])
    }

    // MARK: migration v16

    @Test func aFreshLibraryIsBoundToNothingAndHasEmptyCloudKitTables() throws {
        #expect(try store.backend() == .none)
        for table in ["ck_record", "ck_inflight", "ck_send_result", "ck_remote", "ck_quarantine", "ck_missing", "ck_blob_part"] {
            #expect(try count(table) == 0, "\(table)")
        }
        let state = try db.pool.read { try Row.fetchOne($0, sql: "SELECT * FROM ck_state")! }
        #expect(state["id"] as Int == 1 && state["generation"] as Int == 0 && state["zoneState"] as String == "unknown")
        #expect(state["fenced"] as Bool == false && state["recoveryState"] as String == "none")
    }

    @Test func aCloudflareBoundLibraryBecomesCloudflareAndAnUnboundOneStaysNone() throws {
        for (account, expected) in [("acct-1" as String?, "cloudflare"), (nil, "none")] {
            let queue = try DatabaseQueue()
            try Migrations.migrator.migrate(queue, upTo: "v15-focus")
            try queue.write { db in
                try db.execute(sql: "UPDATE sync_control SET accountId=?, enabled=? WHERE id=1", arguments: [account, account != nil])
            }
            try Migrations.migrator.migrate(queue)
            #expect(try queue.read { try String.fetchOne($0, sql: "SELECT backend FROM sync_control WHERE id=1") } == expected)
        }
    }

    @Test func theMigrationLeavesNotesAndTheJournalOfAnUnsyncedLibraryUntouched() throws {
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue, upTo: "v15-focus")
        func snapshot() throws -> [String] {
            try queue.read { db in
                try Row.fetchAll(db, sql: "SELECT id, text, title FROM note ORDER BY id").map { "\($0["id"] as String)|\($0["text"] as String)" }
                    + Row.fetchAll(db, sql: "SELECT entityType, localId, generation FROM sync_dirty ORDER BY 1,2").map { "\($0["localId"] as String)|\($0["generation"] as Int)" }
                    + Row.fetchAll(db, sql: "SELECT enabled, applying, accountId FROM sync_control").map { "\($0["enabled"] as Int)\($0["applying"] as Int)\(String(describing: $0["accountId"] as String?))" }
            }
        }
        let note = try queue.write { db -> String in
            try db.execute(sql: "INSERT INTO note(id,text,title,titleKey,createdAt,modifiedAt) VALUES('a','# A','A','a',?,?)", arguments: [Date(), Date()])
            try db.execute(sql: "INSERT INTO sync_dirty(entityType,localId,generation) VALUES('note','a',4)")
            return "a"
        }
        let before = try snapshot()
        try Migrations.migrator.migrate(queue)
        #expect(try snapshot() == before)
        #expect(note == "a")
    }

    @Test func theBackendColumnRejectsUnknownValues() throws {
        #expect(throws: (any Error).self) {
            try db.pool.write { try $0.execute(sql: "UPDATE sync_control SET backend='dropbox' WHERE id=1") }
        }
    }

    @Test func aCloudflareConfigureAfterTheMigrationStillBindsTheBackend() throws {
        // The Cloudflare engine is not edited and never writes `backend`; the trigger keeps it truthful.
        try SyncQueue(database: db).configure(accountID: "account")
        #expect(try store.backend() == .cloudflare)
        #expect(throws: CloudSyncStoreError.backendConflict(.cloudflare)) {
            try store.bind(accountId: "ck-1", containerId: "iCloud.test", zoneName: "TheoNotes", cloudUserHash: "u")
        }
    }

    // MARK: binding

    @Test func bindingToCloudKitSetsBackendAccountAndBumpsTheGeneration() throws {
        let generation = try store.bind(accountId: "ck-1", containerId: "iCloud.test", zoneName: "TheoNotes", cloudUserHash: "u1")
        #expect(generation == 1)
        #expect(try store.backend() == .cloudkit)
        #expect(try db.pool.read { try String.fetchOne($0, sql: "SELECT accountId FROM sync_control") } == "ck-1")
        // Same account again changes nothing; another account is refused.
        #expect(try store.bind(accountId: "ck-1", containerId: "iCloud.test", zoneName: "TheoNotes", cloudUserHash: "u1") == 1)
        #expect(throws: CloudSyncStoreError.accountConflict) {
            try store.bind(accountId: "ck-2", containerId: "iCloud.test", zoneName: "TheoNotes", cloudUserHash: "u2")
        }
    }

    // MARK: I3 and the one-transaction rule

    @Test func recordSavedClearsTheDirtyRowWhenTheGenerationsMatch() throws {
        try seedPair(note); try seedDirty(note, generation: 2)
        try store.insertInflight(attempt(generation: 2))
        #expect(try store.recordSaved(attemptId: "att-1", newSystemFields: Data("tag-4".utf8)) == .recorded(clearedDirty: true))
        #expect(try dirtyGenerations().isEmpty)
        let pair = try #require(try store.pair(for: note))
        #expect(pair.ver == 4 && pair.systemFields == Data("tag-4".utf8) && pair.ancestor == Data("sealed-att-1".utf8) && pair.inc == "inc-a")
        #expect(try count("ck_inflight") == 0)
    }

    @Test func successNeverClearsANewerDirtyGeneration() throws {
        try seedPair(note); try seedDirty(note, generation: 3)          // edited again while the g=2 snapshot was in flight
        try store.insertInflight(attempt(generation: 2))
        #expect(try store.recordSaved(attemptId: "att-1", newSystemFields: Data("tag-4".utf8)) == .recorded(clearedDirty: false))
        #expect(try dirtyGenerations() == ["n1": 3])
        #expect(try store.pair(for: note)?.ver == 4)                   // the pair still advances: the next publish builds on it
    }

    @Test func aSecondReportOfTheSameResultIsANoOp() throws {
        try seedPair(note); try seedDirty(note, generation: 2)
        try store.insertInflight(attempt())
        try store.recordSaved(attemptId: "att-1", newSystemFields: Data("tag-4".utf8))
        #expect(try store.recordSaved(attemptId: "att-1", newSystemFields: Data("tag-OTHER".utf8)) == .alreadyRecorded)
        #expect(try store.pair(for: note)?.systemFields == Data("tag-4".utf8))
    }

    @Test(arguments: ["recordSaved.afterPair", "recordSaved.afterInflightDelete", "recordSaved.afterDirtyDelete"])
    func recordSavedIsOneTransaction(_ crashAt: String) throws {
        struct Crash: Error {}
        let crashing = CloudSyncStore(database: db, boundary: { if $0 == crashAt { throw Crash() } })
        try seedPair(note); try seedDirty(note, generation: 2)
        try crashing.insertInflight(attempt())
        let pairBefore = try pairRows().map(\.description)
        #expect(throws: Crash.self) { try crashing.recordSaved(attemptId: "att-1", newSystemFields: Data("tag-4".utf8)) }
        // All three writes rolled back together: old pair, in-flight row kept, dirty row kept.
        #expect(try pairRows().map(\.description) == pairBefore)
        #expect(try count("ck_inflight") == 1)
        #expect(try dirtyGenerations() == ["n1": 2])
        // A restart with the same on-disk state then succeeds exactly once.
        #expect(try store.recordSaved(attemptId: "att-1", newSystemFields: Data("tag-4".utf8)) == .recorded(clearedDirty: true))
    }

    @Test func aFirstPublishCreatesThePairAtVersionOne() throws {
        try seedDirty(note, generation: 1)
        try store.insertInflight(attempt(generation: 1, baseVer: 0, inc: "inc-new", base: false))
        try store.recordSaved(attemptId: "att-1", newSystemFields: Data("tag-1".utf8))
        let pair = try #require(try store.pair(for: note))
        #expect(pair.ver == 1 && pair.inc == "inc-new" && pair.supersededIncs.isEmpty)
    }

    @Test func aNewIncarnationSupersedesTheOldOneAndLiftsThePause() throws {
        try seedPair(note, ver: 10, inc: "inc-a", superseded: ["inc-0"]); try seedDirty(note, generation: 1)
        try store.markMissing(entityType: "note", entityId: "n1", reason: "fullRefetch")
        let plan = try store.adoptIncarnation(entityType: "note", entityId: "n1", newInc: "inc-b")
        #expect(plan == CloudIncarnationPlan(inc: "inc-b", supersededIncs: ["inc-a", "inc-0"]))
        try store.insertInflight(attempt(generation: 1, baseVer: 0, inc: "inc-b", base: false))
        try store.recordSaved(attemptId: "att-1", newSystemFields: Data("tag-1".utf8))
        let pair = try #require(try store.pair(for: note))
        #expect(pair.ver == 1 && pair.inc == "inc-b" && pair.supersededIncs == ["inc-a", "inc-0"])
        #expect(try store.missing(entityType: "note", entityId: "n1") == nil)
    }

    @Test func aStaleAccountGenerationIsRefusedForPrepareAndForTheLateResult() throws {
        try seedPair(note)
        #expect(throws: CloudSyncStoreError.staleAccountGeneration(expected: 0, actual: 7)) {
            try store.insertInflight(attempt(accountGeneration: 7))
        }
        try store.insertInflight(attempt())
        try store.bumpGeneration()                                     // account switched during the send
        #expect(throws: CloudSyncStoreError.staleAccountGeneration(expected: 1, actual: 0)) {
            try store.recordSaved(attemptId: "att-1", newSystemFields: Data("late".utf8))
        }
        #expect(try store.pair(for: note)?.ver == 3)
        #expect(try count("ck_inflight") == 1)
    }

    @Test func onlyOneSnapshotPerEntityIsInFlight() throws {
        try seedPair(note)
        try store.insertInflight(attempt())
        #expect(throws: CloudSyncStoreError.inflightExists(note.recordName)) { try store.insertInflight(attempt(attemptId: "att-2")) }
    }

    // MARK: receive ordering

    @Test func storeRemoteIgnoresLowerAndEqualVersionsOfTheHeldPairAndTheStoredRemote() throws {
        try seedPair(note, ver: 3)
        #expect(try store.storeRemote(remote(ver: 2)) == .ignoredStale)
        let heldTag = String(decoding: try #require(try store.pair(for: note)).systemFields, as: UTF8.self)
        #expect(try store.storeRemote(remote(ver: 3, sealed: "ancestor-3", tag: heldTag)) == .echo)       // echo of our own save: same tag
        #expect(try count("ck_remote") == 0)
        #expect(try count("ck_quarantine") == 0)
        #expect(try store.storeRemote(remote(ver: 5)) == .stored)
        #expect(try store.storeRemote(remote(ver: 4)) == .ignoredStale)                       // stale after a newer one
        #expect(try store.storeRemote(remote(ver: 5)) == .echo)                               // redelivery
        #expect(try store.remote(recordName: note.recordName)?.ver == 5)
    }

    @Test func versionsDeliveredOutOfOrderNeverRegress() throws {
        for order in [[5, 3], [3, 5], [5, 3, 4]] as [[Int64]] {
            try db.pool.write { try $0.execute(sql: "DELETE FROM ck_remote") }
            for ver in order { try store.storeRemote(remote(ver: ver)) }
            #expect(try store.remote(recordName: note.recordName)?.ver == 5, "\(order)")
        }
    }

    @Test func divergentEqualVersionIsQuarantinedAndFencesTheEntity() throws {
        try seedPair(note, ver: 3)
        #expect(try store.storeRemote(remote(ver: 3, sealed: "something-else")) == .quarantinedDivergent(obsoletePinnedPaths: []))
        let row = try #require(try store.quarantineRows().first)
        #expect(row.recordName == note.recordName && row.reason == "divergent-version" && row.entity == note)
        #expect(row.pinnedAssets.map(\.path) == ["/tmp/pinned-3"])
        #expect(try store.isFenced(entityType: "note", entityId: "n1"))
        #expect(try count("ck_remote") == 0)

        // Same for two different attempts claiming one version in ck_remote.
        try store.storeRemote(remote(other, ver: 5, sid: "x"))
        #expect(try store.storeRemote(remote(other, ver: 5, sid: "y")) == .quarantinedDivergent(obsoletePinnedPaths: []))
        #expect(try store.isFenced(entityType: "note", entityId: "n2"))
    }

    @Test func versionIsNeverComparedAcrossIncarnationsButAKnownSupersededOneIsIgnoredWhenIncremental() throws {
        try seedPair(note, ver: 10, inc: "inc-b", superseded: ["inc-a"])
        // A new incarnation with a low ver is followed, not ignored as "older".
        #expect(try store.storeRemote(remote(ver: 1, inc: "inc-c", incs: ["inc-b", "inc-a"])) == .stored)
        // A late delivery of a known superseded history: ignored incrementally ...
        try db.pool.write { try $0.execute(sql: "DELETE FROM ck_remote") }
        #expect(try store.storeRemote(remote(ver: 12, inc: "inc-a")) == .ignoredSupersededIncarnation)
        // ... but followed inside a full refetch and for a serverRecordChanged.
        #expect(try store.storeRemote(remote(ver: 12, inc: "inc-a"), delivery: .fullRefetch) == .stored)
        try db.pool.write { try $0.execute(sql: "DELETE FROM ck_remote") }
        #expect(try store.storeRemote(remote(ver: 12, inc: "inc-a"), delivery: .serverRecordChanged) == .stored)
    }

    @Test func aStoredIncarnationIsNotReplacedByALateOneItSupersedes() throws {
        try store.storeRemote(remote(ver: 1, inc: "inc-b", incs: ["inc-a"]))
        #expect(try store.storeRemote(remote(ver: 9, inc: "inc-a")) == .ignoredSupersededIncarnation)
        #expect(try store.remote(recordName: note.recordName)?.inc == "inc-b")
        // A full refetch is an authoritative picture and a serverRecordChanged is always followed.
        #expect(try store.storeRemote(remote(ver: 9, inc: "inc-a"), delivery: .fullRefetch) == .stored)
        try store.storeRemote(remote(ver: 1, inc: "inc-b", incs: ["inc-a"]), delivery: .serverRecordChanged)
        #expect(try store.remote(recordName: note.recordName)?.inc == "inc-b")
        #expect(try store.storeRemote(remote(ver: 9, inc: "inc-a"), delivery: .serverRecordChanged) == .stored)
    }

    // MARK: I1

    @Test func pairOnlyChangesViaSavedOrApplied() throws {
        try seedPair(note, ver: 3); try seedPair(other, ver: 3)
        try seedDirty(other, generation: 1)
        let before = try pairRows().map(\.description)

        // Everything a fetch, a quarantine, a pause or an account event can do:
        try store.storeRemote(remote(ver: 8))
        try store.storeRemote(remote(ver: 3, sealed: "diverged"))
        try quarantineUnsupported(note)
        try store.releaseQuarantine(recordName: note.recordName)
        try quarantineUnsupported(note)
        try store.ignoreQuarantine(recordName: note.recordName)
        try store.markMissing(entityType: "note", entityId: "n1", reason: "x")
        _ = try store.adoptIncarnation(entityType: "note", entityId: "n1", newInc: "inc-z")
        try store.clearMissing(entityType: "note", entityId: "n1")
        try store.setZoneState(.created); try store.setZoneState(.removed(.deleted))
        try store.bumpGeneration()
        try store.saveEngineState(Data("s".utf8), accountGeneration: store.generation()); try store.clearEngineState()
        try store.setAccountFenced(true); try store.setAccountFenced(false)     // the flag itself writes no pair (while up it refuses writes, CK-R92)
        try store.setWaiting(recordName: note.recordName, .unlock)
        #expect(try pairRows().map(\.description) == before)

        // Applying a stored version is one of the two writers.
        try store.recordApplied(accountGeneration: store.generation(), remote: try #require(try store.remote(recordName: note.recordName)), ancestor: Data("merged".utf8), releasingQuarantine: true)
        #expect(try store.pair(for: note)?.ver == 8)
        // Saving is the other.
        try store.insertInflight(attempt(other, attemptId: "att-9", baseVer: 3))
        try store.recordSaved(attemptId: "att-9", newSystemFields: Data("tag-4".utf8))
        #expect(try store.pair(for: other)?.ver == 4)
    }

    @Test func recordApplyIsOneTransactionWithTheLibraryWrite() throws {
        struct Crash: Error {}
        try seedPair(note, ver: 3)
        let stored = remote(ver: 5)
        try store.storeRemote(stored)
        let pairBefore = try pairRows().map(\.description)

        for crashAfter in ["recordApplied.afterLibraryWrite", "recordApplied.afterPair"] {
            let crashing = CloudSyncStore(database: db, boundary: { if $0 == crashAfter { throw Crash() } })
            #expect(throws: Crash.self) {
                try crashing.recordApplied(accountGeneration: store.generation(), remote: stored, ancestor: Data("merged".utf8)) { db in
                    try db.execute(sql: "INSERT INTO note(id,text,title,titleKey,createdAt,modifiedAt) VALUES('applied','# x','x','x',?,?)", arguments: [Date(), Date()])
                }
            }
            #expect(try pairRows().map(\.description) == pairBefore)                        // old pair
            #expect(try count("note") == 0)                                                    // old library
            #expect(try store.remote(recordName: note.recordName) != nil)                      // still to apply
        }
        // The library write itself failing leaves the pair alone too.
        #expect(throws: Crash.self) { try store.recordApplied(accountGeneration: store.generation(), remote: stored, ancestor: Data("m".utf8)) { _ in throw Crash() } }
        #expect(try pairRows().map(\.description) == pairBefore)

        try store.recordApplied(accountGeneration: store.generation(), remote: stored, ancestor: Data("merged".utf8)) { db in
            try db.execute(sql: "INSERT INTO note(id,text,title,titleKey,createdAt,modifiedAt) VALUES('applied','# x','x','x',?,?)", arguments: [Date(), Date()])
        }
        #expect(try count("note") == 1)
        #expect(try store.pair(for: note)?.ver == 5)
        #expect(try store.pair(for: note)?.ancestor == Data("merged".utf8))
        #expect(try store.remote(recordName: note.recordName) == nil)
    }

    @Test func applyKeepsANewerStoredVersionAndRefusesToRegressThePair() throws {
        try seedPair(note, ver: 3)
        let five = remote(ver: 5), seven = remote(ver: 7)
        try store.storeRemote(five)
        try store.storeRemote(seven)                                   // arrived while five was being applied
        try store.recordApplied(accountGeneration: store.generation(), remote: five, ancestor: Data("m5".utf8))
        #expect(try store.remote(recordName: note.recordName)?.ver == 7)
        #expect(throws: CloudSyncStoreError.wouldRegressPair(note.recordName)) {
            try store.recordApplied(accountGeneration: store.generation(), remote: remote(ver: 4), ancestor: Data("m4".utf8))
        }
    }

    @Test func applyingANewIncarnationAdoptsItAndRemembersTheOldOne() throws {
        try seedPair(note, ver: 10, inc: "inc-a")
        let fresh = remote(ver: 1, inc: "inc-b", incs: ["inc-a"])
        try store.storeRemote(fresh)
        try store.recordApplied(accountGeneration: store.generation(), remote: fresh, ancestor: Data("m".utf8))
        let pair = try #require(try store.pair(for: note))
        #expect(pair.inc == "inc-b" && pair.ver == 1 && pair.supersededIncs == ["inc-a"])
    }

    // MARK: fence

    @Test func fenceBlocksPrepareSubmitAndBasePairUpdateWhileQuarantined() throws {
        try seedPair(note, ver: 3); try seedPair(other, ver: 3)
        try seedDirty(note, generation: 2); try seedDirty(other, generation: 2)
        try store.insertInflight(attempt(note, attemptId: "in-flight-before"))      // prepared before the unreadable record arrived
        try quarantineUnsupported(note)
        let pairsBefore = try pairRows().map(\.description)
        #expect(try store.isFenced(entityType: "note", entityId: "n1"))

        // prepare
        #expect(throws: CloudSyncStoreError.entityFenced(note.recordName)) { try store.insertInflight(attempt(note, attemptId: "att-new")) }
        // submit
        #expect(throws: CloudSyncStoreError.entityFenced(note.recordName)) { try store.markInflight(attemptId: "in-flight-before", state: .sending) }
        // base pair update through a save result and through an apply of any other version
        #expect(throws: CloudSyncStoreError.entityFenced(note.recordName)) {
            try store.recordSaved(attemptId: "in-flight-before", newSystemFields: Data("tag-4".utf8))
        }
        #expect(throws: CloudSyncStoreError.entityFenced(note.recordName)) {
            try store.recordApplied(accountGeneration: store.generation(), remote: remote(ver: 9), ancestor: Data("m".utf8))
        }
        #expect(try pairRows().map(\.description) == pairsBefore)
        #expect(try dirtyGenerations() == ["n1": 2, "n2": 2])                           // nothing lost, nothing cleared
        #expect(try store.inflight(attemptId: "in-flight-before") != nil)

        // Other entities are not fenced.
        #expect(try !store.isFenced(entityType: "note", entityId: "n2"))
        try store.insertInflight(attempt(other, attemptId: "att-other"))
        try store.markInflight(attemptId: "att-other", state: .sending)
        try store.recordSaved(attemptId: "att-other", newSystemFields: Data("tag-4".utf8))
        #expect(try store.pair(for: other)?.ver == 4)
    }

    @Test func theFenceLiftsWhenTheQuarantineIsReleasedOrTheItemIsIgnored() throws {
        try seedPair(note)
        try quarantineUnsupported()
        #expect(try store.releaseQuarantine(recordName: note.recordName) == ["/tmp/pin-1"])
        #expect(try !store.isFenced(entityType: "note", entityId: "n1"))
        try store.insertInflight(attempt())

        try quarantineUnsupported()
        #expect(try store.ignoreQuarantine(recordName: note.recordName) == ["/tmp/pin-1"])
        #expect(try !store.isFenced(entityType: "note", entityId: "n1"))
        #expect(try store.quarantineRows().first?.ignoredByUser == true)
        #expect(try store.quarantineRows().first?.pinnedAssets.isEmpty == true)
        try store.markInflight(attemptId: "att-1", state: .sending)
    }

    @Test func aVersionTheAppNowUnderstandsIsAppliedAndReleasesItsOwnQuarantineInOneTransaction() throws {
        try seedPair(note)
        try quarantineUnsupported()
        let understood = remote(ver: 9)
        try store.storeRemote(understood)
        let released = try store.recordApplied(accountGeneration: store.generation(), remote: understood, ancestor: Data("m".utf8), releasingQuarantine: true)
        #expect(released == ["/tmp/pin-1"])
        #expect(try store.quarantineRows().isEmpty)
        #expect(try !store.isFenced(entityType: "note", entityId: "n1"))
        #expect(try store.pair(for: note)?.ver == 9)
    }

    @Test func aNameThatNamesNoEntityFencesNothing() throws {
        for name in ["b.abc.4.0", "keybundle", "e.", "e.note", "e..x", "garbage"] {
            try store.quarantine(record: CloudQuarantineRecord(recordName: name, reason: "corrupt", rawFields: Data("r".utf8)), pinned: [])
        }
        #expect(try store.quarantineRows().allSatisfy { $0.entity == nil })
        try seedPair(note)
        try store.insertInflight(attempt())
        #expect(CloudEntityRef.parse(recordName: "e.setting.some.key.with.dots") == CloudEntityRef(entityType: "setting", entityId: "some.key.with.dots"))
    }

    @Test func quarantineKeepsTheRowAndItsPinnedPathsTogetherAndRepeatsCountAttempts() throws {
        try quarantineUnsupported()
        try quarantineUnsupported()
        var row = try #require(try store.quarantineRows().first)
        #expect(row.attempts == 1 && row.pinnedAssets == [CloudPinnedAsset(field: "cipherAsset", path: "/tmp/pin-1", size: 3, sha256: "aa")])
        try store.ignoreQuarantine(recordName: note.recordName)
        // The same unreadable version stays ignored; a different version of the record is a new item.
        try quarantineUnsupported()
        #expect(try store.quarantineRows().first?.ignoredByUser == true)
        try store.quarantine(record: CloudQuarantineRecord(recordName: note.recordName, reason: "unsupported-version", v: 10, rawFields: Data("raw-2".utf8)), pinned: [])
        row = try #require(try store.quarantineRows().first)
        #expect(row.ignoredByUser == false && row.attempts == 0 && row.v == 10)
    }

    // MARK: absence (CK-R5)

    @Test func aMissingEntityIsPausedKeepsItsPairAndCanOnlyBePreparedAsANewIncarnation() throws {
        try seedPair(note, ver: 4, inc: "inc-a")
        #expect(throws: CloudSyncStoreError.noBasePair(other.recordName)) { try store.markMissing(entityType: "note", entityId: "n2", reason: "x") }
        try store.markMissing(entityType: "note", entityId: "n1", reason: "fullRefetch")
        #expect(try store.allMissing() == [CloudMissingRow(entity: note, lastVer: 4, lastInc: "inc-a", reason: "fullRefetch")])
        #expect(try store.pair(for: note)?.ver == 4)
        #expect(throws: CloudSyncStoreError.entityPaused(note.recordName)) { try store.insertInflight(attempt()) }
        #expect(throws: (any Error).self) { try store.adoptIncarnation(entityType: "note", entityId: "n1", newInc: "inc-a") }
        try store.insertInflight(attempt(baseVer: 0, inc: "inc-b", base: false))
    }

    // MARK: zone and engine state (CK-R15)

    @Test func zoneStateChangesBumpTheGenerationOnceAndRecordTheReason() throws {
        #expect(try store.generation() == 0)
        try store.setZoneState(.created)
        try store.setZoneState(.created)
        #expect(try store.generation() == 1)
        try store.setZoneState(.removed(.userDeletedZone))
        #expect(try store.zoneState() == .removed(.userDeletedZone))
        #expect(try store.generation() == 2)
        try store.setZoneState(.unknown)
        #expect(try store.zoneState() == .unknown)
        #expect(try db.pool.read { try String.fetchOne($0, sql: "SELECT zoneRemovedReason FROM ck_state") } == nil)
    }

    @Test func engineStateIsSavedClearedAndRefusedFromAnOlderGeneration() throws {
        try store.saveEngineState(Data("s1".utf8), accountGeneration: 0)
        #expect(try store.engineState() == Data("s1".utf8))
        try store.bumpGeneration()
        #expect(throws: CloudSyncStoreError.staleAccountGeneration(expected: 1, actual: 0)) {
            try store.saveEngineState(Data("late".utf8), accountGeneration: 0)
        }
        #expect(try store.engineState() == Data("s1".utf8))
        try store.clearEngineState()
        #expect(try store.engineState() == nil)
    }

    @Test func sendResultsAreStoredOnceAndConsumedByTheSave() throws {
        try seedPair(note); try seedDirty(note, generation: 2)
        try store.insertInflight(attempt())
        try store.recordSendResult(attemptId: "att-1", accountGeneration: 0, outcome: .offline)
        try store.recordSendResult(attemptId: "att-1", accountGeneration: 0, outcome: .quotaExceeded)
        #expect(try store.sendResult(attemptId: "att-1")?.outcome == .offline)
        try store.recordSaved(attemptId: "att-1", newSystemFields: Data("tag-4".utf8))
        #expect(try store.sendResult(attemptId: "att-1") == nil)
    }

    // MARK: fix round 1 (Codex review of Task 3)

    private func bindCloudKit(account: String = "ck-1") throws -> Int64 {
        try store.bind(accountId: account, containerId: "iCloud.test", zoneName: "TheoNotes", cloudUserHash: "u")
    }

    /// I1: a delayed callback of an old account must not write the library or recreate a pair.
    @Test func aDelayedApplyFromTheOldAccountAfterDetachAndRebindWritesNothing() throws {
        let oldGeneration = try bindCloudKit()
        try seedPair(note, ver: 3)
        let stale = remote(ver: 5)
        try store.storeRemote(stale)
        try db.pool.write {
            try $0.execute(sql: "INSERT INTO backup_catalog(id,filename,createdAt,plaintextNoteIds) VALUES('b1','b1.baerchen-backup',?,'[]')", arguments: [Date()])
        }
        try SyncAccountDetach.detach(database: db, expectedBackend: .cloudkit, verifiedBackupID: "b1")
        let newGeneration = try bindCloudKit(account: "ck-2")
        #expect(newGeneration > oldGeneration)

        var libraryWritten = false
        #expect(throws: CloudSyncStoreError.staleAccountGeneration(expected: newGeneration, actual: oldGeneration)) {
            try store.recordApplied(accountGeneration: oldGeneration, remote: stale, ancestor: Data("m".utf8)) { _ in libraryWritten = true }
        }
        #expect(!libraryWritten)
        #expect(try pairRows().isEmpty)
        #expect(try count("note") == 0)
        // The same call with the current generation is fine.
        try store.storeRemote(stale)
        try store.recordApplied(accountGeneration: newGeneration, remote: stale, ancestor: Data("m".utf8))
        #expect(try store.pair(for: note)?.ver == 5)
    }

    /// I2: the same attempt id with different content is not an echo.
    @Test func theSameSidWithADifferentPayloadIsDivergentNotAnEcho() throws {
        try store.storeRemote(remote(ver: 5, sid: "s", sealed: "payload-A"))
        #expect(try store.storeRemote(remote(ver: 5, sid: "s", sealed: "payload-A")) == .echo)
        #expect(try store.storeRemote(remote(ver: 5, sid: "s", sealed: "payload-B")) == .quarantinedDivergent(obsoletePinnedPaths: []))
        #expect(try store.isFenced(entityType: "note", entityId: "n1"))
        #expect(try store.remote(recordName: note.recordName)?.sealed == Data("payload-A".utf8))     // the stored one is kept
    }

    @Test func aDigestOfAnAssetPayloadIsComparedToo() throws {
        func viaAsset(_ hash: String) -> CloudRemoteVersion {
            CloudRemoteVersion(entity: note, inc: "inc-a", ver: 5, sid: "s", sids: ["s"], systemFields: Data("t".utf8),
                               sealed: nil, sealedPath: "/tmp/pinned-asset", sealedSha256: hash, blobRefs: ["h2"])
        }
        try store.storeRemote(viaAsset("aa"))
        #expect(try store.storeRemote(viaAsset("aa")) == .echo)
        #expect(try store.storeRemote(viaAsset("bb")) == .quarantinedDivergent(obsoletePinnedPaths: []))
        // An inline copy and an asset copy of the same bytes are the same content.
        try db.pool.write { try $0.execute(sql: "DELETE FROM ck_remote; DELETE FROM ck_quarantine") }
        try store.storeRemote(remote(ver: 5, sid: "s", sealed: "abc"))
        #expect(try store.storeRemote(viaAsset(CloudSyncStore.sha256Hex(Data("abc".utf8)))) == .echo)
    }

    /// Echo means the whole stored envelope is the same, not only attempt id and payload.
    @Test func aMatchingSidWithDifferentBlobRefsOrHistoryIsDivergent() throws {
        func base() -> CloudRemoteVersion { remote(ver: 5, inc: "inc-b", sid: "s", sealed: "same", incs: ["inc-a"]) }
        let variants: [(String, (inout CloudRemoteVersion) -> Void)] = [
            ("blobRefs", { $0.blobRefs = ["other-blob"] }),
            ("blobRefs order", { $0.blobRefs = ["h2", "h3"] }),
            ("incarnation history", { $0.incs = ["inc-z"] }),
            ("sids chain", { $0.sids = ["s", "older"] }),
        ]
        for (name, change) in variants {
            try db.pool.write { try $0.execute(sql: "DELETE FROM ck_remote; DELETE FROM ck_quarantine") }
            var stored = base()
            if name == "blobRefs order" { stored.blobRefs = ["h3", "h2"] }
            try store.storeRemote(stored)
            var changed = base()
            change(&changed)
            #expect(try store.storeRemote(changed) == .quarantinedDivergent(obsoletePinnedPaths: []), "\(name)")
            #expect(try store.isFenced(entityType: "note", entityId: "n1"), "\(name)")
        }
    }

    @Test func aChangedSystemFieldsTagAloneIsStillAnEcho() throws {
        try store.storeRemote(remote(ver: 5, sid: "s", sealed: "same", tag: "tag-1"))
        #expect(try store.storeRemote(remote(ver: 5, sid: "s", sealed: "same", tag: "tag-2")) == .echo)
        #expect(try store.quarantineRows().isEmpty)
    }

    /// I3: A to B to authoritative A, then further deliveries.
    @Test func aSupersededIncarnationFollowedAuthoritativelyNeverListsItselfAsSuperseded() throws {
        try seedPair(note, ver: 4, inc: "inc-a")
        let toB = remote(ver: 1, inc: "inc-b", incs: ["inc-a"])
        try store.storeRemote(toB)
        try store.recordApplied(accountGeneration: store.generation(), remote: toB, ancestor: Data("mB".utf8))
        #expect(try store.pair(for: note)?.supersededIncs == ["inc-a"])

        // A full refetch finds inc-a again (a Console undo); its record names inc-b in its history.
        let backToA = remote(ver: 6, inc: "inc-a", incs: ["inc-b"])
        #expect(try store.storeRemote(backToA, delivery: .fullRefetch) == .stored)
        try store.recordApplied(accountGeneration: store.generation(), remote: backToA, ancestor: Data("mA".utf8))
        var pair = try #require(try store.pair(for: note))
        #expect(pair.inc == "inc-a" && pair.supersededIncs == ["inc-b"])
        #expect(!pair.supersededIncs.contains(pair.inc))

        // Subsequent deliveries: the now-superseded B is ignored incrementally, A moves on normally.
        #expect(try store.storeRemote(remote(ver: 9, inc: "inc-b")) == .ignoredSupersededIncarnation)
        #expect(try store.storeRemote(remote(ver: 7, inc: "inc-a")) == .stored)
        // A saved version of A keeps the invariant too.
        try db.pool.write { try $0.execute(sql: "DELETE FROM ck_remote") }
        try seedDirty(note, generation: 1)
        try store.insertInflight(attempt(generation: 1, baseVer: 6, inc: "inc-a"))
        try store.recordSaved(attemptId: "att-1", newSystemFields: Data("tag-7".utf8))
        pair = try #require(try store.pair(for: note))
        #expect(pair.inc == "inc-a" && pair.supersededIncs == ["inc-b"])
    }

    @Test func aSupersededIncarnationIdCanNotBeReusedForANewIncarnationOrASave() throws {
        try seedPair(note, ver: 2, inc: "inc-b", superseded: ["inc-a"])
        try store.markMissing(entityType: "note", entityId: "n1", reason: "x")
        #expect(throws: CloudSyncStoreError.incarnationReused("inc-a")) {
            try store.adoptIncarnation(entityType: "note", entityId: "n1", newInc: "inc-a")
        }
        #expect(throws: CloudSyncStoreError.incarnationReused("inc-a")) {
            try store.insertInflight(attempt(baseVer: 0, inc: "inc-a", base: false))
        }
        // A genuinely new id is fine.
        _ = try store.adoptIncarnation(entityType: "note", entityId: "n1", newInc: "inc-c")
    }

    @Test func recordSavedNeverListsTheCurrentIncarnationAsSuperseded() throws {
        // Defensive: a pair whose history somehow lists the incarnation being saved.
        try seedPair(note, ver: 3, inc: "inc-b", superseded: ["inc-a"])
        try db.pool.write { try $0.execute(sql: "UPDATE ck_record SET supersededIncs='[\"inc-b\",\"inc-a\"]'") }
        try seedDirty(note, generation: 2)
        try store.insertInflight(attempt(baseVer: 3, inc: "inc-b"))
        try store.recordSaved(attemptId: "att-1", newSystemFields: Data("tag-4".utf8))
        #expect(try store.pair(for: note)?.supersededIncs == ["inc-a"])
    }

    /// I4: pinned files stay owned by exactly the rows that reference them.
    @Test func replacingAQuarantineRowReturnsOnlyThePinnedFilesNothingReferencesAnyMore() throws {
        func pin(_ names: [String]) -> [CloudPinnedAsset] { names.map { CloudPinnedAsset(field: "f-\($0)", path: "/tmp/\($0)", size: 1, sha256: "h") } }
        func record(_ raw: String) -> CloudQuarantineRecord {
            CloudQuarantineRecord(recordName: note.recordName, reason: "unsupported-version", v: 9, rawFields: Data(raw.utf8))
        }
        #expect(try store.quarantine(record: record("one"), pinned: pin(["a", "b"])) == [])
        // The same record again with the same assets: nothing is obsolete.
        #expect(try store.quarantine(record: record("one"), pinned: pin(["a", "b"])) == [])
        // A changed record keeps "b" and drops "a".
        #expect(try store.quarantine(record: record("two"), pinned: pin(["b", "c"])) == ["/tmp/a"])
        #expect(try store.quarantineRows().first?.pinnedAssets.map(\.path) == ["/tmp/b", "/tmp/c"])
        // A path the same record's stored version still references is never returned.
        try store.storeRemote(CloudRemoteVersion(entity: note, inc: "i", ver: 1, sid: "s", systemFields: Data("t".utf8), sealedPath: "/tmp/c", sealedSha256: "h"))
        #expect(try store.quarantine(record: record("three"), pinned: []) == ["/tmp/b"])
        #expect(try store.releaseQuarantine(recordName: note.recordName) == [])
    }

    @Test func aPinnedPathBelongsToOneRecord() throws {
        let asset = CloudPinnedAsset(field: "cipherAsset", path: "/tmp/shared", size: 1, sha256: "h")
        try store.quarantine(record: CloudQuarantineRecord(recordName: note.recordName, reason: "corrupt", rawFields: Data("x".utf8)), pinned: [asset])
        #expect(throws: CloudSyncStoreError.pinnedPathReused("/tmp/shared")) {
            try store.quarantine(record: CloudQuarantineRecord(recordName: other.recordName, reason: "corrupt", rawFields: Data("y".utf8)), pinned: [asset])
        }
        #expect(throws: CloudSyncStoreError.pinnedPathReused("/tmp/shared")) {
            try store.storeRemote(CloudRemoteVersion(entity: other, inc: "i", ver: 1, sid: "s", systemFields: Data("t".utf8), sealedPath: "/tmp/shared", sealedSha256: "h"))
        }
        #expect(try store.quarantineRows().count == 1)
        #expect(try count("ck_remote") == 0)
    }

    /// Cleanup race: a path handed back for deletion can never gain a new reference, because every
    /// pin takes a fresh path.
    @Test func pinReleasePinAgainUsesANewPathSoDeletingTheOldOneLeavesTheNewOneIntact() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ck-pins-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bytes = Data("the same asset".utf8)
        func pin() throws -> CloudPinnedAsset {
            let relative = CloudSyncStore.newPinnedPath(recordName: note.recordName, field: "cipherAsset")
            let url = folder.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
            return CloudPinnedAsset(field: "cipherAsset", path: relative, size: Int64(bytes.count), sha256: CloudSyncStore.sha256Hex(bytes))
        }
        let record = CloudQuarantineRecord(recordName: note.recordName, reason: "unsupported-version", v: 9, rawFields: Data("raw".utf8))
        let first = try pin()
        try store.quarantine(record: record, pinned: [first])
        let handedBack = try store.releaseQuarantine(recordName: note.recordName)
        #expect(handedBack == [first.path])

        let second = try pin()                                          // the same asset, pinned again before the delete ran
        #expect(second.path != first.path)
        try store.quarantine(record: record, pinned: [second])

        for path in handedBack { try FileManager.default.removeItem(at: folder.appendingPathComponent(path)) }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(first.path).path))
        #expect(try Data(contentsOf: folder.appendingPathComponent(second.path)) == bytes)
        #expect(try store.quarantineRows().first?.pinnedAssets.map(\.path) == [second.path])
    }

    @Test func aDivergentRecordThatReplacesAQuarantineRowReturnsItsObsoleteFiles() throws {
        try seedPair(note, ver: 3)
        try store.quarantine(record: CloudQuarantineRecord(recordName: note.recordName, reason: "unsupported-version", rawFields: Data("old".utf8)),
                             pinned: [CloudPinnedAsset(field: "cipherAsset", path: "/tmp/old-pin", size: 1, sha256: "h")])
        var diverged = remote(ver: 3, sealed: "something-else")
        diverged.pinnedAssets = [CloudPinnedAsset(field: "cipherAsset", path: "/tmp/new-pin", size: 1, sha256: "h")]
        #expect(try store.storeRemote(diverged) == .quarantinedDivergent(obsoletePinnedPaths: ["/tmp/old-pin"]))
    }
}
