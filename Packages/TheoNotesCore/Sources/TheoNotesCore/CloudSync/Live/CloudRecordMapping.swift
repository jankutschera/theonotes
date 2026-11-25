// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CloudKit
import CryptoKit
import Foundation

// `CloudRecord` <-> `CKRecord`. This file and its three neighbours are the only code that imports CloudKit (CK-R19, CK-R160).

enum CloudRecordMappingError: Error, Equatable {
    /// A field name outside the record spec: it would enter the Production schema for good (CK-R151), so it is never written.
    case fieldNotAllowed(recordType: String, field: String)
    case systemFieldsUnreadable
    case systemFieldsMismatch(String)
    case assetFileMissing(field: String)
}

/// The two record zones of one library (CK-R152, CK-R160). `Entity` and `KeyBundle` live in `main`, `BlobPart` in `blob`.
struct CloudZones: Sendable, Equatable {
    static let blobNamePrefix = "b."

    let main: CKRecordZone.ID
    let blob: CKRecordZone.ID

    init(configuration: CloudKitConfiguration) {
        main = CKRecordZone.ID(zoneName: configuration.zoneName, ownerName: CKCurrentUserDefaultName)
        blob = CKRecordZone.ID(zoneName: configuration.blobZoneName, ownerName: CKCurrentUserDefaultName)
    }

    init(main: CKRecordZone.ID, blob: CKRecordZone.ID) { self.main = main; self.blob = blob }

    var all: [CKRecordZone.ID] { [main, blob] }

    func zoneID(for type: CloudRecordType) -> CKRecordZone.ID { type == .blobPart ? blob : main }
    func zoneID(forRecordName name: String) -> CKRecordZone.ID { name.hasPrefix(Self.blobNamePrefix) ? blob : main }
    func recordID(name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zoneID(forRecordName: name)) }
    func isOurs(_ zoneID: CKRecordZone.ID) -> Bool { zoneID.zoneName == main.zoneName || zoneID.zoneName == blob.zoneName }
    func isBlob(_ zoneID: CKRecordZone.ID) -> Bool { zoneID.zoneName == blob.zoneName }
}

enum CloudRecordMapping {
    /// The field names a record of this type may carry: exactly the codec's spec (record spec section 2).
    static func allowedFields(for type: CloudRecordType) -> Set<String> {
        switch type {
        case .entity: return CloudRecordCodec.entityFieldNames
        case .blobPart: return CloudRecordCodec.blobPartFieldNames
        case .keyBundle: return CloudRecordCodec.keyBundleFieldNames
        }
    }

    // MARK: system fields

    /// What the core sees as a record's "system fields": a small deterministic value naming the version (CK-R165). The core compares
    /// these byte for byte to recognise "the same cloud version" (echo of our own save, base of an attempt). The live run measured that
    /// CloudKit's own archive (`encodeSystemFields`) is NOT stable for one version: the archive of a save result, of a fetch by name,
    /// of an engine fetch and of a partial fetch have different bytes (2395, 2381 and 1928 bytes for change tag "3").
    /// So the value carries only what identifies the version, the change tag, and the gateway keeps the real archive itself.
    enum SystemFields {
        private struct Envelope: Codable { let v: Int; let tag: String; let name: String }

        static func make(tag: String, name: String) -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return (try? encoder.encode(Envelope(v: 1, tag: tag, name: name))) ?? Data()
        }

        static func parse(_ data: Data) -> (tag: String, name: String)? {
            guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.v == 1 else { return nil }
            return (envelope.tag, envelope.name)
        }
    }

    /// CloudKit's own change-tag archive: `CKRecord.encodeSystemFields(with:)` into a secure keyed archive. Used as the base of a save.
    static func archive(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func record(fromArchive data: Data) throws -> CKRecord {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { throw CloudRecordMappingError.systemFieldsUnreadable }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        guard let record = CKRecord(coder: coder) else { throw CloudRecordMappingError.systemFieldsUnreadable }
        return record
    }

    // MARK: CloudRecord -> CKRecord

    /// Builds the record to save. With a `base` (the CloudKit record of the version `source.systemFields` names) it continues that
    /// server version, change tag included; without one it is a create. Only allow-listed fields are written; fields of the base
    /// that `source` lacks are set to nil, which removes them on the server.
    static func makeCKRecord(from source: CloudRecord, base: CKRecord?, zones: CloudZones) throws -> CKRecord {
        let typeName = source.type.rawValue
        let allowed = allowedFields(for: source.type)
        if let unknown = source.fields.keys.filter({ !allowed.contains($0) }).sorted().first {
            throw CloudRecordMappingError.fieldNotAllowed(recordType: typeName, field: unknown)
        }
        let record: CKRecord
        if source.systemFields != nil {
            guard let base else { throw CloudRecordMappingError.systemFieldsUnreadable }
            record = base
            guard record.recordType == typeName else { throw CloudRecordMappingError.systemFieldsMismatch("type") }
            guard record.recordID.recordName == source.name else { throw CloudRecordMappingError.systemFieldsMismatch("name") }
            guard record.recordID.zoneID.zoneName == zones.zoneID(for: source.type).zoneName else {
                throw CloudRecordMappingError.systemFieldsMismatch("zone")
            }
        } else {
            record = CKRecord(recordType: typeName, recordID: CKRecord.ID(recordName: source.name, zoneID: zones.zoneID(for: source.type)))
        }
        for (key, value) in source.fields {
            switch value {
            case .int(let number): record[key] = number
            case .string(let text): record[key] = text
            case .bytes(let data): record[key] = data
            case .strings(let list): record[key] = list
            case .asset(let url):
                guard FileManager.default.fileExists(atPath: url.path) else { throw CloudRecordMappingError.assetFileMissing(field: key) }
                record[key] = CKAsset(fileURL: url)
            }
        }
        for key in allowed where source.fields[key] == nil { record[key] = nil }
        return record
    }

    // MARK: CKRecord -> CloudRecord

    /// nil: a record type this build does not model (it cannot be represented, so it is skipped by the caller and counted).
    /// A value of a type outside the five we write becomes a marker string, which the codec rejects as a wrong shape for a known
    /// field and as an unknown field otherwise: the record is quarantined, never misread.
    static func makeCloudRecord(from record: CKRecord) -> CloudRecord? {
        guard let recordType = CloudRecordType(rawValue: record.recordType) else { return nil }
        var fields: [String: CloudValue] = [:]
        for key in record.allKeys() {
            guard let value = record[key] else { continue }
            if let asset = value as? CKAsset {
                if let url = asset.fileURL { fields[key] = .asset(url) }     // no file: the field was not requested (desiredKeys)
            } else if let text = value as? String {
                fields[key] = .string(text)
            } else if let data = value as? Data {
                fields[key] = .bytes(data)
            } else if let list = value as? [String] {
                fields[key] = .strings(list)
            } else if let number = value as? NSNumber {
                fields[key] = .int(number.int64Value)
            } else {
                fields[key] = .string("unsupported-value:\(Swift.type(of: value))")
            }
        }
        let name = record.recordID.recordName
        return CloudRecord(name: name, type: recordType, fields: fields, systemFields: record.recordChangeTag.map { SystemFields.make(tag: $0, name: name) })
    }

    // MARK: sizes (batching)

    /// Bytes of the files the record's asset fields point at.
    static func assetBytes(of record: CloudRecord) -> Int {
        record.fields.values.reduce(0) { total, value in
            guard case .asset(let url) = value else { return total }
            return total + ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
        }
    }

    // MARK: user hash

    /// CK-R10: SHA-256 (hex) of the container's user record name.
    static func userHash(recordName: String) -> String {
        SHA256.hash(data: Data(recordName.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
