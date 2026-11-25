// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation

public enum SyncEntityType: String, Codable, Sendable, CaseIterable {
    case note, attachment, tagPreference, setting, externalRef, keyBundle
}

public enum SyncProtocolError: Error, Equatable {
    case invalidIdentifier, invalidHash, invalidRevision, invalidPayload, invalidEncoding
    case unsupportedVersion, responseTooLarge
}

public enum SyncWire {
    public static let version = 1
    public static let maximumRevision: Int64 = 9_007_199_254_740_991
    public static let inlineBytes = 262_144
    public static let maximumBlobBytes = 263_192_576

    public static func validateID(_ id: String) throws {
        guard !id.isEmpty, id.utf8.count <= 128,
              id.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 })
        else { throw SyncProtocolError.invalidIdentifier }
    }
    public static func validateHash(_ hash: String) throws {
        guard hash.utf8.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw SyncProtocolError.invalidHash }
    }
    public static func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func decode64(_ string: String) throws -> Data {
        let padded = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - string.utf8.count % 4) % 4)
        guard !string.isEmpty, let data = Data(base64Encoded: padded), base64(data) == string
        else { throw SyncProtocolError.invalidEncoding }
        return data
    }
    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func cipherContext(accountID: String, type: SyncEntityType, entityID: String) throws -> String {
        try validateID(accountID); try validateID(entityID)
        return "\(ProtocolLabels.syncCipher):\(accountID):\(type.rawValue):\(entityID):1"
    }
}

public struct SyncMutation: Codable, Equatable, Sendable {
    public var mutationId: String
    public var entityType: SyncEntityType
    public var entityId: String
    public var parentRevision: Int64
    public var tombstone: Bool
    public var payloadFormat: Int
    public var ciphertext: String?
    public var payloadRef: String?
    public var blobRefs: [String]

    public init(mutationId: String, entityType: SyncEntityType, entityId: String, parentRevision: Int64,
                tombstone: Bool = false, ciphertext: String? = nil, payloadRef: String? = nil, blobRefs: [String] = []) {
        self.mutationId = mutationId; self.entityType = entityType; self.entityId = entityId
        self.parentRevision = parentRevision; self.tombstone = tombstone; payloadFormat = 1
        self.ciphertext = ciphertext; self.payloadRef = payloadRef; self.blobRefs = blobRefs
    }

    public func validate() throws {
        try SyncWire.validateID(mutationId); try SyncWire.validateID(entityId)
        guard parentRevision >= 0, parentRevision < SyncWire.maximumRevision else { throw SyncProtocolError.invalidRevision }
        guard payloadFormat == 1 else { throw SyncProtocolError.unsupportedVersion }
        guard blobRefs.count <= 1000, Set(blobRefs).count == blobRefs.count else { throw SyncProtocolError.invalidPayload }
        for hash in blobRefs { try SyncWire.validateHash(hash) }
        if let ciphertext {
            guard try SyncWire.decode64(ciphertext).count <= SyncWire.inlineBytes else { throw SyncProtocolError.invalidPayload }
        }
        if let payloadRef {
            try SyncWire.validateHash(payloadRef)
            guard blobRefs.contains(payloadRef) else { throw SyncProtocolError.invalidPayload }
        }
        guard tombstone ? ciphertext == nil && payloadRef == nil && blobRefs.isEmpty : (ciphertext == nil) != (payloadRef == nil)
        else { throw SyncProtocolError.invalidPayload }
    }

    public func canonicalData() throws -> Data {
        try validate()
        return try JSONSerialization.data(withJSONObject: [1, mutationId, entityType.rawValue, entityId,
            parentRevision, tombstone, payloadFormat, ciphertext as Any? ?? NSNull(),
            payloadRef as Any? ?? NSNull(), blobRefs.sorted()], options: [.withoutEscapingSlashes])
    }
    public func digest() throws -> String { try SyncWire.hash(canonicalData()) }

    // Null fields are mandatory in v1; synthesized Codable would omit optional keys.
    enum CodingKeys: String, CodingKey { case mutationId, entityType, entityId, parentRevision, tombstone, payloadFormat, ciphertext, payloadRef, blobRefs }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mutationId, forKey: .mutationId); try c.encode(entityType, forKey: .entityType)
        try c.encode(entityId, forKey: .entityId); try c.encode(parentRevision, forKey: .parentRevision)
        try c.encode(tombstone, forKey: .tombstone); try c.encode(payloadFormat, forKey: .payloadFormat)
        try c.encode(ciphertext, forKey: .ciphertext); try c.encode(payloadRef, forKey: .payloadRef)
        try c.encode(blobRefs, forKey: .blobRefs)
    }
}

public struct SyncEntity: Codable, Equatable, Sendable {
    public let mutation: SyncMutation
    public let revision: Int64
    public let sequence: Int64
    public let receivedAt: Int64
    public init(mutation: SyncMutation, revision: Int64, sequence: Int64, receivedAt: Int64) {
        self.mutation = mutation; self.revision = revision; self.sequence = sequence; self.receivedAt = receivedAt
    }
    enum CodingKeys: String, CodingKey { case revision, sequence, receivedAt }
    public init(from decoder: any Decoder) throws {
        mutation = try SyncMutation(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revision = try c.decode(Int64.self, forKey: .revision)
        sequence = try c.decode(Int64.self, forKey: .sequence)
        receivedAt = try c.decode(Int64.self, forKey: .receivedAt)
        try mutation.validate()
        guard revision == mutation.parentRevision + 1, sequence > 0, sequence <= SyncWire.maximumRevision, receivedAt >= 0
        else { throw SyncProtocolError.invalidRevision }
    }
    public func encode(to encoder: any Encoder) throws {
        try mutation.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(revision, forKey: .revision); try c.encode(sequence, forKey: .sequence)
        try c.encode(receivedAt, forKey: .receivedAt)
    }
}

public struct SyncPushResult: Codable, Sendable {
    public let results: [SyncMutationResult]
}
public struct SyncMutationResult: Codable, Sendable {
    public enum Status: String, Codable, Sendable { case accepted, conflict, missingBlob = "missing_blob", mutationReused = "mutation_reused" }
    public let mutationId: String
    public let status: Status
    public let entity: SyncEntity?
    public let current: SyncEntity?
}
public struct SyncPullResult: Codable, Sendable {
    public let changes: [SyncEntity]
    public let cursor: Int64
    public let hasMore: Bool
}
public protocol SyncTransport: Sendable {
    func push(_ mutations: [SyncMutation]) async throws -> SyncPushResult
    func pull(after cursor: Int64) async throws -> SyncPullResult
    func acknowledge(_ cursor: Int64) async throws
}
