// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Security

// Where the account master key ("seed") lives so a person's other devices can rebuild the account keys (CK-R6, CK-R14):
// one iCloud-Keychain item (`kSecAttrSynchronizable`) per account id. Next to it, a local, non-synchronizable item holds
// the first device's half-finished key creation so a crash at any step resumes with the same keys.
// Nothing in this file logs, prints or puts secret bytes into an error: descriptions are redacted.

/// What a Keychain probe (write, read back, remove a throw-away synchronizable item) observed (CK-R14).
public enum KeychainAvailability: Sendable, Equatable {
    public enum Reason: String, Sendable, Equatable {
        /// `errSecMissingEntitlement` (-34018): the build has no keychain access group. Unlocking does not help.
        case missingEntitlement
        /// `errSecInteractionNotAllowed` (-25308): the keychain is locked (before the first unlock) or interaction is denied.
        case deviceLocked
        /// Any other refusal.
        case notAllowed
    }
    case usable, unavailable(Reason), failedReadBack

    /// The state an `OSStatus` from a keychain call means. `errSecSuccess` is `usable`.
    public static func classify(status: OSStatus) -> KeychainAvailability {
        switch status {
        case errSecSuccess: .usable
        case errSecMissingEntitlement: .unavailable(.missingEntitlement)
        case errSecInteractionNotAllowed: .unavailable(.deviceLocked)
        default: .unavailable(.notAllowed)
        }
    }
}

public enum CloudKeySeedStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A seed for this account exists with a different value. The store never overwrites it.
    case seedConflict(accountId: String)
    case unavailable(KeychainAvailability)
    /// A stored item could not be decoded.
    case corruptItem
    /// A pending creation exists and is not the one the caller expected (add-only / compare-and-swap).
    case pendingConflict

    public var description: String {
        switch self {
        case .seedConflict(let account): "A different key is already stored for account \(account)."
        case .unavailable(let availability): "The keychain is not available (\(availability))."
        case .corruptItem: "A stored key item could not be read."
        case .pendingConflict: "Another key setup on this device changed the pending state."
        }
    }
}

/// Comparisons of secret bytes take time that depends only on the length (which is public: keys are 32 bytes).
public enum CloudKeyConstantTime {
    public static func equal(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }
}

/// The first device's key creation in progress (CK-R14 step 1). Local and non-synchronizable; it holds the master key
/// until the creation finished or was abandoned, so its description never shows it.
public struct PendingKeyCreation: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var accountId: String
    /// The account master key (32 bytes). Secret.
    public var seed: Data
    /// The bundle to create: public envelope plus canary.
    public var bundle: CloudKeyBundle
    /// `saved` or `acknowledgedSkip`, written to the library once the bundle exists.
    public var recovery: CloudRecoveryState
    public var startedAt: Date
    /// Our bundle is in the cloud (step 3 done).
    public var bundleCreated: Bool
    /// Another device's bundle won; the account id of the winner. Our own seed is removed next.
    public var lostTo: String?

    public init(accountId: String, seed: Data, bundle: CloudKeyBundle, recovery: CloudRecoveryState, startedAt: Date,
                bundleCreated: Bool = false, lostTo: String? = nil) {
        self.accountId = accountId; self.seed = seed; self.bundle = bundle; self.recovery = recovery; self.startedAt = startedAt
        self.bundleCreated = bundleCreated; self.lostTo = lostTo
    }

    public var description: String {
        "PendingKeyCreation(accountId: \(accountId), seed: <redacted>, rev: \(bundle.rev), recovery: \(recovery.rawValue), "
            + "bundleCreated: \(bundleCreated), lostTo: \(lostTo ?? "nil"))"
    }
    public var debugDescription: String { description }

    /// Mirror-based output (`dump`, test frameworks) never shows the seed.
    public var customMirror: Mirror {
        Mirror(self, children: ["accountId": accountId, "seed": "<redacted>", "rev": bundle.rev, "recovery": recovery,
                                "bundleCreated": bundleCreated, "lostTo": lostTo as Any], displayStyle: .struct)
    }

    /// The seed is compared in constant time.
    public static func == (lhs: PendingKeyCreation, rhs: PendingKeyCreation) -> Bool {
        let seedsMatch = CloudKeyConstantTime.equal(lhs.seed, rhs.seed)
        let restMatches = lhs.accountId == rhs.accountId && lhs.bundle == rhs.bundle && lhs.recovery == rhs.recovery
            && lhs.startedAt == rhs.startedAt && lhs.bundleCreated == rhs.bundleCreated && lhs.lostTo == rhs.lostTo
        return seedsMatch && restMatches
    }
}

public protocol CloudKeySeedStore: Sendable {
    /// The library namespace of the pending item. Every key operation built on a store of this namespace shares one
    /// mutex (`CloudKeySerial.shared(namespace:)`), by construction.
    var namespace: String { get }
    func seed(accountId: String) throws -> Data?
    func saveSeed(_ seed: Data, accountId: String) throws        // add-only; identical value again is ok, a different one throws
    /// Only explicit actions call this. Also clears this device's revision mark for the account.
    func removeSeed(accountId: String) throws
    func pending() throws -> PendingKeyCreation?                 // local, non-synchronizable
    /// Add-only: the same value again is a no-op, a different existing one throws `pendingConflict`.
    func savePending(_ p: PendingKeyCreation) throws; func clearPending() throws
    /// Compare-and-swap: replaces the pending creation only while it still equals `expected`, else `pendingConflict`.
    /// Atomic within this process (the store's own lock); callers also hold the namespace mutex.
    func replacePending(_ new: PendingKeyCreation, expected: PendingKeyCreation) throws
    /// The highest bundle revision this device ever verified for the account (local, non-synchronizable, kept across
    /// a library detach). nil = none.
    func highWaterMark(accountId: String) throws -> Int64?
    /// Raises the mark to `rev`; a lower or equal value changes nothing (the mark never decreases).
    func raiseHighWaterMark(_ rev: Int64, accountId: String) throws
    /// The explicit reset: forgets this device's revision mark for the account (the seed stays).
    func forgetAccount(accountId: String) throws
}

/// The throw-away probe: write a synchronizable item, read it back, remove it.
public protocol CloudKeychainProbe: Sendable {
    func probeAvailability() -> KeychainAvailability
}

/// Item names. Neutral (no working title), distinct from the Cloudflare sync item (`KeychainSyncStore.keychainService`)
/// and the note-password vault item; pinned by `synchronizableItemNeverSharesAName`.
public enum CloudKeyNames {
    public static let seedService = "cloudsync.account-seed.v1"
    public static let pendingService = "cloudsync.pending-key-creation.v1"
    public static let probeService = "cloudsync.keychain-probe.v1"
    public static let markService = "cloudsync.revision-mark.v1"
    public static let all = [seedService, pendingService, probeService, markService]
}

// MARK: - In-memory (tests, previews)

/// An in-memory iCloud Keychain shared by several `InMemoryCloudKeySeedStore` devices. With `syncsAutomatically` off,
/// a device's changes stay local until `sync()`, which models the delay of iCloud Keychain between devices.
public final class InMemoryCloudKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var cloud: [String: Data] = [:]
    private var visible: [UUID: [String: Data]] = [:]
    private var unsynced: [UUID: [(String, Data?)]] = [:]
    private var pendingItems: [UUID: Data] = [:]
    private var availability: [UUID: KeychainAvailability] = [:]
    private var readBackFails: Set<UUID> = []
    private var auto: Bool
    private var operations: [String] = []

    public init(syncsAutomatically: Bool = true) { auto = syncsAutomatically }

    public var syncsAutomatically: Bool {
        get { lock.lock(); defer { lock.unlock() }; return auto }
        set { lock.lock(); defer { lock.unlock() }; auto = newValue }
    }

    /// Uploads every device's local changes, then gives every device the cloud's set.
    public func sync() { lock.lock(); defer { lock.unlock() }; syncLocked() }

    /// "device:operation:account" entries, for tests that prove which items were touched.
    public var log: [String] { lock.lock(); defer { lock.unlock() }; return operations }

    private func syncLocked() {
        for (_, changes) in unsynced {
            for (account, value) in changes { cloud[account] = value }
        }
        unsynced = [:]
        for device in visible.keys { visible[device] = cloud }
    }

    fileprivate func register(_ device: UUID) {
        lock.lock(); defer { lock.unlock() }
        visible[device] = auto ? cloud : [:]
    }

    fileprivate func set(_ value: KeychainAvailability, readBackFails fails: Bool, for device: UUID) {
        lock.lock(); defer { lock.unlock() }
        availability[device] = value
        if fails { readBackFails.insert(device) } else { readBackFails.remove(device) }
    }

    private func requireUsable(_ device: UUID) throws {
        if let state = availability[device], state != .usable { throw CloudKeySeedStoreError.unavailable(state) }
    }

    fileprivate func seed(_ account: String, device: UUID) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        try requireUsable(device)
        return visible[device]?[account]
    }

    fileprivate func save(_ seed: Data, _ account: String, device: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        try requireUsable(device)
        if let existing = visible[device]?[account] {
            guard CloudKeyConstantTime.equal(existing, seed) else { throw CloudKeySeedStoreError.seedConflict(accountId: account) }
            return
        }
        visible[device, default: [:]][account] = seed
        unsynced[device, default: []].append((account, seed))
        operations.append("\(device):save:\(account)")
        if auto { syncLocked() }
    }

    fileprivate func remove(_ account: String, device: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        try requireUsable(device)
        visible[device]?[account] = nil
        marks[device]?[account] = nil
        unsynced[device, default: []].append((account, nil))
        operations.append("\(device):remove:\(account)")
        if auto { syncLocked() }
    }

    /// Per device, never synchronised: account id -> highest verified revision.
    private var marks: [UUID: [String: Int64]] = [:]

    fileprivate func mark(_ account: String, device: UUID) throws -> Int64? {
        lock.lock(); defer { lock.unlock() }
        try requireUsable(device)
        return marks[device]?[account]
    }

    fileprivate func raiseMark(_ rev: Int64, _ account: String, device: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        try requireUsable(device)
        if rev > (marks[device]?[account] ?? Int64.min) { marks[device, default: [:]][account] = rev }
    }

    fileprivate func forgetMark(_ account: String, device: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        try requireUsable(device)
        marks[device]?[account] = nil
        operations.append("\(device):forget:\(account)")
    }

    fileprivate func pending(device: UUID) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        try requireUsable(device)
        return pendingItems[device]
    }

    /// Atomically decides the next pending value from the current one (nil result: remove).
    fileprivate func updatePending(device: UUID, _ next: (PendingKeyCreation?) throws -> PendingKeyCreation?) throws {
        lock.lock(); defer { lock.unlock() }
        try requireUsable(device)
        let current = try pendingItems[device].map { data in
            guard let value = try? JSONDecoder().decode(PendingKeyCreation.self, from: data) else { throw CloudKeySeedStoreError.corruptItem }
            return value
        }
        pendingItems[device] = try next(current).map { try JSONEncoder().encode($0) }
    }

    fileprivate func probe(device: UUID) -> KeychainAvailability {
        lock.lock(); defer { lock.unlock() }
        if let state = availability[device], state != .usable { return state }
        if readBackFails.contains(device) { return .failedReadBack }
        operations.append("\(device):probe")
        return .usable
    }
}

/// One device's view of an `InMemoryCloudKeychain`.
public final class InMemoryCloudKeySeedStore: CloudKeySeedStore, CloudKeychainProbe, @unchecked Sendable {
    public let keychain: InMemoryCloudKeychain
    public let deviceId = UUID()
    public let namespace: String

    public init(keychain: InMemoryCloudKeychain = InMemoryCloudKeychain(), namespace: String? = nil) {
        self.keychain = keychain
        self.namespace = namespace ?? "in-memory.\(deviceId.uuidString)"
        keychain.register(deviceId)
    }

    public func highWaterMark(accountId: String) throws -> Int64? { try keychain.mark(accountId, device: deviceId) }
    public func raiseHighWaterMark(_ rev: Int64, accountId: String) throws { try keychain.raiseMark(rev, accountId, device: deviceId) }
    public func forgetAccount(accountId: String) throws { try keychain.forgetMark(accountId, device: deviceId) }

    /// Makes every operation fail as a keychain call with this status would (e.g. -34018, -25308).
    public func simulate(status: OSStatus) { keychain.set(.classify(status: status), readBackFails: false, for: deviceId) }
    /// Writes succeed but the probe's read-back does not return the value.
    public func simulateReadBackFailure() { keychain.set(.usable, readBackFails: true, for: deviceId) }
    public func restoreAvailability() { keychain.set(.usable, readBackFails: false, for: deviceId) }

    public func seed(accountId: String) throws -> Data? { try keychain.seed(accountId, device: deviceId) }
    public func saveSeed(_ seed: Data, accountId: String) throws { try keychain.save(seed, accountId, device: deviceId) }
    public func removeSeed(accountId: String) throws { try keychain.remove(accountId, device: deviceId) }

    public func pending() throws -> PendingKeyCreation? {
        guard let data = try keychain.pending(device: deviceId) else { return nil }
        guard let value = try? JSONDecoder().decode(PendingKeyCreation.self, from: data) else { throw CloudKeySeedStoreError.corruptItem }
        return value
    }
    public func savePending(_ p: PendingKeyCreation) throws {
        try keychain.updatePending(device: deviceId) { current in
            if let current, current != p { throw CloudKeySeedStoreError.pendingConflict }
            return p
        }
    }
    public func replacePending(_ new: PendingKeyCreation, expected: PendingKeyCreation) throws {
        try keychain.updatePending(device: deviceId) { current in
            guard let current, current == expected else { throw CloudKeySeedStoreError.pendingConflict }
            return new
        }
    }
    public func clearPending() throws { try keychain.updatePending(device: deviceId) { _ in nil } }

    public func probeAvailability() -> KeychainAvailability { keychain.probe(device: deviceId) }
}

// MARK: - Keychain (the app)

/// The real store: data-protection keychain, access group `AppIdentity.keychainAccessGroup`.
/// - Seed: `kSecAttrSynchronizable = true`, `kSecAttrAccessibleAfterFirstUnlock` (a `ThisDeviceOnly` class cannot sync),
///   service `CloudKeyNames.seedService`, account = the account id. Add-only.
/// - Pending creation: `kSecAttrSynchronizable = false`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
///   service `CloudKeyNames.pendingService`, account `pending.<namespace>`.
/// Apple: "Updating or deleting items using the kSecAttrSynchronizable key affects all copies of the item, not just the one
/// on your local device" (https://developer.apple.com/documentation/security/ksecattrsynchronizable), so `removeSeed` is
/// only called for our own seed after a lost creation race or by the explicit "Remove the iCloud key" action (CK-R9).
/// Runs only in a team-signed host (Gate G0); an unsigned process gets -34018.
public struct KeychainCloudKeySeedStore: CloudKeySeedStore, CloudKeychainProbe {
    public let accessGroup: String
    public let namespace: String

    public init(namespace: String, accessGroup: String = AppIdentity.current.keychainAccessGroup) {
        self.namespace = namespace; self.accessGroup = accessGroup
    }

    static func base(service: String, account: String, synchronizable: Bool, accessGroup: String) -> [CFString: Any] {
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                                      kSecAttrSynchronizable: synchronizable ? kCFBooleanTrue as Any : kCFBooleanFalse as Any,
                                      kSecAttrAccessGroup: accessGroup]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain] = true
        #endif
        return query
    }

    func seedQuery(accountId: String) -> [CFString: Any] {
        Self.base(service: CloudKeyNames.seedService, account: accountId, synchronizable: true, accessGroup: accessGroup)
    }
    func pendingQuery() -> [CFString: Any] {
        Self.base(service: CloudKeyNames.pendingService, account: "pending.\(namespace)", synchronizable: false, accessGroup: accessGroup)
    }
    func probeQuery(account: String) -> [CFString: Any] {
        Self.base(service: CloudKeyNames.probeService, account: account, synchronizable: true, accessGroup: accessGroup)
    }
    /// The attributes an add uses: the seed and probe sync, so they must not be `ThisDeviceOnly`.
    static func addAttributes(_ query: [CFString: Any], value: Data, synchronizable: Bool) -> [CFString: Any] {
        var attributes = query
        attributes[kSecValueData] = value
        attributes[kSecAttrAccessible] = synchronizable ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return attributes
    }

    private static func read(_ query: [CFString: Any]) throws -> Data? {
        var search = query
        search[kSecReturnData] = true
        search[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CloudKeySeedStoreError.unavailable(.classify(status: status)) }
        guard let data = result as? Data else { throw CloudKeySeedStoreError.corruptItem }
        return data
    }

    private static func delete(_ query: [CFString: Any]) throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CloudKeySeedStoreError.unavailable(.classify(status: status)) }
    }

    public func seed(accountId: String) throws -> Data? { try Self.read(seedQuery(accountId: accountId)) }

    public func saveSeed(_ seed: Data, accountId: String) throws {
        let query = seedQuery(accountId: accountId)
        let status = SecItemAdd(Self.addAttributes(query, value: seed, synchronizable: true) as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard let existing = try Self.read(query), CloudKeyConstantTime.equal(existing, seed) else {
                throw CloudKeySeedStoreError.seedConflict(accountId: accountId)
            }
            return
        }
        guard status == errSecSuccess else { throw CloudKeySeedStoreError.unavailable(.classify(status: status)) }
    }

    /// Removes the synchronizable seed (every device) and this device's revision mark for the account.
    public func removeSeed(accountId: String) throws {
        try Self.delete(seedQuery(accountId: accountId))
        try Self.atomically { try Self.delete(markQuery(accountId: accountId)) }
    }

    public func pending() throws -> PendingKeyCreation? {
        guard let data = try Self.read(pendingQuery()) else { return nil }
        guard let value = try? JSONDecoder().decode(PendingKeyCreation.self, from: data) else { throw CloudKeySeedStoreError.corruptItem }
        return value
    }

    /// The keychain has no compare-and-swap. Read-compare-write sequences of this store (pending item, revision mark) run
    /// under this process-wide lock, so they are atomic within the app; callers additionally hold the namespace mutex
    /// (`CloudKeySerial`). Another process writing the same items is not covered (only the app holds the entitlement).
    private static let itemLock = NSLock()
    private static func atomically<T>(_ body: () throws -> T) rethrows -> T {
        itemLock.lock(); defer { itemLock.unlock() }
        return try body()
    }

    /// Add-only (SecItemAdd fails on a duplicate; an identical value again is a no-op).
    public func savePending(_ p: PendingKeyCreation) throws {
        try Self.atomically {
            let query = pendingQuery()
            let status = SecItemAdd(Self.addAttributes(query, value: try JSONEncoder().encode(p), synchronizable: false) as CFDictionary, nil)
            if status == errSecDuplicateItem {
                guard try pending() == p else { throw CloudKeySeedStoreError.pendingConflict }
                return
            }
            guard status == errSecSuccess else { throw CloudKeySeedStoreError.unavailable(.classify(status: status)) }
        }
    }

    /// Compare-and-swap only under the store's lock (see `atomically`).
    public func replacePending(_ new: PendingKeyCreation, expected: PendingKeyCreation) throws {
        try Self.atomically {
            guard let current = try pending(), current == expected else { throw CloudKeySeedStoreError.pendingConflict }
            let update: [CFString: Any] = [kSecValueData: try JSONEncoder().encode(new),
                                           kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            let updated = SecItemUpdate(pendingQuery() as CFDictionary, update as CFDictionary)
            guard updated == errSecSuccess else { throw CloudKeySeedStoreError.unavailable(.classify(status: updated)) }
        }
    }

    /// The revision mark: not synchronizable, `kSecAttrAccessibleAfterFirstUnlock` (it may move with an encrypted backup
    /// to a restored device, which keeps the rollback protection), account = the account id, value = decimal revision.
    func markQuery(accountId: String) -> [CFString: Any] {
        Self.base(service: CloudKeyNames.markService, account: accountId, synchronizable: false, accessGroup: accessGroup)
    }

    public func highWaterMark(accountId: String) throws -> Int64? {
        guard let data = try Self.read(markQuery(accountId: accountId)) else { return nil }
        guard let value = Int64(String(decoding: data, as: UTF8.self)) else { throw CloudKeySeedStoreError.corruptItem }
        return value
    }

    public func raiseHighWaterMark(_ rev: Int64, accountId: String) throws {
        try Self.atomically {
            let current = try highWaterMark(accountId: accountId)
            if let current, current >= rev { return }
            let query = markQuery(accountId: accountId)
            let value = Data(String(rev).utf8)
            let status: OSStatus
            if current == nil {
                var attributes = query
                attributes[kSecValueData] = value
                attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
                status = SecItemAdd(attributes as CFDictionary, nil)
            } else {
                status = SecItemUpdate(query as CFDictionary, [kSecValueData: value] as CFDictionary)
            }
            guard status == errSecSuccess else { throw CloudKeySeedStoreError.unavailable(.classify(status: status)) }
        }
    }

    public func forgetAccount(accountId: String) throws {
        try Self.atomically { try Self.delete(markQuery(accountId: accountId)) }
    }

    public func clearPending() throws { try Self.delete(pendingQuery()) }

    public func probeAvailability() -> KeychainAvailability {
        let query = probeQuery(account: "probe.\(UUID().uuidString)")
        var value = Data(count: 16)
        for index in value.indices { value[index] = UInt8.random(in: 0...255) }
        let added = SecItemAdd(Self.addAttributes(query, value: value, synchronizable: true) as CFDictionary, nil)
        guard added == errSecSuccess else { return .classify(status: added) }
        defer { try? Self.delete(query) }
        do {
            guard try Self.read(query) == value else { return .failedReadBack }
        } catch CloudKeySeedStoreError.unavailable(let availability) {
            return availability
        } catch {
            return .failedReadBack
        }
        return .usable
    }
}
