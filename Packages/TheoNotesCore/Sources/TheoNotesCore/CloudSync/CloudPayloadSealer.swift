// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB

// The transport-free sealed payload (CK-R17, CK-R19). Defined in docs/superpowers/specs/2026-10-28-sync-payload-v1.md
// and pinned by Fixtures/sync/cloudsync-payload-v1.json. This file knows nothing about where a sealed payload travels:
// no record, no change tag, no state table. A second transport (our own server, the user's own storage) reuses it as is.
//
//   sealed    = BNC1(plaintext, vaultKey, context)
//   context   = "baerchen-sync:1:<accountId>:<entityType>:<entityId>:1"      (frozen, REN2-R2)
//   plaintext = kind || body          kind 0x01 live (body = payload JSON), 0x02 deleted (body = {"at": <ms>})

/// The first plaintext byte (CK-R17). Sealing the kind makes a deletion indistinguishable from an edit to anyone without the key.
public enum SealedPayloadKind: UInt8, Sendable {
    case live = 0x01
    case deleted = 0x02
}

public enum OpenedPayload: Sendable, Equatable {
    /// The payload JSON exactly as the existing capture code wrote it (sorted keys, unescaped slashes, base64url data).
    case live(Data)
    /// Milliseconds since 1970 (UTC) at which the entity was deleted on the sealing device.
    case deleted(atMillis: Int64)
}

public struct CloudPayloadSealer: Sendable {
    /// The largest payload JSON, as `SyncQueue.prepareNext` allows (the kind byte comes on top).
    public static let maximumPayloadBytes = 4_194_304

    public let accountID: String
    private let vaultKey: SymmetricKey

    public init(accountID: String, vaultKey: SymmetricKey) {
        self.accountID = accountID; self.vaultKey = vaultKey
    }

    public func context(type: SyncEntityType, entityID: String) throws -> String {
        try SyncWire.cipherContext(accountID: accountID, type: type, entityID: entityID)
    }

    // MARK: seal

    public func sealLive(_ payload: Data, type: SyncEntityType, entityID: String) throws -> Data {
        guard payload.count <= Self.maximumPayloadBytes else { throw SyncProtocolError.responseTooLarge }
        return try NoteCipher.seal(Data([SealedPayloadKind.live.rawValue]) + payload, vaultKey: vaultKey,
                                   context: try context(type: type, entityID: entityID))
    }

    public func sealDeleted(atMillis: Int64, type: SyncEntityType, entityID: String) throws -> Data {
        try NoteCipher.seal(Data([SealedPayloadKind.deleted.rawValue]) + Self.deletionBody(atMillis: atMillis), vaultKey: vaultKey,
                            context: try context(type: type, entityID: entityID))
    }

    /// `content.payload == nil` is the existing capture code's way to say "deleted".
    func seal(_ content: SyncContent, type: SyncEntityType, entityID: String, deletedAt: Date) throws -> Data {
        if let payload = content.payload { return try sealLive(payload, type: type, entityID: entityID) }
        return try sealDeleted(atMillis: Int64((deletedAt.timeIntervalSince1970 * 1000).rounded()), type: type, entityID: entityID)
    }

    static func deletionBody(atMillis: Int64) -> Data { Data("{\"at\":\(atMillis)}".utf8) }

    // MARK: open

    /// Authenticates the ciphertext against this account, entity type and entity id (a payload sealed for another entity
    /// fails), then splits the kind byte. Typed validation of a live payload is the reader's job (spec section 4).
    public func open(_ sealed: Data, type: SyncEntityType, entityID: String) throws -> OpenedPayload {
        let plain = try NoteCipher.open(sealed, vaultKey: vaultKey, context: try context(type: type, entityID: entityID))
        guard let kind = plain.first, plain.count <= Self.maximumPayloadBytes + 1 else { throw SyncProtocolError.invalidPayload }
        let body = Data(plain.dropFirst())
        switch SealedPayloadKind(rawValue: kind) {
        case .live?: return .live(body)
        case .deleted?:
            struct Stamp: Decodable { let at: Int64 }
            guard let stamp = try? JSONDecoder().decode(Stamp.self, from: body), stamp.at >= 0 else { throw SyncProtocolError.invalidPayload }
            return .deleted(atMillis: stamp.at)
        case nil: throw SyncProtocolError.unsupportedVersion
        }
    }

    // MARK: capture (the existing functions, called as they are)

    /// The immutable content of one dirty row, in the same transaction as the generation read: attachments, notes and the
    /// rest each through the function the Cloudflare engine uses. A tombstone carries no payload. May throw
    /// `SyncQueueError.snapshotUnavailable` (the caller skips the row and retries later).
    static func capture(_ dirty: SyncDirty, accountID: String, vaultKey: SymmetricKey, in db: Database) throws -> SyncContent {
        if dirty.tombstone { return SyncContent(payload: nil) }
        switch dirty.type {
        case .attachment: return try SyncAttachmentPreparer.capture(dirty, accountID: accountID, vaultKey: vaultKey, in: db)
        case .note: return try SyncNoteSnapshot.capture(dirty, accountID: accountID, vaultKey: vaultKey, in: db)
        default: return try SyncPayloadCodec.capture(dirty, in: db)
        }
    }

    /// The entity id of a local row, the same rule as `SyncQueue.prepareNext`: an id already mapped wins; notes and
    /// attachments keep their local id; every other type gets an HMAC of its semantic key so two devices agree on it
    /// without revealing it. Records the mapping in `sync_entity_state` (reused table, `serverRevision` stays 0).
    static func entityID(for dirty: SyncDirty, vaultKey: SymmetricKey, in db: Database) throws -> String {
        if let prior = try String.fetchOne(db, sql: "SELECT entityId FROM sync_entity_state WHERE entityType=? AND localId=?",
                                           arguments: [dirty.type.rawValue, dirty.localID]) { return prior }
        let semantic = dirty.type == .tagPreference
            ? (try String.fetchOne(db, sql: "SELECT pathKey FROM tag WHERE id=?", arguments: [dirty.localID]) ?? dirty.localID)
            : dirty.localID
        let id = derivedEntityID(type: dirty.type, semantic: semantic, vaultKey: vaultKey)
        // The entity id is derived from the semantic key, so it is the same for every local row that stands for it. A tag row that
        // left every note and came back has a new local id for the same path: the map follows the current row (the insert alone
        // would fail on the unique entity id for ever).
        try db.execute(sql: "DELETE FROM sync_entity_state WHERE entityType=? AND entityId=? AND localId<>?",
                       arguments: [dirty.type.rawValue, id, dirty.localID])
        try db.execute(sql: "INSERT INTO sync_entity_state(entityType,localId,entityId) VALUES(?,?,?)",
                       arguments: [dirty.type.rawValue, dirty.localID, id])
        return id
    }

    static func derivedEntityID(type: SyncEntityType, semantic: String, vaultKey: SymmetricKey) -> String {
        if type == .note || type == .attachment { return semantic }
        let input = Data("baerchen-semantic-id:1:\(type.rawValue):\(semantic)".utf8)
        return "m-" + HMAC<SHA256>.authenticationCode(for: input, using: vaultKey).map { String(format: "%02x", $0) }.joined()
    }
}
