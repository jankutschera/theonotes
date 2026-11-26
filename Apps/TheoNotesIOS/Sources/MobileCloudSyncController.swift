// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import BackgroundTasks
import TheoNotesCore
import CryptoKit
import Foundation
import Observation
import OSLog
import SwiftUI
import UIKit

private let cloudSyncLogger = Logger(subsystem: AppIdentity.productionBundleIdentifier, category: "icloud-sync")

/// What the gateway needs from the library that owns it: the SQLite store it persists zone state and send results in (and the engine
/// state it starts from), and the library folder the durable pin folder lives in.
struct MobileCloudSyncGatewayRequest: Sendable {
    let store: CloudSyncStore
    let paths: AppPaths
}

/// A gateway with the two things the controller needs besides its protocol: the fence's cancellation and the way a remote
/// notification reaches it. Tests give just the gateway.
struct MobileCloudSyncGatewayParts: Sendable {
    var gateway: any CloudKitGateway
    /// `{ await gateway.cancelOperations() }` for the live gateway; handed to the coordinator's fence.
    var cancelOperations: @Sendable () async -> Void = {}
    /// `LiveCloudKitGateway.handleRemoteNotification`; nil when the gateway has no push.
    var handleRemoteNotification: (@Sendable ([AnyHashable: Any]) -> Bool)?
}

/// What the controller needs from the outside world. `live` is the real thing (built only when something is switched on); tests pass
/// the in-memory fake and recorders for the system calls. Nothing in here is called before the person flips the switch or a library
/// that has it on starts.
struct MobileCloudSyncServices: Sendable {
    var configuration: CloudKitConfiguration?
    var gateway: @Sendable (MobileCloudSyncGatewayRequest) -> MobileCloudSyncGatewayParts
    var keychain: @Sendable (_ namespace: String) -> any CloudKeychain
    var clock: @Sendable () -> Date = { Date() }
    var drainTimeout: TimeInterval = CloudSyncCoordinator.defaultDrainTimeout
    /// Gate G0 A4: a silent push reached an iPhone in 15 s only after `registerForRemoteNotifications`, so a library with the switch on
    /// registers (every launch, and when it is switched on) and a library that is switched off asks the system to stop.
    var registerForRemoteNotifications: @Sendable @MainActor () -> Void = { UIApplication.shared.registerForRemoteNotifications() }
    var unregisterForRemoteNotifications: @Sendable @MainActor () -> Void = { UIApplication.shared.unregisterForRemoteNotifications() }
    /// Asks the system for one `BGAppRefreshTask` under the app's existing identifier (shared with the private-server sync).
    var scheduleBackgroundRefresh: @Sendable @MainActor () -> Void = { MobileCloudSyncBackground.submit() }
    /// Stop (and every other way the switch goes off) withdraws the pending request, then lets the private-server sync ask again for
    /// its own: the two share one identifier, so cancelling must never be the last word.
    var cancelBackgroundRefresh: @Sendable @MainActor () -> Void = { MobileCloudSyncBackground.cancelPending() }
    var restorePrivateServerRefresh: @Sendable @MainActor (MobileCloudSyncLibrary) -> Void = { $0.restorePrivateServerRefresh() }

    /// The shipped services. Only a build with a valid container AND the flag on
    /// (`ReleaseFeatures.cloudSyncAvailable`) gets a configuration and so a live gateway; any other build keeps `configuration == nil`,
    /// the coordinator answers "not available in this build" and nothing is constructed. Even then the gateway is only made when something
    /// asks for it (the person's switch is on), and `LiveCloudKitGateway` itself touches CloudKit on its first call, not when it is built.
    /// `accessGroup` is the group of the iCloud-Keychain seed; it is the Mac's group, so the synchronizable item is one item for both.
    static func live(bundle: Bundle = .main, accessGroup: String = AppIdentity.current.keychainAccessGroup) -> MobileCloudSyncServices {
        live(infoDictionary: bundle.infoDictionary, accessGroup: accessGroup)
    }

    static func live(infoDictionary: [String: Any]?, accessGroup: String = AppIdentity.current.keychainAccessGroup) -> MobileCloudSyncServices {
        let configuration = ReleaseFeatures.cloudSyncAvailable(infoDictionary: infoDictionary)
            ? CloudKitConfiguration.from(infoDictionary: infoDictionary ?? [:]) : nil
        return MobileCloudSyncServices(
            configuration: configuration,
            gateway: { request in
                guard let configuration else { return MobileCloudSyncGatewayParts(gateway: MobileUnavailableCloudKitGateway()) }
                let gateway = LiveCloudKitGateway(
                    configuration: configuration, store: request.store, engineState: try? request.store.engineState(),
                    pinDirectory: livePinDirectory(for: request.paths))
                return MobileCloudSyncGatewayParts(
                    gateway: gateway, cancelOperations: { await gateway.cancelOperations() },
                    handleRemoteNotification: { gateway.handleRemoteNotification($0) })
            },
            keychain: { KeychainCloudKeySeedStore(namespace: $0, accessGroup: accessGroup) })
    }

    /// The gateway's folder for the files of a conflict record: durable (inside the library folder, which lives in Application
    /// Support, never `tmp`), next to the receiver's `CloudPinned`, and kept out of backups.
    static func livePinDirectory(for paths: AppPaths) -> URL {
        var directory = paths.root.appendingPathComponent("CloudGatewayPins", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        return directory
    }
}

/// The gateway of a build that has no iCloud connection yet. Every call says so; the coordinator never gets here because its
/// configuration is nil.
struct MobileUnavailableCloudKitGateway: CloudKitGateway {
    let events = AsyncStream<CloudGatewayEvent> { $0.finish() }
    func prepare() async throws -> CloudAccountState { throw CloudSyncError.unauthenticated }
    func accountState() async -> CloudAccountState { .couldNotDetermine }
    func submit(_ saves: [CloudSave]) async throws { throw CloudSyncError.unauthenticated }
    func fetchChanges(into sink: any CloudChangeSink) async throws { throw CloudSyncError.unauthenticated }
    func fetch(_ names: [String], keys: [String]?) async throws -> [String: CloudRecord] { throw CloudSyncError.unauthenticated }
    func delete(_ names: [String]) async throws { throw CloudSyncError.unauthenticated }
    func deleteZone() async throws { throw CloudSyncError.unauthenticated }
    func deleteZone(expecting userHash: String) async throws { throw CloudSyncError.unauthenticated }   // fail closed
}

/// The `BGAppRefreshTask` request of the iCloud sync. It uses the identifier the app already registers (`MobileSyncScheduler`), so the
/// private-server sync and this one share one task; `MobileSyncScheduler.refreshIdentifier` is the only place that names it.
@MainActor enum MobileCloudSyncBackground {
    static func submit() {
        let request = BGAppRefreshTaskRequest(identifier: MobileSyncScheduler.refreshIdentifier)
        request.earliestBeginDate = .now.addingTimeInterval(15 * 60)
        // Submission is opportunistic; launch, foreground and local-save sync remain authoritative.
        do { try BGTaskScheduler.shared.submit(request) }
        catch { /* The system may disable background refresh or defer resource allocation. */ }
    }

    static func cancelPending() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: MobileSyncScheduler.refreshIdentifier)
    }
}

/// A secret kept as bytes only for as long as a flow needs it, and zeroed when it is let go. The coordinator API takes a Swift `String`,
/// so `string()` has to make one for the single call that needs it; that `String` (and the one the password field produced) is outside
/// what can be zeroed. This only keeps the copy the controller itself holds short-lived and wiped.
final class MobileHeldSecret {
    private var bytes: [UInt8]
    init(_ text: String) { bytes = Array(text.utf8) }
    var isEmpty: Bool { bytes.isEmpty }
    func string() -> String { String(decoding: bytes, as: UTF8.self) }
    func zero() {
        for index in bytes.indices { bytes[index] = 0 }
        bytes.removeAll()
    }
    /// The bytes as they are now (a test looks at them after `zero()`).
    var snapshot: [UInt8] { bytes }
}

/// What the recovery-words sheet is for.
enum MobileCloudRecoveryPurpose: Equatable {
    /// First device, switching on: the sheet is part of "turn on" and its cancel turns sync off again.
    case firstSetup
    /// Settings: create the words (skipped at setup) or replace them.
    case later
}

/// A message that is already in a person’s words.
struct MobileCloudSyncStringError: Error { let text: String; init(_ text: String) { self.text = text } }

/// Holds the system's wait for a cycle that must finish while the app is in the background, and ends it on every exit. Several
/// holders (a scheduled cycle, a push, a refresh) share one assertion; it ends with the last one. When the system takes the time back,
/// `onExpire` runs first (it suspends the sync, fix round 1) and the assertion is ended at once, as the system demands.
@MainActor final class BackgroundGrace {
    private var task = UIBackgroundTaskIdentifier.invalid
    private var holders = 0
    private var onExpire: (@MainActor () -> Void)?
    func begin(_ name: String, onExpire: @escaping @MainActor () -> Void) {
        holders += 1
        self.onExpire = onExpire
        guard task == .invalid else { return }
        task = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.expired() }
        }
    }
    func end() {
        holders = max(0, holders - 1)
        guard holders == 0 else { return }
        release()
    }
    /// What the system's expiration handler does; also called by a test.
    func expired() {
        let action = onExpire
        holders = 0
        action?()
        release()
    }
    private func release() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task); task = .invalid
    }
    var isHolding: Bool { holders > 0 }
}

/// Settings ▸ iCloud on the iPhone and iPad: owns one `CloudSyncCoordinator` for the library (lazily, flag-gated), turns its answers
/// into what the page shows, and runs the actions the page offers. It mirrors the Mac's `CloudSyncController` and
/// adds the iOS triggers: the silent push (it registers for remote notifications, Gate G0 A4), the launch and foreground fetch, the
/// debounced local-save sync and the `BGAppRefreshTask`. Words live in `MobileCloudSyncStrings`.
@MainActor @Observable
final class MobileCloudSyncController {
    // MARK: what the page shows

    private(set) var state: CloudSyncState = .off
    /// The person's switch (persisted in the library; true from the moment they flip it until they stop or delete).
    private(set) var isOn = false
    private(set) var isWorking = false
    /// The step the first enable is at ("Saving a backup first"); nil when nothing runs.
    private(set) var progress: String?
    private(set) var lastSync: Date?
    private(set) var recoveryState: CloudRecoveryState = .none
    private(set) var boundToPrivateServer = false
    /// The private-server side of the move, set by the app when this build has it (`TheoNotesIOSApp`); nil hides the button.
    /// `true` asks to move without the missing files the refusal named.
    @ObservationIgnored var leavePrivateServer: (@MainActor (_ withoutMissingFiles: Bool) async throws -> Void)?
    /// The last refusal named missing files that no device and no server ever had, and nothing else stops the move: the
    /// "Move to iCloud Without These Files…" card lists these notes (up to five titles, then how many more).
    private(set) var missingFilesToLeave: (notes: [String], moreNotes: Int)?
    var canMoveWithoutMissingFiles: Bool { missingFilesToLeave != nil }
    var canMoveToICloud: Bool { isAvailable && boundToPrivateServer && leavePrivateServer != nil }
    /// After a move: "move your other devices now", until the owner dismisses it.
    private(set) var showsMoveNotice = false

    func dismissMoveNotice() {
        try? PrivateServerMove.dismissOtherDevicesNotice(store.database)
        refreshFacts()
    }
    /// Next to the notice: iCloud sync is not running after the move (switched off, or the switch-on stopped at something the
    /// person must fix; the lines below say what). Nil while it runs, works or waits for the recovery-word step.
    var moveSyncNotStarted: String? {
        guard showsMoveNotice, !isWorking, recoveryOffer == nil else { return nil }
        if !isOn { return MobileCloudSyncStrings.moveSyncOff }
        if problem != nil { return MobileCloudSyncStrings.moveSyncBlocked }
        switch state {
        case .off, .syncing, .upToDate, .offline, .paused, .recoveryNotSaved, .itemsUnreadable: return nil
        default: return MobileCloudSyncStrings.moveSyncBlocked
        }
    }
    /// This library is bound to an iCloud account (it has, or had, a synced copy).
    private(set) var isBoundToICloud = false
    /// This device set up at the same moment as another and lost: its saved words protect nothing (Task 8).
    private(set) var lostSetupRace = false
    /// The first successful sync after a skipped recovery step: the page asks once more.
    private(set) var recoveryNudge = false
    /// A line about something that worked, and one about something that did not. Both go away on the next action.
    private(set) var notice: String?
    private(set) var problem: String?

    // sheets
    private(set) var recoveryOffer: RecoveryKeyOffer?
    private(set) var recoveryPurpose: MobileCloudRecoveryPurpose?
    private(set) var recoverySheetError: String?
    var showsAccountChangedSheet = false
    private(set) var needsNotePasswordInput = false

    let isLocalOnly: Bool
    /// The build offers iCloud sync (`ReleaseFeatures.cloudSyncAvailable`) and this library may sync (not a separate recovery library).
    let isAvailable: Bool

    // MARK: collaborators

    @ObservationIgnored private let library: MobileCloudSyncLibrary
    @ObservationIgnored private let services: MobileCloudSyncServices
    @ObservationIgnored private let store: CloudSyncStore
    @ObservationIgnored private var coordinator: CloudSyncCoordinator?
    @ObservationIgnored private var scheduler: MobileCloudSyncScheduler?
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var started = false
    /// True while `stopSyncing` runs, so a second tap does not start a second stop.
    @ObservationIgnored private var stoppingNow = false
    /// How a remote notification reaches the gateway; nil until the gateway exists (a switched-off library has none).
    @ObservationIgnored private var remoteNotificationHandler: (@Sendable ([AnyHashable: Any]) -> Bool)?
    /// The note password a protected library gave before the recovery step (the password comes first). Memory only; it is
    /// needed again by the enable that follows the sheet, and cleared as soon as that enable has run, the sheet is cancelled or the
    /// app leaves the screen.
    @ObservationIgnored private var heldNotePassword: MobileHeldSecret?
    @ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []
    /// True while the controller holds the note password of a protected library for the step after the recovery sheet.
    var holdsNotePassword: Bool { heldNotePassword != nil }
    @ObservationIgnored private var closed = false
    @ObservationIgnored private let timing: MobileCloudSyncScheduler.Timing
    @ObservationIgnored private let grace = BackgroundGrace()
    /// True from `suspendForBackground()` until the next foreground, background refresh, push or manual sync: the switch is on, but
    /// nothing starts by itself (the coordinator's own events are held too).
    @ObservationIgnored private(set) var suspendedForBackground = false
    /// Counts every time the switch went off or the controller closed: a background refresh that started before does not schedule the
    /// next one (fix round 1).
    @ObservationIgnored private var backgroundEpoch = 0
    /// True while `start()` runs (the launch cycle included); a push that cold-starts the process waits for it.
    @ObservationIgnored private(set) var launchInFlight = false
    /// Whether the system was asked to deliver silent pushes for this switch-on (a test pins both directions).
    @ObservationIgnored private(set) var registeredForPush = false
    /// How often a cycle started (`.syncing` was published): the push handler waits for one to finish.
    @ObservationIgnored private(set) var syncingStarts = 0
    /// Counts how often the live services were asked for anything (a test pins that an off library asks for nothing).
    @ObservationIgnored private(set) var servicesTouched = 0

    init(library: MobileCloudSyncLibrary, services: MobileCloudSyncServices, available: Bool, timing: MobileCloudSyncScheduler.Timing = .init()) {
        self.library = library
        self.services = services
        self.timing = timing
        store = CloudSyncStore(database: library.database, clock: services.clock)
        isLocalOnly = library.syncPolicy != .enabled
        isAvailable = available && library.syncPolicy == .enabled
        refreshFacts()
        // The held note password does not outlive the screen it was typed on.
        for name in [UIApplication.willTerminateNotification, UIApplication.didEnterBackgroundNotification] {
            lifecycleObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.clearHeldNotePassword() }
            })
        }
    }

    isolated deinit {
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        heldNotePassword?.zero()
    }

    // MARK: lifecycle

    /// App launch. A library whose switch is off does nothing here: no coordinator, no gateway, no keychain, no timer, no push
    /// registration. A library whose switch is on registers for silent pushes, fetches (`launch()`) and starts the scheduler.
    func start() async {
        guard isAvailable, !started, !closed else { return }
        started = true
        launchInFlight = true
        defer { launchInFlight = false }
        refreshFacts()
        guard isOn else { return }
        // Registration does not wait for the launch cycle (it can hang offline): the persisted switch and the availability guards are
        // all it needs (fix round 1, G0 A4).
        setPushRegistered(true)
        do {
            let coordinator = ensureCoordinator()
            // The scene/background observers and the grace handling are installed BEFORE the launch is awaited (round 2): a launch that
            // hangs offline is then covered by the background grace and the suspend path, like any other cycle.
            startScheduling()
            // An expiry that arrived before the launch could begin (a cold background refresh the system already cancelled): suspend
            // instead of launching. The next foreground, refresh or push resumes through the scheduler.
            if suspendedForBackground { await coordinator.suspend(); return }
            apply(try await coordinator.launch())
            await afterRun(coordinator)
            startScheduling()
        } catch CloudCoordinatorError.recoveryChoiceRequired {
            setPushRegistered(false)
            stopScheduling()
            beginRecoverySheet(.firstSetup)    // the switch was on but the recovery step never finished
        } catch { fail(error) }
    }

    /// Lets go of the held note password and zeroes its bytes. Called when the flow that needed it ends, and on shutdown, account
    /// change, switching off, backgrounding and app termination.
    func clearHeldNotePassword() {
        heldNotePassword?.zero()
        heldNotePassword = nil
    }

    private func takeHeldNotePassword() -> String? {
        defer { clearHeldNotePassword() }
        return heldNotePassword?.string()
    }

    /// The library is closing (a library switch or the app ending): stops the timer and the engine.
    func shutdown() async {
        closed = true
        backgroundEpoch += 1
        clearHeldNotePassword()
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        lifecycleObservers = []
        stopScheduling()
        listener?.cancel(); listener = nil
        if let coordinator { await coordinator.disable() }
        coordinator = nil
        remoteNotificationHandler = nil
    }

    /// Stops timers only; the engine is stopped by `shutdown`.
    func stopScheduling() {
        scheduler?.stop(); scheduler = nil
    }

    // MARK: push and background

    /// A silent push, if the system delivers one (`AppDelegate` -> `MobileCloudSyncRouter`). The gateway turns a private-database
    /// notification into a change event and the coordinator runs a cycle. Returns whether it was one; false while sync is off.
    @discardableResult
    func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard isOn, !closed, let handler = remoteNotificationHandler else { return false }
        return handler(userInfo)
    }

    /// The same, for the app delegate's completion handler: the system suspends the app when the handler returns, so this waits (at most
    /// `timeout` seconds) for the cycle the push started to finish. A push that LAUNCHES the process arrives before any view exists:
    /// the controller is started here first, from the persisted switch (fix round 1), and that launch is itself the fetch. A push that
    /// finds the sync suspended resumes it with one cycle.
    func handleRemoteNotificationAndWait(_ userInfo: [AnyHashable: Any], timeout: TimeInterval = 25) async -> Bool {
        guard isAvailable, !closed else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        grace.begin("icloud-push", onExpire: expiryAction)
        defer { grace.end() }
        var launchedHere = false
        if !started {
            launchedHere = true
            Task { @MainActor in await self.start() }
        }
        // A hung launch is left to its own deadline; the push is answered when ours runs out.
        while launchInFlight || (launchedHere && !started), Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        guard isOn, !closed else { return false }
        if suspendedForBackground {
            suspendedForBackground = false
            if let coordinator {
                do { apply(try await coordinator.syncNow()); await afterRun(coordinator) }
                catch { if !Task.isCancelled, !closed { fail(error) } }
            }
            return true
        }
        let before = syncingStarts
        guard handleRemoteNotification(userInfo) else { return launchedHere }
        // The coordinator turns the event into a cycle on its own task: give it a moment to start, then wait for it to end.
        let startBy = Date().addingTimeInterval(3)
        while syncingStarts == before, Date() < startBy { try? await Task.sleep(for: .milliseconds(50)) }
        while case .syncing = state, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        return true
    }

    /// The `BGAppRefreshTask` (the existing identifier). A switched-off library does nothing and schedules nothing. When the system
    /// takes the time back it cancels the awaiting task; the cancellation handler then SUSPENDS the sync through the coordinator
    /// (fence closed, cycle cancelled and drained, generation bumped; the switch stays on), because cancelling the Swift task alone
    /// does not reach the gateway's operations. The next refresh asks for itself only while this
    /// controller is still the same one and the switch is still on.
    func backgroundRefresh() async {
        guard isAvailable, !closed else { return }
        refreshFacts()
        guard isOn else { return }
        let epoch = backgroundEpoch
        defer { if isOn, !closed, epoch == backgroundEpoch { services.scheduleBackgroundRefresh() } }
        suspendedForBackground = false
        grace.begin("icloud-refresh", onExpire: expiryAction)
        defer { grace.end() }
        await withTaskCancellationHandler {
            // A cold refresh starts the controller INSIDE this scope (round 2): an expiry during `start()` is caught here too.
            if !started { await start(); return }          // `launch()` is itself a cycle
            guard let coordinator, !isWorking else { return }
            do {
                apply(try await coordinator.syncNow())
                await afterRun(coordinator)
            } catch {
                if case CloudCoordinatorError.notRunning = error { return }
                if Task.isCancelled || closed { return }
                fail(error)
            }
        } onCancel: {
            Task { @MainActor [weak self] in await self?.suspendForBackground() }
        }
    }

    /// The sync is leaving the foreground for good (the background time ran out, or a background refresh expired). One bounded path:
    /// `CloudSyncCoordinator.suspend()`. Unlike Stop the switch stays on, the registration stays, and the next foreground, launch,
    /// refresh or push lifts the fence and resumes. Safe to call twice and when nothing runs.
    func suspendForBackground() async {
        guard isAvailable, isOn, !closed else { return }
        suspendedForBackground = true             // a start that has not reached its launch yet sees this and does not launch
        guard let coordinator else { return }
        await coordinator.suspend()
    }

    /// What the system's expiration handler runs (`BackgroundGrace`); a test calls it too.
    func backgroundTimeExpired() async { await suspendForBackground() }

    /// Whether a background-time assertion is held right now, and the system taking it back (the same code path as the real
    /// expiration handler; tests call it).
    var holdsBackgroundGrace: Bool { grace.isHolding }
    func expireBackgroundGrace() { grace.expired() }

    private var expiryAction: @MainActor () -> Void { { [weak self] in Task { @MainActor in await self?.suspendForBackground() } } }

    /// The scene went to the background. A refresh is requested. A cycle that is running (a foreground one, a manual one, one the
    /// coordinator started for a push) may finish inside the background time the system grants; if it outlives that time the grace
    /// expires and the sync is suspended (fix round 1).
    func sceneDidEnterBackground() {
        guard isOn, !closed else { return }
        services.scheduleBackgroundRefresh()
        guard isWorking || launchInFlight || state == .syncing else { return }
        grace.begin("icloud-background", onExpire: expiryAction)
        Task { @MainActor [weak self] in
            while let self, self.grace.isHolding, self.isWorking || self.launchInFlight || self.state == .syncing, !self.closed {
                try? await Task.sleep(for: .milliseconds(100))
            }
            self?.grace.end()
        }
    }

    // MARK: the switch

    func setSwitch(_ on: Bool) async {
        if on { await turnOn() } else { await stopSyncing() }
    }

    func turnOn() async {
        guard isAvailable, !isWorking else { return }
        await work(progress: MobileCloudSyncStrings.savingBackupFirst) {
            try await self.enable(recovery: nil, notePassword: nil)
        }
    }

    /// "Stop syncing": the engine stops; nothing is deleted anywhere. It always works: a manual "Sync now" that hangs holds
    /// the page's working state, but Stop does not wait for it. It cancels the running cycle through the coordinator (one deadline,
    /// the fence refuses what a stuck call writes later) and returns to Off.
    func stopSyncing() async {
        guard isAvailable, !stoppingNow else { return }
        stoppingNow = true
        defer { stoppingNow = false }
        backgroundEpoch += 1
        stopScheduling()
        setPushRegistered(false)
        clearTransient()
        if let coordinator { await coordinator.disable() }
        else { try? store.setSwitchedOn(false) }
        apply(.off)
        clearTransient()
    }

    private func enable(recovery: RecoveryChoice?, notePassword: String?) async throws {
        let coordinator = ensureCoordinator()
        isOn = true
        do {
            let result = try await coordinator.enable(recovery: recovery, notePassword: notePassword)
            apply(result)
            await afterRun(coordinator)
            startScheduling()
        } catch CloudCoordinatorError.recoveryChoiceRequired {
            // The first device of this iCloud account: the person decides about recovery words before keys exist.
            beginRecoverySheet(.firstSetup)
        }
    }

    // MARK: recovery words

    func beginCreateOrReplaceRecoveryWords() {
        guard isAvailable, !isWorking else { return }
        beginRecoverySheet(.later)
    }

    private func beginRecoverySheet(_ purpose: MobileCloudRecoveryPurpose) {
        do {
            recoveryOffer = try RecoveryKeyOffer.make()
            recoveryPurpose = purpose
            recoverySheetError = nil
        } catch { fail(error) }
    }

    /// The three-word check. Returns true when the sheet can close.
    @discardableResult
    func confirmRecoveryWords(typed: [Int: String]) async -> Bool {
        guard let offer = recoveryOffer, let purpose = recoveryPurpose, !isWorking else { return false }
        let choice: RecoveryChoice
        do { choice = try offer.confirm(typed) }
        catch { recoverySheetError = MobileCloudSyncStrings.sheetWrongWords; return false }
        recoverySheetError = nil
        closeRecoverySheet()
        await work(progress: nil) {
            switch purpose {
            case .firstSetup:
                try await self.enable(recovery: choice, notePassword: self.takeHeldNotePassword())
            case .later:
                guard let coordinator = self.coordinator else { throw CloudCoordinatorError.notRunning }
                switch try await coordinator.saveRecoveryWords(choice) {
                case .replaced: self.notice = MobileCloudSyncStrings.recoveryReplaced
                case .lostRace: self.notice = MobileCloudSyncStrings.recoveryChangedElsewhere
                }
                self.recoveryNudge = false
                self.refreshFacts()
            }
        }
        return true
    }

    /// "Skip for now", allowed only with the risk sentence ticked. First setup only.
    @discardableResult
    func skipRecoveryWords(acknowledged: Bool) async -> Bool {
        guard recoveryPurpose == .firstSetup, !isWorking else { return false }
        let choice: RecoveryChoice
        do { choice = try RecoveryChoice.skip(acknowledged: acknowledged) }
        catch { recoverySheetError = MobileCloudSyncStrings.sheetRiskSentence; return false }
        closeRecoverySheet()
        let held = takeHeldNotePassword()
        await work(progress: nil) {          // the backup was made before the sheet
            try await self.enable(recovery: choice, notePassword: held)
        }
        return true
    }

    /// Cancel. During first setup nothing was saved or created yet, so sync goes back to off.
    func cancelRecoverySheet() async {
        let purpose = recoveryPurpose
        closeRecoverySheet()
        clearHeldNotePassword()
        guard purpose == .firstSetup else { return }
        await work(progress: nil) {
            if let coordinator = self.coordinator { await coordinator.disable() }
            else { try self.store.setSwitchedOn(false) }
            self.apply(.off)
        }
    }

    private func closeRecoverySheet() {
        recoveryOffer = nil; recoveryPurpose = nil; recoverySheetError = nil
    }

    /// "Use recovery words" (this device has no key yet).
    func useRecoveryWords(_ words: String) async {
        guard !isWorking else { return }
        await work(progress: nil) {
            let coordinator = self.ensureCoordinator()
            self.apply(try await coordinator.joinWithRecoveryKey(words))
            await self.afterRun(coordinator)
            self.startScheduling()
        }
    }

    func dismissLostSetupRace() async {
        lostSetupRace = false
        await coordinator?.dismissLostSetupRace()
    }

    // MARK: note password

    func submitNotePassword(_ password: String) async {
        guard !isWorking, !password.isEmpty else { return }
        await work(progress: nil) {
            let coordinator = self.ensureCoordinator()
            do {
                self.apply(try await coordinator.syncNow(notePassword: password))
                await self.afterRun(coordinator)
                self.startScheduling()
            } catch CloudCoordinatorError.recoveryChoiceRequired {
                // The password is right and the backup is made; the first device now decides about recovery words.
                self.clearHeldNotePassword()
                self.heldNotePassword = MobileHeldSecret(password)
                self.beginRecoverySheet(.firstSetup)
            }
        }
    }

    // MARK: sync and repair actions

    func syncNow() async {
        guard let coordinator, !isWorking else { return }
        suspendedForBackground = false
        await work(progress: nil) {
            self.apply(try await coordinator.syncNow())
            await self.afterRun(coordinator)
        }
    }

    /// "Upload again" after the synced copy was removed: the only way to create it again.
    func uploadAgain() async {
        guard let coordinator, !isWorking else { return }
        await work(progress: nil) {
            try await coordinator.chooseUploadAgain()
            var next = try await coordinator.syncNow()
            // The notes of the removed copy come back as "missing" the first time round; one button is enough for the person.
            if case .itemsMissingInCloud = next {
                try await coordinator.uploadMissingAgain()
                next = try await coordinator.syncNow()
            }
            self.apply(next)
            await self.afterRun(coordinator)
        }
    }

    /// "Upload them again" after notes went missing in iCloud.
    func uploadThemAgain() async {
        guard let coordinator, !isWorking else { return }
        await work(progress: nil) {
            try await coordinator.uploadMissingAgain()
            self.apply(try await coordinator.syncNow())
            await self.afterRun(coordinator)
        }
    }

    /// "Move This Library to iCloud…": the private-server sync makes its final sync, checks that nothing is left
    /// in either direction, saves a verified backup and lets go (`MobileSyncController.leaveForICloud`); then the switch goes on as
    /// usual (its own backup and first sync). A refusal changes nothing and says why. The Mac twin is `CloudSyncController.moveToICloud`.
    func moveToICloud() async { await move(withoutMissingFiles: false) }

    /// "Move to iCloud Without These Files…", after the same confirmation: the same move; attachments whose file no device and no server ever had no longer stop it. Their
    /// rows stay as local rows that are never sent; the notes keep their text and show the missing file as before.
    func moveWithoutMissingFiles() async { await move(withoutMissingFiles: true) }

    private func move(withoutMissingFiles: Bool) async {
        guard canMoveToICloud, !isWorking, let leavePrivateServer else { return }
        await work(progress: MobileCloudSyncStrings.moveProgress) {
            try await leavePrivateServer(withoutMissingFiles)
            self.refreshFacts()
            guard !self.boundToPrivateServer else { throw MobileCloudSyncStringError(MobileCloudSyncStrings.genericProblem) }
            self.progress = MobileCloudSyncStrings.savingBackupFirst
            try await self.enable(recovery: nil, notePassword: nil)
        }
    }

    /// "Delete my iCloud copy": backup, delete the copy, let go. This device keeps its notes.
    func deleteICloudCopy() async {
        guard isAvailable, !isWorking else { return }
        await work(progress: nil) {
            self.stopScheduling()
            self.setPushRegistered(false)
            let coordinator = self.ensureCoordinator()
            do { try await coordinator.deleteICloudCopy() }
            catch is CloudSyncError, is URLError {
                self.apply(.off)      // sync was switched off first; nothing was deleted
                throw MobileCloudSyncStringError(MobileCloudSyncStrings.cannotDeleteCopy)
            }
            self.apply(.off)
            self.notice = MobileCloudSyncStrings.deleteCopyDone
        }
    }

    /// Advanced: "Remove the iCloud key from all my devices".
    func removeICloudKey() async {
        guard isAvailable, !isWorking else { return }
        await work(progress: nil) {
            self.stopScheduling()
            self.setPushRegistered(false)
            let coordinator = self.ensureCoordinator()
            try await coordinator.removeICloudKey()
            self.apply(.off)
            self.notice = MobileCloudSyncStrings.removeKeyDone
        }
    }

    // MARK: account changed

    /// The default: nothing is sent to the new account.
    func keepOffline() async {
        showsAccountChangedSheet = false
        await stopSyncing()
    }

    func syncWithNewAccount() async {
        guard isAvailable, !isWorking else { return }
        showsAccountChangedSheet = false
        await work(progress: MobileCloudSyncStrings.savingBackupFirst) {
            self.stopScheduling()
            let coordinator = self.ensureCoordinator()
            try await coordinator.detachForNewAccount()
            self.recoveryState = .none
            try await self.enable(recovery: nil, notePassword: nil)
        }
    }

    // MARK: derived

    var statusText: String { MobileCloudSyncStrings.status(for: state) }
    var headline: String { MobileCloudSyncStrings.headline(for: state) }

    var needsRecoveryWords: Bool { if case .needsRecoveryKey = state { true } else { false } }
    /// G0 A6: waiting for the iCloud Keychain item that may never arrive. The recovery words are the way in while this device waits
    /// for iCloud Keychain or cannot reach it; the coordinator offers the route after ten minutes and the page shows it at once.
    var canUseRecoveryWords: Bool {
        switch state {
        case .needsRecoveryKey, .waitingForKeychain, .keychainUnavailable: isOn
        default: false
        }
    }
    var waitsForKeychain: Bool { if case .waitingForKeychain = state { true } else { false } }
    var needsNotePassword: Bool { if case .needsNotePassword = state { true } else { false } }
    var canUploadAgain: Bool { if case .zoneRemoved = state { true } else { false } }
    var missingCount: Int? { if case .itemsMissingInCloud(let count) = state { count } else { nil } }
    var accountChanged: Bool { if case .accountChanged = state { true } else { false } }
    var showsOpenSettings: Bool {
        switch state {
        case .signedOutOfICloud, .restricted, .keychainUnavailable, .waitingForKeychain, .quotaFull: true
        default: false
        }
    }
    /// The recovery section: saved, or the reminder.
    var recoverySaved: Bool { recoveryState == .saved }
    var showsRecoveryReminder: Bool { isOn && CloudRecoveryReminder.showsSettingsReminder(recoveryState) }
    var hasKeys: Bool { isOn && !needsRecoveryWords }

    // MARK: look of the status

    nonisolated static func symbol(for state: CloudSyncState, working: Bool) -> String {
        if working { return "arrow.triangle.2.circlepath.icloud" }
        switch state {
        case .off: return "icloud.slash"
        case .upToDate: return "checkmark.icloud"
        case .syncing: return "arrow.triangle.2.circlepath.icloud"
        case .offline: return "icloud.slash"
        case .signedOutOfICloud, .restricted, .quotaFull, .accountChanged, .zoneRemoved, .itemsMissingInCloud, .failed,
             .itemsUnreadable, .needsAppUpdate, .keychainUnavailable, .notAvailableInThisBuild:
            return "exclamationmark.icloud"
        default: return "icloud"
        }
    }

    nonisolated static func tint(for state: CloudSyncState) -> Color {
        switch state {
        case .signedOutOfICloud, .restricted, .quotaFull, .accountChanged, .zoneRemoved, .itemsMissingInCloud, .failed,
             .itemsUnreadable, .needsAppUpdate, .keychainUnavailable:
            return .orange
        default: return .primary
        }
    }

    // MARK: internals

    private func ensureCoordinator() -> CloudSyncCoordinator {
        if let coordinator { return coordinator }
        servicesTouched += 1
        started = true          // a coordinator exists: `start()` has nothing left to launch
        let namespace = Self.namespace(for: library.paths.root)
        let parts = services.gateway(MobileCloudSyncGatewayRequest(store: store, paths: library.paths))
        let coordinator = CloudSyncCoordinator(
            library: library, gateway: parts.gateway, seeds: services.keychain(namespace), configuration: services.configuration,
            clock: services.clock, drainTimeout: services.drainTimeout, cancelOperations: parts.cancelOperations)
        remoteNotificationHandler = parts.handleRemoteNotification
        self.coordinator = coordinator
        listener = Task { [weak self] in
            for await next in coordinator.state { self?.apply(next) }
        }
        return coordinator
    }

    /// The same library always gets the same name for its pending-key item.
    static func namespace(for root: URL) -> String {
        let digest = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "ios-" + digest
    }

    private func startScheduling() {
        guard scheduler == nil, !closed, isOn, let coordinator else { return }
        setPushRegistered(true)
        scheduler = MobileCloudSyncScheduler(
            database: library.database, timing: timing,
            didEnterBackground: { [weak self] in self?.sceneDidEnterBackground() }
        ) { [weak self] reason in
            guard let self else { return .stop }
            return await self.scheduledRun(reason, coordinator: coordinator)
        }
        scheduler?.start()
        services.scheduleBackgroundRefresh()
    }

    /// The switch is off: whatever refresh was asked for is withdrawn, and a refresh that is running now will not ask for the next one.
    /// The private-server sync shares the identifier, so it is asked to request its own again (it does so only when it needs one).
    private func withdrawBackgroundRefresh() {
        backgroundEpoch += 1
        services.cancelBackgroundRefresh()
        services.restorePrivateServerRefresh(library)
    }

    private func setPushRegistered(_ wanted: Bool) {
        guard wanted != registeredForPush else { return }
        registeredForPush = wanted
        if wanted { services.registerForRemoteNotifications() } else { services.unregisterForRemoteNotifications() }
    }

    private func scheduledRun(_ reason: MobileCloudSyncScheduler.Reason, coordinator: CloudSyncCoordinator) async -> MobileCloudSyncScheduler.Outcome {
        guard isOn, !isWorking, !closed, !launchInFlight else { return .later }
        // Suspended for the background: only the person coming back (foreground) starts it again.
        if suspendedForBackground {
            guard reason == .foreground else { return .done }
            suspendedForBackground = false
        }
        // A person has to act first for these; the timer does not retry them in a loop.
        switch state {
        case .needsNotePassword, .needsRecoveryKey, .accountChanged, .zoneRemoved, .itemsMissingInCloud, .needsAppUpdate: return .needsPerson
        default: break
        }
        grace.begin("icloud-sync", onExpire: expiryAction)
        defer { grace.end() }
        do {
            let next = reason == .foreground ? try await coordinator.foreground() : try await coordinator.syncNow()
            apply(next)
            await afterRun(coordinator)
        } catch {
            if case CloudCoordinatorError.notRunning = error { return .stop }
            // Switched off or shut down while this cycle ran (its upload was cancelled): that is not a problem to show.
            guard scheduler != nil, !closed else { return .stop }
            fail(error)
        }
        switch await coordinator.retry {
        case .after(let seconds): return .retry(after: seconds)
        default: return .done
        }
    }

    /// After every answer from the coordinator: what its flags and the library say.
    private func afterRun(_ coordinator: CloudSyncCoordinator) async {
        refreshFacts()
        if await coordinator.lostSetupRace { lostSetupRace = true }
    }

    private func refreshFacts() {
        isOn = (try? store.isSwitchedOn()) ?? false
        if !isOn, (try? store.backend()) == .cloudkit, (try? store.isUploadEnabled()) == true { isOn = true }
        let backend = (try? store.backend()) ?? .none
        boundToPrivateServer = backend == .cloudflare
        showsMoveNotice = (try? PrivateServerMove.showsOtherDevicesNotice(store.database)) ?? false
        isBoundToICloud = backend == .cloudkit
        recoveryState = (try? store.keyState().recovery) ?? .none
    }

    func apply(_ next: CloudSyncState) {
        state = next
        if case .syncing = next { syncingStarts += 1 }
        // A different account or switching off ends the flow that needed the held password.
        switch next {
        case .accountChanged:
            clearHeldNotePassword()
            if recoveryPurpose == .firstSetup { closeRecoverySheet() }
        case .off: clearHeldNotePassword()
        default: break
        }
        needsNotePasswordInput = { if case .needsNotePassword = next { true } else { false } }()
        if case .upToDate(let date) = next {
            lastSync = date
            offerRecoveryOnceAfterFirstSync()
        }
        if case .accountChanged = next { showsAccountChangedSheet = true }
        if case .off = next {
            isOn = false; progress = nil; setPushRegistered(false); suspendedForBackground = false
            withdrawBackgroundRefresh()
        }
        refreshFacts()
    }

    /// CK-J1: a person who skipped is asked once more after the first sync that worked; the Settings reminder stays.
    private func offerRecoveryOnceAfterFirstSync() {
        guard CloudRecoveryReminder.offersAfterFirstSuccessfulSync(recoveryState) else { return }
        do { try CloudRecoveryReminder.noteOfferShown(in: store); recoveryNudge = true } catch { cloudSyncLogger.error("recovery offer not noted") }
    }

    private func clearTransient() {
        notice = nil; problem = nil; missingFilesToLeave = nil
    }

    private func work(progress: String?, _ body: @MainActor () async throws -> Void) async {
        isWorking = true
        self.progress = progress
        clearTransient()
        defer { isWorking = false; self.progress = nil }
        do { try await body() } catch { fail(error) }
    }

    private func fail(_ error: Error) {
        problem = Self.message(for: error)
        if case .unavailableAttachments(let notes, let more, true)? = error as? PrivateServerMoveRefusal { missingFilesToLeave = (notes, more) }
        refreshFacts()
        cloudSyncLogger.error("iCloud sync action failed: \(String(describing: type(of: error)), privacy: .public)")
    }

    /// What a person reads for an error. Never prints the error itself (it can name internal things).
    nonisolated static func message(for error: Error) -> String {
        if let string = error as? MobileCloudSyncStringError { return string.text }
        if error as? CloudVaultConversionError == .syncMustBeOff { return MobileCloudSyncStrings.turnSyncOffFirst }
        if case CryptoError.wrongPassword = error { return MobileCloudSyncStrings.notePasswordWrong }
        if let key = error as? CloudKeyError {
            switch key {
            case .invalidRecoveryKey: return MobileCloudSyncStrings.recoveryWordsWrong
            case .recoveryWordsNotConfirmed: return MobileCloudSyncStrings.sheetWrongWords
            default: return MobileCloudSyncStrings.genericProblem
            }
        }
        if let coordinator = error as? CloudCoordinatorError {
            switch coordinator {
            case .ownedElsewhere: return MobileCloudSyncStrings.ownedElsewhere
            case .libraryCopyNeverSyncs: return MobileCloudSyncStrings.libraryNeverSyncs
            case .boundToCloudflare: return MobileCloudSyncStrings.privateServerLibrary
            case .backupNotVerified: return MobileCloudSyncStrings.backupFailed
            case .accountNotCurrent: return MobileCloudSyncStrings.accountNotCurrent
            case .keyBundleCacheMissing: return MobileCloudSyncStrings.uploadAgainNeedsKey
            case .recoveryChoiceRequired, .notRunning: return MobileCloudSyncStrings.genericProblem
            }
        }
        if let refusal = error as? PrivateServerMoveRefusal {
            switch refusal {
            case .notBoundToPrivateServer: return MobileCloudSyncStrings.genericProblem
            case .notConnected: return MobileCloudSyncStrings.moveNotConnected
            case .syncPaused: return MobileCloudSyncStrings.movePaused
            case .firstSyncNotFinished: return MobileCloudSyncStrings.moveFirstSyncUnfinished
            case .unavailableAttachments(let notes, let more, let canMoveWithout):
                return MobileCloudSyncStrings.moveUnavailable(notes: notes, moreNotes: more, canMoveWithout: canMoveWithout)
            case .unsentChanges(let count): return MobileCloudSyncStrings.moveUnsent(count)
            case .unreceivedChanges(let count): return MobileCloudSyncStrings.moveUnreceived(count)
            case .syncRunning, .lockOrUnlockInProgress, .attachmentBeingSaved: return MobileCloudSyncStrings.moveBusy
            }
        }
        if error is URLError || error is SyncHTTPError { return MobileCloudSyncStrings.moveOffline }
        if error is SyncAccountDetachError { return MobileCloudSyncStrings.backupFailed }
        return MobileCloudSyncStrings.genericProblem
    }
}

/// Where the app delegate finds the controller of the open library, so that a silent push reaches it. Set by the app when the library
/// opens (only in a build that offers iCloud sync) and cleared when it closes; empty means "no iCloud sync here".
@MainActor enum MobileCloudSyncRouter {
    private(set) static weak var active: MobileCloudSyncController?
    static func connect(_ controller: MobileCloudSyncController?) { active = controller }

    /// The app delegate's completion value for a remote notification.
    static func handle(_ userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard let active else { return .noData }
        return await active.handleRemoteNotificationAndWait(userInfo) ? .newData : .noData
    }
}
