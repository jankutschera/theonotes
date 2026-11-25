// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import CryptoKit
import Foundation
import Observation

/// The unlocked state of the library's protected notes on the Mac, for the whole process.
///
/// One vault per library environment. It unlocks through `NotePrivacy` (password) or
/// `NotePrivacy.restoreAccess` (key cached in the Keychain behind Touch ID), keeps the resulting
/// `LockedNoteAccess` for the session, and revokes it on the relock triggers. Sessions of locked
/// notes use `access` and are flushed by `addWillRelockHandler` handlers before it is revoked.
/// No UI lives here: lock views, sheets and Settings call this API.
@MainActor @Observable
final class NoteVault {
    enum BiometricOutcome: Equatable, Sendable {
        case unlocked
        /// The user dismissed the prompt or failed the check; the cached item is kept.
        case cancelled
        /// No password, no biometry, the opt-out is on: the caller asks for the password.
        case unavailable
        /// The Keychain cannot be used right now (screen or Mac locked, -25308). The item is kept,
        /// not treated as stale; the caller asks for the password and may offer Touch ID later.
        case temporarilyUnavailable
        /// Nothing is cached (yet): the caller asks for the password, which caches the key again.
        case noCachedKey
        /// The cached item did not match the library any more and was deleted: ask for the password.
        case staleCacheRemoved
    }

    /// The result of the last privacy cleanup after a relock (`finishPendingCleanupWithRetry`).
    enum CleanupState: Equatable, Sendable {
        /// A cleanup cycle is running (or queued behind a newer relock). Never `.clean` until the
        /// last pass for the newest relock has finished.
        case cleaning
        case clean
        /// Still blocked after the retries (a reader holds the WAL, a batch is pending). Retried
        /// on the next relock event, launch or `retryPendingCleanup()`.
        case pending
        /// Another error; the associated text is a `PrivacyErrorCode`, never note content.
        case failed(String)
    }

    struct HandlerToken: Hashable, Sendable { fileprivate let id: Int }

    /// The access of the current unlocked session; nil while locked. Sessions of locked notes are
    /// created with it and its `journalKey()`.
    private(set) var access: LockedNoteAccess?
    var isUnlocked: Bool { access != nil }
    private(set) var hasPassword: Bool
    private(set) var cleanupState: CleanupState = .clean
    var isAuthenticating: Bool { authenticationDepth > 0 }

    @ObservationIgnored private let store: NoteStore
    @ObservationIgnored private let privacy: NotePrivacy
    @ObservationIgnored private let settings: TheoNotesCore.Settings
    @ObservationIgnored private let cache: any VaultKeyCache
    @ObservationIgnored private let account: String
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let cleanup: @Sendable () async throws -> Void
    @ObservationIgnored private var lifecycleObservation: (any VaultLifecycleObservation)?
    @ObservationIgnored private var willRelock: [(token: HandlerToken, handler: @MainActor () -> Void)] = []
    @ObservationIgnored private var didRelock: [(token: HandlerToken, handler: @MainActor () -> Void)] = []
    @ObservationIgnored private var didUnlock: [(token: HandlerToken, handler: @MainActor () -> Void)] = []
    @ObservationIgnored private var relockBarriers: [@MainActor () async -> Void] = []
    @ObservationIgnored private var nextHandlerId = 0
    @ObservationIgnored private var authenticationDepth = 0
    /// Bumped by every relock: an unlock that was waiting for its key derivation or its prompt
    /// while a relock happened discards its result.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    /// Counts relock requests; the cleanup loop runs again while a newer one arrived during a pass.
    @ObservationIgnored private var cleanupRequests = 0

    /// `cleanup` defaults to `NotePrivacy.finishPendingCleanupWithRetry()`; tests inject their own.
    init(store: NoteStore, settings: TheoNotesCore.Settings, cache: any VaultKeyCache, account: String,
         lifecycle: (any VaultLifecycleSource)? = nil, clock: any Clock<Duration> = ContinuousClock(),
         cleanup: (@Sendable () async throws -> Void)? = nil) {
        let privacy = NotePrivacy(store: store)
        self.store = store
        self.privacy = privacy
        self.settings = settings
        self.cache = cache
        self.account = account
        self.clock = clock
        self.cleanup = cleanup ?? { try await privacy.finishPendingCleanupWithRetry() }
        hasPassword = (try? privacy.hasPassword) ?? false
        lifecycleObservation = lifecycle?.observe { [weak self] event in self?.handle(event) }
    }

    // MARK: State for views

    /// The unlocked access, or `accessRevoked` while locked.
    func requireAccess() throws -> LockedNoteAccess {
        guard let access else { throw NotePrivacyError.accessRevoked }
        return access
    }

    /// Whether the lock view should offer Touch ID: a password exists, biometry is usable and
    /// enabled, and an item is cached for this library. Never prompts.
    var canUnlockWithBiometrics: Bool {
        hasPassword && cache.isAvailable && settings.useTouchIDForNotes && cache.contains(account: account)
    }

    /// Whether Settings can offer the Touch ID option at all.
    var biometricUnlockSupported: Bool { cache.isAvailable }

    /// Re-reads whether a password exists (after a restore or a sync that may have changed it).
    func refresh() { hasPassword = (try? privacy.hasPassword) ?? false }

    // MARK: Password and unlock

    /// Sets the library's first Note Password. The vault is then unlocked.
    func createPassword(_ password: String) async throws {
        let generation = generation
        let privacy = privacy
        let new = try await Task.detached(priority: .userInitiated) { try privacy.setPassword(password) }.value
        hasPassword = true
        guard generation == self.generation else { new.revoke(); throw NotePrivacyError.accessRevoked }
        adopt(new)
        cacheIfAllowed(new)
    }

    /// Unlocks with the Note Password. Throws `CryptoError.wrongPassword` for a wrong one. A
    /// success re-caches the key when the cache is allowed.
    func unlock(password: String) async throws {
        let generation = generation
        let privacy = privacy
        let new = try await Task.detached(priority: .userInitiated) { try privacy.unlock(password: password) }.value
        guard generation == self.generation else { new.revoke(); throw NotePrivacyError.accessRevoked }
        adopt(new)
        if let access { cacheIfAllowed(access) }
    }

    /// Unlocks with the key cached behind Touch ID. The system prompt is the authentication; a
    /// resign while it is up does not relock (`isAuthenticating`). A relock invalidates the prompt
    /// and discards (and wipes) whatever it returned.
    func unlockWithBiometrics() async throws -> BiometricOutcome {
        guard hasPassword, cache.isAvailable, settings.useTouchIDForNotes else { return .unavailable }
        guard cache.contains(account: account) else { return .noCachedKey }
        let generation = generation
        beginAuthentication()
        defer { endAuthentication() }
        let cached: CachedVaultKey?
        do {
            cached = try await cache.load(account: account, reason: "Unlock your protected notes")
        } catch VaultKeyCacheError.cancelled {
            return .cancelled
        } catch VaultKeyCacheError.unavailableNow {
            return .temporarilyUnavailable
        } catch VaultKeyCacheError.corrupt {
            try cache.remove(account: account)
            return .staleCacheRemoved
        }
        guard let cached else { return .noCachedKey }
        defer { cached.key.wipe() }
        guard generation == self.generation else { throw NotePrivacyError.accessRevoked }
        let privacy = privacy
        let restored: LockedNoteAccess
        do {
            restored = try await Task.detached(priority: .userInitiated) {
                try privacy.restoreAccess(vaultKey: cached.key.symmetricKey(), matching: cached.envelope)
            }.value
        } catch NotePrivacyError.accessRevoked, CryptoError.tampered, CryptoError.malformed {
            // The envelope moved on (password changed, library replaced) or the key opens nothing.
            try cache.remove(account: account)
            return .staleCacheRemoved
        }
        guard generation == self.generation else { restored.revoke(); throw NotePrivacyError.accessRevoked }
        adopt(restored)
        return .unlocked
    }

    /// Changes the Note Password. Only the wrapped key changes. Fail closed: the cached item is
    /// deleted (and read back as gone) first; if that fails nothing is changed. If the vault is
    /// unlocked the same vault key is cached again under the new envelope.
    func changePassword(old: String, new: String) async throws {
        try cache.remove(account: account)
        let privacy = privacy
        do {
            try await Task.detached(priority: .userInitiated) { try privacy.changePassword(from: old, to: new) }.value
        } catch {
            if let access { cacheIfAllowed(access) }
            throw error
        }
        if let access {
            try await Task.detached(priority: .userInitiated) { try access.acceptPasswordRewrap(password: new) }.value
        }
        if let access { cacheIfAllowed(access) }
    }

    /// The library's envelope was replaced by something other than this vault (a sync adopted a
    /// remote password, a backup was restored). The vault relocks first, then the cached key is
    /// deleted; a failed deletion is thrown (the stale item is refused by the envelope check anyway).
    func envelopeReplaced() throws {
        refresh()
        relock()
        try cache.remove(account: account)
    }

    /// Before Remove Password (the emergency reset): flush and revoke, wait for the privacy
    /// cleanup, then delete the cached key. Only after this returns may the caller delete the
    /// envelope (`NotePrivacy.deletePassword()`) and call `refresh()`. Throws, and the caller must
    /// not delete the envelope, if the cleanup is not clean or the cache item cannot be deleted.
    func resetForRemovePassword() async throws {
        relock()
        await cleanupTask?.value
        guard cleanupState == .clean else { throw NotePrivacyError.cleanupPending }
        try cache.remove(account: account)
    }

    /// Settings: the Touch ID cache on or off (default off: no item exists before an explicit
    /// opt-in). Off deletes the item first and throws if it cannot; on caches the key at once while
    /// unlocked (and is undone if that fails), otherwise at the next password unlock.
    func setUsesBiometricUnlock(_ enabled: Bool) throws {
        if !enabled { try cache.remove(account: account) }
        try settings.set(.useTouchIDForNotes, to: enabled)
        guard enabled, let access else { return }
        do { try storeKey(of: access) } catch {
            try? settings.set(.useTouchIDForNotes, to: false)
            throw error
        }
    }

    // MARK: Authentication scope

    /// Call while a password sheet or another prompt of ours is up: a resign then does not start
    /// the relock countdown. Calls nest.
    func beginAuthentication() { authenticationDepth += 1 }
    func endAuthentication() { authenticationDepth = max(0, authenticationDepth - 1) }

    // MARK: Relock

    /// Runs on every relock while the vault is unlocked, in registration order, before the access
    /// is revoked. Sessions of locked notes flush here.
    @discardableResult
    func addWillRelockHandler(_ handler: @escaping @MainActor () -> Void) -> HandlerToken {
        nextHandlerId += 1
        let token = HandlerToken(id: nextHandlerId)
        willRelock.append((token, handler))
        return token
    }

    func removeWillRelockHandler(_ token: HandlerToken) { willRelock.removeAll { $0.token == token } }

    /// Runs right after a relock revoked the access (`access` is nil): sessions of locked notes
    /// are closed here, so none outlives the key it holds a copy of.
    @discardableResult
    func addDidRelockHandler(_ handler: @escaping @MainActor () -> Void) -> HandlerToken {
        nextHandlerId += 1
        let token = HandlerToken(id: nextHandlerId)
        didRelock.append((token, handler))
        return token
    }

    /// Runs when the vault went from locked to unlocked (`access` is set): sealed journals are
    /// replayed and editors showing a lock view open their note.
    @discardableResult
    func addDidUnlockHandler(_ handler: @escaping @MainActor () -> Void) -> HandlerToken {
        nextHandlerId += 1
        let token = HandlerToken(id: nextHandlerId)
        didUnlock.append((token, handler))
        return token
    }

    /// Flushes through the handlers, revokes the access, then requests the privacy cleanup (see
    /// `cleanupState`; M9M-R15). Safe to call while locked: it cancels a pending unlock and a countdown.
    func relock() {
        generation &+= 1
        idleTask?.cancel()
        idleTask = nil
        // An unlock prompt still up must not produce a key after this point.
        cache.invalidatePendingPrompts()
        guard let current = access else {
            if cleanupState != .clean { requestCleanup() }
            return
        }
        // A failed flush must not keep the key: acknowledged edits are in the encrypted journal
        // and are replayed at the next unlock.
        for entry in willRelock { entry.handler() }
        current.revoke()
        access = nil
        for entry in didRelock { entry.handler() }
        requestCleanup()
    }

    /// Work a relock is not finished without, beyond revoking the key: the editors confirming
    /// that their pages dropped the notes they showed. Run in order by `relockAndFinishCleanup()`.
    func addRelockBarrier(_ barrier: @escaping @MainActor () async -> Void) {
        relockBarriers.append(barrier)
    }

    /// `relock()`, then waits for the relock barriers (editor pages cleared) and the cleanup it started.
    func relockAndFinishCleanup() async {
        relock()
        for barrier in relockBarriers { await barrier() }
        await cleanupTask?.value
    }

    /// Runs the cleanup now (launch, a retry button, the next unlock).
    func retryPendingCleanup() async { await requestCleanup().value }

    /// Launch recovery: finishes lock transitions a crash left behind, off the cleanup retry loop
    /// (the library is not shown yet). A blocked one is reported as `cleanupState == .pending`.
    func recoverAtLaunch() {
        do {
            try privacy.finishPendingCleanup()
            cleanupState = .clean
        } catch NotePrivacyError.cleanupPending {
            cleanupState = .pending
            appLogger.notice("privacy cleanup still pending at launch")
        } catch {
            let code = PrivacyErrorCode.code(for: error)
            cleanupState = .failed(code)
            appLogger.error("privacy cleanup failed at launch: \(code, privacy: .public)")
        }
    }

    /// Waits for a pending relock countdown and a running cleanup (tests, shutdown).
    func waitForPendingWork() async {
        await idleTask?.value
        await cleanupTask?.value
    }

    // MARK: Private

    private func adopt(_ new: LockedNoteAccess) {
        if access != nil {
            // Sessions already hold the current access; the new one only proved the password.
            new.revoke()
        } else {
            access = new
            for entry in didUnlock { entry.handler() }
        }
    }

    private func cacheIfAllowed(_ access: LockedNoteAccess) {
        guard cache.isAvailable, settings.useTouchIDForNotes else { return }
        do { try storeKey(of: access) } catch {
            // Touch ID is a convenience: a failed cache write never fails the unlock.
            appLogger.error("note key cache not stored: \(PrivacyErrorCode.code(for: error), privacy: .public)")
        }
    }

    private func storeKey(of access: LockedNoteAccess) throws {
        guard let envelope = try privacy.envelope() else { return }
        let secret = SecretBytes(key: try access.journalKey())
        defer { secret.wipe() }
        try cache.store(CachedVaultKey(envelope: envelope, key: secret), account: account)
    }

    private func handle(_ event: VaultLifecycleEvent) {
        switch event {
        case .appBecameActive:
            idleTask?.cancel()
            idleTask = nil
        case .deviceLocked:
            relock()
        case .appResigned:
            guard isUnlocked, !isAuthenticating, idleTask == nil else { return }
            let delay = settings.noteRelockDelay
            guard delay > 0 else { return relock() }
            let clock = clock
            idleTask = Task { [weak self] in
                do { try await clock.sleep(for: .seconds(delay)) } catch { return }
                guard !Task.isCancelled, let self else { return }
                self.idleTask = nil
                self.relock()
            }
        }
    }

    /// One loop at a time. A request that arrives while a pass runs makes the loop run again once
    /// that pass is over, so a transition created after the pass's snapshot is never missed; the
    /// state is `.clean` only when the last pass for the newest request finished clean.
    @discardableResult
    private func requestCleanup() -> Task<Void, Never> {
        cleanupRequests &+= 1
        if let cleanupTask { return cleanupTask }
        cleanupState = .cleaning
        let run = cleanup
        let task = Task { [weak self] in
            while true {
                guard let target = self?.cleanupRequests else { return }
                var outcome: CleanupState
                do {
                    try await run()
                    outcome = .clean
                } catch NotePrivacyError.cleanupPending {
                    outcome = .pending
                } catch is CancellationError {
                    outcome = .pending  // the durable transition stays for a later attempt
                } catch {
                    outcome = .failed(PrivacyErrorCode.code(for: error))
                }
                guard let self else { return }
                if cleanupRequests != target { continue }
                cleanupState = outcome
                cleanupTask = nil
                if outcome != .clean { appLogger.notice("privacy cleanup after relock: \(String(describing: outcome), privacy: .public)") }
                return
            }
        }
        cleanupTask = task
        return task
    }
}
