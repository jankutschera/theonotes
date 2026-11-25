// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

// What the receiver (Task 6) needs from the store beyond the invariant methods of `CloudSyncStore`. Nothing here writes
// `ck_record` (the base pair keeps its two writers, I1) or `sync_dirty`.
extension CloudSyncStore {
    /// True while a stored fetched version or a quarantine row names the pinned file.
    func isPathReferenced(_ relativePath: String) throws -> Bool {
        try database.pool.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM ck_remote WHERE sealedPath=?)
                    OR EXISTS(SELECT 1 FROM ck_quarantine q, json_each(q.pinnedAssets) j WHERE json_extract(j.value,'$.path')=?)
                """, arguments: [relativePath, relativePath]) ?? false
        }
    }

    /// Every entity we hold a base pair for (the device based work on it): what a full refetch must return (CK-R5).
    func pairedEntities() throws -> [CloudEntityRef] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT entityType, entityId FROM ck_record ORDER BY entityType, entityId")
                .map { CloudEntityRef(entityType: $0["entityType"], entityId: $0["entityId"]) }
        }
    }

    /// A recovery (CK-R21) is under way: a create-only snapshot of a new incarnation is prepared or in flight. The record being
    /// absent from the cloud is then expected, not a new loss, and the entity must not pause again before the create went out.
    func isRecovering(_ entity: CloudEntityRef) throws -> Bool {
        try database.pool.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM ck_inflight f JOIN ck_record r ON r.entityType=f.entityType AND r.entityId=f.entityId
                              WHERE f.entityType=? AND f.entityId=? AND f.inc<>r.inc AND f.baseSystemFields IS NULL)
                """, arguments: [entity.entityType, entity.entityId]) ?? false
        }
    }

    /// Record names that currently have a quarantine row (ignored or not).
    func quarantinedRecordNames() throws -> Set<String> {
        try database.pool.read { Set(try String.fetchAll($0, sql: "SELECT recordName FROM ck_quarantine")) }
    }

    /// A stored fetched version that turned out unreadable when the receiver opened it (authentication failure, a payload
    /// shape or kind this build does not know): the row moves to quarantine in ONE transaction, with its pinned payload file
    /// (if it came as an asset) now owned by the quarantine row. The entity is fenced from here on (CK-R5). Only the exact
    /// version that was opened moves (record name, incarnation, `ver`, attempt id), and only for the generation it was read in.
    @discardableResult
    func quarantineRemote(_ version: CloudRemoteVersion, reason: String, payloadSize: Int64 = 0, accountGeneration: Int64) throws -> [String] {
        try database.pool.write { db in
            try Self.requireOpen(db, accountGeneration)
            guard let remote = try Self.remote(db, version.recordName), remote.inc == version.inc, remote.ver == version.ver, remote.sid == version.sid else { return [] }
            var fields: [String: CloudValue] = [
                "v": .int(CloudRecordCodec.formatVersion), "etype": .string(remote.entity.entityType), "eid": .string(remote.entity.entityId),
                "inc": .string(remote.inc), "incs": .strings(remote.incs), "ver": .int(remote.ver), "sid": .string(remote.sid),
                "sids": .strings(remote.sids), "blobs": .strings(remote.blobRefs),
            ]
            var pinned: [CloudPinnedAsset] = []
            if let sealed = remote.sealed { fields["cipher"] = .bytes(sealed) }
            if let path = remote.sealedPath, let sha = remote.sealedSha256 {
                pinned = [CloudPinnedAsset(field: "cipherAsset", path: path, size: payloadSize, sha256: sha)]
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let raw = try encoder.encode(CloudRecord(name: remote.recordName, type: .entity, fields: fields, systemFields: remote.systemFields))
            let obsolete = try Self.writeQuarantine(db, CloudQuarantineRecord(recordName: remote.recordName, reason: reason, v: CloudRecordCodec.formatVersion, rawFields: raw),
                                                    pinned: pinned, now: clock())
            try db.execute(sql: "DELETE FROM ck_remote WHERE recordName=? AND inc=? AND ver=? AND sid=?",
                           arguments: [remote.recordName, remote.inc, remote.ver, remote.sid])
            return obsolete
        }
    }

    /// Drops a stored fetched version by its exact identity and for the generation the work started in; refused while the account
    /// fence is up. Returns the pinned file nothing references any more (delete it after the commit). Work that started under an
    /// older account can therefore neither delete a row of the new account nor its pinned asset.
    @discardableResult
    func deleteRemote(_ version: CloudRemoteVersion, accountGeneration: Int64) throws -> [String] {
        try database.pool.write { db in
            try Self.requireOpen(db, accountGeneration)
            try db.execute(sql: "DELETE FROM ck_remote WHERE recordName=? AND inc=? AND ver=? AND sid=?",
                           arguments: [version.recordName, version.inc, version.ver, version.sid])
            guard db.changesCount > 0 else { return [] }
            return try Self.unreferenced(db, version.sealedPath.map { [$0] } ?? [])
        }
    }

    /// Records why a stored version waits, on that exact version, for the generation the work started in.
    func setWaiting(_ version: CloudRemoteVersion, _ waiting: CloudRemoteVersion.Waiting?, accountGeneration: Int64) throws {
        try database.pool.write { db in
            try Self.requireOpen(db, accountGeneration)
            try db.execute(sql: "UPDATE ck_remote SET waitingFor=? WHERE recordName=? AND inc=? AND ver=? AND sid=?",
                           arguments: [waiting?.rawValue, version.recordName, version.inc, version.ver, version.sid])
        }
    }

    /// Releases a quarantine row only if it still holds exactly the record the caller looked at, for the generation the work
    /// started in, and never while the account fence is up. Returns the pinned files nothing references any more.
    @discardableResult
    func releaseQuarantine(recordName: String, matchingRaw: Data, accountGeneration: Int64) throws -> [String] {
        try database.pool.write { db in
            try Self.requireOpen(db, accountGeneration)
            guard let raw = try Data.fetchOne(db, sql: "SELECT rawFields FROM ck_quarantine WHERE recordName=?", arguments: [recordName]), raw == matchingRaw else { return [] }
            return try Self.deleteQuarantine(db, recordName: recordName)
        }
    }

    /// The paths among `paths` that no stored fetched version and no quarantine row names any more.
    func unreferencedPaths(_ paths: [String]) throws -> [String] {
        try database.pool.read { try Self.unreferenced($0, paths) }
    }

    /// The quarantine row of a record name, if any.
    func quarantineRow(recordName: String) throws -> CloudQuarantineRow? {
        try database.pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM ck_quarantine WHERE recordName=?", arguments: [recordName]).map(Self.quarantineRow)
        }
    }

    /// Quarantine rows of one entity.
    func quarantineRows(entity: CloudEntityRef) throws -> [CloudQuarantineRow] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM ck_quarantine WHERE entityType=? AND entityId=?", arguments: [entity.entityType, entity.entityId])
                .map(Self.quarantineRow)
        }
    }
}
