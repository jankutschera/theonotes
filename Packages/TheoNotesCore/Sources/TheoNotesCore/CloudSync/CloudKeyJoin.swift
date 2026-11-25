// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation

// A device joining an account that already has a KeyBundle (CK-R6, CK-R14): it looks up the seed by the bundle's
// account id in iCloud Keychain, rebuilds the keys with `AccountKeys(masterKey:envelope:)` and proves them on the
// bundle's canary, which authenticates every field of the bundle. Without a seed it waits (iCloud Keychain can take
// minutes) and offers the recovery key; with a seed that does not open the bundle, a changed bundle, a bundle of another
// account or an older revision than this library verified, it reports a mismatch. It never writes the bundle and never
// removes or replaces a seed.

public enum CloudKeyJoinState: Sendable, Equatable {
    case noBundle, ready, waitingForKeychain(since: Date, stillWaiting: Bool), needsRecoveryKey,
         keychainUnavailable(KeychainAvailability), keyMismatch
}

public struct CloudKeyJoinEvaluation: Sendable {
    public let state: CloudKeyJoinState
    /// Present only when `state == .ready`.
    public let keys: AccountKeys?
    public let accountId: String?
    /// When to look again while waiting for the keychain (the existing `SyncRetrySchedule` backoff).
    public let retryAfter: TimeInterval?
    /// Why `keyMismatch`: `keyMismatch` (keys or bundle content), `bundleRollback` or `accountMismatch`.
    public let mismatch: CloudKeyError?
    /// The bundle that was verified (only with `.ready`): the coordinator keeps it for an offline launch (CK-R130).
    public var verifiedBundle: CloudKeyBundle?
}

public struct CloudKeyJoinResult: Sendable {
    public let keys: AccountKeys
    /// Whether the seed is now durably in this device's keychain.
    public let seedStored: Bool
    /// Set when the seed could not be stored (`seedNotStored`) or the keychain holds a different one (`seedConflict`).
    /// The keys are then usable for this session only: the library state is not changed and setup is not complete.
    public let blockedBy: CloudKeyError?
}

public final class CloudKeyJoin: @unchecked Sendable {
    /// After this long without a seed the state says `stillWaiting` and points to the recovery-key route.
    public static let stillWaitingAfter: TimeInterval = 600

    public let seeds: any CloudKeySeedStore
    public let probe: any CloudKeychainProbe
    public let bundles: CloudKeyBundleStore
    public let state: any CloudKeyStateStore
    public let serial: CloudKeySerial
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var waitingSince: Date?
    private var retry = SyncRetrySchedule()

    public init(seeds: any CloudKeySeedStore, probe: any CloudKeychainProbe, bundles: CloudKeyBundleStore, state: any CloudKeyStateStore,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.seeds = seeds; self.probe = probe; self.bundles = bundles; self.state = state; self.now = now
        serial = CloudKeySerial.shared(namespace: seeds.namespace)
    }

    public func evaluate() async throws -> CloudKeyJoinEvaluation {
        try await serial.run { try await self.evaluateStep() }
    }

    private func evaluateStep() async throws -> CloudKeyJoinEvaluation {
        guard let fetched = try await bundles.fetch() else {
            stopWaiting()
            return CloudKeyJoinEvaluation(state: .noBundle, keys: nil, accountId: nil, retryAfter: nil, mismatch: nil, verifiedBundle: nil)
        }
        let bundle = fetched.bundle
        func result(_ state: CloudKeyJoinState, retryAfter: TimeInterval? = nil, mismatch: CloudKeyError? = nil) -> CloudKeyJoinEvaluation {
            CloudKeyJoinEvaluation(state: state, keys: nil, accountId: bundle.accountId, retryAfter: retryAfter, mismatch: mismatch, verifiedBundle: nil)
        }
        let local = try state.keyState()
        do { try CloudKeyVerification.checkPin(bundle, local, seeds: seeds) }
        catch let error as CloudKeyError { return result(.keyMismatch, mismatch: error) }
        catch CloudKeySeedStoreError.unavailable(let availability) { return result(.keychainUnavailable(availability)) }
        let seed: Data?
        do { seed = try seeds.seed(accountId: bundle.accountId) }
        catch CloudKeySeedStoreError.unavailable(let availability) { return result(.keychainUnavailable(availability)) }
        guard let seed else {
            let availability = probe.probeAvailability()
            guard availability == .usable else { return result(.keychainUnavailable(availability)) }
            // A library that already held keys and now finds no seed will not get it back by waiting
            // (the item was removed from all devices, or the keychain was reset): the recovery key is the route.
            if local.accountId != nil || local.recovery != .none { return result(.needsRecoveryKey) }
            let (since, delay) = noteWaiting()
            return result(.waitingForKeychain(since: since, stillWaiting: now().timeIntervalSince(since) >= Self.stillWaitingAfter),
                          retryAfter: delay)
        }
        stopWaiting()
        let keys: AccountKeys, recovery: CloudRecoveryState
        do { (keys, recovery) = try CloudKeyVerification.open(bundle, masterKey: seed) } catch {
            return result(.keyMismatch, mismatch: .keyMismatch)
        }
        try CloudKeyVerification.record(CloudKeyVerification.adopted(local, bundle, recovery: recovery), rev: bundle.rev,
                                        accountId: bundle.accountId, seeds: seeds, state: state, previous: local)
        return CloudKeyJoinEvaluation(state: .ready, keys: keys, accountId: bundle.accountId, retryAfter: nil, mismatch: nil, verifiedBundle: bundle)
    }

    /// Joins with the 24 recovery words, without iCloud Keychain. Wrong words change nothing. The library is set up only
    /// when the seed is durably stored (or already there with the same value); otherwise the result is `blockedBy`.
    public func join(recoveryWords: String) async throws -> CloudKeyJoinResult {
        try await serial.run { try await self.joinStep(recoveryWords) }
    }

    private func joinStep(_ recoveryWords: String) async throws -> CloudKeyJoinResult {
        guard let fetched = try await bundles.fetch() else { throw CloudKeyError.noBundle }
        let bundle = fetched.bundle
        let local = try state.keyState()
        // An unreadable keychain cannot give the mark; the join is then blocked (`seedNotStored`) and writes nothing.
        let mark: Int64?
        do { mark = try seeds.highWaterMark(accountId: bundle.accountId) } catch CloudKeySeedStoreError.unavailable { mark = nil }
        try CloudKeyVerification.checkPin(bundle, local, mark: mark)
        let keys: AccountKeys
        do { keys = try AccountKeys(recovery: RecoveryKey(words: recoveryWords), envelope: bundle.envelope) }
        catch { throw CloudKeyError.invalidRecoveryKey }
        _ = try CloudKeyVerification.check(bundle, keys: keys)
        stopWaiting()
        let blocked: CloudKeyError?
        do {
            if let existing = try seeds.seed(accountId: bundle.accountId) {
                blocked = CloudKeyConstantTime.equal(existing, keys.masterKeyData) ? nil : .seedConflict
            } else {
                try seeds.saveSeed(keys.masterKeyData, accountId: bundle.accountId)
                blocked = nil
            }
        } catch CloudKeySeedStoreError.unavailable(let availability) {
            blocked = .seedNotStored(availability)
        } catch CloudKeySeedStoreError.seedConflict {
            blocked = .seedConflict
        }
        if let blocked { return CloudKeyJoinResult(keys: keys, seedStored: false, blockedBy: blocked) }
        // The person just used the recovery key, so it is saved.
        var next = CloudKeyVerification.adopted(local, bundle, recovery: .saved)
        next.recovery = .saved
        try CloudKeyVerification.record(next, rev: bundle.rev, accountId: bundle.accountId, seeds: seeds, state: state)
        return CloudKeyJoinResult(keys: keys, seedStored: true, blockedBy: nil)
    }

    private func noteWaiting() -> (Date, TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        let since = waitingSince ?? now()
        waitingSince = since
        return (since, retry.failed(jitter: 1))
    }

    private func stopWaiting() {
        lock.lock(); defer { lock.unlock() }
        waitingSince = nil
        retry.reset()
    }
}
