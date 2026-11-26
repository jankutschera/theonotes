// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

/// What the unknown-outcome resolution found for one in-flight save whose result never arrived.
public enum CloudUnknownResolution: Sendable, Equatable {
    /// The server's current version is our attempt: the pair was recorded (`CloudSyncStore.recordSaved`).
    case landed
    /// Not our version on the server: nothing was written; the publisher's own table decides.
    case notLanded
}

/// What a guarded store write re-checks inside its own transaction: the generation the operation started in and the
/// iCloud user the library is bound to.
public struct CloudWriteGuard: Sendable, Equatable {
    public var generation: Int64
    public var accountHash: String
    public init(generation: Int64, accountHash: String) { self.generation = generation; self.accountHash = accountHash }
}

/// The generation fence, at the coordinator level. It works through `CloudSyncStore` and `CloudKitGateway` only.
///
/// `ck_state.generation` changes on every account change, bind, detach and zone-state change. Everything that can finish later
/// (a send, a fetch, a late result) carries the generation it started in; `isCurrent` / `requireCurrent` / the store's own
/// checks discard what is older. The durable fence (`ck_state.fenced`) additionally refuses every generation-checked store write
/// from the moment it is set, also while the old generation still matches. The sequence on an account change
/// (`accountChanged()`):
/// 1. gate: no new operation may start (`run` throws `.fenced`), and `ck_state.fenced` is written, so a restart stays fenced;
/// 2. cancel and await the operations started through `run` (and the gateway's own `cancelOperations`, when given), for at most
/// `drainTimeout`;
/// 3. in-flight rows that were being sent become `unknown` (the send may have landed in the old account);
/// 4. the saved engine state is cleared;
/// 5. the generation is bumped; everything older is stale from here on;
/// 6. nothing starts again until `lift` (after `CloudAccountPolicy` said `.resume`).
///
/// Publisher (Task 5) and receiver (Task 6) use: `run { generation in ... }` around every gateway call so a switch can wait for
/// it; `isCurrent(generation)` on every result and callback before acting; `resumeIfAllowed(using:)` when the account changes
/// or the app launches; `resolveUnknownOutcomes(using:)` after the original account returns.
public actor CloudGenerationFence {
    public enum Step: String, Sendable, Equatable {
        case sendsGated, operationsDrained, drainTimedOut, inflightMarkedUnknown, engineStateCleared, generationBumped, lifted
    }

    private struct Operation {
        let cancel: @Sendable () -> Void
        let finished: Task<Void, Never>
    }

    private let store: CloudSyncStore
    private let drainTimeout: TimeInterval
    private let cancelOperations: @Sendable () async -> Void
    private let trace: @Sendable (Step) -> Void
    private var gated: Bool
    private var operations: [UUID: Operation] = [:]
    /// Counts started account changes; `activeChanges` counts the ones still running, so overlapping changes are all
    /// accounted for. A lift or a resolution that notices a different count, or any active change, gives up.
    private var changeCount = 0
    private var activeChanges = 0
    private var changing: Bool { activeChanges > 0 }
    public private(set) var lastDrainTimedOut = false

    /// `drainTimeout` bounds step 2 of the sequence: an operation that ignores cancellation cannot hold an account
    /// switch hostage; the switch goes on, the fence stays closed and the old generation loses its write rights.
    /// `cancelOperations` is the gateway's own cancellation (`CKSyncEngine.cancelOperations()` in the live gateway; it may
    /// return before the operations end, which is why the generation check exists at all). `trace` reports each step of
    /// the sequence, for tests.
    public init(store: CloudSyncStore, drainTimeout: TimeInterval = 10, cancelOperations: @escaping @Sendable () async -> Void = {},
                trace: @escaping @Sendable (Step) -> Void = { _ in }) {
        self.store = store; self.drainTimeout = drainTimeout; self.cancelOperations = cancelOperations; self.trace = trace
        gated = (try? store.isAccountFenced()) ?? false
    }

    /// True while no operation may start.
    public var isGated: Bool { gated }

    // MARK: generation checks

    public func generation() throws -> Int64 { try store.generation() }

    /// True when `generation` is the one in force now. A result, state save or callback from any other generation is discarded.
    /// (The store additionally refuses writes while the durable fence is up, which this check alone does not see.)
    public nonisolated func isCurrent(_ generation: Int64) -> Bool { (try? store.generation()) == generation }

    public nonisolated func requireCurrent(_ generation: Int64) throws {
        let current = try store.generation()
        guard current == generation else { throw CloudSyncStoreError.staleAccountGeneration(expected: current, actual: generation) }
    }

    /// Runs `body` as a tracked operation with the generation it starts in. Throws `.fenced` while gated. A switch cancels the
    /// task and waits for it (bounded); the body should honour cancellation and must not act on its result without `isCurrent`.
    public func run<T: Sendable>(_ body: @escaping @Sendable (Int64) async throws -> T) async throws -> T {
        guard !gated else { throw CloudSyncError.fenced }
        let generation = try store.generation()
        let task = Task { try await body(generation) }
        let id = UUID()
        operations[id] = Operation(cancel: { task.cancel() }, finished: Task { _ = await task.result })
        defer { operations[id] = nil }
        return try await task.value
    }

    /// Stops what is running for "Stop syncing" and the app quit. It is the account-change
    /// sequence for an account that did not change, and it ALWAYS ends with the fence closed:
    /// 1. new work is gated and the durable fence is closed BEFORE anything is cancelled, so nothing starts and no write of a
    /// cancelled call can land;
    /// 2. the gateway's cancellation and every tracked operation are cancelled and awaited under ONE deadline (`drainTimeout`);
    /// 3. whatever the outcome (a cancelled fetch may well return normally and let its enclosing cycle go on to apply or publish), the
    /// in-flight rows become `unknown`, the engine state is cleared and the generation is bumped, so every later write
    ///    of the stopped session, a send result included, is refused.
    /// The fence is not reopened here: the next switch-on lifts it the normal way (`resumeIfAllowed`), at the price of one
    /// refetch. Returns whether everything ended within the deadline.
    @discardableResult
    public func cancelRunning() async -> Bool {
        changeCount += 1
        activeChanges += 1
        defer { activeChanges -= 1 }
        gated = true
        try? store.setAccountFenced(true)
        trace(.sendsGated)

        let deadline = Date().addingTimeInterval(drainTimeout)
        let cancel = cancelOperations
        let running = Array(operations.values)
        for operation in running { operation.cancel() }
        let cancelled = await Self.bounded(timeout: drainTimeout) { await cancel() }
        let tasks = running.map(\.finished)
        let drained = tasks.isEmpty ? true
            : await Self.bounded(timeout: max(0, deadline.timeIntervalSinceNow)) { for task in tasks { await task.value } }
        let clean = cancelled && drained
        lastDrainTimedOut = !clean
        trace(clean ? .operationsDrained : .drainTimedOut)

        try? store.markSendingInflightUnknown()
        trace(.inflightMarkedUnknown)
        try? store.clearEngineState()
        trace(.engineStateCleared)
        try? store.bumpGeneration()
        trace(.generationBumped)
        return clean
    }

    // MARK: the sequence

    /// Handles an account change (the gateway's `.accountChanged` event, or a launch that finds the account different).
    /// Returns the new generation. Safe to call again; each call bumps once more.
    @discardableResult
    public func accountChanged() async throws -> Int64 {
        activeChanges += 1
        changeCount += 1
        defer { activeChanges -= 1 }
        gated = true
        try store.setAccountFenced(true)
        trace(.sendsGated)

        // one deadline for the gateway's cancel and the drain together
        let deadline = Date().addingTimeInterval(drainTimeout)
        let cancel = cancelOperations
        let cancelled = await Self.bounded(timeout: drainTimeout) { await cancel() }
        let running = Array(operations.values)
        for operation in running { operation.cancel() }
        let tasks = running.map(\.finished)
        let drained = tasks.isEmpty ? true
            : await Self.bounded(timeout: max(0, deadline.timeIntervalSinceNow)) { for task in tasks { await task.value } }
        lastDrainTimedOut = !(cancelled && drained)
        let allDone = cancelled && drained
        trace(allDone ? .operationsDrained : .drainTimedOut)

        try store.markSendingInflightUnknown()
        trace(.inflightMarkedUnknown)

        try store.clearEngineState()
        trace(.engineStateCleared)

        let generation = try store.bumpGeneration()
        trace(.generationBumped)
        return generation
    }

    /// True when `work` finished within `timeout`; false when the time ran out first (the work is left running, never awaited again).
    private static func bounded(timeout: TimeInterval, _ work: @escaping @Sendable () async -> Void) async -> Bool {
        let latch = Latch()
        let waiter = Task { await work(); latch.fire(true) }
        let timer = Task { try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000)); latch.fire(false) }
        let result = await latch.wait()
        waiter.cancel(); timer.cancel()
        return result
    }

    /// Lifts the fence: `prepare()` on the gateway (which creates the zone only from `unknown`), then, in ONE store transaction,
    /// in-flight rows and results of an older generation are re-homed and the durable fence is dropped. Nothing is
    /// opened unless, after `prepare()`, the gateway still reports the user this library is bound to, no account change started
    /// meanwhile, and the generation and the binding are what the transaction expects. Otherwise the fence stays closed and
    /// `.temporarilyUnavailable` is returned (retry later). The caller has checked the policy. A fence found in the database (a
    /// restart in the middle of the sequence) is completed first.
    @discardableResult
    public func lift(using gateway: any CloudKitGateway) async throws -> CloudAccountState {
        guard !changing else { return .temporarilyUnavailable }
        let started = changeCount
        let durablyFenced = try store.isAccountFenced()
        if gated || durablyFenced {
            gated = true
            try store.clearEngineState()
            try store.bumpGeneration()
        }
        let state = try await gateway.prepare()
        guard case .available(let hash) = state else { return state }
        let again = await gateway.accountState()
        // from here to the end: no suspension point
        guard !changing, changeCount == started, again == state, try store.cloudUserHash() == hash,
              try store.liftAndRehome(expectedGeneration: try store.generation(), accountHash: hash) else {
            return .temporarilyUnavailable
        }
        gated = false
        trace(.lifted)
        return state
    }

    /// Reads the account the gateway reports, applies `CloudAccountPolicy` with the stored user hash and lifts the fence only for
    /// `.resume`. `.pause(...)`, `.waitForAccount` and `.firstBind` leave the fence up (a first bind is the caller's step:
    /// `CloudSyncStore.bind`, then `lift`). A lift that gave up (the account moved meanwhile) answers `.waitForAccount`.
    @discardableResult
    public func resumeIfAllowed(using gateway: any CloudKitGateway) async throws -> CloudAccountDecision {
        let decision = CloudAccountPolicy.evaluate(stored: try store.cloudUserHash(), current: await gateway.accountState())
        guard decision == .resume else { return decision }
        try await lift(using: gateway)
        return gated ? .waitForAccount : decision
    }

    // MARK: unknown outcomes after the original account returned

    /// For each in-flight save of the current generation in state `unknown` that has no recorded result: fetch the record by
    /// name (as a tracked operation, so a switch cancels it); if the server's version is exactly our attempt (`sid == attemptId`)
    /// the pair is recorded now, in one store transaction that re-checks generation, fence and binding. A fetch that
    /// finishes after an account change writes nothing and throws. Anything else is left alone for the publisher's table;
    /// in particular a version that was overwritten later is never claimed.
    public func resolveUnknownOutcomes(using gateway: any CloudKitGateway) async throws -> [String: CloudUnknownResolution] {
        guard !gated else { throw CloudSyncError.fenced }
        let started = changeCount
        let generation = try store.generation()
        guard let stored = try store.cloudUserHash() else { throw CloudSyncStoreError.accountMismatch }
        var found: [String: CloudUnknownResolution] = [:]
        for attempt in try store.allInflight() where attempt.state == .unknown && attempt.accountGeneration == generation {
            if try store.sendResult(attemptId: attempt.attemptId) != nil { continue }      // a result answers it already
            let name = attempt.entity.recordName
            let fetched = try await run { current in
                guard current == generation else { throw CloudSyncStoreError.staleAccountGeneration(expected: current, actual: generation) }
                return try await gateway.fetch([name], keys: ["sid"])
            }
            let account = await gateway.accountState()
            // from here to the write: no suspension point
            guard !gated, !changing, changeCount == started, account == .available(userHash: stored) else { throw CloudSyncError.fenced }
            try requireCurrent(generation)
            guard let server = fetched[name], case .string(let sid)? = server.fields["sid"],
                  sid == attempt.attemptId, let tag = server.systemFields else { found[attempt.attemptId] = .notLanded; continue }
            try store.recordSaved(attemptId: attempt.attemptId, newSystemFields: tag,
                                  guard: CloudWriteGuard(generation: generation, accountHash: stored))
            found[attempt.attemptId] = .landed
        }
        return found
    }
}

/// One-shot result for a wait that may be answered by whichever of two tasks comes first.
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?
    func fire(_ value: Bool) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result { lock.unlock(); continuation.resume(returning: result) } else { waiter = continuation; lock.unlock() }
        }
    }
}

extension CloudSyncStore {
    /// The durable fence refuses every write of the old session, also while its generation still matches.
    static func requireNotFenced(_ db: Database) throws {
        if try Bool.fetchOne(db, sql: "SELECT fenced FROM ck_state WHERE id=1") == true { throw CloudSyncStoreError.accountFenced }
    }

    /// Receiver writes (fetched data): refused while the fence is up; with a generation, also when it is no longer the current one.
    static func requireOpen(_ db: Database, _ accountGeneration: Int64?) throws {
        try requireNotFenced(db)
        if let accountGeneration {
            let current = try generation(db)
            guard current == accountGeneration else {
                throw CloudSyncStoreError.staleAccountGeneration(expected: current, actual: accountGeneration)
            }
        }
    }

    static func check(_ db: Database, _ writeGuard: CloudWriteGuard) throws {
        let current = try generation(db)
        guard current == writeGuard.generation else {
            throw CloudSyncStoreError.staleAccountGeneration(expected: current, actual: writeGuard.generation)
        }
        guard try String.fetchOne(db, sql: "SELECT cloudUserHash FROM ck_state WHERE id=1") == writeGuard.accountHash else {
            throw CloudSyncStoreError.accountMismatch
        }
    }

    /// Lift and re-homing as one step: only if the generation is still `expectedGeneration` and the library is bound to
    /// `accountHash`; then in-flight rows and results of an older generation move to the generation in force and the fence
    /// drops. The rows were written under the bound account, which is `accountHash`. Returns false (changing nothing) otherwise.
    func liftAndRehome(expectedGeneration: Int64, accountHash: String) throws -> Bool {
        try database.pool.write { db in
            let row = try Row.fetchOne(db, sql: "SELECT generation, cloudUserHash FROM ck_state WHERE id=1")
            guard let row, (row["generation"] as Int64) == expectedGeneration, (row["cloudUserHash"] as String?) == accountHash else { return false }
            try db.execute(sql: """
                UPDATE ck_send_result SET accountGeneration=?
                WHERE attemptId IN (SELECT attemptId FROM ck_inflight WHERE generationOfAccount<>?)
                """, arguments: [expectedGeneration, expectedGeneration])
            try db.execute(sql: "UPDATE ck_inflight SET generationOfAccount=? WHERE generationOfAccount<>?",
                           arguments: [expectedGeneration, expectedGeneration])
            try db.execute(sql: "UPDATE ck_state SET fenced=0 WHERE id=1")
            return true
        }
    }

    /// Step 3 of the fence: a save that was being sent may have landed in the account that just went away.
    func markSendingInflightUnknown() throws {
        try database.pool.write { try $0.execute(sql: "UPDATE ck_inflight SET state='unknown' WHERE state='sending'") }
    }
}
