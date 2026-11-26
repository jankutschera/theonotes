// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import GRDB
import Testing
@testable import TheoNotes

// Task 15: Settings ▸ iCloud against the in-memory iCloud (`FakeCloudKit.swift`, compiled into this target from the Core test folder;
// see project.yml and). Nothing here reaches the real iCloud. Real behaviour is NOT VERIFIED until Gate G0 and Task 14.

/// Counts how often the shipped services were asked for anything.
final class CloudTouchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func hit() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// One Mac with a temporary library, the fake iCloud and the controller.
@MainActor final class CloudMacDevice {
    let parent: URL
    let environment: AppEnvironment
    let cloud: FakeCloudKitAccount
    let keychain: InMemoryCloudKeychain
    let seeds: InMemoryCloudKeySeedStore
    let fake: FakeCloudKitDevice
    let touched = CloudTouchCounter()

    var controller: CloudSyncController { environment.cloudSync }
    var store: CloudSyncStore { CloudSyncStore(database: environment.database) }

    init(cloud: FakeCloudKitAccount = FakeCloudKitAccount(), keychain: InMemoryCloudKeychain = InMemoryCloudKeychain(),
         flag: Bool = true, policy: SyncLaunchPolicy = .enabled, configured: Bool = true,
         wrap: (@Sendable (FakeCloudKitDevice) -> CloudSyncGatewayParts)? = nil) throws {
        self.cloud = cloud; self.keychain = keychain
        parent = FileManager.default.temporaryDirectory.appendingPathComponent("CloudMac-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let paths = AppPaths(root: parent.appendingPathComponent("Library", isDirectory: true))
        // The environment needs the services before it exists; the fake needs the environment's database. A box ties them.
        let box = DeviceBox()
        let seeds = InMemoryCloudKeySeedStore(keychain: keychain)
        let touched = self.touched
        let services = CloudSyncServices(
            configuration: configured ? CloudKitConfiguration(containerIdentifier: "iCloud.test.theonotes") : nil,
            gateway: { _ in touched.hit(); return wrap?(box.gateway!) ?? CloudSyncGatewayParts(gateway: box.gateway!) },
            keychain: { _ in touched.hit(); return seeds },
            clock: { Date(timeIntervalSince1970: 1_793_300_000) },
            drainTimeout: 0.5)
        environment = try AppEnvironment(paths: paths, syncPolicy: policy, syncSetup: false, cloudSync: flag, cloudSyncServices: services)
        let fake = FakeCloudKitDevice(account: cloud, store: CloudSyncStore(database: environment.database), disk: FakeDeviceDisk())
        box.gateway = fake
        self.fake = fake; self.seeds = seeds
    }

    var backupCount: Int { ((try? LibraryBackup(database: environment.database, paths: environment.paths).localBackups()) ?? []).count }
    var backend: SyncBackend { (try? store.backend()) ?? SyncBackend.none }
    var switchedOn: Bool { (try? store.isSwitchedOn()) ?? false }
    func text(of id: String) -> String? { (try? environment.store.note(id: id))??.text }
    func hasSeed(_ account: String) -> Bool { ((try? seeds.seed(accountId: account)) ?? nil) != nil }

    final class DeviceBox: @unchecked Sendable { var gateway: FakeCloudKitDevice? }

    func cleanup() {
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
    func note(_ text: String) throws -> Note { try environment.store.create(text: text) }

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

@MainActor @Suite(.serialized) struct CloudSyncControllerTests {
    private func isUpToDate(_ state: CloudSyncState) -> Bool { if case .upToDate = state { true } else { false } }

    private func with(_ body: (CloudMacDevice) async throws -> Void) async throws {
        let device = try CloudMacDevice()
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
            #expect(await d.cloud.recordNames.isEmpty)
            #expect(d.backend == SyncBackend.none)
            d.environment.startSync()
            await d.controller.shutdown()
            #expect(d.touched.value == 0)
        }
    }

    @Test func aBuildWithoutTheFlagShowsNothingAndStartsNothing() async throws {
        let device = try CloudMacDevice(flag: false)
        defer { device.cleanup() }
        #expect(!device.environment.cloudSyncAvailable)
        device.environment.startSync()
        try await Task.sleep(for: .milliseconds(200))   // startSync hands its work to a task
        device.environment.stopSync()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!device.environment.cloudSyncStarted, "the controller is never even made")
        #expect(device.touched.value == 0)
        #expect(!SettingsTab.order(syncSetup: true, icloud: device.environment.cloudSyncAvailable).contains(.icloud))
        #expect(SettingsTab.icloud.shown(syncSetup: true, icloud: false) == .general, "a saved iCloud tab falls back")
        #expect(SettingsTab.order(syncSetup: true, icloud: true).contains(.icloud))
    }

    @Test func theFlagShownTabSitsBesideSyncAndFallsBackOtherwise() {
        #expect(SettingsTab.order(syncSetup: true, icloud: true).map(\.title) ==
                ["General", "Capture", "Appearance", "Typography", "Automation", "Sync", "iCloud", "Privacy", "Advanced"])
        #expect(SettingsTab.order(syncSetup: false, icloud: true).map(\.title) ==
                ["General", "Capture", "Appearance", "Typography", "Automation", "iCloud", "Privacy", "Advanced"])
        #expect(SettingsTab.order(syncSetup: false, icloud: false).map(\.title) ==
                ["General", "Capture", "Appearance", "Typography", "Automation", "Privacy", "Advanced"])
        #expect(SettingsTab.icloud.shown(syncSetup: true, icloud: true) == .icloud)
        #expect(SettingsTab.sync.shown(syncSetup: false, icloud: true) == .general)
    }

    @Test func aLibraryCopyNeverSyncsAndAsksForNothing() async throws {
        let device = try CloudMacDevice(policy: .localOnly)
        defer { device.cleanup() }
        #expect(device.controller.isLocalOnly && !device.controller.isAvailable)
        await device.controller.start()
        await device.controller.turnOn()
        #expect(device.touched.value == 0)
        #expect(device.controller.isOn == false)
    }

    @Test func aBuildWithoutAContainerSaysNotAvailableAndTouchesNothingInICloud() async throws {
        let device = try CloudMacDevice(configured: false)
        defer { device.cleanup() }
        await device.controller.turnOn()
        #expect(device.controller.state == .notAvailableInThisBuild)
        #expect(device.controller.statusText == CloudSyncState.message(for: .notAvailableInThisBuild))
        #expect(await device.cloud.recordNames.isEmpty)
    }

    // MARK: first enable and the recovery words

    @Test func firstEnableSavesABackupAsksForRecoveryWordsChecksThreeAndSyncs() async throws {
        try await with { d in
            let note = try d.note("# One\n")
            await d.controller.start()
            await d.controller.turnOn()
            #expect(d.controller.recoveryPurpose == .firstSetup, "the first device decides about recovery words before keys exist")
            let offer = try #require(d.controller.recoveryOffer)
            #expect(offer.words.split(separator: " ").count == 24)
            #expect(offer.checkPositions.count == 3)
            #expect(await d.cloud.recordNames.filter { $0.hasPrefix("e.") }.isEmpty, "no note is sent before the recovery step is done")

            // wrong words: the sheet stays, the error is in plain words, nothing is created
            var wrong = d.words(of: offer)
            wrong[offer.checkPositions[0]] = "zzzz"
            #expect(await d.controller.confirmRecoveryWords(typed: wrong) == false)
            #expect(d.controller.recoverySheetError == CloudSyncStrings.sheetWrongWords)
            #expect(d.controller.recoveryOffer != nil)

            #expect(await d.controller.confirmRecoveryWords(typed: d.words(of: offer)))
            #expect(d.controller.recoveryOffer == nil)
            #expect(isUpToDate(d.controller.state), "state: \(d.controller.state)")
            #expect(d.controller.isOn)
            #expect(d.controller.recoveryState == .saved)
            #expect(d.controller.recoverySaved)
            #expect(await d.cloud.recordNames.contains("e.note.\(note.id)"))
            #expect(!(try LibraryBackup(database: d.environment.database, paths: d.environment.paths).localBackups().isEmpty), "a backup was made")
            await d.controller.shutdown()
        }
    }

    @Test func skipForNowNeedsTheRiskSentenceAndLeavesAReminder() async throws {
        try await with { d in
            try d.note("# One\n")
            await d.controller.turnOn()
            #expect(await d.controller.skipRecoveryWords(acknowledged: false) == false, "the button stays off until the sentence is ticked")
            #expect(d.controller.recoveryOffer != nil)
            #expect(await d.controller.skipRecoveryWords(acknowledged: true))
            #expect(isUpToDate(d.controller.state))
            #expect(d.controller.isOn)
            #expect(d.controller.recoveryState != .saved)
            #expect(d.controller.showsRecoveryReminder, "the Settings reminder shows while the words are not saved")
            #expect(d.controller.recoveryNudge, "one more offer after the first sync that worked")
            await d.controller.shutdown()
        }
    }

    @Test func cancellingTheRecoveryStepKeepsSyncOffAndCreatesNothing() async throws {
        try await with { d in
            try d.note("# One\n")
            await d.controller.turnOn()
            #expect(d.controller.recoveryOffer != nil)
            #expect(d.switchedOn, "the switch is on while the person decides about the words")
            #expect(d.controller.isOn)
            await d.controller.cancelRecoverySheet()
            #expect(d.controller.recoveryOffer == nil)
            #expect(d.controller.isOn == false)
            #expect(d.controller.state == .off)
            #expect(d.switchedOn == false)
            #expect(await d.cloud.recordNames.isEmpty, "nothing was saved in iCloud")
            #expect(d.controller.recoveryState == .none)
        }
    }

    @Test func recoveryWordsCanBeCreatedLaterAndReplacedAndTheWordsAreNeverKeyWords() async throws {
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
            #expect(d.controller.notice == CloudSyncStrings.recoveryReplaced)

            d.controller.beginCreateOrReplaceRecoveryWords()
            let second = try #require(d.controller.recoveryOffer)
            #expect(second.words != first.words)
            #expect(await d.controller.confirmRecoveryWords(typed: d.words(of: second)))
            #expect(d.controller.recoverySaved)
            #expect(CloudSyncStrings.replaceRecoveryDetail.contains("keep working"), "one sentence says set-up devices keep working")
            await d.controller.shutdown()
        }
    }

    @Test func aDeviceThatLostTheSetupRaceIsToldItsWordsProtectNothing() async throws {
        let cloud = FakeCloudKitAccount()
        let winner = try CloudMacDevice(cloud: cloud, keychain: InMemoryCloudKeychain())
        let loser = try CloudMacDevice(cloud: cloud, keychain: InMemoryCloudKeychain())
        defer { winner.cleanup(); loser.cleanup() }
        // Both Macs are switched on at the same time. The loser shows its words; before it confirms them the winner finishes.
        await loser.controller.turnOn()
        let offer = try #require(loser.controller.recoveryOffer)
        try await winner.turnOnAndSkip()
        #expect(winner.controller.lostSetupRace == false)

        #expect(await loser.controller.confirmRecoveryWords(typed: loser.words(of: offer)))
        #expect(loser.controller.lostSetupRace, "the words just confirmed belong to a setup that never happened")
        #expect(CloudSyncStrings.lostSetupRace.contains("recovery words shown on the other device"))
        #expect(loser.controller.canUseRecoveryWords, "the other device's words are the way in without iCloud Keychain")
        await loser.controller.dismissLostSetupRace()
        #expect(loser.controller.lostSetupRace == false)
        await winner.controller.shutdown(); await loser.controller.shutdown()
    }

    @Test func aSecondMacJoinsThroughICloudKeychainWithoutAskingForWords() async throws {
        let cloud = FakeCloudKitAccount(), keychain = InMemoryCloudKeychain()
        let first = try CloudMacDevice(cloud: cloud, keychain: keychain)
        let second = try CloudMacDevice(cloud: cloud, keychain: keychain)
        defer { first.cleanup(); second.cleanup() }
        let note = try first.note("# From the first Mac\n")
        try await first.turnOnAndSkip()
        await second.controller.turnOn()
        #expect(second.controller.recoveryOffer == nil)
        #expect(isUpToDate(second.controller.state), "state: \(second.controller.state)")
        #expect(second.text(of: note.id) == "# From the first Mac\n")
        await first.controller.shutdown(); await second.controller.shutdown()
    }

    @Test func aMacWithoutTheKeyAsksForTheWordsAndOpensWithThem() async throws {
        let cloud = FakeCloudKitAccount()
        let first = try CloudMacDevice(cloud: cloud, keychain: InMemoryCloudKeychain())
        let second = try CloudMacDevice(cloud: cloud, keychain: InMemoryCloudKeychain())
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

    // MARK: states

    @Test func aProtectedLibraryAsksForTheNotePasswordAsAStatusNotAnErrorThenBacksUpThenAsksForTheWords() async throws {
        try await with { d in
            let secret = try d.note("# Secret\nbody\n")
            try NotePrivacy(store: d.environment.store).setPassword("correct horse").lock(noteId: secret.id)
            await d.controller.turnOn()
            #expect(d.controller.state == .needsNotePassword)
            #expect(d.controller.needsNotePasswordInput)
            #expect(d.controller.recoveryOffer == nil, "the password comes before the recovery step")
            #expect(d.controller.problem == nil, "an action is offered, not an error")
            #expect(d.controller.headline == "Note password needed")
            await d.controller.submitNotePassword("wrong")
            #expect(d.controller.problem == CloudSyncStrings.notePasswordWrong)
            #expect(d.backupCount == 0, "the backup waits for the right password")
            await d.controller.submitNotePassword("correct horse")
            let offer = try #require(d.controller.recoveryOffer, "the right password leads to the recovery step")
            #expect(d.backupCount == 1, "the backup is made before the words are asked for")
            #expect(await d.cloud.recordNames.isEmpty)
            #expect(await d.controller.confirmRecoveryWords(typed: d.words(of: offer)))
            #expect(isUpToDate(d.controller.state), "state: \(d.controller.state)")
            #expect(d.controller.needsNotePasswordInput == false)
            #expect(d.backupCount == 1, "one backup serves the whole first sync")
            #expect(await d.cloud.recordNames.contains("e.note.\(secret.id)"))
            await d.controller.shutdown()
        }
    }

    /// A protected library whose person typed the right password: the controller holds it for the step after the recovery sheet.
    private func holdingThePassword(_ d: CloudMacDevice) async throws {
        let secret = try d.note("# Secret\nbody\n")
        try NotePrivacy(store: d.environment.store).setPassword("correct horse").lock(noteId: secret.id)
        await d.controller.turnOn()
        await d.controller.submitNotePassword("correct horse")
        #expect(d.controller.recoveryOffer != nil)
        #expect(d.controller.holdsNotePassword, "held while the sheet is open")
    }

    @Test func theHeldNotePasswordIsLetGoOnShutdown() async throws {
        try await with { d in
            try await holdingThePassword(d)
            await d.controller.shutdown()
            #expect(!d.controller.holdsNotePassword)
        }
    }

    @Test func theHeldNotePasswordIsLetGoWhenSyncIsSwitchedOff() async throws {
        try await with { d in
            try await holdingThePassword(d)
            await d.controller.stopSyncing()
            #expect(!d.controller.holdsNotePassword)
        }
    }

    @Test func theHeldNotePasswordIsLetGoOnAnAccountChange() async throws {
        try await with { d in
            try await holdingThePassword(d)
            d.controller.apply(.accountChanged(previousHash: "x"))      // what the coordinator's state stream delivers
            #expect(!d.controller.holdsNotePassword)
            #expect(d.controller.recoveryOffer == nil, "the setup stops; the account sheet asks")
            #expect(d.controller.showsAccountChangedSheet)
        }
    }

    @Test func theHeldNotePasswordIsLetGoWhenTheSheetIsCancelledAndWhenTheAppTerminates() async throws {
        try await with { d in
            try await holdingThePassword(d)
            await d.controller.cancelRecoverySheet()
            #expect(!d.controller.holdsNotePassword)
        }
        try await with { d in
            try await holdingThePassword(d)
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
            #expect(!d.controller.holdsNotePassword)
            await d.controller.shutdown()
        }
    }

    @Test func theHeldNotePasswordIsUsedOnceAndThenGone() async throws {
        try await with { d in
            try await holdingThePassword(d)
            let offer = try #require(d.controller.recoveryOffer)
            #expect(await d.controller.confirmRecoveryWords(typed: d.words(of: offer)))
            #expect(!d.controller.holdsNotePassword, "the enable that follows the sheet took it and let it go")
            #expect(isUpToDate(d.controller.state), "state: \(d.controller.state)")
            await d.controller.shutdown()
        }
    }

    @Test func aHeldSecretIsZeroedWhenLetGo() {
        let secret = HeldSecret("correct horse")
        #expect(secret.string() == "correct horse")
        secret.zero()
        #expect(secret.isEmpty && secret.snapshot.isEmpty && secret.string() == "")
    }

    @Test func theBackupIsMadeBeforeTheRecoverySheetAppearsAndNotAgainAfterIt() async throws {
        try await with { d in
            try d.note("# One\n")
            #expect(d.backupCount == 0)
            await d.controller.turnOn()
            let offer = try #require(d.controller.recoveryOffer)
            #expect(d.backupCount == 1, "Saving a backup first is true: it is done before the words are shown")
            #expect(await d.cloud.recordNames.isEmpty, "no key and no note in iCloud while the sheet is open")
            #expect(d.backend == SyncBackend.none)
            #expect(await d.controller.confirmRecoveryWords(typed: d.words(of: offer)))
            #expect(d.backupCount == 1)
            await d.controller.shutdown()
        }
    }

    @Test func offlineQuotaAndRestrictedShowTheirWordsAndRecover() async throws {
        try await with { d in
            let note = try d.note("# One\n")
            try await d.turnOnAndSkip()
            await d.fake.failNext(.offline)
            _ = try d.environment.store.updateText(id: note.id, text: "# One\nmore\n", expectedRevision: note.revision)
            await d.controller.syncNow()
            if case .offline = d.controller.state {} else { Issue.record("expected offline, got \(d.controller.state)") }
            #expect(d.controller.statusText == "You are offline. Sync will try again by itself.")

            await d.controller.syncNow()
            #expect(isUpToDate(d.controller.state))

            await d.fake.setQuota(bytes: 1)
            await d.fake.failNext(.quotaExceeded)
            let current = try #require(try d.environment.store.note(id: note.id))
            _ = try d.environment.store.updateText(id: note.id, text: "# One\n" + String(repeating: "x", count: 4_000), expectedRevision: current.revision)
            await d.controller.syncNow()
            #expect(d.controller.state == .quotaFull, "state: \(d.controller.state), problem: \(d.controller.problem ?? "-")")
            #expect(d.controller.showsOpenICloudSettings)
            #expect(d.controller.headline == "iCloud storage is full")
            await d.fake.setQuota(bytes: nil)

            await d.fake.restrict()
            #expect(await d.eventually { d.controller.state == .restricted }, "state: \(d.controller.state)")
            #expect(d.controller.showsOpenICloudSettings)
            await d.controller.shutdown()
        }
    }

    @Test func signedOutAndTheKeychainStatesAreShownAndOfferTheSettingsLink() async throws {
        try await with { d in
            try d.note("# One\n")
            await d.fake.signOut()
            await d.controller.turnOn()
            #expect(d.controller.state == .signedOutOfICloud)
            #expect(d.controller.showsOpenICloudSettings)
            #expect(d.controller.problem == nil)
        }
        try await with { d in
            d.seeds.simulate(status: -25308)
            await d.controller.turnOn()
            #expect(d.controller.state == .keychainUnavailable, "state: \(d.controller.state), problem: \(d.controller.problem ?? "-"), offer: \(d.controller.recoveryOffer != nil)")
            #expect(d.controller.showsOpenICloudSettings)
            #expect(d.controller.statusText.contains("iCloud Keychain"))
        }
    }

    @Test func aSecondMacWaitingForTheKeychainSaysSoAndSyncsOnceTheKeyArrives() async throws {
        let cloud = FakeCloudKitAccount()
        let first = try CloudMacDevice(cloud: cloud, keychain: InMemoryCloudKeychain())
        let second = try CloudMacDevice(cloud: cloud, keychain: InMemoryCloudKeychain())
        defer { first.cleanup(); second.cleanup() }
        let note = try first.note("# One\n")
        try await first.turnOnAndSkip()
        await second.controller.turnOn()
        #expect(second.controller.state == .waitingForKeychain || second.controller.needsRecoveryWords, "state: \(second.controller.state)")
        let account = try #require(try first.store.keyState().accountId)
        try second.seeds.saveSeed(try #require(try first.seeds.seed(accountId: account)), accountId: account)
        await second.controller.syncNow()
        #expect(isUpToDate(second.controller.state), "state: \(second.controller.state)")
        #expect(second.text(of: note.id) == "# One\n")
        await first.controller.shutdown(); await second.controller.shutdown()
    }

    @Test func aRemovedSyncedCopyIsReportedAndUploadAgainMakesItAgain() async throws {
        try await with { d in
            let note = try d.note("# One\n")
            try await d.turnOnAndSkip()
            await d.cloud.removeZone(reason: .userDeletedZone)
            await d.fake.pushRemoteChange()
            #expect(await d.eventually { d.controller.canUploadAgain }, "state: \(d.controller.state)")
            #expect(d.controller.headline == "iCloud copy removed")
            #expect(await d.cloud.recordNames.isEmpty, "nothing creates it again by itself")
            await d.controller.uploadAgain()
            #expect(d.controller.canUploadAgain == false)
            #expect(isUpToDate(d.controller.state), "uploaded again: \(d.controller.state)")
            #expect(await d.cloud.recordNames.contains("e.note.\(note.id)"))
            #expect(await d.cloud.recordNames.contains(CloudRecordCodec.keyBundleRecordName), "the key is back, a new device can join")
            #expect(d.text(of: note.id) == "# One\n")
            await d.controller.shutdown()
        }
    }

    @Test func uploadAgainWithoutTheVerifiedKeyExplainsAndChangesNothing() async throws {
        try await with { d in
            try d.note("# One\n")
            try await d.turnOnAndSkip()
            await d.cloud.removeZone(reason: .userDeletedZone)
            await d.fake.pushRemoteChange()
            #expect(await d.eventually { d.controller.canUploadAgain })
            try await d.environment.database.pool.write { try $0.execute(sql: "UPDATE ck_state SET keyBundleCache=NULL") }
            await d.controller.uploadAgain()
            #expect(d.controller.problem == CloudSyncStrings.uploadAgainNeedsKey)
            #expect(d.controller.canUploadAgain, "still offered; nothing was half made")
            #expect(await d.cloud.recordNames.isEmpty)
            await d.controller.shutdown()
        }
    }

    @Test func deletingTheCopyAfterTheAccountChangedExplainsAndChangesNothing() async throws {
        try await with { d in
            let note = try d.note("# Mine\n")
            try await d.turnOnAndSkip()
            let other = FakeCloudKitAccount(user: "someone-else")
            let stranger = try CloudMacDevice(cloud: other, keychain: InMemoryCloudKeychain())
            defer { stranger.cleanup() }
            try stranger.note("# Theirs\n")
            try await stranger.turnOnAndSkip()
            let theirs = Set(await other.recordNames)
            await d.fake.switchAccount(to: other)
            await d.controller.deleteICloudCopy()
            #expect(d.controller.problem == CloudSyncStrings.accountNotCurrent)
            #expect(Set(await other.recordNames) == theirs, "the other account was not touched")
            #expect(d.text(of: note.id) == "# Mine\n")
            #expect(d.backend == SyncBackend.cloudkit)
        }
    }

    @Test func removeKeyWordsDoNotOverpromise() {
        for recoverySaved in [true, false] {
            let text = CloudSyncStrings.removeKeyMessage(recoverySaved: recoverySaved).lowercased()
            #expect(text.contains("asks icloud keychain"))
            #expect(text.contains("offline"), "offline devices remove it later")
            #expect(text.contains("restart"), "open devices may keep it until they restart")
            #expect(!text.contains("nothing can open"))
        }
        #expect(!CloudSyncStrings.removeKeyDone.lowercased().contains("was removed from"))
        #expect(CloudSyncStrings.removeKeyDone.contains("asked iCloud Keychain"))
        #expect(!CloudSyncStrings.removeKeyTitle.lowercased().contains("nothing"))
    }

    @Test func notesMissingInICloudAreShownAndUploadThemAgainPutsThemBack() async throws {
        try await with { d in
            let note = try d.note("# Gone\n")
            try await d.turnOnAndSkip()
            await d.cloud.removeRecord("e.note.\(note.id)")
            await d.controller.syncNow()
            await d.fake.pushRemoteChange()
            await d.controller.syncNow()
            #expect(d.controller.missingCount == 1, "state: \(d.controller.state)")
            #expect(d.controller.headline == "Some notes are missing in iCloud")
            await d.controller.uploadThemAgain()
            #expect(d.controller.missingCount == nil, "state: \(d.controller.state), problem: \(d.controller.problem ?? "-")")
            #expect(await d.cloud.recordNames.contains("e.note.\(note.id)"))
            #expect(d.text(of: note.id) == "# Gone\n")
            await d.controller.shutdown()
        }
    }

    @Test func theKeyFailuresHavePlainSentencesOfTheirOwn() {
        for kind in ["keyBundleUnreadable", "keyRollback", "keyMismatch", "keyBundleMissing", "keys"] {
            let text = CloudSyncStrings.status(for: .failed(kind: kind))
            #expect(text != CloudSyncState.message(for: .failed(kind: kind)), "\(kind) says more than 'ran into a problem'")
            #expect(text.contains("Nothing was changed"), "\(kind): \(text)")
        }
        #expect(CloudSyncStrings.status(for: .failed(kind: "something else")) == CloudSyncState.message(for: .failed(kind: "something else")))
    }

    // MARK: account change

    @Test func aDifferentAccountPausesAndKeepOfflineIsTheDefault() async throws {
        try await with { d in
            let note = try d.note("# Mine\n")
            try await d.turnOnAndSkip()
            let other = FakeCloudKitAccount(user: "someone-else")
            await d.fake.switchAccount(to: other)
            #expect(await d.eventually { d.controller.accountChanged }, "state: \(d.controller.state)")
            #expect(d.controller.showsAccountChangedSheet, "the sheet asks")
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
            // the new account has no keys yet: the recovery step comes again, for the new account
            #expect(d.controller.recoveryPurpose == .firstSetup, "state: \(d.controller.state), problem: \(d.controller.problem ?? "-")")
            #expect(await d.controller.skipRecoveryWords(acknowledged: true))
            #expect(isUpToDate(d.controller.state), "state: \(d.controller.state)")
            #expect(await other.recordNames.contains("e.note.\(note.id)"))
            #expect(d.controller.showsAccountChangedSheet == false)
            await d.controller.shutdown()
        }
    }

    // MARK: stop, delete, remove the key

    @Test func stopSyncingStopsThisMacAndDeletesNothing() async throws {
        try await with { d in
            let note = try d.note("# One\n")
            try await d.turnOnAndSkip()
            let records = await d.cloud.recordNames
            await d.controller.stopSyncing()
            #expect(d.controller.isOn == false)
            #expect(d.controller.state == .off)
            #expect(await d.cloud.recordNames == records, "nothing in iCloud was deleted")
            #expect(d.text(of: note.id) == "# One\n")
            #expect(d.controller.isBoundToICloud, "the copy and the key are still there for a later switch-on")
            // and it can be turned on again without a second recovery step
            await d.controller.turnOn()
            #expect(isUpToDate(d.controller.state), "state: \(d.controller.state)")
            #expect(d.controller.recoveryOffer == nil)
            await d.controller.shutdown()
        }
    }

    @Test func deleteMyICloudCopyDeletesTheCopyAndKeepsThisMacsNotes() async throws {
        try await with { d in
            let note = try d.note("# Mine\n")
            try await d.turnOnAndSkip()
            #expect(await d.cloud.recordNames.isEmpty == false)
            await d.controller.deleteICloudCopy()
            #expect(await d.cloud.recordNames.isEmpty)
            #expect(d.text(of: note.id) == "# Mine\n")
            #expect(d.controller.isOn == false)
            #expect(d.controller.notice == CloudSyncStrings.deleteCopyDone)
            #expect(CloudSyncStrings.deleteCopyMessage.contains("notes on this Mac stay"), "the confirmation names what is deleted and what stays")
            #expect(d.controller.isBoundToICloud == false)
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
            #expect(d.controller.notice == CloudSyncStrings.removeKeyDone)
        }
    }

    // MARK: private server, vault conversion, words

    @Test func aLibraryBoundToThePrivateServerSaysSoAndNeverStartsICloud() async throws {
        try await with { d in
            try await d.environment.database.pool.write { try $0.execute(sql: "UPDATE sync_control SET backend='cloudflare' WHERE id=1") }
            await d.controller.start()
            #expect(d.controller.boundToPrivateServer)
            #expect(CloudSyncStrings.privateServerLibrary == "This library syncs through your private server")
            await d.controller.turnOn()
            #expect(d.controller.problem == CloudSyncStrings.privateServerLibrary, "the coordinator refuses and the person is told why")
            #expect(d.backend == SyncBackend.cloudflare)
            #expect(await d.cloud.recordNames.isEmpty)
        }
    }

    // MARK: move this library to iCloud

    /// The private-server binding as the old engine leaves it after a finished sync: an account, uploads on, empty queue.
    private func bindToPrivateServer(_ d: CloudMacDevice) async throws {
        try await d.environment.database.pool.write { try $0.execute(sql: "UPDATE sync_control SET accountId='server-account', enabled=1 WHERE id=1") }
        #expect(d.backend == SyncBackend.cloudflare)
    }

    @Test func aPrivateServerLibraryOffersTheMoveAndAfterItICloudIsSwitchedOn() async throws {
        try await with { d in
            let note = try d.note("# Years of notes\nkept")        // already on the server: nothing left to send
            try await bindToPrivateServer(d)
            let finalSyncs = CloudTouchCounter()
            d.controller.leavePrivateServer = { _ in
                let environment = d.environment
                try await PrivateServerMove.run(database: environment.database, paths: environment.paths, finalSync: { finalSyncs.hit() },
                                                makeBackup: { try await MacCloudSyncLibrary(environment: environment).makeBackup() })
            }
            await d.controller.start()
            #expect(d.controller.boundToPrivateServer && d.controller.canMoveToICloud)
            let backups = d.backupCount
            await d.controller.moveToICloud()
            #expect(finalSyncs.value == 1)
            #expect(d.controller.problem == nil, "\(d.controller.problem ?? "")")
            #expect(d.backupCount > backups, "a backup is saved before the library lets go")
            #expect(try PrivateServerMove.hasLeft(d.environment.database))
            #expect(!d.controller.boundToPrivateServer)
            #expect(d.controller.problem == nil)
            #expect(d.controller.recoveryOffer != nil, "the normal switch-on follows: first device of this iCloud account")
            #expect(await d.controller.skipRecoveryWords(acknowledged: true))
            #expect(d.backend == SyncBackend.cloudkit)
            #expect(d.controller.showsMoveNotice, "move your other devices now: stays after the switch-on")
            d.controller.dismissMoveNotice()
            #expect(!d.controller.showsMoveNotice, "gone only when the owner dismisses it")
            #expect(d.text(of: note.id) == "# Years of notes\nkept")
            #expect(await d.cloud.recordNames.contains("e.note.\(note.id)"))
        }
    }

    /// Design r3: the move finished but the iCloud switch-on did not; the tab says so next to the notice until iCloud sync runs.
    @Test func aMoveWhoseICloudSwitchOnFailsSaysSoNextToTheNotice() async throws {
        try await with { d in
            try await bindToPrivateServer(d)
            d.controller.leavePrivateServer = { _ in
                let environment = d.environment
                try await PrivateServerMove.run(database: environment.database, paths: environment.paths, finalSync: {},
                                                makeBackup: { try await MacCloudSyncLibrary(environment: environment).makeBackup() })
            }
            await d.controller.start()
            await d.fake.signOut()
            await d.controller.moveToICloud()
            #expect(try PrivateServerMove.hasLeft(d.environment.database), "the move itself finished")
            #expect(d.controller.state == .signedOutOfICloud && d.controller.showsMoveNotice)
            #expect(d.controller.moveSyncNotStarted == CloudSyncStrings.moveSyncBlocked)
            await d.controller.stopSyncing()
            #expect(d.controller.moveSyncNotStarted == CloudSyncStrings.moveSyncOff)
            await d.fake.signIn(user: d.cloud)
            await d.controller.turnOn()
            #expect(d.controller.moveSyncNotStarted == nil, "no warning while the recovery-word step is open")
            #expect(await d.controller.skipRecoveryWords(acknowledged: true))
            #expect(d.controller.moveSyncNotStarted == nil, "iCloud sync runs: the line goes")
        }
    }

    @Test func aRefusedMoveChangesNothingAndSaysWhy() async throws {
        let refusals: [(Error, String)] = [
            (PrivateServerMoveRefusal.unsentChanges(2), CloudSyncStrings.moveUnsent(2)),
            (PrivateServerMoveRefusal.unavailableAttachments(notes: ["Plans", "Trip"], moreNotes: 4, canMoveWithout: false), CloudSyncStrings.moveUnavailable(notes: ["Plans", "Trip"], moreNotes: 4)),
            (PrivateServerMoveRefusal.unreceivedChanges(1), CloudSyncStrings.moveUnreceived(1)),
            (PrivateServerMoveRefusal.notConnected, CloudSyncStrings.moveNotConnected),
            (PrivateServerMoveRefusal.syncPaused, CloudSyncStrings.movePaused),
            (PrivateServerMoveRefusal.firstSyncNotFinished, CloudSyncStrings.moveFirstSyncUnfinished),
            (PrivateServerMoveRefusal.lockOrUnlockInProgress, CloudSyncStrings.moveBusy),
            (URLError(.notConnectedToInternet), CloudSyncStrings.moveOffline),
            (SyncAccountDetachError.backupNotVerified, CloudSyncStrings.backupFailed),
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

    /// The card's words, the same on Mac and iOS; six notes list five titles and "and 1 more", one per line.
    @Test func theMissingFilesCardSaysWhatHappensInShortLines() {
        let text = CloudSyncStrings.moveUnavailable(notes: ["A", "B", "C", "D", "E"], moreNotes: 1, canMoveWithout: true)
        #expect(text.split(separator: "\n").map(String.init) == [
            "Some Attachments Are Missing", "6 notes link to files that never reached this device or your private server:",
            "A", "B", "C", "D", "E", "and 1 more",
            "You can move without these files. The notes move as they are and keep showing the missing file.", "Nothing has been moved yet.",
        ])
        #expect(CloudSyncStrings.missingFilesCount(1) == "1 note links to one or more files that never reached this device or your private server:")
        #expect(CloudSyncStrings.moveWithoutFilesButton == "Move to iCloud Without These Files…")
        #expect(CloudSyncStrings.moveWithoutFilesMessage == CloudSyncStrings.moveMessage + "\n\nThe missing attachment files stay missing.")
    }

    /// The refusal names notes whose files no device and no server ever had; "Move to iCloud Without These Files…" then moves.
    @Test func missingFilesNoDeviceHadOfferMoveWithoutTheseFilesWhichMoves() async throws {
        try await with { d in
            let note = try d.note("# Imported cover\nkept")
            try await bindToPrivateServer(d)
            let asked = LockedFlags()
            let library = d.environment
            d.controller.leavePrivateServer = { withoutMissingFiles in
                asked.append(withoutMissingFiles)
                guard withoutMissingFiles else {
                    throw PrivateServerMoveRefusal.unavailableAttachments(notes: ["Imported cover"], moreNotes: 0, canMoveWithout: true)
                }
                try await PrivateServerMove.run(database: library.database, paths: library.paths, finalSync: {},
                                                makeBackup: { try await MacCloudSyncLibrary(environment: library).makeBackup() }, withoutMissingFiles: true)
            }
            await d.controller.start()
            await d.controller.moveToICloud()
            #expect(d.controller.problem == CloudSyncStrings.moveUnavailable(notes: ["Imported cover"], moreNotes: 0, canMoveWithout: true))
            #expect(d.controller.canMoveWithoutMissingFiles && d.backend == SyncBackend.cloudflare, "refused first, nothing moved")
            #expect(d.controller.missingFilesToLeave?.notes == ["Imported cover"] && d.controller.missingFilesToLeave?.moreNotes == 0, "the card lists the note")
            await d.controller.moveWithoutMissingFiles()
            #expect(asked.values == [false, true])
            #expect(d.controller.problem == nil && !d.controller.canMoveWithoutMissingFiles)
            #expect(try PrivateServerMove.hasLeft(library.database) && !d.controller.boundToPrivateServer)
            #expect(d.text(of: note.id) == "# Imported cover\nkept")
        }
    }

    /// Another reason is shown first; once it is gone the missing-files message with the button comes back.
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
            #expect(d.controller.problem == CloudSyncStrings.moveUnsent(1), "the person reads the reason that blocks now")
            #expect(!d.controller.canMoveWithoutMissingFiles)
            await d.controller.moveToICloud()
            #expect(d.controller.problem == CloudSyncStrings.moveUnavailable(notes: ["Imported cover"], moreNotes: 0, canMoveWithout: true))
            #expect(d.controller.canMoveWithoutMissingFiles)
        }
    }

    @Test func missingFilesTheServerHadOfferNoSecondButton() async throws {
        try await with { d in
            try await bindToPrivateServer(d)
            d.controller.leavePrivateServer = { _ in throw PrivateServerMoveRefusal.unavailableAttachments(notes: ["Plans"], moreNotes: 0, canMoveWithout: false) }
            await d.controller.start()
            await d.controller.moveToICloud()
            #expect(d.controller.problem == CloudSyncStrings.moveUnavailable(notes: ["Plans"], moreNotes: 0))
            #expect(!d.controller.canMoveWithoutMissingFiles)
        }
    }

    @Test func theMoveIsOfferedOnlyWithThePrivateServerSideAndTheICloudFlag() async throws {
        try await with { d in
            try await bindToPrivateServer(d)
            await d.controller.start()
            #expect(d.controller.boundToPrivateServer && !d.controller.canMoveToICloud, "no private-server side in this build")
        }
        let off = try CloudMacDevice(flag: false); defer { off.cleanup() }
        try await bindToPrivateServer(off)
        off.controller.leavePrivateServer = { _ in }
        #expect(!off.controller.canMoveToICloud, "a build without iCloud sync has nothing to move to")
        #expect(CloudSyncStrings.privateServerDetail.contains("not available yet") == false)
        #expect(!CloudSyncStrings.all.contains { $0.contains("  ") }, "no runs of spaces in any string")
    }

    @Test func vaultConversionWhileSyncIsOnAsksToTurnSyncOffFirst() {
        #expect(CloudSyncController.message(for: CloudVaultConversionError.syncMustBeOff) == CloudSyncStrings.turnSyncOffFirst)
        #expect(CloudSyncStrings.turnSyncOffFirst.contains("Turn iCloud sync off first"))
    }

    @Test func errorMessagesNeverPrintInternalNames() {
        struct Odd: Error, CustomStringConvertible { var description: String { "CKError zone record token" } }
        let text = CloudSyncController.message(for: Odd())
        #expect(text == CloudSyncStrings.genericProblem)
    }

    @Test func noWordOfTheTabOrItsSheetsUsesABannedWord() throws {
        for text in CloudSyncStrings.all {
            let lower = text.lowercased()
            for banned in CloudSyncStrings.bannedWords {
                #expect(!lower.contains(banned), "“\(text)” contains “\(banned)”")
            }
        }
        // Every status the person can see, not only the ones the tab rewrites.
        for state in [CloudSyncState.needsRecoveryKey, .recoveryNotSaved, .needsNotePassword] {
            #expect(!CloudSyncStrings.status(for: state).lowercased().contains("recovery key"))
        }
        // The views carry no wording of their own beyond the strings file: banned words, and no fixed text in a string literal at all
        // (accessibility labels included). What may stay: identifiers, symbol names, URLs, interpolations of strings-file values.
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Sync")
        for file in ["CloudSyncSettingsView.swift", "CloudRecoveryKeySheet.swift", "CloudAccountChangedSheet.swift"] {
            let source = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
            for banned in CloudSyncStrings.bannedWords { #expect(!source.lowercased().contains(banned), "\(file) contains “\(banned)”") }
            #expect(Self.hardCodedWording(in: source).isEmpty, "\(file) has wording outside the strings file: \(Self.hardCodedWording(in: source))")
        }
    }

    /// String literals with fixed words in them, minus the code-ish ones (ids like "cloud-sync-switch", symbol names like "icloud.slash",
    /// URLs). Comments are skipped.
    static func hardCodedWording(in source: String) -> [String] {
        var found: [String] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let code = line.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            var rest = Substring(code)
            while let open = rest.firstIndex(of: "\"") {
                let after = rest[rest.index(after: open)...]
                guard let close = after.firstIndex(of: "\"") else { break }
                let literal = String(after[..<close])
                rest = after[after.index(after: close)...]
                var fixed = literal
                while let start = fixed.range(of: "\\(") {
                    guard let end = fixed[start.upperBound...].firstIndex(of: ")") else { break }
                    fixed.removeSubrange(start.lowerBound...end)
                }
                let codeish = fixed.allSatisfy { $0.isLowercase || $0.isNumber || ".-_:".contains($0) } || fixed.hasPrefix("x-apple.")
                if !codeish && fixed.contains(where: \.isLetter) { found.append(literal) }
            }
        }
        return found
    }
}
