// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
import UIKit
@testable import TheoNotesCore
@testable import BaerchenIOS

// Task 16: Settings ▸ iCloud on the iPhone and iPad against the in-memory iCloud (`FakeCloudKit.swift`, compiled into this target from the
// Core test folder; see project.yml and CK-R178). Nothing here reaches the real iCloud. Real behaviour is NOT VERIFIED until the signed
// two-device run (docs/release/cloudkit-acceptance.md, section E).

/// Counts how often the shipped services were asked for anything.
final class MobileCloudTouchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func hit() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// What the controller asked the system for: silent pushes and the background refresh.
final class MobileSystemCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var _registered = 0, _unregistered = 0, _scheduled = 0, _cancelled = 0, _restored = 0
    func cancelled() { lock.withLock { _cancelled += 1 } }
    func restored() { lock.withLock { _restored += 1 } }
    var cancelCount: Int { lock.withLock { _cancelled } }
    var restoreCount: Int { lock.withLock { _restored } }
    func registered() { lock.withLock { _registered += 1 } }
    func unregistered() { lock.withLock { _unregistered += 1 } }
    func scheduled() { lock.withLock { _scheduled += 1 } }
    var registerCount: Int { lock.withLock { _registered } }
    var unregisterCount: Int { lock.withLock { _unregistered } }
    var scheduleCount: Int { lock.withLock { _scheduled } }
}

/// A gateway in front of the fake whose `submit` can be made to hang until it is cancelled, the way a long attachment upload hangs.
final class MobileHangingSubmitGateway: CloudKitGateway, @unchecked Sendable {
    let inner: FakeCloudKitDevice
    private let lock = NSLock()
    private var armed = false
    private var released = false
    private var stuck = false
    private var stuckReleased = false
    private var prepareHangs = false
    private(set) var completedLate = false
    private var _prepareEntered = 0, _fetches = 0
    /// How often `prepare()` was entered while it was armed to hang, and how often a fetch was started (a start that ran on would fetch).
    var prepareEntered: Int { lock.withLock { _prepareEntered } }
    var fetchCalls: Int { lock.withLock { _fetches } }
    private(set) var entered = 0
    private(set) var enteredOnMainThread = false
    private(set) var fenceCancels = 0

    init(_ inner: FakeCloudKitDevice) { self.inner = inner }

    var events: AsyncStream<CloudGatewayEvent> { inner.events }

    func arm() { lock.lock(); armed = true; released = false; lock.unlock() }
    /// A send that ignores both cancellations (Task and the fence's closure), and when finally let go still completes: a late result.
    func armStuck() { lock.withLock { stuck = true; stuckReleased = false } }
    func releaseStuck() { lock.withLock { stuckReleased = true } }
    /// `prepare()` (the first call of every launch cycle) hangs until the fence's closure or a cancellation ends it.
    func armPrepare() { lock.withLock { prepareHangs = true; released = false } }
    private var stuckNow: Bool { lock.withLock { stuck && !stuckReleased } }
    func cancelOperations() async { lock.withLock { fenceCancels += 1; released = true } }
    var hasEntered: Bool { lock.withLock { entered > 0 } }
    var cancelCount: Int { lock.withLock { fenceCancels } }
    private var shouldHang: Bool { lock.withLock { armed && !released } }

    func prepare() async throws -> CloudAccountState {
        if lock.withLock({ if prepareHangs && !released { _prepareEntered += 1; return true }; return false }) {
            while lock.withLock({ prepareHangs && !released }), !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            throw CancellationError()
        }
        return try await inner.prepare()
    }
    func accountState() async -> CloudAccountState { await inner.accountState() }
    func submit(_ saves: [CloudSave]) async throws {
        if lock.withLock({ if stuck && !stuckReleased { entered += 1; return true }; return false }) {
            while stuckNow { try? await Task.sleep(for: .milliseconds(5)) }
            try await inner.submit(saves)
            lock.withLock { completedLate = true }
            return
        }
        let hang = lock.withLock { () -> Bool in
            let hang = armed && !released
            if hang { entered += 1; enteredOnMainThread = enteredOnMainThread || Thread.isMainThread }
            return hang
        }
        if hang {
            while shouldHang, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            throw CancellationError()
        }
        try await inner.submit(saves)
    }
    func fetchChanges(into sink: any CloudChangeSink) async throws { lock.withLock { _fetches += 1 }; try await inner.fetchChanges(into: sink) }
    func fetch(_ names: [String], keys: [String]?) async throws -> [String: CloudRecord] { try await inner.fetch(names, keys: keys) }
    func delete(_ names: [String]) async throws { try await inner.delete(names) }
    func deleteZone() async throws { try await inner.deleteZone() }
    func deleteZone(expecting userHash: String) async throws { try await inner.deleteZone(expecting: userHash) }
}

private final class RemoteNotes: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [[String]] = []
    func add(_ info: [AnyHashable: Any]) -> Bool {
        lock.lock(); seen.append(info.keys.compactMap { $0 as? String }.sorted()); lock.unlock()
        return true
    }
    var all: [[String]] { lock.lock(); defer { lock.unlock() }; return seen }
}

/// One iPhone with a temporary library, the fake iCloud and the controller.
@MainActor final class MobileCloudDevice {
    let parent: URL
    let library: MobileLibrary
    let cloud: FakeCloudKitAccount
    let keychain: InMemoryCloudKeychain
    let seeds: InMemoryCloudKeySeedStore
    let fake: FakeCloudKitDevice
    let touched = MobileCloudTouchCounter()
    let system = MobileSystemCalls()
    let controller: MobileCloudSyncController
    let services: MobileCloudSyncServices

    var store: CloudSyncStore { CloudSyncStore(database: library.database) }

    init(cloud: FakeCloudKitAccount = FakeCloudKitAccount(), keychain: InMemoryCloudKeychain = InMemoryCloudKeychain(),
         flag: Bool = true, policy: SyncLaunchPolicy = .enabled, configured: Bool = true,
         timing: MobileCloudSyncScheduler.Timing = .init(),
         wrap: (@Sendable (FakeCloudKitDevice) -> MobileCloudSyncGatewayParts)? = nil) throws {
        self.cloud = cloud; self.keychain = keychain
        parent = FileManager.default.temporaryDirectory.appendingPathComponent("CloudIOS-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        library = try MobileLibrary(paths: AppPaths(root: parent.appendingPathComponent("Library", isDirectory: true)))
        // The controller needs the services before it exists; the fake needs the library's database. A box ties them.
        let box = DeviceBox()
        let seeds = InMemoryCloudKeySeedStore(keychain: keychain)
        let touched = self.touched, system = self.system
        let services = MobileCloudSyncServices(
            configuration: configured ? CloudKitConfiguration(containerIdentifier: "iCloud.test.theonotes") : nil,
            gateway: { _ in touched.hit(); return wrap?(box.gateway!) ?? MobileCloudSyncGatewayParts(gateway: box.gateway!) },
            keychain: { _ in touched.hit(); return seeds },
            clock: { Date(timeIntervalSince1970: 1_793_300_000) },
            drainTimeout: 0.5,
            registerForRemoteNotifications: { system.registered() },
            unregisterForRemoteNotifications: { system.unregistered() },
            scheduleBackgroundRefresh: { system.scheduled() },
            cancelBackgroundRefresh: { system.cancelled() },
            restorePrivateServerRefresh: { _ in system.restored() })
        self.services = services
        let fake = FakeCloudKitDevice(account: cloud, store: CloudSyncStore(database: library.database), disk: FakeDeviceDisk())
        box.gateway = fake
        self.fake = fake; self.seeds = seeds
        controller = MobileCloudSyncController(
            library: MobileCloudSyncLibrary(library: library, policy: policy), services: services, available: flag, timing: timing)
    }

    /// A new controller for the same library and the same fake iCloud, as after the process was killed while the switch was on:
    /// the persisted switch and the uploads are on, no coordinator exists, no view exists. (The old one is stopped first, which
    /// releases the owner lock; the flags are then put back by hand.)
    func relaunchedController(timing: MobileCloudSyncScheduler.Timing = .init()) async throws -> MobileCloudSyncController {
        await controller.stopSyncing()
        try store.setSwitchedOn(true)
        _ = try store.enableUploads()
        return MobileCloudSyncController(library: MobileCloudSyncLibrary(library: library), services: services, available: true, timing: timing)
    }

    var backupCount: Int { ((try? LibraryBackup(database: library.database, paths: library.paths).localBackups()) ?? []).count }
    var backend: SyncBackend { (try? store.backend()) ?? SyncBackend.none }
    var switchedOn: Bool { (try? store.isSwitchedOn()) ?? false }
    func text(of id: String) -> String? { (try? library.store.note(id: id))??.text }
    func hasSeed(_ account: String) -> Bool { ((try? seeds.seed(accountId: account)) ?? nil) != nil }

    final class DeviceBox: @unchecked Sendable { var gateway: FakeCloudKitDevice? }

    func cleanup() {
        try? library.close()
        try? FileManager.default.removeItem(at: parent)
    }

    func words(of offer: RecoveryKeyOffer) -> [Int: String] {
        let list = offer.words.split(separator: " ").map(String.init)
        return Dictionary(uniqueKeysWithValues: offer.checkPositions.map { ($0, list[$0]) })
    }

    /// Switches on and saves recovery words: the person's whole first-setup path.
    func turnOnAndSaveWords() async throws {
        await controller.turnOn()
        let offer = try #require(controller.recoveryOffer)
        #expect(await controller.confirmRecoveryWords(typed: words(of: offer)))
    }

    func turnOnAndSkip() async throws {
        await controller.turnOn()
        #expect(await controller.skipRecoveryWords(acknowledged: true))
    }

    @discardableResult
    func note(_ text: String) throws -> Note { try library.store.create(text: text) }

    func eventually(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

/// What the move closure was asked, in order.
final class LockedFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Bool] = []
    func append(_ value: Bool) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [Bool] { lock.lock(); defer { lock.unlock() }; return stored }
}

@MainActor @Suite(.serialized) struct MobileCloudSyncControllerTests {
    private func isUpToDate(_ state: CloudSyncState) -> Bool { if case .upToDate = state { true } else { false } }

    private func with(_ body: (MobileCloudDevice) async throws -> Void) async throws {
        let device = try MobileCloudDevice()
        defer { device.cleanup() }
        try await body(device)
    }

    // MARK: off by default

    @Test func aLibraryWithTheSwitchOffAsksForNothingAndStartsNothing() async throws {
        try await with { d in
            await d.controller.start()
            #expect(d.controller.isOn == false)
            #expect(d.controller.state == .off)
            #expect(d.touched.value == 0, "no gateway, no keychain: nothing contacts iCloud before the switch is flipped")
            #expect(d.controller.servicesTouched == 0)
            #expect(d.system.registerCount == 0, "no push registration while the switch is off")
            #expect(d.system.scheduleCount == 0, "no background refresh while the switch is off")
            #expect(await d.cloud.recordNames.isEmpty)
            #expect(d.backend == SyncBackend.none)
            await d.controller.backgroundRefresh()
            #expect(d.system.scheduleCount == 0 && d.touched.value == 0, "a background refresh of an off library does nothing")
            #expect(d.controller.handleRemoteNotification(["ck": 1]) == false)
            await d.controller.shutdown()
            #expect(d.touched.value == 0)
        }
    }

    @Test func aBuildWithoutTheFlagIsNotAvailableAndAsksForNothing() async throws {
        let device = try MobileCloudDevice(flag: false)
        defer { device.cleanup() }
        #expect(!device.controller.isAvailable)
        await device.controller.start()
        await device.controller.turnOn()
        await device.controller.backgroundRefresh()
        #expect(device.touched.value == 0)
        #expect(device.system.registerCount == 0 && device.system.scheduleCount == 0)
        #expect(device.controller.isOn == false)
    }

    @Test func aRecoveryLibraryNeverSyncsAndAsksForNothing() async throws {
        let device = try MobileCloudDevice(policy: .localOnly)
        defer { device.cleanup() }
        #expect(device.controller.isLocalOnly && !device.controller.isAvailable)
        await device.controller.start()
        await device.controller.turnOn()
        #expect(device.touched.value == 0)
        #expect(device.controller.isOn == false)
    }

    @Test func aBuildWithoutAContainerSaysNotAvailableAndTouchesNothingInICloud() async throws {
        let device = try MobileCloudDevice(configured: false)
        defer { device.cleanup() }
        await device.controller.turnOn()
        #expect(device.controller.state == .notAvailableInThisBuild)
        #expect(device.controller.statusText == CloudSyncState.message(for: .notAvailableInThisBuild))
        #expect(await device.cloud.recordNames.isEmpty)
    }

    // MARK: first enable and the recovery words

    @Test func firstEnableSavesABackupAsksForRecoveryWordsChecksThreeSyncsAndRegistersForPush() async throws {
        try await with { d in
            let note = try d.note("# One\n")
            await d.controller.start()
            await d.controller.turnOn()
            #expect(d.controller.recoveryPurpose == .firstSetup, "the first device decides about recovery words before keys exist")
            let offer = try #require(d.controller.recoveryOffer)
            #expect(offer.words.split(separator: " ").count == 24)
            #expect(offer.checkPositions.count == 3)
            #expect(await d.cloud.recordNames.filter { $0.hasPrefix("e.") }.isEmpty, "no note is sent before the recovery step is done")
            #expect(d.system.registerCount == 0, "nothing is registered while the person is still deciding")

            var wrong = d.words(of: offer)
            wrong[offer.checkPositions[0]] = "zzzz"
            #expect(await d.controller.confirmRecoveryWords(typed: wrong) == false)
            #expect(d.controller.recoverySheetError == MobileCloudSyncStrings.sheetWrongWords)
            #expect(d.controller.recoveryOffer != nil)

            #expect(await d.controller.confirmRecoveryWords(typed: d.words(of: offer)))
            #expect(d.controller.recoveryOffer == nil)
            #expect(isUpToDate(d.controller.state), "state: \(d.controller.state)")
            #expect(d.controller.isOn)
            #expect(d.controller.recoveryState == .saved)
            #expect(await d.cloud.recordNames.contains("e.note.\(note.id)"))
            #expect(d.backupCount >= 1, "a backup was made")
            #expect(d.system.registerCount == 1, "G0 A4: a silent push only arrives after registerForRemoteNotifications")
            #expect(d.system.scheduleCount >= 1, "a background refresh is requested once sync is on")
            await d.controller.shutdown()
        }
    }

    @Test func skipForNowNeedsTheRiskSentenceAndLeavesAReminder() async throws {
        try await with { d in
            try d.note("# One\n")
            await d.controller.turnOn()
            #expect(await d.controller.skipRecoveryWords(acknowledged: false) == false)
            #expect(d.controller.recoveryOffer != nil)
            #expect(await d.controller.skipRecoveryWords(acknowledged: true))
            #expect(isUpToDate(d.controller.state))
            #expect(d.controller.isOn)
            #expect(d.controller.recoveryState != .saved)
            #expect(d.controller.showsRecoveryReminder)
            #expect(d.controller.recoveryNudge)
            await d.controller.shutdown()
        }
    }

    @Test func cancellingTheRecoveryStepKeepsSyncOffAndCreatesNothing() async throws {
        try await with { d in
            try d.note("# One\n")
            await d.controller.turnOn()
            #expect(d.controller.recoveryOffer != nil)
            await d.controller.cancelRecoverySheet()
            #expect(d.controller.recoveryOffer == nil)
            #expect(d.controller.isOn == false)
            #expect(d.controller.state == .off)
            #expect(d.switchedOn == false)
            #expect(await d.cloud.recordNames.isEmpty)
            #expect(d.system.registerCount == 0)
        }
    }

    @Test func recoveryWordsCanBeCreatedLaterAndReplaced() async throws {
        try await with { d in
            try d.note("# One\n")
            try await d.turnOnAndSkip()
            #expect(!d.controller.recoverySaved)
            d.controller.beginCreateOrReplaceRecoveryWords()
            #expect(d.controller.recoveryPurpose == .later)
            let first = try #require(d.controller.recoveryOffer)
            #expect(await d.controller.skipRecoveryWords(acknowledged: true) == false, "no skip when creating later")
            #expect(await d.controller.confirmRecoveryWords(typed: d.words(of: first)))
            #expect(d.controller.recoverySaved)
            #expect(d.controller.notice == MobileCloudSyncStrings.recoveryReplaced)

            d.controller.beginCreateOrReplaceRecoveryWords()
            let second = try #require(d.controller.recoveryOffer)
            #expect(second.words != first.words)
            #expect(await d.controller.confirmRecoveryWords(typed: d.words(of: second)))
            #expect(d.controller.recoverySaved)
            await d.controller.shutdown()
        }
    }

    @Test func aDeviceThatLostTheSetupRaceIsToldItsWordsProtectNothing() async throws {
        let cloud = FakeCloudKitAccount()
        let winner = try MobileCloudDevice(cloud: cloud, keychain: InMemoryCloudKeychain())
        let loser = try MobileCloudDevice(cloud: cloud, keychain: InMemoryCloudKeychain())
        defer { winner.cleanup(); loser.cleanup() }
        await loser.controller.turnOn()
        let offer = try #require(loser.controller.recoveryOffer)
        try await winner.turnOnAndSkip()
        #expect(await loser.controller.confirmRecoveryWords(typed: loser.words(of: offer)))
        #expect(loser.controller.lostSetupRace)
        #expect(loser.controller.canUseRecoveryWords)
        await loser.controller.dismissLostSetupRace()
        #expect(loser.controller.lostSetupRace == false)
        await winner.controller.shutdown(); await loser.controller.shutdown()
    }

    // MARK: a second device, iCloud Keychain and the recovery words

    @Test func aSecondDeviceJoinsThroughICloudKeychainWithoutAskingForWords() async throws {
        let cloud = FakeCloudKitAccount(), keychain = InMemoryCloudKeychain()
        let first = try MobileCloudDevice(cloud: cloud, keychain: keychain)
        let second = try MobileCloudDevice(cloud: cloud, keychain: keychain)
        defer { first.cleanup(); second.cleanup() }
        let note = try first.note("# From the first device\n")
        try await first.turnOnAndSkip()
        await second.controller.turnOn()
        #expect(second.controller.recoveryOffer == nil)
        #expect(isUpToDate(second.controller.state), "state: \(second.controller.state)")
        #expect(second.text(of: note.id) == "# From the first device\n")
        await first.controller.shutdown(); await second.controller.shutdown()
    }

    @Test func aDeviceWaitingForTheKeychainSaysSoOffersTheRecoveryWordsAndSyncsOnceTheKeyArrives() async throws {
        let cloud = FakeCloudKitAccount()
        let first = try MobileCloudDevice(cloud: cloud, keychain: InMemoryCloudKeychain())
        let second = try MobileCloudDevice(cloud: cloud, keychain: InMemoryCloudKeychain())
        defer { first.cleanup(); second.cleanup() }
        let note = try first.note("# One\n")
        try await first.turnOnAndSkip()
        await second.controller.turnOn()
        #expect(second.controller.state == .waitingForKeychain || second.controller.needsRecoveryWords, "state: \(second.controller.state)")
        // Gate G0 A6: one Keychain item never reached the second device. The wait is shown, and the words are the way out at once.
        if second.controller.state == .waitingForKeychain {
            #expect(second.controller.waitsForKeychain)
            #expect(second.controller.canUseRecoveryWords, "the route to the recovery words exists during the wait")
            #expect(second.controller.showsOpenSettings)
            #expect(second.controller.headline == "Waiting")
        }
        let account = try #require(try first.store.keyState().accountId)
        try second.seeds.saveSeed(try #require(try first.seeds.seed(accountId: account)), accountId: account)
        await second.controller.syncNow()
        #expect(isUpToDate(second.controller.state), "state: \(second.controller.state)")
        #expect(second.text(of: note.id) == "# One\n")
        await first.controller.shutdown(); await second.controller.shutdown()
    }

    @Test func aDeviceWithoutTheKeyAsksForTheWordsAndOpensWithThem() async throws {
        let cloud = FakeCloudKitAccount()
        let first = try MobileCloudDevice(cloud: cloud, keychain: InMemoryCloudKeychain())
        let second = try MobileCloudDevice(cloud: cloud, keychain: InMemoryCloudKeychain())
        defer { first.cleanup(); second.cleanup() }
        let note = try first.note("# Words\n")
        await first.controller.turnOn()
        let offer = try #require(first.controller.recoveryOffer)
        let words = offer.words
        #expect(await first.controller.confirmRecoveryWords(typed: first.words(of: offer)))

        await second.controller.turnOn()
        #expect(second.controller.canUseRecoveryWords, "state: \(second.controller.state)")
        await second.controller.useRecoveryWords("not the words at all")
        #expect(second.controller.problem != nil, "wrong words are explained, nothing breaks")
        await second.controller.useRecoveryWords(words)
        #expect(isUpToDate(second.controller.state), "state: \(second.controller.state)")
        #expect(second.text(of: note.id) == "# Words\n")
        await first.controller.shutdown(); await second.controller.shutdown()
    }

    @Test func signedOutAndTheKeychainStatesAreShownAndOfferTheSettingsLink() async throws {
        try await with { d in
            try d.note("# One\n")
            await d.fake.signOut()
            await d.controller.turnOn()
            #expect(d.controller.state == .signedOutOfICloud)
            #expect(d.controller.showsOpenSettings)
            #expect(d.controller.problem == nil)
        }
        try await with { d in
            d.seeds.simulate(status: -25308)
            await d.controller.turnOn()
            #expect(d.controller.state == .keychainUnavailable)
            #expect(d.controller.showsOpenSettings)
            #expect(d.controller.statusText.contains("iCloud Keychain"))
            #expect(d.controller.statusText.contains("in Settings"), "the iPhone says Settings, not System Settings")
            #expect(!d.controller.statusText.contains("System Settings"))
        }
    }

    // MARK: the note password

    @Test func aProtectedLibraryAsksForTheNotePasswordThenBacksUpThenAsksForTheWords() async throws {
        try await with { d in
            let secret = try d.note("# Secret\nbody\n")
            try NotePrivacy(store: d.library.store).setPassword("correct horse").lock(noteId: secret.id)
            await d.controller.turnOn()
            // the state stream is delivered on its own task: wait for the last published state
            #expect(await d.eventually { d.controller.state == .needsNotePassword }, "state: \(d.controller.state)")
            #expect(d.controller.needsNotePasswordInput)
            #expect(d.controller.recoveryOffer == nil, "the password comes before the recovery step")
            #expect(d.controller.problem == nil)
            await d.controller.submitNotePassword("wrong")
            #expect(d.controller.problem == MobileCloudSyncStrings.notePasswordWrong)
            #expect(d.backupCount == 0, "the backup waits for the right password")
            await d.controller.submitNotePassword("correct horse")
            let offer = try #require(d.controller.recoveryOffer)
            #expect(d.backupCount == 1)
            #expect(d.controller.holdsNotePassword, "held while the sheet is open")
            #expect(await d.controller.confirmRecoveryWords(typed: d.words(of: offer)))
            #expect(!d.controller.holdsNotePassword, "used once and gone")
            #expect(isUpToDate(d.controller.state), "state: \(d.controller.state)")
            #expect(await d.cloud.recordNames.contains("e.note.\(secret.id)"))
            await d.controller.shutdown()
        }
    }

    private func holdingThePassword(_ d: MobileCloudDevice) async throws {
        let secret = try d.note("# Secret\nbody\n")
        try NotePrivacy(store: d.library.store).setPassword("correct horse").lock(noteId: secret.id)
        await d.controller.turnOn()
        await d.controller.submitNotePassword("correct horse")
        #expect(d.controller.recoveryOffer != nil)
        #expect(d.controller.holdsNotePassword)
    }

    @Test func theHeldNotePasswordIsLetGoOnShutdownStopCancelBackgroundingAndTermination() async throws {
        try await with { d in
            try await holdingThePassword(d)
            await d.controller.shutdown()
            #expect(!d.controller.holdsNotePassword)
        }
        try await with { d in
            try await holdingThePassword(d)
            await d.controller.stopSyncing()
            #expect(!d.controller.holdsNotePassword)
        }
        try await with { d in
            try await holdingThePassword(d)
            await d.controller.cancelRecoverySheet()
            #expect(!d.controller.holdsNotePassword)
        }
        try await with { d in
            try await holdingThePassword(d)
            NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
            #expect(!d.controller.holdsNotePassword, "the password does not outlive the screen")
            await d.controller.shutdown()
        }
        try await with { d in
            try await holdingThePassword(d)
            NotificationCenter.default.post(name: UIApplication.willTerminateNotification, object: nil)
            #expect(!d.controller.holdsNotePassword)
            await d.controller.shutdown()
        }
    }

    @Test func aHeldSecretIsZeroedWhenLetGo() {
        let secret = MobileHeldSecret("correct horse")
        #expect(secret.string() == "correct horse")
        secret.zero()
        #expect(secret.isEmpty && secret.snapshot.isEmpty && secret.string() == "")
    }

    // MARK: account, stop, delete

    @Test func aDifferentAccountPausesAndKeepOfflineIsTheDefault() async throws {
        try await with { d in
            let note = try d.note("# Mine\n")
            try await d.turnOnAndSkip()
            let other = FakeCloudKitAccount(user: "someone-else")
            await d.fake.switchAccount(to: other)
            #expect(await d.eventually { d.controller.accountChanged }, "state: \(d.controller.state)")
            #expect(d.controller.showsAccountChangedSheet)
            #expect(await other.recordNames.isEmpty, "nothing goes to the new account")
            await d.controller.keepOffline()
            #expect(d.controller.showsAccountChangedSheet == false)
            #expect(d.controller.isOn == false)
            #expect(d.controller.state == .off)
            #expect(await other.recordNames.isEmpty)
            #expect(d.text(of: note.id) == "# Mine\n")
        }
    }

    @Test func syncWithTheNewAccountSavesABackupAndStartsFresh() async throws {
        try await with { d in
            let note = try d.note("# Mine\n")
            try await d.turnOnAndSkip()
            let other = FakeCloudKitAccount(user: "someone-else")
            await d.fake.switchAccount(to: other)
            #expect(await d.eventually { d.controller.accountChanged })
            await d.controller.syncWithNewAccount()
            #expect(d.controller.recoveryPurpose == .firstSetup, "state: \(d.controller.state), problem: \(d.controller.problem ?? "-")")
            #expect(await d.controller.skipRecoveryWords(acknowledged: true))
            #expect(isUpToDate(d.controller.state), "state: \(d.controller.state)")
            #expect(await other.recordNames.contains("e.note.\(note.id)"))
            await d.controller.shutdown()
        }
    }

    @Test func stopSyncingStopsThisDeviceUnregistersPushAndDeletesNothing() async throws {
        try await with { d in
            let note = try d.note("# One\n")
            try await d.turnOnAndSkip()
            #expect(d.system.registerCount == 1)
            let records = await d.cloud.recordNames
            await d.controller.stopSyncing()
            #expect(d.controller.isOn == false)
            #expect(d.controller.state == .off)
            #expect(d.system.unregisterCount == 1, "a switched-off library asks the system to stop the pushes")
            #expect(await d.cloud.recordNames == records, "nothing in iCloud was deleted")
            #expect(d.text(of: note.id) == "# One\n")
            #expect(d.controller.isBoundToICloud)
            #expect((try? d.store.isAccountFenced()) == true, "a stop always leaves the durable fence closed (CK-R171)")
            // and it can be turned on again without a second recovery step
            await d.controller.turnOn()
            #expect(isUpToDate(d.controller.state), "state: \(d.controller.state)")
            #expect(d.controller.recoveryOffer == nil)
            #expect(d.system.registerCount == 2)
            await d.controller.shutdown()
        }
    }

    @Test func deleteMyICloudCopyDeletesTheCopyAndKeepsThisDevicesNotes() async throws {
        try await with { d in
            let note = try d.note("# Mine\n")
            try await d.turnOnAndSkip()
            #expect(await d.cloud.recordNames.isEmpty == false)
            await d.controller.deleteICloudCopy()
            #expect(await d.cloud.recordNames.isEmpty)
            #expect(d.text(of: note.id) == "# Mine\n")
            #expect(d.controller.isOn == false)
            #expect(d.controller.notice == MobileCloudSyncStrings.deleteCopyDone)
            #expect(MobileCloudSyncStrings.deleteCopyMessage.contains("notes on this device stay"))
            #expect(d.controller.isBoundToICloud == false)
            #expect(d.system.unregisterCount >= 1)
        }
    }

    @Test func removingTheICloudKeyStopsSyncRemovesItFromTheKeychainAndTheCopyStays() async throws {
        try await with { d in
            let note = try d.note("# Mine\n")
            try await d.turnOnAndSkip()
            let account = try #require(try d.store.keyState().accountId)
            #expect(d.hasSeed(account))
            await d.controller.removeICloudKey()
            #expect(!d.hasSeed(account))
            #expect(d.controller.isOn == false)
            #expect(await d.cloud.recordNames.isEmpty == false, "the copy is not deleted")
            #expect(d.text(of: note.id) == "# Mine\n")
            #expect(d.controller.notice == MobileCloudSyncStrings.removeKeyDone)
        }
    }

    @Test func aRemovedSyncedCopyIsReportedAndUploadAgainMakesItAgain() async throws {
        try await with { d in
            let note = try d.note("# One\n")
            try await d.turnOnAndSkip()
            await d.fake.removeZone()
            await d.controller.syncNow()
            #expect(d.controller.canUploadAgain, "state: \(d.controller.state)")
            await d.controller.uploadAgain()
            #expect(isUpToDate(d.controller.state), "state: \(d.controller.state), problem: \(d.controller.problem ?? "-")")
            #expect(await d.cloud.recordNames.contains("e.note.\(note.id)"))
            await d.controller.shutdown()
        }
    }

    @Test func aLibraryBoundToThePrivateServerSaysSoAndNeverStartsICloud() async throws {
        try await with { d in
            try await d.library.database.pool.write { try $0.execute(sql: "UPDATE sync_control SET backend='cloudflare' WHERE id=1") }
            await d.controller.start()
            #expect(d.controller.boundToPrivateServer)
            await d.controller.turnOn()
            #expect(d.controller.problem == MobileCloudSyncStrings.privateServerLibrary)
            #expect(d.backend == SyncBackend.cloudflare)
            #expect(await d.cloud.recordNames.isEmpty)
        }
    }

    // MARK: move this library to iCloud (MOVE-R1 to MOVE-R6; the Mac twin is in CloudSyncControllerTests)

    /// The private-server binding as the old engine leaves it after a finished sync: an account, uploads on, empty queue.
    private func bindToPrivateServer(_ d: MobileCloudDevice) async throws {
        try await d.library.database.pool.write { try $0.execute(sql: "UPDATE sync_control SET accountId='server-account', enabled=1 WHERE id=1") }
        #expect(d.backend == SyncBackend.cloudflare)
    }

    @Test func aPrivateServerLibraryOffersTheMoveAndAfterItICloudIsSwitchedOn() async throws {
        try await with { d in
            let note = try d.note("# Years of notes\nkept")        // already on the server: nothing left to send
            try await bindToPrivateServer(d)
            let finalSyncs = MobileCloudTouchCounter()
            let library = d.library
            d.controller.leavePrivateServer = { _ in
                try await PrivateServerMove.run(database: library.database, paths: library.paths, finalSync: { finalSyncs.hit() },
                                                makeBackup: { try await MobileCloudSyncLibrary(library: library).makeBackup() })
            }
            await d.controller.start()
            #expect(d.controller.boundToPrivateServer && d.controller.canMoveToICloud)
            let backups = d.backupCount
            await d.controller.moveToICloud()
            #expect(d.controller.problem == nil, "\(d.controller.problem ?? "")")
            #expect(finalSyncs.value == 1)
            #expect(d.backupCount > backups, "a backup is saved before the library lets go")
            #expect(try PrivateServerMove.hasLeft(d.library.database))
            #expect(!d.controller.boundToPrivateServer)
            #expect(d.controller.recoveryOffer != nil, "the normal switch-on follows: first device of this iCloud account")
            #expect(await d.controller.skipRecoveryWords(acknowledged: true))
            #expect(d.backend == SyncBackend.cloudkit)
            #expect(d.controller.showsMoveNotice, "move your other devices now: stays after the switch-on")
            #expect(d.controller.moveSyncNotStarted == nil, "iCloud sync runs: nothing to warn about")
            d.controller.dismissMoveNotice()
            #expect(!d.controller.showsMoveNotice, "gone only when the owner dismisses it")
            #expect(d.text(of: note.id) == "# Years of notes\nkept")
            #expect(await d.cloud.recordNames.contains("e.note.\(note.id)"))
            await d.controller.shutdown()
        }
    }

    /// Design r3: the move finished but the iCloud switch-on did not (no iCloud account here; then the recovery step cancelled). The
    /// settings say so next to the notice, the status says why, and the line goes once iCloud sync runs.
    @Test func aMoveWhoseICloudSwitchOnFailsSaysSoNextToTheNotice() async throws {
        try await with { d in
            let note = try d.note("# Kept\nhere")
            try await bindToPrivateServer(d)
            let library = d.library
            d.controller.leavePrivateServer = { _ in
                try await PrivateServerMove.run(database: library.database, paths: library.paths, finalSync: {},
                                                makeBackup: { try await MobileCloudSyncLibrary(library: library).makeBackup() })
            }
            await d.controller.start()
            await d.fake.signOut()
            await d.controller.moveToICloud()
            #expect(try PrivateServerMove.hasLeft(d.library.database), "the move itself finished")
            #expect(d.controller.showsMoveNotice && d.controller.isOn)
            #expect(d.controller.state == .signedOutOfICloud && d.controller.showsOpenSettings, "the status says why and offers Settings")
            #expect(d.controller.moveSyncNotStarted == MobileCloudSyncStrings.moveSyncBlocked)

            await d.fake.signIn(user: d.cloud)
            await d.controller.turnOn()
            #expect(d.controller.recoveryOffer != nil)
            #expect(d.controller.moveSyncNotStarted == nil, "no warning while the recovery-word step is open")
            await d.controller.cancelRecoverySheet()
            #expect(!d.controller.isOn)
            #expect(d.controller.moveSyncNotStarted == MobileCloudSyncStrings.moveSyncOff, "switched off after a move: said next to the notice")

            await d.controller.turnOn()
            #expect(await d.controller.skipRecoveryWords(acknowledged: true))
            #expect(d.controller.moveSyncNotStarted == nil, "iCloud sync runs: the line goes")
            #expect(d.text(of: note.id) == "# Kept\nhere")
            await d.controller.shutdown()
        }
    }

    @Test func aRefusedMoveChangesNothingAndSaysWhy() async throws {
        let refusals: [(Error, String)] = [
            (PrivateServerMoveRefusal.unsentChanges(2), MobileCloudSyncStrings.moveUnsent(2)),
            (PrivateServerMoveRefusal.unavailableAttachments(notes: ["Plans", "Trip"], moreNotes: 4, canMoveWithout: false), MobileCloudSyncStrings.moveUnavailable(notes: ["Plans", "Trip"], moreNotes: 4)),
            (PrivateServerMoveRefusal.unreceivedChanges(1), MobileCloudSyncStrings.moveUnreceived(1)),
            (PrivateServerMoveRefusal.notConnected, MobileCloudSyncStrings.moveNotConnected),
            (PrivateServerMoveRefusal.syncPaused, MobileCloudSyncStrings.movePaused),
            (PrivateServerMoveRefusal.firstSyncNotFinished, MobileCloudSyncStrings.moveFirstSyncUnfinished),
            (PrivateServerMoveRefusal.attachmentBeingSaved, MobileCloudSyncStrings.moveBusy),
            (URLError(.notConnectedToInternet), MobileCloudSyncStrings.moveOffline),
            (SyncAccountDetachError.backupNotVerified, MobileCloudSyncStrings.backupFailed),
        ]
        for (error, words) in refusals {
            try await with { d in
                try await bindToPrivateServer(d)
                d.controller.leavePrivateServer = { _ in throw error }
                await d.controller.start()
                await d.controller.moveToICloud()
                #expect(d.controller.problem == words)
                #expect(d.backend == SyncBackend.cloudflare && d.controller.boundToPrivateServer && !d.controller.isOn)
                #expect(d.touched.value == 0, "nothing reached iCloud")
            }
        }
    }

    /// MOVE-R13: the card's words, the same on Mac and iOS; six notes list five titles and "and 1 more", one per line.
    @Test func theMissingFilesCardSaysWhatHappensInShortLines() {
        let text = MobileCloudSyncStrings.moveUnavailable(notes: ["A", "B", "C", "D", "E"], moreNotes: 1, canMoveWithout: true)
        #expect(text.split(separator: "\n").map(String.init) == [
            "Some Attachments Are Missing", "6 notes link to files that never reached this device or your private server:",
            "A", "B", "C", "D", "E", "and 1 more",
            "You can move without these files. The notes move as they are and keep showing the missing file.", "Nothing has been moved yet.",
        ])
        #expect(MobileCloudSyncStrings.missingFilesCount(1) == "1 note links to one or more files that never reached this device or your private server:")
        #expect(MobileCloudSyncStrings.moveWithoutFilesButton == "Move to iCloud Without These Files…")
        #expect(MobileCloudSyncStrings.moveWithoutFilesMessage == MobileCloudSyncStrings.moveMessage + "\n\nThe missing attachment files stay missing.")
    }

    /// MOVE-R10: the refusal names notes whose files no device and no server ever had; "Move to iCloud Without These Files…" then moves.
    @Test func missingFilesNoDeviceHadOfferMoveWithoutTheseFilesWhichMoves() async throws {
        try await with { d in
            let note = try d.note("# Imported cover\nkept")
            try await bindToPrivateServer(d)
            let asked = LockedFlags()
            let library = d.library
            d.controller.leavePrivateServer = { withoutMissingFiles in
                asked.append(withoutMissingFiles)
                guard withoutMissingFiles else {
                    throw PrivateServerMoveRefusal.unavailableAttachments(notes: ["Imported cover"], moreNotes: 0, canMoveWithout: true)
                }
                try await PrivateServerMove.run(database: library.database, paths: library.paths, finalSync: {},
                                                makeBackup: { try await MobileCloudSyncLibrary(library: library).makeBackup() }, withoutMissingFiles: true)
            }
            await d.controller.start()
            await d.controller.moveToICloud()
            #expect(d.controller.problem == MobileCloudSyncStrings.moveUnavailable(notes: ["Imported cover"], moreNotes: 0, canMoveWithout: true))
            #expect(d.controller.canMoveWithoutMissingFiles && d.backend == SyncBackend.cloudflare, "refused first, nothing moved")
            #expect(d.controller.missingFilesToLeave?.notes == ["Imported cover"] && d.controller.missingFilesToLeave?.moreNotes == 0, "the card lists the note")
            await d.controller.moveWithoutMissingFiles()
            #expect(asked.values == [false, true])
            #expect(d.controller.problem == nil && !d.controller.canMoveWithoutMissingFiles)
            #expect(try PrivateServerMove.hasLeft(library.database) && !d.controller.boundToPrivateServer)
            #expect(d.text(of: note.id) == "# Imported cover\nkept")
        }
    }

    /// MOVE-R12: another reason is shown first; once it is gone the missing-files message with the button comes back.
    @Test func anotherReasonIsShownBeforeTheMissingFilesAndTheButton() async throws {
        try await with { d in
            try await bindToPrivateServer(d)
            let answers = LockedFlags()
            d.controller.leavePrivateServer = { _ in
                answers.append(true)
                if answers.values.count == 1 { throw PrivateServerMoveRefusal.unsentChanges(1) }
                throw PrivateServerMoveRefusal.unavailableAttachments(notes: ["Imported cover"], moreNotes: 0, canMoveWithout: true)
            }
            await d.controller.start()
            await d.controller.moveToICloud()
            #expect(d.controller.problem == MobileCloudSyncStrings.moveUnsent(1), "the person reads the reason that blocks now")
            #expect(!d.controller.canMoveWithoutMissingFiles)
            await d.controller.moveToICloud()
            #expect(d.controller.problem == MobileCloudSyncStrings.moveUnavailable(notes: ["Imported cover"], moreNotes: 0, canMoveWithout: true))
            #expect(d.controller.canMoveWithoutMissingFiles)
        }
    }

    @Test func missingFilesTheServerHadOfferNoSecondButton() async throws {
        try await with { d in
            try await bindToPrivateServer(d)
            d.controller.leavePrivateServer = { _ in throw PrivateServerMoveRefusal.unavailableAttachments(notes: ["Plans"], moreNotes: 0, canMoveWithout: false) }
            await d.controller.start()
            await d.controller.moveToICloud()
            #expect(d.controller.problem == MobileCloudSyncStrings.moveUnavailable(notes: ["Plans"], moreNotes: 0))
            #expect(!d.controller.canMoveWithoutMissingFiles)
        }
    }

    @Test func theMoveIsOfferedOnlyWithThePrivateServerSideAndTheICloudFlag() async throws {
        try await with { d in
            try await bindToPrivateServer(d)
            await d.controller.start()
            #expect(d.controller.boundToPrivateServer && !d.controller.canMoveToICloud, "no private-server side in this build")
        }
        let off = try MobileCloudDevice(flag: false); defer { off.cleanup() }
        try await bindToPrivateServer(off)
        off.controller.leavePrivateServer = { _ in }
        #expect(!off.controller.canMoveToICloud, "a build without iCloud sync has nothing to move to")
        #expect(MobileCloudSyncStrings.privateServerDetail.contains("not available yet") == false)
        #expect(!MobileCloudSyncStrings.moveMessage.contains("  "), "no runs of spaces")
    }

    // MARK: the silent push and the background refresh

    @Test func aSilentPushIsForwardedToTheGatewayOnlyWhileSyncIsOn() async throws {
        let notes = RemoteNotes()
        let d = try MobileCloudDevice(wrap: { fake in
            MobileCloudSyncGatewayParts(gateway: fake, handleRemoteNotification: { notes.add($0) })
        })
        defer { d.cleanup() }
        #expect(d.controller.handleRemoteNotification(["ck": 1]) == false, "switched off: no gateway exists, nothing is made for it")
        #expect(await MobileCloudSyncRouter.handle(["ck": 1]) == .noData, "no controller connected: nothing happens")
        #expect(d.touched.value == 0)
        try await d.turnOnAndSkip()
        #expect(d.controller.handleRemoteNotification(["ck": 1]) == true)
        #expect(notes.all == [["ck"]])
        MobileCloudSyncRouter.connect(d.controller)
        #expect(await MobileCloudSyncRouter.handle(["ck": 1]) == .newData)
        MobileCloudSyncRouter.connect(nil)
        await d.controller.stopSyncing()
        #expect(d.controller.handleRemoteNotification(["ck": 1]) == false, "after Stop the gateway still exists but nothing is forwarded")
        #expect(notes.all.count == 2)
        await d.controller.shutdown()
        #expect(d.controller.handleRemoteNotification(["ck": 1]) == false, "after shutdown nothing is forwarded")
    }

    @Test func aSilentPushBringsAnotherDevicesChangeAndTheHandlerWaitsForTheCycle() async throws {
        let cloud = FakeCloudKitAccount(), keychain = InMemoryCloudKeychain()
        let first = try MobileCloudDevice(cloud: cloud, keychain: keychain)
        let second = try MobileCloudDevice(cloud: cloud, keychain: keychain, wrap: { fake in
            MobileCloudSyncGatewayParts(gateway: fake, handleRemoteNotification: { _ in
                Task { await fake.receiveRemotePush() }
                return true
            })
        })
        defer { first.cleanup(); second.cleanup() }
        try await first.turnOnAndSkip()
        await second.controller.turnOn()
        #expect(isUpToDate(second.controller.state), "state: \(second.controller.state)")

        let note = try first.note("# Written on the first device\n")
        await first.controller.syncNow()
        #expect(second.text(of: note.id) == nil)
        let handled = await second.controller.handleRemoteNotificationAndWait(["ck": 1], timeout: 10)
        #expect(handled)
        #expect(await second.eventually { second.text(of: note.id) == "# Written on the first device\n" },
                "the push alone, without the timer or a foreground, brought the note")
        await first.controller.shutdown(); await second.controller.shutdown()
    }

    @Test func theBackgroundRefreshRunsOneCycleAndAsksForTheNextOne() async throws {
        let cloud = FakeCloudKitAccount(), keychain = InMemoryCloudKeychain()
        let first = try MobileCloudDevice(cloud: cloud, keychain: keychain)
        let second = try MobileCloudDevice(cloud: cloud, keychain: keychain)
        defer { first.cleanup(); second.cleanup() }
        try await first.turnOnAndSkip()
        await second.controller.turnOn()
        let note = try first.note("# While the app was closed\n")
        await first.controller.syncNow()
        let before = second.system.scheduleCount
        await second.controller.backgroundRefresh()
        #expect(second.text(of: note.id) == "# While the app was closed\n")
        #expect(second.system.scheduleCount == before + 1, "the next refresh is requested")
        await first.controller.shutdown(); await second.controller.shutdown()
    }

    // MARK: Stop always works

    @Test func stopSyncingWorksWhileAHungManualSyncNowIsRunning() async throws {
        final class Box: @unchecked Sendable { var gateway: MobileHangingSubmitGateway? }
        let box = Box()
        let d = try MobileCloudDevice(wrap: { fake in
            let hang = MobileHangingSubmitGateway(fake)
            box.gateway = hang
            return MobileCloudSyncGatewayParts(gateway: hang, cancelOperations: { await hang.cancelOperations() })
        })
        defer { d.cleanup() }
        try await d.turnOnAndSkip()
        let hang = try #require(box.gateway)
        hang.arm()
        try d.note("# a manual sync that hangs\n")
        let syncing = Task { await d.controller.syncNow() }
        #expect(await d.eventually { hang.hasEntered })
        #expect(!hang.enteredOnMainThread, "the upload runs off the main thread")
        #expect(d.controller.isWorking, "the manual sync holds the page's working state")

        let begun = Date()
        await d.controller.stopSyncing()
        #expect(Date().timeIntervalSince(begun) < 3, "stop returned in \(Date().timeIntervalSince(begun)) s")
        #expect(hang.cancelCount >= 1, "the fence's closure reached the gateway")
        #expect(d.controller.state == .off, "state: \(d.controller.state)")
        #expect(!d.controller.isOn)
        #expect((try? d.store.isAccountFenced()) == true, "the fence is closed and the generation bumped")
        _ = await syncing.value
        #expect(!d.controller.isWorking)
        try await Task.sleep(for: .milliseconds(200))
        #expect(d.controller.state == .off, "the cancelled cycle does not move the state after the stop: \(d.controller.state)")
        #expect(d.controller.problem == nil)
        await d.controller.shutdown()
    }

    @Test func stopSyncingWhileASchedulerDrivenUploadHangsCancelsItAndShowsNoProblem() async throws {
        final class Box: @unchecked Sendable { var gateway: MobileHangingSubmitGateway? }
        let box = Box()
        let d = try MobileCloudDevice(timing: .init(debounce: 0.2, interval: 600), wrap: { fake in
            let hang = MobileHangingSubmitGateway(fake)
            box.gateway = hang
            return MobileCloudSyncGatewayParts(gateway: hang, cancelOperations: { await hang.cancelOperations() })
        })
        defer { d.cleanup() }
        try await d.turnOnAndSkip()
        let hang = try #require(box.gateway)
        hang.arm()
        try d.note("# edited while online\n")
        #expect(await d.eventually(8) { hang.hasEntered }, "the debounced cycle started the upload")
        #expect(!d.controller.isWorking, "a scheduled cycle does not hold the page")
        let begun = Date()
        await d.controller.stopSyncing()
        #expect(Date().timeIntervalSince(begun) < 3)
        #expect(d.controller.state == .off)
        try await Task.sleep(for: .milliseconds(200))
        #expect(d.controller.problem == nil)
        #expect(d.controller.state == .off, "\(d.controller.state)")
        await d.controller.shutdown()
    }

    // MARK: wording

    @Test func vaultConversionWhileSyncIsOnAsksToTurnSyncOffFirst() {
        #expect(MobileCloudSyncController.message(for: CloudVaultConversionError.syncMustBeOff) == MobileCloudSyncStrings.turnSyncOffFirst)
        #expect(MobileCloudSyncStrings.turnSyncOffFirst.contains("Turn iCloud sync off first"))
    }

    @Test func errorMessagesNeverPrintInternalNames() {
        struct Odd: Error, CustomStringConvertible { var description: String { "CKError zone record token" } }
        #expect(MobileCloudSyncController.message(for: Odd()) == MobileCloudSyncStrings.genericProblem)
    }
}
