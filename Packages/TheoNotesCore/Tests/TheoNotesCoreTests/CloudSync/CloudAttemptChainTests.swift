// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// CK-R70: the attempt-id chain is stored with the base pair (migration v17) and extended by every saver.
@Suite struct CloudAttemptChainTests {
    let entity = CloudEntityRef(entityType: "note", entityId: "n1")

    @Test func v17AddsTheChainColumnsAndLeavesExistingPairsWithAnEmptyChain() throws {
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue, upTo: "v16-cloudkit-native")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO ck_record(entityType,entityId,systemFields,ancestor,ver,inc) VALUES('note','n1',x'01',x'02',3,'inc-a')
                """)
        }
        try Migrations.migrator.migrate(queue)
        let (chain, columns) = try queue.read { db -> (String?, [String]) in
            (try String.fetchOne(db, sql: "SELECT sids FROM ck_record WHERE entityId='n1'"),
             try Row.fetchAll(db, sql: "PRAGMA table_info(ck_inflight)").map { $0["name"] as String })
        }
        #expect(chain == "[]")
        #expect(columns.contains("sids"))
    }

    @Test func recordSavedStoresTheChainThatWasSentAndRecordAppliedTheChainOfTheAppliedVersion() throws {
        let store = CloudSyncStore(database: try AppDatabase.inMemory())
        let generation = try store.bind(accountId: "ck-1", containerId: "iCloud.test", zoneName: "TheoNotes", cloudUserHash: "u")
        try store.database.pool.write {
            try $0.execute(sql: "INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('note','n1',1,0)")
        }
        try store.insertInflight(CloudInflight(entity: entity, localId: "n1", generation: 1, attemptId: "att-2", baseSystemFields: nil,
                                               inc: "inc-a", sealed: Data("s".utf8), accountGeneration: generation, sids: ["att-2", "att-1"]))
        try store.recordSaved(attemptId: "att-2", newSystemFields: Data("t".utf8))
        #expect(try store.pair(for: entity)?.sids == ["att-2", "att-1"])
        let remote = CloudRemoteVersion(entity: entity, inc: "inc-a", ver: 3, sid: "att-9", sids: ["att-9", "att-2", "att-1"],
                                        systemFields: Data("t3".utf8), sealed: Data("r".utf8))
        try store.recordApplied(accountGeneration: generation, remote: remote, ancestor: Data("r".utf8))
        #expect(try store.pair(for: entity)?.sids == ["att-9", "att-2", "att-1"])
    }

    @Test func aDeviceThatMergedAVersionThenSavesExtendsItsChain() async throws {
        let (world, a, b, id) = try await CloudOutcomeResolverTests.synced(); defer { world.cleanup() }
        let first = try #require(await world.account.record(named: "e.note.\(id)"))
        try b.edit(id, "# T\nbase\nB\n")
        try await b.publish()
        try await a.sync()                                                     // A merges B's version 2
        try a.edit(id, "# T\nbase\nB\nA\n")
        try await a.publish()
        let record = try #require(await world.account.record(named: "e.note.\(id)"))
        #expect(record.ver == 3 && record.sids.count == 3 && record.sids.last == first.sid)   // A's, B's, then the first author's
    }

    @Test func theInflightRowKeepsExactlyTheChainThatWasPrepared() async throws {
        let world = try await PublisherWorld.make(1); defer { world.cleanup() }
        let a = world.devices[0]
        let note = try a.noteStore.create(text: "# C\n")
        let made = try await a.publisher.prepare()
        #expect(made.first?.sids == [made.first!.attemptId])
        #expect(try a.store.inflight(for: a.ref(note.id))?.sids == made.first?.sids)
    }

    @Test func interruptSendingTurnsOnlySendingRowsIntoUnknownAndOrphanResultsAreDeleted() throws {
        let store = CloudSyncStore(database: try AppDatabase.inMemory())
        let generation = try store.bind(accountId: "ck-1", containerId: "iCloud.test", zoneName: "TheoNotes", cloudUserHash: "u")
        for (id, state) in [("a", CloudInflight.State.sending), ("b", .prepared), ("c", .unknown)] {
            try store.insertInflight(CloudInflight(entity: CloudEntityRef(entityType: "note", entityId: id), localId: id, generation: 1, attemptId: "att-\(id)",
                                                   inc: "inc", sealed: Data(), state: state, accountGeneration: generation))
        }
        #expect(try store.interruptSending() == 1)
        #expect(try store.allInflight().map(\.state) == [.unknown, .prepared, .unknown])
        try store.recordSendResult(attemptId: "att-a", accountGeneration: generation, outcome: .offline)
        try store.recordSendResult(attemptId: "att-gone", accountGeneration: generation, outcome: .offline)
        #expect(try store.deleteOrphanSendResults() == 1)
        #expect(try store.sendResult(attemptId: "att-a") != nil && store.sendResult(attemptId: "att-gone") == nil)
    }
}
