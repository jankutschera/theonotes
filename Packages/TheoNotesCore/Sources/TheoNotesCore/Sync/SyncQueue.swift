// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB

public enum SyncQueueError: Error, Equatable {
    case accountMismatch, notEnabled, invalidReceipt, mutationNotFound, snapshotUnavailable
    /// This library moved to iCloud; the private-server engine never binds it again.
    case movedToICloud
}

struct SyncDirty: Sendable {
    let type: SyncEntityType
    let localID: String
    let generation: Int64
    let tombstone: Bool
}
struct SyncContent: Sendable {
    let payload: Data?
    var blobRefs: [String] = []
}

/// A durable, encrypted outbox. Dirty markers are written by the semantic-row SQL triggers in
/// the exact transaction that saves the edit. Prepared mutations are immutable until their
/// receipt is persisted; newer edits keep a higher generation behind the in-flight mutation.
public struct SyncQueue: Sendable {
    let database: AppDatabase
    public init(database: AppDatabase) { self.database = database }

    public func isEnabled() throws -> Bool {
        try database.pool.read { try Bool.fetchOne($0, sql: "SELECT enabled FROM sync_control WHERE id=1") == true }
    }
    public func hasRemoteState() throws -> Bool {
        try database.pool.read { try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM sync_shadow) OR EXISTS(SELECT 1 FROM sync_inbox) OR EXISTS(SELECT 1 FROM sync_outbox)") == true }
    }

    /// Reserve this library for the validated account and start durable local edit capture
    /// before its first download/reconciliation. Uploads remain disabled until the verified
    /// first-sync backup and reconciliation finish; repeating the same account preserves work.
    public func configure(accountID: String) throws {
        try SyncWire.validateID(accountID)
        try database.pool.write { db in
            let current = try String.fetchOne(db, sql: "SELECT accountId FROM sync_control WHERE id=1")
            guard current == nil || current == accountID else { throw SyncQueueError.accountMismatch }
            if try PrivateServerMove.hasLeft(db) { throw SyncQueueError.movedToICloud }
            // A library bound to CloudKit belongs to that engine, whatever account id is offered.
            guard try String.fetchOne(db, sql: "SELECT backend FROM sync_control WHERE id=1") != "cloudkit" else { throw SyncQueueError.accountMismatch }
            try db.execute(sql: "UPDATE sync_control SET accountId=? WHERE id=1", arguments: [accountID])
        }
    }

    /// Evaluate only after a successful full engine cycle and the verified first-sync backup.
    /// A locally edited attachment can make reconciliation wait for its own first upload;
    /// permit only that bounded escape while keeping unresolved password envelopes gated.
    /// This check never enables capture/uploads or changes account ownership.
    public func canEnableAfterInitialDownload(_ summary: SyncRunSummary) throws -> Bool {
        if summary.pendingDownloads == 0 { return true }
        guard summary.waitingForUploads > 0, summary.waitingForUnlock == 0 else { return false }
        return try database.pool.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT NOT EXISTS(SELECT 1 FROM sync_inbox WHERE entityType='keyBundle' OR waitingForUnlock=1)
                  AND EXISTS(SELECT 1 FROM sync_dirty WHERE entityType='attachment')
                """) == true
        }
    }

    /// Caller must finish the verified first-sync backup and persist device keys before enabling.
    /// Repeating this for the same account preserves the queue; changing accounts never clears it.
    /// Seed only unsynchronized rows; pre-enable edits already have durable dirty markers.
    public func enable(accountID: String) throws {
        try SyncWire.validateID(accountID)
        try database.pool.write { db in
            let current = try String.fetchOne(db, sql: "SELECT accountId FROM sync_control WHERE id=1")
            if let current, current != accountID { throw SyncQueueError.accountMismatch }
            if try PrivateServerMove.hasLeft(db) { throw SyncQueueError.movedToICloud }
            guard try String.fetchOne(db, sql: "SELECT backend FROM sync_control WHERE id=1") != "cloudkit" else { throw SyncQueueError.accountMismatch }
            if try Bool.fetchOne(db, sql: "SELECT enabled FROM sync_control WHERE id=1") == true { return }
            try db.execute(sql: "UPDATE sync_control SET enabled=1,accountId=? WHERE id=1", arguments: [accountID])
            for (table, type, key, condition) in [
                ("note", "note", "local.id", "1"), ("attachment", "attachment", "local.id", "1"),
                ("tag", "tagPreference", "local.id", "1"),
                ("setting", "setting", "local.key", "key IN ('hideMarkdown','showNoteCounts','autoSortTodos','showHeadingLevels','autocomplete','startNoteTemplate','tagPosition','noteSort')"),
                ("external_ref", "externalRef", "json_array(local.source,local.externalId)", "1"),
                ("crypto_envelope", "keyBundle", "'lock-vault'", "1"),
            ] {
                try db.execute(sql: """
                    INSERT INTO sync_dirty(entityType,localId,generation,tombstone)
                    SELECT ?,\(key),1,0 FROM \(table) AS local WHERE \(condition)
                      AND NOT EXISTS(SELECT 1 FROM sync_entity_state s
                        WHERE s.entityType=? AND s.localId=\(key)
                          AND s.serverRevision>0)
                    ON CONFLICT(entityType,localId) DO NOTHING
                    """, arguments: [type, type])
            }
        }
    }

    public func pendingMutations(limit: Int = 100) throws -> [SyncMutation] {
        try database.pool.read { db in
            try Data.fetchAll(db, sql: "SELECT wireMutation FROM sync_outbox ORDER BY ordinal LIMIT ?", arguments: [max(1, min(limit, 100))])
                .map { data in
                    let value = try JSONDecoder().decode(SyncMutation.self, from: data)
                    try value.validate(); return value
                }
        }
    }
    /// Total dirty entities, including retained work with unavailable local attachment bytes.
    public func pendingCount() throws -> Int {
        try database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_dirty") ?? 0 }
    }

    /// A read-only snapshot of dirty work, partitioned by attachment source availability.
    /// Immutable outbox entries remain pending; otherwise current-generation ciphertext or
    /// its server upload acknowledgement can stand in for the original source. Local files
    /// are safely opened and stat'ed without reading/hashing their contents. These counts
    /// do not certify ciphertext integrity, network readiness, or staging/privacy eligibility.
    /// Files can change immediately after the snapshot; capture and upload still validate them.
    public func pendingUploadCounts(paths: AppPaths) throws -> (pendingUploads: Int, unavailableAttachments: Int) {
        try database.pool.read { db in
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_dirty") ?? 0
            let unavailable = try Self.unavailableAttachments(paths: paths, in: db).count
            return (total - unavailable, unavailable)
        }
    }

    /// Every dirty attachment whose bytes are on this device in no form (the source file, a prepared upload or its
    /// acknowledgement): it can never be sent. One entry per attachment, with its note.
    static func unavailableAttachments(paths: AppPaths, in db: Database) throws -> [(id: String, noteId: String)] {
        let candidates = try Row.fetchAll(db, sql: """
            SELECT a.id,a.noteId,a.filename,c.blobHash,b.localPath,b.byteSize,b.uploaded,
              length(b.data) AS dataBytes
            FROM sync_dirty d JOIN attachment a ON a.id=d.localId
            LEFT JOIN sync_attachment_cache c ON c.attachmentId=d.localId AND c.generation=d.generation
            LEFT JOIN sync_blob_state b ON b.hash=c.blobHash
            WHERE d.entityType='attachment' AND d.tombstone=0
              AND NOT EXISTS(SELECT 1 FROM sync_outbox o
                WHERE o.entityType='attachment' AND o.localId=d.localId)
            """)
        var unavailable: [(id: String, noteId: String)] = []
        for row in candidates {
            try Task.checkCancellation()
            if SyncAttachmentPreparer.hasSource(paths: paths, noteId: row["noteId"], filename: row["filename"]) { continue }
            if let uploaded: Bool = row["uploaded"], uploaded { continue }
            if let size: Int64 = row["byteSize"], size > 0, size <= SyncWire.maximumBlobBytes {
                // Match the uploader's preference for a stored path over inline bytes.
                if let path: String = row["localPath"], let hash: String = row["blobHash"] {
                    if SyncBlobLocation.isPresent(path, paths: paths, hash: hash, size: size) { continue }
                } else if let bytes: Int64 = row["dataBytes"], bytes == size { continue }
            }
            unavailable.append((row["id"], row["noteId"]))
        }
        return unavailable
    }

    /// Prepare semantic payloads after `SyncAttachmentPreparer` has staged file ciphertext.
    public func prepareNext(vaultKey: SymmetricKey) throws -> SyncMutation? {
        try prepareNext(vaultKey: vaultKey) { db, dirty in
            if dirty.type == .attachment {
                guard let account = try String.fetchOne(db, sql: "SELECT accountId FROM sync_control WHERE enabled=1") else { throw SyncQueueError.notEnabled }
                return try SyncAttachmentPreparer.capture(dirty, accountID: account, vaultKey: vaultKey, in: db)
            }
            if dirty.type == .note {
                guard let account = try String.fetchOne(db, sql: "SELECT accountId FROM sync_control WHERE enabled=1") else { throw SyncQueueError.notEnabled }
                return try SyncNoteSnapshot.capture(dirty, accountID: account, vaultKey: vaultKey, in: db)
            }
            return try SyncPayloadCodec.capture(dirty, in: db)
        }
    }

    /// The resolver runs inside the write transaction so ciphertext and generation describe the
    /// same committed snapshot. Returning nil means a tombstone, never an empty note body.
    func prepareNext(vaultKey: SymmetricKey, resolve: (Database, SyncDirty) throws -> SyncContent) throws -> SyncMutation? {
        try database.pool.write { db in
            guard let account = try String.fetchOne(db, sql: "SELECT accountId FROM sync_control WHERE id=1 AND enabled=1")
            else { throw SyncQueueError.notEnabled }
            let rows = try Row.fetchAll(db, sql: """
                SELECT d.* FROM sync_dirty d WHERE NOT EXISTS(SELECT 1 FROM sync_outbox o
                  WHERE o.entityType=d.entityType AND o.localId=d.localId)
                ORDER BY CASE d.entityType WHEN 'keyBundle' THEN 0 WHEN 'attachment' THEN 1 ELSE 2 END,d.entityType,d.localId
                """)
            for row in rows {
                guard let type = SyncEntityType(rawValue: row["entityType"]) else { throw SyncProtocolError.unsupportedVersion }
                let dirty = SyncDirty(type: type, localID: row["localId"], generation: row["generation"], tombstone: row["tombstone"])
                let content: SyncContent
                do { content = dirty.tombstone ? SyncContent(payload: nil) : try resolve(db, dirty) }
                catch SyncQueueError.snapshotUnavailable { continue }
                let existing = try Row.fetchOne(db, sql: "SELECT * FROM sync_entity_state WHERE entityType=? AND localId=?", arguments: [type.rawValue, dirty.localID])
                let entityID: String
                if let prior: String = existing?["entityId"] { entityID = prior }
                else if type == .note || type == .attachment { entityID = dirty.localID }
                else {
                    // Different devices have different SQLite tag UUIDs. Their same semantic
                    // preference must share one CAS entity without revealing its plaintext key.
                    let semantic = type == .tagPreference
                        ? (try String.fetchOne(db, sql: "SELECT pathKey FROM tag WHERE id=?", arguments: [dirty.localID]) ?? dirty.localID)
                        : dirty.localID
                    let input = Data("\(ProtocolLabels.semanticID):\(type.rawValue):\(semantic)".utf8)
                    entityID = "m-" + HMAC<SHA256>.authenticationCode(for: input, using: vaultKey).map { String(format: "%02x", $0) }.joined()
                }
                let revision: Int64 = existing?["serverRevision"] ?? 0
                if existing == nil {
                    try db.execute(sql: "INSERT INTO sync_entity_state(entityType,localId,entityId) VALUES(?,?,?)", arguments: [type.rawValue, dirty.localID, entityID])
                }
                var mutation = SyncMutation(mutationId: UUIDv7.make(), entityType: type, entityId: entityID,
                                            parentRevision: revision, tombstone: content.payload == nil)
                if let payload = content.payload {
                    guard payload.count <= 4_194_304 else { throw SyncProtocolError.responseTooLarge }
                    let context = try SyncWire.cipherContext(accountID: account, type: type, entityID: entityID)
                    let cipher = try NoteCipher.seal(payload, vaultKey: vaultKey, context: context)
                    mutation.blobRefs = content.blobRefs
                    if cipher.count <= SyncWire.inlineBytes { mutation.ciphertext = SyncWire.base64(cipher) }
                    else {
                        let hash = SyncWire.hash(cipher)
                        mutation.payloadRef = hash
                        if !mutation.blobRefs.contains(hash) { mutation.blobRefs.append(hash) }
                        try db.execute(sql: "INSERT OR IGNORE INTO sync_blob_state(hash,data,byteSize) VALUES(?,?,?)", arguments: [hash, cipher, cipher.count])
                    }
                }
                try mutation.validate()
                let wire = try JSONEncoder().encode(mutation)
                try db.execute(sql: """
                    INSERT INTO sync_outbox(mutationId,entityType,localId,generation,wireMutation) VALUES(?,?,?,?,?)
                    """, arguments: [mutation.mutationId, type.rawValue, dirty.localID, dirty.generation, wire])
                return mutation
            }
            return nil
        }
    }

    /// Persist an accepted receipt before removing its queued generation. Newer edits remain
    /// dirty and use this server revision as their next CAS parent. Pull cursor is independent.
    public func accept(_ receipt: SyncEntity) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let receiptHash = SyncWire.hash(try encoder.encode(receipt))
        try database.pool.write { db in
            if let prior = try String.fetchOne(db, sql: "SELECT receiptHash FROM sync_receipt WHERE mutationId=?", arguments: [receipt.mutation.mutationId]) {
                guard prior == receiptHash else { throw SyncQueueError.invalidReceipt }
                return
            }
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM sync_outbox WHERE mutationId=?", arguments: [receipt.mutation.mutationId]) else {
                // An already persisted receipt is harmless to repeat, but must match exactly.
                guard let shadow = try Data.fetchOne(db, sql: "SELECT wireEntity FROM sync_shadow WHERE entityType=? AND entityId=?",
                    arguments: [receipt.mutation.entityType.rawValue, receipt.mutation.entityId]),
                      try JSONDecoder().decode(SyncEntity.self, from: shadow) == receipt
                else { throw SyncQueueError.mutationNotFound }
                return
            }
            let expected = try JSONDecoder().decode(SyncMutation.self, from: row["wireMutation"])
            guard expected == receipt.mutation, receipt.revision == expected.parentRevision + 1,
                  receipt.sequence > 0, receipt.sequence <= SyncWire.maximumRevision
            else { throw SyncQueueError.invalidReceipt }
            try receipt.mutation.validate()
            try db.execute(sql: "UPDATE sync_entity_state SET serverRevision=MAX(serverRevision,?) WHERE entityType=? AND localId=?",
                           arguments: [receipt.revision, expected.entityType.rawValue, row["localId"] as String])
            try db.execute(sql: """
                INSERT INTO sync_shadow(entityType,entityId,serverRevision,sequence,wireEntity) VALUES(?,?,?,?,?)
                ON CONFLICT(entityType,entityId) DO UPDATE SET serverRevision=excluded.serverRevision,
                  sequence=excluded.sequence,wireEntity=excluded.wireEntity
                WHERE excluded.serverRevision > sync_shadow.serverRevision
                """, arguments: [expected.entityType.rawValue, expected.entityId, receipt.revision, receipt.sequence, try JSONEncoder().encode(receipt)])
            try db.execute(sql: "DELETE FROM sync_dirty WHERE entityType=? AND localId=? AND generation=?",
                           arguments: [expected.entityType.rawValue, row["localId"] as String, row["generation"] as Int64])
            try db.execute(sql: "DELETE FROM sync_outbox WHERE mutationId=?", arguments: [expected.mutationId])
            try db.execute(sql: "INSERT INTO sync_receipt(mutationId,receiptHash) VALUES(?,?)", arguments: [expected.mutationId, receiptHash])
        }
    }

    /// The caller applies an entire validated pull page and its cursor in this transaction.
    /// Triggers are suppressed only within this write; failures roll back both data and cursor.
    func applyRemote(cursor: Int64, _ body: (Database) throws -> Void) throws {
        guard cursor >= 0, cursor <= SyncWire.maximumRevision else { throw SyncProtocolError.invalidRevision }
        try database.pool.write { db in
            try db.execute(sql: "UPDATE sync_control SET applying=1 WHERE id=1")
            try body(db)
            try db.execute(sql: "UPDATE sync_cursor SET sequence=MAX(sequence,?) WHERE id=1", arguments: [cursor])
            try db.execute(sql: "UPDATE sync_control SET applying=0 WHERE id=1")
        }
    }
}
