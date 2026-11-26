// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import Synchronization
import GRDB

// The CloudKit sync coordinator (Task 10): the one object a Mac or iOS app owns per library. It wires the parts the earlier
// tasks built (store, publisher, receiver, blob transfer, key layer, account fence, gateway) and runs the first sync, the
// ordinary cycles, the launch recovery and the account lifecycle. It is written once for both apps; the Cloudflare controllers
// are not built on it.

/// What the coordinator needs from the app that owns the library. The Mac and iOS apps implement it; tests implement it over a
/// temporary library.
public enum CloudJournalRecoveryState: Sendable, Equatable { case ready, waitingForKey, blocked }

public protocol CloudSyncLibrary: Sendable {
    var database: AppDatabase { get }
    var paths: AppPaths { get }
    /// `.localOnly` for a library copy (`--data-dir`): such a library never syncs, decided at launch.
    var syncPolicy: SyncLaunchPolicy { get }
    /// A verified backup of the whole library; returns its id. The first sync waits for it.
    func makeBackup() async throws -> String
    /// Throws unless `password` opens the library's note password (a wrong one is `CryptoError.wrongPassword`).
    func verifyNotePassword(_ password: String) async throws
    var hasNotePassword: Bool { get throws }
    /// Coordinates the synchronous local mutation of a fetched change with open editor sessions.
    var commitCoordinator: (any SyncCommitCoordinator)? { get }
    /// Commits what open editors hold, so that the cycle sees it.
    func flushForSync() async throws
    func journalRecoveryState() async -> CloudJournalRecoveryState
    func withJournalKeyInstall(_ install: @Sendable () async throws -> Bool) async throws -> Bool
    func recoverJournalsAfterKey(password: String) async throws
    func offerJournalMoveAsideForUnavailableKey() async throws
}

extension CloudSyncLibrary {
    public var syncPolicy: SyncLaunchPolicy { .enabled }
    public var commitCoordinator: (any SyncCommitCoordinator)? { nil }
    public func flushForSync() async throws {}
    private var privacy: NotePrivacy { NotePrivacy(store: NoteStore(db: database, notifier: nil, paths: paths)) }
    public var hasNotePassword: Bool { get throws { try privacy.hasPassword } }
    public func verifyNotePassword(_ password: String) async throws {
        let privacy = self.privacy
        let access = try await Task.detached(priority: .userInitiated) { try privacy.unlock(password: password) }.value
        access.revoke()
    }
}

public enum CloudCoordinatorError: Error, Equatable, Sendable {
    /// A library copy or a `--data-dir` library never syncs.
    case libraryCopyNeverSyncs
    /// The library syncs through the Cloudflare engine; changing the service goes through `SyncAccountDetach`.
    case boundToCloudflare
    /// Another coordinator, in this process or another, already owns this library.
    case ownedElsewhere
    /// The first device needs the person's choice about the recovery key (CK-J1) before keys can be made.
    case recoveryChoiceRequired
    case backupNotVerified
    /// `syncNow` was called while the coordinator is not running (`enable` or `launch` first).
    case notRunning
    /// The iCloud account the device reports is not the one this library is bound to (or cannot be told right now): a destructive
    /// or key-changing action does nothing.
    case accountNotCurrent
    /// "Upload again" needs the verified key bundle this library kept (`ck_state.keyBundleCache`); it is missing or does not
    /// authenticate against the account, revision and seed this library pins. Nothing was changed.
    case keyBundleCacheMissing
}

/// How the blob transfer is configured (part size and timing are tests' business; the defaults are the shipped ones).
public struct CloudBlobSettings: Sendable {
    public var partBytes: Int
    public var timing: CloudBlobTiming
    public var freeBytes: (@Sendable () -> Int64)?
    public var diagnostics: CloudBlobDiagnostics
    public init(partBytes: Int = 33_554_432, timing: CloudBlobTiming = CloudBlobTiming(), freeBytes: (@Sendable () -> Int64)? = nil,
                diagnostics: CloudBlobDiagnostics = CloudBlobDiagnostics()) {
        self.partBytes = partBytes; self.timing = timing; self.freeBytes = freeBytes; self.diagnostics = diagnostics
    }
}

/// The keychain a coordinator uses: the seed store and the availability probe (`KeychainCloudKeySeedStore`, `InMemoryCloudKeySeedStore`).
public typealias CloudKeychain = CloudKeySeedStore & CloudKeychainProbe

public actor CloudSyncCoordinator {
    /// The states the person sees, in order. One consumer. `currentState` answers "what now" without the stream.
    public nonisolated let state: AsyncStream<CloudSyncState>
    private let continuation: AsyncStream<CloudSyncState>.Continuation
    public private(set) var currentState: CloudSyncState = .off
    /// Cycles that ran to the end (one per `syncNow`, the first-run cycles included); a test and diagnostics counter.
    public private(set) var completedCycles = 0
    private var unopenableLockedNotes = 0
    /// Gateway events the coordinator has taken in (a diagnostics counter; a test waits on it).
    public private(set) var handledEvents = 0
    /// When the last failure wants to be retried (the scheduler of the app reads it).
    public private(set) var retry: CloudErrorDecision.Retry = .none
    /// True when this device set up the keys at the same moment as another device and lost: the recovery words it
    /// showed belong to a setup that was dropped and protect nothing. The app tells the person to use the other device's words.
    /// Cleared by `disable()` and by `dismissLostSetupRace()`.
    public private(set) var lostSetupRace = false

    private let library: any CloudSyncLibrary
    private let gateway: any CloudKitGateway
    private let seeds: any CloudKeychain
    private let configuration: CloudKitConfiguration?
    private let blobSettings: CloudBlobSettings
    private let clock: @Sendable () -> Date
    private let crash: CrashPoint
    private let checkpoint: @Sendable (String) async -> Void
    private let appBuild: String?
    /// Test seam: the shipped starter versions this device merges against (a 1.0.x build knew only the first set).
    private var starterVersions = CloudStarterBase.shippedPayloads
    func useStarterVersions(_ versions: [String: [Data]]) { starterVersions = versions }
    private let store: CloudSyncStore
    private let fence: CloudGenerationFence
    private let join: CloudKeyJoin
    /// How long an account change waits for running operations.
    public nonisolated let drainTimeout: TimeInterval
    public static let defaultDrainTimeout: TimeInterval = 10

    private var session: CloudSyncSession?
    private var resumeAfterJournalRecovery = false
    private var owner: CloudSyncOwnerLock?
    private var errorPolicy: CloudErrorPolicy
    private var eventTask: Task<Void, Never>?
    private var runnerTask: Task<Void, Never>?
    private var cyclePending = false
    private var busy = false
    /// Counts cycles that were retired because they ignored the deadline of `disable()`; a retired cycle no longer owns `busy`.
    private var cycleEpoch = 0
    /// True from `disable()` until the next `enable()`/`launch()`: what a cancelled or retired cycle still tries to publish is dropped.
    private var cyclesRetired = false
    /// True from `suspend()` until the next `launch()`/`enable()`/`syncNow()`: the switch is still on, but nothing starts by itself.
    private var suspended = false
    /// Counts lifecycle transitions (`enable`, `launch`, `disable`, `suspend`). A transition publishes its final state only while no
    /// newer one has started, so a slow `suspend()` can never overwrite the `.off` of a `disable()` that finished first (round 2).
    private var transitionId = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var stopping = false
    /// The recovery choice of the running `enable`, kept in memory only while the first sync is not finished.
    private var pendingRecovery: RecoveryChoice?
    /// The verified backup of the running first sync (kept in memory until the first sync is finished, so asking again after the
    /// recovery step does not back up a second time).
    private var firstSyncBackup: String?

    /// - Parameters:
    ///   - configuration: the container; `nil` (an unconfigured build) means "not available in this build" and nothing is touched.
    ///   - blobs: how the blob transfer is configured; the coordinator builds it (it needs the fence and the key gate it owns).
    ///   - checkpoint: called at every named step (after `crash`); tests hold a device there to interleave devices or to act
    ///     between steps. Production passes the default.
    ///   - appBuild: the app build; a changed build retries quarantined records that were unreadable when opened.
    /// - drainTimeout: how long an account change waits for running operations.
    ///   - cancelOperations: the gateway's own cancellation, handed to the fence (`{ await gateway.cancelOperations() }` for the live
    /// gateway). An account change and `disable` call it, so a long `submit` does not hold them up.
    public init(library: any CloudSyncLibrary, gateway: any CloudKitGateway, seeds: any CloudKeychain,
                configuration: CloudKitConfiguration?, blobs: CloudBlobSettings = CloudBlobSettings(),
                clock: @escaping @Sendable () -> Date = { Date() }, crash: CrashPoint = .never,
                checkpoint: @escaping @Sendable (String) async -> Void = { _ in }, appBuild: String? = nil, drainTimeout: TimeInterval = CloudSyncCoordinator.defaultDrainTimeout,
                cancelOperations: @escaping @Sendable () async -> Void = {}) {
        self.library = library; self.gateway = gateway; self.seeds = seeds; self.configuration = configuration
        self.drainTimeout = drainTimeout
        self.blobSettings = blobs; self.clock = clock; self.crash = crash; self.checkpoint = checkpoint; self.appBuild = appBuild
        let store = CloudSyncStore(database: library.database, clock: clock)
        self.store = store
        fence = CloudGenerationFence(store: store, drainTimeout: drainTimeout, cancelOperations: cancelOperations)
        join = CloudKeyJoin(seeds: seeds, probe: seeds, bundles: CloudKeyBundleStore(gateway: gateway, results: store, currentGeneration: { try store.generation() }), state: store, now: clock)
        errorPolicy = CloudErrorPolicy(now: clock)
        (state, continuation) = AsyncStream.makeStream()
    }

    // MARK: switching on and off

    /// "Sync with iCloud" switched on. Idempotent: after an interruption the app calls it again and the first run continues where
    /// it stopped. Order (the Cloudflare flow of `MacSyncController`): account -> keys complete -> note password for a protected
    /// library -> verified backup -> bind -> download first, uploads off -> enable uploads -> clean up the markers the switch made ->
    /// first upload cycle. Returns the state the person sees afterwards.
    /// - Parameters:
    ///   - recovery: the person's recovery-key choice; needed only when this is the first device of the account.
    ///   - notePassword: needed once for a library with protected notes.
    @discardableResult
    public func enable(recovery: RecoveryChoice? = nil, notePassword: String? = nil) async throws -> CloudSyncState {
        guard configuration != nil else { return publish(.notAvailableInThisBuild) }
        try ensureUsable()
        try acquireOwnership()
        transitionId += 1
        cyclesRetired = false
        suspended = false
        try store.setSwitchedOn(true)
        if let recovery { pendingRecovery = recovery }
        publish(.syncing)
        do {
            let result = try await runExclusive {
                // Already switched on (the app started again after an interruption, or the person asks twice): this is a launch.
                if try self.store.backend() == .cloudkit, try self.store.isUploadEnabled() { return try await self.resume(notePassword: notePassword) }
                return try await self.firstRun(recovery: recovery, notePassword: notePassword)
            }
            startListening()
            return publish(result)
        } catch {
            let state = try stateFor(error)
            startListening()          // a paused or offline engine still listens: the account or the network may come back
            return publish(state)
        }
    }

    /// Switches this device's sync off. The engine stops, uploads are off, the owner lock is released. Nothing is deleted: not in
    /// the library, not in iCloud, not in the keychain. Edits made afterwards keep being captured and go out on the next
    /// `enable`.
    public func disable() async {
        transitionId += 1
        stopping = true
        suspended = false
        cyclesRetired = true            // from here on a cycle that was running publishes nothing
        eventTask?.cancel(); eventTask = nil
        cyclePending = false
        runnerTask?.cancel()
        // ONE deadline (the drain timeout) covers the cancellation, the drain and the wait for the cycle to stop. A cycle in the middle
        // of an upload would otherwise hold the switch-off and the app quit until the transfer ends (`submit` has no timeout of its
        // own). The fence closes first, so whatever a call that outlives the deadline writes later is refused.
        let deadline = Date().addingTimeInterval(drainTimeout)
        await fence.cancelRunning()
        while busy, Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        if busy {
            // The cycle ignored the deadline: it is retired. It keeps running detached, its writes are refused, and the next
            // switch-on does not wait for it.
            cycleEpoch += 1
            busy = false
            let stuck = waiters
            waiters = []
            for waiter in stuck { waiter.resume() }
        }
        runnerTask = nil
        if let session {
            // The blob transfer waits for its uploads; one that ignores cancellation must not outlive the deadline either.
            let transfer = session.transfer
            let done = CloudDoneFlag()
            Task { await transfer.shutdown(); done.set() }
            while !done.isSet, Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
        if (try? store.backend()) == .cloudkit { try? store.disableUploads() }
        try? store.setSwitchedOn(false)
        pendingRecovery = nil
        firstSyncBackup = nil
        lostSetupRace = false
        session = nil
        resumeAfterJournalRecovery = false
        owner?.release(); owner = nil
        stopping = false
        publish(.off, force: true)
    }

    /// Suspends this device's sync WITHOUT switching it off (Task 16 fix round 1): the app is leaving the foreground for good (iOS ends
    /// its background time, or a background refresh expired), so whatever is running must stop and nothing may write afterwards.
    /// It is the first half of `disable()` and nothing else: the durable fence is closed BEFORE anything is cancelled, the gateway
    /// and the tracked operations are cancelled and drained under ONE deadline (`drainTimeout`, `CloudGenerationFence.cancelRunning`),
    /// in-flight rows become `unknown` and the generation is bumped, so a late result of the suspended cycle is refused.
    /// The person's switch, the uploads, the session and the owner lock stay. The next `foreground()`, `syncNow()` or `launch()` lifts the
    /// fence the normal way (`resumeIfAllowed`, one refetch) and goes on; until then no event starts a cycle.
    /// It also covers a start that has no session yet (a cold launch or the first run is still on its way, owner lock taken or the switch
    /// on): the fence is closed and the start, which checks the suspension at its steps, ends without running on (round 2). Does nothing
    /// for a switched-off library with nothing running. A `disable()` that starts or finishes meanwhile wins: this call then publishes
    /// nothing (`transitionId`).
    public func suspend() async {
        guard !stopping else { return }
        guard session != nil || owner != nil || ((try? store.isSwitchedOn()) ?? false) else { return }
        transitionId += 1
        let mine = transitionId
        suspended = true
        cyclesRetired = true            // a cycle that was running publishes nothing from here on
        cyclePending = false
        runnerTask?.cancel()
        let deadline = Date().addingTimeInterval(drainTimeout)
        await fence.cancelRunning()
        while busy, Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        if busy {
            // The cycle ignored the deadline: it is retired like in `disable()`; its writes are refused and the next cycle does not wait.
            cycleEpoch += 1
            busy = false
            let stuck = waiters
            waiters = []
            for waiter in stuck { waiter.resume() }
        }
        runnerTask = nil
        guard transitionId == mine, !stopping else { return }
        publish(.paused, force: true)
    }

    /// App launch (and the person's switch was on): rebuilds the state from durable data, treats a crash's `sending` rows as
    /// unknown, resolves them through the fence, brings the account fence in line with the account (`resumeIfAllowed`), sweeps
    /// pinned files and scratch, retries quarantined records and runs a cycle. A library that is not bound and enabled stays off.
    @discardableResult
    public func launch() async throws -> CloudSyncState {
        guard configuration != nil else { return publish(.notAvailableInThisBuild) }
        try ensureUsable()
        let enabled = try store.backend() == .cloudkit && store.isUploadEnabled()
        let switchedOn = try store.isSwitchedOn()
        guard enabled || switchedOn else { return publish(.off, force: true) }
        try acquireOwnership()
        transitionId += 1
        cyclesRetired = false
        suspended = false
        publish(.syncing)
        do {
            let result = try await runExclusive {
                // The switch is on but the first sync never got to switch uploads on: it goes on from where it stopped.
                if !enabled { return try await self.firstRun(recovery: self.pendingRecovery, notePassword: nil) }
                return try await self.resume(notePassword: nil)
            }
            startListening()
            return publish(result)
        } catch {
            let state = try stateFor(error)
            startListening()
            return publish(state)
        }
    }

    /// The app came to the foreground: the account is looked at again (`resumeIfAllowed`) and a cycle runs.
    @discardableResult
    public func foreground() async throws -> CloudSyncState {
        guard session != nil else { return try await launch() }
        return try await syncNow()
    }

    /// One cycle now. `notePassword` lets fetched protected notes be merged (it is used for this cycle only).
    @discardableResult
    public func syncNow(notePassword: String? = nil) async throws -> CloudSyncState {
        let switchedOn = try store.isSwitchedOn()
        guard session != nil || switchedOn else { throw CloudCoordinatorError.notRunning }
        if suspended { suspended = false; cyclesRetired = false }       // the next cycle after `suspend()` is the resume
        publish(.syncing)
        do {
            return publish(try await runExclusive {
                // A switch that is on while uploads are not: the first sync is not finished (a password, the keychain, the account or
                // a dependency held it). Every cycle, a timer's or a signal's, takes it up again instead of cycling with uploads off.
                if try self.store.isSwitchedOn(), try !(self.store.backend() == .cloudkit && self.store.isUploadEnabled()) {
                    return try await self.firstRun(recovery: self.pendingRecovery, notePassword: notePassword)
                }
                return try await self.cycleOrResume(notePassword: notePassword)
            })
        } catch { return publish(try stateFor(error)) }
    }

    /// The person has read the notice about a lost setup race.
    public func dismissLostSetupRace() { lostSetupRace = false }

    /// "Upload again" after the synced copy was removed. The key bundle lived in the removed copy, so it comes back first (c)
    /// the account is checked, the bundle this library kept after its last verification (`ck_state.keyBundleCache`) is authenticated
    /// against the pinned account, revision, seed and canary, the zone is made again and the bundle is written create-only under the
    /// fence; a bundle another device wrote first is verified instead of overwritten. Only then can uploads follow. If the cached
    /// bundle is missing or does not authenticate, or anything else is uncertain, nothing changes and the state stays "removed"
    /// (`keyBundleCacheMissing`). A crash between the steps is finished by the next launch before anything is uploaded.
    public func chooseUploadAgain() async throws {
        guard case .removed(let reason) = try store.zoneState() else { return }
        try acquireOwnership()
        guard let bound = try store.cloudUserHash() else { throw CloudCoordinatorError.keyBundleCacheMissing }
        do {
            try await runExclusive {
                try await self.requireCurrentAccount(bound)
                let cached = try await self.authenticatedCachedBundle()
                _ = try self.store.chooseUploadAgain()
                do {
                    try await self.step("uploadAgain.afterReset")
                    try await self.recreateKeyBundle(cached)
                } catch {
                    // Not a crash: the sequence did not finish, so the copy stays "removed" and the person can try again.
                    if !(error is CrashInjected) { try? self.store.setZoneState(.removed(reason)) }
                    throw error
                }
            }
        } catch {
            if error is CrashInjected { endAsIfTheProcessDied() }
            else if session == nil { owner?.release(); owner = nil }
            throw error
        }
    }

    /// The cached key bundle, if it still authenticates against what this library pins: the account of `ck_state`, the revision
    /// high-water marks, the seed in the keychain and the canary inside the bundle.
    private func authenticatedCachedBundle() throws -> CloudKeyBundle {
        do {
            guard let cached = try store.cachedKeyBundle() else { throw CloudCoordinatorError.keyBundleCacheMissing }
            let local = try store.keyState()
            guard local.accountId == cached.accountId, let seed = try seeds.seed(accountId: cached.accountId) else {
                throw CloudCoordinatorError.keyBundleCacheMissing
            }
            try CloudKeyVerification.checkPin(cached, local, seeds: seeds)
            _ = try CloudKeyVerification.open(cached, masterKey: seed)
            return cached
        } catch let error as CloudCoordinatorError { throw error }
        catch { throw CloudCoordinatorError.keyBundleCacheMissing }
    }

    /// Makes the zone (from `unknown`) and writes the verified bundle create-only, inside the fence. A bundle already there is
    /// verified through the key layer; the same account's bundle is accepted, anything else stops.
    private func recreateKeyBundle(_ cached: CloudKeyBundle) async throws {
        _ = try await fence.run { _ in try await self.gateway.prepare() }
        try await step("uploadAgain.afterZone")
        let generation = try store.generation()
        let bundles = CloudKeyBundleStore(gateway: gateway, results: store, accountGeneration: generation)
        let written = try await fence.run { _ in try await bundles.create(cached) }
        switch written {
        case .written: break
        case .conflict(let winner?):
            guard winner.bundle.accountId == cached.accountId else { throw CloudKeyError.accountMismatch }
            let evaluation = try await join.evaluate()
            guard evaluation.state == .ready else { throw CloudKeyError.keyMismatch }
        case .conflict(nil), .notWritten:
            throw CloudKeyError.bundleNotWritten
        }
        try fence.requireCurrent(generation)
        try await step("uploadAgain.afterBundle")
    }

    // MARK: what the settings screen offers besides the switch

    /// Whether the person has saved recovery words (`none` and `acknowledgedSkip` and `pending` are "not saved").
    public func recoveryState() throws -> CloudRecoveryState { try store.keyState().recovery }

    /// "Create recovery words" / "Replace recovery words": the words the person confirmed replace the ones in the key bundle. This is
    /// not revocation: devices that are set up keep working. Needs a running coordinator (the keys are open). It runs one
    /// at a time with the cycles, looks at the account first and does its fetch and conditional write inside the generation fence
    ///: after an account change it sends nothing.
    public func saveRecoveryWords(_ choice: RecoveryChoice) async throws -> CloudRecoveryRotationOutcome {
        guard let session, let bound = try store.cloudUserHash() else { throw CloudCoordinatorError.notRunning }
        return try await runExclusive {
            try await self.requireCurrentAccount(bound)
            let generation = try self.store.generation()
            let rotation = CloudRecoveryRotation(seeds: self.seeds, bundles: CloudKeyBundleStore(gateway: self.gateway, results: self.store, accountGeneration: generation),
                                                 state: self.store)
            let keys = session.keys
            let outcome = try await self.fence.run { _ in try await rotation.createOrReplaceRecoveryKey(choice, keys: keys) }
            try self.fence.requireCurrent(generation)
            return outcome
        }
    }

    /// The account the device reports is the one this library is bound to, and the fence is open. Otherwise a destructive or
    /// key-changing action must not run (it throws `accountNotCurrent`); a different account also closes the fence.
    private func isRemoved(_ zone: CloudZoneState) -> Bool { if case .removed = zone { true } else { false } }

    private func requireCurrentAccount(_ bound: String) async throws {
        if try await reconcileAccount(preparing: false) != nil { throw CloudCoordinatorError.accountNotCurrent }
        guard case .available(let hash) = await gateway.accountState(), hash == bound, !(await fence.isGated) else {
            throw CloudCoordinatorError.accountNotCurrent
        }
    }

    /// "Upload them again" after notes went missing in iCloud: every paused note gets a new copy made from this library's
    /// content, sent by the next cycle. Returns how many were prepared.
    @discardableResult
    public func uploadMissingAgain() async throws -> Int {
        guard let session else { throw CloudCoordinatorError.notRunning }
        let recovery = CloudIncarnation(database: library.database, store: store, accountID: session.keys.accountID, vaultKey: session.keys.vaultKey, clock: clock)
        let outcomes = try recovery.recoverAll()
        return outcomes.filter { if case .prepared = $0.1 { true } else { false } }.count
    }

    /// "Delete my iCloud copy": a verified backup of this library, then the synced copy in iCloud is deleted and this library is
    /// let go of its binding. Notes, attachments and tags on this device stay; the keychain keeps its key. A later switch-on
    /// starts a new sync from this library. Sync is off afterwards.
    ///
    /// The deletion is the one thing here that cannot be undone, so it is held to the account fence: this coordinator
    /// keeps the library's owner lock and runs nothing else meanwhile; the device must report the account the library is bound to; the
    /// gateway deletes only while that account is still the signed-in one (`deleteZone(expecting:)`) and inside a fenced operation;
    /// and the library is let go only after the deletion is confirmed and the generation did not change. Any failure leaves the
    /// library bound, the notes untouched and the copy where it was.
    public func deleteICloudCopy() async throws {
        try ensureUsable()
        try acquireOwnership()
        guard try store.backend() == .cloudkit, let bound = try store.cloudUserHash() else { await disable(); return }
        do {
            try await runExclusive {
                let backup = try await self.library.makeBackup()
                guard !backup.isEmpty else { throw CloudCoordinatorError.backupNotVerified }
                try await self.requireCurrentAccount(bound)
                try await self.step("deleteCopy.beforeDelete")
                // (The generation moves when the zone state does, so it cannot be compared before and after; the account check above
                // and the gateway's own expecting-check are what bind the deletion to the bound account.)
                try await self.fence.run { _ in
                    do { try await self.gateway.deleteZone(expecting: bound) }
                    catch CloudSyncError.zoneNotFound { /* already gone: the copy is deleted */ }
                }
                try SyncAccountDetach.detach(database: self.library.database, expectedBackend: .cloudkit, verifiedBackupID: backup)
            }
        } catch {
            if error is CrashInjected { endAsIfTheProcessDied() }
            else if session == nil { owner?.release(); owner = nil }
            throw error
        }
        await disable()
    }

    /// "Remove the iCloud key from all my devices" (Advanced): sync is switched off here and the account's key is removed from
    /// iCloud Keychain, which removes it on every device. The iCloud copy stays but needs the recovery words to be opened again.
    public func removeICloudKey() async throws {
        await disable()
        guard let account = try store.keyState().accountId else { return }
        try seeds.removeSeed(accountId: account)
    }

    /// "Sync with the new iCloud account": sync is switched off, a verified backup is made and this library lets go of the old
    /// account. The old account's copy is not touched. The caller then switches sync on again (`enable`).
    public func detachForNewAccount() async throws {
        await disable()
        guard try store.backend() == .cloudkit else { return }
        let backup = try await library.makeBackup()
        guard !backup.isEmpty else { throw CloudCoordinatorError.backupNotVerified }
        try SyncAccountDetach.detach(database: library.database, expectedBackend: .cloudkit, verifiedBackupID: backup)
    }

    // MARK: first run

    private func journalRecoveryGate(notePassword: String?) async throws -> CloudSyncState? {
        switch await library.journalRecoveryState() {
        case .ready: return nil
        case .blocked:
            if session == nil { resumeAfterJournalRecovery = true }
            return .failed(kind: "journalRecoveryBlocked")
        case .waitingForKey:
            if session == nil { resumeAfterJournalRecovery = true }
        }
        let evaluation = try await join.evaluate()
        switch evaluation.state {
        case .ready: break
        case .noBundle:
            try await library.offerJournalMoveAsideForUnavailableKey()
            return .failed(kind: "journalKeyUnavailable")
        case .waitingForKeychain: return .waitingForKeychain
        case .needsRecoveryKey: return .needsRecoveryKey
        case .keychainUnavailable: return .keychainUnavailable
        case .keyMismatch: return .failed(kind: "keyMismatch")
        }
        guard let keys = evaluation.keys, let bundle = evaluation.verifiedBundle else { return .failed(kind: "journalKeyUnavailable") }
        let intake = CloudVaultIntake(database: library.database, gateway: gateway, accountID: keys.accountID, vaultKey: keys.vaultKey)
        guard let notePassword else {
            if try await intake.vaultIsAbsent() {
                try await library.offerJournalMoveAsideForUnavailableKey()
                return .failed(kind: "journalKeyUnavailable")
            }
            return .needsNotePassword
        }
        guard let candidate = try await intake.scan(password: notePassword) else {
            try await library.offerJournalMoveAsideForUnavailableKey()
            return .failed(kind: "journalKeyUnavailable")
        }
        try throwIfSuspended()
        let library = self.library, store = self.store, seeds = self.seeds
        let installed = try await intake.install(candidate) { operation in
            try await library.withJournalKeyInstall {
                try Task.checkCancellation()
                try CloudKeyVerification.checkPin(bundle, store.keyState(), seeds: seeds)
                return try await operation()
            }
        }
        guard installed else { return .failed(kind: "journalKeyUnavailable") }
        unopenableLockedNotes = try await intake.unopenableLockedNoteCount(for: candidate)
        try await library.recoverJournalsAfterKey(password: notePassword)
        return await library.journalRecoveryState() == .ready ? nil : .failed(kind: "journalRecoveryBlocked")
    }

    private func firstRun(recovery: RecoveryChoice?, notePassword: String?) async throws -> CloudSyncState {
        if let blocked = try await journalRecoveryGate(notePassword: notePassword) { return blocked }
        guard let configuration else { return .notAvailableInThisBuild }
        try await step("firstRun.begin")
        if let blocked = try await reconcileAccount(preparing: true) { return blocked }
        let wasEnabled = try store.isUploadEnabled()
        // A protected library needs its password before anything is backed up, bound or uploaded (the Cloudflare order).
        if !wasEnabled, try library.hasNotePassword {
            guard let notePassword else { return .needsNotePassword }
            try await library.verifyNotePassword(notePassword)
        }
        // The backup is a local backup of the library and needs no keys, so it comes FIRST: before the person is asked about recovery
        // words and before any key exists. It happens once per first sync: asked again after the recovery step, it is the same.
        // A library that is already bound had it before it was bound.
        if !wasEnabled, try store.backend() != .cloudkit {
            if firstSyncBackup == nil {
                try await library.flushForSync()
                let backup = try await library.makeBackup()
                guard !backup.isEmpty else { throw CloudCoordinatorError.backupNotVerified }
                firstSyncBackup = backup
            }
            try await step("firstRun.afterBackup")
        }
        if let blocked = try await journalRecoveryGate(notePassword: notePassword) { return blocked }
        let keys: AccountKeys
        switch try await resolveKeys(recovery: recovery, allowCreation: true) {
        case .ready(let ready): keys = ready
        case .blocked(let state): return state
        }
        try await step("firstRun.afterKeys")
        guard case .available(let userHash) = await gateway.accountState() else { return .waitingForICloud }
        try store.bind(accountId: keys.accountID, containerId: configuration.containerIdentifier, zoneName: configuration.zoneName, cloudUserHash: userHash)
        try await step("firstRun.afterConfigure")
        _ = try await fence.resumeIfAllowed(using: gateway)
        let session = makeSession(keys)
        self.session = session
        resumeAfterJournalRecovery = false
        let access = try await unlock(notePassword)
        defer { access?.revoke() }

        if !wasEnabled {
            // Starter notes deleted before this library ever met the cloud have no tombstone: remember them for the merge.
            try store.recordDeletedStarters()
            // Download first, uploads off: what the cloud already has is merged before this library publishes anything.
            var report = CloudCycleReport()
            for _ in 0..<3 {
                if let blocked = try await journalRecoveryGate(notePassword: notePassword) { return blocked }
                report = try await session.run(uploads: false, access: access, notePassword: notePassword)
                completedCycles += 1
                if try CloudFirstRun.canEnable(store: store) || report.applied == 0 { break }
            }
            try await step("firstRun.afterDownload")
            guard try CloudFirstRun.canEnable(store: store) else {
                retry = .after(5)           // the first sync goes on by itself when what it waits for is there
                return report.waitingForUnlock > 0 ? .needsNotePassword : .syncing
            }
            // Through the editors' commit coordination, as an apply: open editors are drained first, and an editor whose note the
            // first-bind guard removes is closed by the host. A journal with uncommitted text keeps the guard off.
            let store = store, paths = library.paths
            let enableUploads: @Sendable () throws -> Void = { try store.enableUploads(keeping: CloudFirstRun.startersWithPendingJournal(in: paths)) }
            do {
                if let commits = library.commitCoordinator {
                    _ = try await commits.commit(scope: .unknown) { try enableUploads(); return .applied }
                } else {
                    try enableUploads()
                }
            } catch where Self.isEditorWait(error) {
                // The host could not drain its editor right now (iOS: a scene drain, an attachment write, text being composed). Like
                // the wait above: the first sync goes on by itself shortly, with nothing switched on yet.
                retry = .after(5)
                return .syncing
            }
            try await step("firstRun.afterEnable")
        }
        try cleanUpEnableMarkers(keys)
        try await step("firstRun.afterCleanup")
        // Not the cycle that switched uploads on: another device may be binding at the same moment, and the first-contact rules
        // decide a starter's first meeting. The next cycle upgrades.
        let state = try await runCycle(session, uploads: true, access: access, notePassword: notePassword, upgradesStarters: false)
        try await step("firstRun.afterUpload")
        pendingRecovery = nil
        firstSyncBackup = nil
        return state
    }

    /// The markers the enable step made, for content the cloud already holds, go (see `CloudSyncStore.cleanUpEnableMarkers`).
    private func cleanUpEnableMarkers(_ keys: AccountKeys) throws {
        guard try store.enableMarkerCount() > 0 else { return }
        let crash = self.crash
        try store.cleanUpEnableMarkers(accountID: keys.accountID, vaultKey: keys.vaultKey, boundary: { try crash.hit($0) })
    }

    // MARK: launch

    private func resume(notePassword: String?) async throws -> CloudSyncState {
        if let blocked = try await journalRecoveryGate(notePassword: notePassword) { return blocked }
        // A crash may have left sends in the `sending` state: they may or may not have landed. This is the first thing
        // that happens, before any network call.
        try store.interruptSending()
        try throwIfSuspended()
        // Offline at launch is not a reason to have no engine: the account is looked at again by every cycle, and the keys come
        // from the verified bundle kept on this device.
        var unreachable: Error?
        do { if let blocked = try await reconcileAccount(preparing: false) { return blocked } }
        catch where Self.isNetworkFailure(error) { unreachable = error }
        let keys: AccountKeys
        switch try await resolveKeys(recovery: nil, allowCreation: false) {
        case .ready(let ready): keys = ready
        case .blocked(let state): return state
        }
        try throwIfSuspended()
        let session = makeSession(keys)
        self.session = session
        resumeAfterJournalRecovery = false
        _ = try session.publisher.treatSendingAsUnknown()
        _ = try? session.pinner.sweep(store: store, now: clock())
        session.transfer.sweepScratch(now: clock())
        try cleanUpEnableMarkers(keys)
        if let unreachable { throw unreachable }
        let access = try await unlock(notePassword)
        defer { access?.revoke() }
        return try await runCycle(session, uploads: true, access: access, notePassword: notePassword)
    }

    // MARK: cycles

    private func cycleOrResume(notePassword: String?) async throws -> CloudSyncState {
        if session == nil && resumeAfterJournalRecovery { return try await resume(notePassword: notePassword) }
        return try await cycleOnce(notePassword: notePassword)
    }

    private func cycleOnce(notePassword: String?) async throws -> CloudSyncState {
        if let blocked = try await journalRecoveryGate(notePassword: notePassword) { return blocked }
        guard let session else { throw CloudCoordinatorError.notRunning }
        try throwIfSuspended()
        if let blocked = try await reconcileAccount(preparing: false) { return blocked }
        try throwIfSuspended()
        let access = try await unlock(notePassword)
        defer { access?.revoke() }
        return try await runCycle(session, uploads: try store.isUploadEnabled(), access: access, notePassword: notePassword)
    }

    /// A suspension that arrived while a start or a cycle was on its way ends it here, before anything can lift the fence or write.
    private func throwIfSuspended() throws {
        if suspended || stopping { throw CancellationError() }
    }

    private func runCycle(_ session: CloudSyncSession, uploads: Bool, access: LockedNoteAccess?, notePassword: String?,
                          upgradesStarters: Bool = true) async throws -> CloudSyncState {
        try throwIfSuspended()
        try await library.flushForSync()
        if let blocked = try await journalRecoveryGate(notePassword: notePassword) { return blocked }
        let report = try await session.run(uploads: uploads, access: access, notePassword: notePassword)
        completedCycles += 1
        errorPolicy.succeeded()
        if uploads, upgradesStarters, !report.moreWork, !report.quotaHeld { await upgradeStartersAfterSync() }
        // No room in iCloud: say so, and ask for no cycle of our own (a foreground or the slow timer looks again).
        if report.quotaHeld {
            retry = .onForegroundOrEvery(CloudErrorPolicy.quotaRetryInterval)
            return .quotaFull
        }
        retry = report.moreWork ? .after(0) : .none
        if report.moreWork { requestCycle() }
        if report.waitingForUnlock > 0, notePassword == nil { return .needsNotePassword }
        return try steadyState()
    }

    /// The one-time starter upgrade of a library bound to an account runs here, after a cycle that fetched everything with
    /// uploads on, so a deletion or an edit made elsewhere has arrived (a starter that is gone or edited is left alone) and the first-bind
    /// guard has run. Through the editors' commit coordination, as an apply. A failure or an editor that cannot be drained leaves the
    /// marker unset: the next cycle tries again. One more cycle sends the new texts.
    private func upgradeStartersAfterSync() async {
        let database = library.database, paths = library.paths
        let marker = SettingKey<Bool>.gettingStartedUpgraded
        guard (try? Settings(db: database).value(marker)) == false else { return }
        let replaced = Mutex(false)
        let upgrade: @Sendable () throws -> SyncApplyResult = {
            let ids = try GettingStartedNotes.upgradeFirstShipped(in: NoteStore(db: database, notifier: nil, paths: paths), paths: paths, afterSync: true)
            replaced.withLock { $0 = !ids.isEmpty }
            return .applied
        }
        do {
            if let commits = library.commitCoordinator { _ = try await commits.commit(scope: .unknown, upgrade) } else { _ = try upgrade() }
        } catch { return }
        // A cycle to send the new texts only when some were written: an untouched-nothing upgrade must not cost a cycle (quota tests).
        if replaced.withLock({ $0 }), (try? Settings(db: database).value(marker)) == true { requestCycle() }
    }

    /// What the person sees when nothing is wrong right now.
    private func steadyState() throws -> CloudSyncState {
        if case .removed(let reason) = try store.zoneState() { return .zoneRemoved(reason: reason) }
        let held = try store.quarantineRows().filter { !$0.ignoredByUser }
        if held.contains(where: { $0.reason.hasPrefix("version:") || $0.reason == "payload:unsupported" }) { return .needsAppUpdate }
        if !held.isEmpty { return .itemsUnreadable(count: held.count) }
        let missing = try store.allMissing()
        if !missing.isEmpty { return .itemsMissingInCloud(count: missing.count) }
        if unopenableLockedNotes > 0 { return .failed(kind: "vaultPartial:\(unopenableLockedNotes)") }
        return .upToDate(lastSync: clock())
    }

    /// Looks at the account the device reports and brings the fence in line with it. Returns the state to show
    /// when sync must not run now, nil when it may.
    private func reconcileAccount(preparing: Bool) async throws -> CloudSyncState? {
        let current = await gateway.accountState()
        let stored = try store.cloudUserHash()
        let decision = CloudAccountPolicy.evaluate(stored: stored, current: current)
        switch decision {
        case .firstBind:
            if preparing { _ = try await gateway.prepare() }
            return nil
        case .resume:
            // A suspension that landed while the account was being read must not be undone by the lift (round 2).
            try throwIfSuspended()
            _ = try await fence.resumeIfAllowed(using: gateway)
            return await fence.isGated ? .waitingForICloud : nil
        case .pause:
            // A different user, no account or a restriction: stop everything that could write, once.
            if stored != nil, !(await fence.isGated) { try await fence.accountChanged() }
            return CloudAccountPolicy.state(for: decision, stored: stored)
        case .waitForAccount:
            return .waitingForICloud
        }
    }

    // MARK: events

    private func startListening() {
        guard eventTask == nil else { return }
        let events = gateway.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: CloudGatewayEvent) async {
        handledEvents += 1
        guard !stopping, !suspended else { return }
        switch event {
        case .remoteChange:
            requestCycle()
        case .accountChanged:
            if await library.journalRecoveryState() != .ready { requestCycle(); return }
            do {
                if let blocked = try await reconcileAccount(preparing: false) { publish(blocked) } else { requestCycle() }
            } catch { publish((try? stateFor(error)) ?? .paused) }
        case .zoneRemoved(let reason):
            publish(.zoneRemoved(reason: reason))
        }
    }

    /// Any number of requests while a cycle runs make exactly one more cycle.
    private func requestCycle() {
        guard session != nil || ((try? store.isSwitchedOn()) ?? false), !stopping, !suspended else { return }
        cyclePending = true
        guard runnerTask == nil else { return }
        runnerTask = Task { [weak self] in await self?.drainRequests() }
    }

    private func drainRequests() async {
        while cyclePending, !stopping, !Task.isCancelled {
            cyclePending = false
            _ = try? await syncNow()
        }
        runnerTask = nil
    }

    // MARK: keys

    private enum KeyResolution { case ready(AccountKeys), blocked(CloudSyncState) }

    private func resolveKeys(recovery: RecoveryChoice?, allowCreation: Bool) async throws -> KeyResolution {
        // A key creation that was interrupted finishes first: its pending item holds its own keys and its own choice, which win
        // over anything passed now. Until it is complete no data record may be saved.
        if try seeds.pending() != nil {
            let resumed = try await makeCreation().run(try recovery ?? RecoveryChoice.skip(acknowledged: true))
            if case .anotherDeviceWon = resumed { lostSetupRace = true }
            try await step("firstRun.afterKeyCreation")
        }
        // Words the person confirmed for a setup that never happens: this library had no keys and no creation under way, and by the
        // time they were confirmed another device had finished its own setup.
        let hadNoKeys = try store.keyState().accountId == nil
        var evaluation: CloudKeyJoinEvaluation
        do { evaluation = try await join.evaluate() } catch {
            // Offline at launch: the verified bundle kept from the last online run plus the keychain seed are enough.
            if Self.isNetworkFailure(error), let keys = try cachedKeys() { return .ready(keys) }
            throw error
        }
        // The person chose "Upload again" (the zone is not "removed" any more) but the key bundle is not in the cloud: an interrupted
        // "Upload again". The verified bundle this library kept is written again before anything else is done (c).
        if evaluation.state == .noBundle, !allowCreation, !isRemoved(try store.zoneState()), let cached = try? authenticatedCachedBundle() {
            try await recreateKeyBundle(cached)
            evaluation = try await join.evaluate()
        }
        if evaluation.state != .noBundle, hadNoKeys, recovery?.isSaved == true { lostSetupRace = true }
        if evaluation.state == .noBundle {
            guard allowCreation else { return .blocked(.failed(kind: "keyBundleMissing")) }
            guard let recovery else { throw CloudCoordinatorError.recoveryChoiceRequired }
            let created = try await makeCreation().run(recovery)
            if case .anotherDeviceWon = created { lostSetupRace = true }
            try await step("firstRun.afterKeyCreation")
            evaluation = try await join.evaluate()
        }
        switch evaluation.state {
        case .ready:
            guard let keys = evaluation.keys else { return .blocked(.failed(kind: "keys")) }
            if let bundle = evaluation.verifiedBundle { try store.cacheKeyBundle(bundle) }
            return .ready(keys)
        case .noBundle: return .blocked(.failed(kind: "keyBundleMissing"))
        case .waitingForKeychain: return .blocked(.waitingForKeychain)
        case .needsRecoveryKey: return .blocked(.needsRecoveryKey)
        case .keychainUnavailable: return .blocked(.keychainUnavailable)
        case .keyMismatch: return .blocked(.failed(kind: "keys"))
        }
    }

    /// The person typed the 24 recovery words on a device that has no seed. On success the first sync continues.
    @discardableResult
    public func joinWithRecoveryKey(_ words: String, notePassword: String? = nil) async throws -> CloudSyncState {
        _ = try await join.join(recoveryWords: words)
        return try await enable(recovery: nil, notePassword: notePassword)
    }

    private func makeCreation() throws -> CloudKeyCreation {
        CloudKeyCreation(seeds: seeds, probe: seeds,
                         bundles: CloudKeyBundleStore(gateway: gateway, results: store, accountGeneration: try store.generation()),
                         state: store, crash: crash, now: clock)
    }

    private func cachedKeys() throws -> AccountKeys? {
        guard let cached = try store.cachedKeyBundle() else { return nil }
        let local = try store.keyState()
        guard local.accountId == cached.accountId, let seed = try seeds.seed(accountId: cached.accountId) else { return nil }
        try CloudKeyVerification.checkPin(cached, local, seeds: seeds)
        return try CloudKeyVerification.open(cached, masterKey: seed).0
    }

    /// A `KeyBundle` record changed in the cloud (another device replaced the recovery key, or somebody wrote something else):
    /// verify it through the key layer before the cycle does anything else with its data. A failure holds the work.
    private func verifyKeyBundle(_ changed: CloudChangeFlag) async throws {
        let evaluation: CloudKeyJoinEvaluation
        do { evaluation = try await join.evaluate() }
        catch let error as CloudKeyError {
            if case .bundleUnreadable = error { throw CloudKeyHold(state: .failed(kind: "keyBundleUnreadable")) }
            throw CloudKeyHold(state: .failed(kind: "keys"))
        }
        switch evaluation.state {
        case .ready:
            if let bundle = evaluation.verifiedBundle { try store.cacheKeyBundle(bundle) }
            changed.clear()
        case .keyMismatch:
            if case .bundleRollback? = evaluation.mismatch { throw CloudKeyHold(state: .failed(kind: "keyRollback")) }
            throw CloudKeyHold(state: .failed(kind: "keyMismatch"))
        case .needsRecoveryKey: throw CloudKeyHold(state: .needsRecoveryKey)
        case .waitingForKeychain: throw CloudKeyHold(state: .waitingForKeychain)
        case .keychainUnavailable: throw CloudKeyHold(state: .keychainUnavailable)
        case .noBundle: throw CloudKeyHold(state: .failed(kind: "keyBundleMissing"))
        }
    }

    static func isNetworkFailure(_ error: Error) -> Bool {
        switch CloudErrorPolicy.classify(error) {
        case .offline, .unauthenticated: return true
        default: return false
        }
    }

    // MARK: session

    private func makeSession(_ keys: AccountKeys) -> CloudSyncSession {
        let creation = (try? makeCreation()) ?? CloudKeyCreation(seeds: seeds, probe: seeds, bundles: CloudKeyBundleStore(gateway: gateway, results: store, currentGeneration: { [store] in try store.generation() }), state: store)
        let ready: @Sendable () throws -> Void = { try creation.requireComplete(keys: keys) }
        let pinner = CloudAssetPinner(directory: library.paths.cloudPinned)
        let changed = CloudChangeFlag()
        let transfer = CloudKitBlobTransfer(
            database: library.database, paths: library.paths, gateway: gateway, store: store, fence: fence, keyReadiness: ready,
            partBytes: blobSettings.partBytes, timing: blobSettings.timing, crash: crash, clock: clock, freeBytes: blobSettings.freeBytes,
            diagnostics: blobSettings.diagnostics)
        let intake = CloudFeedSink(store: store, pinner: pinner, crash: crash, onKeyBundle: { _ in changed.raise() }, onUnreadableKeyBundle: { changed.raise() })
        let publisher = CloudPublisher(database: library.database, paths: library.paths, store: store, gateway: gateway,
                                       accountID: keys.accountID, vaultKey: keys.vaultKey, blobs: transfer, intake: intake,
                                       keyReadiness: ready, crash: crash, clock: clock)
        return CloudSyncSession(library: library, store: store, gateway: gateway, fence: fence, keys: keys, pinner: pinner, transfer: transfer,
                                publisher: publisher, changed: changed, appBuild: appBuild, step: { [weak self] name in if let self { try await self.step(name) } },
                                crash: crash, verifyKeys: { [weak self] in if let self { try await self.verifyKeyBundle(changed) } },
                                starterVersions: starterVersions)
    }

    // MARK: helpers

    private func ensureUsable() throws {
        guard library.syncPolicy == .enabled else { throw CloudCoordinatorError.libraryCopyNeverSyncs }
        if try store.backend() == .cloudflare { throw CloudCoordinatorError.boundToCloudflare }
    }

    private func acquireOwnership() throws {
        guard owner == nil else { return }
        do { owner = try CloudSyncOwnerLock.acquire(root: library.paths.root) }
        catch CloudSyncOwnerLock.Failure.ownedElsewhere { throw CloudCoordinatorError.ownedElsewhere }
    }

    /// A named step: an armed `CrashPoint` throws here, a test's checkpoint may hold the caller, and `disable()` stops it.
    func step(_ name: String) async throws {
        try crash.hit(name)
        await checkpoint(name)
        if stopping || suspended { throw CancellationError() }
    }

    private func unlock(_ password: String?) async throws -> LockedNoteAccess? {
        guard let password else { return nil }
        let privacy = NotePrivacy(store: NoteStore(db: library.database, notifier: nil, paths: library.paths))
        return try await Task.detached(priority: .userInitiated) { try privacy.unlock(password: password) }.value
    }

    /// A crash injected by a test stands for the process ending: the operating system releases the owner lock and everything
    /// else stays exactly as it is on disk. Nothing is cleaned up, nothing is written (that is the point of the crash tests).
    func endAsIfTheProcessDied() {
        eventTask?.cancel(); eventTask = nil
        cyclePending = false
        runnerTask?.cancel(); runnerTask = nil
        session = nil
        owner?.release(); owner = nil
    }

    /// Maps what went wrong to what the person sees, or rethrows what is not a sync condition (a crash injected by a test, a
    /// bug, a wrong note password).
    /// An error of the host's editor coordination around the switch-on, not of the store or of CloudKit (those keep their handling).
    static func isEditorWait(_ error: Error) -> Bool {
        !(error is CloudSyncStoreError || error is DatabaseError || error is CancellationError || error is CrashInjected
          || error is CloudSyncError || error is CloudPolicyError || error is CloudRecordRejection || error is URLError)
    }

    private func stateFor(_ error: Error) throws -> CloudSyncState {
        if error is CrashInjected { endAsIfTheProcessDied(); throw error }
        if let hold = error as? CloudKeyHold { return hold.state }
        if let mismatch = error as? VaultIntakeLockedNotesMismatch { return .failed(kind: "vaultMismatch:\(mismatch.count)") }
        if error is CancellationError { return .paused }
        if case CloudSyncStoreError.staleAccountGeneration = error { return .paused }
        if case CloudSyncStoreError.accountFenced = error { return .paused }
        // The keychain refused a plain read of this device's items (for example -34018, -25308): the same state the probe reports.
        if case CloudKeySeedStoreError.unavailable? = error as? CloudKeySeedStoreError { return .keychainUnavailable }
        if let keyError = error as? CloudKeyError {
            if case .keychainUnavailable = keyError { return .keychainUnavailable }
            if case .invalidRecoveryKey = keyError { throw error }
            if case .creationIncomplete = keyError { return .failed(kind: "keys") }
            throw error
        }
        guard error is CloudSyncError || error is CloudPolicyError || error is CloudRecordRejection || error is URLError else { throw error }
        let decision = errorPolicy.decide(error, account: nil)
        retry = decision.retry
        return decision.state
    }

    @discardableResult
    private func publish(_ next: CloudSyncState, force: Bool = false) -> CloudSyncState {
        if cyclesRetired, !force { return currentState }
        currentState = next
        continuation.yield(next)
        return next
    }

    private func runExclusive<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        while busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
        let mine = cycleEpoch
        defer {
            // A cycle that `disable()` retired no longer owns the flag: the next owner may already be running.
            if cycleEpoch == mine {
                busy = false
                if !waiters.isEmpty { waiters.removeFirst().resume() }
            }
        }
        return try await body()
    }
}

// MARK: the verified key bundle, kept for an offline launch

extension CloudSyncStore {
    func cachedKeyBundle() throws -> CloudKeyBundle? {
        try database.pool.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT keyBundleCache FROM ck_state WHERE id=1") else { return nil }
            return try? JSONDecoder().decode(CloudKeyBundle.self, from: data)
        }
    }

    func cacheKeyBundle(_ bundle: CloudKeyBundle) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(bundle)
        try database.pool.write { try $0.execute(sql: "UPDATE ck_state SET keyBundleCache=? WHERE id=1", arguments: [data]) }
    }
}

/// Set once by a detached task; polled by `disable()` so one deadline can cover work it cannot cancel.
private final class CloudDoneFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
