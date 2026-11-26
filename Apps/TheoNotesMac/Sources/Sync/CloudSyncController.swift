// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import CryptoKit
import Foundation
import Observation
import SwiftUI

/// What the gateway needs from the library that owns it: the SQLite store it persists zone state and send results in (and the engine
/// state it starts from), and the library folder the durable pin folder lives in.
struct CloudSyncGatewayRequest: Sendable {
    let store: CloudSyncStore
    let paths: AppPaths
}

/// A gateway with the two things the controller needs besides its protocol: the fence's cancellation and the way a remote
/// notification reaches it. Tests give just the gateway.
struct CloudSyncGatewayParts: Sendable {
    var gateway: any CloudKitGateway
    /// `{ await gateway.cancelOperations() }` for the live gateway; handed to the coordinator's fence.
    var cancelOperations: @Sendable () async -> Void = {}
    /// `LiveCloudKitGateway.handleRemoteNotification`; nil when the gateway has no push.
    var handleRemoteNotification: (@Sendable ([AnyHashable: Any]) -> Bool)?
}

/// What the controller needs from the outside world. `live` is the real thing (built only when something is switched on); tests
/// pass the in-memory fake. Nothing in here is called before the person flips the switch or a library that has it on starts.
struct CloudSyncServices: Sendable {
    var configuration: CloudKitConfiguration?
    var gateway: @Sendable (CloudSyncGatewayRequest) -> CloudSyncGatewayParts
    var keychain: @Sendable (_ namespace: String) -> any CloudKeychain
    var clock: @Sendable () -> Date = { Date() }
    var drainTimeout: TimeInterval = CloudSyncCoordinator.defaultDrainTimeout

    /// The shipped services. Only a build with a valid container AND the flag on (`ReleaseFeatures.cloudSyncAvailable`) gets
    /// a configuration and so a live gateway; any other build keeps `configuration == nil`, the coordinator answers "not available in
    /// this build" and nothing is constructed. Even then the gateway is only made when something asks for it (the person's switch is
    /// on), and `LiveCloudKitGateway` itself touches CloudKit on its first call, not when it is built.
    static func live(bundle: Bundle = .main) -> CloudSyncServices {
        live(infoDictionary: bundle.infoDictionary)
    }

    static func live(infoDictionary: [String: Any]?) -> CloudSyncServices {
        let configuration = ReleaseFeatures.cloudSyncAvailable(infoDictionary: infoDictionary)
            ? CloudKitConfiguration.from(infoDictionary: infoDictionary ?? [:]) : nil
        return CloudSyncServices(
            configuration: configuration,
            gateway: { request in
                guard let configuration else { return CloudSyncGatewayParts(gateway: UnavailableCloudKitGateway()) }
                let gateway = LiveCloudKitGateway(
                    configuration: configuration, store: request.store, engineState: try? request.store.engineState(),
                    pinDirectory: livePinDirectory(for: request.paths))
                return CloudSyncGatewayParts(
                    gateway: gateway, cancelOperations: { await gateway.cancelOperations() },
                    handleRemoteNotification: { gateway.handleRemoteNotification($0) })
            },
            keychain: { KeychainCloudKeySeedStore(namespace: $0, accessGroup: AppIdentity.current.keychainAccessGroup) })
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
struct UnavailableCloudKitGateway: CloudKitGateway {
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

/// A secret kept as bytes only for as long as a flow needs it, and zeroed when it is let go. The coordinator API takes a Swift `String`,
/// so `take()` has to make one for the single call that needs it; that `String` (and the one the password field produced) is outside
/// what can be zeroed. This only keeps the copy the controller itself holds short-lived and wiped.
final class HeldSecret {
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
enum CloudRecoverySheetPurpose: Equatable {
    /// First device, switching on: the sheet is part of "turn on" and its cancel turns sync off again.
    case firstSetup
    /// Settings: create the words (skipped at setup) or replace them.
    case later
}

/// Settings ▸ iCloud: owns one `CloudSyncCoordinator` for the library (lazily, flag-gated), turns its answers into what the tab
/// shows, and runs the actions the tab offers. Words live in `CloudSyncStrings`.
@MainActor @Observable
final class CloudSyncController {
    // MARK: what the tab shows

    private(set) var state: CloudSyncState = .off
    /// The person's switch (persisted in the library; true from the moment they flip it until they stop or delete).
    private(set) var isOn = false
    private(set) var isWorking = false
    /// The step the first enable is at ("Saving a backup first"); nil when nothing runs.
    private(set) var progress: String?
    private(set) var lastSync: Date?
    private(set) var recoveryState: CloudRecoveryState = .none
    private(set) var boundToPrivateServer = false
    /// The private-server side of the move, set by the app when this build has it (`AppEnvironment`); nil hides the button.
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
        if !isOn { return CloudSyncStrings.moveSyncOff }
        if problem != nil { return CloudSyncStrings.moveSyncBlocked }
        switch state {
        case .off, .syncing, .upToDate, .offline, .paused, .recoveryNotSaved, .itemsUnreadable: return nil
        default: return CloudSyncStrings.moveSyncBlocked
        }
    }
    /// This library is bound to an iCloud account (it has, or had, a synced copy).
    private(set) var isBoundToICloud = false
    /// This Mac set up at the same moment as another device and lost: its saved words protect nothing (Task 8).
    private(set) var lostSetupRace = false
    /// The first successful sync after a skipped recovery step: the tab asks once more.
    private(set) var recoveryNudge = false
    /// A line about something that worked, and one about something that did not. Both go away on the next action.
    private(set) var notice: String?
    private(set) var problem: String?

    // sheets
    private(set) var recoveryOffer: RecoveryKeyOffer?
    private(set) var recoveryPurpose: CloudRecoverySheetPurpose?
    private(set) var recoverySheetError: String?
    var showsAccountChangedSheet = false
    private(set) var needsNotePasswordInput = false

    let isLocalOnly: Bool
    /// The build offers iCloud sync (`ReleaseFeatures.cloudSyncAvailable`) and this launch may sync (not a `--data-dir` library).
    let isAvailable: Bool

    // MARK: collaborators

    @ObservationIgnored private let library: MacCloudSyncLibrary
    @ObservationIgnored private let services: CloudSyncServices
    @ObservationIgnored private let store: CloudSyncStore
    @ObservationIgnored private var coordinator: CloudSyncCoordinator?
    @ObservationIgnored private var scheduler: CloudSyncScheduler?
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var started = false
    /// True while `stopSyncing` runs, so a second tap does not start a second stop.
    @ObservationIgnored private var stoppingNow = false
    /// How a remote notification reaches the gateway; nil until the gateway exists (a switched-off library has none).
    @ObservationIgnored private var remoteNotificationHandler: (@Sendable ([AnyHashable: Any]) -> Bool)?
    /// The note password a protected library gave before the recovery step (the password comes first). Memory only; it is
    /// needed again by the enable that follows the sheet, and cleared as soon as that enable has run or the sheet is cancelled.
    @ObservationIgnored private var heldNotePassword: HeldSecret?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    /// True while the controller holds the note password of a protected library for the step after the recovery sheet.
    var holdsNotePassword: Bool { heldNotePassword != nil }
    @ObservationIgnored private var closed = false
    @ObservationIgnored private let timing: CloudSyncScheduler.Timing
    /// Counts how often the live services were asked for anything (a test pins that an off library asks for nothing).
    @ObservationIgnored private(set) var servicesTouched = 0

    init(library: MacCloudSyncLibrary, services: CloudSyncServices, available: Bool, timing: CloudSyncScheduler.Timing = .init()) {
        self.library = library
        self.services = services
        self.timing = timing
        store = CloudSyncStore(database: library.database, clock: services.clock)
        isLocalOnly = library.syncPolicy != .enabled
        isAvailable = available && library.syncPolicy == .enabled
        refreshFacts()
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearHeldNotePassword() }
        }
    }

    isolated deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        heldNotePassword?.zero()
    }

    // MARK: lifecycle

    /// App launch. A library whose switch is off does nothing here: no coordinator, no gateway, no keychain, no timer.
    func start() async {
        guard isAvailable, !started, !closed else { return }
        started = true
        refreshFacts()
        guard isOn else { return }
        do {
            let coordinator = ensureCoordinator()
            apply(try await coordinator.launch())
            await afterRun(coordinator)
            startScheduling()
        } catch CloudCoordinatorError.recoveryChoiceRequired {
            beginRecoverySheet(.firstSetup)    // the switch was on but the recovery step never finished
        } catch { fail(error) }
    }

    /// Lets go of the held note password and zeroes its bytes. Called when the flow that needed it ends, and on shutdown, account
    /// change, switching off and app termination.
    func clearHeldNotePassword() {
        heldNotePassword?.zero()
        heldNotePassword = nil
    }

    private func takeHeldNotePassword() -> String? {
        defer { clearHeldNotePassword() }
        return heldNotePassword?.string()
    }

    /// App quit or the window closed for good: stops the timer and the engine.
    func shutdown() async {
        closed = true
        clearHeldNotePassword()
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver); self.terminationObserver = nil }
        stopScheduling()
        listener?.cancel(); listener = nil
        if let coordinator { await coordinator.disable() }
        coordinator = nil
    }

    /// A remote notification, if one ever arrives (the Mac does not register for push: Gate G0 A4 found none on the Mac, so the timer,
    /// the foreground and the launch are its triggers). The gateway turns a private-database notification into a change event and the
    /// coordinator runs a cycle. Returns whether it was one; false while sync is off.
    @discardableResult
    func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard isOn, !closed, let handler = remoteNotificationHandler else { return false }
        return handler(userInfo)
    }

    /// Stops timers only (the window system is going away); the engine is stopped by `shutdown`.
    func stopScheduling() {
        scheduler?.stop(); scheduler = nil
    }

    // MARK: the switch

    func setSwitch(_ on: Bool) async {
        if on { await turnOn() } else { await stopSyncing() }
    }

    func turnOn() async {
        guard isAvailable, !isWorking else { return }
        await work(progress: CloudSyncStrings.savingBackupFirst) {
            try await self.enable(recovery: nil, notePassword: nil)
        }
    }

    /// "Stop syncing": the engine stops; nothing is deleted anywhere. It always works: a manual "Sync now" that hangs holds
    /// the tab's working state, but Stop does not wait for it. It cancels the running cycle through the coordinator (one deadline,
    /// the fence refuses what a stuck call writes later) and returns to Off.
    func stopSyncing() async {
        guard isAvailable, !stoppingNow else { return }
        stoppingNow = true
        defer { stoppingNow = false }
        stopScheduling()
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

    private func beginRecoverySheet(_ purpose: CloudRecoverySheetPurpose) {
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
        catch { recoverySheetError = CloudSyncStrings.sheetWrongWords; return false }
        recoverySheetError = nil
        closeRecoverySheet()
        await work(progress: nil) {
            switch purpose {
            case .firstSetup:
                try await self.enable(recovery: choice, notePassword: self.takeHeldNotePassword())
            case .later:
                guard let coordinator = self.coordinator else { throw CloudCoordinatorError.notRunning }
                switch try await coordinator.saveRecoveryWords(choice) {
                case .replaced: self.notice = CloudSyncStrings.recoveryReplaced
                case .lostRace: self.notice = CloudSyncStrings.recoveryChangedElsewhere
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
        catch { recoverySheetError = CloudSyncStrings.sheetRiskSentence; return false }
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

    /// "Use recovery words" (this Mac has no key yet).
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
                self.heldNotePassword = HeldSecret(password)
                self.beginRecoverySheet(.firstSetup)
            }
        }
    }

    // MARK: sync and repair actions

    func syncNow() async {
        guard let coordinator, !isWorking else { return }
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
    /// in either direction, saves a verified backup and lets go (`MacSyncController.leaveForICloud`); then the switch goes on as
    /// usual (its own backup and first sync). A refusal changes nothing and says why.
    func moveToICloud() async { await move(withoutMissingFiles: false) }

    /// "Move to iCloud Without These Files…", after the same confirmation: the same move; attachments whose file no device and no server ever had no longer stop it. Their
    /// rows stay as local rows that are never sent; the notes keep their text and show the missing file as before.
    func moveWithoutMissingFiles() async { await move(withoutMissingFiles: true) }

    private func move(withoutMissingFiles: Bool) async {
        guard canMoveToICloud, !isWorking, let leavePrivateServer else { return }
        await work(progress: CloudSyncStrings.moveProgress) {
            try await leavePrivateServer(withoutMissingFiles)
            self.refreshFacts()
            guard !self.boundToPrivateServer else { throw CloudSyncStringError(CloudSyncStrings.genericProblem) }
            self.progress = CloudSyncStrings.savingBackupFirst
            try await self.enable(recovery: nil, notePassword: nil)
        }
    }

    /// "Delete my iCloud copy": backup, delete the copy, let go. This Mac keeps its notes.
    func deleteICloudCopy() async {
        guard isAvailable, !isWorking else { return }
        await work(progress: nil) {
            self.stopScheduling()
            let coordinator = self.ensureCoordinator()
            do { try await coordinator.deleteICloudCopy() }
            catch is CloudSyncError, is URLError {
                self.apply(.off)      // sync was switched off first; nothing was deleted
                throw CloudSyncStringError(CloudSyncStrings.cannotDeleteCopy)
            }
            self.apply(.off)
            self.notice = CloudSyncStrings.deleteCopyDone
        }
    }

    /// Advanced: "Remove the iCloud key from all my devices".
    func removeICloudKey() async {
        guard isAvailable, !isWorking else { return }
        await work(progress: nil) {
            self.stopScheduling()
            let coordinator = self.ensureCoordinator()
            try await coordinator.removeICloudKey()
            self.apply(.off)
            self.notice = CloudSyncStrings.removeKeyDone
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
        await work(progress: CloudSyncStrings.savingBackupFirst) {
            self.stopScheduling()
            let coordinator = self.ensureCoordinator()
            try await coordinator.detachForNewAccount()
            self.recoveryState = .none
            try await self.enable(recovery: nil, notePassword: nil)
        }
    }

    // MARK: derived

    var statusText: String { CloudSyncStrings.status(for: state) }
    var headline: String { CloudSyncStrings.headline(for: state) }

    var needsRecoveryWords: Bool { if case .needsRecoveryKey = state { true } else { false } }
    /// The recovery words are also the way in while this Mac waits for iCloud Keychain or cannot reach it: the wait is ten minutes.
    var canUseRecoveryWords: Bool {
        switch state {
        case .needsRecoveryKey, .waitingForKeychain, .keychainUnavailable: isOn
        default: false
        }
    }
    var needsNotePassword: Bool { if case .needsNotePassword = state { true } else { false } }
    var canUploadAgain: Bool { if case .zoneRemoved = state { true } else { false } }
    var missingCount: Int? { if case .itemsMissingInCloud(let count) = state { count } else { nil } }
    var accountChanged: Bool { if case .accountChanged = state { true } else { false } }
    var showsOpenICloudSettings: Bool {
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
        let namespace = Self.namespace(for: library.paths.root)
        let parts = services.gateway(CloudSyncGatewayRequest(store: store, paths: library.paths))
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
        return "mac-" + digest
    }

    private func startScheduling() {
        guard scheduler == nil, !closed, isOn, let coordinator else { return }
        scheduler = CloudSyncScheduler(database: library.database, timing: timing) { [weak self] reason in
            guard let self else { return .stop }
            return await self.scheduledRun(reason, coordinator: coordinator)
        }
        scheduler?.start()
    }

    private func scheduledRun(_ reason: CloudSyncScheduler.Reason, coordinator: CloudSyncCoordinator) async -> CloudSyncScheduler.Outcome {
        guard isOn, !isWorking, !closed else { return .later }
        // A person has to act first for these; the timer does not retry them in a loop.
        switch state {
        case .needsNotePassword, .needsRecoveryKey, .accountChanged, .zoneRemoved, .itemsMissingInCloud, .needsAppUpdate: return .needsPerson
        default: break
        }
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
        if case .off = next { isOn = false; progress = nil }
        refreshFacts()
    }

    /// CK-J1: a person who skipped is asked once more after the first sync that worked; the Settings reminder stays.
    private func offerRecoveryOnceAfterFirstSync() {
        guard CloudRecoveryReminder.offersAfterFirstSuccessfulSync(recoveryState) else { return }
        do { try CloudRecoveryReminder.noteOfferShown(in: store); recoveryNudge = true } catch { appLogger.error("recovery offer not noted") }
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
        appLogger.error("iCloud sync action failed: \(String(describing: type(of: error)), privacy: .public)")
    }

    /// What a person reads for an error. Never prints the error itself (it can name internal things).
    static func message(for error: Error) -> String {
        if let string = error as? CloudSyncStringError { return string.text }
        if error as? CloudVaultConversionError == .syncMustBeOff { return CloudSyncStrings.turnSyncOffFirst }
        if case CryptoError.wrongPassword = error { return CloudSyncStrings.notePasswordWrong }
        if let key = error as? CloudKeyError {
            switch key {
            case .invalidRecoveryKey: return CloudSyncStrings.recoveryWordsWrong
            case .recoveryWordsNotConfirmed: return CloudSyncStrings.sheetWrongWords
            default: return CloudSyncStrings.genericProblem
            }
        }
        if let coordinator = error as? CloudCoordinatorError {
            switch coordinator {
            case .ownedElsewhere: return CloudSyncStrings.ownedElsewhere
            case .libraryCopyNeverSyncs: return CloudSyncStrings.libraryCopyNeverSyncs
            case .boundToCloudflare: return CloudSyncStrings.privateServerLibrary
            case .backupNotVerified: return CloudSyncStrings.backupFailed
            case .accountNotCurrent: return CloudSyncStrings.accountNotCurrent
            case .keyBundleCacheMissing: return CloudSyncStrings.uploadAgainNeedsKey
            case .recoveryChoiceRequired, .notRunning: return CloudSyncStrings.genericProblem
            }
        }
        if let refusal = error as? PrivateServerMoveRefusal {
            switch refusal {
            case .notBoundToPrivateServer: return CloudSyncStrings.genericProblem
            case .notConnected: return CloudSyncStrings.moveNotConnected
            case .syncPaused: return CloudSyncStrings.movePaused
            case .firstSyncNotFinished: return CloudSyncStrings.moveFirstSyncUnfinished
            case .unavailableAttachments(let notes, let more, let canMoveWithout):
                return CloudSyncStrings.moveUnavailable(notes: notes, moreNotes: more, canMoveWithout: canMoveWithout)
            case .unsentChanges(let count): return CloudSyncStrings.moveUnsent(count)
            case .unreceivedChanges(let count): return CloudSyncStrings.moveUnreceived(count)
            case .syncRunning, .lockOrUnlockInProgress, .attachmentBeingSaved: return CloudSyncStrings.moveBusy
            }
        }
        if error is URLError || error is SyncHTTPError { return CloudSyncStrings.moveOffline }
        if error is SyncAccountDetachError { return CloudSyncStrings.backupFailed }
        return CloudSyncStrings.genericProblem
    }
}

/// A message that is already in a person’s words.
struct CloudSyncStringError: Error { let text: String; init(_ text: String) { self.text = text } }
