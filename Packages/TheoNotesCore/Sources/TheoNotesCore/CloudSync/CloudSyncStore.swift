// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB

// The durable state of the CloudKit-native engine. Everything the
// publisher and the receiver must keep consistent is one method here, one transaction, so the
// invariants cannot be broken by calling two methods in the wrong order:
//
// - I1: `ck_record` (the base pair: change-tag archive plus the merge ancestor of that same
//   version) is written only by `recordSaved` (a save of our own snapshot) and `recordApplied`
//   (a fetched version merged into the library). No other method writes it.
// - I3: a save result clears the dirty generation it was prepared at, never a higher one.
// - Fence: while an entity has an unresolved quarantine row, nothing is prepared, submitted,
//   paired or applied for it.
// No CloudKit types appear here; the store is plain SQL over `AppDatabase`.

public enum CloudSyncStoreError: Error, Equatable {
    /// The entity has an unresolved quarantine row.
    case entityFenced(String)
    /// The entity is paused after its record went missing; only a new incarnation may be prepared.
    case entityPaused(String)
    /// A result or write belongs to an older account generation and is discarded.
    case staleAccountGeneration(expected: Int64, actual: Int64)
    case inflightExists(String)
    case unknownAttempt(String)
    case noBasePair(String)
    /// Applying would move the base pair to an older version of the same incarnation.
    case wouldRegressPair(String)
    case backendConflict(SyncBackend)
    case accountConflict
    case invalidRecordName(String)
    /// A superseded incarnation id was offered again as a new or current incarnation.
    case incarnationReused(String)
    /// The quarantine row is no longer the record the caller inspected when it decided to release it.
    case quarantineChanged(String)
    /// A pinned file path is already owned by another record (pinned paths are unique and immutable).
    case pinnedPathReused(String)
    /// A fetched version of the entity waits for the receiver's merge; nothing is sent on a base it will replace.
    case entityMergePending(String)
    /// The base pair is no longer the one the snapshot was built on.
    case pairAdvanced(String)
    /// The account fence is up: no write of the old session lands, even while its generation still matches.
    case accountFenced
    /// A guarded write was prepared for another account than the one this library is bound to.
    case accountMismatch
}

public struct CloudEntityRef: Hashable, Sendable {
    public let entityType: String
    public let entityId: String
    public init(entityType: String, entityId: String) { self.entityType = entityType; self.entityId = entityId }
    /// Authoritative record name of an `Entity` record.
    public var recordName: String { "e.\(entityType).\(entityId)" }
    /// `nil` when the name does not name an entity we could hold (a `BlobPart`, the key bundle,
    /// anything unparseable): such a name fences nothing.
    public static func parse(recordName: String) -> CloudEntityRef? {
        guard recordName.hasPrefix("e.") else { return nil }
        let rest = recordName.dropFirst(2)
        guard let dot = rest.firstIndex(of: "."), dot != rest.startIndex else { return nil }
        let id = rest[rest.index(after: dot)...]
        guard !id.isEmpty else { return nil }
        return CloudEntityRef(entityType: String(rest[..<dot]), entityId: String(id))
    }
}

/// The base pair of one entity: written together, so a change tag is never used with an ancestor
/// that is not the content of that exact version.
public struct CloudBasePair: Sendable, Equatable {
    public var entity: CloudEntityRef
    public var systemFields: Data
    public var ancestor: Data
    public var ver: Int64
    public var inc: String
    public var supersededIncs: [String]
    /// The attempt-id chain of this version, newest first (`sids`): the next saver extends it.
    public var sids: [String]
    public init(entity: CloudEntityRef, systemFields: Data, ancestor: Data, ver: Int64, inc: String, supersededIncs: [String] = [],
                sids: [String] = []) {
        self.entity = entity; self.systemFields = systemFields; self.ancestor = ancestor
        self.ver = ver; self.inc = inc; self.supersededIncs = supersededIncs; self.sids = sids
    }
}

/// One prepared save: the immutable snapshot plus the base pair it was built on.
public struct CloudInflight: Sendable, Equatable {
    public enum State: String, Sendable { case prepared, sending, unknown }
    public var entity: CloudEntityRef
    public var localId: String
    /// The `sync_dirty` generation captured when the snapshot was taken.
    public var generation: Int64
    public var attemptId: String
    public var baseSystemFields: Data?
    public var baseAncestor: Data?
    public var baseVer: Int64
    public var inc: String
    public var sealed: Data
    public var blobRefs: [String]
    public var state: State
    public var accountGeneration: Int64
    public var preparedAt: Date
    /// The attempt-id chain exactly as sent: `[attemptId] + base chain`, at most 8; just `[attemptId]` for a create.
    public var sids: [String]
    public init(entity: CloudEntityRef, localId: String, generation: Int64, attemptId: String,
                baseSystemFields: Data? = nil, baseAncestor: Data? = nil, baseVer: Int64 = 0, inc: String,
                sealed: Data, blobRefs: [String] = [], state: State = .prepared,
                accountGeneration: Int64, preparedAt: Date = Date(), sids: [String]? = nil) {
        self.entity = entity; self.localId = localId; self.generation = generation; self.attemptId = attemptId
        self.baseSystemFields = baseSystemFields; self.baseAncestor = baseAncestor; self.baseVer = baseVer
        self.inc = inc; self.sealed = sealed; self.blobRefs = blobRefs; self.state = state
        self.accountGeneration = accountGeneration; self.preparedAt = preparedAt; self.sids = sids ?? [attemptId]
    }
}

/// A copy of an asset made durable before the engine state may advance.
public struct CloudPinnedAsset: Codable, Sendable, Equatable {
    public var field: String
    public var path: String
    public var size: Int64
    public var sha256: String
    public init(field: String, path: String, size: Int64, sha256: String) {
        self.field = field; self.path = path; self.size = size; self.sha256 = sha256
    }
}

/// A fetched, validated `Entity` version as stored in `ck_remote`. `rawFields` and
/// `pinnedAssets` are used only if the version turns out divergent and must be quarantined.
public struct CloudRemoteVersion: Sendable, Equatable {
    public enum Waiting: String, Sendable { case unlock, dependency }
    public var recordName: String
    public var entity: CloudEntityRef
    public var inc: String
    public var incs: [String]
    public var ver: Int64
    public var sid: String
    public var sids: [String]
    public var systemFields: Data
    public var sealed: Data?
    public var sealedPath: String?
    public var sealedSha256: String?
    public var blobRefs: [String]
    public var receivedAt: Date
    public var waitingFor: Waiting?
    public var rawFields: Data
    public var pinnedAssets: [CloudPinnedAsset]
    public init(entity: CloudEntityRef, inc: String, incs: [String] = [], ver: Int64, sid: String, sids: [String] = [],
                systemFields: Data, sealed: Data? = nil, sealedPath: String? = nil, sealedSha256: String? = nil,
                blobRefs: [String] = [], receivedAt: Date = Date(), waitingFor: Waiting? = nil,
                rawFields: Data = Data(), pinnedAssets: [CloudPinnedAsset] = []) {
        self.recordName = entity.recordName; self.entity = entity; self.inc = inc; self.incs = incs
        self.ver = ver; self.sid = sid; self.sids = sids; self.systemFields = systemFields
        self.sealed = sealed; self.sealedPath = sealedPath; self.sealedSha256 = sealedSha256
        self.blobRefs = blobRefs; self.receivedAt = receivedAt; self.waitingFor = waitingFor
        self.rawFields = rawFields; self.pinnedAssets = pinnedAssets
    }
}

public struct CloudQuarantineRecord: Sendable, Equatable {
    public var recordName: String
    public var reason: String
    public var v: Int64?
    public var rawFields: Data
    public init(recordName: String, reason: String, v: Int64? = nil, rawFields: Data) {
        self.recordName = recordName; self.reason = reason; self.v = v; self.rawFields = rawFields
    }
}

public struct CloudQuarantineRow: Sendable, Equatable {
    public var recordName: String
    public var entity: CloudEntityRef?
    public var reason: String
    public var v: Int64?
    public var rawFields: Data
    public var pinnedAssets: [CloudPinnedAsset]
    public var ignoredByUser: Bool
    public var attempts: Int
}

public struct CloudMissingRow: Sendable, Equatable {
    public var entity: CloudEntityRef
    public var lastVer: Int64
    public var lastInc: String
    public var reason: String
}

/// How a version reached us. Only an ordinary incremental fetch may ignore a superseded
/// incarnation; a full refetch and a `serverRecordChanged` are always followed.
public enum CloudDelivery: Sendable { case incremental, fullRefetch, serverRecordChanged }

public enum CloudStoreRemoteOutcome: Sendable, Equatable {
    case stored
    /// The same version again (an echo of our own save, or a redelivery).
    case echo
    case ignoredStale
    case ignoredSupersededIncarnation
    /// Equal `ver`, different content: quarantined, the entity is fenced.
    /// Equal `ver` or `sid`, different content: quarantined, the entity is fenced. The paths are pinned
    /// files the replaced quarantine row owned and nothing references any more; delete them after the commit.
    case quarantinedDivergent(obsoletePinnedPaths: [String])
}

public enum CloudSaveRecorded: Sendable, Equatable {
    case recorded(clearedDirty: Bool)
    /// No in-flight row for the attempt: the result was already consumed.
    case alreadyRecorded
    /// The pair is no longer the one the snapshot was built on (a fetched version was applied while the save was in
    /// flight). The save landed and the applied version descends from it, so nothing is written and nothing is
    /// cleared: the pair stays where the merge put it, the dirty generations stay, the caller drops the snapshot.
    case pairAdvanced
}


public struct CloudIncarnationPlan: Sendable, Equatable {
    public var inc: String
    public var supersededIncs: [String]
}

public struct CloudSyncStore: Sendable {
    public let database: AppDatabase
    private let boundary: @Sendable (String) throws -> Void
    let clock: @Sendable () -> Date

    /// `boundary` is called with a named step name between the writes of a multi-write
    /// transaction; a test throws from it to prove the transaction rolls back as a whole.
    public init(database: AppDatabase,
                boundary: @escaping @Sendable (String) throws -> Void = { _ in },
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database; self.boundary = boundary; self.clock = clock
    }

    static let maxLocalSupersededIncs = 8

    // MARK: - Backend binding

    public func backend() throws -> SyncBackend {
        try database.pool.read { try Self.backend($0) }
    }

    static func backend(_ db: Database) throws -> SyncBackend {
        SyncBackend(rawValue: try String.fetchOne(db, sql: "SELECT backend FROM sync_control WHERE id=1") ?? "none") ?? .none
    }

    /// Binds this library to CloudKit. Refused while it is bound to Cloudflare or to another
    /// account; repeating the same bind is a no-op for the state and still bumps nothing.
    /// Capture starts at once (the capture triggers watch `accountId`); uploads wait for `enable`.
    @discardableResult
    public func bind(accountId: String, containerId: String, zoneName: String, cloudUserHash: String) throws -> Int64 {
        try database.pool.write { db in
            let row = try Row.fetchOne(db, sql: "SELECT backend, accountId FROM sync_control WHERE id=1")
            let current = SyncBackend(rawValue: row?["backend"] ?? "none") ?? .none
            let currentAccount: String? = row?["accountId"]
            if current == .cloudflare { throw CloudSyncStoreError.backendConflict(current) }
            if current == .cloudkit, currentAccount != accountId { throw CloudSyncStoreError.accountConflict }
            if current == .none, currentAccount != nil { throw CloudSyncStoreError.backendConflict(.cloudflare) }
            if current == .cloudkit { return try Self.generation(db) }
            try db.execute(sql: "UPDATE sync_control SET backend='cloudkit', accountId=? WHERE id=1", arguments: [accountId])
            try db.execute(sql: """
                UPDATE ck_state SET containerId=?, zoneName=?, accountId=?, cloudUserHash=?, generation=generation+1 WHERE id=1
                """, arguments: [containerId, zoneName, accountId, cloudUserHash])
            return try Self.generation(db)
        }
    }

    // MARK: - Generation, account fence, zone, engine state

    public func generation() throws -> Int64 { try database.pool.read { try Self.generation($0) } }
    static func generation(_ db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT generation FROM ck_state WHERE id=1") ?? 0
    }

    @discardableResult
    public func bumpGeneration() throws -> Int64 {
        try database.pool.write { db in
            try db.execute(sql: "UPDATE ck_state SET generation=generation+1 WHERE id=1")
            return try Self.generation(db)
        }
    }

    public func isAccountFenced() throws -> Bool {
        try database.pool.read { try Bool.fetchOne($0, sql: "SELECT fenced FROM ck_state WHERE id=1") ?? false }
    }
    public func setAccountFenced(_ fenced: Bool) throws {
        try database.pool.write { try $0.execute(sql: "UPDATE ck_state SET fenced=? WHERE id=1", arguments: [fenced]) }
    }

    public func engineState() throws -> Data? {
        try database.pool.read { try Data.fetchOne($0, sql: "SELECT engineState FROM ck_state WHERE id=1") }
    }

    /// Saved by the sink after the commits it follows. A state from an older account generation
    /// is refused so a late callback cannot resurrect a cleared engine.
    public func saveEngineState(_ state: Data, accountGeneration: Int64) throws {
        try database.pool.write { db in
            let current = try Self.generation(db)
            guard current == accountGeneration else {
                throw CloudSyncStoreError.staleAccountGeneration(expected: current, actual: accountGeneration)
            }
            try Self.requireNotFenced(db)
            try db.execute(sql: "UPDATE ck_state SET engineState=? WHERE id=1", arguments: [state])
        }
    }
    public func clearEngineState() throws {
        try database.pool.write { try $0.execute(sql: "UPDATE ck_state SET engineState=NULL WHERE id=1") }
    }

    // MARK: - Fence

    /// `true` while the entity has a quarantine row the person has not chosen to ignore.
    public func isFenced(entityType: String, entityId: String) throws -> Bool {
        try database.pool.read { try Self.isFenced($0, CloudEntityRef(entityType: entityType, entityId: entityId)) }
    }

    static func isFenced(_ db: Database, _ entity: CloudEntityRef) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM ck_quarantine WHERE entityType=? AND entityId=? AND ignoredByUser=0)
            """, arguments: [entity.entityType, entity.entityId]) ?? false
    }

    // MARK: - Prepare and submit (publisher side)

    /// Writes the immutable snapshot of one entity. Refused for a fenced entity, for a stale
    /// account generation, while one is already in flight, and for a paused (missing) entity
    /// unless this is a new incarnation.
    public func insertInflight(_ attempt: CloudInflight) throws {
        try database.pool.write { db in try Self.insertInflight(db, attempt) }
    }

    /// The same checks and write inside a transaction the caller owns, so a snapshot of the library and its
    /// in-flight row commit together ( "preparing a send atomically snapshots the current content").
    static func insertInflight(_ db: Database, _ attempt: CloudInflight) throws {
        if try Self.isFenced(db, attempt.entity) { throw CloudSyncStoreError.entityFenced(attempt.entity.recordName) }
        let generation = try Self.generation(db)
        guard generation == attempt.accountGeneration else {
            throw CloudSyncStoreError.staleAccountGeneration(expected: generation, actual: attempt.accountGeneration)
        }
        try Self.requireNotFenced(db)
        if let pair = try Self.pair(db, attempt.entity), attempt.inc != pair.inc, pair.supersededIncs.contains(attempt.inc) {
            throw CloudSyncStoreError.incarnationReused(attempt.inc)
        }
        if let missing = try Self.missing(db, attempt.entity), missing.lastInc == attempt.inc {
            throw CloudSyncStoreError.entityPaused(attempt.entity.recordName)
        }
        if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM ck_inflight WHERE entityType=? AND entityId=?)",
                             arguments: [attempt.entity.entityType, attempt.entity.entityId]) == true {
            throw CloudSyncStoreError.inflightExists(attempt.entity.recordName)
        }
        try db.execute(sql: """
            INSERT INTO ck_inflight(entityType,entityId,localId,generation,attemptId,baseSystemFields,baseAncestor,baseVer,
                                    inc,sealed,blobRefs,state,generationOfAccount,preparedAt,sids)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, arguments: [attempt.entity.entityType, attempt.entity.entityId, attempt.localId, attempt.generation,
                             attempt.attemptId, attempt.baseSystemFields, attempt.baseAncestor, attempt.baseVer,
                             attempt.inc, attempt.sealed, Self.json(attempt.blobRefs), attempt.state.rawValue,
                             attempt.accountGeneration, attempt.preparedAt, Self.json(attempt.sids)])
    }

    /// State `sending` is written before `submit`; refused for a fenced entity.
    public func markInflight(attemptId: String, state: CloudInflight.State) throws {
        try database.pool.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT entityType, entityId FROM ck_inflight WHERE attemptId=?", arguments: [attemptId]) else {
                throw CloudSyncStoreError.unknownAttempt(attemptId)
            }
            let entity = CloudEntityRef(entityType: row["entityType"], entityId: row["entityId"])
            if state == .sending, try Self.isFenced(db, entity) { throw CloudSyncStoreError.entityFenced(entity.recordName) }
            if state == .sending { try Self.requireNotFenced(db) }
            try db.execute(sql: "UPDATE ck_inflight SET state=? WHERE attemptId=?", arguments: [state.rawValue, attemptId])
        }
    }

    public func inflight(attemptId: String) throws -> CloudInflight? {
        try database.pool.read { try Self.fetchInflight($0, sql: "WHERE attemptId=?", [attemptId]).first }
    }
    public func inflight(for entity: CloudEntityRef) throws -> CloudInflight? {
        try database.pool.read { try Self.fetchInflight($0, sql: "WHERE entityType=? AND entityId=?", [entity.entityType, entity.entityId]).first }
    }
    public func allInflight() throws -> [CloudInflight] {
        try database.pool.read { try Self.fetchInflight($0, sql: "ORDER BY preparedAt, attemptId", []) }
    }

    // MARK: - The base pair (invariant I1)

    public func pair(for entity: CloudEntityRef) throws -> CloudBasePair? {
        try database.pool.read { try Self.pair($0, entity) }
    }

    /// Result `saved(newSystemFields)`: pair:= (new tag, ancestor = the snapshot that was
    /// sent, ver = baseVer + 1), delete the in-flight row, delete the dirty row only if its
    /// generation is the one the snapshot was prepared at (I3). One transaction.
    @discardableResult
    public func recordSaved(attemptId: String, newSystemFields: Data, guard writeGuard: CloudWriteGuard? = nil) throws -> CloudSaveRecorded {
        try database.pool.write { db in
            guard let attempt = try Self.fetchInflight(db, sql: "WHERE attemptId=?", [attemptId]).first else { return .alreadyRecorded }
            try Self.requireNotFenced(db)
            if let writeGuard { try Self.check(db, writeGuard) }
            if try Self.isFenced(db, attempt.entity) { throw CloudSyncStoreError.entityFenced(attempt.entity.recordName) }
            let generation = try Self.generation(db)
            guard attempt.accountGeneration == generation else {
                throw CloudSyncStoreError.staleAccountGeneration(expected: generation, actual: attempt.accountGeneration)
            }
            let previous = try Self.pair(db, attempt.entity)
            if let previous, Self.pairAdvanced(previous, beyond: attempt) { return .pairAdvanced }
            var superseded = Self.cap(previous?.supersededIncs ?? [], Self.maxLocalSupersededIncs, excluding: attempt.inc)
            if let previous, previous.inc != attempt.inc {
                superseded = Self.cap([previous.inc] + previous.supersededIncs, Self.maxLocalSupersededIncs, excluding: attempt.inc)
            }
            try Self.writePair(db, CloudBasePair(entity: attempt.entity, systemFields: newSystemFields, ancestor: attempt.sealed,
                                                 ver: attempt.baseVer + 1, inc: attempt.inc, supersededIncs: superseded,
                                                 sids: attempt.sids))
            try boundary("recordSaved.afterPair")
            try db.execute(sql: "DELETE FROM ck_inflight WHERE attemptId=?", arguments: [attemptId])
            try boundary("recordSaved.afterInflightDelete")
            try db.execute(sql: "DELETE FROM sync_dirty WHERE entityType=? AND localId=? AND generation=?",
                           arguments: [attempt.entity.entityType, attempt.localId, attempt.generation])
            let cleared = db.changesCount > 0
            try boundary("recordSaved.afterDirtyDelete")
            try db.execute(sql: "DELETE FROM ck_send_result WHERE attemptId=?", arguments: [attemptId])
            try db.execute(sql: "DELETE FROM ck_missing WHERE entityType=? AND entityId=?",
                           arguments: [attempt.entity.entityType, attempt.entity.entityId])
            return .recorded(clearedDirty: cleared)
        }
    }

    /// A fetched version merged into the library. `libraryWrite` runs inside the same
    /// transaction, before the pair moves, so a failure leaves the old library and the old pair.
    /// Refused for a fenced entity unless the caller releases the quarantine because the app now
    /// understands the version; returns the pinned files of the released rows for the caller to
    /// delete after the commit.
    @discardableResult
    public func recordApplied(accountGeneration: Int64, remote: CloudRemoteVersion, ancestor: Data, releasingQuarantine: Bool = false,
                              expectedQuarantine: Data? = nil, libraryWrite: (Database) throws -> Void = { _ in }) throws -> [String] {
        try database.pool.write { db in
            // A delayed callback of an older account (or of a detached and rebound library) writes nothing.
            let generation = try Self.generation(db)
            guard generation == accountGeneration else {
                throw CloudSyncStoreError.staleAccountGeneration(expected: generation, actual: accountGeneration)
            }
            try Self.requireNotFenced(db)
            var released: [String] = []
            if try Self.isFenced(db, remote.entity) {
                guard releasingQuarantine else { throw CloudSyncStoreError.entityFenced(remote.recordName) }
                // Only the record that was inspected may be released: a row that changed since (a newer quarantine) stays.
                if let expectedQuarantine {
                    let current = try Data.fetchOne(db, sql: "SELECT rawFields FROM ck_quarantine WHERE recordName=?", arguments: [remote.recordName])
                    guard current == expectedQuarantine else { throw CloudSyncStoreError.quarantineChanged(remote.recordName) }
                }
                released = try Self.deleteQuarantine(db, entity: remote.entity)
            }
            let previous = try Self.pair(db, remote.entity)
            if let previous, previous.inc == remote.inc, previous.ver > remote.ver {
                throw CloudSyncStoreError.wouldRegressPair(remote.recordName)
            }
            try libraryWrite(db)
            try boundary("recordApplied.afterLibraryWrite")
            let superseded = Self.mergeSuperseded(previous, remote: remote)
            try Self.writePair(db, CloudBasePair(entity: remote.entity, systemFields: remote.systemFields, ancestor: ancestor,
                                                 ver: remote.ver, inc: remote.inc, supersededIncs: superseded,
                                                 sids: remote.sids))
            try boundary("recordApplied.afterPair")
            // Only the version that was applied: a newer one stored meanwhile stays for its own turn.
            try db.execute(sql: "DELETE FROM ck_remote WHERE recordName=? AND inc=? AND ver=? AND sid=?",
                           arguments: [remote.recordName, remote.inc, remote.ver, remote.sid])
            return try Self.unreferenced(db, released)
        }
    }

    /// The pair move of `recordApplied` for a second entity inside a transaction the caller already runs (an attachment version
    /// folded into a note's transaction): the same checks and the same pair, and the fetched row is removed by its exact identity.
    /// The generation was checked by the caller's `recordApplied` for the whole transaction.
    static func applyVersion(_ db: Database, remote: CloudRemoteVersion, ancestor: Data) throws {
        try requireNotFenced(db)
        if try isFenced(db, remote.entity) { throw CloudSyncStoreError.entityFenced(remote.recordName) }
        let previous = try pair(db, remote.entity)
        if let previous, previous.inc == remote.inc, previous.ver > remote.ver { throw CloudSyncStoreError.wouldRegressPair(remote.recordName) }
        try writePair(db, CloudBasePair(entity: remote.entity, systemFields: remote.systemFields, ancestor: ancestor, ver: remote.ver, inc: remote.inc,
                                        supersededIncs: mergeSuperseded(previous, remote: remote), sids: remote.sids))
        try db.execute(sql: "DELETE FROM ck_remote WHERE recordName=? AND inc=? AND ver=? AND sid=?",
                       arguments: [remote.recordName, remote.inc, remote.ver, remote.sid])
    }

    // MARK: - Receive

    public func remote(recordName: String) throws -> CloudRemoteVersion? {
        try database.pool.read { try Self.remote($0, recordName) }
    }
    public func allRemote() throws -> [CloudRemoteVersion] {
        try database.pool.read { db in try Row.fetchAll(db, sql: "SELECT * FROM ck_remote ORDER BY recordName").map(Self.remoteVersion) }
    }
    public func setWaiting(recordName: String, _ waiting: CloudRemoteVersion.Waiting?) throws {
        try database.pool.write { try $0.execute(sql: "UPDATE ck_remote SET waitingFor=? WHERE recordName=?", arguments: [waiting?.rawValue, recordName]) }
    }

    /// Stores the latest version per record name by the ordering rules; fetching never touches
    /// the library or the base pair. Arrival order is never trusted within an incarnation.
    @discardableResult
    public func storeRemote(_ remote: CloudRemoteVersion, delivery: CloudDelivery = .incremental,
                            accountGeneration: Int64? = nil) throws -> CloudStoreRemoteOutcome {
        try database.pool.write { db in
            try Self.requireOpen(db, accountGeneration)
            let pair = try Self.pair(db, remote.entity)
            let held = try Self.remote(db, remote.recordName)

            if let pair {
                if pair.inc == remote.inc {
                    if remote.ver < pair.ver { return .ignoredStale }
                    if remote.ver == pair.ver {
                        if Self.sameContent(remote, as: pair.ancestor) {
                            // Our own save coming back carries the change tag we hold. The same version and content under another
                            // tag means the record was recreated (resent after a deletion by hand): it is stored so that the pair
                            // takes the new tag, otherwise every save on the old tag would meet the new record for ever.
                            if remote.systemFields == pair.systemFields { return .echo }
                        } else {
                            return try Self.quarantineDivergent(db, remote, now: clock())
                        }
                    }
                } else if pair.supersededIncs.contains(remote.inc), delivery == .incremental {
                    return .ignoredSupersededIncarnation
                }
            }
            if let held {
                if held.inc == remote.inc {
                    if remote.ver < held.ver { return .ignoredStale }
                    if remote.ver == held.ver {
                        if remote.sid == held.sid, let digest = Self.envelopeDigest(remote), digest == Self.envelopeDigest(held) { return .echo }
                        return try Self.quarantineDivergent(db, remote, now: clock())
                    }
                } else if held.incs.contains(remote.inc), delivery == .incremental {
                    return .ignoredSupersededIncarnation
                }
            }
            if let path = remote.sealedPath { try Self.requireOwnedPaths(db, [path], by: remote.recordName) }
            try db.execute(sql: """
                INSERT INTO ck_remote(recordName,entityType,entityId,inc,incs,ver,sid,sids,systemFields,sealed,sealedPath,sealedSha256,blobRefs,receivedAt,waitingFor)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(recordName) DO UPDATE SET entityType=excluded.entityType, entityId=excluded.entityId, inc=excluded.inc,
                  incs=excluded.incs, ver=excluded.ver, sid=excluded.sid, sids=excluded.sids, systemFields=excluded.systemFields,
                  sealed=excluded.sealed, sealedPath=excluded.sealedPath, sealedSha256=excluded.sealedSha256,
                  blobRefs=excluded.blobRefs, receivedAt=excluded.receivedAt, waitingFor=excluded.waitingFor
                """, arguments: [remote.recordName, remote.entity.entityType, remote.entity.entityId, remote.inc, Self.json(remote.incs),
                                 remote.ver, remote.sid, Self.json(remote.sids), remote.systemFields, remote.sealed, remote.sealedPath,
                                 remote.sealedSha256, Self.json(remote.blobRefs), remote.receivedAt, remote.waitingFor?.rawValue])
            return .stored
        }
    }

    // MARK: - Quarantine

    /// The row and its pinned asset paths in one transaction. A repeated quarantine of the same
    /// record counts an attempt; a different version of it is a new item and un-ignores it.
    /// Returns the pinned files the replaced row owned that nothing references any more (not the
    /// new row, not another quarantine row, not a stored remote version); delete them after the commit.
    @discardableResult
    public func quarantine(record: CloudQuarantineRecord, pinned: [CloudPinnedAsset], accountGeneration: Int64? = nil) throws -> [String] {
        try database.pool.write { db in
            try Self.requireOpen(db, accountGeneration)
            return try Self.writeQuarantine(db, record, pinned: pinned, now: clock())
        }
    }

    public func quarantineRows() throws -> [CloudQuarantineRow] {
        try database.pool.read { db in try Row.fetchAll(db, sql: "SELECT * FROM ck_quarantine ORDER BY recordName").map(Self.quarantineRow) }
    }

    /// The version is understood or superseded: the row goes, the fence lifts, the caller deletes the files.
    @discardableResult
    public func releaseQuarantine(recordName: String) throws -> [String] {
        try database.pool.write { db in try Self.deleteQuarantine(db, recordName: recordName) }
    }

    /// "Ignore this item": explicit, recorded, the fence lifts; the caller deletes the returned files.
    @discardableResult
    public func ignoreQuarantine(recordName: String) throws -> [String] {
        try database.pool.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT pinnedAssets FROM ck_quarantine WHERE recordName=?", arguments: [recordName]) else { return [] }
            let paths = Self.decodeAssets(row["pinnedAssets"]).map(\.path)
            try db.execute(sql: "UPDATE ck_quarantine SET ignoredByUser=1, pinnedAssets='[]' WHERE recordName=?", arguments: [recordName])
            return try Self.unreferenced(db, paths)
        }
    }

    // MARK: - Absence and incarnations

    /// Pauses an entity the cloud no longer returns. Local content is untouched and the base
    /// pair stays; nothing is republished until the person starts recovery.
    public func markMissing(entityType: String, entityId: String, reason: String, accountGeneration: Int64? = nil) throws {
        try database.pool.write { db in
            try Self.requireOpen(db, accountGeneration)
            let entity = CloudEntityRef(entityType: entityType, entityId: entityId)
            guard let pair = try Self.pair(db, entity) else { throw CloudSyncStoreError.noBasePair(entity.recordName) }
            try db.execute(sql: """
                INSERT INTO ck_missing(entityType,entityId,lastVer,lastInc,detectedAt,reason) VALUES(?,?,?,?,?,?)
                ON CONFLICT(entityType,entityId) DO UPDATE SET reason=excluded.reason
                """, arguments: [entityType, entityId, pair.ver, pair.inc, clock(), reason])
        }
    }
    public func missing(entityType: String, entityId: String) throws -> CloudMissingRow? {
        try database.pool.read { try Self.missing($0, CloudEntityRef(entityType: entityType, entityId: entityId)) }
    }
    public func allMissing() throws -> [CloudMissingRow] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM ck_missing ORDER BY entityType, entityId").map(Self.missingRow)
        }
    }
    public func clearMissing(entityType: String, entityId: String) throws {
        try database.pool.write { try $0.execute(sql: "DELETE FROM ck_missing WHERE entityType=? AND entityId=?", arguments: [entityType, entityId]) }
    }

    /// Starts recovery of a paused entity under a new incarnation: returns the
    /// incarnation id and the superseded list (`[old inc] + old incs`) for the create-only save,
    /// which `recordSaved` then turns into the new pair. Writes nothing: `ck_record` changes only
    /// through a successful save (I1), and the pause lifts with it.
    public func adoptIncarnation(entityType: String, entityId: String, newInc: String) throws -> CloudIncarnationPlan {
        try database.pool.read { db in
            let entity = CloudEntityRef(entityType: entityType, entityId: entityId)
            if try Self.isFenced(db, entity) { throw CloudSyncStoreError.entityFenced(entity.recordName) }
            guard let missing = try Self.missing(db, entity), let pair = try Self.pair(db, entity) else {
                throw CloudSyncStoreError.noBasePair(entity.recordName)
            }
            guard newInc != missing.lastInc, newInc != pair.inc, !pair.supersededIncs.contains(newInc) else {
                throw CloudSyncStoreError.incarnationReused(newInc)
            }
            return CloudIncarnationPlan(inc: newInc, supersededIncs: Self.cap([pair.inc] + pair.supersededIncs, 4, excluding: newInc))
        }
    }

    // MARK: - Internals

    /// The pair moved since the snapshot was built: another tag, version or ancestor than its base, or (for a create, a first
    /// publish or a recovery) a pair of the same incarnation. Only an applied merge can do that (I1).
    static func pairAdvanced(_ pair: CloudBasePair, beyond attempt: CloudInflight) -> Bool {
        guard let base = attempt.baseSystemFields else { return pair.inc == attempt.inc }
        return pair.systemFields != base || pair.ver != attempt.baseVer || pair.inc != attempt.inc || pair.ancestor != attempt.baseAncestor
    }

    /// De-duplicated, newest first, without the incarnation that is current (it is never its own history).
    static func cap(_ values: [String], _ limit: Int, excluding current: String? = nil) -> [String] {
        var seen = Set<String>(), out: [String] = []
        if let current { seen.insert(current) }
        for value in values where seen.insert(value).inserted { out.append(value) }
        return Array(out.prefix(limit))
    }

    static func mergeSuperseded(_ previous: CloudBasePair?, remote: CloudRemoteVersion) -> [String] {
        guard let previous else { return cap(remote.incs, maxLocalSupersededIncs, excluding: remote.inc) }
        if previous.inc == remote.inc { return cap(previous.supersededIncs, maxLocalSupersededIncs, excluding: remote.inc) }
        return cap([previous.inc] + previous.supersededIncs + remote.incs, maxLocalSupersededIncs, excluding: remote.inc)
    }

    static func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// SHA-256 (lowercase hex) of the sealed payload, whether it came inline or as a pinned asset.
    static func digest(_ remote: CloudRemoteVersion) -> String? {
        remote.sealedSha256 ?? remote.sealed.map(sha256Hex)
    }

    /// SHA-256 of everything we store about a version except what the server legitimately changes on
    /// every save (the CloudKit system fields and their change tag): payload digest, blob references,
    /// incarnation, incarnation history, attempt id and attempt-id chain. `nil` when the payload has no digest.
    static func envelopeDigest(_ remote: CloudRemoteVersion) -> String? {
        guard let payload = digest(remote) else { return nil }
        struct Envelope: Encodable {
            let payload: String, blobRefs: [String], inc: String, incs: [String], ver: Int64, sid: String, sids: [String]
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Envelope(payload: payload, blobRefs: remote.blobRefs, inc: remote.inc, incs: remote.incs,
                                                      ver: remote.ver, sid: remote.sid, sids: remote.sids)) else { return nil }
        return sha256Hex(data)
    }

    /// A new, never-reused path for one pinned asset: `<record>/<field>-<random>`, relative to the
    /// pinned-files folder. Every pin takes a fresh one, so a path handed back for deletion can
    /// never gain a new reference between the commit and the delete.
    public static func newPinnedPath(recordName: String, field: String) -> String {
        func safe(_ text: String) -> String { String(text.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }) }
        return "\(safe(recordName))/\(safe(field))-\(UUID().uuidString.lowercased())"
    }

    /// A path may be named only by rows of one record (its quarantine row and its stored version).
    static func requireOwnedPaths(_ db: Database, _ paths: [String], by recordName: String) throws {
        for path in paths {
            let taken = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM ck_remote WHERE sealedPath=? AND recordName<>?)
                    OR EXISTS(SELECT 1 FROM ck_quarantine q, json_each(q.pinnedAssets) j
                              WHERE json_extract(j.value,'$.path')=? AND q.recordName<>?)
                """, arguments: [path, recordName, path, recordName]) ?? false
            if taken { throw CloudSyncStoreError.pinnedPathReused(path) }
        }
    }

    static func sameContent(_ remote: CloudRemoteVersion, as ancestor: Data) -> Bool {
        if let sealed = remote.sealed { return sealed == ancestor }
        if let hash = remote.sealedSha256 { return hash == sha256Hex(ancestor) }
        return false
    }

    static func json(_ values: [String]) -> String {
        String(decoding: (try? JSONEncoder().encode(values)) ?? Data("[]".utf8), as: UTF8.self)
    }
    static func decode(_ text: String?) -> [String] {
        text.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
    }
    static func decodeAssets(_ text: String?) -> [CloudPinnedAsset] {
        text.flatMap { try? JSONDecoder().decode([CloudPinnedAsset].self, from: Data($0.utf8)) } ?? []
    }
    static func encodeAssets(_ assets: [CloudPinnedAsset]) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: (try? encoder.encode(assets)) ?? Data("[]".utf8), as: UTF8.self)
    }

    static func pair(_ db: Database, _ entity: CloudEntityRef) throws -> CloudBasePair? {
        try Row.fetchOne(db, sql: "SELECT * FROM ck_record WHERE entityType=? AND entityId=?", arguments: [entity.entityType, entity.entityId]).map {
            CloudBasePair(entity: entity, systemFields: $0["systemFields"], ancestor: $0["ancestor"], ver: $0["ver"], inc: $0["inc"],
                          supersededIncs: decode($0["supersededIncs"]), sids: decode($0["sids"]))
        }
    }

    /// The single place that writes `ck_record`; private to this file's two writers.
    private static func writePair(_ db: Database, _ pair: CloudBasePair) throws {
        try db.execute(sql: """
            INSERT INTO ck_record(entityType,entityId,systemFields,ancestor,ver,inc,supersededIncs,sids) VALUES(?,?,?,?,?,?,?,?)
            ON CONFLICT(entityType,entityId) DO UPDATE SET systemFields=excluded.systemFields, ancestor=excluded.ancestor,
              ver=excluded.ver, inc=excluded.inc, supersededIncs=excluded.supersededIncs, sids=excluded.sids
            """, arguments: [pair.entity.entityType, pair.entity.entityId, pair.systemFields, pair.ancestor, pair.ver, pair.inc,
                             json(pair.supersededIncs), json(pair.sids)])
    }

    static func fetchInflight(_ db: Database, sql suffix: String, _ arguments: StatementArguments) throws -> [CloudInflight] {
        try Row.fetchAll(db, sql: "SELECT * FROM ck_inflight \(suffix)", arguments: arguments).map { row in
            CloudInflight(entity: CloudEntityRef(entityType: row["entityType"], entityId: row["entityId"]), localId: row["localId"],
                          generation: row["generation"], attemptId: row["attemptId"], baseSystemFields: row["baseSystemFields"],
                          baseAncestor: row["baseAncestor"], baseVer: row["baseVer"], inc: row["inc"], sealed: row["sealed"],
                          blobRefs: decode(row["blobRefs"]), state: CloudInflight.State(rawValue: row["state"]) ?? .unknown,
                          accountGeneration: row["generationOfAccount"], preparedAt: row["preparedAt"], sids: decode(row["sids"]))
        }
    }

    static func remote(_ db: Database, _ recordName: String) throws -> CloudRemoteVersion? {
        try Row.fetchOne(db, sql: "SELECT * FROM ck_remote WHERE recordName=?", arguments: [recordName]).map(remoteVersion)
    }
    static func remoteVersion(_ row: Row) -> CloudRemoteVersion {
        var version = CloudRemoteVersion(
            entity: CloudEntityRef(entityType: row["entityType"], entityId: row["entityId"]), inc: row["inc"], incs: decode(row["incs"]),
            ver: row["ver"], sid: row["sid"], sids: decode(row["sids"]), systemFields: row["systemFields"], sealed: row["sealed"],
            sealedPath: row["sealedPath"], sealedSha256: row["sealedSha256"], blobRefs: decode(row["blobRefs"]),
            receivedAt: row["receivedAt"], waitingFor: (row["waitingFor"] as String?).flatMap(CloudRemoteVersion.Waiting.init))
        version.recordName = row["recordName"]
        return version
    }

    static func missing(_ db: Database, _ entity: CloudEntityRef) throws -> CloudMissingRow? {
        try Row.fetchOne(db, sql: "SELECT * FROM ck_missing WHERE entityType=? AND entityId=?", arguments: [entity.entityType, entity.entityId]).map(missingRow)
    }
    static func missingRow(_ row: Row) -> CloudMissingRow {
        CloudMissingRow(entity: CloudEntityRef(entityType: row["entityType"], entityId: row["entityId"]),
                        lastVer: row["lastVer"], lastInc: row["lastInc"], reason: row["reason"])
    }

    static func quarantineRow(_ row: Row) -> CloudQuarantineRow {
        let type: String? = row["entityType"], id: String? = row["entityId"]
        return CloudQuarantineRow(recordName: row["recordName"], entity: type.flatMap { t in id.map { CloudEntityRef(entityType: t, entityId: $0) } },
                                  reason: row["reason"], v: row["v"], rawFields: row["rawFields"], pinnedAssets: decodeAssets(row["pinnedAssets"]),
                                  ignoredByUser: row["ignoredByUser"], attempts: row["attempts"])
    }

    @discardableResult
    static func writeQuarantine(_ db: Database, _ record: CloudQuarantineRecord, pinned: [CloudPinnedAsset], now: Date) throws -> [String] {
        let entity = CloudEntityRef.parse(recordName: record.recordName)
        try requireOwnedPaths(db, pinned.map(\.path), by: record.recordName)
        let previous = try String.fetchOne(db, sql: "SELECT pinnedAssets FROM ck_quarantine WHERE recordName=?", arguments: [record.recordName])
            .map { decodeAssets($0).map(\.path) } ?? []
        try db.execute(sql: """
            INSERT INTO ck_quarantine(recordName,entityType,entityId,reason,v,rawFields,pinnedAssets,ignoredByUser,firstSeen,attempts)
            VALUES(?,?,?,?,?,?,?,0,?,0)
            ON CONFLICT(recordName) DO UPDATE SET
              ignoredByUser = CASE WHEN ck_quarantine.rawFields = excluded.rawFields THEN ck_quarantine.ignoredByUser ELSE 0 END,
              attempts = CASE WHEN ck_quarantine.rawFields = excluded.rawFields THEN ck_quarantine.attempts + 1 ELSE 0 END,
              reason=excluded.reason, v=excluded.v, rawFields=excluded.rawFields, pinnedAssets=excluded.pinnedAssets
            """, arguments: [record.recordName, entity?.entityType, entity?.entityId, record.reason, record.v, record.rawFields,
                             encodeAssets(pinned), now])
        let kept = Set(pinned.map(\.path))
        return try unreferenced(db, previous.filter { !kept.contains($0) })
    }

    /// The paths among `candidates` that no quarantine row and no stored remote version names.
    /// Called after the rows were changed, so the result is what is safe to delete after the commit.
    static func unreferenced(_ db: Database, _ candidates: [String]) throws -> [String] {
        try candidates.filter { path in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM ck_remote WHERE sealedPath=?)
                    OR EXISTS(SELECT 1 FROM ck_quarantine q, json_each(q.pinnedAssets) j WHERE json_extract(j.value,'$.path')=?)
                """, arguments: [path, path]) != true
        }
    }

    static func quarantineDivergent(_ db: Database, _ remote: CloudRemoteVersion, now: Date) throws -> CloudStoreRemoteOutcome {
        let obsolete = try writeQuarantine(db, CloudQuarantineRecord(recordName: remote.recordName, reason: "divergent-version", v: nil, rawFields: remote.rawFields),
                                           pinned: remote.pinnedAssets, now: now)
        return .quarantinedDivergent(obsoletePinnedPaths: obsolete)
    }

    static func deleteQuarantine(_ db: Database, entity: CloudEntityRef) throws -> [String] {
        let rows = try Row.fetchAll(db, sql: "SELECT recordName FROM ck_quarantine WHERE entityType=? AND entityId=?",
                                    arguments: [entity.entityType, entity.entityId])
        return try rows.flatMap { try deleteQuarantine(db, recordName: $0["recordName"]) }
    }
    static func deleteQuarantine(_ db: Database, recordName: String) throws -> [String] {
        let paths = try String.fetchOne(db, sql: "SELECT pinnedAssets FROM ck_quarantine WHERE recordName=?", arguments: [recordName])
            .map { decodeAssets($0).map(\.path) } ?? []
        try db.execute(sql: "DELETE FROM ck_quarantine WHERE recordName=?", arguments: [recordName])
        return try unreferenced(db, paths)
    }
}
