// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CloudKit
import Foundation
import Testing
@testable import TheoNotesCore

// The live contract run (Task 14, section B of docs/release/cloudkit-acceptance.md): `CloudKitGatewayContract` and the extra cases
// below, against `LiveCloudKitGateway` and the REAL service.
//
// Skipped everywhere except in a signed host: `THEONOTES_CLOUDKIT_LIVE=1` AND a process that holds the iCloud entitlement. CloudKit
// traps (not throws) in a process without it, so the entitlement is checked before any container is created. Run it with
// `spikes/cloudkit-gate/run-contract.sh` (Development environment, team Q446J364FH, container from the host's Info.plist).
//
// Every test works in its own scratch zone pair `TheoNotesTest-<uuid>` / `TheoNotesTest-<uuid>Blobs`, deleted at the end of the test.
// Never touches the product zones `TheoNotes` / `TheoNotesBlobs`, and the host is entitled to Development only.

enum LiveRun {
    static var requested: Bool { ProcessInfo.processInfo.environment["THEONOTES_CLOUDKIT_LIVE"] == "1" }
    static var enabled: Bool { requested && LiveCloudKitGateway.processHasCloudKitEntitlement() && container != nil }
    static var container: String? { Bundle.main.infoDictionary?["GateContainer"] as? String }
    static var logPath: String { ProcessInfo.processInfo.environment["THEONOTES_LIVE_LOG"] ?? "/tmp/theonotes-live-contract.log" }
    private static let lock = NSLock()

    /// One line to stdout and to the log file; the file is what gets pasted into the acceptance document.
    static func log(_ id: String, _ text: String) {
        let line = "LIVE \(id) \(text)"
        print(line)
        lock.lock(); defer { lock.unlock() }
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile(); handle.write(Data((line + "\n").utf8)); try? handle.close()
        } else {
            try? Data((line + "\n").utf8).write(to: URL(fileURLWithPath: logPath))
        }
    }
}

/// A scratch zone pair and the gateways made for it.
final class LiveHarness: CloudKitGatewayContractHarness, @unchecked Sendable {
    let configuration: CloudKitConfiguration
    let pinDirectory: URL
    let batchItemLimit: Int
    var resultTimeout: TimeInterval { 180 }

    init(batchItemLimit: Int = 100) {
        configuration = CloudKitConfiguration(containerIdentifier: LiveRun.container ?? "", zoneName: "TheoNotesTest-\(UUID().uuidString)")
        pinDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("live-pins-\(UUID().uuidString)", isDirectory: true)
        self.batchItemLimit = batchItemLimit
    }

    func makeLive(store: InMemoryCloudGatewayStore, engineState: Data?) -> LiveCloudKitGateway {
        let gateway = LiveCloudKitGateway(configuration: configuration, store: store, engineState: engineState, pinDirectory: pinDirectory, batchItemLimit: batchItemLimit,
                                          automaticallySync: ProcessInfo.processInfo.environment["THEONOTES_LIVE_AUTO"] == "1", hooks: nil)
        if ProcessInfo.processInfo.environment["THEONOTES_LIVE_TRACE"] == "1" {
            let id = UUID().uuidString.prefix(4)
            Task { await gateway.setTrace { LiveRun.log("trace\(id)", $0) } }
        }
        return gateway
    }

    func makeGateway(store: InMemoryCloudGatewayStore, engineState: Data?) async throws -> any CloudKitGateway {
        makeLive(store: store, engineState: engineState)
    }

    var database: CKDatabase { CKContainer(identifier: configuration.containerIdentifier).privateCloudDatabase }
    var zones: CloudZones { CloudZones(configuration: configuration) }

    /// Deletes both scratch zones and checks that they are gone (the test fails if the clean-up did not work).
    func cleanUp() async {
        let gateway = makeLive(store: InMemoryCloudGatewayStore(), engineState: nil)
        do { try await gateway.deleteZone() } catch { LiveRun.log("cleanup", "deleteZone threw \(error)") }
        let left = (try? await database.recordZones(for: zones.all).filter { if case .success = $0.value { return true } else { return false } }.count) ?? -1
        LiveRun.log("cleanup", "zone=\(configuration.zoneName) zonesLeft=\(left)")
        if left != 0 { Issue.record("scratch zone \(configuration.zoneName) was not deleted (left: \(left))") }
        try? FileManager.default.removeItem(at: pinDirectory)
    }
}

enum LiveFixtures {
    static func file(_ bytes: Int, fill: UInt8 = 0xAB) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("live-asset-\(UUID().uuidString)")
        try Data(repeating: fill, count: bytes).write(to: url)
        return url
    }

    static func assetEntity(_ id: String, bytes: Int, systemFields: Data? = nil) throws -> CloudRecord {
        var record = CloudRecordCodec.encode(CloudEntityHeader(
            entityType: .note, entityId: id, inc: "inc-\(id)", incs: [], ver: 1, sid: "s-\(id)", sids: ["s-\(id)"],
            payload: .asset(try file(bytes)), blobs: []))
        record.systemFields = systemFields
        return record
    }

    static func part(_ tag: Character = "a", bytes: Int = 1_048_576) throws -> CloudRecord {
        CloudRecordCodec.encode(CloudBlobPartHeader(
            hash: String(repeating: tag, count: 64), part: 0, parts: 1, partBytes: 33_554_432, totalBytes: bytes,
            partSha256: String(repeating: "b", count: 64), asset: try file(bytes, fill: 0xCD)))
    }

    static func timed<T>(_ body: () async throws -> T) async rethrows -> (T, Double) {
        let start = Date()
        let value = try await body()
        return (value, (Date().timeIntervalSince(start) * 10).rounded() / 10)
    }
}

@Suite(.serialized, .enabled(if: LiveRun.enabled)) struct LiveCloudKitGatewayContractTests {
    private func withHarness(_ name: String, batchItemLimit: Int = 100, _ body: (LiveHarness) async throws -> Void) async throws {
        let harness = LiveHarness(batchItemLimit: batchItemLimit)
        LiveRun.log(name, "start zone=\(harness.configuration.zoneName)")
        let start = Date()
        do { try await body(harness) } catch {
            LiveRun.log(name, "THREW \(error)")
            await harness.cleanUp()
            throw error
        }
        LiveRun.log(name, "done in \(Int(Date().timeIntervalSince(start))) s")
        await harness.cleanUp()
    }

    // MARK: the generic contract (the same cases the fake runs)

    @Test func contractChangeTagSemantics() async throws { try await withHarness("B1.changeTagSemantics") { try await CloudKitGatewayContract.changeTagSemantics($0) } }
    @Test func contractIndependentRecords() async throws { try await withHarness("B1.independentRecords") { try await CloudKitGatewayContract.independentRecords($0) } }
    @Test func contractUnknownItem() async throws { try await withHarness("B1.unknownItem") { try await CloudKitGatewayContract.unknownItemForAMissingRecordWithATag($0) } }
    @Test func contractTokenResume() async throws { try await withHarness("B1.tokenResume") { try await CloudKitGatewayContract.tokenResume($0) } }
    @Test func contractFetchByName() async throws { try await withHarness("B1.fetchByName") { try await CloudKitGatewayContract.fetchByName($0) } }
    @Test func contractDeletionsAreDelivered() async throws { try await withHarness("B1.deletionsAreDelivered") { try await CloudKitGatewayContract.deletionsAreDelivered($0) } }
    @Test func contractPrepare() async throws { try await withHarness("B1.prepare") { try await CloudKitGatewayContract.prepareCreatesTheZoneOnlyFromUnknown($0) } }

    // MARK: B1 extras: what the fake cannot know

    /// Item L1: BlobParts live in the second zone; the engine never fetches it; parts are read by name with and without the asset.
    @Test func blobPartsLiveInTheSecondZoneAndAreReadByName() async throws {
        try await withHarness("L1.blobZone") { harness in
            let (gateway, store, _) = try await CloudKitGatewayContract.ready(harness)
            let part = try LiveFixtures.part()
            let entity = CloudKitGatewayContract.entity("with-part")
            let outcomes = try await CloudKitGatewayContract.send(gateway, store, [entity, part])
            #expect(outcomes.allSatisfy { CloudKitGatewayContract.savedFields($0) != nil }, "\(outcomes)")

            // where the records really are
            let inBlobZone = try await harness.database.records(for: [CKRecord.ID(recordName: part.name, zoneID: harness.zones.blob)], desiredKeys: ["v"])
            let inMainZone = try await harness.database.records(for: [CKRecord.ID(recordName: part.name, zoneID: harness.zones.main)], desiredKeys: ["v"])
            let blobFound = inBlobZone.values.contains { if case .success = $0 { return true } else { return false } }
            let mainFound = inMainZone.values.contains { if case .success = $0 { return true } else { return false } }
            LiveRun.log("L1", "part in blob zone=\(blobFound) in main zone=\(mainFound)")
            #expect(blobFound && !mainFound)

            // a fresh device's engine fetch delivers the entity and not the part
            let (reader, _, sink) = try await CloudKitGatewayContract.ready(harness)
            let (_, seconds) = try await LiveFixtures.timed { try await reader.fetchChanges(into: sink) }
            LiveRun.log("L1", "fresh fetch \(seconds) s delivered=\(sink.changedNames.sorted())")
            #expect(sink.changedNames.contains(entity.name) && !sink.changedNames.contains(part.name))

            let metadata = try await reader.fetch([part.name], keys: ["v", "hash", "part", "parts", "partBytes", "totalBytes", "partSha256"])
            #expect(metadata[part.name]?.fields["hash"] != nil && metadata[part.name]?.fields["asset"] == nil)
            let full = try await reader.fetch([part.name], keys: nil)
            guard case .asset(let url)? = full[part.name]?.fields["asset"] else { Issue.record("asset missing in a full read"); return }
            #expect(try Data(contentsOf: url).count == 1_048_576)
            try await reader.delete([part.name])
            #expect(try await reader.fetch([part.name], keys: ["v"]).isEmpty)
        }
    }

    /// Item L2: does CloudKit return a list field that was saved empty? Either way the mapping must hand the codec a record it accepts.
    @Test func anEmptyListRoundTrips() async throws {
        try await withHarness("L2.emptyList") { harness in
            let (gateway, store, _) = try await CloudKitGatewayContract.ready(harness)
            let record = CloudKitGatewayContract.entity("empty-lists")       // incs: [] and blobs: []
            _ = try await CloudKitGatewayContract.send(gateway, store, [record])
            let id = CKRecord.ID(recordName: record.name, zoneID: harness.zones.main)
            let raw = try await harness.database.records(for: [id])[id]?.get()
            LiveRun.log("L2", "raw incs=\(String(describing: raw?["incs"])) raw blobs=\(String(describing: raw?["blobs"]))")
            let fetched = try #require(try await gateway.fetch([record.name], keys: nil)[record.name])
            #expect(throws: Never.self) { _ = try CloudRecordCodec.decode(fetched) }
            let (reader, _, sink) = try await CloudKitGatewayContract.ready(harness)
            try await reader.fetchChanges(into: sink)
            let delivered = try #require(sink.changed(named: record.name))
            #expect(throws: Never.self) { _ = try CloudRecordCodec.decode(delivered) }
        }
    }

    /// Item L3: a new version that switches from the inline payload to an asset must leave no `cipher` behind.
    @Test func switchingFromInlineToAssetClearsTheOtherField() async throws {
        try await withHarness("L3.clearField") { harness in
            let (gateway, store, _) = try await CloudKitGatewayContract.ready(harness)
            let tag = try #require(CloudKitGatewayContract.savedFields(try await CloudKitGatewayContract.send(gateway, store, [CloudKitGatewayContract.entity("switch")])[0]))
            var next = try LiveFixtures.assetEntity("switch", bytes: 4096, systemFields: tag)
            next.fields["ver"] = .int(2)
            let outcome = try await CloudKitGatewayContract.send(gateway, store, [next])[0]
            #expect(CloudKitGatewayContract.savedFields(outcome) != nil, "\(outcome)")
            let id = CKRecord.ID(recordName: next.name, zoneID: harness.zones.main)
            let raw = try #require(try await harness.database.records(for: [id])[id]?.get())
            LiveRun.log("L3", "after switch cipher=\(raw["cipher"] == nil ? "absent" : "PRESENT") cipherAsset=\(raw["cipherAsset"] == nil ? "absent" : "present")")
            #expect(raw["cipher"] == nil && raw["cipherAsset"] != nil)
        }
    }

    /// Item L4: assets round trip (save, fetch by name, engine fetch) and the asset of a conflict record is pinned.
    @Test func assetsRoundTripAndAConflictAssetIsPinned() async throws {
        try await withHarness("L4.assets") { harness in
            let (a, aStore, _) = try await CloudKitGatewayContract.ready(harness)
            let record = try LiveFixtures.assetEntity("asset-1", bytes: 1_048_576)
            let (outcome, seconds) = try await LiveFixtures.timed { try await CloudKitGatewayContract.send(a, aStore, [record])[0] }
            LiveRun.log("L4", "1 MiB cipherAsset save \(seconds) s")
            #expect(CloudKitGatewayContract.savedFields(outcome) != nil)
            let byName = try #require(try await a.fetch([record.name], keys: nil)[record.name])
            guard case .asset(let byNameURL)? = byName.fields["cipherAsset"] else { Issue.record("no asset by name"); return }
            #expect(try Data(contentsOf: byNameURL).count == 1_048_576)

            let (b, bStore, bSink) = try await CloudKitGatewayContract.ready(harness)
            try await b.fetchChanges(into: bSink)
            guard case .asset(let fetchedURL)? = bSink.changed(named: record.name)?.fields["cipherAsset"] else { Issue.record("no asset from the engine fetch"); return }
            #expect(try Data(contentsOf: fetchedURL) == Data(repeating: 0xAB, count: 1_048_576))

            // create-only on an existing name: the server record comes back with its asset, pinned into our own folder
            let conflict = try await CloudKitGatewayContract.send(b, bStore, [try LiveFixtures.assetEntity("asset-1", bytes: 2048)])[0]
            guard case .serverRecordChanged(let server) = conflict, case .asset(let pinnedURL)? = server.fields["cipherAsset"] else {
                Issue.record("expected serverRecordChanged with an asset, got \(conflict)"); return
            }
            LiveRun.log("L4", "conflict asset pinned at \(pinnedURL.deletingLastPathComponent().lastPathComponent) bytes=\((try? Data(contentsOf: pinnedURL).count) ?? -1)")
            #expect(pinnedURL.path.hasPrefix(harness.pinDirectory.path))
            #expect(try Data(contentsOf: pinnedURL).count == 1_048_576)
        }
    }

    /// Item L5: an engine fetch nobody asked for delivers nothing and announces `.remoteChange`; the caller's own fetch then gets it all.
    @Test func aFetchWithoutASinkDeliversNothing() async throws {
        try await withHarness("L5.sinkless") { harness in
            let writerStore = InMemoryCloudGatewayStore(), readerStore = InMemoryCloudGatewayStore()
            let writer = harness.makeLive(store: writerStore, engineState: nil)
            let reader = harness.makeLive(store: readerStore, engineState: nil)
            _ = try await writer.prepare(); _ = try await reader.prepare()
            let sink = RecordingSink()
            try await reader.fetchChanges(into: sink)               // baseline
            let collected = LiveEventBox<[CloudGatewayEvent]>([])
            let listener = Task { for await event in reader.events { collected.mutate { $0.append(event) } } }
            defer { listener.cancel() }
            _ = try await CloudKitGatewayContract.send(writer, writerStore, [CloudKitGatewayContract.entity("while-away")])
            let leaked = try await reader.fetchWithoutSink()
            for _ in 0..<50 where !collected.value.contains(.remoteChange) { try await Task.sleep(nanoseconds: 100_000_000) }
            LiveRun.log("L5", "records delivered without a sink=\(leaked) events=\(collected.value)")
            #expect(leaked == 0)
            #expect(collected.value.contains(.remoteChange))
            #expect(!sink.changedNames.contains("e.note.while-away"))
            try await reader.fetchChanges(into: sink)
            #expect(sink.changedNames.contains("e.note.while-away"), "the record was consumed by the sink-less fetch")
        }
    }

    /// Item L6: what binds `deleteZone(expecting:)` to the expected account. The foreign-owner delete is raw CloudKit, on the scratch zone.
    @Test func deletingTheZoneIsBoundToItsOwner() async throws {
        try await withHarness("L6.deleteZone") { harness in
            let store = InMemoryCloudGatewayStore()
            let gateway = harness.makeLive(store: store, engineState: nil)
            let state = try await gateway.prepare()
            guard case .available(let hash) = state else { Issue.record("no account: \(state)"); return }
            _ = try await CloudKitGatewayContract.send(gateway, store, [CloudKitGatewayContract.entity("keep-me"), try LiveFixtures.part("e")])
            func zonesPresent() async -> [Bool] {
                let result = (try? await harness.database.recordZones(for: harness.zones.all)) ?? [:]
                return harness.zones.all.map { id in
                    if case .success? = result[id] { return true } else { return false }
                }
            }
            #expect(await zonesPresent() == [true, true])

            // (a) the wrong expected account: refused before anything is deleted
            do { try await gateway.deleteZone(expecting: String(repeating: "0", count: 64)); Issue.record("a wrong account must be refused") }
            catch { #expect(error as? CloudSyncError == .fenced) }
            #expect(await zonesPresent() == [true, true])

            // (b) what the server does with a zone id that names another owner: nothing may be deleted
            let foreign = CKRecordZone.ID(zoneName: harness.zones.main.zoneName, ownerName: "_00000000000000000000000000000000")
            var foreignNote = "no error"
            do {
                let result = try await harness.database.modifyRecordZones(saving: [], deleting: [foreign])
                if case .failure(let error)? = result.deleteResults[foreign] { foreignNote = "per-zone error \(CloudKitErrorMapping.ckError(error).map { CloudKitErrorMapping.codeName($0.code) } ?? "\(error)")" }
            } catch { foreignNote = "thrown \(CloudKitErrorMapping.ckError(error).map { CloudKitErrorMapping.codeName($0.code) } ?? "\(error)")" }
            let afterForeign = await zonesPresent()
            LiveRun.log("L6", "foreign-owner delete: \(foreignNote); zones present afterwards=\(afterForeign)")
            #expect(afterForeign == [true, true], "a zone id naming another owner deleted our zone")

            // (c) the right account: both zones go, the zone state follows
            try await gateway.deleteZone(expecting: hash)
            #expect(await zonesPresent() == [false, false])
            #expect(try store.zoneState() == .removed(.deleted))
            try await gateway.deleteZone(expecting: hash)           // again: nothing left, no error
        }
    }

    /// Item L7: a zone that went away while this device was not looking is reported, not fetched as an empty picture.
    @Test func aZoneRemovedBehindOurBackIsReported() async throws {
        try await withHarness("L7.zoneVanished") { harness in
            let first = harness.makeLive(store: InMemoryCloudGatewayStore(), engineState: nil)
            _ = try await first.prepare()
            _ = try await harness.database.modifyRecordZones(saving: [], deleting: harness.zones.all)
            let store = InMemoryCloudGatewayStore()
            try store.setZoneState(.created)
            let second = harness.makeLive(store: store, engineState: nil)
            let state = try await second.prepare()
            guard case .available = state else { Issue.record("no account"); return }
            let collected = LiveEventBox<[CloudGatewayEvent]>([])
            let listener = Task { for await event in second.events { collected.mutate { $0.append(event) } } }
            defer { listener.cancel() }
            let sink = RecordingSink()
            try await second.fetchChanges(into: sink)
            try await Task.sleep(nanoseconds: 300_000_000)
            LiveRun.log("L7", "zoneState=\(try store.zoneState()) events=\(collected.value) fullRefetches=\(sink.fullRefetches)")
            #expect(try store.zoneState() == .removed(.deleted))
            #expect(collected.value.contains(.zoneRemoved(.deleted)))
            #expect(sink.fullRefetches == 0)
        }
    }

    /// Item L8: CK-R46. 450 records in one batch: the engine's documented limit is 250 per request; the gateway halves and sends again.
    @Test func anOversizedBatchIsHalved() async throws {
        try await withHarness("L8.limitExceeded", batchItemLimit: 450) { harness in
            let (gateway, store, _) = try await CloudKitGatewayContract.ready(harness)
            let records = (0..<450).map { CloudKitGatewayContract.entity("many-\($0)") }
            let (outcomes, seconds) = try await LiveFixtures.timed { try await CloudKitGatewayContract.send(gateway, store, records, timeout: 300) }
            let saved = outcomes.filter { CloudKitGatewayContract.savedFields($0) != nil }.count
            let kinds = Dictionary(grouping: outcomes.filter { CloudKitGatewayContract.savedFields($0) == nil }) { "\($0)" }.mapValues(\.count)
            LiveRun.log("L8", "450 records, limit 450: saved=\(saved) others=\(kinds) in \(seconds) s")
            #expect(saved == 450, "\(kinds)")
        }
    }

    /// Item L9: a field outside the spec never reaches CloudKit (it would enter the Production schema for good).
    @Test func aFieldOutsideTheSpecIsRefusedBeforeSending() async throws {
        try await withHarness("L9.allowList") { harness in
            let (gateway, store, _) = try await CloudKitGatewayContract.ready(harness)
            var bad = CloudKitGatewayContract.entity("bad-field")
            bad.fields["note"] = .string("never send me")
            let outcome = try await CloudKitGatewayContract.send(gateway, store, [bad])[0]
            LiveRun.log("L9", "outcome=\(outcome)")
            #expect(outcome == .failed(code: "fieldNotAllowed:Entity.note"))
            #expect(try await gateway.fetch([bad.name], keys: nil).isEmpty)
        }
    }

    /// Item L11 (CK-R165): CloudKit's own system-field archive differs in bytes between a save result, a fetch by name (with and without
    /// `desiredKeys`), an engine fetch and a conflict record, although the change tag is the same (measured: 2395, 2381, 1928 bytes). The
    /// core compares these values byte for byte, so the gateway hands out one value per version.
    @Test func oneVersionHasOneSystemFieldsValueOnEveryPath() async throws {
        try await withHarness("L11.versionIdentity") { harness in
            let (gateway, store, _) = try await CloudKitGatewayContract.ready(harness)
            let saved = try #require(CloudKitGatewayContract.savedFields(try await CloudKitGatewayContract.send(gateway, store, [CloudKitGatewayContract.entity("arch")])[0]))
            let byName = try #require(try await gateway.fetch(["e.note.arch"], keys: nil)["e.note.arch"]?.systemFields)
            let byNameKeys = try #require(try await gateway.fetch(["e.note.arch"], keys: ["ver"])["e.note.arch"]?.systemFields)
            let (reader, _, sink) = try await CloudKitGatewayContract.ready(harness)
            try await reader.fetchChanges(into: sink)
            let engine = try #require(sink.changed(named: "e.note.arch")?.systemFields)
            guard case .serverRecordChanged(let conflict) = try await CloudKitGatewayContract.send(gateway, store, [CloudKitGatewayContract.entity("arch")])[0] else { Issue.record("no conflict"); return }
            let viaConflict = try #require(conflict.systemFields)
            LiveRun.log("L11", "saved==byName \(saved == byName), byName==byNameKeys \(byName == byNameKeys), byName==engine \(byName == engine), byName==conflict \(byName == viaConflict), value=\(String(decoding: saved, as: UTF8.self))")
            #expect(saved == byName && byName == byNameKeys && byName == engine && byName == viaConflict)
        }
    }

    /// Item L12: a save by a gateway that never saw the version (a restart: the base cache is empty) is repaired by a fetch by name.
    @Test func aSaveAfterARestartFindsItsBase() async throws {
        try await withHarness("L12.restart") { harness in
            let (first, store, _) = try await CloudKitGatewayContract.ready(harness)
            let tag = try #require(CloudKitGatewayContract.savedFields(try await CloudKitGatewayContract.send(first, store, [CloudKitGatewayContract.entity("restart")])[0]))
            let (second, secondStore, _) = try await CloudKitGatewayContract.ready(harness)       // a new gateway: no cache
            let next = try await CloudKitGatewayContract.send(second, secondStore, [CloudKitGatewayContract.entity("restart", ver: 2, systemFields: tag)])[0]
            #expect(CloudKitGatewayContract.savedFields(next) != nil, "\(next)")
            // and a stale tag from the same cold start is a conflict carrying the current record, not a failure
            let stale = try await CloudKitGatewayContract.send(second, secondStore, [CloudKitGatewayContract.entity("restart", ver: 3, systemFields: tag)])[0]
            if case .serverRecordChanged(let server) = stale { #expect(server.name == "e.note.restart") } else { Issue.record("expected serverRecordChanged, got \(stale)") }
            // a save with a tag for a record that is gone is unknownItem
            try await second.delete(["e.note.restart"])
            let (third, thirdStore, _) = try await CloudKitGatewayContract.ready(harness)
            let gone = try await CloudKitGatewayContract.send(third, thirdStore, [CloudKitGatewayContract.entity("restart", ver: 4, systemFields: tag)])[0]
            #expect(gone == .unknownItem)
        }
    }

    /// Item L13: the subscriptions in the container, and that a notification which is not CloudKit's is not taken for ours.
    @Test func subscriptionsAndNotifications() async throws {
        try await withHarness("L13.subscriptions") { harness in
            let live = harness.makeLive(store: InMemoryCloudGatewayStore(), engineState: nil)
            _ = try await live.prepare()
            let list = try await harness.database.allSubscriptions().map(\.subscriptionID).sorted()
            LiveRun.log("L13", "subscriptions after prepare (manual engine)=\(list)")
            #expect(live.handleRemoteNotification(["aps": ["content-available": 1]]) == false)
        }
    }

    /// Item L15 (CK-R169): `prepare()` makes sure the private database has a subscription: after all of them are deleted a prepare
    /// creates one, and another prepare (same gateway, or a new one) does not add a second.
    @Test func prepareEnsuresTheDatabaseSubscription() async throws {
        try await withHarness("L15.subscription") { harness in
            let before = try await harness.database.allSubscriptions().map(\.subscriptionID).sorted()
            _ = try await harness.database.modifySubscriptions(saving: [], deleting: before)
            for _ in 0..<20 where !(try await harness.database.allSubscriptions().isEmpty) { try await Task.sleep(nanoseconds: 500_000_000) }
            #expect(try await harness.database.allSubscriptions().isEmpty, "the container still lists subscriptions after they were deleted")

            let first = harness.makeLive(store: InMemoryCloudGatewayStore(), engineState: nil)
            _ = try await first.prepare()
            var afterFirst: [String] = []
            for _ in 0..<20 where afterFirst.isEmpty {
                afterFirst = try await harness.database.allSubscriptions().map(\.subscriptionID)
                if afterFirst.isEmpty { try await Task.sleep(nanoseconds: 500_000_000) }
            }
            _ = try await first.prepare()                                                // again, same gateway
            let second = harness.makeLive(store: InMemoryCloudGatewayStore(), engineState: nil)
            _ = try await second.prepare()                                               // and a new gateway
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let afterAll = try await harness.database.allSubscriptions().map(\.subscriptionID)
            let error = await first.subscriptionError
            LiveRun.log("L15", "before=\(before) afterFirstPrepare=\(afterFirst) afterThreePrepares=\(afterAll) subscriptionError=\(String(describing: error))")
            #expect(afterFirst == [LiveCloudKitGateway.pushSubscriptionID])
            #expect(afterAll == [LiveCloudKitGateway.pushSubscriptionID], "a second prepare duplicated or replaced the subscription")
            #expect(error == nil)
        }
    }

    /// Item L10: deleting a name that never existed raises no error (G0 A2 row; the gateway must not turn it into one).
    @Test func deletingANameThatNeverExistedIsQuiet() async throws {
        try await withHarness("L10.deleteMissing") { harness in
            let (gateway, _, _) = try await CloudKitGatewayContract.ready(harness)
            try await gateway.delete(["e.note.never-existed", "b.\(String(repeating: "9", count: 64)).32.0"])
        }
    }
}

/// A small lock-protected box for events collected on another task.
final class LiveEventBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ change: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; change(&stored) }
}

/// Always runs: says why the live suite is on or off (a silently skipped live run once looked like a pass).
@Suite struct LiveRunStatusTests {
    @Test func reportsWhetherTheLiveSuiteIsEnabled() {
        LiveRun.log("status", "requested=\(LiveRun.requested) entitlement=\(LiveCloudKitGateway.processHasCloudKitEntitlement()) container=\(LiveRun.container ?? "nil")")
        if LiveRun.requested && !LiveRun.enabled { Issue.record("THEONOTES_CLOUDKIT_LIVE=1 but this process cannot run the live suite (no entitlement or no container in Info.plist)") }
    }
}
