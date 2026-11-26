// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import Testing
@testable import TheoNotesCore

struct FakeCloudKitHarness: CloudKitGatewayContractHarness {
    let cloud: FakeCloudKitAccount
    var resultTimeout: TimeInterval { 1 }
    init(cloud: FakeCloudKitAccount = FakeCloudKitAccount()) { self.cloud = cloud }
    func makeGateway(store: InMemoryCloudGatewayStore, engineState: Data?) async throws -> any CloudKitGateway {
        FakeCloudKitDevice(account: cloud, store: store, engineState: engineState)
    }
}

/// One device of the test world: its gateway, its durable store and the sink that stands in for the receiver.
struct Peer {
    let device: FakeCloudKitDevice
    let store: InMemoryCloudGatewayStore
    let sink: RecordingSink
    let disk: FakeDeviceDisk

    static func make(_ cloud: FakeCloudKitAccount?, disk: FakeDeviceDisk = FakeDeviceDisk(), store: InMemoryCloudGatewayStore = InMemoryCloudGatewayStore(),
                     sink: RecordingSink = RecordingSink(), engineState: Data? = nil, prepare: Bool = true) async throws -> Peer {
        let device = FakeCloudKitDevice(account: cloud, store: store, disk: disk, engineState: engineState)
        if prepare { _ = try await device.prepare() }
        return Peer(device: device, store: store, sink: sink, disk: disk)
    }

    @discardableResult
    func save(_ records: [CloudRecord], generation: Int64 = 1) async throws -> [CloudSaveOutcome] {
        try await CloudKitGatewayContract.send(device, store, records, generation: generation, timeout: 1)
    }

    @discardableResult
    func save(_ record: CloudRecord, generation: Int64 = 1) async throws -> CloudSaveOutcome {
        try await save([record], generation: generation)[0]
    }

    func fetch() async throws { try await device.fetchChanges(into: sink) }
}

func entity(_ id: String, ver: Int64 = 1, sid: String = UUID().uuidString, payload: [UInt8] = [1, 2, 3], systemFields: Data? = nil) -> CloudRecord {
    CloudKitGatewayContract.entity(id, ver: ver, sid: sid, payload: payload, systemFields: systemFields)
}

func tag(_ outcome: CloudSaveOutcome) throws -> Data { try #require(CloudKitGatewayContract.savedFields(outcome)) }

func decodedEntity(_ record: CloudRecord) throws -> CloudEntityHeader {
    guard case .entity(let header) = try CloudRecordCodec.decode(record) else { throw CloudSyncError.failed(code: "not an entity") }
    return header
}

func tempFile(_ bytes: Data, name: String = UUID().uuidString) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fake-ck-tests", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try bytes.write(to: url)
    return url
}

func assetEntity(_ id: String, bytes: Data, systemFields: Data? = nil) throws -> CloudRecord {
    var record = CloudRecordCodec.encode(CloudEntityHeader(
        entityType: .note, entityId: id, inc: "inc-\(id)", incs: [], ver: 1, sid: "s-\(id)", sids: ["s-\(id)"],
        payload: .asset(try tempFile(bytes)), blobs: []))
    record.systemFields = systemFields
    return record
}

@Suite struct FakeCloudKitContractTests {
    // MARK: the generic contract (also run live at Gate G0)

    @Test func contractChangeTagSemantics() async throws { try await CloudKitGatewayContract.changeTagSemantics(FakeCloudKitHarness()) }
    @Test func contractIndependentRecords() async throws { try await CloudKitGatewayContract.independentRecords(FakeCloudKitHarness()) }
    @Test func contractUnknownItem() async throws { try await CloudKitGatewayContract.unknownItemForAMissingRecordWithATag(FakeCloudKitHarness()) }
    @Test func contractTokenResume() async throws { try await CloudKitGatewayContract.tokenResume(FakeCloudKitHarness()) }
    @Test func contractFetchByName() async throws { try await CloudKitGatewayContract.fetchByName(FakeCloudKitHarness()) }
    @Test func contractDeletionsAreDelivered() async throws { try await CloudKitGatewayContract.deletionsAreDelivered(FakeCloudKitHarness()) }
    @Test func contractPrepare() async throws { try await CloudKitGatewayContract.prepareCreatesTheZoneOnlyFromUnknown(FakeCloudKitHarness()) }

    // MARK: change tags and conflicts

    @Test func createOnAnExistingNameIsServerRecordChangedWithTheServerVersion() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud), b = try await Peer.make(cloud)
        let first = try tag(try await a.save(entity("n1", ver: 1)))
        let outcome = try await b.save(entity("n1", ver: 1))
        guard case .serverRecordChanged(let server) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(server.systemFields == first)
        #expect(try decodedEntity(server).ver == 1)
        #expect(await cloud.versionCount(of: "e.note.n1") == 1)
    }

    @Test func staleTagIsServerRecordChangedAndNothingIsWritten() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud)
        let t1 = try tag(try await a.save(entity("n1", ver: 1)))
        let t2 = try tag(try await a.save(entity("n1", ver: 2, systemFields: t1)))
        let outcome = try await a.save(entity("n1", ver: 3, systemFields: t1))
        guard case .serverRecordChanged(let server) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(server.systemFields == t2)
        #expect(try decodedEntity(server).ver == 2)
        #expect(await cloud.versionCount(of: "e.note.n1") == 2)
    }

    @Test func changeTagsAreOpaqueAndNeverRepeat() async throws {
        let a = try await Peer.make(FakeCloudKitAccount())
        var last: Data?
        var seen = Set<Data>()
        for ver in 1...30 {
            let t = try tag(try await a.save(entity("n1", ver: Int64(ver), systemFields: last)))
            #expect(seen.insert(t).inserted)
            last = t
        }
    }

    @Test func aTagFromAnotherRecordNameIsRejected() async throws {
        let a = try await Peer.make(FakeCloudKitAccount())
        let other = try tag(try await a.save(entity("other")))
        _ = try tag(try await a.save(entity("n1")))
        let outcome = try await a.save(entity("n1", ver: 2, systemFields: other))
        #expect(outcome == .failed(code: "invalidArguments"))
    }

    @Test func independentRecordsInABatchReportTheirOwnOutcomes() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud), b = try await Peer.make(cloud)
        let t1 = try tag(try await a.save(entity("b")))
        try await b.save(entity("b", ver: 2, systemFields: t1))
        let outcomes = try await a.save([entity("a"), entity("b", ver: 2, systemFields: t1), entity("c")])
        #expect(CloudKitGatewayContract.savedFields(outcomes[0]) != nil)
        if case .serverRecordChanged = outcomes[1] {} else { Issue.record("got \(outcomes[1])") }
        #expect(CloudKitGatewayContract.savedFields(outcomes[2]) != nil)
        #expect(await cloud.recordNames.sorted() == ["e.note.a", "e.note.b", "e.note.c"])
    }

    @Test func atomicByZoneModeFailsEveryRecordOfTheBatchWhenOneFails() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud), b = try await Peer.make(cloud)
        let t1 = try tag(try await a.save(entity("b")))
        try await b.save(entity("b", ver: 2, systemFields: t1))
        await a.device.setAtomicByZone(true)
        let outcomes = try await a.save([entity("a"), entity("b", ver: 2, systemFields: t1), entity("c")])
        #expect(outcomes[0] == .failed(code: "batchRequestFailed"))
        if case .serverRecordChanged = outcomes[1] {} else { Issue.record("got \(outcomes[1])") }
        #expect(outcomes[2] == .failed(code: "batchRequestFailed"))
        #expect(await cloud.recordNames == ["e.note.b"])
    }

    @Test func aTagForARecordTheServerDoesNotHaveIsUnknownItem() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud)
        let t1 = try tag(try await a.save(entity("n1")))
        await cloud.removeRecord("e.note.n1")
        #expect(try await a.save(entity("n1", ver: 2, systemFields: t1)) == .unknownItem)
        #expect(await cloud.recordNames.isEmpty)
    }

    @Test func offerFreshTagReturnsTheServerTagAndLogsWhenASaveUsesIt() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud), b = try await Peer.make(cloud)
        let t1 = try tag(try await a.save(entity("n1")))
        let t2 = try tag(try await b.save(entity("n1", ver: 2, systemFields: t1)))
        let offered = try #require(await cloud.offerFreshTag(for: "e.note.n1"))
        #expect(offered == t2)
        // a careless caller sends its old content with the fresh tag: the cloud accepts it (it cannot know) but the log shows the trap was used
        let outcome = try await a.save(entity("n1", ver: 2, systemFields: offered))
        #expect(CloudKitGatewayContract.savedFields(outcome) != nil)
        let log = await a.device.sendLog
        #expect(log.last?.usedOfferedTag == true)
        #expect(log.first?.usedOfferedTag == false)
    }

    // MARK: fetch semantics

    @Test func fetchDeliversOldestChangeFirstAndOnlyTheLatestVersionOfARecord() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud), b = try await Peer.make(cloud)
        let t1 = try tag(try await a.save(entity("x", ver: 1)))
        try await a.save(entity("y"))
        try await a.save(entity("x", ver: 2, systemFields: t1))
        try await a.save(entity("z"))
        try await b.fetch()
        #expect(b.sink.changedNames == ["e.note.y", "e.note.x", "e.note.z"])
        #expect(try decodedEntity(b.sink.changed(named: "e.note.x")!).ver == 2)
    }

    @Test func fetchDeliversInBatchesAndSavesStateAfterEachCommit() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud), b = try await Peer.make(cloud)
        try await a.save((1...5).map { entity("n\($0)") })
        await b.device.setFetchBatchSize(2)
        try await b.fetch()
        #expect(b.sink.commitSizes == [2, 2, 1])
        // a full refetch defers the state until the bracket ends; then one state is saved
        #expect(b.sink.log == ["begin", "commit", "commit", "commit", "end", "state"])
        try await a.save(entity("n6"))
        try await a.save(entity("n7"))
        try await a.save(entity("n8"))
        let before = b.sink.log.count
        try await b.fetch()
        #expect(Array(b.sink.log[before...]) == ["commit", "state", "commit", "state"])
    }

    @Test func fullRefetchKeepsTheStateUntilTheBracketEnds() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud), b = try await Peer.make(cloud)
        try await a.save((1...4).map { entity("n\($0)") })
        await b.device.setFetchBatchSize(1)
        b.sink.failCommit(onCall: 3)
        await #expect(throws: (any Error).self) { try await b.fetch() }
        #expect(b.sink.lastState == nil, "no state may be saved before endFullRefetch")
        #expect(!b.sink.log.contains("end"))
    }

    @Test func aSinkThatThrowsOnCommitSavesNoStateAndTheNextFetchRedeliversEverything() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud), b = try await Peer.make(cloud)
        try await a.save(entity("n1"))
        try await b.fetch()
        let state = try #require(b.sink.lastState)
        try await a.save(entity("n2"))
        let restarted = try await Peer.make(cloud, store: b.store, engineState: state)
        restarted.sink.failCommit(onCall: 1)
        await #expect(throws: (any Error).self) { try await restarted.fetch() }
        #expect(restarted.sink.lastState == nil)
        try await restarted.fetch()
        #expect(restarted.sink.changedNames == ["e.note.n2"])
    }

    @Test func aSinkThatThrowsOnStateSaveDoesNotAdvanceTheDeviceToken() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud), b = try await Peer.make(cloud)
        try await b.fetch()
        try await a.save(entity("n1"))
        b.sink.failStateSave(onCall: 1)
        await #expect(throws: (any Error).self) { try await b.fetch() }
        try await b.fetch()
        #expect(b.sink.changedNames.filter { $0 == "e.note.n1" }.count == 2, "the change is delivered again because the state never saved")
    }

    @Test func expiredTokenTriggersAFullRefetchBracketAndRedeliversCurrentRecords() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud), b = try await Peer.make(cloud)
        try await a.save([entity("n1"), entity("n2")])
        try await b.fetch()
        try await a.save(entity("n3"))
        await cloud.removeRecord("e.note.n1")
        let other = RecordingSink()
        await b.device.expireTokenNextFetch()
        try await b.device.fetchChanges(into: other)
        #expect(other.log.first == "begin")
        #expect(other.log.suffix(2) == ["end", "state"])
        #expect(Set(other.changedNames) == ["e.note.n2", "e.note.n3"], "a full fetch returns current records only; no deletion is reported")
        #expect(other.deletedNames.isEmpty)
        // the state afterwards works normally
        let again = RecordingSink()
        try await b.device.fetchChanges(into: again)
        #expect(again.changedNames.isEmpty)
        #expect(again.fullRefetches == 0)
    }

    @Test func droppedEngineStateAndAForeignAccountsStateBothForceAFullRefetch() async throws {
        let cloud = FakeCloudKitAccount(user: "one"), foreign = FakeCloudKitAccount(user: "two")
        let a = try await Peer.make(cloud)
        try await a.save(entity("n1"))
        let b = try await Peer.make(cloud)
        try await b.fetch()
        let state = try #require(b.sink.lastState)
        await b.device.dropEngineState()
        let sink = RecordingSink()
        try await b.device.fetchChanges(into: sink)
        #expect(sink.fullRefetches == 1)

        let c = try await Peer.make(foreign, engineState: state)
        try await c.fetch()
        #expect(c.sink.fullRefetches == 1, "a token from another account's history is not valid here")
    }

    @Test func reorderBatchDeliversAnyPermutation() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud), b = try await Peer.make(cloud)
        try await a.save([entity("n1"), entity("n2"), entity("n3")])
        await b.device.reorderBatch([2, 0, 1])
        try await b.fetch()
        #expect(b.sink.changedNames == ["e.note.n3", "e.note.n1", "e.note.n2"])
    }

    @Test func reorderBatchWithASeedShufflesDeterministically() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud)
        try await a.save((1...8).map { entity("n\($0)") })
        var orders: [[String]] = []
        for _ in 0..<2 {
            let b = try await Peer.make(cloud)
            await b.device.reorderBatch(seed: 42)
            try await b.fetch()
            orders.append(b.sink.changedNames)
        }
        #expect(orders[0] == orders[1])
        #expect(orders[0] != (1...8).map { "e.note.n\($0)" })
        #expect(Set(orders[0]).count == 8)
    }

    @Test func redeliverBatchDeliversTheFirstBatchTwice() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud), b = try await Peer.make(cloud)
        try await a.save([entity("n1"), entity("n2")])
        await b.device.redeliverBatch()
        try await b.fetch()
        #expect(b.sink.changedNames == ["e.note.n1", "e.note.n2", "e.note.n1", "e.note.n2"])
    }

    @Test func deliverStaleVersionArrivesAfterTheNewerOne() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud), b = try await Peer.make(cloud)
        let t1 = try tag(try await a.save(entity("n1", ver: 1)))
        let t2 = try tag(try await a.save(entity("n1", ver: 2, systemFields: t1)))
        await b.device.deliverStaleVersion(of: "e.note.n1")
        try await b.fetch()
        #expect(b.sink.changedNames == ["e.note.n1", "e.note.n1"])
        let versions = try b.sink.allChanged.map { try decodedEntity($0).ver }
        #expect(versions == [2, 1])
        #expect(b.sink.allChanged.map(\.systemFields) == [t2, t1])
    }

    @Test func ownSavesComeBackAsEchoesInTheNextFetch() async throws {
        let a = try await Peer.make(FakeCloudKitAccount())
        let t = try tag(try await a.save(entity("n1")))
        try await a.fetch()
        #expect(a.sink.changedNames == ["e.note.n1"])
        #expect(a.sink.changed(named: "e.note.n1")?.systemFields == t)
    }

    @Test func removedRecordsAreReportedAsDeletedNamesIncludingOnesNeverSeen() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud), b = try await Peer.make(cloud)
        try await a.save([entity("n1"), entity("n2")])
        try await b.fetch()
        await cloud.removeRecord("e.note.n1")
        try await b.fetch()
        #expect(b.sink.deletedNames == ["e.note.n1"])
        let c = try await Peer.make(cloud, engineState: nil)
        try await c.fetch()
        #expect(c.sink.changedNames == ["e.note.n2"])
    }

    @Test func fetchByNameRestrictsFieldsAndIncludesSystemFields() async throws {
        let a = try await Peer.make(FakeCloudKitAccount())
        try await a.save(entity("n1"))
        let got = try await a.device.fetch(["e.note.n1", "e.note.none"], keys: ["ver", "inc"])
        let record = try #require(got["e.note.n1"])
        #expect(Set(record.fields.keys) == ["ver", "inc"])
        #expect(record.systemFields != nil)
        #expect(got["e.note.none"] == nil)
    }

    // MARK: assets

    @Test func assetsAreCopiedToTheServerAtSaveAndStagedOnFetch() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud), b = try await Peer.make(cloud)
        let payload = Data((0..<5000).map { UInt8($0 % 251) })
        let record = try assetEntity("big", bytes: payload)
        guard case .asset(let source)? = record.fields["cipherAsset"] else { Issue.record("no asset"); return }
        try await a.save(record)
        try FileManager.default.removeItem(at: source)   // the local file may go away after the save
        try await b.fetch()
        guard case .asset(let staged)? = b.sink.changed(named: "e.note.big")?.fields["cipherAsset"] else { Issue.record("no staged asset"); return }
        #expect(try Data(contentsOf: staged) == payload)
        #expect(staged != source)
    }

    @Test func evictStagedAssetsDeletesEveryStagedFileAndRedeliveryStagesAgain() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud), b = try await Peer.make(cloud)
        try await a.save(try assetEntity("big", bytes: Data([1, 2, 3, 4])))
        try await b.fetch()
        guard case .asset(let staged)? = b.sink.changed(named: "e.note.big")?.fields["cipherAsset"] else { Issue.record("no staged asset"); return }
        #expect(FileManager.default.fileExists(atPath: staged.path))
        await b.device.evictStagedAssets()
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        #expect(await b.device.stagedFiles.isEmpty)
        // a later delivery of the same record brings a fresh staged copy
        let sink = RecordingSink()
        await b.device.expireTokenNextFetch()
        try await b.device.fetchChanges(into: sink)
        guard case .asset(let again)? = sink.changed(named: "e.note.big")?.fields["cipherAsset"] else { Issue.record("no staged asset"); return }
        #expect(FileManager.default.fileExists(atPath: again.path))
        #expect(try Data(contentsOf: again) == Data([1, 2, 3, 4]))
    }

    @Test func serverRecordChangedAssetsAreHandedOverPinnedNotEvictable() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud), b = try await Peer.make(cloud)
        try await a.save(try assetEntity("big", bytes: Data([7, 7, 7])))
        let outcome = try await b.save(try assetEntity("big", bytes: Data([8])))
        guard case .serverRecordChanged(let server) = outcome, case .asset(let staged)? = server.fields["cipherAsset"] else { Issue.record("got \(outcome)"); return }
        #expect(try Data(contentsOf: staged) == Data([7, 7, 7]))
        await b.device.evictStagedAssets()
        #expect(FileManager.default.fileExists(atPath: staged.path), "the persisted result holds a pinned copy (CK-R60), not a staged one")
        #expect(try Data(contentsOf: staged) == Data([7, 7, 7]))
    }

    @Test func aSaveWhoseAssetFileIsGoneFailsWithAssetFileNotFound() async throws {
        let a = try await Peer.make(FakeCloudKitAccount())
        let record = try assetEntity("big", bytes: Data([1]))
        guard case .asset(let source)? = record.fields["cipherAsset"] else { return }
        try FileManager.default.removeItem(at: source)
        #expect(try await a.save(record) == .failed(code: "assetFileNotFound"))
    }

    @Test func anAssetOverMaxAssetBytesIsRejectedAndNothingIsStored() async throws {
        let cloud = FakeCloudKitAccount(maxAssetBytes: 10)
        let a = try await Peer.make(cloud)
        #expect(try await a.save(try assetEntity("big", bytes: Data(count: 11))) == .failed(code: "assetTooLarge"))
        #expect(await cloud.recordNames.isEmpty)
        #expect(CloudKitGatewayContract.savedFields(try await a.save(try assetEntity("ok", bytes: Data(count: 10)))) != nil)
    }

    @Test func blobPartAssetsCanBeWithheldToModelLazyAssetDelivery() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud), b = try await Peer.make(cloud)
        let part = CloudRecordCodec.encode(CloudBlobPartHeader(
            hash: String(repeating: "a", count: 64), part: 0, parts: 1, partBytes: 33_554_432, totalBytes: 3,
            partSha256: String(repeating: "b", count: 64), asset: try tempFile(Data([1, 2, 3]))))
        try await a.save(part)
        await b.device.setFetchesBlobZone(true)       // the zone is not fetched by default; here it is, to test the asset knob
        await b.device.setDeliversBlobPartAssets(false)
        try await b.fetch()
        let delivered = try #require(b.sink.changed(named: part.name))
        #expect(delivered.fields["asset"] == nil)
        #expect(delivered.fields["hash"] != nil)
    }

    // MARK: quota and limits

    @Test func quotaExceededRejectsOnlyWritesAndClearsWhenRaised() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud), b = try await Peer.make(cloud)
        try await a.save(entity("small", payload: [1]))
        await cloud.setQuota(bytes: await cloud.usedBytes + 50)
        let big = entity("big", payload: Array(repeating: 9, count: 4000))
        #expect(try await a.save(big) == .quotaExceeded)
        #expect(await cloud.recordNames == ["e.note.small"])
        try await b.fetch()   // downloads never need quota
        #expect(b.sink.changedNames == ["e.note.small"])
        await cloud.setQuota(bytes: nil)
        #expect(CloudKitGatewayContract.savedFields(try await a.save(big)) != nil)
    }

    @Test func replacingARecordWithASmallerOneFreesQuota() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud)
        let t1 = try tag(try await a.save(entity("n1", payload: Array(repeating: 1, count: 3000))))
        await cloud.setQuota(bytes: await cloud.usedBytes + 10)
        #expect(CloudKitGatewayContract.savedFields(try await a.save(entity("n1", ver: 2, payload: [1], systemFields: t1))) != nil)
    }

    @Test func failNextQuotaExceededHitsTheNextSendAndNotAFetch() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud)
        await a.device.failNext(.quotaExceeded)
        try await a.fetch()
        #expect(try await a.save(entity("n1")) == .quotaExceeded)
        #expect(CloudKitGatewayContract.savedFields(try await a.save(entity("n1"))) != nil)
    }

    @Test func limitExceededSplitsTheOperationInHalfUntilItFits() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud)
        await cloud.setLimits(items: 2, bytes: 2_000_000)
        let outcomes = try await a.save((1...5).map { entity("n\($0)") })
        #expect(outcomes.allSatisfy { CloudKitGatewayContract.savedFields($0) != nil })
        let ops = await a.device.operationLog
        #expect(ops.contains("send:5:limitExceeded"))
        #expect(ops.filter { $0.hasPrefix("send:") && $0.hasSuffix(":ok") }.allSatisfy { Int($0.split(separator: ":")[1])! <= 2 })
        #expect(await cloud.recordNames.count == 5)
    }

    @Test func aSingleRecordOverTheByteLimitIsLimitExceeded() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud)
        await cloud.setLimits(items: 400, bytes: 1_000)
        let outcomes = try await a.save([entity("small", payload: [1]), entity("huge", payload: Array(repeating: 1, count: 5_000))])
        #expect(CloudKitGatewayContract.savedFields(outcomes[0]) != nil)
        #expect(outcomes[1] == .limitExceeded)
    }

    // MARK: network and account faults

    @Test func failNextOfflineIsReportedPerRecordOnSendAndThrownOnFetchOnceOnly() async throws {
        let a = try await Peer.make(FakeCloudKitAccount())
        await a.device.failNext(.offline)
        #expect(try await a.save(entity("n1")) == .offline)
        #expect(await a.device.sendLog.isEmpty, "a send that failed on the network never reached the server")
        #expect(await a.device.operationLog.contains("send:1:offline"))
        await a.device.failNext(.offline)
        await #expect(throws: CloudSyncError.offline) { try await a.fetch() }
        try await a.fetch()
        #expect(CloudKitGatewayContract.savedFields(try await a.save(entity("n1"))) != nil)
    }

    @Test func failNextUnauthenticated() async throws {
        let a = try await Peer.make(FakeCloudKitAccount())
        await a.device.failNext(.unauthenticated)
        #expect(try await a.save(entity("n1")) == .unauthenticated)
        await a.device.failNext(.unauthenticated)
        await #expect(throws: CloudSyncError.unauthenticated) { try await a.fetch() }
    }

    @Test func signOutFencesTheDeviceAndReportsNoAccount() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud)
        await a.device.signOut()
        #expect(await a.device.accountState() == .noAccount)
        #expect(await a.device.eventLog == [.accountChanged(.noAccount)])
        #expect(try await a.save(entity("n1")) == .fenced)
        await #expect(throws: CloudSyncError.fenced) { try await a.fetch() }
        #expect(await cloud.recordNames.isEmpty)
        // signing back in does not lift the fence by itself; prepare() does, after the caller's policy allowed it
        await a.device.signIn(user: cloud)
        #expect(try await a.save(entity("n1")) == .fenced)
        let state = try await a.device.prepare()
        #expect(state == .available(userHash: await cloud.userHash))
        #expect(CloudKitGatewayContract.savedFields(try await a.save(entity("n1"))) != nil)
    }

    @Test func switchAccountFencesDropsPendingAndNeverWritesToTheNewAccountUntilPrepared() async throws {
        let one = FakeCloudKitAccount(user: "one"), two = FakeCloudKitAccount(user: "two")
        let a = try await Peer.make(one)
        await a.device.setAutoSend(false)
        try await a.device.submit([CloudSave(attemptId: "p1", accountGeneration: 1, record: entity("n1"))])
        #expect(await a.device.pendingAttemptIds == ["p1"])
        await a.device.switchAccount(to: two)
        #expect(await a.device.eventLog == [.accountChanged(.available(userHash: await two.userHash))])
        #expect(await a.device.pendingAttemptIds.isEmpty, "the engine resets unsaved changes on an account change")
        await a.device.setAutoSend(true)
        #expect(try await a.save(entity("n2")) == .fenced)
        #expect(await one.recordNames.isEmpty)
        #expect(await two.recordNames.isEmpty)
        _ = try await a.device.prepare()
        #expect(CloudKitGatewayContract.savedFields(try await a.save(entity("n2"))) != nil)
        #expect(await two.recordNames == ["e.note.n2"])
        #expect(await one.recordNames.isEmpty)
    }

    @Test func restrictedAndTheOtherAccountStatesAreReported() async throws {
        let a = try await Peer.make(FakeCloudKitAccount())
        await a.device.restrict()
        #expect(await a.device.accountState() == .restricted)
        #expect(await a.device.eventLog.last == .accountChanged(.restricted))
        for state in [CloudAccountState.temporarilyUnavailable, .couldNotDetermine] {
            await a.device.setAccountState(state)
            #expect(await a.device.accountState() == state)
        }
    }

    @Test func aDeviceWithoutAnAccountPreparesToNoAccount() async throws {
        let a = try await Peer.make(nil, prepare: false)
        #expect(try await a.device.prepare() == .noAccount)
        #expect(try await a.save(entity("n1")) == .unauthenticated)
    }

    @Test func userHashIsTheSha256OfTheUserRecordName() async throws {
        let cloud = FakeCloudKitAccount(user: "_abc123")
        let expected = SHA256.hash(data: Data("_abc123".utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(await cloud.userHash == expected)
    }

    // MARK: zones

    @Test func creatingTheZoneForTheFirstTimeIsNotAZoneRemoval() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud, prepare: false)
        try await a.fetch()
        #expect(await a.device.eventLog.isEmpty)
        #expect(try a.store.zoneState() == .unknown)
        _ = try await a.device.prepare()
        #expect(try a.store.zoneState() == .created)
        #expect(await cloud.zonePresent)
    }

    @Test func aRemovedZoneIsReportedOnFetchAndSaveAndNotRecreatedByPrepare() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud)
        try await a.save(entity("n1"))
        await cloud.removeZone(reason: .userDeletedZone)
        try await a.fetch()
        #expect(await a.device.eventLog == [.zoneRemoved(.userDeletedZone)])
        #expect(try a.store.zoneState() == .removed(.userDeletedZone))
        #expect(try await a.save(entity("n2")) == .zoneNotFound)
        _ = try await a.device.prepare()
        #expect(await cloud.zonePresent == false, "prepare() creates the zone only from unknown")
        #expect(try await a.save(entity("n2")) == .zoneNotFound)
        // the explicit "upload again" path: the caller sets unknown, then prepare() creates a fresh empty zone
        try a.store.setZoneState(.unknown)
        _ = try await a.device.prepare()
        #expect(await cloud.zonePresent)
        #expect(await cloud.recordNames.isEmpty)
        #expect(CloudKitGatewayContract.savedFields(try await a.save(entity("n2"))) != nil)
    }

    @Test func everyRemovalReasonIsReported() async throws {
        for reason in [ZoneRemoval.deleted, .purged, .encryptedDataReset, .userDeletedZone] {
            let cloud = FakeCloudKitAccount()
            let a = try await Peer.make(cloud)
            await cloud.removeZone(reason: reason)
            try await a.fetch()
            #expect(await a.device.eventLog == [.zoneRemoved(reason)])
        }
    }

    @Test func aZoneRemovedWhileUnknownOnANewDeviceStartsFresh() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud)
        try await a.save(entity("n1"))
        await cloud.removeZone(reason: .deleted)
        let newDevice = try await Peer.make(cloud)
        #expect(await cloud.zonePresent)
        #expect(try newDevice.store.zoneState() == .created)
        #expect(await cloud.recordNames.isEmpty)
    }

    @Test func deleteZoneRemovesTheZoneAndLeavesTheDeviceRemoved() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud)
        try await a.save(entity("n1"))
        try await a.device.deleteZone()
        #expect(await cloud.zonePresent == false)
        #expect(await a.device.deleteLog == ["zone"])
        #expect(try a.store.zoneState() == .removed(.deleted))
    }

    @Test func deleteLogsEveryNameAndIgnoresMissingOnes() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud)
        try await a.save(entity("n1"))
        try await a.device.delete(["e.note.n1", "e.note.never"])
        #expect(await a.device.deleteLog == ["e.note.n1", "e.note.never"])
        #expect(await cloud.recordNames.isEmpty)
    }

    // MARK: lost and late responses

    @Test func lostResponseAfterCommitLandsTheSaveButReportsANetworkFailure() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud)
        await a.device.loseNextResponseAfterCommit()
        let outcome = try await a.save(entity("n1", sid: "attempt-1"))
        #expect(outcome == .offline)
        let landed = try #require(await cloud.record(named: "e.note.n1"))
        #expect(try decodedEntity(landed).sid == "attempt-1")
        // the retry of the same create now conflicts, with our own attempt id on the server version
        let retry = try await a.save(entity("n1", sid: "attempt-1"))
        guard case .serverRecordChanged(let server) = retry else { Issue.record("got \(retry)"); return }
        #expect(try decodedEntity(server).sid == "attempt-1")
    }

    @Test func lostResponseCanAlsoBeSilentSoNoResultIsEverRecorded() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud)
        await a.device.loseNextResponseAfterCommit(report: .silence)
        try await a.device.submit([CloudSave(attemptId: "lost", accountGeneration: 1, record: entity("n1"))])
        #expect(a.store.outcome(for: "lost") == nil)
        #expect(await cloud.recordNames == ["e.note.n1"])
        #expect(await a.device.pendingAttemptIds.isEmpty)
    }

    @Test func lateCompletionAfterCancelCommitsToTheOriginalAccountWithTheOldGeneration() async throws {
        let one = FakeCloudKitAccount(user: "one"), two = FakeCloudKitAccount(user: "two")
        let a = try await Peer.make(one)
        await a.device.completeLateAfterCancel()
        try await a.device.submit([CloudSave(attemptId: "late", accountGeneration: 7, record: entity("n1"))])
        #expect(a.store.outcome(for: "late") == nil)
        #expect(await one.recordNames.isEmpty)
        await a.device.switchAccount(to: two)
        #expect(a.store.outcome(for: "late") == nil, "still on the wire after cancelOperations")
        await a.device.deliverLateCompletions()
        #expect(await one.recordNames == ["e.note.n1"])
        #expect(await two.recordNames.isEmpty)
        let result = try #require(a.store.result(for: "late"))
        #expect(result.accountGeneration == 7)
        #expect(CloudKitGatewayContract.savedFields(result.outcome) != nil)
    }

    // MARK: restart

    @Test func pendingSavesAreDurableAcrossARestartAndResultsReachTheStore() async throws {
        let cloud = FakeCloudKitAccount()
        let disk = FakeDeviceDisk(), store = InMemoryCloudGatewayStore()
        let a = try await Peer.make(cloud, disk: disk, store: store)
        await a.device.setAutoSend(false)
        try await a.device.submit([CloudSave(attemptId: "p1", accountGeneration: 3, record: entity("n1"))])
        #expect(await cloud.recordNames.isEmpty)
        let restarted = try await Peer.make(cloud, disk: disk, store: store)
        #expect(await restarted.device.pendingAttemptIds == ["p1"])
        try await restarted.device.sendPending()
        #expect(await cloud.recordNames == ["e.note.n1"])
        #expect(store.result(for: "p1")?.accountGeneration == 3)
        #expect(await restarted.device.pendingAttemptIds.isEmpty)
        let third = try await Peer.make(cloud, disk: disk, store: store)
        #expect(await third.device.pendingAttemptIds.isEmpty)
    }

    // MARK: server-side damage

    @Test func corruptChangesOneFieldOfTheStoredRecordAndBumpsItsTag() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud), b = try await Peer.make(cloud)
        let t1 = try tag(try await a.save(entity("n1", payload: [1, 2, 3])))
        await cloud.corrupt(record: "e.note.n1", field: "cipher")
        try await b.fetch()
        let delivered = try #require(b.sink.changed(named: "e.note.n1"))
        #expect(delivered.fields["cipher"] != .bytes(Data([1, 2, 3])))
        #expect(delivered.systemFields != t1)
        #expect(try await a.save(entity("n1", ver: 2, systemFields: t1)).isConflict)
    }

    @Test func injectUnsupportedVersionMakesTheCodecRejectItAsAFutureVersion() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud), b = try await Peer.make(cloud)
        try await a.save(entity("n1"))
        await cloud.injectUnsupportedVersion(record: "e.note.n1")
        try await b.fetch()
        let delivered = try #require(b.sink.changed(named: "e.note.n1"))
        #expect(CloudRecordCodecTests.reason(delivered) == .version(99))
    }

    // MARK: events and instrumentation

    @Test func pushRemoteChangeEmitsARemoteChangeEvent() async throws {
        let a = try await Peer.make(FakeCloudKitAccount())
        await a.device.pushRemoteChange()
        #expect(await a.device.eventLog == [.remoteChange])
    }

    @Test func theEventStreamDeliversEventsToAConsumer() async throws {
        let a = try await Peer.make(FakeCloudKitAccount())
        let stream = a.device.events
        let consumer = Task { () -> [CloudGatewayEvent] in
            var seen: [CloudGatewayEvent] = []
            for await event in stream { seen.append(event); if seen.count == 2 { break } }
            return seen
        }
        await a.device.pushRemoteChange()
        await a.device.signOut()
        #expect(await consumer.value == [.remoteChange, .accountChanged(.noAccount)])
    }

    @Test func autoPushNotifiesOtherDevicesOfTheSameAccountAfterACommit() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud), b = try await Peer.make(cloud)
        await cloud.setAutoPush(true)
        try await a.save(entity("n1"))
        #expect(await b.device.eventLog == [.remoteChange])
        #expect(await a.device.eventLog.isEmpty)
    }

    @Test func sendLogRecordsAttemptNameAndTagUsage() async throws {
        let a = try await Peer.make(FakeCloudKitAccount())
        try await a.device.submit([CloudSave(attemptId: "x1", accountGeneration: 2, record: entity("n1"))])
        let entry = try #require(await a.device.sendLog.first)
        #expect(entry.attemptId == "x1" && entry.recordName == "e.note.n1" && entry.accountGeneration == 2)
        #expect(entry.hadSystemFields == false)
    }
}

extension CloudSaveOutcome {
    var isConflict: Bool { if case .serverRecordChanged = self { return true }; return false }
}
