// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

/// Task 15, fix round 1 (Codex review): destructive actions and key changes under the account fence (C1, C2), the key bundle
/// comes back with "Upload again" (I1, c), quota is reported across rounds (I2) and the backup comes before the
/// recovery step (I4).

/// Forwards to a coordinator gateway and lets a test act at the moment a call is made.
final class HookGateway: CloudKitGateway, @unchecked Sendable {
    let inner: CoordGateway
    nonisolated let events: AsyncStream<CloudGatewayEvent>
    private let lock = NSLock()
    private var _beforeDeleteZone: (@Sendable () async -> Void)?
    private var _beforeSubmit: (@Sendable () async -> Void)?
    private var _beforeFetch: (@Sendable () async -> Void)?
    private var _failDelete: Error?
    private var _deleteCalls = 0

    init(_ inner: CoordGateway) { self.inner = inner; events = inner.events }

    var beforeDeleteZone: (@Sendable () async -> Void)? { get { lock.withLock { _beforeDeleteZone } } set { lock.withLock { _beforeDeleteZone = newValue } } }
    var beforeSubmit: (@Sendable () async -> Void)? { get { lock.withLock { _beforeSubmit } } set { lock.withLock { _beforeSubmit = newValue } } }
    var beforeFetch: (@Sendable () async -> Void)? { get { lock.withLock { _beforeFetch } } set { lock.withLock { _beforeFetch = newValue } } }
    var failDelete: Error? { get { lock.withLock { _failDelete } } set { lock.withLock { _failDelete = newValue } } }
    var deleteCalls: Int { lock.withLock { _deleteCalls } }

    func prepare() async throws -> CloudAccountState { try await inner.prepare() }
    func accountState() async -> CloudAccountState { await inner.accountState() }
    func submit(_ batch: [CloudSave]) async throws { await beforeSubmit?(); try await inner.submit(batch) }
    func fetchChanges(into sink: any CloudChangeSink) async throws { try await inner.fetchChanges(into: sink) }
    func fetch(_ names: [String], keys: [String]?) async throws -> [String: CloudRecord] { await beforeFetch?(); return try await inner.fetch(names, keys: keys) }
    func delete(_ names: [String]) async throws { try await inner.delete(names) }
    func deleteZone() async throws {
        lock.withLock { _deleteCalls += 1 }
        await beforeDeleteZone?()
        if let failure = failDelete { throw failure }
        try await inner.deleteZone()
    }
    func deleteZone(expecting userHash: String) async throws {
        lock.withLock { _deleteCalls += 1 }
        await beforeDeleteZone?()
        if let failure = failDelete { throw failure }
        try await inner.inner.deleteZone(expecting: userHash)
    }
}

@Suite(.serialized) struct CloudSettingsFixRound1Tests {
    static func choice() throws -> RecoveryChoice {
        let offer = try RecoveryKeyOffer.make()
        let words = offer.words.split(separator: " ").map(String.init)
        return try offer.confirm(Dictionary(uniqueKeysWithValues: offer.checkPositions.map { ($0, words[$0]) }))
    }

    /// Another person's iCloud with a synced copy of its own.
    static func otherPerson() async throws -> (account: FakeCloudKitAccount, device: CoordDevice, records: Set<String>) {
        let other = FakeCloudKitAccount(user: "someone-else")
        let device = try CoordDevice("other", cloud: other, keychain: InMemoryCloudKeychain())
        _ = try device.noteStore.create(text: "# Theirs\n")
        try await device.enable()
        let names = await other.recordNames
        #expect(!names.isEmpty)
        return (other, device, Set(names))
    }

    static func zoneRemoved(_ coordinator: CloudSyncCoordinator) async throws -> Bool {
        try await eventually { if case .zoneRemoved = await coordinator.currentState { true } else { false } }
    }

    // MARK: C1, delete my iCloud copy under the fence

    @Test func anAccountChangeBeforeTheDeleteDeletesNothingInTheNewAccount() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            a.realBackups = true
            let note = try a.noteStore.create(text: "# Mine\n")
            try await a.enable()
            let (other, device, before) = try await Self.otherPerson()
            defer { device.cleanup() }
            await a.fake.switchAccount(to: other)

            await #expect(throws: CloudCoordinatorError.accountNotCurrent) { try await a.coordinator.deleteICloudCopy() }
            #expect(Set(await other.recordNames) == before, "the other account's copy is untouched")
            #expect(try a.note(note.id)?.text == "# Mine\n", "this library is untouched")
            #expect(try a.store.backend() == .cloudkit, "not detached: nothing was deleted")
        }
    }

    @Test func anAccountChangeDuringTheDeleteDeletesNothingInTheNewAccount() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            a.realBackups = true
            let hook = HookGateway(a.gateway)
            let coordinator = a.makeCoordinator(gateway: hook)
            let note = try a.noteStore.create(text: "# Mine\n")
            try await a.enable(using: coordinator)
            let (other, device, before) = try await Self.otherPerson()
            defer { device.cleanup() }
            let fake = a.fake
            // the gateway has already re-registered for the new account (its fence lifted) when the delete is issued
            hook.beforeDeleteZone = { await fake.switchAccount(to: other); _ = try? await fake.prepare() }

            await #expect(throws: (any Error).self) { try await coordinator.deleteICloudCopy() }
            #expect(hook.deleteCalls == 1, "the delete was attempted")
            #expect(Set(await other.recordNames) == before, "the account changed between the check and the delete; the delete was refused")
            #expect(try a.note(note.id)?.text == "# Mine\n")
            #expect(try a.store.backend() == .cloudkit, "detach only after the deletion is confirmed")
        }
    }

    @Test func theOwnerLockIsHeldWhileTheCopyIsBeingDeleted() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            a.realBackups = true
            let hook = HookGateway(a.gateway)
            let coordinator = a.makeCoordinator(gateway: hook)
            try await a.enable(using: coordinator)
            let secondOwnerGotIn = LockedBox<Bool?>(nil)
            let root = a.paths.root
            hook.beforeDeleteZone = {
                let lock = try? CloudSyncOwnerLock.acquire(root: root)
                secondOwnerGotIn.update { $0 = lock != nil }
                lock?.release()
            }
            try await coordinator.deleteICloudCopy()
            #expect(secondOwnerGotIn.value == false, "no other coordinator may take the library while its copy is being deleted")
            #expect(hook.deleteCalls == 1)
        }
    }

    @Test func aFailedDeleteLeavesTheLibraryBoundAndTheCopyInPlace() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            a.realBackups = true
            let hook = HookGateway(a.gateway)
            let coordinator = a.makeCoordinator(gateway: hook)
            let note = try a.noteStore.create(text: "# Mine\n")
            try await a.enable(using: coordinator)
            let records = Set(await world.cloud.recordNames)
            hook.failDelete = CloudSyncError.offline
            await #expect(throws: CloudSyncError.offline) { try await coordinator.deleteICloudCopy() }
            #expect(Set(await world.cloud.recordNames) == records)
            #expect(try a.store.backend() == .cloudkit)
            #expect(try a.note(note.id)?.text == "# Mine\n")
            // and it works once the network is back
            hook.failDelete = nil
            try await coordinator.deleteICloudCopy()
            #expect(await world.cloud.recordNames.isEmpty)
            #expect(try a.store.backend() == .none)
        }
    }

    @Test func theGatewayDeletesTheZoneOnlyForTheAccountItIsSignedInTo() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            try await a.enable()
            let records = Set(await world.cloud.recordNames)
            await #expect(throws: CloudSyncError.fenced) { try await a.fake.deleteZone(expecting: "someone-else-hash") }
            #expect(Set(await world.cloud.recordNames) == records, "a wrong account hash deletes nothing")
            try await a.fake.deleteZone(expecting: world.cloud.userHash)
            #expect(await world.cloud.recordNames.isEmpty)
        }
    }

    // MARK: C2, replacing recovery words under the fence

    @Test func recoveryWordsAreNotReplacedAfterAnAccountChange() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            _ = try a.noteStore.create(text: "# Mine\n")
            try await a.enable()
            let (other, device, before) = try await Self.otherPerson()
            defer { device.cleanup() }
            await a.fake.switchAccount(to: other)
            let saves = a.gateway.saves.count

            await #expect(throws: CloudCoordinatorError.accountNotCurrent) { _ = try await a.coordinator.saveRecoveryWords(try Self.choice()) }
            #expect(a.gateway.saves.count == saves, "nothing was sent")
            #expect(Set(await other.recordNames) == before)
            #expect(try await a.coordinator.recoveryState() == .acknowledgedSkip)
        }
    }

    @Test func recoveryWordsWaitForARunningCycleInsteadOfWritingAlongsideIt() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            _ = try a.noteStore.create(text: "# Mine\n")
            try await a.enable()
            let hold = Latch()
            a.hooks.on("cycle.afterFetch") { await hold.wait() }
            let cycle = Task { try await a.coordinator.syncNow() }
            #expect(try await eventually { a.hooks.steps.contains("cycle.afterFetch") })
            let finished = LockedBox<Bool>(false)
            let rotation = Task {
                let outcome = try await a.coordinator.saveRecoveryWords(try Self.choice())
                finished.update { $0 = true }
                return outcome
            }
            try await Task.sleep(nanoseconds: 300_000_000)
            #expect(finished.value == false, "the rotation waits for the cycle that is running")
            #expect(a.gateway.savedNames.filter { $0 == "keybundle" }.count == 1, "no second bundle write while the cycle runs")
            a.hooks.clear()
            await hold.release()
            _ = try await cycle.value
            guard case .replaced = try await rotation.value else { Issue.record("expected the words to be replaced"); return }
            #expect(try await a.coordinator.recoveryState() == .saved)
        }
    }

    @Test func anAccountChangeDuringTheRotationWritesNothingAndKeepsTheOldWords() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            let hook = HookGateway(a.gateway)
            let coordinator = a.makeCoordinator(gateway: hook)
            _ = try a.noteStore.create(text: "# Mine\n")
            try await a.enable(using: coordinator)
            let (other, device, before) = try await Self.otherPerson()
            defer { device.cleanup() }
            let fake = a.fake
            hook.beforeSubmit = { await fake.switchAccount(to: other) }

            await #expect(throws: (any Error).self) { _ = try await coordinator.saveRecoveryWords(try Self.choice()) }
            #expect(Set(await other.recordNames) == before, "nothing reached the new account")
            #expect(try await coordinator.recoveryState() == .acknowledgedSkip, "the old state stands")
        }
    }

    // MARK: I1, "Upload again" puts the key bundle back (c)

    @Test func uploadAgainBringsTheKeyBundleBackSoANewDeviceCanJoin() async throws {
        try await withCoordWorld(2) { world in
            let a = world.devices[0], c = world.devices[1]
            let note = try a.noteStore.create(text: "# Mine\n")
            try await a.enable()
            await world.cloud.removeZone(reason: .userDeletedZone)
            await a.fake.pushRemoteChange()
            #expect(try await Self.zoneRemoved(a.coordinator))

            try await a.coordinator.chooseUploadAgain()
            #expect(await world.cloud.recordNames.contains(CloudRecordCodec.keyBundleRecordName), "the key is back before anything else is uploaded")
            #expect(try a.store.zoneState() == .created)
            _ = try await a.coordinator.syncNow()
            _ = try await a.coordinator.uploadMissingAgain()
            _ = try await a.coordinator.syncNow()

            _ = try await c.enable()
            #expect(try c.note(note.id)?.text == "# Mine\n", "a new device joins and gets the notes")
        }
    }

    @Test func uploadAgainWithoutAVerifiedCachedBundleStopsAndChangesNothing() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            try await a.enable()
            await world.cloud.removeZone(reason: .userDeletedZone)
            await a.fake.pushRemoteChange()
            #expect(try await Self.zoneRemoved(a.coordinator))

            let genuine = try #require(try a.store.cachedKeyBundle())
            try a.sql("UPDATE ck_state SET keyBundleCache=NULL")
            await #expect(throws: CloudCoordinatorError.keyBundleCacheMissing) { try await a.coordinator.chooseUploadAgain() }
            #expect(try a.store.zoneState() == .removed(.userDeletedZone), "still removed: a clear state, not a half-made copy")
            #expect(await world.cloud.recordNames.isEmpty)

            // a cache that does not belong to the pinned account does not count either
            var forged = genuine
            forged.accountId = "ck-someone-else"
            try a.store.cacheKeyBundle(forged)
            await #expect(throws: CloudCoordinatorError.keyBundleCacheMissing) { try await a.coordinator.chooseUploadAgain() }
            #expect(await world.cloud.recordNames.isEmpty)
            #expect(try a.store.zoneState() == .removed(.userDeletedZone))
        }
    }

    @Test func anAccountChangeDuringUploadAgainWritesNothingInTheNewAccountAndStaysRemoved() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            let hook = HookGateway(a.gateway)
            let coordinator = a.makeCoordinator(gateway: hook)
            try await a.enable(using: coordinator)
            await world.cloud.removeZone(reason: .userDeletedZone)
            await a.fake.pushRemoteChange()
            #expect(try await Self.zoneRemoved(coordinator))
            let other = FakeCloudKitAccount(user: "someone-else")
            let fake = a.fake
            hook.beforeSubmit = { await fake.switchAccount(to: other) }       // the account changes when the key is about to be written

            await #expect(throws: (any Error).self) { try await coordinator.chooseUploadAgain() }
            #expect(await other.recordNames.filter { $0 == CloudRecordCodec.keyBundleRecordName }.isEmpty, "the new account got no key")
            #expect(await other.recordNames.filter { $0.hasPrefix("e.") }.isEmpty)
        }
    }

    @Test func aCrashBetweenTheStepsOfUploadAgainIsFinishedByTheNextLaunchBeforeAnythingIsUploaded() async throws {
        for boundary in ["uploadAgain.afterReset", "uploadAgain.afterZone", "uploadAgain.afterBundle"] {
            try await withCoordWorld(2) { world in
                let a = world.devices[0], c = world.devices[1]
                let crash = CrashPoint()
                let first = a.makeCoordinator(crash: crash)
                let note = try a.noteStore.create(text: "# Mine\n")
                try await a.enable(using: first)
                await world.cloud.removeZone(reason: .userDeletedZone)
                await a.fake.pushRemoteChange()
                #expect(try await Self.zoneRemoved(first))

                crash.arm(boundary)
                await #expect(throws: CrashInjected(boundary: boundary)) { try await first.chooseUploadAgain() }
                #expect(await world.cloud.recordNames.filter { $0.hasPrefix("e.") }.isEmpty, "\(boundary): no note was uploaded")

                let restarted = a.makeCoordinator()
                _ = try await restarted.launch()
                #expect(await world.cloud.recordNames.contains(CloudRecordCodec.keyBundleRecordName), "\(boundary): the next launch put the key back")
                #expect(await world.cloud.versionCount(of: CloudRecordCodec.keyBundleRecordName) == 1, "\(boundary): exactly one key bundle")
                _ = try await restarted.uploadMissingAgain()
                _ = try await restarted.syncNow()
                _ = try await c.enable()
                #expect(try c.note(note.id)?.text == "# Mine\n", "\(boundary): a new device can join")
            }
        }
    }

    @Test func twoDevicesMakingTheCopyAgainAtTheSameTimeEndWithOneKeyBundle() async throws {
        try await withCoordWorld(3) { world in
            let a = world.devices[0], b = world.devices[1], c = world.devices[2]
            let note = try a.noteStore.create(text: "# Mine\n")
            try await a.enable()
            try await b.enable()
            try await world.converge([a, b])
            await world.cloud.removeZone(reason: .userDeletedZone)
            await a.fake.pushRemoteChange(); await b.fake.pushRemoteChange()
            let removedA = try await Self.zoneRemoved(a.coordinator), removedB = try await Self.zoneRemoved(b.coordinator)
            #expect(removedA && removedB)

            async let first: Void = a.coordinator.chooseUploadAgain()
            async let second: Void = b.coordinator.chooseUploadAgain()
            _ = try await (first, second)
            #expect(await world.cloud.versionCount(of: CloudRecordCodec.keyBundleRecordName) == 1, "the create-only write let exactly one win")
            for device in [a, b] { _ = try await device.coordinator.syncNow(); _ = try? await device.coordinator.uploadMissingAgain(); _ = try await device.coordinator.syncNow() }
            _ = try await c.enable()
            #expect(try c.note(note.id)?.text == "# Mine\n")
        }
    }

    // MARK: I2, quota across rounds

    @Test func aQuotaRefusalConsumedAtTheStartOfTheNextCycleIsStillReported() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            try await a.enable()
            await world.cloud.setQuota(bytes: 1)
            await a.fake.setAutoSend(false)                       // the answer arrives later, like the live engine's
            let note = try a.noteStore.create(text: "# No room\nbody\n")
            _ = try await a.coordinator.syncNow()                 // submitted, no answer yet
            try await a.fake.sendPending()                        // iCloud answers: no room
            let held = try await a.coordinator.syncNow()          // the answer is consumed at the start of this cycle
            #expect(held == .quotaFull, "got \(held)")
            #expect(try a.dirtyGeneration(note.id) != nil)
        }
    }

    @Test func whileQuotaIsHeldNoImmediateRetryIsRequested() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            try await a.enable()
            await world.cloud.setQuota(bytes: 1)
            _ = try a.noteStore.create(text: "# No room\nbody\n")
            let held = try await a.coordinator.syncNow()
            #expect(held == .quotaFull)
            #expect(await a.coordinator.retry == .onForegroundOrEvery(CloudErrorPolicy.quotaRetryInterval))
            let cycles = await a.coordinator.completedCycles
            try await Task.sleep(nanoseconds: 400_000_000)
            #expect(await a.coordinator.completedCycles == cycles, "no cycle was started on its own")
        }
    }

    // MARK: I4, the backup comes before the recovery step

    @Test func theBackupIsMadeAndVerifiedBeforeTheRecoveryChoiceIsAskedFor() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            a.realBackups = true
            _ = try a.noteStore.create(text: "# Mine\n")
            await #expect(throws: CloudCoordinatorError.recoveryChoiceRequired) { _ = try await a.coordinator.enable(recovery: nil) }
            #expect(a.backups == 1, "the backup came first")
            #expect(await world.cloud.recordNames.isEmpty, "no key and no note is in iCloud yet")
            #expect(try a.store.backend() == .none)

            _ = try await a.coordinator.enable(recovery: try Self.choice())
            #expect(a.backups == 1, "the same backup serves the whole first sync")
            #expect(try a.store.backend() == .cloudkit)
        }
    }
}
