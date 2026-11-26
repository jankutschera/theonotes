// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// `CloudSyncStore` (SQLite) and `InMemoryCloudGatewayStore` (Task 4's stand-in) are driven through
/// the same `CloudGatewayStore` contract, so the gateway behaves the same against either.
@Suite struct CloudGatewayStoreConformanceTests {
    /// One store under test plus how to read back what it recorded.
    struct Subject {
        let name: String
        let store: any CloudGatewayStore
        let recorded: @Sendable (String) throws -> (accountGeneration: Int64, outcome: CloudSaveOutcome)?
        /// Makes `generation` the one in force (the SQLite store refuses a result of any other generation).
        let adopt: @Sendable (Int64) throws -> Void
    }

    static func subjects() throws -> [Subject] {
        let memory = InMemoryCloudGatewayStore()
        let db = try AppDatabase.inMemory()
        let sqlite = CloudSyncStore(database: db)
        return [
            Subject(name: "InMemoryCloudGatewayStore", store: memory,
                    recorded: { id in memory.result(for: id).map { ($0.accountGeneration, $0.outcome) } }, adopt: { _ in }),
            Subject(name: "CloudSyncStore", store: sqlite, recorded: { try sqlite.sendResult(attemptId: $0) },
                    adopt: { generation in try db.pool.write { try $0.execute(sql: "UPDATE ck_state SET generation=?", arguments: [generation]) } }),
        ]
    }

    static let record = CloudRecord(name: "e.note.n1", type: .entity, fields: ["ver": .int(3), "cipher": .bytes(Data([1, 2, 3])), "sids": .strings(["a", "b"])],
                                    systemFields: Data("tag".utf8))
    static let outcomes: [CloudSaveOutcome] = [
        .saved(systemFields: Data("new-tag".utf8)), .serverRecordChanged(server: record), .unknownItem, .quotaExceeded, .limitExceeded,
        .zoneNotFound, .unauthenticated, .offline, .fenced, .failed(code: "boom"),
    ]
    static let zones: [CloudZoneState] = [.unknown, .created] + [ZoneRemoval.deleted, .userDeletedZone, .purged, .encryptedDataReset].map { CloudZoneState.removed($0) }

    @Test func zoneStateStartsUnknownAndRoundTripsEveryState() throws {
        for subject in try Self.subjects() {
            #expect(try subject.store.zoneState() == .unknown, "\(subject.name)")
            for zone in Self.zones {
                try subject.store.setZoneState(zone)
                #expect(try subject.store.zoneState() == zone, "\(subject.name) \(zone)")
            }
            try subject.store.setZoneState(.created)
            try subject.store.setZoneState(.unknown)
            #expect(try subject.store.zoneState() == .unknown, "\(subject.name)")
        }
    }

    @Test func everySendOutcomeIsRecordedWithItsGenerationAndReadsBackEqual() throws {
        for subject in try Self.subjects() {
            #expect(try subject.recorded("none") == nil, "\(subject.name)")
            try subject.adopt(4_000_000_000)                                                          // Int64, not Int32
            for (index, outcome) in Self.outcomes.enumerated() {
                let id = "attempt-\(index)"
                try subject.store.recordSendResult(attemptId: id, accountGeneration: 4_000_000_000, outcome: outcome)
                let read = try #require(try subject.recorded(id), "\(subject.name) \(outcome)")
                #expect(read.outcome == outcome, "\(subject.name)")
                #expect(read.accountGeneration == 4_000_000_000, "\(subject.name)")
            }
        }
    }

    @Test func resultsOfDifferentAttemptsDoNotInterfere() throws {
        for subject in try Self.subjects() {
            try subject.adopt(1)
            try subject.store.recordSendResult(attemptId: "a", accountGeneration: 1, outcome: .offline)
            try subject.store.recordSendResult(attemptId: "b", accountGeneration: 1, outcome: .quotaExceeded)
            #expect(try subject.recorded("a")?.outcome == .offline, "\(subject.name)")
            #expect(try subject.recorded("b")?.outcome == .quotaExceeded, "\(subject.name)")
        }
    }

    // Where the two deliberately differ (documented, not part of the shared contract):
    @Test func theSqliteStoreKeepsTheFirstReportOfAnAttemptAndBumpsTheGenerationOnAZoneChange() throws {
        let store = CloudSyncStore(database: try AppDatabase.inMemory())
        let generation = try store.generation()
        try store.recordSendResult(attemptId: "a", accountGeneration: generation, outcome: .offline)
        try store.recordSendResult(attemptId: "a", accountGeneration: generation, outcome: .quotaExceeded)
        #expect(try store.sendResult(attemptId: "a")?.outcome == .offline)
        let before = try store.generation()
        try store.setZoneState(.removed(.purged))
        try store.setZoneState(.removed(.purged))
        #expect(try store.generation() == before + 1)
        try store.setZoneState(.removed(.deleted))                       // another reason is another state
        #expect(try store.generation() == before + 2)
    }

    @Test func aZoneReasonThisBuildDoesNotKnowReadsAsARemovedZone() throws {
        let db = try AppDatabase.inMemory()
        try db.pool.write { try $0.execute(sql: "UPDATE ck_state SET zoneState='removed', zoneRemovedReason='someFutureReason'") }
        #expect(try CloudSyncStore(database: db).zoneState() == .removed(.deleted))
    }
}
