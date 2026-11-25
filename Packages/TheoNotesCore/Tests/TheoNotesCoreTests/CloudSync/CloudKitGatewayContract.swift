// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

/// Everything a gateway must do the same way on the in-memory fake and on the live CloudKit gateway.
/// The fake runs it in `FakeCloudKitContractTests`; Gate G0 and Task 14 run it against the live gateway
/// in a signed host (`THEONOTES_CLOUDKIT_LIVE=1`, scratch zone). Anything the fake teaches that the live
/// run contradicts is a fake bug, not a product bug.
protocol CloudKitGatewayContractHarness: Sendable {
    /// A gateway for a device of the same iCloud user and the same zone. `engineState` nil means a new device.
    func makeGateway(store: InMemoryCloudGatewayStore, engineState: Data?) async throws -> any CloudKitGateway
    /// How long a submitted save may take to report its outcome (the fake: immediately).
    var resultTimeout: TimeInterval { get }
}

enum CloudKitGatewayContract {
    // MARK: building blocks

    static func entity(_ id: String, ver: Int64 = 1, sid: String = UUID().uuidString, payload: [UInt8] = [1, 2, 3], systemFields: Data? = nil) -> CloudRecord {
        var record = CloudRecordCodec.encode(CloudEntityHeader(
            entityType: .note, entityId: id, inc: "inc-\(id)", incs: [], ver: ver, sid: sid, sids: [sid],
            payload: .inline(Data(payload)), blobs: []))
        record.systemFields = systemFields
        return record
    }

    /// Submits and waits for the outcomes in the store (outcomes arrive there, not as a return value).
    @discardableResult
    static func send(_ gateway: any CloudKitGateway, _ store: InMemoryCloudGatewayStore, _ records: [CloudRecord], generation: Int64 = 1,
                     timeout: TimeInterval = 5) async throws -> [CloudSaveOutcome] {
        let saves = records.map { CloudSave(attemptId: UUID().uuidString, accountGeneration: generation, record: $0) }
        try await gateway.submit(saves)
        return try await store.waitForOutcomes(saves.map(\.attemptId), timeout: timeout)
    }

    static func savedFields(_ outcome: CloudSaveOutcome) -> Data? {
        if case .saved(let fields) = outcome { return fields }
        return nil
    }

    static func ready(_ harness: some CloudKitGatewayContractHarness, engineState: Data? = nil) async throws
        -> (gateway: any CloudKitGateway, store: InMemoryCloudGatewayStore, sink: RecordingSink) {
        let store = InMemoryCloudGatewayStore()
        let gateway = try await harness.makeGateway(store: store, engineState: engineState)
        _ = try await gateway.prepare()
        return (gateway, store, RecordingSink())
    }

    // MARK: the contract

    /// A create on an existing name and a save with a stale tag both come back as `serverRecordChanged` carrying the server version.
    static func changeTagSemantics(_ harness: some CloudKitGatewayContractHarness) async throws {
        let (gateway, store, _) = try await ready(harness)
        let first = try await send(gateway, store, [entity("tag-1", ver: 1)])[0]
        let tag1 = try #require(savedFields(first))

        let second = try await send(gateway, store, [entity("tag-1", ver: 2, systemFields: tag1)])[0]
        let tag2 = try #require(savedFields(second))
        #expect(tag2 != tag1)

        // stale tag
        let stale = try await send(gateway, store, [entity("tag-1", ver: 3, systemFields: tag1)])[0]
        guard case .serverRecordChanged(let server) = stale else { Issue.record("expected serverRecordChanged, got \(stale)"); return }
        #expect(server.name == "e.note.tag-1")
        #expect(server.systemFields == tag2)
        #expect(try CloudRecordCodec.decode(server) == CloudRecordCodec.decode(entity("tag-1", ver: 2, sid: headerSid(server))))

        // create on an existing name
        let create = try await send(gateway, store, [entity("tag-1", ver: 1)])[0]
        guard case .serverRecordChanged(let existing) = create else { Issue.record("expected serverRecordChanged, got \(create)"); return }
        #expect(existing.systemFields == tag2)
    }

    private static func headerSid(_ record: CloudRecord) -> String {
        if case .entity(let header)? = try? CloudRecordCodec.decode(record) { return header.sid }
        return ""
    }

    /// A failing record does not fail its neighbours (`atomicByZone = false`).
    static func independentRecords(_ harness: some CloudKitGatewayContractHarness) async throws {
        let (gateway, store, _) = try await ready(harness)
        let base = try #require(savedFields(try await send(gateway, store, [entity("ind-b", ver: 1)])[0]))
        _ = try await send(gateway, store, [entity("ind-b", ver: 2, systemFields: base)])
        let outcomes = try await send(gateway, store, [
            entity("ind-a"), entity("ind-b", ver: 3, systemFields: base), entity("ind-c"),
        ])
        #expect(savedFields(outcomes[0]) != nil)
        if case .serverRecordChanged = outcomes[1] {} else { Issue.record("middle record should conflict, got \(outcomes[1])") }
        #expect(savedFields(outcomes[2]) != nil)
        let fetched = try await gateway.fetch(["e.note.ind-a", "e.note.ind-b", "e.note.ind-c"], keys: nil)
        #expect(Set(fetched.keys) == ["e.note.ind-a", "e.note.ind-b", "e.note.ind-c"])
    }

    /// A save that carries a tag for a record the server does not have is `unknownItem`.
    static func unknownItemForAMissingRecordWithATag(_ harness: some CloudKitGatewayContractHarness) async throws {
        let (gateway, store, _) = try await ready(harness)
        let tag = try #require(savedFields(try await send(gateway, store, [entity("gone-1")])[0]))
        try await gateway.delete(["e.note.gone-1"])
        let outcome = try await send(gateway, store, [entity("gone-1", ver: 2, systemFields: tag)])[0]
        #expect(outcome == .unknownItem)
        // and the record is still absent: nothing was created behind our back
        #expect(try await gateway.fetch(["e.note.gone-1"], keys: nil).isEmpty)
    }

    /// Fetch resumes from the saved engine state; a device that saved nothing refetches everything inside a full-refetch bracket.
    static func tokenResume(_ harness: some CloudKitGatewayContractHarness) async throws {
        let (writer, writerStore, _) = try await ready(harness)
        try await send(writer, writerStore, [entity("tok-1"), entity("tok-2"), entity("tok-3")])

        let (reader, _, sink) = try await ready(harness)
        try await reader.fetchChanges(into: sink)
        #expect(Set(sink.changedNames).isSuperset(of: ["e.note.tok-1", "e.note.tok-2", "e.note.tok-3"]))
        #expect(sink.fullRefetches == 1)
        let state = try #require(sink.lastState)

        // a restarted device with the saved state sees only what is new
        let (restarted, _, sink2) = try await ready(harness, engineState: state)
        try await restarted.fetchChanges(into: sink2)
        #expect(sink2.changedNames.isEmpty)
        #expect(sink2.fullRefetches == 0)
        try await send(writer, writerStore, [entity("tok-4")])
        try await restarted.fetchChanges(into: sink2)
        #expect(sink2.changedNames == ["e.note.tok-4"])
    }

    /// Fetch by name returns what exists, omits what does not, and honours the field subset.
    static func fetchByName(_ harness: some CloudKitGatewayContractHarness) async throws {
        let (gateway, store, _) = try await ready(harness)
        try await send(gateway, store, [entity("by-1", payload: [4, 5, 6])])
        let all = try await gateway.fetch(["e.note.by-1", "e.note.by-missing"], keys: nil)
        #expect(Set(all.keys) == ["e.note.by-1"])
        #expect(all["e.note.by-1"]?.systemFields != nil)
        #expect(all["e.note.by-1"]?.fields["cipher"] == .bytes(Data([4, 5, 6])))
        let some = try await gateway.fetch(["e.note.by-1"], keys: ["ver"])
        #expect(Set(some["e.note.by-1"]?.fields.keys.map { $0 } ?? []) == ["ver"])
    }

    /// A deletion is delivered to other devices as a name in `deletedNames`.
    static func deletionsAreDelivered(_ harness: some CloudKitGatewayContractHarness) async throws {
        let (a, aStore, _) = try await ready(harness)
        try await send(a, aStore, [entity("del-1")])
        let (b, _, bSink) = try await ready(harness)
        try await b.fetchChanges(into: bSink)
        #expect(bSink.changedNames.contains("e.note.del-1"))
        try await a.delete(["e.note.del-1"])
        try await b.fetchChanges(into: bSink)
        #expect(bSink.deletedNames.contains("e.note.del-1"))
    }

    /// `prepare()` reports the account and creates the zone only from `zoneState == unknown`.
    static func prepareCreatesTheZoneOnlyFromUnknown(_ harness: some CloudKitGatewayContractHarness) async throws {
        let store = InMemoryCloudGatewayStore()
        let gateway = try await harness.makeGateway(store: store, engineState: nil)
        let state = try await gateway.prepare()
        guard case .available = state else { Issue.record("expected an available account, got \(state)"); return }
        #expect(try store.zoneState() == .created)
        let again = try await gateway.prepare()
        #expect(again == state)
        #expect(try store.zoneState() == .created)
    }
}
