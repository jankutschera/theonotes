// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

// What the publisher needs from the store beyond the invariant methods of `CloudSyncStore`. None of this touches
// `ck_record` (the base pair keeps exactly two writers, I1) or `sync_dirty` (cleared only by `recordSaved`, I3).
extension CloudSyncStore {
    /// A crash (or a gateway that reported nothing) leaves `sending` rows: the send may or may not have landed, so they
    /// become `unknown` and the outcome table decides (CK-R4). Returns how many rows changed.
    @discardableResult
    public func interruptSending() throws -> Int {
        try database.pool.write { db in
            try db.execute(sql: "UPDATE ck_inflight SET state='unknown' WHERE state='sending'")
            return db.changesCount
        }
    }

    /// The one step that turns a prepared snapshot into `sending`, revalidating everything that may have changed since the
    /// publisher first looked (it awaits blob uploads in between): a quarantine fence, a pause, a fetched version waiting
    /// for its merge, a base pair that moved, an older account generation. Any of them throws and leaves the snapshot
    /// `prepared` with its dirty generations untouched.
    public func beginSending(attemptId: String) throws {
        try database.pool.write { db in
            guard let attempt = try Self.fetchInflight(db, sql: "WHERE attemptId=?", [attemptId]).first else { throw CloudSyncStoreError.unknownAttempt(attemptId) }
            let name = attempt.entity.recordName
            if try Self.isFenced(db, attempt.entity) { throw CloudSyncStoreError.entityFenced(name) }
            if try Self.isPaused(db, attempt.entity) { throw CloudSyncStoreError.entityPaused(name) }
            if try Self.hasPendingRemote(db, attempt.entity) { throw CloudSyncStoreError.entityMergePending(name) }
            let generation = try Self.generation(db)
            guard attempt.accountGeneration == generation else {
                throw CloudSyncStoreError.staleAccountGeneration(expected: generation, actual: attempt.accountGeneration)
            }
            try Self.requireNotFenced(db)
            if let pair = try Self.pair(db, attempt.entity), Self.pairAdvanced(pair, beyond: attempt) { throw CloudSyncStoreError.pairAdvanced(name) }
            try db.execute(sql: "UPDATE ck_inflight SET state='sending' WHERE attemptId=?", arguments: [attemptId])
        }
    }

    /// Removes a send result (consumed, or discarded because it belongs to an older account generation, CK-R15).
    public func deleteSendResult(attemptId: String) throws {
        try database.pool.write { try $0.execute(sql: "DELETE FROM ck_send_result WHERE attemptId=?", arguments: [attemptId]) }
    }

    /// Attempt ids of `BlobPart` saves start with this. Their results have no in-flight row: the blob transfer reads and deletes
    /// them itself, so the orphan sweep leaves them alone (CK-R114).
    public static let blobAttemptPrefix = "blob-"

    /// Results nobody waits for any more: the in-flight row they answer is gone. `BlobPart` results (attempt ids with
    /// `blobAttemptPrefix`) have no in-flight row by design: the blob transfer reads and deletes them itself, so they are kept
    /// (a quota or conflict outcome must not vanish before it is read) and swept only when a day old, which means the transfer
    /// that was waiting for them died.
    @discardableResult
    public func deleteOrphanSendResults() throws -> Int {
        let cutoff = clock().addingTimeInterval(-24 * 3600)
        return try database.pool.write { db in
            try db.execute(sql: """
                DELETE FROM ck_send_result WHERE attemptId NOT IN (SELECT attemptId FROM ck_inflight)
                  AND (attemptId NOT LIKE ? OR recordedAt < ?)
                """, arguments: [Self.blobAttemptPrefix + "%", cutoff])
            return db.changesCount
        }
    }

    /// Drops the in-flight snapshot of an attempt. The receiver calls the static form inside the transaction in which it
    /// merged the server version into the library: from then on the content lives in the library and in the (still
    /// present) dirty generation, so nothing is lost (CK-R4 `serverRecordChanged`). Also removes its send result.
    static func dropInflight(_ db: Database, attemptId: String) throws {
        try db.execute(sql: "DELETE FROM ck_inflight WHERE attemptId=?", arguments: [attemptId])
        try db.execute(sql: "DELETE FROM ck_send_result WHERE attemptId=?", arguments: [attemptId])
    }

    public func discardInflight(attemptId: String) throws {
        try database.pool.write { try Self.dropInflight($0, attemptId: attemptId) }
    }

    /// A fetched version of the entity waits in `ck_remote` for the receiver to merge it. While it does, nothing new is
    /// prepared or sent for the entity: the next snapshot must be built on the pair that merge creates (I1).
    static func hasPendingRemote(_ db: Database, _ entity: CloudEntityRef) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM ck_remote WHERE entityType=? AND entityId=?)",
                          arguments: [entity.entityType, entity.entityId]) ?? false
    }

    public func hasPendingRemote(_ entity: CloudEntityRef) throws -> Bool {
        try database.pool.read { try Self.hasPendingRemote($0, entity) }
    }

    static func isPaused(_ db: Database, _ entity: CloudEntityRef) throws -> Bool {
        try missing(db, entity) != nil
    }

    public func sendResultRow(attemptId: String) throws -> (accountGeneration: Int64, outcome: CloudSaveOutcome)? {
        try sendResult(attemptId: attemptId)
    }

    public func inflightAttemptIds() throws -> [String] {
        try database.pool.read { try String.fetchAll($0, sql: "SELECT attemptId FROM ck_inflight ORDER BY preparedAt, attemptId") }
    }
}
