// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CloudKit
import Foundation
import Testing
@testable import TheoNotesCore

// The gateway's event handling without CloudKit: the engine is a script (`ScriptedEngine`), the events are plain values, the base record
// comes from a captured archive (`LiveGatewayFixture`). Fix round 1 of Task 14: stale callbacks, incomplete fetches, engines
// reused after a failed final commit, outcomes lost after a store failure, the subscription.

final class ScriptedEngine: SyncEngineHandle, @unchecked Sendable {
    let epoch: Int
    let state: Data?
    private let lock = NSLock()
    private var pending: [CKRecord.ID] = []
    private var sends = 0, fetches = 0
    var onSend: (@Sendable (ScriptedEngine, Int) async throws -> Void)?
    var onFetch: (@Sendable (ScriptedEngine) async throws -> Void)?

    init(epoch: Int, state: Data?) { self.epoch = epoch; self.state = state }

    var sendCount: Int { lock.withLock { sends } }
    var fetchCount: Int { lock.withLock { fetches } }
    func fetchChanges() async throws { lock.withLock { fetches += 1 }; try await onFetch?(self) }
    func sendChanges() async throws { let n = lock.withLock { sends += 1; return sends }; try await onSend?(self, n) }
    func cancelOperations() async {}
    var pendingSaveIDs: [CKRecord.ID] { lock.withLock { pending } }
    func addPendingSaves(_ ids: [CKRecord.ID]) { lock.withLock { for id in ids where !pending.contains(id) { pending.append(id) } } }
    func removePendingSaves(_ ids: [CKRecord.ID]) { lock.withLock { pending.removeAll { ids.contains($0) } } }
    func addPendingZoneSaves(_ ids: [CKRecordZone.ID]) {}
    func removePendingZoneSaves(_ ids: [CKRecordZone.ID]) {}
    func clearPending() { lock.withLock { pending = [] } }
}

final class RefusingStore: CloudGatewayStore, @unchecked Sendable {
    let inner = InMemoryCloudGatewayStore()
    private let lock = NSLock()
    private var _refuse = false
    var refuse: Bool { get { lock.withLock { _refuse } } set { lock.withLock { _refuse = newValue } } }
    func zoneState() throws -> CloudZoneState { try inner.zoneState() }
    func setZoneState(_ state: CloudZoneState) throws { try inner.setZoneState(state) }
    private var _revoke = false
    /// The store answers like the SQLite one does while the durable fence is up.
    var revoke: Bool { get { lock.withLock { _revoke } } set { lock.withLock { _revoke = newValue } } }
    func recordSendResult(attemptId: String, accountGeneration: Int64, outcome: CloudSaveOutcome) throws {
        if revoke { throw CloudSyncStoreError.accountFenced }
        if refuse { throw SinkFailure(what: "refused") }
        try inner.recordSendResult(attemptId: attemptId, accountGeneration: accountGeneration, outcome: outcome)
    }
}

/// A sink that fails on demand, in front of the usual recorder.
final class FlakySink: CloudChangeSink, @unchecked Sendable {
    let inner = RecordingSink()
    private let lock = NSLock()
    private var failEnds = 0, failStates = 0
    func failEnd(times: Int) { lock.withLock { failEnds = times } }
    func failState(times: Int) { lock.withLock { failStates = times } }
    func commit(changed: [CloudRecord], deletedNames: [String]) throws { try inner.commit(changed: changed, deletedNames: deletedNames) }
    func saveEngineState(_ state: Data) throws {
        if lock.withLock({ if failStates > 0 { failStates -= 1; return true } else { return false } }) { throw SinkFailure(what: "state") }
        try inner.saveEngineState(state)
    }
    func beginFullRefetch() throws { try inner.beginFullRefetch() }
    func endFullRefetch() throws {
        if lock.withLock({ if failEnds > 0 { failEnds -= 1; return true } else { return false } }) { throw SinkFailure(what: "end") }
        try inner.endFullRefetch()
    }
}

final class GatewayRig: @unchecked Sendable {
    let store: any CloudGatewayStore
    private let lock = NSLock()
    private var _engines: [ScriptedEngine] = []
    private var _account: CloudAccountState = .available(userHash: "account-A")
    private var _subscriptionCalls = 0
    private var _subscriptionFails = false
    var script: @Sendable (ScriptedEngine, GatewayRig) -> Void = { _, _ in }
    var gateway: LiveCloudKitGateway!

    var engines: [ScriptedEngine] { lock.withLock { _engines } }
    var account: CloudAccountState { get { lock.withLock { _account } } set { lock.withLock { _account = newValue } } }
    var subscriptionCalls: Int { lock.withLock { _subscriptionCalls } }
    var subscriptionFails: Bool { get { lock.withLock { _subscriptionFails } } set { lock.withLock { _subscriptionFails = newValue } } }

    init(store: (any CloudGatewayStore)? = nil, engineState: Data? = nil, zoneCreated: Bool = true) {
        let store = store ?? InMemoryCloudGatewayStore()
        self.store = store
        if zoneCreated { try? store.setZoneState(.created) }
        let hooks = LiveGatewayHooks(
            makeEngine: { [unowned self] state, epoch in
                let engine = ScriptedEngine(epoch: epoch, state: state)
                self.script(engine, self)
                self.lock.withLock { self._engines.append(engine) }
                return engine
            },
            accountState: { [unowned self] in self.account },
            ensureSubscription: { [unowned self] in
                self.lock.withLock { self._subscriptionCalls += 1 }
                if self.subscriptionFails { throw SinkFailure(what: "subscription") }
            })
        gateway = LiveCloudKitGateway(configuration: LiveGatewayFixture.configuration, store: store, engineState: engineState,
                                      pinDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("rig-pins-\(UUID().uuidString)"),
                                      batchItemLimit: 100, automaticallySync: false, hooks: hooks)
    }

    func save(_ attempt: String, ver: Int64 = 1, generation: Int64 = 1) -> CloudSave {
        CloudSave(attemptId: attempt, accountGeneration: generation, record: CloudKitGatewayContract.entity("arch", ver: ver, sid: attempt))
    }

    func outcome(_ attempt: String) -> CloudSaveOutcome? { ((store as? InMemoryCloudGatewayStore) ?? (store as? RefusingStore)?.inner)?.outcome(for: attempt) }
}

/// The fixture record (change tag "3") as an engine would report a save of the attempt whose `sid` is given.
func fixtureRecord(sid: String) throws -> CKRecord {
    let record = try LiveGatewayFixture.record()
    record["sid"] = sid
    return record
}

/// The record of a failed save: the one the gateway handed out, which carries the attempt's `sid`.
func failureRecord(_ id: CKRecord.ID, sid: String) throws -> CKRecord {
    let record = CKRecord(recordType: "Entity", recordID: id)
    record["sid"] = sid
    return record
}

func ckError(_ code: CKError.Code, _ userInfo: [String: Any] = [:]) -> CKError {
    CKError(_nsError: NSError(domain: CKErrorDomain, code: code.rawValue, userInfo: userInfo))
}

/// What a script does when the engine is asked to send: hand the pending saves out (as the delegate's batch callback would).
@Sendable func handOut(_ engine: ScriptedEngine, _ rig: GatewayRig) async {
    _ = await rig.gateway.selectBatch(pending: engine.pendingSaveIDs, epoch: engine.epoch)
}

final class Observations: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    subscript(key: String) -> String? { get { lock.withLock { values[key] } } set { lock.withLock { values[key] = newValue } } }
}

@Suite(.serialized) struct LiveCloudKitGatewayEventTests {
    // MARK: C1 stale callbacks

    @Test func aLateResultOfAnOldEngineNeverCompletesOrCachesForANewerAttempt() async throws {
        let rig = GatewayRig()
        let seen = Observations()
        let fixture = try LiveGatewayFixture.record()
        let id = fixture.recordID
        rig.script = { engine, rig in
            switch engine.epoch {
            case 1:      // the first engine takes the save and the response is lost
                engine.onSend = { engine, _ in await handOut(engine, rig); engine.clearPending() }
            default:     // the engine of the new account: while it holds the new attempt, the OLD engine answers
                engine.onSend = { engine, _ in
                    await handOut(engine, rig)
                    await rig.gateway.processSent(saved: [try fixtureRecord(sid: "attempt-1")], failed: [], epoch: 1)
                    seen["queuedDuringStale"] = "\(await rig.gateway.queuedSaveCount())"
                    seen["newAttemptResultDuringStale"] = "\(rig.outcome("attempt-2") != nil)"
                    seen["cacheDuringStale"] = "\(await rig.gateway.cachedTag(for: id) ?? "none")"
                    engine.clearPending()
                }
            }
        }
        _ = try await rig.gateway.prepare()
        try await rig.gateway.submit([rig.save("attempt-1")])
        #expect(await rig.gateway.lateSaveCount() == 1, "the lost response stays reachable as a late result, outside the queue")
        #expect(await rig.gateway.queuedSaveCount() == 0)

        await rig.gateway.processAccountChange(.available(userHash: "account-B"), epoch: 1)        // the account switch
        rig.account = .available(userHash: "account-B")
        _ = try await rig.gateway.prepare()
        try await rig.gateway.submit([rig.save("attempt-2", generation: 2)])

        #expect(seen["newAttemptResultDuringStale"] == "false", "the old engine's result completed the new account's attempt")
        #expect(seen["queuedDuringStale"] == "1", "the stale event changed the queue")
        #expect(seen["cacheDuringStale"] == "none", "the old account's archive entered the base cache")
        // The late result is still recorded, for the attempt it answers and with that attempt's generation
        if case .saved? = rig.outcome("attempt-1") {} else { Issue.record("the late result of attempt-1 must be recorded, got \(String(describing: rig.outcome("attempt-1")))") }
    }

    @Test func aDuplicateResultNeverCompletesTheNextSaveOfTheSameRecord() async throws {
        let rig = GatewayRig()
        let seen = Observations()
        let id = try LiveGatewayFixture.recordID
        rig.script = { engine, rig in
            engine.onSend = { engine, n in
                guard n == 1 else { engine.clearPending(); return }
                await handOut(engine, rig)                          // first save of the record is out
                let failed = [(record: try failureRecord(id, sid: "first"), error: ckError(.quotaExceeded))]
                await rig.gateway.processSent(saved: [], failed: failed, epoch: engine.epoch)              // its result
                await rig.gateway.processSent(saved: [], failed: failed, epoch: engine.epoch)              // the same event again
                seen["second"] = "\(rig.outcome("second") != nil)"
                engine.clearPending()
            }
        }
        _ = try await rig.gateway.prepare()
        try await rig.gateway.submit([rig.save("first"), rig.save("second", ver: 2)])
        #expect(rig.outcome("first") == .quotaExceeded)
        #expect(seen["second"] == "false", "a repeated event completed whatever sat at the head of the record's queue")
    }

    @Test func aSavedResultOfTheCurrentEngineFillsTheCache() async throws {
        let rig = GatewayRig()
        let id = try LiveGatewayFixture.recordID
        rig.script = { engine, rig in
            engine.onSend = { engine, _ in
                await handOut(engine, rig)
                await rig.gateway.processSent(saved: [try fixtureRecord(sid: "a")], failed: [], epoch: engine.epoch)
                engine.clearPending()
            }
        }
        _ = try await rig.gateway.prepare()
        try await rig.gateway.submit([rig.save("a")])
        if case .saved(let fields)? = rig.outcome("a") { #expect(CloudRecordMapping.SystemFields.parse(fields)?.tag == "3") }
        else { Issue.record("expected saved, got \(String(describing: rig.outcome("a")))") }
        #expect(await rig.gateway.cachedTag(for: id) == "3")
    }

    // MARK: fix round 2: a result belongs to exactly one attempt

    private func recordWithSid(_ sid: String) throws -> CKRecord {
        let record = try LiveGatewayFixture.record()
        record["sid"] = sid
        return record
    }

    @Test func aResultWithAnotherAttemptsSidNeverCompletesTheHeadOfTheQueue() async throws {
        let rig = GatewayRig()
        let seen = Observations()
        let id = try LiveGatewayFixture.recordID
        rig.script = { engine, rig in
            engine.onSend = { engine, _ in
                await handOut(engine, rig)
                // an answer of an EARLIER lost attempt of this record arrives on the same engine
                await rig.gateway.processSent(saved: [try self.recordWithSid("attempt-0")], failed: [], epoch: engine.epoch)
                seen["outcomeAfterOld"] = "\(rig.outcome("attempt-1") != nil)"
                seen["cacheAfterOld"] = "\(await rig.gateway.cachedTag(for: id) ?? "none")"
                seen["queued"] = "\(await rig.gateway.queuedSaveCount())"
                // and then its own
                await rig.gateway.processSent(saved: [try self.recordWithSid("attempt-1")], failed: [], epoch: engine.epoch)
                engine.clearPending()
            }
        }
        _ = try await rig.gateway.prepare()
        try await rig.gateway.submit([rig.save("attempt-1")])
        #expect(seen["outcomeAfterOld"] == "false", "another attempt's result completed attempt-1")
        #expect(seen["cacheAfterOld"] == "none", "another attempt's archive entered the base cache")
        #expect(seen["queued"] == "1")
        if case .saved? = rig.outcome("attempt-1") {} else { Issue.record("attempt-1's own result must complete it, got \(String(describing: rig.outcome("attempt-1")))") }
    }

    @Test func theSidOfTheRecordIsTheBindingEvenWhenItIsNotTheAttemptId() async throws {
        // The publisher sets sid = attempt id; the contract's records (and any other caller) use their own sid. The first live run of
        // round 2 timed out on every save because the match compared the attempt id.
        let rig = GatewayRig()
        rig.script = { engine, rig in
            engine.onSend = { engine, _ in
                await handOut(engine, rig)
                await rig.gateway.processSent(saved: [try fixtureRecord(sid: "the-records-own-sid")], failed: [], epoch: engine.epoch)
                engine.clearPending()
            }
        }
        _ = try await rig.gateway.prepare()
        let save = CloudSave(attemptId: "attempt-x", accountGeneration: 1, record: CloudKitGatewayContract.entity("arch", sid: "the-records-own-sid"))
        try await rig.gateway.submit([save])
        if case .saved? = rig.outcome("attempt-x") {} else { Issue.record("expected saved, got \(String(describing: rig.outcome("attempt-x")))") }
    }

    @Test func aLostResponseOfARecordWithoutASidRetiresTheEngine() async throws {
        // BlobPart and KeyBundle records carry no attempt id, so a late answer cannot be told apart by content: the engine that lost a
        // response is never used for that record again.
        let rig = GatewayRig()
        let seen = Observations()
        let part = try LiveFixtures.part("c")
        let partID = CKRecord.ID(recordName: part.name, zoneID: CloudZones(configuration: LiveGatewayFixture.configuration).blob)
        rig.script = { engine, rig in
            if engine.epoch == 1 {
                engine.onSend = { engine, _ in await handOut(engine, rig); engine.clearPending() }          // the response is lost
            } else {
                engine.onSend = { engine, _ in
                    await handOut(engine, rig)
                    await rig.gateway.processSent(saved: [], failed: [(CKRecord(recordType: "BlobPart", recordID: partID), ckError(.quotaExceeded))], epoch: 1)
                    seen["secondDuringStale"] = "\(rig.outcome("part-2") != nil)"
                    engine.clearPending()
                }
            }
        }
        _ = try await rig.gateway.prepare()
        try await rig.gateway.submit([CloudSave(attemptId: "part-1", accountGeneration: 1, record: part)])
        try await rig.gateway.submit([CloudSave(attemptId: "part-2", accountGeneration: 1, record: part)])
        #expect(rig.engines.count >= 2, "the second save of the record went to the engine that had lost the first response")
        #expect(seen["secondDuringStale"] == "false", "the old engine's answer completed the newer attempt")
        #expect(rig.outcome("part-1") == .quotaExceeded, "the late answer is still recorded for its own attempt")
    }

    // MARK: fix round 2: state of an incomplete fetch

    @Test func aStateUpdateFollowedByAZoneErrorPersistsNothingAndTheRebuildStartsFromTheOldState() async throws {
        let rig = GatewayRig(engineState: Data("S0".utf8), zoneCreated: false)
        let counter = Observations()
        rig.script = { engine, rig in
            engine.onFetch = { engine in
                if counter["failed"] == nil {
                    counter["failed"] = "yes"
                    await rig.gateway.processFetched(modifications: [], deletions: [], epoch: engine.epoch)
                    await rig.gateway.processState(Data("S1".utf8), epoch: engine.epoch)
                    await rig.gateway.processZoneFetched(error: ckError(.networkFailure), epoch: engine.epoch)
                } else {
                    await rig.gateway.processState(Data("S2".utf8), epoch: engine.epoch)
                }
            }
        }
        let sink = FlakySink()
        await #expect(throws: CloudSyncError.offline) { try await rig.gateway.fetchChanges(into: sink) }
        #expect(sink.inner.lastState == nil, "state of an incomplete fetch was saved")
        try await rig.gateway.fetchChanges(into: sink)
        #expect(rig.engines.count == 2)
        #expect(rig.engines.last?.state == Data("S0".utf8), "the rebuilt engine started from the advanced state of the failed fetch")
        #expect(sink.inner.lastState == Data("S2".utf8))
    }

    @Test func theStateIsSavedOnlyAfterTheCommitsItFollows() async throws {
        let rig = GatewayRig(engineState: Data("S0".utf8), zoneCreated: false)
        rig.script = { engine, rig in
            engine.onFetch = { engine in
                await rig.gateway.processFetched(modifications: [], deletions: ["e.note.gone"], epoch: engine.epoch)
                await rig.gateway.processState(Data("S1".utf8), epoch: engine.epoch)
            }
        }
        let sink = FlakySink()
        try await rig.gateway.fetchChanges(into: sink)
        #expect(sink.inner.log == ["commit", "state"])
        #expect(sink.inner.lastState == Data("S1".utf8))
    }

    // MARK: C2 incomplete fetch

    private func fetchWithZoneError(_ error: CKError, state: Data? = nil) async throws -> (rig: GatewayRig, sink: FlakySink, thrown: Error?) {
        let rig = GatewayRig(engineState: state, zoneCreated: false)
        rig.script = { engine, rig in
            engine.onFetch = { engine in
                await rig.gateway.processFetched(modifications: [], deletions: [], epoch: engine.epoch)
                await rig.gateway.processState(Data("S-after-error".utf8), epoch: engine.epoch)
                await rig.gateway.processZoneFetched(error: error, epoch: engine.epoch)
            }
        }
        let sink = FlakySink()
        do { try await rig.gateway.fetchChanges(into: sink); return (rig, sink, nil) } catch { return (rig, sink, error) }
    }

    @Test func aZoneErrorInAFullRefetchLeavesTheBracketOpenAndMarksNothing() async throws {
        for (error, expected) in [(ckError(.networkFailure), CloudSyncError.offline), (ckError(.notAuthenticated), .unauthenticated),
                                  (ckError(.serviceUnavailable), .offline)] {
            let (_, sink, thrown) = try await fetchWithZoneError(error)
            #expect(thrown as? CloudSyncError == expected, "\(error.code)")
            #expect(!sink.inner.log.contains("end"), "the bracket was ended on an incomplete fetch (\(error.code))")
            #expect(sink.inner.lastState == nil, "state advanced on an incomplete fetch (\(error.code))")
        }
    }

    @Test func aZoneErrorOfAnIncrementalFetchStillFails() async throws {
        let (_, sink, thrown) = try await fetchWithZoneError(ckError(.zoneBusy), state: Data("S0".utf8))
        #expect(thrown as? CloudSyncError == .offline)
        #expect(!sink.inner.log.contains("end"))
    }

    @Test func aRateLimitedZoneFetchHonoursTheRetryAfter() async throws {
        let (rig, _, thrown) = try await fetchWithZoneError(ckError(.requestRateLimited, [CKErrorRetryAfterKey: 3600.0]))
        #expect(thrown as? CloudSyncError == .offline)
        let hold = try #require(await rig.gateway.rateLimitHold())
        #expect(hold.timeIntervalSinceNow > 3000)
        let enginesBefore = rig.engines.map(\.fetchCount).reduce(0, +)
        let sink = FlakySink()
        await #expect(throws: CloudSyncError.offline) { try await rig.gateway.fetchChanges(into: sink) }
        #expect(rig.engines.map(\.fetchCount).reduce(0, +) == enginesBefore, "a fetch was made inside the retry-after window")
    }

    // MARK: I1 engine reuse after a failed final step

    private func completingScript(state: String) -> @Sendable (ScriptedEngine, GatewayRig) -> Void {
        { engine, rig in
            engine.onFetch = { engine in
                await rig.gateway.processState(Data(state.utf8), epoch: engine.epoch)
            }
        }
    }

    @Test func aFailedEndOfTheBracketDiscardsTheEngineAndTheRetrySucceeds() async throws {
        let rig = GatewayRig(zoneCreated: false)
        rig.script = completingScript(state: "S1")
        let sink = FlakySink()
        sink.failEnd(times: 1)
        await #expect(throws: SinkFailure.self) { try await rig.gateway.fetchChanges(into: sink) }
        #expect(sink.inner.lastState == nil)
        try await rig.gateway.fetchChanges(into: sink)
        #expect(rig.engines.count == 2, "the second fetch must use a new engine")
        #expect(rig.engines.last?.state == nil, "a new engine starts from the last durable state (none yet)")
        #expect(sink.inner.log.contains("end") && sink.inner.lastState == Data("S1".utf8))
    }

    @Test func aFailedFinalStateSaveDiscardsTheEngineAndTheRetrySucceeds() async throws {
        let rig = GatewayRig(zoneCreated: false)
        rig.script = completingScript(state: "S1")
        let sink = FlakySink()
        sink.failState(times: 1)
        await #expect(throws: SinkFailure.self) { try await rig.gateway.fetchChanges(into: sink) }
        try await rig.gateway.fetchChanges(into: sink)
        #expect(rig.engines.count == 2 && rig.engines.last?.state == nil)
        #expect(sink.inner.lastState == Data("S1".utf8))
    }

    @Test func aFailedStateSaveInAnIncrementalFetchRebuildsFromTheLastDurableState() async throws {
        let rig = GatewayRig(zoneCreated: false)
        let counter = Observations()
        rig.script = { engine, rig in
            engine.onFetch = { engine in
                let round = Int(counter["round"] ?? "0") ?? 0
                counter["round"] = "\(round + 1)"
                await rig.gateway.processState(Data("S\(round + 1)".utf8), epoch: engine.epoch)
            }
        }
        let sink = FlakySink()
        try await rig.gateway.fetchChanges(into: sink)                    // full: S1 is durable
        sink.failState(times: 1)
        await #expect(throws: SinkFailure.self) { try await rig.gateway.fetchChanges(into: sink) }       // S2 refused
        try await rig.gateway.fetchChanges(into: sink)
        // one engine served the first two fetches; the refused one was discarded, so the third fetch got a new one
        #expect(rig.engines.count == 2)
        #expect(rig.engines.last?.state == Data("S1".utf8), "the rebuilt engine must start from the last durable state, not from the refused one")
    }

    @Test func aThrowingEngineFetchDiscardsTheEngine() async throws {
        let rig = GatewayRig(zoneCreated: false)
        let counter = Observations()
        rig.script = { engine, rig in
            engine.onFetch = { engine in
                if counter["thrown"] == nil { counter["thrown"] = "yes"; throw ckError(.networkUnavailable) }
                await rig.gateway.processState(Data("S1".utf8), epoch: engine.epoch)
            }
        }
        let sink = FlakySink()
        await #expect(throws: CloudSyncError.offline) { try await rig.gateway.fetchChanges(into: sink) }
        try await rig.gateway.fetchChanges(into: sink)
        #expect(rig.engines.count == 2)
        #expect(sink.inner.lastState == Data("S1".utf8))
    }

    // MARK: I2 outcomes and the store

    @Test func aResultTheStoreRefusesStaysQueuedAndTheCallerIsTold() async throws {
        let store = RefusingStore()
        let rig = GatewayRig(store: store)
        let id = try LiveGatewayFixture.recordID
        rig.script = { engine, rig in
            engine.onSend = { engine, _ in
                await handOut(engine, rig)
                await rig.gateway.processSent(saved: [], failed: [(try failureRecord(id, sid: "a"), ckError(.quotaExceeded))], epoch: engine.epoch)
                engine.clearPending()
            }
        }
        _ = try await rig.gateway.prepare()
        store.refuse = true
        // the caller learns that the outcome is not durable, so it marks its rows unknown; the restart path resolves them
        await #expect(throws: CloudSyncError.failed(code: "outcomeNotStored")) { try await rig.gateway.submit([rig.save("a")]) }
        #expect(store.inner.outcome(for: "a") == nil)
        #expect(await rig.gateway.queuedSaveCount() == 1, "the entry was removed before its result was stored")
        // and nothing is lost while the process lives: the next time the store takes it
        store.refuse = false
        await rig.gateway.flushOutcomes()
        #expect(store.inner.outcome(for: "a") == .quotaExceeded)
        #expect(await rig.gateway.queuedSaveCount() == 0)
    }

    @Test func aResultTheFenceRefusesIsDroppedAndNeverBlocksTheQueue() async throws {
        let store = RefusingStore()
        let rig = GatewayRig(store: store)
        let id = try LiveGatewayFixture.recordID
        rig.script = { engine, rig in
            engine.onSend = { engine, _ in
                await handOut(engine, rig)
                await rig.gateway.processSent(saved: [], failed: [(try failureRecord(id, sid: "a"), ckError(.quotaExceeded))], epoch: engine.epoch)
                engine.clearPending()
            }
        }
        _ = try await rig.gateway.prepare()
        store.revoke = true                               // the library was stopped: the durable fence refuses result writes
        try await rig.gateway.submit([rig.save("a")])      // no "outcomeNotStored": the result is moot, not lost
        #expect(store.inner.outcome(for: "a") == nil)
        #expect(await rig.gateway.queuedSaveCount() == 0, "a revoked result leaves the queue instead of waiting for a store that will not take it")
        store.revoke = false
        await rig.gateway.flushOutcomes()
        #expect(store.inner.outcome(for: "a") == nil, "and it is not written later")
    }

    @Test func aRestartAfterARefusedResultLosesNoOutcome() async throws {
        let store = RefusingStore()
        let first = GatewayRig(store: store)
        let id = try LiveGatewayFixture.recordID
        first.script = { engine, rig in
            engine.onSend = { engine, _ in
                await handOut(engine, rig)
                await rig.gateway.processSent(saved: [], failed: [(try failureRecord(id, sid: "a"), ckError(.quotaExceeded))], epoch: engine.epoch)
                engine.clearPending()
            }
        }
        _ = try await first.gateway.prepare()
        store.refuse = true
        var told = false
        do { try await first.gateway.submit([first.save("a")]) } catch { told = (error as? CloudSyncError) == .failed(code: "outcomeNotStored") }
        #expect(told)
        // the process dies here; the library's row for "a" is still `sending` and becomes `unknown` at launch. A new gateway on the same
        // store must neither invent a result nor trip over the old attempt.
        store.refuse = false
        let second = GatewayRig(store: store)
        _ = try await second.gateway.prepare()
        #expect(store.inner.outcome(for: "a") == nil, "no outcome exists: the caller's unknown-resolution owns this attempt")
        #expect(await second.gateway.queuedSaveCount() == 0)
    }

    // MARK: I3 the subscription

    @Test func prepareEnsuresTheSubscriptionAndNeverFailsBecauseOfIt() async throws {
        let rig = GatewayRig()
        _ = try await rig.gateway.prepare()
        #expect(rig.subscriptionCalls == 1)
        rig.subscriptionFails = true
        let state = try await rig.gateway.prepare()
        guard case .available = state else { Issue.record("prepare must still succeed"); return }
        #expect(rig.subscriptionCalls == 2)
        #expect(await rig.gateway.subscriptionError != nil)
        rig.subscriptionFails = false
        _ = try await rig.gateway.prepare()
        #expect(await rig.gateway.subscriptionError == nil)
    }

    @Test func noSubscriptionIsTriedWithoutAnAccount() async throws {
        let rig = GatewayRig()
        rig.account = .noAccount
        _ = try await rig.gateway.prepare()
        #expect(rig.subscriptionCalls == 0)
    }
}
