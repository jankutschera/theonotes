// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// Holds one call of a gateway in the middle until the test lets it go. The held call ignores cancellation (like a real call
/// that is already on the wire). Single use: after `release` nothing is held any more.
final class Hold: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false, entered = false, released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func arm() { lock.lock(); armed = true; lock.unlock() }

    private func enter() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let hold = armed && !released
        if hold { entered = true }
        return hold
    }
    private func park(_ next: CheckedContinuation<Void, Never>) {
        lock.lock()
        if released { lock.unlock(); next.resume() } else { continuation = next; lock.unlock() }
    }
    private var hasEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered }

    func pass() async {
        guard enter() else { return }
        await withCheckedContinuation { (next: CheckedContinuation<Void, Never>) in park(next) }
    }

    func waitUntilEntered() async {
        while !hasEntered { try? await Task.sleep(nanoseconds: 2_000_000) }
    }

    func release() {
        lock.lock()
        released = true
        let next = continuation
        continuation = nil
        lock.unlock()
        next?.resume()
    }
}

/// A gateway in front of the fake device whose `prepare`/`fetch` (after the real work) and `submit` (before it) can be held.
final class SuspendingGateway: CloudKitGateway, @unchecked Sendable {
    let inner: FakeCloudKitDevice
    let holdPrepare = Hold(), holdFetch = Hold(), holdSubmit = Hold()
    init(_ inner: FakeCloudKitDevice) { self.inner = inner }

    var events: AsyncStream<CloudGatewayEvent> { inner.events }
    func prepare() async throws -> CloudAccountState { let state = try await inner.prepare(); await holdPrepare.pass(); return state }
    func accountState() async -> CloudAccountState { await inner.accountState() }
    func submit(_ saves: [CloudSave]) async throws { await holdSubmit.pass(); try await inner.submit(saves) }
    func fetchChanges(into sink: any CloudChangeSink) async throws { try await inner.fetchChanges(into: sink) }
    func fetch(_ names: [String], keys: [String]?) async throws -> [String: CloudRecord] {
        let result = try await inner.fetch(names, keys: keys)
        await holdFetch.pass()
        return result
    }
    func delete(_ names: [String]) async throws { try await inner.delete(names) }
    func deleteZone() async throws { try await inner.deleteZone() }
    func deleteZone(expecting userHash: String) async throws { try await inner.deleteZone(expecting: userHash) }
}

/// Races between an account switch and calls that are suspended in the middle and resume afterwards (Codex review of Task 9).
@Suite struct CloudGenerationFenceRaceTests {
    private let n1 = CloudEntityRef(entityType: "note", entityId: "n1")

    // MARK: C1: the account moves while a lift is in its prepare()

    @Test func aLiftWhoseAccountChangedDuringPrepareNeverOpensTheFence() async throws {
        let w = try await CloudPolicyWorld.make()
        try w.inflight("x", state: .sending)
        try await w.fence.accountChanged()
        let staleGeneration = try #require(try w.store.inflight(attemptId: "x")).accountGeneration

        w.gateway.holdPrepare.arm()
        let fence = w.fence, gateway = w.gateway
        let lift = Task { try await fence.resumeIfAllowed(using: gateway) }
        await w.gateway.holdPrepare.waitUntilEntered()
        await w.device.switchAccount(to: w.two)          // while the lift sits inside prepare()
        try await w.fence.accountChanged()               // the event arrives and runs the whole sequence
        w.gateway.holdPrepare.release()

        #expect(try await lift.value == .waitForAccount, "the lift gave up")
        #expect(await w.fence.isGated)
        #expect(try w.store.isAccountFenced())
        #expect(w.log.all.contains("lifted") == false)
        #expect(try w.store.inflight(attemptId: "x")?.accountGeneration == staleGeneration, "nothing was re-homed")
        #expect(await w.two.recordNames.isEmpty)
        #expect(try await w.fence.resumeIfAllowed(using: w.gateway) == .pause(.accountChanged))
    }

    @Test func aLiftNeverOpensTheFenceForAnAccountThatChangedBeforeItsEventArrived() async throws {
        let w = try await CloudPolicyWorld.make()
        try w.inflight("x", state: .sending)
        try await w.fence.accountChanged()
        let staleGeneration = try #require(try w.store.inflight(attemptId: "x")).accountGeneration

        w.gateway.holdPrepare.arm()
        let fence = w.fence, gateway = w.gateway
        let lift = Task { try await fence.resumeIfAllowed(using: gateway) }
        await w.gateway.holdPrepare.waitUntilEntered()
        await w.device.switchAccount(to: w.two)          // no event for the fence yet
        w.gateway.holdPrepare.release()

        #expect(try await lift.value == .waitForAccount, "the account re-check after prepare() caught it")
        #expect(await w.fence.isGated)
        #expect(try w.store.isAccountFenced())
        #expect(try w.store.inflight(attemptId: "x")?.accountGeneration == staleGeneration)
        try await w.fence.accountChanged()               // the late event
        #expect(try await w.fence.resumeIfAllowed(using: w.gateway) == .pause(.accountChanged))
    }

    @Test func aLiftThatOverlapsAnAccountRoundTripGivesUpEvenIfTheFirstAccountIsBack() async throws {
        let w = try await CloudPolicyWorld.make()
        try w.inflight("x", state: .sending)
        try await w.fence.accountChanged()
        w.gateway.holdPrepare.arm()
        let fence = w.fence, gateway = w.gateway
        let lift = Task { try await fence.resumeIfAllowed(using: gateway) }
        await w.gateway.holdPrepare.waitUntilEntered()
        await w.device.switchAccount(to: w.two)
        try await w.fence.accountChanged()
        await w.device.switchAccount(to: w.one)          // the same account is back when the held prepare() returns
        w.gateway.holdPrepare.release()

        #expect(try await lift.value == .waitForAccount, "a whole change happened inside the lift: its picture is outdated")
        #expect(await w.fence.isGated)
        #expect(try await w.fence.resumeIfAllowed(using: w.gateway) == .resume, "a fresh lift, started after the change, opens it")
        #expect(await w.fence.isGated == false)
    }

    @Test func liftAndRehomeIsOneStepThatChecksTheBindingAndTheGeneration() async throws {
        let w = try await CloudPolicyWorld.make()
        try w.inflight("x", state: .unknown)
        try await w.db.pool.write { try $0.execute(sql: "UPDATE ck_inflight SET generationOfAccount=generationOfAccount-1") }
        try w.store.setAccountFenced(true)
        let current = try w.store.generation()
        let before = try #require(try w.store.inflight(attemptId: "x")).accountGeneration

        #expect(try w.store.liftAndRehome(expectedGeneration: current, accountHash: "another-user") == false, "rows are re-homed only for the bound user")
        #expect(try w.store.liftAndRehome(expectedGeneration: current - 1, accountHash: w.one.userHash) == false, "and only in the expected generation")
        #expect(try w.store.inflight(attemptId: "x")?.accountGeneration == before)
        #expect(try w.store.isAccountFenced(), "a refused lift leaves the fence up")

        #expect(try w.store.liftAndRehome(expectedGeneration: current, accountHash: w.one.userHash))
        #expect(try w.store.inflight(attemptId: "x")?.accountGeneration == current)
        #expect(try w.store.isAccountFenced() == false)
    }

    // MARK: C2: a resolution fetch that finishes after the account moved

    @Test func aResolutionFetchThatFinishesAfterTheAccountMovedWritesNothing() async throws {
        let w = try await CloudPolicyWorld.make(drainTimeout: 0.05)
        try w.inflight("x", entity: "n1", state: .sending)
        try await w.device.submit([CloudSave(attemptId: "x", accountGeneration: try w.store.generation(), record: entity("n1", sid: "x"))])
        try await w.db.pool.write { try $0.execute(sql: "DELETE FROM ck_send_result") }
        try await w.fence.accountChanged()
        #expect(try await w.fence.resumeIfAllowed(using: w.gateway) == .resume)

        w.gateway.holdFetch.arm()
        let fence = w.fence, gateway = w.gateway
        let resolve = Task { try await fence.resolveUnknownOutcomes(using: gateway) }
        await w.gateway.holdFetch.waitUntilEntered()      // the fetch has the record of the first account in hand

        await w.device.switchAccount(to: w.two)
        try await w.fence.accountChanged()
        #expect(await w.fence.lastDrainTimedOut)
        await w.device.switchAccount(to: w.one)           // and the first account comes back and is re-homed
        #expect(try await w.fence.resumeIfAllowed(using: w.gateway) == .resume)
        let rehomed = try #require(try w.store.inflight(attemptId: "x")).accountGeneration
        #expect(rehomed == (try w.store.generation()))

        w.gateway.holdFetch.release()                     // the old fetch finishes only now
        await #expect(throws: CloudSyncError.fenced) { try await resolve.value }
        #expect(try w.store.pair(for: n1) == nil, "no write of the old session in the new generation")
        #expect(try w.store.inflight(attemptId: "x")?.state == .unknown)
    }

    @Test func aGuardedWriteChecksGenerationAndBindingInsideTheTransaction() async throws {
        let w = try await CloudPolicyWorld.make()
        try w.inflight("x", state: .unknown)
        let generation = try w.store.generation()
        let tag = Data("tag".utf8)
        #expect(throws: CloudSyncStoreError.staleAccountGeneration(expected: generation, actual: generation - 1)) {
            try w.store.recordSaved(attemptId: "x", newSystemFields: tag, guard: CloudWriteGuard(generation: generation - 1, accountHash: w.one.userHash))
        }
        #expect(throws: CloudSyncStoreError.accountMismatch) {
            try w.store.recordSaved(attemptId: "x", newSystemFields: tag, guard: CloudWriteGuard(generation: generation, accountHash: "another-user"))
        }
        #expect(try w.store.pair(for: n1) == nil)
        try w.store.recordSaved(attemptId: "x", newSystemFields: tag, guard: CloudWriteGuard(generation: generation, accountHash: w.one.userHash))
        #expect(try w.store.pair(for: n1)?.systemFields == tag)
    }

    // MARK: I1: the window between setting the fence and bumping the generation

    @Test func storeWritesAreRefusedFromTheMomentTheFenceIsSetEvenWhileTheGenerationStillMatches() async throws {
        let w = try await CloudPolicyWorld.make()
        try w.inflight("w1", state: .sending)
        try w.inflight("w3", entity: "n3", state: .prepared)
        let generation = try w.store.generation()
        let hold = Hold()
        hold.arm()
        let fence = w.fence
        let straggler = Task { try await fence.run { _ in await hold.pass() } }
        await hold.waitUntilEntered()

        let change = Task { try await fence.accountChanged() }          // stuck in the drain until the straggler ends
        while !w.log.all.contains("sendsGated") { try await Task.sleep(nanoseconds: 2_000_000) }

        #expect(w.fence.isCurrent(generation), "the generation alone cannot tell yet")
        #expect(try w.store.generation() == generation)
        #expect(throws: CloudSyncStoreError.accountFenced) { try w.store.recordSaved(attemptId: "w1", newSystemFields: Data([1])) }
        #expect(throws: CloudSyncStoreError.accountFenced) { try w.store.saveEngineState(Data([1]), accountGeneration: generation) }
        #expect(throws: CloudSyncStoreError.accountFenced) { try w.store.markInflight(attemptId: "w1", state: .sending) }
        #expect(throws: CloudSyncStoreError.accountFenced) { try w.store.beginSending(attemptId: "w3") }
        #expect(throws: CloudSyncStoreError.accountFenced) {
            try w.store.insertInflight(CloudInflight(entity: CloudEntityRef(entityType: "note", entityId: "n2"), localId: "n2", generation: 1,
                                                     attemptId: "w2", inc: "i", sealed: Data([1]), accountGeneration: generation))
        }
        #expect(throws: CloudSyncStoreError.accountFenced) {
            try w.store.recordApplied(accountGeneration: generation, remote: CloudRemoteVersion(entity: n1, inc: "i", ver: 1, sid: "s", systemFields: Data([1])),
                                      ancestor: Data([1]))
        }
        #expect(try w.store.pair(for: n1) == nil)

        hold.release()
        _ = try await change.value
        _ = try await straggler.value
        #expect(w.log.all.last == "generationBumped")
    }

    // MARK: I2: the drain is bounded

    @Test func aCallThatIgnoresCancellationCannotHoldAnAccountSwitchHostage() async throws {
        let w = try await CloudPolicyWorld.make(drainTimeout: 0.05)
        try w.inflight("x", state: .sending)
        let generation = try w.store.generation()
        let hold = Hold()
        hold.arm()
        let fence = w.fence, store = w.store
        let lateWrite = OrderLog()
        let straggler = Task {
            try await fence.run { started in
                await hold.pass()                  // never cooperates
                do { try store.recordSaved(attemptId: "x", newSystemFields: Data([9])); lateWrite.add("written") }
                catch { lateWrite.add("refused:\(started == generation)") }
            }
        }
        await hold.waitUntilEntered()

        await w.device.switchAccount(to: w.two)
        let beforeChange = try w.store.generation()
        let bumped = try await w.fence.accountChanged()      // returns although the call is still stuck
        #expect(bumped == beforeChange + 1, "the generation moved on although the drain gave up")

        #expect(await w.fence.lastDrainTimedOut)
        #expect(w.log.all == ["sendsGated", "drainTimedOut", "inflightMarkedUnknown", "engineStateCleared", "generationBumped"])
        #expect(bumped != generation && w.fence.isCurrent(generation) == false)
        #expect(await w.fence.isGated)
        #expect(try w.store.isAccountFenced(), "the fence stays closed")
        await #expect(throws: CloudSyncError.fenced) { try await w.fence.run { _ in 1 } }
        #expect(try await w.fence.resumeIfAllowed(using: w.gateway) == .pause(.accountChanged), "the switch ends in a paused state")

        hold.release()                                      // the stuck call wakes up long after
        try await straggler.value
        #expect(lateWrite.all == ["refused:true"], "its write is refused: \(lateWrite.all)")
        #expect(try w.store.pair(for: n1) == nil)
        #expect(await w.two.recordNames.isEmpty)
    }

    // MARK: round 2: overlapping changes, receiver writes, unbounded cancel

    @Test func overlappingAccountChangesKeepTheFenceClosedUntilBothAreDone() async throws {
        let w = try await CloudPolicyWorld.make()
        let slowCancel = Hold()
        slowCancel.arm()
        let calls = OrderLog()
        // the first change's gateway cancel is slow, the second one's is immediate
        let fence = CloudGenerationFence(store: w.store, cancelOperations: {
            calls.add("cancel")
            if calls.all.count == 1 { await slowCancel.pass() }
        })
        let before = try w.store.generation()
        let first = Task { try await fence.accountChanged() }
        await slowCancel.waitUntilEntered()

        try await fence.accountChanged()                  // the second change runs to its end while the first is still going
        #expect(try w.store.generation() == before + 1)
        #expect(try await fence.resumeIfAllowed(using: w.gateway) == .waitForAccount, "a lift in between must not open the fence")
        #expect(await fence.isGated)
        #expect(try w.store.isAccountFenced())

        slowCancel.release()
        _ = try await first.value
        #expect(try w.store.generation() == before + 2, "changes are counted, not coalesced: each one bumps the generation")
        #expect(try await fence.resumeIfAllowed(using: w.gateway) == .resume, "after both are done the lift opens it")
        #expect(await fence.isGated == false)
    }

    private func remoteVersion(_ ver: Int64 = 1) -> CloudRemoteVersion {
        CloudRemoteVersion(entity: n1, inc: "inc-1", ver: ver, sid: "sid-\(ver)", systemFields: Data("tag".utf8), sealed: Data("sealed".utf8))
    }

    @Test func receiverWritesAreRefusedWhileTheFenceIsUpAndForAnOldGeneration() async throws {
        let w = try await CloudPolicyWorld.make()
        let old = try w.store.generation()
        try await w.db.pool.write {
            try $0.execute(sql: "INSERT INTO ck_record(entityType,entityId,systemFields,ancestor,ver,inc) VALUES('note','n1',x'01',x'02',1,'inc-1')")
        }
        let quarantined = CloudQuarantineRecord(recordName: "e.note.q9", reason: "invalid-value:cipher", rawFields: Data("r".utf8))

        try w.store.setAccountFenced(true)                // the window before the bump: generation still equal
        #expect(throws: CloudSyncStoreError.accountFenced) { try w.store.storeRemote(remoteVersion(2), accountGeneration: old) }
        #expect(throws: CloudSyncStoreError.accountFenced) { try w.store.storeRemote(remoteVersion(2)) }
        #expect(throws: CloudSyncStoreError.accountFenced) { try w.store.quarantine(record: quarantined, pinned: [], accountGeneration: old) }
        #expect(throws: CloudSyncStoreError.accountFenced) { try w.store.markMissing(entityType: "note", entityId: "n1", reason: "x", accountGeneration: old) }
        try w.store.setAccountFenced(false)

        try await w.fence.accountChanged()
        #expect(try await w.fence.resumeIfAllowed(using: w.gateway) == .resume)
        let now = try w.store.generation()
        #expect(throws: CloudSyncStoreError.staleAccountGeneration(expected: now, actual: old)) { try w.store.storeRemote(remoteVersion(2), accountGeneration: old) }
        #expect(throws: CloudSyncStoreError.staleAccountGeneration(expected: now, actual: old)) { try w.store.quarantine(record: quarantined, pinned: [], accountGeneration: old) }
        #expect(throws: CloudSyncStoreError.staleAccountGeneration(expected: now, actual: old)) { try w.store.markMissing(entityType: "note", entityId: "n1", reason: "x", accountGeneration: old) }
        #expect(try w.store.allRemote().isEmpty && w.store.quarantineRows().isEmpty && w.store.allMissing().isEmpty)

        #expect(try w.store.storeRemote(remoteVersion(2), accountGeneration: now) == .stored, "the current generation still stores")
    }

    /// A receiver sink that stores what the fetch delivers under the generation it started in.
    private final class StoringSink: CloudChangeSink, @unchecked Sendable {
        let store: CloudSyncStore, generation: Int64
        init(_ store: CloudSyncStore, generation: Int64) { self.store = store; self.generation = generation }
        func commit(changed: [CloudRecord], deletedNames: [String]) throws {
            for record in changed {
                guard case .entity(let header) = try CloudRecordCodec.decode(record), case .inline(let sealed) = header.payload else { continue }
                try store.storeRemote(CloudRemoteVersion(entity: CloudEntityRef(entityType: header.entityType.rawValue, entityId: header.entityId),
                                                         inc: header.inc, ver: header.ver, sid: header.sid, systemFields: record.systemFields ?? Data(), sealed: sealed),
                                      accountGeneration: generation)
            }
        }
        func saveEngineState(_ state: Data) throws { try store.saveEngineState(state, accountGeneration: generation) }
        func beginFullRefetch() throws {}
        func endFullRefetch() throws {}
    }

    @Test func aLateFetchDeliveryAfterAnAccountChangeStoresNothing() async throws {
        let w = try await CloudPolicyWorld.make()
        let other = FakeCloudKitDevice(account: w.one, store: InMemoryCloudGatewayStore())
        _ = try await other.prepare()
        try await other.submit([CloudSave(attemptId: "o1", accountGeneration: 1, record: entity("from-other"))])

        let sink = StoringSink(w.store, generation: try w.store.generation())      // the fetch started in this generation
        try await w.fence.accountChanged()
        #expect(try await w.fence.resumeIfAllowed(using: w.gateway) == .resume)     // and the account is back when it delivers

        await #expect(throws: CloudSyncStoreError.self) { try await w.device.fetchChanges(into: sink) }
        #expect(try w.store.allRemote().isEmpty, "nothing of the old session was stored")
        #expect(try w.store.engineState() == nil)

        let fresh = StoringSink(w.store, generation: try w.store.generation())
        try await w.device.fetchChanges(into: fresh)
        #expect(try w.store.allRemote().map(\.recordName) == ["e.note.from-other"])
    }

    @Test func aGatewayCancelThatNeverReturnsCannotHoldTheSwitchHostage() async throws {
        let w = try await CloudPolicyWorld.make()
        let stuckCancel = Hold(), stuckOperation = Hold()
        stuckCancel.arm(); stuckOperation.arm()
        let fence = CloudGenerationFence(store: w.store, drainTimeout: 0.1, cancelOperations: { await stuckCancel.pass() },
                                         trace: { w.log.add($0.rawValue) })
        let straggler = Task { try await fence.run { _ in await stuckOperation.pass() } }
        await stuckOperation.waitUntilEntered()
        let before = try w.store.generation()

        let bumped = try await fence.accountChanged()     // both the cancel and the operation are stuck: it still returns
        #expect(bumped == before + 1)
        #expect(await fence.lastDrainTimedOut)
        #expect(w.log.all == ["sendsGated", "drainTimedOut", "inflightMarkedUnknown", "engineStateCleared", "generationBumped"])
        #expect(await fence.isGated)
        #expect(try w.store.isAccountFenced())
        stuckCancel.release(); stuckOperation.release()
        try await straggler.value
    }

    @Test func aSlowButFinishingCancelDoesNotCountAsATimeout() async throws {
        let w = try await CloudPolicyWorld.make()
        let fence = CloudGenerationFence(store: w.store, drainTimeout: 5, cancelOperations: { try? await Task.sleep(nanoseconds: 20_000_000) })
        try await fence.accountChanged()
        #expect(await fence.lastDrainTimedOut == false)
    }

    // MARK: cancelRunning

    @Test func cancelRunningStopsATrackedOperationAndTheGatewayAndAlwaysLeavesTheFenceClosed() async throws {
        let w = try await CloudPolicyWorld.make()
        let cancelled = Flag()
        let fence = CloudGenerationFence(store: w.store, drainTimeout: 5, cancelOperations: { cancelled.raise() })
        let before = try w.store.generation()
        let started = Hold()
        started.arm()
        // An upload that only ends when it is cancelled (as a real `sendChanges` does after `cancelOperations`).
        let upload = Task { try await fence.run { _ in
            await started.pass()
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000) }
            throw CancellationError()
        } }
        await started.waitUntilEntered()
        started.release()
        // Not measured by the clock: in a parallel run, resuming on the shared pool alone can take seconds. A drain that
        // completed (with a 5 s limit) is the proof that it returned because the operation ended.
        let clean = await fence.cancelRunning()
        #expect(clean, "returns as soon as the operation has ended")
        #expect(await fence.lastDrainTimedOut == false)
        #expect(cancelled.isRaised, "the gateway's own cancellation ran")
        await #expect(throws: CancellationError.self) { try await upload.value }
        // A stop ALWAYS leaves the fence closed and the generation bumped, whatever the drain outcome.
        #expect(try w.store.generation() == before + 1)
        #expect(await fence.isGated)
        #expect(try w.store.isAccountFenced())
        await #expect(throws: CloudSyncError.fenced) { try await fence.run { _ in 7 } }
    }

    @Test func aCancelledFetchThatReturnsNormallyWithinTheDeadlineCannotApplyOrPublishAnything() async throws {
        let w = try await CloudPolicyWorld.make()
        try w.inflight("x", state: .sending)
        let fence = w.fence, store = w.store
        let started = Hold(), proceed = Hold()
        started.arm(); proceed.arm()
        let after = OrderLog()
        // The enclosing cycle: a fetch that, once cancelled, ENDS NORMALLY (no throw), and then the cycle goes on to apply and publish.
        let cycle = Task { () -> Void in
            let generation: Int64 = try await fence.run { started_ in
                await started.pass()
                while !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000) }
                return started_                            // returns normally although it was cancelled
            }
            await proceed.pass()                           // the cycle only goes on once the stop has returned
            do { try store.recordSaved(attemptId: "x", newSystemFields: Data([9])); after.add("applied") } catch { after.add("apply refused") }
            do { try store.saveEngineState(Data([1]), accountGeneration: generation); after.add("state saved") } catch { after.add("state refused") }
            do { _ = try await fence.run { _ in 1 }; after.add("next call ran") } catch { after.add("next call refused") }
        }
        await started.waitUntilEntered()
        started.release()
        await fence.cancelRunning()
        proceed.release()
        try await cycle.value
        #expect(after.all == ["apply refused", "state refused", "next call refused"], "\(after.all)")
        #expect(try w.store.pair(for: n1) == nil)
        #expect(try w.store.engineState() == nil)
    }

    @Test func aLateSendResultAfterStopWritesNothing() async throws {
        let w = try await CloudPolicyWorld.make(drainTimeout: 0.05)
        let generation = try w.store.generation()
        let hold = Hold()
        hold.arm()
        let fence = w.fence, store = w.store
        let late = OrderLog()
        let straggler = Task {
            try await fence.run { _ in
                await hold.pass()                  // a send that ignores cancellation; its answer arrives after the stop
                do { try store.recordSendResult(attemptId: "late", accountGeneration: generation, outcome: .offline); late.add("recorded") }
                catch { late.add("refused") }
            }
        }
        await hold.waitUntilEntered()
        await w.fence.cancelRunning()
        hold.release()
        try await straggler.value
        #expect(late.all == ["refused"], "\(late.all)")
        #expect(try w.store.sendResult(attemptId: "late") == nil)
    }

    @Test func recordSendResultChecksTheFenceAndTheGenerationLikeRecordSaved() throws {
        let store = CloudSyncStore(database: try AppDatabase.inMemory())
        let current = try store.generation()
        // the current generation: recorded (the late-result path of Task 14 keeps working)
        try store.recordSendResult(attemptId: "now", accountGeneration: current, outcome: .offline)
        #expect(try store.sendResult(attemptId: "now")?.outcome == .offline)
        // an older generation is refused
        try store.bumpGeneration()
        #expect(throws: CloudSyncStoreError.staleAccountGeneration(expected: current + 1, actual: current)) {
            try store.recordSendResult(attemptId: "old", accountGeneration: current, outcome: .offline)
        }
        #expect(try store.sendResult(attemptId: "old") == nil)
        // while the durable fence is up, even the current generation is refused
        try store.setAccountFenced(true)
        #expect(throws: CloudSyncStoreError.accountFenced) {
            try store.recordSendResult(attemptId: "fenced", accountGeneration: current + 1, outcome: .offline)
        }
        #expect(try store.sendResult(attemptId: "fenced") == nil)
        try store.setAccountFenced(false)
        try store.recordSendResult(attemptId: "after", accountGeneration: current + 1, outcome: .offline)
        #expect(try store.sendResult(attemptId: "after")?.outcome == .offline)
    }

    @Test(.timeLimit(.minutes(1))) func cancelRunningIsBoundedWhenAnOperationIgnoresCancellation() async throws {
        let w = try await CloudPolicyWorld.make()
        let stuck = Hold()
        stuck.arm()
        let fence = CloudGenerationFence(store: w.store, drainTimeout: 0.2)
        let finished = Flag()
        let straggler = Task { try await fence.run { _ in await stuck.pass() }; finished.raise() }
        await stuck.waitUntilEntered()
        // Not measured by the clock (see above): the straggler can only finish after `release()` below, so
        // `cancelRunning()` returning at all, with the drain marked as timed out, proves the stuck call did not hold it.
        let clean = await fence.cancelRunning()
        #expect(!clean && !finished.isRaised, "a stuck call cannot hold the caller past the drain time")
        #expect(await fence.lastDrainTimedOut)
        stuck.release()
        try await straggler.value
        #expect(finished.isRaised)
    }

    // MARK: fix round 1 (Codex review of Task 15b): cancelling closes the fence, one deadline, concurrent account change

    @Test func stoppingWithAnUncooperativeSendClosesTheFenceAndItsLateWriteIsRefused() async throws {
        let w = try await CloudPolicyWorld.make(drainTimeout: 0.05)
        try w.inflight("x", state: .sending)
        let generation = try w.store.generation()
        let hold = Hold()
        hold.arm()
        let fence = w.fence, store = w.store
        let lateWrite = OrderLog()
        let straggler = Task {
            try await fence.run { _ in
                await hold.pass()                  // ignores cancellation, like a send already on the wire
                do { try store.recordSaved(attemptId: "x", newSystemFields: Data([9])); lateWrite.add("written") }
                catch { lateWrite.add("refused") }
            }
        }
        await hold.waitUntilEntered()

        await w.fence.cancelRunning()              // Stop syncing / app quit

        #expect(await w.fence.lastDrainTimedOut)
        #expect(await w.fence.isGated, "no new work may start")
        #expect(try w.store.isAccountFenced(), "the durable fence refuses the stuck call's writes")
        #expect(try w.store.generation() == generation + 1, "and so does the generation")
        #expect(try w.store.inflight(attemptId: "x")?.state == .unknown)
        await #expect(throws: CloudSyncError.fenced) { try await w.fence.run { _ in 1 } }

        hold.release()                             // the send's answer arrives after the stop
        try await straggler.value
        #expect(lateWrite.all == ["refused"], "its write is refused: \(lateWrite.all)")
        #expect(try w.store.pair(for: n1) == nil)

        // Switching on again lifts the fence the normal way.
        #expect(try await w.fence.resumeIfAllowed(using: w.gateway) == .resume)
        #expect(await w.fence.isGated == false)
        #expect(try w.store.isAccountFenced() == false)
    }

    @Test func stoppingWhileAnAccountChangeRunsNeverOpensTheFenceBehindIt() async throws {
        let w = try await CloudPolicyWorld.make(drainTimeout: 5)
        // A gateway cancel that takes a moment, so the two sequences overlap.
        let fence = CloudGenerationFence(store: w.store, drainTimeout: 5, cancelOperations: { try? await Task.sleep(nanoseconds: 300_000_000) })
        let stop = Task { await fence.cancelRunning() }
        try await Task.sleep(nanoseconds: 50_000_000)
        let change = Task { try await fence.accountChanged() }
        await stop.value
        _ = try await change.value
        #expect(await fence.isGated, "the account change's fence stays closed")
        #expect(try w.store.isAccountFenced())
        await #expect(throws: CloudSyncError.fenced) { try await fence.run { _ in 1 } }
        #expect(try await fence.resumeIfAllowed(using: w.gateway) == .resume, "and it lifts the normal way")
        #expect(await fence.isGated == false)
    }

    @Test func cancelRunningGivesUpOnAStuckCancelAndDrain() async throws {
        let w = try await CloudPolicyWorld.make()
        let stuckCancel = Hold(), stuckOperation = Hold()
        stuckCancel.arm(); stuckOperation.arm()
        let fence = CloudGenerationFence(store: w.store, drainTimeout: 1.0, cancelOperations: { await stuckCancel.pass() })
        let straggler = Task { try await fence.run { _ in await stuckOperation.pass() } }
        await stuckOperation.waitUntilEntered()
        await fence.cancelRunning()
        #expect(await fence.lastDrainTimedOut)
        stuckCancel.release(); stuckOperation.release()
        try await straggler.value
    }

    /// Wall-clock bound, so it runs only in the serial perf pass (R29); under a loaded parallel run the clock is not the fence's.
    @Test(.tags(.perf), .enabled(if: ProcessInfo.processInfo.environment["BAERCHEN_PERF"] == "1"))
    func testPerfCancelRunningUsesOneDeadlineForTheGatewayCancelAndTheDrain() async throws {
        let w = try await CloudPolicyWorld.make()
        let stuckCancel = Hold(), stuckOperation = Hold()
        stuckCancel.arm(); stuckOperation.arm()
        let fence = CloudGenerationFence(store: w.store, drainTimeout: 1.0, cancelOperations: { await stuckCancel.pass() })
        let straggler = Task { try await fence.run { _ in await stuckOperation.pass() } }
        await stuckOperation.waitUntilEntered()
        let begun = Date()
        await fence.cancelRunning()
        let took = Date().timeIntervalSince(begun)
        #expect(took < 1.7, "cancel and drain share one deadline of 1.0 s (two would be 2.0 s), took \(took)")
        #expect(await fence.lastDrainTimedOut)
        stuckCancel.release(); stuckOperation.release()
        try await straggler.value
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func raise() { lock.lock(); raised = true; lock.unlock() }
    var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return raised }
}
