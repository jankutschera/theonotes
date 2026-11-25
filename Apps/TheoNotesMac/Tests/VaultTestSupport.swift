// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
@testable import TheoNotes

/// A clock a test advances by hand. `sleep` suspends until `advance` passes its deadline.
final class ManualVaultClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Swift.Duration
        func advanced(by duration: Swift.Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Swift.Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }
    private typealias Sleeper = (deadline: Instant, continuation: CheckedContinuation<Void, any Error>)

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [UUID: Sleeper] = [:]

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Swift.Duration { .zero }
    var sleeperCount: Int { lock.withLock { sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if deadline <= current {
                    lock.unlock()
                    continuation.resume()
                } else {
                    sleepers[id] = (deadline, continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            let sleeper = lock.withLock { sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Swift.Duration) {
        let ready: [Sleeper] = lock.withLock {
            current = current.advanced(by: duration)
            let due = sleepers.filter { $0.value.deadline <= current }
            for key in due.keys { sleepers.removeValue(forKey: key) }
            return Array(due.values)
        }
        for sleeper in ready { sleeper.continuation.resume() }
    }

    /// The vault's pending relock registers its sleep on a task; wait until it is there.
    @MainActor func waitForSleeper() async {
        for _ in 0..<1000 where sleeperCount == 0 { await Task.yield() }
    }
}

/// An in-memory `VaultKeyCache`. `loadBehavior` decides what a biometric prompt does; `holdLoads`
/// keeps a prompt "up" until `releaseLoads()`. Like the real cache it never keeps the caller's
/// buffer (the vault wipes it) and hands out a fresh copy on every load.
final class FakeVaultKeyCache: VaultKeyCache, @unchecked Sendable {
    enum LoadBehavior { case item, cancel, corrupt, interactionNotAllowed }
    private let lock = NSLock()
    private var storage: [String: CachedVaultKey] = [:]
    private var removedLog: [String] = []
    private var loadCount = 0
    private var invalidationCount = 0
    private var storedInputs: [CachedVaultKey] = []
    private var loadedOutputs: [CachedVaultKey] = []
    private var held: [CheckedContinuation<Void, Never>] = []
    private var holding = false
    var available: Bool = true
    var loadBehavior: LoadBehavior = .item
    /// A removal that fails: the item stays (the real cache throws `notRemoved`).
    var removeFails = false

    var isAvailable: Bool { available }
    var items: [String: CachedVaultKey] { lock.withLock { storage } }
    var removed: [String] { lock.withLock { removedLog } }
    var loads: Int { lock.withLock { loadCount } }
    var invalidations: Int { lock.withLock { invalidationCount } }
    /// The objects the vault passed to `store`, to check they were wiped afterwards.
    var storeInputs: [CachedVaultKey] { lock.withLock { storedInputs } }
    /// The objects `load` returned, to check the vault wiped them.
    var loadOutputs: [CachedVaultKey] { lock.withLock { loadedOutputs } }

    func holdLoads() { lock.withLock { holding = true } }
    func releaseLoads() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            holding = false
            let copy = held
            held = []
            return copy
        }
        for continuation in waiting { continuation.resume() }
    }

    func store(_ cached: CachedVaultKey, account: String) throws {
        lock.withLock {
            storedInputs.append(cached)
            storage[account] = cached.copy()
        }
    }
    func contains(account: String) -> Bool { lock.withLock { storage[account] != nil } }
    func load(account: String, reason: String) async throws -> CachedVaultKey? {
        lock.withLock { loadCount += 1 }
        if lock.withLock({ holding }) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { () -> Bool in
                    if holding { held.append(continuation); return false }
                    return true
                }
                if resumeNow { continuation.resume() }
            }
        }
        switch loadBehavior {
        case .cancel: throw VaultKeyCacheError.cancelled
        case .corrupt: throw VaultKeyCacheError.corrupt
        case .interactionNotAllowed: throw VaultKeyCacheError.unavailableNow
        case .item:
            return lock.withLock {
                guard let item = storage[account] else { return nil }
                let out = item.copy()
                loadedOutputs.append(out)
                return out
            }
        }
    }
    func remove(account: String) throws {
        try lock.withLock {
            removedLog.append(account)
            if removeFails { throw VaultKeyCacheError.notRemoved }
            storage[account] = nil
        }
    }
    func invalidatePendingPrompts() { lock.withLock { invalidationCount += 1 } }
}

/// Lets a test deliver lifecycle events by hand.
@MainActor
final class ManualLifecycleSource: VaultLifecycleSource {
    private final class Token: VaultLifecycleObservation {}
    private var handler: (@MainActor (VaultLifecycleEvent) -> Void)?
    private weak var token: Token?
    var isObserved: Bool { token != nil }

    func observe(_ handler: @escaping @MainActor (VaultLifecycleEvent) -> Void) -> any VaultLifecycleObservation {
        self.handler = handler
        let token = Token()
        self.token = token
        return token
    }
    func send(_ event: VaultLifecycleEvent) { handler?(event) }
}

/// A temporary library with the store, settings and an unlocked-capable vault.
@MainActor
struct VaultLibrary {
    let paths: AppPaths
    let database: AppDatabase
    let store: NoteStore
    let settings: TheoNotesCore.Settings
    let cache = FakeVaultKeyCache()
    let clock = ManualVaultClock()
    let lifecycle = ManualLifecycleSource()
    static let account = "test-library"

    /// `optIn` sets `useTouchIDForNotes` (off by default in the app, so most tests turn it on).
    init(optIn: Bool = true) throws {
        paths = AppPaths(root: URL(fileURLWithPath: "/tmp/theo-vault-\(UUID().uuidString.prefix(8))", isDirectory: true))
        try paths.createDirectories()
        database = try AppDatabase(path: paths.database)
        store = NoteStore(db: database, notifier: nil, paths: paths)
        settings = TheoNotesCore.Settings(db: database)
        settings.useTouchIDForNotes = optIn
    }

    func makeVault(cleanup: (@Sendable () async throws -> Void)? = nil) -> NoteVault {
        NoteVault(store: store, settings: settings, cache: cache, account: Self.account,
                  lifecycle: lifecycle, clock: clock, cleanup: cleanup)
    }

    func destroy() {
        try? database.pool.close()
        try? FileManager.default.removeItem(at: paths.root)
    }
}

extension SecretBytes {
    var dataForTesting: Data { withUnsafeBytes { Data($0) } }
}
