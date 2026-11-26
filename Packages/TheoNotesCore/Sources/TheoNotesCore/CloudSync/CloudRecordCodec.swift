// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

// The structural (plaintext) side of the CloudKit record format, frozen in docs/superpowers/specs/2026-10-28-cloudkit-record-v1.md
// and Fixtures/sync/cloudkit-record-v1.json. Everything here is a number, a random id, a hash, a timestamp-free counter, or
// opaque ciphertext. The sealed content format and the kind byte live in `CloudPayloadSealer`.

public enum CloudEntityPayload: Sendable, Equatable {
    case inline(Data)
    case asset(URL)
}

public struct CloudEntityHeader: Sendable, Equatable {
    public var entityType: SyncEntityType
    public var entityId: String
    /// Incarnation id and the last 4 superseded ones, newest first.
    public var inc: String
    public var incs: [String]
    /// Version within the incarnation, restarts at 1 in a new incarnation.
    public var ver: Int64
    /// Attempt id of the save that produced this version and the last 8 (newest first, `sids[0] == sid`).
    public var sid: String
    public var sids: [String]
    public var payload: CloudEntityPayload
    /// Hashes of the blob ciphertexts the payload references.
    public var blobs: [String]

    public init(entityType: SyncEntityType, entityId: String, inc: String, incs: [String], ver: Int64, sid: String, sids: [String],
                payload: CloudEntityPayload, blobs: [String]) {
        self.entityType = entityType; self.entityId = entityId; self.inc = inc; self.incs = incs; self.ver = ver
        self.sid = sid; self.sids = sids; self.payload = payload; self.blobs = blobs
    }

    public var recordName: String { CloudRecordCodec.entityRecordName(type: entityType, id: entityId) }
}

public struct CloudBlobPartHeader: Sendable, Equatable {
    public var hash: String
    /// Zero-based index of this part.
    public var part: Int
    public var parts: Int
    public var partBytes: Int
    public var totalBytes: Int
    public var partSha256: String
    public var asset: URL

    public init(hash: String, part: Int, parts: Int, partBytes: Int, totalBytes: Int, partSha256: String, asset: URL) {
        self.hash = hash; self.part = part; self.parts = parts; self.partBytes = partBytes
        self.totalBytes = totalBytes; self.partSha256 = partSha256; self.asset = asset
    }

    public var recordName: String { CloudRecordCodec.blobPartRecordName(hash: hash, partBytes: partBytes, part: part) }
}

public struct CloudKeyBundleHeader: Sendable, Equatable {
    public var account: String
    public var rev: Int64
    public var envelope: Data

    public init(account: String, rev: Int64, envelope: Data) {
        self.account = account; self.rev = rev; self.envelope = envelope
    }
}

public enum CloudDecodedRecord: Sendable, Equatable {
    case entity(CloudEntityHeader), blobPart(CloudBlobPartHeader), keyBundle(CloudKeyBundleHeader)
}

/// A record this build cannot fully validate. The receiver quarantines it; it is never a crash.
public enum CloudRecordRejection: Error, Equatable, Sendable {
    case unsupported(Reason)

    public enum Reason: Sendable, Equatable {
        case version(Int64)
        case missingField(String)
        case unknownField(String)
        case fieldShape(String)
        case invalidValue(String)
        case nameMismatch
        case unknownEntityType(String)

        /// Stable text for logs, fixtures and `ck_quarantine.reason`.
        public var code: String {
            switch self {
            case .version(let v): return "version:\(v)"
            case .missingField(let f): return "missing-field:\(f)"
            case .unknownField(let f): return "unknown-field:\(f)"
            case .fieldShape(let f): return "field-shape:\(f)"
            case .invalidValue(let f): return "invalid-value:\(f)"
            case .nameMismatch: return "name-mismatch"
            case .unknownEntityType: return "unknown-entity-type"
            }
        }
    }
}

public enum CloudRecordCodec {
    public static let formatVersion: Int64 = 1
    public static let maxInlineCipherBytes = 200 * 1024
    public static let maxIncarnationHistory = 4
    public static let maxAttemptHistory = 8
    public static let maxBlobRefs = 1000
    public static let maxBlobParts = 8
    public static let partUnitBytes = 1_048_576
    public static let maxKeyEnvelopeBytes = 65_536
    public static let keyBundleRecordName = "keybundle"

    public static let entityFieldNames: Set<String> = ["v", "etype", "eid", "inc", "incs", "ver", "sid", "sids", "cipher", "cipherAsset", "blobs"]
    public static let blobPartFieldNames: Set<String> = ["v", "hash", "part", "parts", "partBytes", "totalBytes", "partSha256", "asset"]
    public static let keyBundleFieldNames: Set<String> = ["v", "account", "rev", "envelope"]

    public static func entityRecordName(type: SyncEntityType, id: String) -> String { "e.\(type.rawValue).\(id)" }
    public static func blobPartRecordName(hash: String, partBytes: Int, part: Int) -> String {
        "b.\(hash).\(partBytes / partUnitBytes).\(part)"
    }

    // MARK: encode

    public static func encode(_ header: CloudEntityHeader) -> CloudRecord {
        var fields: [String: CloudValue] = [
            "v": .int(formatVersion), "etype": .string(header.entityType.rawValue), "eid": .string(header.entityId),
            "inc": .string(header.inc), "incs": .strings(header.incs), "ver": .int(header.ver),
            "sid": .string(header.sid), "sids": .strings(header.sids), "blobs": .strings(header.blobs),
        ]
        switch header.payload {
        case .inline(let data): fields["cipher"] = .bytes(data)
        case .asset(let url): fields["cipherAsset"] = .asset(url)
        }
        return CloudRecord(name: header.recordName, type: .entity, fields: fields)
    }

    public static func encode(_ header: CloudBlobPartHeader) -> CloudRecord {
        CloudRecord(name: header.recordName, type: .blobPart, fields: [
            "v": .int(formatVersion), "hash": .string(header.hash), "part": .int(Int64(header.part)), "parts": .int(Int64(header.parts)),
            "partBytes": .int(Int64(header.partBytes)), "totalBytes": .int(Int64(header.totalBytes)),
            "partSha256": .string(header.partSha256), "asset": .asset(header.asset),
        ])
    }

    public static func encode(_ header: CloudKeyBundleHeader) -> CloudRecord {
        CloudRecord(name: keyBundleRecordName, type: .keyBundle, fields: [
            "v": .int(formatVersion), "account": .string(header.account), "rev": .int(header.rev), "envelope": .bytes(header.envelope),
        ])
    }

    // MARK: decode

    public static func decode(_ record: CloudRecord) throws -> CloudDecodedRecord {
        try checkVersion(record.fields)
        switch record.type {
        case .entity: return .entity(try decodeEntity(record))
        case .blobPart: return .blobPart(try decodeBlobPart(record))
        case .keyBundle: return .keyBundle(try decodeKeyBundle(record))
        }
    }

    private static func reject(_ reason: CloudRecordRejection.Reason) -> CloudRecordRejection { .unsupported(reason) }

    /// `v` is checked before anything else, so a record written by a newer format with a different shape is recognised as newer.
    private static func checkVersion(_ fields: [String: CloudValue]) throws {
        guard let value = fields["v"] else { throw reject(.missingField("v")) }
        guard case .int(let v) = value else { throw reject(.fieldShape("v")) }
        guard v == formatVersion else { throw reject(.version(v)) }
    }

    private static func rejectUnknownFields(_ record: CloudRecord, allowed: Set<String>) throws {
        if let unknown = record.fields.keys.filter({ !allowed.contains($0) }).sorted().first { throw reject(.unknownField(unknown)) }
    }

    private static func string(_ fields: [String: CloudValue], _ key: String) throws -> String {
        guard let value = fields[key] else { throw reject(.missingField(key)) }
        guard case .string(let s) = value else { throw reject(.fieldShape(key)) }
        return s
    }

    private static func int(_ fields: [String: CloudValue], _ key: String) throws -> Int64 {
        guard let value = fields[key] else { throw reject(.missingField(key)) }
        guard case .int(let i) = value else { throw reject(.fieldShape(key)) }
        return i
    }

    private static func strings(_ fields: [String: CloudValue], _ key: String) throws -> [String] {
        guard let value = fields[key] else { throw reject(.missingField(key)) }
        guard case .strings(let list) = value else { throw reject(.fieldShape(key)) }
        return list
    }

    private static func bytes(_ fields: [String: CloudValue], _ key: String) throws -> Data {
        guard let value = fields[key] else { throw reject(.missingField(key)) }
        guard case .bytes(let data) = value else { throw reject(.fieldShape(key)) }
        return data
    }

    private static func asset(_ fields: [String: CloudValue], _ key: String) throws -> URL {
        guard let value = fields[key] else { throw reject(.missingField(key)) }
        guard case .asset(let url) = value else { throw reject(.fieldShape(key)) }
        return url
    }

    private static func isToken(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.count <= 64
            && s.utf8.allSatisfy { ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95 }
    }

    private static func isID(_ s: String) -> Bool { (try? SyncWire.validateID(s)) != nil }
    private static func isHash(_ s: String) -> Bool { (try? SyncWire.validateHash(s)) != nil }

    private static func decodeEntity(_ record: CloudRecord) throws -> CloudEntityHeader {
        try rejectUnknownFields(record, allowed: entityFieldNames)
        let f = record.fields
        let etype = try string(f, "etype")
        guard let entityType = SyncEntityType(rawValue: etype) else { throw reject(.unknownEntityType(etype)) }
        let eid = try string(f, "eid")
        guard isID(eid) else { throw reject(.invalidValue("eid")) }
        let inc = try string(f, "inc")
        guard isToken(inc) else { throw reject(.invalidValue("inc")) }
        let incs = try strings(f, "incs")
        guard incs.count <= maxIncarnationHistory, incs.allSatisfy(isToken) else { throw reject(.invalidValue("incs")) }
        let ver = try int(f, "ver")
        guard ver >= 1, ver <= SyncWire.maximumRevision else { throw reject(.invalidValue("ver")) }
        let sid = try string(f, "sid")
        guard isID(sid) else { throw reject(.invalidValue("sid")) }
        let sids = try strings(f, "sids")
        guard !sids.isEmpty, sids.count <= maxAttemptHistory, sids.allSatisfy(isID), sids[0] == sid else { throw reject(.invalidValue("sids")) }
        let blobs = try strings(f, "blobs")
        guard blobs.count <= maxBlobRefs, blobs.allSatisfy(isHash) else { throw reject(.invalidValue("blobs")) }

        let payload: CloudEntityPayload
        switch (f["cipher"], f["cipherAsset"]) {
        case (.some, .some): throw reject(.invalidValue("cipher"))
        case (nil, nil): throw reject(.missingField("cipher"))
        case (.some, nil):
            let data = try bytes(f, "cipher")
            guard !data.isEmpty, data.count <= maxInlineCipherBytes else { throw reject(.invalidValue("cipher")) }
            payload = .inline(data)
        case (nil, .some):
            payload = .asset(try asset(f, "cipherAsset"))
        }
        guard record.name == entityRecordName(type: entityType, id: eid) else { throw reject(.nameMismatch) }
        return CloudEntityHeader(entityType: entityType, entityId: eid, inc: inc, incs: incs, ver: ver, sid: sid, sids: sids,
                                 payload: payload, blobs: blobs)
    }

    private static func decodeBlobPart(_ record: CloudRecord) throws -> CloudBlobPartHeader {
        try rejectUnknownFields(record, allowed: blobPartFieldNames)
        let f = record.fields
        let hash = try string(f, "hash")
        guard isHash(hash) else { throw reject(.invalidValue("hash")) }
        let parts = try int(f, "parts")
        guard parts >= 1, parts <= Int64(maxBlobParts) else { throw reject(.invalidValue("parts")) }
        let part = try int(f, "part")
        guard part >= 0, part < parts else { throw reject(.invalidValue("part")) }
        let partBytes = try int(f, "partBytes")
        guard partBytes >= Int64(partUnitBytes), partBytes % Int64(partUnitBytes) == 0, partBytes <= 256 * Int64(partUnitBytes)
        else { throw reject(.invalidValue("partBytes")) }
        let totalBytes = try int(f, "totalBytes")
        guard totalBytes >= 1, totalBytes <= Int64(SyncWire.maximumBlobBytes),
              totalBytes <= parts * partBytes, totalBytes > (parts - 1) * partBytes
        else { throw reject(.invalidValue("totalBytes")) }
        let partSha256 = try string(f, "partSha256")
        guard isHash(partSha256) else { throw reject(.invalidValue("partSha256")) }
        let url = try asset(f, "asset")
        guard record.name == blobPartRecordName(hash: hash, partBytes: Int(partBytes), part: Int(part)) else { throw reject(.nameMismatch) }
        return CloudBlobPartHeader(hash: hash, part: Int(part), parts: Int(parts), partBytes: Int(partBytes), totalBytes: Int(totalBytes),
                                   partSha256: partSha256, asset: url)
    }

    private static func decodeKeyBundle(_ record: CloudRecord) throws -> CloudKeyBundleHeader {
        try rejectUnknownFields(record, allowed: keyBundleFieldNames)
        let f = record.fields
        let account = try string(f, "account")
        guard isID(account) else { throw reject(.invalidValue("account")) }
        let rev = try int(f, "rev")
        guard rev >= 0, rev <= SyncWire.maximumRevision else { throw reject(.invalidValue("rev")) }
        let envelope = try bytes(f, "envelope")
        guard !envelope.isEmpty, envelope.count <= maxKeyEnvelopeBytes else { throw reject(.invalidValue("envelope")) }
        guard record.name == keyBundleRecordName else { throw reject(.nameMismatch) }
        return CloudKeyBundleHeader(account: account, rev: rev, envelope: envelope)
    }
}
