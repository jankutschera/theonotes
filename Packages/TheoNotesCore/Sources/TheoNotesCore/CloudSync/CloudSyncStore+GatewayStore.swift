// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

/// The SQLite side of what the gateway persists itself (Task 4's `CloudGatewayStore`): the zone
/// lifecycle in `ck_state` and every send outcome in `ck_send_result`, the moment it is known.
extension CloudSyncStore: CloudGatewayStore {
    public func zoneState() throws -> CloudZoneState {
        try database.pool.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT zoneState, zoneRemovedReason FROM ck_state WHERE id=1")
            switch row?["zoneState"] as String? {
            case "created": return .created
            case "removed":
                // A reason this build does not know (written by a newer build) reads as the generic removal.
                return .removed((row?["zoneRemovedReason"] as String?).flatMap(ZoneRemoval.init(rawValue:)) ?? .deleted)
            default: return .unknown
            }
        }
    }

    /// A change of zone state bumps the generation; setting the same state is a no-op.
    public func setZoneState(_ state: CloudZoneState) throws {
        let name: String, reason: String?
        switch state {
        case .unknown: name = "unknown"; reason = nil
        case .created: name = "created"; reason = nil
        case .removed(let why): name = "removed"; reason = why.rawValue
        }
        try database.pool.write { db in
            let current = try Row.fetchOne(db, sql: "SELECT zoneState, zoneRemovedReason FROM ck_state WHERE id=1")
            guard (current?["zoneState"] as String?) != name || (current?["zoneRemovedReason"] as String?) != reason else { return }
            try db.execute(sql: "UPDATE ck_state SET zoneState=?, zoneRemovedReason=?, generation=generation+1 WHERE id=1",
                           arguments: [name, reason])
        }
    }

    /// The first report for an attempt is kept; a repeated report for it changes nothing. Like `recordSaved`, the write
    /// is refused inside its transaction while the durable fence is up and when the save belongs to another generation: the result of
    /// a stopped or switched session is moot and writes nothing. A late result of the CURRENT generation is still recorded.
    public func recordSendResult(attemptId: String, accountGeneration: Int64, outcome: CloudSaveOutcome) throws {
        let encoded = try outcome.encoded()
        try database.pool.write { db in
            try Self.requireNotFenced(db)
            let current = try Self.generation(db)
            guard current == accountGeneration else {
                throw CloudSyncStoreError.staleAccountGeneration(expected: current, actual: accountGeneration)
            }
            try db.execute(sql: "INSERT OR IGNORE INTO ck_send_result(attemptId,accountGeneration,outcome,recordedAt) VALUES(?,?,?,?)",
                           arguments: [attemptId, accountGeneration, encoded, clock()])
        }
    }

    public func sendResult(attemptId: String) throws -> (accountGeneration: Int64, outcome: CloudSaveOutcome)? {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT accountGeneration, outcome FROM ck_send_result WHERE attemptId=?", arguments: [attemptId])
            else { return nil }
            return (row["accountGeneration"], try CloudSaveOutcome.decode(row["outcome"]))
        }
    }
}
