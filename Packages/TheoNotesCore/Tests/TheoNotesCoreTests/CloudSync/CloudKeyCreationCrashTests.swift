// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import Testing
@testable import TheoNotesCore

/// First-device key creation (CK-R14): order, crash resumption, races, lost responses, the recovery choice and the
/// data-save gate.
@Suite struct CloudKeyCreationCrashTests {
    enum Outcome: Equatable { case running, completed(String), lost(String) }

    /// Runs the device's next step: `begin` first, then one `advance` each.
    func step(_ device: KeyDevice, _ choice: RecoveryChoice, started: inout Bool, outcome: inout Outcome) async throws {
        guard outcome == .running else { return }
        if !started { try await device.creation.begin(choice); started = true; return }
        switch try await device.creation.advance() {
        case .completed(let account): outcome = .completed(account)
        case .lost(let winner): outcome = .lost(winner)
        case .idle: Issue.record("idle while running")
        default: break
        }
    }

    @Test func twoFirstDevicesOneBundleWins() async throws {
        let wordsA = try KeyTest.knownRecovery()
        let schedules = KeyTest.interleavings(5, 5)
        #expect(schedules.count == 252)
        for schedule in schedules {
            let cloud = FakeCloudKitAccount(), keychain = InMemoryCloudKeychain()
            let a = try await KeyDevice.make(cloud: cloud, keychain: keychain)
            let b = try await KeyDevice.make(cloud: cloud, keychain: keychain)
            var startedA = false, startedB = false
            var outA = Outcome.running, outB = Outcome.running
            for pickA in schedule {
                if pickA { try await step(a, wordsA.choice, started: &startedA, outcome: &outA) }
                else { try await step(b, .acknowledgedRisk, started: &startedB, outcome: &outB) }
            }
            #expect(outA != .running && outB != .running, "five steps finish each device")

            let winner: KeyDevice, loser: KeyDevice, winnerAccount: String
            switch (outA, outB) {
            case (.completed(let x), .lost(let y)) where x == y: (winner, loser, winnerAccount) = (a, b, x)
            case (.lost(let y), .completed(let x)) where x == y: (winner, loser, winnerAccount) = (b, a, x)
            default: Issue.record("expected exactly one winner, got \(outA) and \(outB) for \(schedule)"); continue
            }
            let bundle = try #require(try await winner.bundles.fetch()).bundle
            #expect(bundle.accountId == winnerAccount)
            #expect(await cloud.versionCount(of: "keybundle") == 1)
            // Only the bundle record was ever saved, by either device.
            let names = await a.savedNames + b.savedNames
            #expect(names.allSatisfy { $0 == "keybundle" })
            // The loser removed only its own seed; the winner's seed is on both devices.
            let removals = keychain.log.filter { $0.contains(":remove:") }
            #expect(removals.count == 1)
            #expect(removals.allSatisfy { !$0.hasSuffix(":remove:\(winnerAccount)") })
            #expect(try KeyTest.hasSeed(winner.seeds, winnerAccount))
            #expect(try KeyTest.hasSeed(loser.seeds, winnerAccount))
            #expect(try KeyTest.noPending(loser.seeds))
            #expect(try loser.state.keyState().recovery == .none)
            #expect(try loser.creation.isComplete == false)
            #expect(try winner.creation.isComplete)
            // The loser joins the winner and gets the same vault key.
            let keysW = try await winner.readyKeys(), keysL = try await loser.readyKeys()
            do { let sameKeys = KeyTest.same(keysW.vaultKey, keysL.vaultKey); #expect(sameKeys) }
            #expect(try loser.creation.isComplete)
        }
    }

    @Test func crashAtEachStepOfFirstDeviceCreationResumes() async throws {
        let boundaries = ["keys.afterProbe", "keys.afterPending", "keys.afterSeed", "keys.beforeBundle", "keys.afterBundleWritten",
                          "keys.afterBundle", "keys.afterRecoveryState", "keys.afterPendingCleared"]
        let words = try KeyTest.knownRecovery()
        for boundary in boundaries {
            let cloud = FakeCloudKitAccount(), keychain = InMemoryCloudKeychain()
            let device = try await KeyDevice.make(cloud: cloud, keychain: keychain)
            device.crash.arm(boundary)
            await #expect(throws: CrashInjected(boundary: boundary)) { _ = try await device.creation.run(words.choice) }
            let accountAtCrash = try device.seeds.pending()?.accountId

            let restarted = try await device.restarted(cloud: cloud)
            if try restarted.creation.isComplete == false {
                guard case .created(let account) = try await restarted.creation.run(words.choice) else {
                    Issue.record("not created after \(boundary)"); continue
                }
                if let accountAtCrash { #expect(account == accountAtCrash, "resumes with the same keys after \(boundary)") }
            }
            #expect(try restarted.creation.isComplete)
            #expect(try KeyTest.noPending(restarted.seeds))
            #expect(await cloud.versionCount(of: "keybundle") == 1, "one bundle after \(boundary)")
            let bundle = try #require(try await restarted.bundles.fetch()).bundle
            if let accountAtCrash { #expect(bundle.accountId == accountAtCrash) }
            #expect(try restarted.state.keyState().summary == "saved/1")
            // Seed, bundle and recovery words all lead to the same vault key.
            let other = try await KeyDevice.make(cloud: cloud, keychain: keychain)
            let viaSeed = try await other.readyKeys()
            let viaWords = try await KeyDevice.make(cloud: cloud, keychain: InMemoryCloudKeychain()).joiner().join(recoveryWords: words.words)
            do { let sameKeys = KeyTest.same(viaSeed.vaultKey, viaWords.keys.vaultKey); #expect(sameKeys) }
        }
    }

    @Test func lostResponseOnBundleCreateResolvesByFetch() async throws {
        for report in [FakeCloudKitDevice.LostResponse.offline, .silence] {
            let cloud = FakeCloudKitAccount()
            let device = try await KeyDevice.make(cloud: cloud, keychain: InMemoryCloudKeychain())
            await device.fake.loseNextResponseAfterCommit(report: report)
            guard case .created(let account) = try await device.creation.run(.acknowledgedRisk) else { Issue.record("not created"); continue }
            #expect(await cloud.versionCount(of: "keybundle") == 1)
            #expect(await device.gateway.saves.count == 1, "the lost response was resolved by a fetch, not a second save")
            #expect(try #require(try await device.bundles.fetch()).bundle.accountId == account)
        }
        // Lost response while another device's bundle is there: the fetch shows the winner, this device joins it.
        let cloud = FakeCloudKitAccount(), keychain = InMemoryCloudKeychain()
        let first = try await KeyDevice.make(cloud: cloud, keychain: keychain)
        let second = try await KeyDevice.make(cloud: cloud, keychain: keychain)
        guard case .created(let winner) = try await first.creation.run(.acknowledgedRisk) else { Issue.record("not created"); return }
        await second.fake.loseNextResponseAfterCommit(report: .offline)
        #expect(try await second.creation.run(.acknowledgedRisk) == .anotherDeviceWon(accountId: winner))
        do { let sameKeys = KeyTest.same(try await second.readyKeys().vaultKey, try await first.readyKeys().vaultKey); #expect(sameKeys) }
        // The send itself failed (offline) and the fetch shows no bundle: nothing is lost, the next run finishes with
        // the same account.
        let third = FakeCloudKitAccount()
        let device = try await KeyDevice.make(cloud: third, keychain: InMemoryCloudKeychain())
        await device.fake.failNext(.offline)
        await #expect(throws: CloudKeyError.bundleNotWritten) { _ = try await device.creation.run(.acknowledgedRisk) }
        #expect(await third.versionCount(of: "keybundle") == 0)
        let pendingAccount = try device.seeds.pending()?.accountId
        #expect(try await device.creation.run(.acknowledgedRisk) == .created(accountId: try #require(pendingAccount)))
        #expect(await third.versionCount(of: "keybundle") == 1)
    }

    @Test func noDataRecordSavedBeforeCreationComplete() async throws {
        let cloud = FakeCloudKitAccount(), keychain = InMemoryCloudKeychain()
        let device = try await KeyDevice.make(cloud: cloud, keychain: keychain)
        let creation = device.creation
        #expect(try creation.isComplete == false)
        try await creation.begin(.acknowledgedRisk)
        var steps: [CloudKeyCreationStep] = []
        while true {
            #expect(try creation.isComplete == false, "incomplete before step \(steps.count + 2)")
            #expect(throws: CloudKeyError.creationIncomplete) { try creation.requireComplete(keys: KeyTest.dummyKeys) }
            let step = try await creation.advance()
            steps.append(step)
            if case .completed = step { break }
        }
        let account = try #require(try await device.bundles.fetch()).bundle.accountId
        #expect(steps == [.seedSaved, .bundleCreated, .recoveryStateSet, .completed(accountId: account)])
        let keys = try await device.readyKeys()
        try creation.requireComplete(keys: keys)
        // Keys of another account, or of this account but not matching the stored seed, are refused.
        #expect(throws: CloudKeyError.creationIncomplete) { try creation.requireComplete(keys: KeyTest.dummyKeys) }
        let impostor = try AccountKeys(accountID: account)
        #expect(throws: CloudKeyError.creationIncomplete) { try creation.requireComplete(keys: impostor) }
        #expect(await device.savedNames == ["keybundle"])

        // A device that lost the race never becomes complete through creation.
        let loser = try await KeyDevice.make(cloud: cloud, keychain: keychain)
        _ = try await loser.creation.run(.acknowledgedRisk)
        #expect(throws: CloudKeyError.creationIncomplete) { try loser.creation.requireComplete(keys: keys) }
        #expect(await loser.savedNames == ["keybundle"])
    }

    @Test func skipWithoutAcknowledgementIsRefused() async throws {
        #expect(throws: CloudKeyError.acknowledgementRequired) { _ = try RecoveryChoice.skip(acknowledged: false) }
        let skip = try RecoveryChoice.skip(acknowledged: true)
        #expect(!skip.isSaved && skip.offerId == nil)
        // A "saved" choice without the three confirmed words is not a way around it: an offer refuses an empty check.
        let device = try await KeyDevice.make(cloud: FakeCloudKitAccount(), keychain: InMemoryCloudKeychain())
        let offer = try RecoveryKeyOffer.make()
        #expect(throws: CloudKeyError.recoveryWordsNotConfirmed) { _ = try offer.confirm([:]) }
        #expect(try KeyTest.noPending(device.seeds))
        #expect(await device.gateway.saves.isEmpty)
        #expect(device.seeds.keychain.log.isEmpty, "not even the keychain probe ran")
    }

    @Test func skipWithAcknowledgementCreatesAnUnshownRandomRecoveryKey() async throws {
        let cloud = FakeCloudKitAccount()
        let device = try await KeyDevice.make(cloud: cloud, keychain: InMemoryCloudKeychain())
        try await device.creation.begin(try RecoveryChoice.skip(acknowledged: true))
        let pending = try #require(try device.seeds.pending())
        let stored = try #require(String(data: try JSONEncoder().encode(pending), encoding: .utf8))
        #expect(!stored.contains("words") && !stored.contains("recoveryKey"), "no recovery key is kept")
        let result = try await device.creation.run(.acknowledgedRisk)
        guard case .created = result else { Issue.record("not created"); return }
        #expect(try device.state.keyState().recovery == .acknowledgedSkip)
        let envelope = try #require(try await device.bundles.fetch()).bundle.envelope
        #expect(try SyncWire.decode64(envelope.recoveryPublicKey).count == 32)

        let other = try await KeyDevice.make(cloud: FakeCloudKitAccount(), keychain: InMemoryCloudKeychain())
        _ = try await other.creation.run(.acknowledgedRisk)
        let otherEnvelope = try #require(try await other.bundles.fetch()).bundle.envelope
        #expect(otherEnvelope.recoveryPublicKey != envelope.recoveryPublicKey, "a random key each time")
        // A recovery key can still be created afterwards.
        let later = try KeyTest.knownRecovery()
        #expect(try await device.rotation.createOrReplaceRecoveryKey(later.choice, keys: try await device.readyKeys()) == .replaced(revision: 2))
    }

    @Test func threeWordCheckRejectsWrongWords() async throws {
        let offer = try RecoveryKeyOffer.make()
        #expect(offer.checkPositions.count == 3 && Set(offer.checkPositions).count == 3)
        #expect(offer.checkPositions.allSatisfy { (0..<24).contains($0) })
        let list = offer.words.split(separator: " ").map(String.init)
        let right = Dictionary(uniqueKeysWithValues: offer.checkPositions.map { ($0, list[$0]) })
        var wrong = right; wrong[offer.checkPositions[1]] = list[offer.checkPositions[1]] == "zoo" ? "abandon" : "zoo"
        let two = Dictionary(uniqueKeysWithValues: offer.checkPositions.prefix(2).map { ($0, list[$0]) })
        var four = right
        if let extra = (0..<24).first(where: { right[$0] == nil }) { four[extra] = list[extra] }
        let outOfRange = [24: "abandon", 0: list[0], 1: list[1]]
        let device = try await KeyDevice.make(cloud: FakeCloudKitAccount(), keychain: InMemoryCloudKeychain())
        for confirmed in [wrong, two, four, outOfRange] {
            #expect(throws: CloudKeyError.recoveryWordsNotConfirmed) { _ = try offer.confirm(confirmed) }
        }
        #expect(try KeyTest.noPending(device.seeds))
        #expect(await device.gateway.saves.isEmpty)
        // Case and surrounding spaces do not matter.
        let relaxed = right.mapValues { "  " + $0.uppercased() + "\n" }
        let choice = try offer.confirm(relaxed)
        #expect(choice.isSaved && choice.offerId == offer.id)
        guard case .created = try await device.creation.run(choice) else { Issue.record("not created"); return }
        #expect(try device.state.keyState().recovery == .saved)
    }

    @Test func theConfirmationIsBoundToTheOfferedPositions() throws {
        let offer = try RecoveryKeyOffer(key: RecoveryKey(), checkPositions: [3, 9, 17])
        let list = offer.words.split(separator: " ").map(String.init)
        // Three correct words, but not the three the offer asked for.
        let otherPositions = Dictionary(uniqueKeysWithValues: [0, 1, 2].map { ($0, list[$0]) })
        #expect(throws: CloudKeyError.recoveryWordsNotConfirmed) { _ = try offer.confirm(otherPositions) }
        // Two of the asked positions plus one other correct word.
        let mixed = [3: list[3], 9: list[9], 18: list[18]]
        #expect(throws: CloudKeyError.recoveryWordsNotConfirmed) { _ = try offer.confirm(mixed) }
        // Every asked position is checked, not only the first.
        for wrongAt in [3, 9, 17] {
            var typed = [3: list[3], 9: list[9], 17: list[17]]
            typed[wrongAt] = list[wrongAt] == "zoo" ? "abandon" : "zoo"
            #expect(throws: CloudKeyError.recoveryWordsNotConfirmed) { _ = try offer.confirm(typed) }
        }
        let choice = try offer.confirm([3: list[3], 9: list[9], 17: list[17]])
        #expect(choice.offerId == offer.id)
        // Two offers of the same key are distinct offers.
        #expect(try RecoveryKeyOffer.make().id != RecoveryKeyOffer.make().id)
    }

    @Test func recoveryOfferedAgainLaterWhileNotSaved() async throws {
        let device = try await KeyDevice.make(cloud: FakeCloudKitAccount(), keychain: InMemoryCloudKeychain())
        #expect(!CloudRecoveryReminder.showsSettingsReminder(.none))
        _ = try await device.creation.run(.acknowledgedRisk)
        #expect(CloudRecoveryReminder.showsSettingsReminder(try device.state.keyState().recovery))
        try CloudRecoveryReminder.noteOfferShown(in: device.state)
        #expect(CloudRecoveryReminder.showsSettingsReminder(try device.state.keyState().recovery), "declining once keeps the reminder")
        let later = try KeyTest.knownRecovery()
        _ = try await device.rotation.createOrReplaceRecoveryKey(later.choice, keys: try await device.readyKeys())
        #expect(!CloudRecoveryReminder.showsSettingsReminder(try device.state.keyState().recovery))
    }

    @Test func recoveryOfferedOnceAfterFirstSuccessfulSync() async throws {
        let skipped = try await KeyDevice.make(cloud: FakeCloudKitAccount(), keychain: InMemoryCloudKeychain())
        _ = try await skipped.creation.run(.acknowledgedRisk)
        #expect(CloudRecoveryReminder.offersAfterFirstSuccessfulSync(try skipped.state.keyState().recovery))
        try CloudRecoveryReminder.noteOfferShown(in: skipped.state)
        #expect(!CloudRecoveryReminder.offersAfterFirstSuccessfulSync(try skipped.state.keyState().recovery), "only once")
        try CloudRecoveryReminder.noteOfferShown(in: skipped.state)
        #expect(try skipped.state.keyState().recovery == .pending)

        let saved = try await KeyDevice.make(cloud: FakeCloudKitAccount(), keychain: InMemoryCloudKeychain())
        _ = try await saved.creation.run(try KeyTest.knownRecovery().choice)
        #expect(!CloudRecoveryReminder.offersAfterFirstSuccessfulSync(try saved.state.keyState().recovery))
        try CloudRecoveryReminder.noteOfferShown(in: saved.state)
        #expect(try saved.state.keyState().recovery == .saved, "noting the offer never downgrades a saved key")
    }

    @Test func aLibraryWithKeysRefusesASecondCreation() async throws {
        let device = try await KeyDevice.make(cloud: FakeCloudKitAccount(), keychain: InMemoryCloudKeychain())
        _ = try await device.creation.run(.acknowledgedRisk)
        await #expect(throws: CloudKeyError.alreadyComplete) { try await device.creation.begin(.acknowledgedRisk) }
        #expect(try await device.creation.advance() == .idle)
    }

    // MARK: fix round 1

    @Test func completionNeedsTheMatchingDurableSeed() async throws {
        let cloud = FakeCloudKitAccount(), keychain = InMemoryCloudKeychain()
        let a = try await KeyDevice.make(cloud: cloud, keychain: keychain)
        guard case .created(let account) = try await a.creation.run(.acknowledgedRisk) else { Issue.record("not created"); return }
        #expect(try a.creation.isComplete)
        try a.seeds.removeSeed(accountId: account)
        #expect(try a.creation.isComplete == false, "no durable seed, no completion")

        // A recovery join whose seed could not be stored is not complete and changes no state.
        let cloud2 = FakeCloudKitAccount()
        let b = try await KeyDevice.make(cloud: cloud2, keychain: InMemoryCloudKeychain())
        let words = try KeyTest.knownRecovery()
        _ = try await b.creation.run(words.choice)
        let c = try await KeyDevice.make(cloud: cloud2, keychain: InMemoryCloudKeychain())
        c.seeds.simulate(status: -25308)
        let joined = try await c.joiner().join(recoveryWords: words.words)
        #expect(joined.seedStored == false)
        #expect(joined.blockedBy == .seedNotStored(.unavailable(.deviceLocked)))
        c.seeds.restoreAvailability()
        #expect(try c.state.keyState().recovery == .none)
        #expect(try c.state.keyState().accountId == nil)
        #expect(try c.creation.isComplete == false)
        #expect(throws: CloudKeyError.creationIncomplete) { try c.creation.requireComplete(keys: joined.keys) }

        // A different seed already stored under the pending account blocks creation before the bundle.
        let d = try await KeyDevice.make(cloud: FakeCloudKitAccount(), keychain: InMemoryCloudKeychain())
        let pendingAccount = try await d.creation.begin(.acknowledgedRisk)
        try d.seeds.saveSeed(KeyTest.bytes(SymmetricKey(size: .bits256)), accountId: pendingAccount)
        await #expect(throws: CloudKeyError.seedConflict) { _ = try await d.creation.run(.acknowledgedRisk) }
        #expect(await d.gateway.saves.isEmpty, "no bundle under a key this device does not hold")
        #expect(try d.creation.isComplete == false)
    }

    @Test func overlappingCallsOnOneDeviceCreateOneAccount() async throws {
        let cloud = FakeCloudKitAccount(), keychain = InMemoryCloudKeychain()
        let device = try await KeyDevice.make(cloud: cloud, keychain: keychain)
        let slow = SlowPendingSeeds(device.seeds)
        let creation = CloudKeyCreation(seeds: slow, probe: device.seeds, bundles: device.bundles, state: device.state)
        async let first = creation.run(.acknowledgedRisk)
        async let second = creation.run(.acknowledgedRisk)
        let results = try await [first, second]
        #expect(results[0] == results[1], "both calls finish the same creation")
        #expect(await cloud.versionCount(of: "keybundle") == 1)
        #expect(keychain.log.filter { $0.contains(":save:") }.count == 1, "one seed, one account")
        let account = try #require(try await device.bundles.fetch()).bundle.accountId
        let seedStored = try device.seeds.seed(accountId: account) != nil
        #expect(seedStored)
        #expect(try await device.readyKeys().accountID == account)
    }
}

extension CloudKeyCreationCrashTests {
    @Test func separatelyBuiltCreationJoinAndRotationForOneLibraryAreSerialised() async throws {
        let cloud = FakeCloudKitAccount(), keychain = InMemoryCloudKeychain()
        let device = try await KeyDevice.make(cloud: cloud, keychain: keychain)
        _ = try await device.creation.run(.acknowledgedRisk)
        let keys = try await device.readyKeys()
        let watched = OverlapDetectingState(device.state)
        let words = try KeyTest.knownRecovery()
        // Three objects built independently, as three parts of an app would, on the same library and keychain.
        let creation = CloudKeyCreation(seeds: device.seeds, probe: device.seeds, bundles: device.bundles, state: watched)
        let join = CloudKeyJoin(seeds: device.seeds, probe: device.seeds, bundles: device.bundles, state: watched)
        let rotation = CloudRecoveryRotation(seeds: device.seeds, bundles: device.bundles, state: watched)
        async let created = creation.run(.acknowledgedRisk)
        async let evaluated = join.evaluate()
        async let rotated = rotation.createOrReplaceRecoveryKey(words.choice, keys: keys)
        let (c, e, r) = try await (created, evaluated, rotated)
        #expect(watched.maximumOverlap == 1, "no two key operations of one library ran at the same time")
        #expect(c == .created(accountId: keys.accountID))
        #expect(e.state == .ready)
        #expect(r == .replaced(revision: 2))
        let bundle = try #require(try await device.bundles.fetch()).bundle
        #expect(try device.state.keyState().summary == "saved/\(bundle.rev)")
    }
}

/// Counts how many callers are inside the library's key state at once (each read waits a little to widen the window).
final class OverlapDetectingState: CloudKeyStateStore, @unchecked Sendable {
    let inner: InMemoryCloudKeyStateStore
    private let lock = NSLock()
    private var active = 0
    private var maximum = 0
    init(_ inner: InMemoryCloudKeyStateStore) { self.inner = inner }
    var maximumOverlap: Int { lock.lock(); defer { lock.unlock() }; return maximum }
    private func enter() { lock.lock(); active += 1; maximum = max(maximum, active); lock.unlock() }
    private func leave() { lock.lock(); active -= 1; lock.unlock() }
    func keyState() throws -> CloudKeyLocalState {
        enter(); defer { leave() }
        Thread.sleep(forTimeInterval: 0.03)
        return try inner.keyState()
    }
    func setKeyState(_ state: CloudKeyLocalState) throws {
        enter(); defer { leave() }
        try inner.setKeyState(state)
    }
}

/// Widens the window between reading and writing the pending creation, so overlapping calls interleave.
final class SlowPendingSeeds: CloudKeySeedStore, @unchecked Sendable {
    let inner: InMemoryCloudKeySeedStore
    init(_ inner: InMemoryCloudKeySeedStore) { self.inner = inner }
    func seed(accountId: String) throws -> Data? { try inner.seed(accountId: accountId) }
    func saveSeed(_ seed: Data, accountId: String) throws { try inner.saveSeed(seed, accountId: accountId) }
    func removeSeed(accountId: String) throws { try inner.removeSeed(accountId: accountId) }
    func pending() throws -> PendingKeyCreation? {
        let value = try inner.pending()
        Thread.sleep(forTimeInterval: 0.05)
        return value
    }
    func savePending(_ p: PendingKeyCreation) throws { try inner.savePending(p) }
    func replacePending(_ new: PendingKeyCreation, expected: PendingKeyCreation) throws { try inner.replacePending(new, expected: expected) }
    func clearPending() throws { try inner.clearPending() }
    var namespace: String { inner.namespace }
    func highWaterMark(accountId: String) throws -> Int64? { try inner.highWaterMark(accountId: accountId) }
    func raiseHighWaterMark(_ rev: Int64, accountId: String) throws { try inner.raiseHighWaterMark(rev, accountId: accountId) }
    func forgetAccount(accountId: String) throws { try inner.forgetAccount(accountId: accountId) }
}
