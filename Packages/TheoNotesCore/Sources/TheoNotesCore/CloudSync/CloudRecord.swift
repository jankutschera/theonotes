// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

// The CloudKit-shaped value types of the sync seam. They import no CloudKit symbol: the live gateway (Task 14,
// `CloudSync/Live/`) maps them to `CKRecord`. Draft until Gate G0.

public enum CloudValue: Sendable, Equatable, Codable {
    case int(Int64), string(String), bytes(Data), strings([String]), asset(URL)
}

public enum CloudRecordType: String, Sendable, Equatable, Codable {
    case entity = "Entity", blobPart = "BlobPart", keyBundle = "KeyBundle"
}

public struct CloudRecord: Sendable, Equatable, Codable {
    public var name: String
    public var type: CloudRecordType
    public var fields: [String: CloudValue]
    /// `CKRecord.encodeSystemFields` archive (carries the change tag); nil before the first save.
    public var systemFields: Data?

    public init(name: String, type: CloudRecordType, fields: [String: CloudValue], systemFields: Data? = nil) {
        self.name = name; self.type = type; self.fields = fields; self.systemFields = systemFields
    }

    /// Bytes the record counts against CloudKit's per-record limit: name, field names and values, not assets.
    /// An estimate for budgeting and tests; CloudKit's own accounting is NOT VERIFIED (Gate G0).
    public var approximateSize: Int {
        var total = name.utf8.count + type.rawValue.utf8.count
        for (key, value) in fields {
            total += key.utf8.count
            switch value {
            case .int: total += 8
            case .string(let s): total += s.utf8.count
            case .bytes(let d): total += d.count
            case .strings(let list): total += list.reduce(0) { $0 + $1.utf8.count + 2 }
            case .asset: total += 64
            }
        }
        return total
    }
}

public struct CloudSave: Sendable, Equatable {
    public var attemptId: String
    public var accountGeneration: Int64
    public var record: CloudRecord

    public init(attemptId: String, accountGeneration: Int64, record: CloudRecord) {
        self.attemptId = attemptId; self.accountGeneration = accountGeneration; self.record = record
    }
}

public enum CloudSaveOutcome: Sendable, Equatable, Codable {
    case saved(systemFields: Data)
    case serverRecordChanged(server: CloudRecord)
    /// A base was held but the record is absent on the server.
    case unknownItem
    case quotaExceeded, limitExceeded, zoneNotFound, unauthenticated, offline, fenced
    case failed(code: String)

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> CloudSaveOutcome {
        try JSONDecoder().decode(CloudSaveOutcome.self, from: data)
    }
}

public enum CloudAccountState: Sendable, Equatable {
    case available(userHash: String), noAccount, restricted, temporarilyUnavailable, couldNotDetermine
}

/// Why a record zone disappeared. `deleted`, `purged` and `encryptedDataReset` are the three reasons of CKSyncEngine's
/// zone-deletion change; `userDeletedZone` is `CKError.Code.userDeletedZone` ("the user deletes a record zone using the Settings app").
public enum ZoneRemoval: String, Sendable, Equatable, Codable {
    case deleted, userDeletedZone, purged, encryptedDataReset
}

/// The person-visible zone lifecycle kept in `ck_state.zoneState`. The gateway creates the zone only from `unknown`.
public enum CloudZoneState: Sendable, Equatable {
    case unknown, created, removed(ZoneRemoval)
}

public enum CloudGatewayEvent: Sendable, Equatable {
    case remoteChange, accountChanged(CloudAccountState), zoneRemoved(ZoneRemoval)
}
