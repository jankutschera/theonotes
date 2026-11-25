// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation

// First-device key creation (CK-R14), the recovery-key choice (CK-J1) and replacing the recovery words later.
// Creation is a sequence of durable steps, each resumable and idempotent:
//   (1) generate keys, persist the local pending creation    (begin)
//   (2) add the synchronizable seed (add-only, per account)   (advance)
//   (3) create the KeyBundle (create-only; a lost response is resolved by fetching it)
//   (4) write account, revision and recovery state to the library
//   (5) clear the pending creation: complete
// A lost race at (3) records the winner, removes only our own seed and clears the pending creation; the caller then joins
// the winner. No data record may be saved before completion (`isComplete`, `requireComplete(keys:)`).
// All bootstrap calls of one library run one at a time (`CloudKeySerial`), across every `await`.

/// The person's choice at setup. It can only be made through `RecoveryKeyOffer.confirm(_:)` (the three offered words
/// typed back) or `RecoveryChoice.skip(acknowledged:)` (the risk acknowledgement ticked); there is no other initializer.
public struct RecoveryChoice: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    enum Kind: Sendable { case saved(offerId: String, key: RecoveryKey), acknowledgedRisk }
    let kind: Kind

    fileprivate init(_ kind: Kind) { self.kind = kind }

    /// The "Skip for now" button: allowed only with the risk acknowledgement ticked (CK-J1).
    public static func skip(acknowledged: Bool) throws -> RecoveryChoice {
        guard acknowledged else { throw CloudKeyError.acknowledgementRequired }
        return RecoveryChoice(.acknowledgedRisk)
    }

    public var isSaved: Bool { if case .saved = kind { true } else { false } }
    /// The offer this choice confirmed (nil for a skip).
    public var offerId: String? { if case .saved(let id, _) = kind { id } else { nil } }

    public var description: String {
        switch kind {
        case .saved(let id, _): "RecoveryChoice.saved(offer: \(id), key: <redacted>)"
        case .acknowledgedRisk: "RecoveryChoice.acknowledgedRisk"
        }
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["choice": description], displayStyle: .struct) }
}

/// A new recovery key to show, with the three positions (0-based, chosen at random) the person must type back.
/// Only `make()` creates one; `confirm(_:)` turns it into a `RecoveryChoice`.
public struct RecoveryKeyOffer: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let confirmationCount = 3
    public let id: String
    public let words: String
    public let checkPositions: [Int]
    let key: RecoveryKey

    init(key: RecoveryKey, checkPositions: [Int]) throws {
        self.key = key
        words = try key.words()
        self.checkPositions = checkPositions.sorted()
        id = UUIDv7.make()
    }

    public static func make() throws -> RecoveryKeyOffer {
        var positions = Set<Int>()
        while positions.count < confirmationCount { positions.insert(Int.random(in: 0..<24)) }
        return try RecoveryKeyOffer(key: RecoveryKey(), checkPositions: Array(positions))
    }

    /// The three-word check: exactly the offered positions, each typed word equal to the word there (case and surrounding
    /// whitespace ignored). Every position is compared (fixed-length digests, no early exit) before the verdict.
    public func confirm(_ typed: [Int: String]) throws -> RecoveryChoice {
        guard typed.count == checkPositions.count, Set(typed.keys) == Set(checkPositions) else {
            throw CloudKeyError.recoveryWordsNotConfirmed
        }
        let list = words.split(separator: " ").map(String.init)
        var allMatch = true
        for position in checkPositions {
            let given = (typed[position] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let match = CloudKeyConstantTime.equal(Data(SHA256.hash(data: Data(given.utf8))),
                                                   Data(SHA256.hash(data: Data(list[position].utf8))))
            allMatch = allMatch && match
        }
        guard allMatch else { throw CloudKeyError.recoveryWordsNotConfirmed }
        return RecoveryChoice(.saved(offerId: id, key: key))
    }

    public var description: String { "RecoveryKeyOffer(id: \(id), words: <redacted>, checkPositions: \(checkPositions))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["id": id, "words": "<redacted>", "checkPositions": checkPositions], displayStyle: .struct)
    }
}

public enum CloudKeyError: Error, Equatable, Sendable, CustomStringConvertible {
    case acknowledgementRequired
    case recoveryWordsNotConfirmed
    case invalidRecoveryKey
    case keychainUnavailable(KeychainAvailability)
    case bundleUnreadable(String)
    /// The bundle write has no known result yet; nothing is lost, try again later.
    case bundleNotWritten
    case noBundle
    /// The keys this device holds do not open the bundle, or the bundle was changed. Nothing is overwritten.
    case keyMismatch
    /// The bundle's revision is lower than one this library already verified.
    case bundleRollback
    /// The bundle belongs to another account than the one this library holds keys for.
    case accountMismatch
    /// The keychain holds a different seed for this account; it is never overwritten.
    case seedConflict
    /// The seed could not be stored durably, so this device cannot finish setup.
    case seedNotStored(KeychainAvailability)
    case creationIncomplete
    case alreadyComplete

    public var description: String {
        switch self {
        case .acknowledgementRequired: "Skipping the recovery key needs the acknowledgement."
        case .recoveryWordsNotConfirmed: "The recovery key words were not confirmed."
        case .invalidRecoveryKey: "The recovery key does not open this account."
        case .keychainUnavailable(let availability): "The keychain is not available (\(availability))."
        case .bundleUnreadable(let code): "The key bundle in iCloud cannot be read (\(code))."
        case .bundleNotWritten: "The key bundle was not confirmed yet."
        case .noBundle: "There is no key bundle in iCloud."
        case .keyMismatch: "The keys on this device do not match the key bundle in iCloud."
        case .bundleRollback: "The key bundle in iCloud is older than one this device already checked."
        case .accountMismatch: "The key bundle in iCloud belongs to another account."
        case .seedConflict: "The keychain holds a different key for this account."
        case .seedNotStored(let availability): "The key could not be stored in the keychain (\(availability))."
        case .creationIncomplete: "Key setup has not finished."
        case .alreadyComplete: "This library already has its keys."
        }
    }
}

/// Runs the key operations of one library one call at a time, across every `await`. There is exactly one instance per
/// library namespace in the process (`shared(namespace:)`, no public initializer): `CloudKeyCreation`, `CloudKeyJoin`
/// and `CloudRecoveryRotation` take it from their seed store's namespace, so separately built objects for the same
/// library cannot race (fix round 2).
public actor CloudKeySerial {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private init() {}

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: CloudKeySerial] = [:]

    public static func shared(namespace: String) -> CloudKeySerial {
        registryLock.lock(); defer { registryLock.unlock() }
        if let existing = registry[namespace] { return existing }
        let created = CloudKeySerial()
        registry[namespace] = created
        return created
    }

    public func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        while busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
        defer {
            busy = false
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }
        return try await body()
    }
}

/// When to offer the recovery key again (CK-J1): a Settings reminder while it is not saved, and one offer after the first
/// successful sync for a person who skipped at setup.
public enum CloudRecoveryReminder {
    public static func showsSettingsReminder(_ state: CloudRecoveryState) -> Bool { state == .acknowledgedSkip || state == .pending }
    public static func offersAfterFirstSuccessfulSync(_ state: CloudRecoveryState) -> Bool { state == .acknowledgedSkip }

    /// Call after the one-time offer was shown and not taken: the Settings reminder stays, the offer is not repeated.
    public static func noteOfferShown(in store: any CloudKeyStateStore) throws {
        var state = try store.keyState()
        guard state.recovery == .acknowledgedSkip else { return }
        state.recovery = .pending
        try store.setKeyState(state)
    }
}

public enum CloudKeyCreationStep: Sendable, Equatable {
    case idle
    case seedSaved, bundleCreated, recoveryStateSet
    case completed(accountId: String)
    case lostRaceRecorded(winner: String), ownSeedRemoved
    case lost(winner: String)
}

public enum CloudKeyCreationResult: Sendable, Equatable {
    case created(accountId: String)
    /// Another device created the bundle first; join it (`CloudKeyJoin`). This device's seed was removed.
    case anotherDeviceWon(accountId: String)
}

/// A keychain refusal surfaces as `CloudKeyError.keychainUnavailable`, the same state the probe reports.
func mappingKeychainErrors<T>(_ body: () async throws -> T) async throws -> T {
    do { return try await body() } catch CloudKeySeedStoreError.unavailable(let availability) {
        throw CloudKeyError.keychainUnavailable(availability)
    } catch CloudKeySeedStoreError.seedConflict {
        throw CloudKeyError.seedConflict
    }
}

public struct CloudKeyCreation: Sendable {
    public let seeds: any CloudKeySeedStore
    public let probe: any CloudKeychainProbe
    public let bundles: CloudKeyBundleStore
    public let state: any CloudKeyStateStore
    public let serial: CloudKeySerial
    let crash: CrashPoint
    let now: @Sendable () -> Date

    public init(seeds: any CloudKeySeedStore, probe: any CloudKeychainProbe, bundles: CloudKeyBundleStore, state: any CloudKeyStateStore,
                crash: CrashPoint = .never, now: @escaping @Sendable () -> Date = { Date() }) {
        self.seeds = seeds; self.probe = probe; self.bundles = bundles; self.state = state
        serial = CloudKeySerial.shared(namespace: seeds.namespace)
        self.crash = crash; self.now = now
    }

    /// True once this library holds finished keys: no half-done creation, a pinned account and recovery state, and the
    /// seed of that account durably in the keychain. Every data save is gated on it (CK-R14, CK-R84).
    public var isComplete: Bool {
        get throws {
            guard try seeds.pending() == nil else { return false }
            let local = try state.keyState()
            guard let account = local.accountId, local.recovery != .none, local.bundleRevision > 0 else { return false }
            return try seeds.seed(accountId: account) != nil
        }
    }

    /// Throws unless the library is complete and `keys` (from a verified join or creation) are those of the pinned account
    /// and match its durable seed.
    public func requireComplete(keys: AccountKeys) throws {
        guard try isComplete, try state.keyState().accountId == keys.accountID,
              let seed = try seeds.seed(accountId: keys.accountID), CloudKeyConstantTime.equal(seed, keys.masterKeyData)
        else { throw CloudKeyError.creationIncomplete }
    }

    /// Step (1). Resumes an existing pending creation (its keys and choice win); otherwise checks the choice, probes the
    /// keychain, generates the keys and persists them locally. Returns the account id.
    @discardableResult
    public func begin(_ choice: RecoveryChoice) async throws -> String {
        try await serial.run { try await mappingKeychainErrors { try beginStep(choice) } }
    }

    /// Performs exactly one durable step from what is persisted, so a restart after a crash continues where it stopped.
    public func advance() async throws -> CloudKeyCreationStep {
        try await serial.run { try await mappingKeychainErrors { try await advanceStep() } }
    }

    /// Steps (1) to (5) as one serialised call. Safe to call again after any failure or crash; a call that finds the
    /// creation already complete (an overlapping call finished it) returns its account. Every path finishes within four
    /// `advance` steps; the bound turns a step that fails to make progress into an error instead of a spin.
    public func run(_ choice: RecoveryChoice) async throws -> CloudKeyCreationResult {
        try await serial.run {
            try await mappingKeychainErrors {
                if try isComplete, let account = try state.keyState().accountId { return .created(accountId: account) }
                _ = try beginStep(choice)
                for _ in 0..<Self.maximumSteps {
                    switch try await advanceStep() {
                    case .completed(let accountId): return .created(accountId: accountId)
                    case .lost(let winner): return .anotherDeviceWon(accountId: winner)
                    case .idle: throw CloudKeyError.creationIncomplete
                    default: continue
                    }
                }
                throw CloudKeyError.creationIncomplete
            }
        }
    }

    static let maximumSteps = 8

    private func beginStep(_ choice: RecoveryChoice) throws -> String {
        if let pending = try seeds.pending() { return pending.accountId }
        let local = try state.keyState()
        guard local.recovery == .none, local.accountId == nil else { throw CloudKeyError.alreadyComplete }
        let recoveryKey: RecoveryKey, recovery: CloudRecoveryState
        switch choice.kind {
        case .saved(_, let key): (recoveryKey, recovery) = (key, .saved)
        case .acknowledgedRisk: (recoveryKey, recovery) = (RecoveryKey(), .acknowledgedSkip)
        }
        let availability = probe.probeAvailability()
        guard availability == .usable else { throw CloudKeyError.keychainUnavailable(availability) }
        try crash.hit("keys.afterProbe")
        let accountId = "ck-" + UUIDv7.make(now: now())
        let keys = try AccountKeys(accountID: accountId)
        let envelope = try keys.envelope(recovery: recoveryKey)
        try CloudKeyVerification.checkRecoveryWrapper(envelope, recoveryKey: recoveryKey, keys: keys)
        let bundle = try CloudKeyBundle.sealed(keys: keys, rev: 1, envelope: envelope, recovery: recovery)
        try seeds.savePending(PendingKeyCreation(accountId: accountId, seed: keys.masterKeyData, bundle: bundle, recovery: recovery,
                                                 startedAt: now()))
        try crash.hit("keys.afterPending")
        return accountId
    }

    private func advanceStep() async throws -> CloudKeyCreationStep {
        guard let pending = try seeds.pending() else { return .idle }
        if let winner = pending.lostTo {
            if try seeds.seed(accountId: pending.accountId) != nil {
                try seeds.removeSeed(accountId: pending.accountId)
                try crash.hit("keys.afterOwnSeedRemoved")
                return .ownSeedRemoved
            }
            try seeds.clearPending()
            try crash.hit("keys.afterPendingCleared")
            return .lost(winner: winner)
        }
        if pending.bundleCreated {
            let local = try state.keyState()
            if local.accountId == nil {
                try CloudKeyVerification.record(CloudKeyLocalState(accountId: pending.accountId, recovery: pending.recovery,
                                                                   bundleRevision: pending.bundle.rev),
                                                rev: pending.bundle.rev, accountId: pending.accountId, seeds: seeds, state: state)
                try crash.hit("keys.afterRecoveryState")
                return .recoveryStateSet
            }
            guard local.accountId == pending.accountId else { throw CloudKeyError.accountMismatch }
            try seeds.clearPending()
            try crash.hit("keys.afterPendingCleared")
            return .completed(accountId: pending.accountId)
        }
        if let existing = try seeds.seed(accountId: pending.accountId) {
            // Never put a bundle in iCloud under a key this device does not hold in its keychain.
            guard CloudKeyConstantTime.equal(existing, pending.seed) else { throw CloudKeyError.seedConflict }
        } else {
            try seeds.saveSeed(pending.seed, accountId: pending.accountId)
            try crash.hit("keys.afterSeed")
            return .seedSaved
        }
        try crash.hit("keys.beforeBundle")
        switch try await bundles.create(pending.bundle) {
        case .written:
            try crash.hit("keys.afterBundleWritten")
            var next = pending
            next.bundleCreated = true
            try seeds.replacePending(next, expected: pending)
            try crash.hit("keys.afterBundle")
            return .bundleCreated
        case .conflict(let winner?):
            var next = pending
            next.lostTo = winner.bundle.accountId
            try seeds.replacePending(next, expected: pending)
            try crash.hit("keys.afterLostRace")
            return .lostRaceRecorded(winner: winner.bundle.accountId)
        case .conflict(nil), .notWritten:
            throw CloudKeyError.bundleNotWritten
        }
    }
}

public enum CloudRecoveryRotationOutcome: Sendable, Equatable {
    case replaced(revision: Int64)
    /// Another device changed the bundle first. Nothing was overwritten; this library now knows the newer bundle.
    case lostRace
}

/// Replacing the recovery words later (Settings ▸ iCloud ▸ Recovery key, CK-R14). This is NOT revocation (CK-R89): the
/// master and vault keys stay, so old words plus an old copy of the bundle still open the data. The person confirms three
/// words first; then the bundle is re-wrapped and change-tag-updated. Every device that holds the seed keeps working.
public struct CloudRecoveryRotation: Sendable {
    public struct Draft: Sendable {
        let base: FetchedKeyBundle
        let replacement: CloudKeyBundle
        public var revision: Int64 { replacement.rev }
    }

    public let seeds: any CloudKeySeedStore
    public let bundles: CloudKeyBundleStore
    public let state: any CloudKeyStateStore
    public let serial: CloudKeySerial

    public init(seeds: any CloudKeySeedStore, bundles: CloudKeyBundleStore, state: any CloudKeyStateStore) {
        self.seeds = seeds; self.bundles = bundles; self.state = state
        serial = CloudKeySerial.shared(namespace: seeds.namespace)
    }

    /// Checks that `keys` open the current, authentic bundle and builds the replacement. Uploads nothing.
    public func prepare(_ choice: RecoveryChoice, keys: AccountKeys) async throws -> Draft {
        guard case .saved(_, let recoveryKey) = choice.kind else { throw CloudKeyError.recoveryWordsNotConfirmed }
        return try await serial.run {
            try await mappingKeychainErrors {
                guard let current = try await bundles.fetch() else { throw CloudKeyError.noBundle }
                try CloudKeyVerification.checkPin(current.bundle, try state.keyState(), seeds: seeds)
                _ = try CloudKeyVerification.check(current.bundle, keys: keys)
                let envelope = try keys.envelope(recovery: recoveryKey)
                try CloudKeyVerification.checkRecoveryWrapper(envelope, recoveryKey: recoveryKey, keys: keys)
                let replacement = try CloudKeyBundle.sealed(keys: keys, rev: current.bundle.rev + 1, envelope: envelope, recovery: .saved)
                return Draft(base: current, replacement: replacement)
            }
        }
    }

    /// Uploads the replacement. A bundle that changed since this library last verified it, or changes before the save
    /// lands, is a lost race: reported, never overwritten.
    public func commit(_ draft: Draft, keys: AccountKeys) async throws -> CloudRecoveryRotationOutcome {
        try await serial.run { try await mappingKeychainErrors { try await commitStep(draft, keys: keys) } }
    }

    private func commitStep(_ draft: Draft, keys: AccountKeys) async throws -> CloudRecoveryRotationOutcome {
        let local = try state.keyState()
        try CloudKeyVerification.checkPin(draft.base.bundle, local, seeds: seeds)
        guard draft.base.bundle.rev == local.bundleRevision else {
            try adopt(draft.base.bundle, keys: keys)
            return .lostRace
        }
        switch try await bundles.replace(draft.replacement, base: draft.base) {
        case .written:
            var next = local
            next.accountId = keys.accountID; next.recovery = .saved; next.bundleRevision = draft.replacement.rev
            try CloudKeyVerification.record(next, rev: draft.replacement.rev, accountId: keys.accountID, seeds: seeds, state: state)
            return .replaced(revision: draft.replacement.rev)
        case .conflict(let current?):
            try adopt(current.bundle, keys: keys)
            return .lostRace
        case .conflict(nil):
            throw CloudKeyError.noBundle
        case .notWritten:
            throw CloudKeyError.bundleNotWritten
        }
    }

    public func createOrReplaceRecoveryKey(_ choice: RecoveryChoice, keys: AccountKeys) async throws -> CloudRecoveryRotationOutcome {
        try await commit(try await prepare(choice, keys: keys), keys: keys)
    }

    /// Takes over the revision and recovery state of a newer bundle that `keys` open and that passes the pins.
    private func adopt(_ bundle: CloudKeyBundle, keys: AccountKeys) throws {
        let local = try state.keyState()
        try CloudKeyVerification.checkPin(bundle, local, seeds: seeds)
        let recovery = try CloudKeyVerification.check(bundle, keys: keys)
        try CloudKeyVerification.record(CloudKeyVerification.adopted(local, bundle, recovery: recovery), rev: bundle.rev,
                                        accountId: bundle.accountId, seeds: seeds, state: state, previous: local)
    }
}
