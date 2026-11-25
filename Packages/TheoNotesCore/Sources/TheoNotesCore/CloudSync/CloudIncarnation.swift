// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB

// Missing-record recovery (CK-R5, CK-R21). A record the cloud stopped returning pauses its entity: nothing is republished, the
// local content is untouched. The only way out is this explicit recovery, which is never a version bump:
//
//   1. a NEW incarnation: `inc' = random`, `incs' = [old inc] + old incs`, `ver = 1`;
//   2. sealed from the CURRENT library content of the entity (edits made while it was paused are in it);
//   3. saved CREATE-ONLY (no change tag), so when two devices recover at once the cloud lets exactly one create win; the loser gets
//      `serverRecordChanged` with the winner's record and merges it against its own stored ancestor (the receiver does that);
//   4. blob references are verified by the publisher before the save (the same seam as every other save).
//
// This type prepares the snapshot (the in-flight row of the new incarnation) in one transaction and lifts the pause with it; the
// publisher sends it like any other snapshot. The recovery does not talk to the cloud itself.

public enum CloudRecoveryOutcome: Sendable, Equatable {
    /// The create-only snapshot of the new incarnation is prepared; the next publish cycle sends it.
    case prepared(attemptId: String, inc: String)
    /// The entity is not paused: there is nothing to recover.
    case notPaused
    /// A fetched version of the entity waits for the receiver's merge; the record is back, adopting it is the recovery.
    case mergePending
    case fenced
    /// The content cannot be snapshotted right now (for example an attachment that is not prepared yet); try again later.
    case unavailable
}

public struct CloudIncarnation: Sendable {
    private let database: AppDatabase
    private let store: CloudSyncStore
    private let accountID: String
    private let vaultKey: SymmetricKey
    private let sealer: CloudPayloadSealer
    private let clock: @Sendable () -> Date
    private let newIncarnation: @Sendable () -> String

    public init(database: AppDatabase, store: CloudSyncStore, accountID: String, vaultKey: SymmetricKey,
                clock: @escaping @Sendable () -> Date = { Date() }, newIncarnation: (@Sendable () -> String)? = nil) {
        self.database = database; self.store = store; self.accountID = accountID; self.vaultKey = vaultKey
        self.sealer = CloudPayloadSealer(accountID: accountID, vaultKey: vaultKey); self.clock = clock; self.newIncarnation = newIncarnation ?? { CloudPublisher.newIncarnation() }
    }

    /// "Upload them again" for one paused entity. Explicit: nothing in the engine calls this on its own.
    public func recover(entityType: String, entityId: String) throws -> CloudRecoveryOutcome {
        let entity = CloudEntityRef(entityType: entityType, entityId: entityId)
        guard let type = SyncEntityType(rawValue: entityType) else { return .unavailable }
        return try database.pool.write { db in
            guard let missing = try CloudSyncStore.missing(db, entity), let pair = try CloudSyncStore.pair(db, entity) else { return .notPaused }
            if try CloudSyncStore.isFenced(db, entity) { return .fenced }
            if try CloudSyncStore.hasPendingRemote(db, entity) { return .mergePending }
            let localID = try String.fetchOne(db, sql: "SELECT localId FROM sync_entity_state WHERE entityType=? AND entityId=?",
                                              arguments: [entityType, entityId]) ?? entityId
            // The current content, exactly as the publisher snapshots it; a dirty row (edits made while paused) gives the generation.
            let row = try Row.fetchOne(db, sql: "SELECT generation, tombstone FROM sync_dirty WHERE entityType=? AND localId=?", arguments: [entityType, localID])
            var generation: Int64 = row?["generation"] ?? 0
            if row == nil, type == .attachment {
                // A saved attachment has no dirty row; the descriptor cache remembers the generation it was prepared at.
                generation = try Int64.fetchOne(db, sql: "SELECT generation FROM sync_attachment_cache WHERE attachmentId=?", arguments: [localID]) ?? 0
            }
            let dirty = SyncDirty(type: type, localID: localID, generation: generation, tombstone: row?["tombstone"] ?? false)
            let content: SyncContent
            do { content = try CloudPayloadSealer.capture(dirty, accountID: accountID, vaultKey: vaultKey, in: db) }
            catch SyncQueueError.snapshotUnavailable { return .unavailable }
            // The snapshot that was kept when the entity paused described the old incarnation; the library content replaces it.
            for old in try CloudSyncStore.fetchInflight(db, sql: "WHERE entityType=? AND entityId=?", [entityType, entityId]) {
                try CloudSyncStore.dropInflight(db, attemptId: old.attemptId)
            }
            var inc = newIncarnation()
            while inc == pair.inc || inc == missing.lastInc || pair.supersededIncs.contains(inc) { inc = newIncarnation() }
            let attemptId = UUIDv7.make()
            // A create: no change tag. The ancestor of the old history is kept, so that when another device's recovery wins,
            // the merge of its record runs against the last version this device held (CK-R21).
            let attempt = CloudInflight(entity: entity, localId: localID, generation: dirty.generation, attemptId: attemptId,
                                        baseSystemFields: nil, baseAncestor: pair.ancestor, baseVer: 0, inc: inc,
                                        sealed: try sealer.seal(content, type: type, entityID: entityId, deletedAt: clock()),
                                        blobRefs: content.blobRefs, state: .prepared,
                                        accountGeneration: try CloudSyncStore.generation(db), preparedAt: clock(), sids: [attemptId])
            // The pause lifts first so that the standard checks of the insert (paused entity, only a new incarnation) hold.
            try db.execute(sql: "DELETE FROM ck_missing WHERE entityType=? AND entityId=?", arguments: [entityType, entityId])
            try CloudSyncStore.insertInflight(db, attempt)
            return .prepared(attemptId: attemptId, inc: inc)
        }
    }

    /// Recovery of every paused entity, the button "Upload them again". Returns the outcome per entity.
    public func recoverAll() throws -> [(CloudEntityRef, CloudRecoveryOutcome)] {
        try store.allMissing().map { ($0.entity, try recover(entityType: $0.entity.entityType, entityId: $0.entity.entityId)) }
    }
}
