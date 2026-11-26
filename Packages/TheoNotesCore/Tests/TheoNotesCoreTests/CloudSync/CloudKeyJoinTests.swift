// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import Security
import Testing
@testable import TheoNotesCore

/// A device joining an existing account: through the synchronizable seed, by waiting for it, or with the
/// recovery key; never by overwriting a seed or the bundle.
@Suite struct CloudKeyJoinTests {
    @Test func vaultKeyEqualsOnBothDevices() async throws {
        let cloud = FakeCloudKitAccount(), keychain = InMemoryCloudKeychain()
        let a = try await KeyDevice.make(cloud: cloud, keychain: keychain)
        let b = try await KeyDevice.make(cloud: cloud, keychain: keychain)
        _ = try await a.creation.run(try KeyTest.knownRecovery().choice)
        let keysA = try await a.readyKeys()
        let evaluation = try await b.joiner().evaluate()
        #expect(evaluation.state == .ready)
        let keysB = try #require(evaluation.keys)
        do { let sameKeys = KeyTest.same(keysA.vaultKey, keysB.vaultKey); #expect(sameKeys) }
        #expect(keysB.accountID == keysA.accountID)
        let body = Data("written on device A".utf8)
        let sealed = try NoteCipher.seal(body, vaultKey: keysA.vaultKey, context: "baerchen-sync:1:\(keysA.accountID):note:n1:1")
        #expect(try NoteCipher.open(sealed, vaultKey: keysB.vaultKey, context: "baerchen-sync:1:\(keysA.accountID):note:n1:1") == body)
        #expect(try b.state.keyState().summary == "saved/1")
        #expect(try b.creation.isComplete, "a joined device may save data")
        #expect(await b.gateway.saves.isEmpty, "joining writes nothing to the cloud")
    }

    @Test func secondDeviceWaitsForKeychainThenJoins() async throws {
        let cloud = FakeCloudKitAccount(), keychain = InMemoryCloudKeychain(syncsAutomatically: false)
        let a = try await KeyDevice.make(cloud: cloud, keychain: keychain)
        let b = try await KeyDevice.make(cloud: cloud, keychain: keychain)
        _ = try await a.creation.run(.acknowledgedRisk)
        let join = b.joiner()
        let waiting = try await join.evaluate()
        #expect(waiting.state == .waitingForKeychain(since: b.clock.now, stillWaiting: false))
        #expect(waiting.keys == nil)
        #expect(waiting.retryAfter != nil)
        #expect(try b.creation.isComplete == false)
        keychain.sync()
        let ready = try await join.evaluate()
        #expect(ready.state == .ready)
        do { let sameKeys = KeyTest.same(try #require(ready.keys).vaultKey, try await a.readyKeys().vaultKey); #expect(sameKeys) }
        #expect(try b.state.keyState().summary == "acknowledgedSkip/1")
    }

    @Test func delayedKeychainShowsStillWaitingAfterTenMinutes() async throws {
        let cloud = FakeCloudKitAccount(), keychain = InMemoryCloudKeychain(syncsAutomatically: false)
        let a = try await KeyDevice.make(cloud: cloud, keychain: keychain)
        let b = try await KeyDevice.make(cloud: cloud, keychain: keychain)
        _ = try await a.creation.run(.acknowledgedRisk)
        let join = b.joiner()
        let start = b.clock.now
        #expect(try await join.evaluate().state == .waitingForKeychain(since: start, stillWaiting: false))
        b.clock.advance(300)
        #expect(try await join.evaluate().state == .waitingForKeychain(since: start, stillWaiting: false))
        b.clock.advance(299)
        #expect(try await join.evaluate().state == .waitingForKeychain(since: start, stillWaiting: false))
        b.clock.advance(1)
        let still = try await join.evaluate()
        #expect(still.state == .waitingForKeychain(since: start, stillWaiting: true))
        // The backoff grows while waiting and stays bounded (the existing SyncRetrySchedule).
        #expect((still.retryAfter ?? 0) > 2 && (still.retryAfter ?? 0) <= 300)
        keychain.sync()
        #expect(try await join.evaluate().state == .ready)
    }

    @Test func keychainUnavailableStatesAreDistinct() async throws {
        #expect(KeychainAvailability.classify(status: errSecSuccess) == .usable)
        #expect(KeychainAvailability.classify(status: -34018) == .unavailable(.missingEntitlement))
        #expect(KeychainAvailability.classify(status: -25308) == .unavailable(.deviceLocked))
        #expect(KeychainAvailability.classify(status: errSecAuthFailed) == .unavailable(.notAllowed))

        let cloud = FakeCloudKitAccount()
        let a = try await KeyDevice.make(cloud: cloud, keychain: InMemoryCloudKeychain())
        _ = try await a.creation.run(.acknowledgedRisk)
        var observed: [KeychainAvailability] = []
        for variant in 0..<3 {
            let keychain = InMemoryCloudKeychain(syncsAutomatically: false)
            let device = try await KeyDevice.make(cloud: cloud, keychain: keychain)
            switch variant {
            case 0: device.seeds.simulate(status: -34018)
            case 1: device.seeds.simulate(status: -25308)
            default: device.seeds.simulateReadBackFailure()
            }
            let expected: KeychainAvailability = [.unavailable(.missingEntitlement), .unavailable(.deviceLocked), .failedReadBack][variant]
            #expect(device.seeds.probeAvailability() == expected)
            #expect(try await device.joiner().evaluate().state == .keychainUnavailable(expected))
            // A first-device creation stops before anything is persisted or sent.
            let fresh = try await KeyDevice.make(cloud: FakeCloudKitAccount(), keychain: keychain, seeds: device.seeds)
            await #expect(throws: CloudKeyError.keychainUnavailable(expected)) { try await fresh.creation.begin(.acknowledgedRisk) }
            device.seeds.restoreAvailability()
            #expect(try KeyTest.noPending(device.seeds))
            #expect(await fresh.gateway.saves.isEmpty)
            observed.append(expected)
        }
        #expect(Set(observed.map { "\($0)" }).count == 3)
    }

    @Test func recoveryKeyJoinsWithoutKeychain() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await KeyDevice.make(cloud: cloud, keychain: InMemoryCloudKeychain())
        let words = try KeyTest.knownRecovery()
        _ = try await a.creation.run(words.choice)
        let b = try await KeyDevice.make(cloud: cloud, keychain: InMemoryCloudKeychain())
        b.seeds.simulate(status: -34018)
        let join = b.joiner()
        #expect(try await join.evaluate().state == .keychainUnavailable(.unavailable(.missingEntitlement)))
        let joined = try await join.join(recoveryWords: "  " + words.words.uppercased() + "\n")
        do { let sameKeys = KeyTest.same(joined.keys.vaultKey, try await a.readyKeys().vaultKey); #expect(sameKeys) }
        #expect(joined.seedStored == false)
        // Usable keys for this session, but setup is blocked: nothing durable, nothing marked saved or complete.
        #expect(joined.blockedBy == .seedNotStored(.unavailable(.missingEntitlement)))
        #expect(try b.state.keyState().summary == "none/0")
        b.seeds.restoreAvailability()
        #expect(try b.creation.isComplete == false)
        #expect(await b.gateway.saves.isEmpty)

        // With a usable keychain the seed is stored too (add-only, same value).
        let c = try await KeyDevice.make(cloud: cloud, keychain: InMemoryCloudKeychain())
        let stored = try await c.joiner().join(recoveryWords: words.words)
        #expect(stored.seedStored)
        #expect(try await c.joiner().evaluate().state == .ready)
    }

    @Test func wrongRecoveryWordsRejectedNoStateChange() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await KeyDevice.make(cloud: cloud, keychain: InMemoryCloudKeychain())
        let words = try KeyTest.knownRecovery()
        _ = try await a.creation.run(words.choice)
        let b = try await KeyDevice.make(cloud: cloud, keychain: InMemoryCloudKeychain())
        var swapped = words.words.split(separator: " ").map(String.init)
        swapped.swapAt(0, 1)
        if swapped[0] == swapped[1] { swapped[0] = swapped[0] == "zoo" ? "abandon" : "zoo" }
        for attempt in ["not a recovery key", try RecoveryKey().words(), Array(repeating: "abandon", count: 24).joined(separator: " ")] {
            await #expect(throws: CloudKeyError.invalidRecoveryKey) { _ = try await b.joiner().join(recoveryWords: attempt) }
        }
        await #expect(throws: CloudKeyError.invalidRecoveryKey) { _ = try await b.joiner().join(recoveryWords: swapped.joined(separator: " ")) }
        #expect(try b.state.keyState().summary == "none/0")
        #expect(b.seeds.keychain.log.allSatisfy { !$0.contains(":save:") })
        #expect(await b.gateway.saves.isEmpty)
        #expect(try b.creation.isComplete == false)
    }

    @Test func seedPresentButEnvelopeDoesNotOpenIsKeyMismatchNotOverwrite() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await KeyDevice.make(cloud: cloud, keychain: InMemoryCloudKeychain())
        guard case .created(let account) = try await a.creation.run(.acknowledgedRisk) else { Issue.record("not created"); return }
        let b = try await KeyDevice.make(cloud: cloud, keychain: InMemoryCloudKeychain())
        let foreign = KeyTest.bytes(SymmetricKey(size: .bits256))
        try b.seeds.saveSeed(foreign, accountId: account)
        let before = await cloud.record(named: "keybundle")
        #expect(try await b.joiner().evaluate().state == .keyMismatch)
        let unchangedSeed = try b.seeds.seed(accountId: account) == foreign
        #expect(unchangedSeed, "the seed is never replaced")
        #expect(b.seeds.keychain.log.filter { $0.contains(":remove:") }.isEmpty)
        #expect(await b.gateway.saves.isEmpty)
        #expect(await cloud.record(named: "keybundle") == before)
        #expect(try b.state.keyState().recovery == .none)
        // The recovery path does not overwrite the conflicting seed either.
        let rotated = try KeyTest.knownRecovery()
        _ = try await a.rotation.createOrReplaceRecoveryKey(rotated.choice, keys: try await a.readyKeys())
        let joined = try await b.joiner().join(recoveryWords: rotated.words)
        #expect(joined.seedStored == false)
        #expect(joined.blockedBy == .seedConflict)
        #expect(try b.state.keyState().recovery == .none, "a blocked join changes no state")
        let stillForeign = try b.seeds.seed(accountId: account) == foreign
        #expect(stillForeign)

        // A bundle whose envelope opens with the seed but whose canary does not is a mismatch too (tampered bundle).
        let keysA = try await a.readyKeys()
        let current = try #require(try await a.bundles.fetch())
        var tampered = current.bundle
        tampered.rev += 1
        tampered.canary = try CloudKeyCanary.seal(vaultKey: SymmetricKey(size: .bits256), accountId: account, rev: tampered.rev,
                                                  envelope: tampered.envelope, recovery: .saved)
        #expect(try await a.bundles.replace(tampered, base: current) == .written)
        #expect(try await a.joiner().evaluate().state == .keyMismatch)
        await #expect(throws: CloudKeyError.keyMismatch) { _ = try await a.rotation.prepare(try KeyTest.knownRecovery().choice, keys: keysA) }
    }

    @Test func bundleDeletedInCloudDoesNotDeleteSeed() async throws {
        let cloud = FakeCloudKitAccount(), keychain = InMemoryCloudKeychain()
        let a = try await KeyDevice.make(cloud: cloud, keychain: keychain)
        let b = try await KeyDevice.make(cloud: cloud, keychain: keychain)
        guard case .created(let account) = try await a.creation.run(.acknowledgedRisk) else { Issue.record("not created"); return }
        _ = try await b.readyKeys()
        await cloud.removeRecord("keybundle")
        #expect(try await a.joiner().evaluate().state == .noBundle)
        #expect(try await b.joiner().evaluate().state == .noBundle)
        #expect(try KeyTest.hasSeed(a.seeds, account))
        #expect(try KeyTest.hasSeed(b.seeds, account))
        #expect(keychain.log.filter { $0.contains(":remove:") }.isEmpty)
        #expect(await a.savedNames == ["keybundle"])
        #expect(await b.gateway.saves.isEmpty)
        #expect(try a.state.keyState().recovery == .acknowledgedSkip, "local key state is kept")
        await #expect(throws: CloudKeyError.noBundle) { _ = try await b.joiner().join(recoveryWords: try RecoveryKey().words()) }
    }

    @Test func aJoinedDeviceWhoseSeedWasRemovedNeedsTheRecoveryKey() async throws {
        let cloud = FakeCloudKitAccount(), keychain = InMemoryCloudKeychain()
        let a = try await KeyDevice.make(cloud: cloud, keychain: keychain)
        let b = try await KeyDevice.make(cloud: cloud, keychain: keychain)
        let words = try KeyTest.knownRecovery()
        guard case .created(let account) = try await a.creation.run(words.choice) else { Issue.record("not created"); return }
        _ = try await b.readyKeys()
        // "Remove the iCloud key from all my devices" on A.
        try a.seeds.removeSeed(accountId: account)
        #expect(try await b.joiner().evaluate().state == .needsRecoveryKey)
        let joined = try await b.joiner().join(recoveryWords: words.words)
        #expect(joined.seedStored)
        #expect(try await a.joiner().evaluate().state == .ready, "the recovery join put the seed back for every device")
    }

    // MARK: fix round 1: the bundle is authenticated as a whole and never rolled back

    /// Writes a changed bundle over the current one, as someone with write access to the private database could.
    func overwrite(_ device: KeyDevice, _ change: (inout CloudKeyBundle) -> Void) async throws {
        let current = try #require(try await device.bundles.fetch())
        var changed = current.bundle
        change(&changed)
        #expect(try await device.bundles.replace(changed, base: current) == .written)
    }

    static func envelope(_ e: AccountKeyEnvelope, wrappedMasterKey: String? = nil, recoveryPublicKey: String? = nil) -> AccountKeyEnvelope {
        AccountKeyEnvelope(version: e.version, algorithm: e.algorithm, accountId: e.accountId,
                           wrappedMasterKey: wrappedMasterKey ?? e.wrappedMasterKey, wrappedVaultKey: e.wrappedVaultKey,
                           recoveryPublicKey: recoveryPublicKey ?? e.recoveryPublicKey)
    }

    @Test func aTamperedRecoveryWrapperOrRecoveryKeyIsRefused() async throws {
        for part in 0..<2 {
            let cloud = FakeCloudKitAccount(), keychain = InMemoryCloudKeychain()
            let a = try await KeyDevice.make(cloud: cloud, keychain: keychain)
            let b = try await KeyDevice.make(cloud: cloud, keychain: keychain)
            _ = try await a.creation.run(try KeyTest.knownRecovery().choice)
            let foreign = try AccountKeys(accountID: try #require(try await a.bundles.fetch()).bundle.accountId)
                .envelope(recovery: RecoveryKey())
            try await overwrite(a) { bundle in
                bundle.envelope = part == 0 ? Self.envelope(bundle.envelope, wrappedMasterKey: foreign.wrappedMasterKey)
                                            : Self.envelope(bundle.envelope, recoveryPublicKey: foreign.recoveryPublicKey)
            }
            #expect(try await b.joiner().evaluate().state == .keyMismatch, "tampered part \(part) must not join")
            #expect(try b.state.keyState().recovery == .none)
        }
    }

    @Test func aTamperedRevisionIsRefused() async throws {
        let cloud = FakeCloudKitAccount(), keychain = InMemoryCloudKeychain()
        let a = try await KeyDevice.make(cloud: cloud, keychain: keychain)
        let b = try await KeyDevice.make(cloud: cloud, keychain: keychain)
        _ = try await a.creation.run(.acknowledgedRisk)
        try await overwrite(a) { $0.rev = 7 }
        #expect(try await b.joiner().evaluate().state == .keyMismatch)
        #expect(try b.state.keyState().bundleRevision == 0)
    }

    @Test func aReplayedOlderBundleIsRefusedAsRollback() async throws {
        let cloud = FakeCloudKitAccount(), keychain = InMemoryCloudKeychain()
        let a = try await KeyDevice.make(cloud: cloud, keychain: keychain)
        let b = try await KeyDevice.make(cloud: cloud, keychain: keychain)
        _ = try await a.creation.run(.acknowledgedRisk)
        let original = try #require(try await a.bundles.fetch()).bundle
        let words = try KeyTest.knownRecovery()
        _ = try await a.rotation.createOrReplaceRecoveryKey(words.choice, keys: try await a.readyKeys())
        #expect(try await b.joiner().evaluate().state == .ready)
        #expect(try b.state.keyState().bundleRevision == 2)
        try await overwrite(a) { $0 = original }
        let rolledBack = try await b.joiner().evaluate()
        #expect(rolledBack.state == .keyMismatch, "rev 1 after rev 2 is a rollback")
        #expect(rolledBack.mismatch == .bundleRollback)
        #expect(try b.state.keyState().bundleRevision == 2)
        #expect(try b.state.keyState().recovery == .saved)
        await #expect(throws: CloudKeyError.bundleRollback) { _ = try await b.joiner().join(recoveryWords: words.words) }

        // A bundle of another account is never adopted by a library pinned to this one.
        await cloud.removeRecord("keybundle")
        let c = try await KeyDevice.make(cloud: cloud, keychain: keychain)
        _ = try await c.creation.run(.acknowledgedRisk)
        let foreign = try await b.joiner().evaluate()
        #expect(foreign.state == .keyMismatch)
        #expect(foreign.mismatch == .accountMismatch)
        #expect(try b.state.keyState().bundleRevision == 2)
    }

    // MARK: fix round 2: the revision high-water mark survives detach

    /// Detach clears every `ck_*` table, including the library's pin (Task 3); this is what it leaves of the key state.
    func detach(_ device: KeyDevice) throws {
        try device.state.setKeyState(CloudKeyLocalState(recovery: .none, bundleRevision: 0))
    }

    @Test func detachThenAnOlderAuthenticBundleIsStillARollback() async throws {
        let cloud = FakeCloudKitAccount(), keychain = InMemoryCloudKeychain()
        let a = try await KeyDevice.make(cloud: cloud, keychain: keychain)
        let b = try await KeyDevice.make(cloud: cloud, keychain: keychain)
        _ = try await a.creation.run(.acknowledgedRisk)
        let original = try #require(try await a.bundles.fetch()).bundle
        _ = try await a.rotation.createOrReplaceRecoveryKey(try KeyTest.knownRecovery().choice, keys: try await a.readyKeys())
        #expect(try await b.joiner().evaluate().state == .ready)
        try detach(b)
        try await overwrite(a) { $0 = original }
        let after = try await b.joiner().evaluate()
        #expect(after.state == .keyMismatch, "the per-account mark is kept across detach")
        #expect(after.mismatch == .bundleRollback)
        #expect(try b.state.keyState().summary == "none/0")
        await #expect(throws: CloudKeyError.bundleRollback) { _ = try await b.joiner().join(recoveryWords: try RecoveryKey().words()) }
    }

    @Test func anExplicitForgetAcceptsAnOlderBundleAsFirstContact() async throws {
        let cloud = FakeCloudKitAccount(), keychain = InMemoryCloudKeychain()
        let a = try await KeyDevice.make(cloud: cloud, keychain: keychain)
        let b = try await KeyDevice.make(cloud: cloud, keychain: keychain)
        guard case .created(let account) = try await a.creation.run(.acknowledgedRisk) else { Issue.record("not created"); return }
        let original = try #require(try await a.bundles.fetch()).bundle
        _ = try await a.rotation.createOrReplaceRecoveryKey(try KeyTest.knownRecovery().choice, keys: try await a.readyKeys())
        #expect(try await b.joiner().evaluate().state == .ready)
        #expect(try b.seeds.highWaterMark(accountId: account) == 2)
        try detach(b)
        try b.seeds.forgetAccount(accountId: account)
        #expect(try b.seeds.highWaterMark(accountId: account) == nil)
        #expect(try KeyTest.hasSeed(b.seeds, account), "forgetting the mark keeps the seed")
        try await overwrite(a) { $0 = original }
        // Documented limitation: without any mark, an older authentic bundle is first contact.
        #expect(try await b.joiner().evaluate().state == .ready)
        #expect(try b.seeds.highWaterMark(accountId: account) == 1)
    }

    @Test func theRevisionMarkNeverDecreases() async throws {
        let store = InMemoryCloudKeySeedStore()
        #expect(try store.highWaterMark(accountId: "ck-1") == nil)
        try store.raiseHighWaterMark(3, accountId: "ck-1")
        try store.raiseHighWaterMark(2, accountId: "ck-1")
        #expect(try store.highWaterMark(accountId: "ck-1") == 3, "a lower value does not lower the mark")
        try store.raiseHighWaterMark(3, accountId: "ck-1")
        #expect(try store.highWaterMark(accountId: "ck-1") == 3)
        try store.raiseHighWaterMark(5, accountId: "ck-1")
        #expect(try store.highWaterMark(accountId: "ck-1") == 5)
        #expect(try store.highWaterMark(accountId: "ck-2") == nil, "per account")
        // The mark is per device, not synchronised; removing the seed (explicit action) clears this device's mark.
        let other = InMemoryCloudKeySeedStore(keychain: store.keychain)
        #expect(try other.highWaterMark(accountId: "ck-1") == nil)
        try store.saveSeed(KeyTest.bytes(SymmetricKey(size: .bits256)), accountId: "ck-1")
        try store.removeSeed(accountId: "ck-1")
        #expect(try store.highWaterMark(accountId: "ck-1") == nil)

        // Through the flows: creation, join, replacement and adoption only ever raise it.
        let cloud = FakeCloudKitAccount(), keychain = InMemoryCloudKeychain()
        let a = try await KeyDevice.make(cloud: cloud, keychain: keychain)
        let b = try await KeyDevice.make(cloud: cloud, keychain: keychain)
        guard case .created(let account) = try await a.creation.run(.acknowledgedRisk) else { Issue.record("not created"); return }
        #expect(try a.seeds.highWaterMark(accountId: account) == 1)
        let keysA = try await a.readyKeys()
        for round in 2...4 {
            #expect(try await a.rotation.createOrReplaceRecoveryKey(try KeyTest.knownRecovery().choice, keys: keysA) == .replaced(revision: Int64(round)))
            #expect(try a.seeds.highWaterMark(accountId: account) == Int64(round))
        }
        #expect(try await b.joiner().evaluate().state == .ready)
        #expect(try b.seeds.highWaterMark(accountId: account) == 4)
        try detach(b)
        #expect(try b.seeds.highWaterMark(accountId: account) == 4, "detach does not touch the mark")
        // The real detach (Task 3) has no way to reach the keychain items.
        let detachSource = try String(contentsOf: SchemaSnapshotTests.fixtureDir.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Packages/TheoNotesCore/Sources/TheoNotesCore/Sync/SyncAccountDetach.swift"), encoding: .utf8)
        for name in ["CloudKeySeedStore", "forgetAccount", "removeSeed", "HighWaterMark", "SecItem"] {
            #expect(!detachSource.contains(name), "SyncAccountDetach must not touch \(name)")
        }
    }
}
