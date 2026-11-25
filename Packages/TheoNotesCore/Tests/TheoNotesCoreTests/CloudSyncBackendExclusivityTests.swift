// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// C1 of the Task 3 review: a library belongs to one backend, in both binding orders and under
/// concurrency, even when both engines are given the same account id.
@Suite struct CloudSyncBackendExclusivityTests {
    private func library() throws -> (AppDatabase, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ck-exclusive-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (try AppDatabase(path: root.appendingPathComponent("lib.sqlite")), root)
    }

    private func control(_ db: AppDatabase) throws -> (backend: String, account: String?, enabled: Bool) {
        try db.pool.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT backend, accountId, enabled FROM sync_control")!
            return (row["backend"], row["accountId"], row["enabled"])
        }
    }

    @Test(arguments: ["shared-1", "other-1"])
    func cloudflareCanNotConfigureOrEnableAfterCloudKitBound(_ cloudflareAccount: String) throws {
        let (db, root) = try library(); defer { try? db.pool.close(); try? FileManager.default.removeItem(at: root) }
        try db.pool.write {
            try $0.execute(sql: "INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('note','n',1,0)")
        }
        try CloudSyncStore(database: db).bind(accountId: "shared-1", containerId: "iCloud.test", zoneName: "TheoNotes", cloudUserHash: "u")
        let queue = SyncQueue(database: db)
        #expect(throws: SyncQueueError.accountMismatch) { try queue.configure(accountID: cloudflareAccount) }
        #expect(throws: SyncQueueError.accountMismatch) { try queue.enable(accountID: cloudflareAccount) }
        let state = try control(db)
        #expect(state.backend == "cloudkit" && state.account == "shared-1" && state.enabled == false)
        // Nothing was seeded by the refused enable.
        #expect(try db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_dirty") } == 1)
    }

    @Test func cloudKitCanNotBindAfterCloudflareConfiguredOrEnabled() throws {
        for enable in [false, true] {
            let (db, root) = try library(); defer { try? db.pool.close(); try? FileManager.default.removeItem(at: root) }
            let queue = SyncQueue(database: db)
            if enable { try queue.enable(accountID: "shared-1") } else { try queue.configure(accountID: "shared-1") }
            #expect(throws: CloudSyncStoreError.backendConflict(.cloudflare)) {
                try CloudSyncStore(database: db).bind(accountId: "shared-1", containerId: "iCloud.test", zoneName: "TheoNotes", cloudUserHash: "u")
            }
            #expect(try control(db).backend == "cloudflare")
        }
    }

    @Test func aCloudKitDetachNeverTouchesCloudflareState() throws {
        // The race can not leave a Cloudflare-owned library at backend=cloudkit, so the CloudKit
        // detach's clearing of shared tables can not reach Cloudflare state.
        let (db, root) = try library(); defer { try? db.pool.close(); try? FileManager.default.removeItem(at: root) }
        try SyncQueue(database: db).configure(accountID: "shared-1")
        try db.pool.write {
            try $0.execute(sql: "INSERT INTO sync_entity_state(entityType,localId,entityId) VALUES('note','n','e')")
            try $0.execute(sql: "INSERT INTO backup_catalog(id,filename,createdAt,plaintextNoteIds) VALUES('b1','b1.baerchen-backup',?,'[]')", arguments: [Date()])
        }
        #expect(throws: SyncAccountDetachError.backendMismatch(expected: .cloudkit, actual: .cloudflare)) {
            try SyncAccountDetach.detach(database: db, expectedBackend: .cloudkit, verifiedBackupID: "b1")
        }
        #expect(try db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_entity_state") } == 1)
    }

    @Test func concurrentCloudflareAndCloudKitBindingsLeaveExactlyOneOwner() throws {
        for round in 0..<40 {
            let (db, root) = try library(); defer { try? db.pool.close(); try? FileManager.default.removeItem(at: root) }
            let outcomes = OutcomeBox()
            let enable = round % 2 == 0
            let cloudflareIndex = (round / 2) % 2          // both start orders
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                do {
                    if index == cloudflareIndex {
                        let queue = SyncQueue(database: db)
                        if enable { try queue.enable(accountID: "shared-1") } else { try queue.configure(accountID: "shared-1") }
                    } else {
                        try CloudSyncStore(database: db).bind(accountId: "shared-1", containerId: "iCloud.test", zoneName: "TheoNotes", cloudUserHash: "u")
                    }
                    outcomes.record(index, ok: true)
                } catch { outcomes.record(index, ok: false) }
            }
            let ok = outcomes.snapshot()
            #expect(ok.values.filter { $0 }.count == 1, "round \(round): \(ok)")
            let state = try control(db)
            #expect(state.backend == (ok[cloudflareIndex] == true ? "cloudflare" : "cloudkit"), "round \(round)")
            #expect(state.account == "shared-1")
        }
    }
}

private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int: Bool] = [:]
    func record(_ index: Int, ok: Bool) { lock.lock(); values[index] = ok; lock.unlock() }
    func snapshot() -> [Int: Bool] { lock.lock(); defer { lock.unlock() }; return values }
}
