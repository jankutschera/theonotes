// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

/// Codex review findings C2, I1 to I4 of Task 4 (fix round 1).

struct SplitMix {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}

/// The CK-R5 ordering rule for one incarnation: keep the highest `ver`, ignore lower and equal.
final class VersionOrderingSink: CloudChangeSink, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var held: [String: Int64] = [:]
    private let ordered: Bool
    init(ordered: Bool = true) { self.ordered = ordered }

    func commit(changed: [CloudRecord], deletedNames: [String]) throws {
        lock.lock(); defer { lock.unlock() }
        for record in changed {
            guard case .entity(let header) = try CloudRecordCodec.decode(record) else { continue }
            if ordered, let current = held[record.name], header.ver <= current { continue }
            held[record.name] = header.ver
        }
        for name in deletedNames { held[name] = nil }
    }
    func saveEngineState(_ state: Data) throws { lock.lock(); defer { lock.unlock() }; saved = state }
    private(set) var saved: Data?
    func beginFullRefetch() throws {}
    func endFullRefetch() throws {}
}

@Suite struct FakeCloudKitFixRound1Tests {
    // MARK: C2 conflict assets must be durable

    @Test func aConflictAssetIsPinnedOutsideTheStagingAreaBeforeTheResultIsRecorded() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud), b = try await Peer.make(cloud)
        try await a.save(try assetEntity("big", bytes: Data([7, 7, 7])))
        let outcome = try await b.save(try assetEntity("big", bytes: Data([8])))
        guard case .serverRecordChanged(let server) = outcome, case .asset(let url)? = server.fields["cipherAsset"] else { Issue.record("got \(outcome)"); return }
        let staging = b.device.stagingDirectory.path
        #expect(!url.path.hasPrefix(staging), "a persisted result must not hold a staged URL")
        #expect(!url.path.hasPrefix(await cloud.rootPath), "nor a server path")
        await b.device.evictStagedAssets()
        #expect(try Data(contentsOf: url) == Data([7, 7, 7]))
        // and the stored form (what ck_send_result keeps) holds only pinned paths
        for id in b.store.attemptIds {
            guard case .serverRecordChanged(let stored)? = b.store.outcome(for: id) else { continue }
            if case .asset(let storedURL)? = stored.fields["cipherAsset"] { #expect(!storedURL.path.hasPrefix(staging)) }
        }
    }

    @Test func aPinnedConflictAssetSurvivesARestartBetweenRecordAndConsume() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud)
        let disk = FakeDeviceDisk(), store = InMemoryCloudGatewayStore()
        let b = try await Peer.make(cloud, disk: disk, store: store)
        try await a.save(try assetEntity("big", bytes: Data([1, 2, 3, 4])))
        try await b.save(try assetEntity("big", bytes: Data([9])))
        await b.device.evictStagedAssets()
        let restarted = try await Peer.make(cloud, disk: disk, store: store)
        await restarted.device.evictStagedAssets()
        let attempt = try #require(store.attemptIds.first)
        let stored = try CloudSaveOutcome.decode(try #require(store.outcome(for: attempt)).encoded())
        guard case .serverRecordChanged(let server) = stored, case .asset(let url)? = server.fields["cipherAsset"] else { Issue.record("got \(stored)"); return }
        #expect(try Data(contentsOf: url) == Data([1, 2, 3, 4]))
    }

    @Test func aConflictAssetThatIsGoneBeforePinningIsRecordedAsUnavailable() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud), b = try await Peer.make(cloud)
        try await a.save(try assetEntity("big", bytes: Data([7])))
        await b.device.evictStagedAssetsBeforePinning()
        #expect(try await b.save(try assetEntity("big", bytes: Data([8]))) == .failed(code: "conflictAssetUnavailable"))
        #expect(await cloud.versionCount(of: "e.note.big") == 1)
    }

    // MARK: I1 atomic mode is all or nothing

    @Test func atomicModeStagesAndValidatesTheWholeTransactionIncludingCumulativeQuota() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud)
        try await a.save(entity("seed", payload: [1]))
        let each = entity("x", payload: Array(repeating: 1, count: 1000)).approximateSize
        await cloud.setQuota(bytes: await cloud.usedBytes + each + each / 2)   // one fits, two do not
        await a.device.setAtomicByZone(true)
        let outcomes = try await a.save([entity("x", payload: Array(repeating: 1, count: 1000)), entity("y", payload: Array(repeating: 2, count: 1000))])
        #expect(outcomes[0] == .failed(code: "batchRequestFailed"))
        #expect(outcomes[1] == .quotaExceeded)
        #expect(await cloud.recordNames == ["e.note.seed"], "nothing of the transaction may be saved")
    }

    @Test func nonAtomicModeStillSavesTheFirstRecordWhenTheSecondDoesNotFit() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud)
        try await a.save(entity("seed", payload: [1]))
        let each = entity("x", payload: Array(repeating: 1, count: 1000)).approximateSize
        await cloud.setQuota(bytes: await cloud.usedBytes + each + each / 2)
        let outcomes = try await a.save([entity("x", payload: Array(repeating: 1, count: 1000)), entity("y", payload: Array(repeating: 2, count: 1000))])
        #expect(CloudKitGatewayContract.savedFields(outcomes[0]) != nil)
        #expect(outcomes[1] == .quotaExceeded)
    }

    @Test func atomicModeAssetCopyFailureLeavesNothingSaved() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud)
        await a.device.setAtomicByZone(true)
        await cloud.failNextAssetCopy()
        let outcomes = try await a.save([entity("a"), try assetEntity("b", bytes: Data([1])), entity("c")])
        #expect(outcomes[0] == .failed(code: "batchRequestFailed"))
        #expect(outcomes[1] == .failed(code: "assetFileNotFound"))
        #expect(outcomes[2] == .failed(code: "batchRequestFailed"))
        #expect(await cloud.recordNames.isEmpty)
    }

    // MARK: I2 pending intent stays until the outcome is durable

    @Test func aStoreFailureWhileRecordingOutcomesLeavesTheRemainderPending() async throws {
        let cloud = FakeCloudKitAccount()
        let disk = FakeDeviceDisk(), store = InMemoryCloudGatewayStore()
        let a = try await Peer.make(cloud, disk: disk, store: store)
        store.failRecord(onCall: 2)
        let saves = (1...3).map { CloudSave(attemptId: "p\($0)", accountGeneration: 1, record: entity("n\($0)")) }
        await #expect(throws: (any Error).self) { try await a.device.submit(saves) }
        #expect(await a.device.pendingAttemptIds == ["p2", "p3"])
        #expect(store.outcome(for: "p1") != nil)
        let restarted = try await Peer.make(cloud, disk: disk, store: store)
        #expect(await restarted.device.pendingAttemptIds == ["p2", "p3"])
        try await restarted.device.sendPending()
        #expect(store.outcome(for: "p2") != nil && store.outcome(for: "p3") != nil)
        #expect(await restarted.device.pendingAttemptIds.isEmpty)
    }

    @Test func aFailureAfterTheSendBeforeAnyOutcomeIsStoredKeepsTheWholeBatchPending() async throws {
        let cloud = FakeCloudKitAccount()
        let disk = FakeDeviceDisk(), store = InMemoryCloudGatewayStore(), crash = CrashPoint()
        let device = FakeCloudKitDevice(account: cloud, store: store, disk: disk, crash: crash)
        _ = try await device.prepare()
        crash.arm("afterSend")
        let saves = (1...2).map { CloudSave(attemptId: "p\($0)", accountGeneration: 1, record: entity("n\($0)")) }
        await #expect(throws: CrashInjected(boundary: "afterSend")) { try await device.submit(saves) }
        #expect(await cloud.recordNames.sorted() == ["e.note.n1", "e.note.n2"], "the saves did land")
        #expect(store.attemptIds.isEmpty)
        #expect(disk.pending.map(\.attemptId) == ["p1", "p2"])
        // restart: the intent is resent; the landed creates come back as conflicts carrying our attempt ids (resolved by CK-R4)
        let restarted = try await Peer.make(cloud, disk: disk, store: store)
        try await restarted.device.sendPending()
        for id in ["p1", "p2"] { #expect(store.outcome(for: id)?.isConflict == true) }
        #expect(disk.pending.isEmpty)
    }

    @Test func manyPendingSavesAreSentInBatchesAndAllLeaveThePendingList() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud)
        let saves = (1...250).map { CloudSave(attemptId: "p\($0)", accountGeneration: 1, record: entity("n\($0)")) }
        try await a.device.submit(saves)
        #expect(await a.device.pendingAttemptIds.isEmpty)
        #expect(await cloud.recordNames.count == 250)
        #expect(a.store.attemptIds.count == 250)
    }

    @Test func accountGenerationsAreInt64AndReachTheStoreUnchanged() async throws {
        let a = try await Peer.make(FakeCloudKitAccount())
        let big: Int64 = 5_000_000_000
        try await a.save(entity("n1"), generation: big)
        let id = try #require(a.store.attemptIds.first)
        #expect(a.store.result(for: id)?.accountGeneration == big)
        #expect(await a.device.sendLog.first?.accountGeneration == big)
    }

    // MARK: I3 no server path escapes

    @Test func aStagingCopyFailureFailsDeliveryAndNoServerPathEscapes() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud), b = try await Peer.make(cloud)
        try await a.save(try assetEntity("big", bytes: Data([1, 2, 3])))
        await b.device.failNextStaging()
        await #expect(throws: CloudSyncError.failed(code: "assetNotAvailable")) { try await b.fetch() }
        #expect(b.sink.allChanged.isEmpty)
        #expect(b.sink.lastState == nil)
        try await b.fetch()
        let urls = b.sink.allChanged.compactMap { record -> URL? in if case .asset(let u)? = record.fields["cipherAsset"] { return u }; return nil }
        #expect(urls.count == 1)
        for url in urls {
            #expect(url.path.hasPrefix(b.device.stagingDirectory.path))
            #expect(!url.path.hasPrefix(await cloud.rootPath))
        }
    }

    @Test func aStagingCopyFailureOnFetchByNameThrowsInsteadOfReturningTheServerFile() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud)
        try await a.save(try assetEntity("big", bytes: Data([1])))
        await a.device.failNextStaging()
        await #expect(throws: CloudSyncError.failed(code: "assetNotAvailable")) { _ = try await a.device.fetch(["e.note.big"], keys: nil) }
    }

    // MARK: I4 adversarial delivery across batches

    @Test func aStaleVersionCanArriveInALaterBatchThanTheNewerOne() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud), b = try await Peer.make(cloud)
        let t1 = try tag(try await a.save(entity("x", ver: 1)))
        try await a.save(entity("x", ver: 2, systemFields: t1))
        try await a.save([entity("p"), entity("q"), entity("r")])
        await b.device.setFetchBatchSize(1)
        await b.device.deliverStaleVersion(of: "e.note.x", afterBatches: 2)
        try await b.fetch()
        let order = try b.sink.allChanged.map { "\($0.name)@\(try decodedEntity($0).ver)" }
        #expect(order == ["e.note.x@2", "e.note.p@1", "e.note.q@1", "e.note.x@1", "e.note.r@1"])
    }

    @Test func aDelayedRecordNeverLetsTheSavedStatePassIt() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud), b = try await Peer.make(cloud)
        try await a.save(entity("n0"))
        try await b.fetch()
        try await a.save([entity("n1"), entity("n2"), entity("n3")])
        await b.device.setFetchBatchSize(1)
        await b.device.delayDelivery(of: "e.note.n1", byBatches: 3)   // a batch of its own, behind n2 and n3
        b.sink.failCommit(onCall: 3)                 // order is n2, n3, n1: the commit of n1 fails
        await #expect(throws: (any Error).self) { try await b.fetch() }
        #expect(b.sink.changedNames.suffix(2) == ["e.note.n2", "e.note.n3"])
        let state = try #require(b.sink.lastState)
        let restarted = try await Peer.make(cloud, engineState: state)
        try await restarted.fetch()
        #expect(restarted.sink.changedNames.contains("e.note.n1"), "a state saved after n3 must not skip the delayed n1")
    }

    @Test func armedAdversaryFaultsDoNotLeakIntoTheNextFetch() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud), b = try await Peer.make(cloud)
        let t1 = try tag(try await a.save(entity("n1", ver: 1)))
        let t2 = try tag(try await a.save(entity("n1", ver: 2, systemFields: t1)))
        await b.device.deliverStaleVersion(of: "e.note.n1")          // applies to this fetch only
        await b.device.delayDelivery(of: "e.note.n9", byBatches: 3)  // not in the delta: dropped
        try await b.fetch()
        #expect(try b.sink.allChanged.map { try decodedEntity($0).ver } == [2, 1])
        try await a.save(entity("n1", ver: 3, systemFields: t2))
        try await b.fetch()
        #expect(try b.sink.allChanged.map { try decodedEntity($0).ver } == [2, 1, 3], "the stale injection of the first fetch must not repeat")
    }

    @Test func aVersionOrderingReceiverConvergesUnderAdversarialDeliveryAndANaiveOneDoesNot() async throws {
        var naiveDiverged = 0
        for seed in 1...150 {
            var rng = SplitMix(UInt64(seed))
            let cloud = FakeCloudKitAccount()
            let writer = try await Peer.make(cloud)
            let ordered = try await Peer.make(cloud), naive = try await Peer.make(cloud)
            let orderedSink = VersionOrderingSink(), naiveSink = VersionOrderingSink(ordered: false)
            var tags: [String: Data] = [:], vers: [String: Int64] = [:]

            for _ in 0..<(2 + rng.below(3)) {
                for _ in 0..<(1 + rng.below(5)) {
                    let id = "n\(rng.below(6))"
                    let key = "e.note.\(id)"
                    let ver = (vers[key] ?? 0) + 1
                    let outcome = try await writer.save(entity(id, ver: ver, systemFields: tags[key]))
                    tags[key] = try tag(outcome); vers[key] = ver
                }
                let batch = 1 + rng.below(4)
                let seedForShuffle = rng.next()
                let staleName = "e.note.n\(rng.below(6))", staleAfter = rng.below(3)
                let delayName = "e.note.n\(rng.below(6))", delayBy = rng.below(3)
                let redeliver = rng.below(4) == 0, expire = rng.below(5) == 0
                for (peer, sink) in [(ordered, orderedSink), (naive, naiveSink)] {
                    await peer.device.setFetchBatchSize(batch)
                    await peer.device.reorderBatch(seed: seedForShuffle)
                    await peer.device.deliverStaleVersion(of: staleName, afterBatches: staleAfter)
                    await peer.device.delayDelivery(of: delayName, byBatches: delayBy)
                    if redeliver { await peer.device.redeliverBatch() }
                    if expire { await peer.device.expireTokenNextFetch() }
                    try await peer.device.fetchChanges(into: sink)
                }
            }
            for (peer, sink) in [(ordered, orderedSink), (naive, naiveSink)] { try await peer.device.fetchChanges(into: sink) }

            #expect(orderedSink.held == vers, "seed \(seed): an ordering receiver must end at the server's versions")
            if naiveSink.held != vers { naiveDiverged += 1 }
        }
        #expect(naiveDiverged > 20, "the adversary must actually bite a last-write-wins receiver (\(naiveDiverged)/150)")
    }
}
