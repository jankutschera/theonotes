// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB

/// Reads just the note-vault envelope; callers fence only the subsequent local install.
struct CloudVaultIntake: Sendable {
    let database: AppDatabase
    let gateway: any CloudKitGateway
    let accountID: String
    let vaultKey: SymmetricKey

    struct Candidate: Sendable {
        fileprivate let header: CloudEntityHeader, bytes: Data, sealed: Data, noteKey: SymmetricKey
        fileprivate let generation: Int64, bundleRevision: Int64
        fileprivate let boundAccount: String?, syncAccount: String?, cloudUser: String?, observedUser: String
    }
    private struct Fetched: Sendable {
        let header: CloudEntityHeader, sealed: Data, bytes: Data
        let generation: Int64, bundleRevision: Int64
        let boundAccount: String?, syncAccount: String?, cloudUser: String?, observedUser: String
    }

    func scan(password: String) async throws -> Candidate? {
        guard let fetched = try await fetch() else { return nil }
        let noteKey = try JSONDecoder().decode(CryptoEnvelope.self, from: fetched.bytes).unwrap(password: password)
        return Candidate(header: fetched.header, bytes: fetched.bytes, sealed: fetched.sealed, noteKey: noteKey, generation: fetched.generation,
                         bundleRevision: fetched.bundleRevision, boundAccount: fetched.boundAccount, syncAccount: fetched.syncAccount,
                         cloudUser: fetched.cloudUser, observedUser: fetched.observedUser)
    }

    func vaultIsAbsent() async throws -> Bool { try await fetch() == nil }

    func unopenableLockedNoteCount(for candidate: Candidate) async throws -> Int {
        try await database.pool.read { try VaultIntakeKeyProof.unopenableCount(key: candidate.noteKey, in: $0).0 }
    }

    private func fetch() async throws -> Fetched? {
        let snapshot = try await database.pool.read { db -> (String, Int64, Int64, String?, String?, String?) in
            let id = try String.fetchOne(db, sql: "SELECT entityId FROM sync_entity_state WHERE entityType='keyBundle' AND localId='lock-vault'")
                ?? CloudPayloadSealer.derivedEntityID(type: .keyBundle, semantic: "lock-vault", vaultKey: vaultKey)
            let state = try Row.fetchOne(db, sql: "SELECT generation, bundleRevision, accountId, cloudUserHash FROM ck_state WHERE id=1")!
            let syncAccount = try String.fetchOne(db, sql: "SELECT accountId FROM sync_control WHERE id=1")
            return (id, state["generation"], state["bundleRevision"], state["accountId"], syncAccount, state["cloudUserHash"])
        }
        guard (snapshot.3 == nil || snapshot.3 == accountID), (snapshot.4 == nil || snapshot.4 == accountID) else { throw CloudCoordinatorError.accountNotCurrent }
        guard case .available(let user) = await gateway.accountState(), snapshot.5 == nil || snapshot.5 == user else {
            throw CloudCoordinatorError.accountNotCurrent
        }
        let name = CloudRecordCodec.entityRecordName(type: .keyBundle, id: snapshot.0)
        let record = try await gateway.fetch([name], keys: nil)[name]
        guard case .available(let current) = await gateway.accountState(), current == user else { throw CloudCoordinatorError.accountNotCurrent }
        guard let record else { return nil }
        guard case .entity(let header) = try CloudRecordCodec.decode(record), header.entityType == .keyBundle,
              header.entityId == snapshot.0, header.blobs.isEmpty, case .inline(let sealed) = header.payload else {
            throw SyncProtocolError.invalidPayload
        }
        let reader = CloudRemoteReader(sealer: CloudPayloadSealer(accountID: accountID, vaultKey: vaultKey))
        let bytes: Data
        switch try reader.read(sealed: sealed, type: .keyBundle, entityId: header.entityId, blobRefs: []) {
        case .deleted: return nil
        case .lockEnvelope(let envelope): bytes = envelope
        default: throw SyncProtocolError.invalidPayload
        }
        return Fetched(header: header, sealed: sealed, bytes: bytes, generation: snapshot.1, bundleRevision: snapshot.2,
                       boundAccount: snapshot.3, syncAccount: snapshot.4, cloudUser: snapshot.5, observedUser: user)
    }

    func install(_ candidate: Candidate, fenced: @Sendable (@Sendable () async throws -> Bool) async throws -> Bool) async throws -> Bool {
        guard case .available(let current) = await gateway.accountState(), current == candidate.observedUser else {
            throw CloudCoordinatorError.accountNotCurrent
        }
        return try await fenced {
            try await installUnderFence(candidate)
        }
    }

    private func installUnderFence(_ candidate: Candidate) async throws -> Bool {
        try await database.pool.write { db in
            let state = try Row.fetchOne(db, sql: "SELECT generation, bundleRevision, accountId, cloudUserHash, fenced FROM ck_state WHERE id=1")!
            guard (state["generation"] as Int64) == candidate.generation,
                  (state["bundleRevision"] as Int64) == candidate.bundleRevision,
                  (state["accountId"] as String?) == candidate.boundAccount,
                  (state["cloudUserHash"] as String?) == candidate.cloudUser,
                  (state["fenced"] as Bool) == false,
                  try String.fetchOne(db, sql: "SELECT accountId FROM sync_control WHERE id=1") == candidate.syncAccount,
                  try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(SELECT 1 FROM crypto_envelope)
                      OR EXISTS(SELECT 1 FROM privacy_transition) OR EXISTS(SELECT 1 FROM sync_dirty WHERE entityType='keyBundle')
                      OR EXISTS(SELECT 1 FROM ck_inflight WHERE entityType='keyBundle')
                      OR EXISTS(SELECT 1 FROM ck_missing WHERE entityType='keyBundle')
                      OR EXISTS(SELECT 1 FROM ck_quarantine WHERE entityType='keyBundle' AND ignoredByUser=0)
                    """) == false else { throw SyncQueueError.snapshotUnavailable }
            try VaultIntakeKeyProof.requireMatch(key: candidate.noteKey, in: db)
            let header = candidate.header
            let states = try Row.fetchAll(db, sql: "SELECT entityId,serverRevision FROM sync_entity_state WHERE entityType='keyBundle'")
            for row in states {
                guard (row["entityId"] as String) == header.entityId else { throw SyncQueueError.snapshotUnavailable }
                guard (row["serverRevision"] as Int64) <= header.ver else { return false }
            }
            let known = try Row.fetchAll(db, sql: "SELECT entityId,inc,ver,ancestor AS sealed FROM ck_record WHERE entityType='keyBundle'")
                + Row.fetchAll(db, sql: "SELECT entityId,inc,ver,sealed FROM ck_remote WHERE entityType='keyBundle'")
            for row in known {
                guard (row["entityId"] as String) == header.entityId else { throw SyncQueueError.snapshotUnavailable }
                let inc: String = row["inc"], ver: Int64 = row["ver"]
                guard inc == header.inc || header.incs.contains(inc) else { return false }
                if inc == header.inc {
                    guard ver <= header.ver else { return false }
                    if ver == header.ver, (row["sealed"] as Data?) != candidate.sealed { throw SyncQueueError.snapshotUnavailable }
                }
            }
            try db.execute(sql: "UPDATE sync_control SET applying=1 WHERE id=1")
            try db.execute(sql: "INSERT INTO crypto_envelope(id,envelope) VALUES(1,?)", arguments: [candidate.bytes])
            try db.execute(sql: "UPDATE sync_control SET applying=0 WHERE id=1")
            return true
        }
    }
}
