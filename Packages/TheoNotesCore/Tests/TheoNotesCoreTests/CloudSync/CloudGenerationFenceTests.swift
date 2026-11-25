// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// A list that tasks of any isolation can append to; the order of the entries is what the tests look at.
final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

/// A library database bound to the fake account "one", a fake device on it and a fence, all over the real `CloudSyncStore`.
struct CloudPolicyWorld {
    let db: AppDatabase
    let store: CloudSyncStore
    let one: FakeCloudKitAccount
    let two: FakeCloudKitAccount
    let device: FakeCloudKitDevice
    let disk: FakeDeviceDisk
    let fence: CloudGenerationFence
    let log: OrderLog
    /// The device behind a gateway whose calls can be held in the middle and resumed after other things happened.
    let gateway: SuspendingGateway

    static func make(prepare: Bool = true, bind: Bool = true, drainTimeout: TimeInterval = 10) async throws -> CloudPolicyWorld {
        let db = try AppDatabase.inMemory()
        let store = CloudSyncStore(database: db)
        let one = FakeCloudKitAccount(user: "one"), two = FakeCloudKitAccount(user: "two")
        if bind { try store.bind(accountId: "ck-one", containerId: "iCloud.test", zoneName: "TheoNotes", cloudUserHash: one.userHash) }
        let disk = FakeDeviceDisk()
        let device = FakeCloudKitDevice(account: one, store: store, disk: disk)
        if prepare { _ = try await device.prepare() }
        let log = OrderLog()
        let fence = CloudGenerationFence(store: store, drainTimeout: drainTimeout, trace: { log.add($0.rawValue) })
        return CloudPolicyWorld(db: db, store: store, one: one, two: two, device: device, disk: disk, fence: fence, log: log,
                                gateway: SuspendingGateway(device))
    }

    /// An in-flight row in the generation in force now.
    @discardableResult
    func inflight(_ attemptId: String, entity id: String = "n1", state: CloudInflight.State = .sending) throws -> CloudInflight {
        let attempt = CloudInflight(entity: CloudEntityRef(entityType: "note", entityId: id), localId: id, generation: 1, attemptId: attemptId,
                                    inc: "inc-\(id)", sealed: Data("sealed-\(attemptId)".utf8), state: state, accountGeneration: try store.generation())
        try store.insertInflight(attempt)
        return attempt
    }

    func count(_ table: String) throws -> Int { try db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)")! } }
}

@Suite struct CloudGenerationFenceTests {
    // MARK: account switch

    @Test func accountSwitchPausesAndNeverUploads() async throws {
        let w = try await CloudPolicyWorld.make()
        try await w.fence.run { _ in try await w.device.submit([CloudSave(attemptId: "a1", accountGeneration: 1, record: entity("n1"))]) }
        #expect(await w.one.recordNames == ["e.note.n1"])

        await w.device.switchAccount(to: w.two)
        try await w.fence.accountChanged()
        let decision = try await w.fence.resumeIfAllowed(using: w.device)

        #expect(decision == .pause(.accountChanged))
        #expect(await w.fence.isGated)
        #expect(try w.store.isAccountFenced())
        await #expect(throws: CloudSyncError.fenced) { try await w.fence.run { _ in 1 } }
        // even a send that bypasses the fence ends at the fenced gateway; its result is refused by the durable fence (CK-R171)
        try await w.device.submit([CloudSave(attemptId: "a2", accountGeneration: 1, record: entity("n2"))])
        #expect(try w.store.sendResult(attemptId: "a2") == nil)
        await #expect(throws: CloudSyncError.fenced) { try await w.device.fetchChanges(into: RecordingSink()) }
        #expect(await w.one.recordNames == ["e.note.n1"])
        #expect(await w.two.recordNames.isEmpty)
        #expect(try CloudAccountPolicy.launchState(store: w.store, account: await w.device.accountState())
                == .accountChanged(previousHash: w.one.userHash))
    }

    @Test func accountSwitchDuringInFlightSendDiscardsTheLateCompletion() async throws {
        // the send is still INSIDE the gateway call when the account switches, and finishes only afterwards
        let w = try await CloudPolicyWorld.make(drainTimeout: 0.05)
        let before = try w.store.generation()
        try w.inflight("late", state: .sending)
        await w.device.completeLateAfterCancel()
        w.gateway.holdSubmit.arm()
        let fence = w.fence, gateway = w.gateway
        let send = Task {
            try await fence.run { generation in
                try await gateway.submit([CloudSave(attemptId: "late", accountGeneration: generation, record: entity("n1", sid: "late"))])
            }
        }
        await w.gateway.holdSubmit.waitUntilEntered()

        await w.device.switchAccount(to: w.two)
        try await w.fence.accountChanged()
        #expect(await w.fence.lastDrainTimedOut, "the suspended call ignores cancellation, so the drain gave up")
        #expect(try await w.fence.resumeIfAllowed(using: w.gateway) == .pause(.accountChanged))

        w.gateway.holdSubmit.release()          // the held call goes on now, after the switch
        try await send.value
        await w.device.deliverLateCompletions()

        #expect(w.fence.isCurrent(before) == false, "the late send belongs to an older generation")
        #expect(try w.store.sendResult(attemptId: "late") == nil, "its result is refused by the store, not recorded (CK-R171)")
        let tag = Data("tag".utf8)
        #expect(throws: CloudSyncStoreError.self) { try w.store.recordSaved(attemptId: "late", newSystemFields: tag) }
        #expect(throws: CloudSyncStoreError.self) {
            try w.store.recordSaved(attemptId: "late", newSystemFields: tag, guard: CloudWriteGuard(generation: before, accountHash: w.one.userHash))
        }
        #expect(try w.store.pair(for: CloudEntityRef(entityType: "note", entityId: "n1")) == nil)
        #expect(try w.store.inflight(attemptId: "late")?.state == .unknown)
        #expect(try w.store.generation() != before)
        #expect(await w.one.recordNames.isEmpty)
        #expect(await w.two.recordNames.isEmpty, "nothing was written in the new account")
        #expect(await w.fence.isGated)
        #expect(try w.store.isAccountFenced())
    }

    @Test func lateResultOfTheOriginalAccountIsDroppedAndTheSaveIsResolvedFromTheServerWhenItReturns() async throws {
        let w = try await CloudPolicyWorld.make()
        try w.inflight("late", state: .sending)
        await w.device.completeLateAfterCancel()
        try await w.fence.run { generation in
            try await w.device.submit([CloudSave(attemptId: "late", accountGeneration: generation, record: entity("n1", sid: "late"))])
        }
        await w.device.switchAccount(to: w.two)
        try await w.fence.accountChanged()
        await w.device.deliverLateCompletions()
        let stale = try w.store.generation() - 1
        #expect(w.fence.isCurrent(stale) == false)
        // CK-R171: the result of the old generation is refused while the fence is up, so nothing is recorded for it
        #expect(try w.store.sendResult(attemptId: "late") == nil)

        await w.device.switchAccount(to: w.one)
        try await w.fence.accountChanged()
        #expect(try await w.fence.resumeIfAllowed(using: w.device) == .resume)
        #expect(await w.fence.isGated == false)
        let now = try w.store.generation()
        #expect(try w.store.inflight(attemptId: "late")?.accountGeneration == now, "the row was re-homed")

        // The save landed in the original account: the server's version carries our attempt id, so it is resolved by fetching it.
        let found = try await w.fence.resolveUnknownOutcomes(using: w.device)
        #expect(found == ["late": .landed])
        #expect(try w.store.pair(for: CloudEntityRef(entityType: "note", entityId: "n1")) != nil)
    }

    @Test func anOutcomeThatNeverArrivedIsResolvedFromTheServerVersionAndNeverClaimsAnOverwrittenOne() async throws {
        let w = try await CloudPolicyWorld.make()
        try w.inflight("silent", entity: "n1", state: .sending)
        try w.inflight("overwritten", entity: "n2", state: .sending)
        let ours = entity("n1", sid: "silent")
        let theirs = entity("n2", sid: "other-device")
        try await w.device.submit([CloudSave(attemptId: "silent", accountGeneration: try w.store.generation(), record: ours)])
        try await w.device.submit([CloudSave(attemptId: "other", accountGeneration: try w.store.generation(), record: theirs)])
        // both landed, but the device never learned the outcome of the two in-flight attempts
        try await w.db.pool.write { try $0.execute(sql: "DELETE FROM ck_send_result") }

        try await w.fence.accountChanged()
        #expect(try await w.fence.resumeIfAllowed(using: w.device) == .resume)
        let found = try await w.fence.resolveUnknownOutcomes(using: w.device)

        #expect(found == ["silent": .landed, "overwritten": .notLanded])
        #expect(try w.store.pair(for: CloudEntityRef(entityType: "note", entityId: "n1")) != nil)
        #expect(try w.store.pair(for: CloudEntityRef(entityType: "note", entityId: "n2")) == nil, "a version that is not ours is never claimed")
        #expect(try w.store.inflight(attemptId: "overwritten")?.state == .unknown)
    }

    @Test func sendsStopBeforeTheAccountStateIsChanged() async throws {
        let w = try await CloudPolicyWorld.make()
        let log = w.log
        try w.inflight("sending-1", state: .sending)
        try w.store.saveEngineState(Data("engine".utf8), accountGeneration: try w.store.generation())
        let hold = Hold()
        hold.arm()
        let fence = w.fence, device = w.device
        // an operation that ignores cancellation until it is released
        let operation = Task {
            try await fence.run { _ in
                await hold.pass()
                do { try await fence.run { _ in log.add("restarted") } } catch { log.add("blocked") }
                log.add("operationEnded")
            }
        }
        await hold.waitUntilEntered()
        let sendsBefore = await device.sendLog.count

        let change = Task { try await fence.accountChanged() }
        while !log.all.contains("sendsGated") { try await Task.sleep(nanoseconds: 2_000_000) }
        // only now does the account state change underneath: sends had stopped first
        await device.switchAccount(to: w.two)
        #expect(await fence.isGated)
        await #expect(throws: CloudSyncError.fenced) { try await fence.run { _ in 1 } }
        hold.release()
        _ = try await change.value
        _ = try? await operation.value

        #expect(log.all == ["sendsGated", "blocked", "operationEnded", "operationsDrained", "inflightMarkedUnknown",
                            "engineStateCleared", "generationBumped"], "\(log.all)")
        #expect(await device.sendLog.count == sendsBefore, "no send reached the cloud after the fence went up")
        #expect(try w.store.inflight(attemptId: "sending-1")?.state == .unknown)
        #expect(try w.store.engineState() == nil, "cleared by the sequence itself, before any lift")
    }

    @Test func theGenerationIsBumpedOnlyAfterTheOperationsEnded() async throws {
        let w = try await CloudPolicyWorld.make()
        let before = try w.store.generation()
        let fence = w.fence
        let seen = OrderLog()
        let operation = Task { try await fence.run { generation in
            seen.add("gen:\(generation)")
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
            seen.add("stillAt:\(try w.store.generation())")
        } }
        while seen.all.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        let after = try await fence.accountChanged()
        _ = try? await operation.value
        #expect(after == before + 1)
        #expect(seen.all == ["gen:\(before)", "stillAt:\(before)"], "the operation saw the old generation until it ended")
        #expect(fence.isCurrent(before) == false && fence.isCurrent(after))
    }

    // MARK: sign out

    @Test func signOutKeepsLocalLibrary() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("cloud-policy-\(UUID())"))
        try paths.createDirectories()
        let db = try AppDatabase(path: paths.database)
        defer { try? db.pool.close(); try? FileManager.default.removeItem(at: paths.root) }
        let notes = NoteStore(db: db, notifier: nil, paths: paths)
        let store = CloudSyncStore(database: db)
        let cloud = FakeCloudKitAccount(user: "one")
        try store.bind(accountId: "ck-one", containerId: "iCloud.test", zoneName: "TheoNotes", cloudUserHash: cloud.userHash)
        let device = FakeCloudKitDevice(account: cloud, store: store)
        _ = try await device.prepare()
        let fence = CloudGenerationFence(store: store)
        _ = try notes.create(text: "# First\n#work")
        _ = try notes.create(text: "# Second")

        func libraryHash() throws -> String {
            try db.pool.read { db in
                try Row.fetchAll(db, sql: "SELECT id, text, title, revision FROM note ORDER BY id")
                    .map { "\($0["id"] as String)|\($0["text"] as String)|\($0["revision"] as Int)" }.joined(separator: "\n")
            }
        }
        func dirty() throws -> Int { try db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_dirty")! } }
        let hashBefore = try libraryHash(), dirtyBefore = try dirty()
        #expect(dirtyBefore >= 2, "capture is on while bound")

        await device.signOut()
        try await fence.accountChanged()
        #expect(try await fence.resumeIfAllowed(using: device) == .pause(.signedOut))

        #expect(try libraryHash() == hashBefore, "signing out changes nothing in the library")
        #expect(try dirty() == dirtyBefore)
        _ = try notes.create(text: "# Written while signed out")
        #expect(try dirty() == dirtyBefore + 1, "the dirty queue keeps counting")
        #expect(try store.backend() == .cloudkit, "the binding stays; nothing was detached")
        #expect(try store.cloudUserHash() == cloud.userHash)
        #expect(try CloudAccountPolicy.launchState(store: store, account: .noAccount) == .signedOutOfICloud)

        // signing back in as the same person resumes
        await device.signIn(user: cloud)
        #expect(try await fence.resumeIfAllowed(using: device) == .resume)
        #expect(try dirty() == dirtyBefore + 1)
        #expect(try libraryHash() != hashBefore, "the new note is simply part of the library")
    }

    // MARK: events

    @Test func eventsAreHandledWithoutAWaitingCall() async throws {
        let w = try await CloudPolicyWorld.make()
        // nobody waits for the outcome and nobody reads the event stream
        try await w.device.submit([CloudSave(attemptId: "nobody-waits", accountGeneration: try w.store.generation(), record: entity("n1"))])
        let stored = try #require(try w.store.sendResult(attemptId: "nobody-waits"))
        guard case .saved = stored.outcome else { Issue.record("expected saved"); return }

        await w.one.removeZone(reason: .userDeletedZone)
        try await w.device.fetchChanges(into: RecordingSink())
        #expect(try w.store.zoneState() == .removed(.userDeletedZone), "the zone event was written to ck_state by the gateway")
        #expect(try CloudAccountPolicy.launchState(store: w.store, account: await w.device.accountState()) == .zoneRemoved(reason: .userDeletedZone))
    }

    @Test func eventsSurviveRestart() async throws {
        let w = try await CloudPolicyWorld.make()
        try w.inflight("pending", state: .sending)
        try await w.device.submit([CloudSave(attemptId: "answered", accountGeneration: try w.store.generation(), record: entity("n9"))])
        await w.one.removeZone(reason: .encryptedDataReset)
        try await w.device.fetchChanges(into: RecordingSink())

        // a new process: a new store object over the same database
        let restarted = CloudSyncStore(database: w.db)
        #expect(try restarted.sendResult(attemptId: "answered") != nil, "the result was durable before anyone asked for it")
        #expect(try CloudAccountPolicy.launchState(store: restarted, account: .available(userHash: w.one.userHash))
                == .zoneRemoved(reason: .encryptedDataReset))

        await w.device.switchAccount(to: w.two)
        try await w.fence.accountChanged()
        let store = CloudSyncStore(database: w.db)
        let device = FakeCloudKitDevice(account: w.two, store: store, disk: w.disk)
        let fence = CloudGenerationFence(store: store)

        #expect(await fence.isGated, "the fence is durable")
        #expect(try store.inflight(attemptId: "pending")?.state == .unknown)
        #expect(try await fence.resumeIfAllowed(using: device) == .pause(.accountChanged))
        #expect(try CloudAccountPolicy.launchState(store: store, account: await device.accountState()) == .accountChanged(previousHash: w.one.userHash))
        await #expect(throws: CloudSyncError.fenced) { try await fence.run { _ in 1 } }
    }

    @Test func aCrashBetweenTheGateAndTheBumpIsCompletedByTheNextLift() async throws {
        let w = try await CloudPolicyWorld.make()
        await w.device.signOut()
        // the process died right after step 1: only the durable fence exists
        try w.store.saveEngineState(Data("old".utf8), accountGeneration: try w.store.generation())
        try w.store.setAccountFenced(true)
        let before = try w.store.generation()

        let fence = CloudGenerationFence(store: w.store)
        #expect(await fence.isGated)
        await w.device.signIn(user: w.one)
        #expect(try await fence.resumeIfAllowed(using: w.device) == .resume)

        #expect(try w.store.engineState() == nil, "the engine state of the old session is gone")
        #expect(try w.store.generation() > before)
        #expect(await fence.isGated == false)
        #expect(try w.store.isAccountFenced() == false)
    }

    @Test func aFirstBindWaitsForTheCallersBindAndThenLifts() async throws {
        let w = try await CloudPolicyWorld.make(prepare: false, bind: false)
        #expect(try await w.fence.resumeIfAllowed(using: w.device) == .firstBind)
        try w.store.bind(accountId: "ck-one", containerId: "iCloud.test", zoneName: "TheoNotes", cloudUserHash: w.one.userHash)
        #expect(try await w.fence.lift(using: w.device) == .available(userHash: w.one.userHash))
        #expect(try w.store.zoneState() == .created)
    }
}
