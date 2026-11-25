// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import CryptoKit
import LocalAuthentication
import Foundation
import Observation
import os

private let mobileLinkLogger = Logger(subsystem: MobileIdentity.bundleIdentifier, category: "links")

enum MobileMissingJournalRecoveryError: LocalizedError, Equatable {
    case unlockRequired
    case waitingForSyncKey
    case leftoversNeedReview
    case recoveryFailed
    var errorDescription: String? {
        switch self {
        case .unlockRequired: "Some recovered edits need your notes password. Unlock your notes, then try again."
        case .waitingForSyncKey: "Some recovered edits are waiting for the notes key from another device through sync. Their recovery journals are kept."
        case .recoveryFailed: "Some edits could not be recovered. Check available storage and try again; recovery files were kept."
        case .leftoversNeedReview: "Recovered notes are saved. Review and remove their leftover recovery files before continuing."
        }
    }
}

enum MobileSketchDraftError: LocalizedError {
    case protectedDrafts, draftsPreventReplacement
    var errorDescription: String? {
        switch self {
        case .protectedDrafts: "Protected sketch drafts still need this password. Open a draft or discard the drafts before deleting the password."
        case .draftsPreventReplacement: "Open or discard your sketch drafts before replacing this library."
        }
    }
}

/// One sandboxed library, with the same journal-before-ack sessions as the Mac app.
@MainActor @Observable
final class MobileLibrary {
    @ObservationIgnored let sortUndoCoordinator = MobileSortUndoCoordinator()
    let paths: AppPaths
    let database: AppDatabase
    let store: NoteStore
    let ocr: OCRQueue
    private var ocrActive = false
    var isActive: Bool { ocrActive }
    private var syncExclusive = false
    private var attachmentWriteInFlight = false { didSet { if !attachmentWriteInFlight { resumeSceneAdmissionWaiters() } } }
    @ObservationIgnored var spotlightDidChange: (() -> Void)?
    private(set) var isClosed = false { didSet { spotlightDidChange?(); watchPrivacyDidChange?() } }
    private(set) var isClosing = false { didSet { spotlightDidChange?(); watchPrivacyDidChange?(); if !isClosing { resumeSceneAdmissionWaiters() } } }
    var scope: SidebarScope = .notes { didSet { if scope != oldValue { observe() } } }
    var query = "" { didSet { search(); dispatchLegacyNavigation() } }
    var selectedID: String? {
        didSet {
            if !restoringDisplayedSelection { selectionIntentGeneration &+= 1 }
            if oldValue != selectedID, let oldValue {
                // If a capture was left before its editor loaded, a later open is a real open.
                unrecordedCaptureOpens.remove(oldValue)
            }
            if let selectedID { history.visit(selectedID) }
            dispatchLegacyNavigation()
        }
    }
    private(set) var selectionIntentGeneration = 0
    @ObservationIgnored private var restoringDisplayedSelection = false
    func restoreDisplayedSelection(_ id: String) {
        restoringDisplayedSelection = true
        defer { restoringDisplayedSelection = false }
        selectedID = id
    }
    var workspace: Workspace? { didSet { if workspace != oldValue { observe() } } }
    var history = NoteHistory()
    var pendingCallbackNavigation: MobileCallbackNavigation? { didSet { dispatchLegacyNavigation() } }
    var pendingCaret: [String: Int] = [:]
    @ObservationIgnored private var unrecordedCaptureOpens: Set<String> = []
    @ObservationIgnored private var activeCaptures: Set<String> = []
    var tagUndo: TagRewriteResult?
    var preferences = MobilePreferences()
    private(set) var privateAccess: LockedNoteAccess?
    func acceptNotePasswordRewrap(_ password: String) async throws {
        let privateAccess = privateAccess, syncAccess = syncNoteAccess
        try await Task.detached(priority: .userInitiated) {
            try privateAccess?.acceptPasswordRewrap(password: password)
            try syncAccess?.acceptPasswordRewrap(password: password)
        }.value
    }
    private(set) var hasNotePassword = false
    private var unlockGeneration = 0
    @ObservationIgnored private var syncNoteAccess: LockedNoteAccess?
    private(set) var biometryEnabled = false
    private(set) var authenticatingDevice = false
    private(set) var appLockEnabled = false { didSet { spotlightDidChange?(); watchPrivacyDidChange?() } }
    private(set) var appLocked = false { didSet { spotlightDidChange?(); watchPrivacyDidChange?() } }
    @ObservationIgnored var watchPrivacyDidChange: (() -> Void)?
    @ObservationIgnored var watchWillRestrictAccess: (() -> Void)?
    var settings: Settings { Settings(db: database) }
    private(set) var snapshot = LibrarySnapshot()
    private(set) var items: [NoteListItem] = []
    var errorMessage: String?
    var recoveryMessage: String?
    struct RecoveredJournalNotice: Identifiable {
        let id: UUID
        let sourceID: String
        let suffix: String
        let noteID: String
        let noteRevision: Int
        let noteLocked: Bool
        let retirement: MissingJournalRecovery.Retirement
    }
    private(set) var recoveredJournalNotices: [RecoveredJournalNotice] = []
    struct RecoveredVariantNotice: Identifiable {
        let id: UUID
        let sourceID: String
        let noteIDs: [String]
        let sourceMustExist: Bool
        let retirement: JournalVariantRecovery.Retirement
    }
    private(set) var recoveredVariantNotices: [RecoveredVariantNotice] = []
    private var missingJournalBlock: MobileMissingJournalRecoveryError?
    private var allowSealedJournalMoveAside = false
    private var keyUnavailableJournalFiles: Set<String> = []
    private var retirementCleanupPending = false
    private(set) var missingJournalRecoveryUnresolved = false
    private(set) var quarantinableJournalFiles: [String] = []
    private(set) var quarantinableMarkers: [String] = []
    /// What one Move aside confirmation covers: the eligible files, otherwise one blocking marker.
    var quarantineOffer: [String] { quarantinableJournalFiles.isEmpty ? Array(quarantinableMarkers.prefix(1)) : quarantinableJournalFiles }
    @ObservationIgnored private var existingReplayFailureIDs: Set<String> = []
    @ObservationIgnored private var lastReplayError: (any Error)?
    /// Q2: plain unsaved text of deleted notes during a password reset. It is never discarded:
    /// kept out of the gates and the eviction, then saved once the vault is gone.
    @ObservationIgnored private var resetDeferredPlainOrphans: Set<String> = []
    var awaitsMissingJournalSyncKey: Bool {
        if missingJournalBlock == .waitingForSyncKey { return true }
        guard privateAccess == nil, (try? NotePrivacy(store: store).hasPassword) == false,
              (try? store.canRecoverMissingJournalPlain()) == false else { return false }
        return NoteSession.liveSessionIDs(journalDirectory: paths.journal).contains { id in
            (try? store.note(id: id)) == nil
        }
    }
    @ObservationIgnored private var reportedOrphanSessions: Set<String> = []
    private(set) var libraryOperationBusy = false { didSet { spotlightDidChange?(); watchPrivacyDidChange?() } }
    private(set) var libraryGeneration = 0
    @ObservationIgnored var prepareForLibraryOperation: (() throws -> Void)?
    @ObservationIgnored var drainEditorForLibraryOperation: (() async throws -> (() -> Void)?)?
    @ObservationIgnored var displayedEditorNoteID: (() -> String?)?
    #if DEBUG && targetEnvironment(simulator)
    @ObservationIgnored var lockSelectedNoteForTesting: (() -> Void)?
    #endif
    let sceneRegistry = MobileSceneRegistry()
    private final class SceneState {
        weak var editor: MobileEditor?
        weak var navigation: MobileSceneNavigation?
        weak var observation: MobileSceneLibraryObservation?
        var activity: MobileSceneRegistry.Activity
        var activation: UInt64 = 0
        init(activity: MobileSceneRegistry.Activity) { self.activity = activity }
    }
    @ObservationIgnored private var sceneStates: [UUID: SceneState] = [:]
    private struct PendingSceneDetach {
        let state: SceneState
        let editor: MobileEditor
        let retryAfterAdmission: Int
        let automaticAttempts: Int
    }
    @ObservationIgnored private var pendingSceneDetaches: [UUID: PendingSceneDetach] = [:]
    @ObservationIgnored private var sceneDetachRetryTask: Task<Void, Never>?
    var pendingSceneDetachCount: Int { pendingSceneDetaches.count }
    var blockedSceneDetachCount: Int { pendingSceneDetaches.values.filter { $0.automaticAttempts >= 1 }.count }
    private var blockedSceneDetachMessage: String {
        "A closed window could not finish saving. Its edits and recovery journal are retained; operations that need that page remain blocked."
    }
    @ObservationIgnored private var sceneActivation: UInt64 = 0
    @ObservationIgnored private var activeSceneFreeze: MobileSceneRegistry.FreezeLease?
    @ObservationIgnored private var sceneDrainInFlight = false { didSet { if !sceneDrainInFlight { resumeSceneAdmissionWaiters() } } }
    @ObservationIgnored private var sceneAdmissionWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var sceneOperationPending = false { didSet { if !sceneOperationPending { resumeSceneAdmissionWaiters() } } }
    private(set) var sceneAdmissionGeneration = 0
    // Read together with sceneAdmissionGeneration: release of these guards retries deferred UI work.
    var sceneEditorAdmissionBlocked: Bool {
        sceneDrainInFlight || attachmentWriteInFlight || sceneOperationPending || libraryOperationBusy || isClosing || isClosed
    }
    private(set) var sceneRoutingGeneration = 0
    @ObservationIgnored private var sceneRoutingLease: (token: UUID, sceneID: UUID, deliveryID: UUID)?
    @ObservationIgnored private var scenePrivacyCloseToken: UUID?
    @ObservationIgnored private let sceneSketchHosts = NSHashTable<MobileSketchDraftHost>.weakObjects()
    @ObservationIgnored private var scenePrivacyCheckpointHosts: [MobileSketchDraftHost] = []
    @ObservationIgnored private var legacyDeliveryPending = false
    @ObservationIgnored private var dispatchingLegacyNavigation = false
    var hasRegisteredSceneWindows: Bool { !sceneStates.isEmpty }
    var hasActiveSceneWindows: Bool { sceneStates.values.contains { $0.activity == .active } }

    /// Register window activity before attaching/opening its editor, including slow/cold scenes.
    func registerScene(id: UUID, activity: MobileSceneRegistry.Activity) throws {
        guard !sceneOperationPending, !sceneDrainInFlight, !libraryOperationBusy, !isClosing, !isClosed else { throw MobileEditorDrainError.busy }
        if sceneStates[id] == nil { sceneStates[id] = SceneState(activity: activity) }
        _ = updateSceneActivity(id: id, activity: activity)
    }
    func registerScene(id: UUID, editor: MobileEditor, navigation: MobileSceneNavigation,
                       observation: MobileSceneLibraryObservation?, activity: MobileSceneRegistry.Activity) throws {
        try registerScene(id: id, activity: activity)
        try sceneRegistry.register(sceneID: id, editor: editor, activity: activity)
        let state = sceneStates[id]!
        state.editor = editor; state.navigation = navigation; state.observation = observation
        if legacyDeliveryPending { dispatchLegacyNavigation() }
    }
    @discardableResult func updateSceneActivity(id: UUID, activity: MobileSceneRegistry.Activity) -> MobileSceneRegistry.ActivityChange {
        let was = hasActiveSceneWindows
        guard let state = sceneStates[id] else { return .init(wasActive: was, isActive: was) }
        if activity == .active, state.activity != .active || state.activation == 0 {
            sceneActivation &+= 1; state.activation = sceneActivation
        }
        state.activity = activity
        sceneRoutingGeneration &+= 1
        _ = sceneRegistry.updateActivity(sceneID: id, activity: activity)
        let active = hasActiveSceneWindows
        setActive(active)
        if active { voiceCapture.updateSceneActivity(active: true, background: false) }
        else { voiceCaptureStorage?.updateSceneActivity(active: false,
            background: !sceneStates.isEmpty && sceneStates.values.allSatisfy { $0.activity == .background }) }
        if active, legacyDeliveryPending { dispatchLegacyNavigation() }
        return .init(wasActive: was, isActive: active)
    }
    func replaceSceneEditor(id: UUID, editor: MobileEditor, observation: MobileSceneLibraryObservation? = nil) async throws {
        guard !sceneOperationPending, !sceneDrainInFlight, !libraryOperationBusy, !isClosing, !isClosed,
              let state = sceneStates[id] else { throw MobileEditorDrainError.busy }
        if state.editor !== editor {
            sceneDrainInFlight = true
            defer { sceneDrainInFlight = false }
            _ = try await sceneRegistry.detach(sceneID: id)
            guard sceneStates[id] === state, !sceneOperationPending, !isClosing, !isClosed else { throw MobileEditorDrainError.busy }
            try sceneRegistry.register(sceneID: id, editor: editor, activity: state.activity)
            state.editor = editor
        }
        if let observation { state.observation = observation }
    }
    func replaceClosedSceneEditor(id: UUID, editor: MobileEditor, observation: MobileSceneLibraryObservation? = nil) throws {
        guard !sceneOperationPending, !sceneDrainInFlight, !libraryOperationBusy, !isClosing, !isClosed,
              let state = sceneStates[id] else { throw MobileEditorDrainError.busy }
        try sceneRegistry.replaceClosedEditor(sceneID: id, editor: editor)
        state.editor = editor
        if let observation { state.observation = observation }
    }
    func markSceneFrontmost(id: UUID) {
        guard let state = sceneStates[id] else { return }
        sceneActivation &+= 1; state.activation = sceneActivation
        sceneRoutingGeneration &+= 1
    }
    func isPreferredActiveScene(id: UUID, noteID: String? = nil) -> Bool {
        guard let state = sceneStates[id], state.activity == .active else { return false }
        if let lease = sceneRoutingLease { return lease.sceneID == id }
        let eligible = sceneStates.values.filter { candidate in
            candidate.activity == .active && candidate.navigation != nil &&
                (noteID == nil || candidate.navigation?.selectedID == noteID)
        }
        return eligible.max { $0.activation < $1.activation } === state
    }
    func beginSceneRoutingLease(sceneID: UUID, deliveryID: UUID, noteID: String? = nil) -> UUID? {
        if let lease = sceneRoutingLease {
            return lease.sceneID == sceneID && lease.deliveryID == deliveryID ? lease.token : nil
        }
        guard isPreferredActiveScene(id: sceneID, noteID: noteID), !sceneOperationPending, !isClosing, !isClosed else { return nil }
        let token = UUID(); sceneRoutingLease = (token, sceneID, deliveryID)
        sceneRoutingGeneration &+= 1
        return token
    }
    func releaseSceneRoutingLease(_ token: UUID) {
        guard let lease = sceneRoutingLease, lease.token == token else { return }
        let ownerStillAttached = sceneStates[lease.sceneID]?.navigation != nil
        sceneRoutingLease = nil; sceneRoutingGeneration &+= 1
        if ownerStillAttached {
            if legacyDeliveryPending { dispatchLegacyNavigation(to: lease.sceneID) }
        } else {
            // A late delivery for a closed modal owner must not migrate to another window.
            let previous = dispatchingLegacyNavigation; dispatchingLegacyNavigation = true
            legacyDeliveryPending = false; pendingCaret.removeAll(); pendingCallbackNavigation = nil
            dispatchingLegacyNavigation = previous
        }
    }
    private func resumeSceneAdmissionWaiters() {
        sceneAdmissionGeneration &+= 1
        let pending = sceneAdmissionWaiters; sceneAdmissionWaiters.removeAll()
        for waiter in pending { waiter.resume() }
        schedulePendingSceneDetaches()
    }
    private func schedulePendingSceneDetaches() {
        guard sceneDetachRetryTask == nil, !sceneEditorAdmissionBlocked else { return }
        let ids = pendingSceneDetaches.filter {
            $0.value.automaticAttempts < 1 && $0.value.retryAfterAdmission < sceneAdmissionGeneration
        }.map(\.key)
        guard !ids.isEmpty else { return }
        sceneDetachRetryTask = Task { [weak self] in
            guard let self else { return }
            defer { sceneDetachRetryTask = nil }
            for id in ids {
                guard !Task.isCancelled, !sceneEditorAdmissionBlocked else { return }
                guard let pending = pendingSceneDetaches[id], sceneStates[id] === pending.state,
                      pending.automaticAttempts < 1, pending.retryAfterAdmission < sceneAdmissionGeneration else { continue }
                pendingSceneDetaches[id] = PendingSceneDetach(state: pending.state, editor: pending.editor,
                    retryAfterAdmission: pending.retryAfterAdmission, automaticAttempts: pending.automaticAttempts + 1)
                do { try await detachScene(id: id) }
                catch { errorMessage = blockedSceneDetachMessage }
            }
        }
    }
    private func waitForSceneAdmission() async {
        while !isClosed && (sceneOperationPending || sceneDrainInFlight || attachmentWriteInFlight || isClosing) {
            await withCheckedContinuation { sceneAdmissionWaiters.append($0) }
        }
    }
    func detachScene(id: UUID) async throws {
        guard let state = sceneStates[id] else { return }
        // The disappearing View may release its last editor owner while these async
        // barriers drain. Keep its WebKit bridge/listener alive until registry detach
        // finishes (including a thrown/cancelled result); normal registry storage is weak.
        let closingEditor = pendingSceneDetaches[id]?.editor ?? state.editor
        var detached = false
        defer {
            if detached { pendingSceneDetaches.removeValue(forKey: id) }
            else if sceneStates[id] === state, let closingEditor {
                // An error/cancellation is not permission to drop a live page with
                // unacknowledged edits. Retry only after a FUTURE admission release,
                // never spin on this attempt's own failed release.
                let attempts = pendingSceneDetaches[id]?.automaticAttempts ?? 0
                pendingSceneDetaches[id] = PendingSceneDetach(state: state, editor: closingEditor,
                    retryAfterAdmission: sceneAdmissionGeneration, automaticAttempts: attempts)
                errorMessage = attempts >= 1 ? blockedSceneDetachMessage
                    : "A closed window is still saving. Its editor and recovery journal are kept; a later operation will retry once."
            }
            withExtendedLifetime(closingEditor) {}
        }
        _ = updateSceneActivity(id: id, activity: .background)
        state.observation?.stop()
        try await state.observation?.stopAndWait()
        // A disappearing window waits for an already-owned shared transition; it must
        // neither release somebody else's freeze nor leave a permanently stale entry.
        await waitForSceneAdmission()
        guard sceneStates[id] === state else { return }
        sceneDrainInFlight = true
        defer { sceneDrainInFlight = false }
        _ = try await sceneRegistry.detach(sceneID: id)
        if sceneStates[id] === state { sceneStates.removeValue(forKey: id) }
        detached = true
        setActive(hasActiveSceneWindows)
    }
    /// Register every new/recovered canvas host at its library-bound factory. Weak
    /// ownership avoids retaining a scene; pending host Tasks keep themselves alive.
    func registerSceneSketchHost(_ host: MobileSketchDraftHost, sceneID: UUID) {
        guard sceneStates[sceneID] != nil else { return }
        sceneSketchHosts.add(host)
    }
    /// Awaited INSIDE the existing shared privacy budget, never under a second timeout.
    func completeScenePrivacyCheckpoints() async throws {
        guard let token = scenePrivacyCloseToken else { throw CancellationError() }
        let hosts = scenePrivacyCheckpointHosts
        var firstError: (any Error)?
        for host in hosts {
            try Task.checkCancellation()
            do { try await host.completeSuspendedCheckpoint() }
            catch { if firstError == nil { firstError = error } }
            guard !Task.isCancelled, scenePrivacyCloseToken == token else { throw CancellationError() }
        }
        if let firstError { throw firstError }
    }
    func beginScenePrivacyClose() -> UUID? {
        guard !sceneOperationPending, !sceneDrainInFlight, !libraryOperationBusy, !isClosing, !isClosed else { return nil }
        let token = UUID(); scenePrivacyCloseToken = token
        // Snapshot/suspend ALL scenes synchronously, before shared admission changes
        // enqueue their UI cancellation callbacks. The key is still valid here.
        scenePrivacyCheckpointHosts = sceneSketchHosts.allObjects.sorted { $0.id.uuidString < $1.id.uuidString }
        scenePrivacyCheckpointHosts.forEach { $0.suspend() }
        sceneOperationPending = true
        for state in sceneStates.values { state.observation?.stop() }
        return token
    }
    /// Call only AFTER final key revocation, including bounded-timeout/OS-expiry failures.
    func finishScenePrivacyClose(_ token: UUID) {
        guard scenePrivacyCloseToken == token, privateAccess == nil else { return }
        scenePrivacyCloseToken = nil
        scenePrivacyCheckpointHosts.removeAll()
        sceneOperationPending = false
        libraryGeneration += 1
        restartSceneObservations()
    }
    func claimSceneLibrarySwitch() throws {
        guard !sceneOperationPending, !libraryOperationBusy, !isClosing, !isClosed,
              !attachmentWriteInFlight, voiceCaptureStorage?.isBusy != true else { throw BackupError.pendingFiles }
        sceneOperationPending = true
        for state in sceneStates.values { state.observation?.stop() }
    }
    func cancelSceneLibrarySwitch() {
        guard !isClosed, !isClosing, !libraryOperationBusy else { return }
        sceneOperationPending = false
        restartSceneObservations()
    }
    private func stopAndDrainSceneObservations() async throws {
        let observations = sceneStates.values.compactMap(\.observation)
        observations.forEach { $0.stop() }
        for observation in observations { try await observation.stopAndWait() }
    }
    private func restartSceneObservations() {
        guard !isClosed, !isClosing, !sceneOperationPending else { return }
        for state in sceneStates.values { state.observation?.start() }
    }
    private func prepareAllSceneEditors() throws {
        if hasRegisteredSceneWindows {
            if let activeSceneFreeze { try activeSceneFreeze.detachEditors() }
            else if editors.allObjects.contains(where: { $0.session != nil }) { throw MobileEditorDrainError.busy }
        } else { try prepareForLibraryOperation?() }
    }
    private var preferredLegacyScene: SceneState? {
        if let lease = sceneRoutingLease { return sceneStates[lease.sceneID] }
        return sceneStates.values.filter { $0.activity == .active && $0.navigation != nil }
            .max { $0.activation < $1.activation }
            ?? (sceneStates.count == 1 ? sceneStates.values.first : nil)
    }
    private func adoptSceneNavigationForLegacy(_ navigation: MobileSceneNavigation) {
        let previous = dispatchingLegacyNavigation; dispatchingLegacyNavigation = true
        defer { dispatchingLegacyNavigation = previous }
        workspace = navigation.workspace; scope = navigation.scope; query = navigation.query
        selectedID = navigation.selectedID
    }
    func prepareLegacyNavigationContext(for sceneID: UUID) {
        markSceneFrontmost(id: sceneID)
        if let navigation = sceneStates[sceneID]?.navigation { adoptSceneNavigationForLegacy(navigation) }
    }
    /// Legacy automation is a single delivery, never a broadcast to every window.
    func dispatchLegacyNavigation(to sceneID: UUID? = nil) {
        guard !dispatchingLegacyNavigation else { return }
        dispatchingLegacyNavigation = true
        defer { dispatchingLegacyNavigation = false }
        let chosen: SceneState?
        if let sceneID { chosen = sceneStates[sceneID] }
        else {
            chosen = preferredLegacyScene
        }
        guard let navigation = chosen?.navigation else { legacyDeliveryPending = true; return }
        navigation.workspace = workspace; navigation.scope = scope; navigation.query = query
        navigation.pendingCaret.merge(pendingCaret) { _, incoming in incoming }
        navigation.pendingCallbackNavigation = pendingCallbackNavigation
        navigation.selectedID = selectedID
        pendingCaret.removeAll()
        pendingCallbackNavigation = nil // Consumed exactly once; dispatch guard prevents an echo.
        legacyDeliveryPending = false
    }

    @ObservationIgnored private var observation: ObservationToken?
    @ObservationIgnored private var sessions: [String: NoteSession] = [:]
    /// Times the wiki-link follower's debounce; tests set a manual one before opening a session.
    @ObservationIgnored var linkScheduler: any DebounceScheduler = TaskDebounceScheduler()
    @ObservationIgnored private var linkMonitorStorage: TitleChangeMonitor?
    /// Follows titles typed in any open session and rewrites wiki links to them, as on the Mac (IOS-LINKS-R1).
    private var linkMonitor: TitleChangeMonitor {
        if let linkMonitorStorage { return linkMonitorStorage }
        let monitor = TitleChangeMonitor(
            scheduler: linkScheduler,
            read: { [weak self] id in try? self?.store.linkTargetState(id: id) },
            flush: { [weak self] in try? self?.flush() },
            rewrite: { [weak self] id, previous, busy in self?.rewriteLinks(to: id, from: previous, busy: busy) ?? true })
        linkMonitorStorage = monitor
        return monitor
    }
    @ObservationIgnored private let editors = NSHashTable<MobileEditor>.weakObjects()
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var dailyBackupTask: Task<Void, Never>?
    @ObservationIgnored private var attachmentSweepTask: Task<Int, Never>?
    @ObservationIgnored private var attachmentSweepResult: Int?
    @ObservationIgnored private var sketchDraftStoreStorage: MobileSketchDraftStore?
    var sketchDraftStore: MobileSketchDraftStore {
        if let sketchDraftStoreStorage { return sketchDraftStoreStorage }
        let result = MobileSketchDraftStore(root: paths.root, libraryID: MobileCardPublication.libraryID(for: paths))
        sketchDraftStoreStorage = result
        return result
    }
    @ObservationIgnored private var syncController: MobileSyncController?
    @ObservationIgnored private var voiceCaptureStorage: MobileVoiceCaptureModel?
    var voiceCaptureBusy: Bool { voiceCaptureStorage?.isBusy == true }
    @ObservationIgnored var makeVoiceCapture: (MobileLibrary) -> MobileVoiceCaptureModel = { MobileVoiceCaptureModel(library: $0) }
    var voiceCapture: MobileVoiceCaptureModel {
        if let voiceCaptureStorage { return voiceCaptureStorage }
        let model = makeVoiceCapture(self)
        voiceCaptureStorage = model
        return model
    }
    var sync: MobileSyncController {
        if let syncController { return syncController }
        let controller = MobileSyncController(library: self)
        syncController = controller
        return controller
    }

    @ObservationIgnored let shareContainer: URL?
    @ObservationIgnored var shareInbox: CaptureInbox?
    @ObservationIgnored var drainingShareInbox = false
    @ObservationIgnored var sharePublicationScrubPending = false
    @ObservationIgnored var widgetPublisher: MobileCardPublicationPublisher?
    @ObservationIgnored var widgetPublicationTask: Task<Void, Never>?
    @ObservationIgnored var widgetPublicationDebounce: Duration = .seconds(2)
    @ObservationIgnored var reloadWidgetTimelines: () -> Void = { MobileShareContainer.reloadWidgets() }
    @ObservationIgnored var waitForSpotlightPreparation: (() async -> Void)?
    @ObservationIgnored var spotlightPreparationBusy: (() -> Bool)?
    @ObservationIgnored var widgetConfigurations: (String) async throws -> MobileWidgetSelections = { id in
        try await MobileWidgetConfigurations.current(libraryID: id)
    }
    var sharingError: String?
    var sharingEnabled: Bool { shareInbox != nil }

    /// `seedsGettingStarted` is true only for the app's own launches (REL-R79); a library opened by a test or
    /// tool is never given the notes.
    init(paths: AppPaths = .production, shareContainer: URL? = nil, seedsGettingStarted: Bool = false) throws {
        self.shareContainer = shareContainer
        // A previous library's picker must disappear before opening any scene or recovery UI.
        let scrubError = MobileShareContainer.scrubRecentNotes(in: shareContainer)
        sharingError = scrubError
        sharePublicationScrubPending = scrubError != nil
        self.paths = paths
        let isNewLibrary = seedsGettingStarted && MobileGettingStarted.createsNewLibrary(at: paths)
        try paths.createDirectories()
        let previews = paths.root.appendingPathComponent("UnlockedPreviews")
        if FileManager.default.fileExists(atPath: previews.path) { try FileManager.default.removeItem(at: previews) }
        database = try AppDatabase(path: paths.database)
        store = NoteStore(db: database, notifier: nil, paths: paths)
        // REL-R71/R79: a failure never stops the launch; the person starts with an empty library.
        _ = try? GettingStartedNotes.seedNewLibrary(in: store, isNewLibrary: isNewLibrary)
        // STARTER-R18: untouched first-release starters get the new texts once; a failure leaves the marker unset for the next launch.
        if seedsGettingStarted { _ = try? GettingStartedNotes.upgradeFirstShipped(in: store, paths: paths) }
        ocr = OCRQueue(store: AttachmentTextStore(database: database), files: AttachmentStore(paths: paths, database: database), extractor: AttachmentTextExtractor())
        _ = try AttachmentFiles(paths: paths, database: database).recover()
        try SyncMaterializer.recoverImportCleanup(database: database, paths: paths)
        try LibraryBackup(database: database, paths: paths).recoverAbandonedCopies()
        try NotePrivacy(store: store).finishPendingCleanup()
        hasNotePassword = try NotePrivacy(store: store).hasPassword
        biometryEnabled = try Settings(db: database).value(.mobileBiometry)
        appLockEnabled = try Settings(db: database).value(.mobileAppLock)
        appLocked = appLockEnabled
        try removePrivatePreviews()
        // Missing-source journals must be recovered, never moved aside by the deletion cleanup.
        do { try recoverMissingJournals(access: nil) }
        catch { missingJournalRecoveryUnresolved = true; recoveryMessage = recoveryFailureMessage(error) }
        // Recover all journals before querying, including notes the user hasn't reopened.
        // A temporarily unreadable journal directory must not make the app fail to launch.
        var blockedVariantDuringLaunch = false
        for file in (try? FileManager.default.contentsOfDirectory(at: paths.journal, includingPropertiesForKeys: nil)) ?? []
            where file.pathExtension == "jsonl" {
            let id = file.deletingPathExtension().lastPathComponent
            guard try store.note(id: id) != nil else { continue }
            if try store.note(id: id)?.isLocked == true { continue } // Recover only after password authentication.
            do {
                let recovered = try session(for: id)
                try recovered.flush()
            } catch let failure as JournalVariantRecovery.Failure {
                switch failure {
                case .requiresKey, .partialReplayBlocked, .unavailable:
                    blockedVariantDuringLaunch = true
                    continue
                default: throw failure
                }
            }
        }
        let retained = (try? FileManager.default.contentsOfDirectory(atPath: paths.journal.path)) ?? []
        if let missingJournalBlock {
            recoveryMessage = missingJournalBlock.localizedDescription
        } else if missingJournalRecoveryUnresolved {
            // Preserve the specific failure message from the recovery attempt.
        } else if !recoveredJournalNotices.isEmpty || !recoveredVariantNotices.isEmpty {
            recoveryMessage = MobileMissingJournalRecoveryError.leftoversNeedReview.localizedDescription
        } else if retained.contains(where: { $0.contains(".unreplayed") }) {
            recoveryMessage = "Some edits need manual recovery. Their journal files have been kept safely."
        }
        if blockedVariantDuringLaunch && !missingJournalRecoveryUnresolved && missingJournalBlock == nil {
            recoveryMessage = "Some recovery files need your attention. Unlock your notes or resolve the remaining files before opening the affected note."
        }
        preferences = try settings.value(.mobilePreferences)
        let restoration = try settings.value(.mobileRestoration)
        workspace = restoration.workspace.map(Workspace.init(path:))
        scope = restoration.scopeValue
        if let id = restoration.noteID, let note = try store.note(id: id), note.deletedAt == nil { selectedID = id }
        if let shareContainer, SharedContainerFiles.validate(container: shareContainer) {
            do { widgetPublisher = try MobileCardPublicationPublisher(library: self, container: shareContainer) }
            catch { throw MobileWidgetCleanupError() }
        }
        openShareContainer()
        observe()
    }

    private func recoverMissingJournals(access: LockedNoteAccess?) throws {
        // The coordinator performs a synchronous pass on MainActor. Hold admission from
        // the registry snapshot through any proven automatic cleanup; never clear a fence
        // already held by the caller.
        let ownsAdmission = !sceneOperationPending
        if ownsAdmission { sceneOperationPending = true }
        defer { if ownsAdmission { sceneOperationPending = false } }
        let liveIDs = NoteSession.liveSessionIDs(journalDirectory: paths.journal)
        // An evicted but retained session can still own uncommitted text; conservatively
        // treat every live missing-source holder as dirty until the Core registry can prove otherwise.
        let report = try JournalRecoveryCoordinator.recover(store: store, access: access,
            liveSessionIDs: liveIDs, dirtyLiveSessionIDs: liveIDs.subtracting(resetDeferredPlainOrphans), existingReplayFailureIDs: existingReplayFailureIDs,
            allowSealedMoveAside: allowSealedJournalMoveAside)
        recoveredJournalNotices = report.singles.map { item in
            .init(id: Self.recoveryNoticeID([item.sourceID, item.suffix, item.note.id]), sourceID: item.sourceID,
                  suffix: item.suffix, noteID: item.note.id, noteRevision: item.note.revision,
                  noteLocked: item.note.isLocked, retirement: item.retirement)
        }
        recoveredVariantNotices = report.variants.map { item in
            .init(id: Self.recoveryNoticeID([item.sourceID, "variants"] + item.notes.map(\.id).sorted()),
                  sourceID: item.sourceID, noteIDs: item.notes.map(\.id), sourceMustExist: item.sourceMustExist,
                  retirement: item.retirement)
        }
        switch report.keyState {
        case .unlockRequired: missingJournalBlock = .unlockRequired
        case .waitingForSyncKey: missingJournalBlock = .waitingForSyncKey
        case nil: missingJournalBlock = nil
        }
        retirementCleanupPending = report.cleanupPending
        quarantinableJournalFiles = report.quarantineFiles
        keyUnavailableJournalFiles = Set(report.keyUnavailableFiles)
        quarantinableMarkers = report.markerMoves
        let hasPendingQuarantine = !(try pendingQuarantineDirectories()).isEmpty
        missingJournalRecoveryUnresolved = report.hasUncommittedRecovery || hasPendingQuarantine
        if let block = missingJournalBlock { recoveryMessage = block.localizedDescription }
        else if missingJournalRecoveryUnresolved { recoveryMessage = MobileMissingJournalRecoveryError.recoveryFailed.localizedDescription }
        else if !recoveredJournalNotices.isEmpty || !recoveredVariantNotices.isEmpty {
            recoveryMessage = MobileMissingJournalRecoveryError.leftoversNeedReview.localizedDescription
        } else if report.variantMarkerNeedsAttention {
            recoveryMessage = "Some recovery files need separate handling. If the affected note is open, close it first; other notes remain available."
        }
    }

    private static func recoveryNoticeID(_ components: [String]) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(components.joined(separator: "\0").utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private func pendingQuarantineDirectories() throws -> [URL] {
        let root = paths.root.appendingPathComponent("Recovery/Quarantine", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { directory in
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(".confirmation.json").path) else { return false }
            let completed = directory.appendingPathComponent(".completed")
            guard FileManager.default.fileExists(atPath: completed.path) else { return true }
            guard try Data(contentsOf: completed) == Data("complete-v1".utf8) else { throw BackupError.pendingFiles }
            return false
        }
    }

    struct JournalQuarantinePlan {
        let id: UUID
        let libraryGeneration: Int
        let sceneGeneration: Int
        let fileNames: [String]
        let includesUnavailableKeyFiles: Bool
        let selection: JournalQuarantine.Selection
    }
    func prepareJournalQuarantine() throws -> JournalQuarantinePlan {
        guard !isClosed, !isClosing, !libraryOperationBusy, !sceneOperationPending else { throw BackupError.pendingFiles }
        try recoverMissingJournals(access: privateAccess)
        let names = quarantineOffer
        guard let first = names.first else { throw BackupError.pendingFiles }
        let selection = first.hasPrefix(".") ? try JournalQuarantine.inspectMarker(store: store, markerName: first)
            : try JournalQuarantine.inspect(libraryRoot: paths.root, fileNames: names)
        return .init(id: UUID(), libraryGeneration: libraryGeneration, sceneGeneration: sceneRoutingGeneration,
                     fileNames: names, includesUnavailableKeyFiles: !keyUnavailableJournalFiles.isDisjoint(with: names), selection: selection)
    }
    func moveJournalFilesAfterConfirmation(_ plan: JournalQuarantinePlan) async throws {
        guard plan.libraryGeneration == libraryGeneration, plan.sceneGeneration == sceneRoutingGeneration,
              plan.fileNames == quarantineOffer else { throw BackupError.pendingFiles }
        try await beginLibraryOperationAfterDraining(allowConfirmedJournalReset: true)
        defer { endLibraryOperation() }
        try recoverMissingJournals(access: privateAccess)
        guard plan.libraryGeneration == libraryGeneration, plan.sceneGeneration == sceneRoutingGeneration,
              plan.fileNames == quarantineOffer else { throw BackupError.pendingFiles }
        let directory = try JournalQuarantine.moveAfterConfirmation(plan.selection, store: store)
        existingReplayFailureIDs = existingReplayFailureIDs.filter { id in
            !plan.fileNames.contains { $0.hasPrefix(id + ".jsonl") || $0.hasPrefix(id + ".base") }
        }
        try recoverMissingJournals(access: privateAccess)
        recoveryMessage = "Recovery files were moved unchanged to Recovery/Quarantine/\(directory.lastPathComponent). Back up these files separately; portable backups do not include them."
    }
    func resumeConfirmedJournalQuarantines() async throws {
        let directories = try pendingQuarantineDirectories()
        guard !directories.isEmpty else { return }
        try await beginLibraryOperationAfterDraining(allowConfirmedJournalReset: true)
        defer { endLibraryOperation() }
        for directory in directories {
            try JournalQuarantine.resumeConfirmed(JournalQuarantine.confirmed(libraryRoot: paths.root, directory: directory), store: store)
        }
        try recoverMissingJournals(access: privateAccess)
        recoveryMessage = "A previously confirmed recovery file move finished. Find the files in Recovery/Quarantine and back them up separately; portable backups do not include them."
    }

    private func recoveryFailureMessage(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError {
            return "Recovery could not save edits because storage is full. Free space and try again; recovery files were kept."
        }
        return "Recovery could not read or save some edits. Check storage and try again; recovery files were kept."
    }

    func retryMissingJournalRecovery() {
        guard !isClosed, !isClosing, !libraryOperationBusy, !sceneOperationPending else { return }
        do {
            try refreshMissingJournalRecovery()
            // S4: with the vault open, Try Again also retries a failed replay of a locked note.
            if privateAccess != nil, !existingReplayFailureIDs.isEmpty { try recoverLockedExistingJournals() }
        }
        catch { missingJournalRecoveryUnresolved = true; recoveryMessage = recoveryFailureMessage(error) }
    }

    func requireSyncRecoveryReady() throws {
        do { try recoverMissingJournals(access: privateAccess) }
        catch { missingJournalRecoveryUnresolved = true; recoveryMessage = recoveryFailureMessage(error); throw MobileMissingJournalRecoveryError.recoveryFailed }
        if let missingJournalBlock { throw missingJournalBlock }
        if missingJournalRecoveryUnresolved { throw MobileMissingJournalRecoveryError.recoveryFailed }
    }

    func refreshMissingJournalRecovery() throws {
        hasNotePassword = try NotePrivacy(store: store).hasPassword
        try recoverMissingJournals(access: privateAccess)
    }

    func offerSealedJournalMoveAside() throws {
        allowSealedJournalMoveAside = true
        try refreshMissingJournalRecovery()
    }

    private func requireMissingJournalRecoveryCleared() throws {
        try recoverMissingJournals(access: privateAccess)
        if let missingJournalBlock { throw missingJournalBlock }
        if missingJournalRecoveryUnresolved { throw MobileMissingJournalRecoveryError.recoveryFailed }
        if retirementCleanupPending { throw MobileMissingJournalRecoveryError.leftoversNeedReview }
        if !recoveredJournalNotices.isEmpty || !recoveredVariantNotices.isEmpty { throw MobileMissingJournalRecoveryError.leftoversNeedReview }
    }

    func removeRecoveredVariantAfterConfirmation(id: UUID) async throws {
        guard let notice = recoveredVariantNotices.first(where: { $0.id == id }),
              sessions[notice.sourceID] == nil,
              (try store.note(id: notice.sourceID) != nil) == notice.sourceMustExist else { throw BackupError.pendingFiles }
        let generation = libraryGeneration, sceneGeneration = sceneRoutingGeneration
        try await beginLibraryOperationAfterDraining(allowConfirmedJournalReset: true)
        defer { endLibraryOperation() }
        guard generation == libraryGeneration, sceneGeneration == sceneRoutingGeneration,
              sessions[notice.sourceID] == nil,
              (try store.note(id: notice.sourceID) != nil) == notice.sourceMustExist else { throw BackupError.pendingFiles }
        try JournalVariantRecovery.removeAfterConfirmation(notice.retirement, store: store, access: privateAccess)
        try recoverMissingJournals(access: privateAccess)
    }

    /// Caller must explicitly confirm. The opaque token is bound to the saved copy and both files.
    func removeRecoveredJournalAfterConfirmation(id: UUID) throws {
        guard !isClosed, !isClosing, !libraryOperationBusy, !sceneOperationPending,
              let notice = recoveredJournalNotices.first(where: { $0.id == id }),
              sessions[notice.sourceID] == nil, try store.note(id: notice.sourceID) == nil else { throw BackupError.pendingFiles }
        // N4: a protected leftover needs the key; say so instead of "files changed".
        if notice.noteLocked, (try? privateAccess?.journalKey()) == nil { throw MobileMissingJournalRecoveryError.unlockRequired }
        if try store.note(id: notice.noteID) == nil {
            let result = try MissingJournalRecovery.recover(noteId: notice.sourceID, directory: paths.journal,
                suffix: notice.suffix, store: store, access: privateAccess, avoidingRecoveryID: notice.noteID)
            recoveredJournalNotices.removeAll { $0.id == id }
            recoveredJournalNotices.append(.init(id: UUID(), sourceID: notice.sourceID, suffix: notice.suffix,
                noteID: result.note.id, noteRevision: result.note.revision, noteLocked: result.note.isLocked, retirement: result.retirement))
            recoveryMessage = "The recovered note was deleted. A new recovery note was saved; review it before removing the leftover files."
            throw BackupError.pendingFiles
        }
        do {
            try MissingJournalRecovery.removeLeftover(notice.retirement, access: privateAccess)
            try recoverMissingJournals(access: privateAccess)
            if recoveredJournalNotices.isEmpty && !missingJournalRecoveryUnresolved && missingJournalBlock == nil {
                recoveryMessage = "Recovered edits are saved in Notes."
            }
        } catch MissingJournalRecovery.RetirementError.changed {
            try recoverMissingJournals(access: privateAccess)
            throw MissingJournalRecovery.RetirementError.changed
        }
    }

    func session(for id: String) throws -> NoteSession {
        guard !attachmentWriteInFlight, !sceneOperationPending, !sceneDrainInFlight, !libraryOperationBusy, !isClosing, !isClosed else { throw MobileEditorDrainError.busy }
        if let existing = sessions[id] { return existing }
        store.retention.retain(id)
        let session: NoteSession
        do {
            if try store.note(id: id)?.isLocked == true {
                guard let privateAccess else { throw StoreError.noteLocked(id: id) }
                session = try NoteSession(noteId: id, store: privateAccess, journalDirectory: paths.journal,
                                          journalKey: privateAccess.journalKey())
            } else {
                session = try NoteSession(noteId: id, store: store, journalDirectory: paths.journal)
            }
        } catch {
            store.retention.release(id)
            throw error
        }
        _ = session.addConflictCopyListener { [weak self] _ in
            self?.recoveryMessage = "Two versions of a note were recovered. Both have been kept in your library."
        }
        if session.recoveryConflictCopyId != nil {
            recoveryMessage = "Two versions of a note were recovered. Both have been kept in your library."
        }
        sessions[id] = session
        _ = session.addActivityListener { [weak self] in self?.linkMonitor.sessionActivity(id, $0) }
        linkMonitor.watch(Set(sessions.keys))
        return session
    }

    private func removeSession(_ id: String) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        session.removeAllListeners()
        store.retention.release(id)
        linkMonitorStorage?.watch(Set(sessions.keys))
    }

    /// The links to `id` follow its new title (`NoteStore.rewriteWikiLinks`, same rules as the Mac);
    /// false waits and tries again (an editor still typing, or the library is busy, IOS-LINKS-R3).
    private func rewriteLinks(to id: String, from previous: LinkTargetState, busy: Set<String>) -> Bool {
        guard !isClosed, !libraryOperationBusy,
              forcingLinkRewrites || (!isClosing && !sceneOperationPending && !sceneDrainInFlight && !attachmentWriteInFlight) else { return false }
        let unsaved = Set(sessions.values.filter { !TextNormalization.identical($0.text, $0.committedText) }.map(\.noteId))
        do {
            let result = try store.rewriteWikiLinks(to: id, from: previous, skipping: unsaved, deferringIfTouching: busy)
            guard !result.deferred else { return false }
            if result.didChange { try refreshSessions() }
        } catch {
            mobileLinkLogger.error("updating links to a renamed note failed: \(error)")
        }
        return true
    }

    /// Close runs the pending rewrites now, as the Mac does on window close and quit; a closing
    /// library's own fences must not hold them back (IOS-LINKS-R4).
    @ObservationIgnored private var forcingLinkRewrites = false
    private func runPendingLinkRewrites(forced: Bool) {
        forcingLinkRewrites = forced
        defer { forcingLinkRewrites = false }
        linkMonitorStorage?.runPendingNow()
    }

    /// A restore or another library operation replaced what the follower last saw: start over from
    /// the notes as they are now (IOS-LINKS-R5).
    private func resetLinkMonitor() {
        linkMonitorStorage = nil
        if !sessions.isEmpty { linkMonitor.watch(Set(sessions.keys)) }
    }

    private func removeAllSessions(excluding retained: Set<String> = []) {
        for id in Array(sessions.keys) where !retained.contains(id) { removeSession(id) }
    }

    func hasSyncInterest(in noteID: String) -> Bool {
        hasCachedSession(for: noteID) || editors.allObjects.contains { $0.session?.noteId == noteID }
            || displayedEditorNoteID?() == noteID
    }
    func hasCachedSession(for id: String) -> Bool { sessions[id] != nil }
    func cachedSession(for id: String) -> NoteSession? { sessions[id] }

    func flush(excluding excluded: Set<String> = []) throws {
        guard !libraryOperationBusy else { return } // All ordinary sessions were flushed before the operation.
        for session in sessions.values where !excluded.contains(session.noteId) {
            let current = try store.note(id: session.noteId)
            if current == nil || current?.deletedAt != nil || current?.isLocked != session.wasOriginallyLocked {
                if reportedOrphanSessions.insert(session.noteId).inserted {
                    recoveryMessage = editors.allObjects.contains(where: { $0.session === session })
                        ? "A note was removed or its protection changed. Keep its editor open while its edits are recovered."
                        : "A note was removed or its protection changed. Its pending edits need recovery."
                }
                continue
            }
            try session.flush()
        }
        let sceneRestoration = sceneStates.values.filter { $0.navigation != nil }.max { $0.activation < $1.activation }?.navigation?.restoration
        try settings.set(.mobileRestoration, to: sceneRestoration ?? MobileRestoration(scope: scope, workspace: workspace?.path, noteID: selectedID))
    }

    func requireNoOrphanSessionsBeforeEviction(excludingConfirmedResetIDs: Set<String> = []) throws {
        for session in sessions.values {
            let note = try store.note(id: session.noteId)
            guard note == nil || note?.deletedAt != nil || note?.isLocked != session.wasOriginallyLocked else { continue }
            // A reset-specific, explicitly confirmed token owns these missing-source
            // sessions. Keep them in the cache until its full registry fence matches.
            if note == nil && excludingConfirmedResetIDs.contains(session.noteId) { continue }
            let clean = Data(session.text.utf8) == Data(session.committedText.utf8)
            let hasLiveEditor = editors.allObjects.contains(where: { $0.session === session })
            if clean && (!hasLiveEditor || activeSceneFreeze != nil) {
                try activeSceneFreeze?.validate()
                continue
            }
            // A live page may hold text beyond the session. A synchronous flush cannot prove
            // that page saved it; leave both page and session intact for the editor recovery flow.
            guard !hasLiveEditor else {
                recoveryMessage = "Unsaved text from a removed or protected note must be recovered before this operation."
                throw BackupError.pendingFiles
            }
            // A clean cached session holds no edits beyond the already-committed row. Do not
            // resurrect content the user deleted on another device.
            do {
                let recovered: BrowserRecoveryResult
                if let access = privateAccess, note == nil || note?.isLocked == true || session.wasOriginallyLocked {
                    if session.wasOriginallyLocked {
                        recovered = try access.preserveProtectedBrowserRecovery(noteId: session.noteId, text: session.text,
                                                                               baseRevision: session.revision, now: .now)
                    } else {
                        recovered = try access.preserveBrowserRecovery(noteId: session.noteId, text: session.text,
                                                                      baseRevision: session.revision, now: .now)
                    }
                } else {
                    recovered = try session.preserveBrowserRecoveryResult(text: session.text, baseRevision: session.revision)
                }
                if recovered.created { recoveryMessage = "Unsaved text from a removed note was saved as a recovery copy." }
            } catch {
                if (try? store.canRecoverMissingJournalPlain()) == false,
                   privateAccess == nil || (try? privateAccess?.journalKey()) == nil ||
                    (error as? NotePrivacyError) == .accessRevoked {
                    if try NotePrivacy(store: store).hasPassword {
                        recoveryMessage = MobileMissingJournalRecoveryError.unlockRequired.localizedDescription
                        throw MobileMissingJournalRecoveryError.unlockRequired
                    }
                    recoveryMessage = MobileMissingJournalRecoveryError.waitingForSyncKey.localizedDescription
                    throw MobileMissingJournalRecoveryError.waitingForSyncKey
                }
                recoveryMessage = "Unsaved text from a removed note must be recovered before this operation."
                throw BackupError.pendingFiles
            }
        }
    }

    /// Keep the store alive and exclude restore/switch operations for the entire import batch.
    func importNotes(_ urls: [URL], options: FileImportOptions = FileImportOptions(), progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> FileImportReport {
        guard !isClosed, !isClosing else { throw CancellationError() }
        try await beginLibraryOperationAfterDraining()
        defer { endLibraryOperation() }
        let importer = FileImporter(store: store, paths: paths)
        return try await Task.detached(priority: .userInitiated) {
            try importer.importItems(urls, options: options, progress: progress)
        }.value
    }

    func makeBackup() async throws -> URL {
        try await beginLibraryOperationAfterDraining()
        defer { endLibraryOperation() }
        let backup = LibraryBackup(database: database, paths: paths)
        return try await Task.detached(priority: .userInitiated) { try backup.createRolling() }.value
    }

    func synchronize(using engine: SyncEngine, notePassword: String? = nil, remoteNotePassword: String? = nil, exclusive: Bool = true) async throws -> SyncRunSummary {
        guard !isClosed, !libraryOperationBusy else { throw CancellationError() }
        if !exclusive, notePassword == nil {
            try requireSyncRecoveryReady()
            try flush()
            return try await engine.synchronize()
        }
        if let notePassword {
            do { try await unlockNotes(password: notePassword) }
            catch CryptoError.wrongPassword {
                guard let remoteNotePassword, remoteNotePassword != notePassword else { throw CryptoError.wrongPassword }
                // The preceding first-sync download can have adopted this password before
                // capture is enabled and the second upload cycle begins.
                try await unlockNotes(password: remoteNotePassword)
            }
        }
        let authorized = notePassword == nil ? nil : privateAccess
        let privacy = NotePrivacy(store: store)
        let previousEnvelope = try privacy.envelope()
        try await beginLibraryOperationAfterDraining(allowCommittedRecoveryForSync: true)
        syncNoteAccess = authorized
        syncExclusive = true
        defer {
            syncExclusive = false
            authorized?.revoke(); syncNoteAccess = nil
            hasNotePassword = (try? privacy.hasPassword) ?? hasNotePassword
            if (try? privacy.envelope()) != previousEnvelope { try? disableBiometrics() }
            endLibraryOperation()
        }
        await ocr.cancel()
        await ocr.waitUntilIdle()
        // A remote password-envelope or lock transition invalidates the old authorized view.
        if authorized == nil { privateAccess?.revoke() }
        privateAccess = nil
        return try await engine.synchronize(noteAccess: authorized, remoteNotePassword: remoteNotePassword ?? notePassword)
    }

    /// No suspension between flushing acknowledged edits and refreshing their sessions.
    /// Network and attachment downloads have already completed at this boundary.
    func commitSyncedChange(_ change: @Sendable () throws -> SyncApplyResult) throws -> SyncApplyResult {
        guard !isClosed else { throw CancellationError() }
        guard !attachmentWriteInFlight, !hasAttachmentReads else { throw CancellationError() }
        // Voice retains its journaled session until recording teardown completes.
        guard voiceCaptureStorage?.isBusy != true else { throw CancellationError() }
        if syncExclusive { return try change() }
        guard !libraryOperationBusy, !sceneOperationPending, !isClosing else { throw CancellationError() }
        try requireNoOrphanSessionsBeforeEviction()
        try flush()
        let before = try Dictionary(uniqueKeysWithValues: sessions.keys.compactMap { id in
            try store.note(id: id).map { (id, $0) }
        })
        let privacy = NotePrivacy(store: store), envelope = try privacy.envelope()
        clearSharePublicationForSync()
        defer { publishRecentNotes() }
        let outcome = Result { try change() }
        let nextEnvelope = try privacy.envelope()
        var needsNewSession = nextEnvelope != envelope, metadataChanged = false
        for (id, previous) in before {
            guard let next = try store.note(id: id), next.deletedAt == nil else { needsNewSession = true; continue }
            if next.isLocked != previous.isLocked { needsNewSession = true }
            if next.isReadOnly != previous.isReadOnly || next.location != previous.location { metadataChanged = true }
        }
        if needsNewSession {
            try prepareAllSceneEditors()
            removeAllSessions()
            privateAccess?.revoke(); privateAccess = nil
            try removePrivatePreviews()
            if nextEnvelope != envelope { try disableBiometrics() }
            hasNotePassword = try privacy.hasPassword
            libraryGeneration += 1
        } else {
            try refreshSessions()
            if metadataChanged { libraryGeneration += 1 }
        }
        return try outcome.get()
    }

    func restoreBackup(_ url: URL, mode: BackupRestoreMode, backupPassword: String?, currentPassword: String?) async throws -> BackupRestoreResult {
        try await beginLibraryOperationAfterDraining()
        defer { endLibraryOperation() }
        return try await withSuspendedSketchWrites {
            if mode == .replaceAll, !(try await sketchDraftStore.discover()).isEmpty {
                throw MobileSketchDraftError.draftsPreventReplacement
            }
            return try await restoreBackupWhileSuspended(url, mode: mode, backupPassword: backupPassword, currentPassword: currentPassword)
        }
    }

    private func restoreBackupWhileSuspended(_ url: URL, mode: BackupRestoreMode, backupPassword: String?, currentPassword: String?) async throws -> BackupRestoreResult {
        try requireNoOrphanSessionsBeforeEviction()
        await ocr.cancel()
        await ocr.waitUntilIdle()
        removeAllSessions()
        privateAccess?.revoke(); privateAccess = nil
        // This is the legacy projection only; never route its stale filters into
        // the frontmost scene while all windows are restoring independently.
        let wasDispatching = dispatchingLegacyNavigation
        dispatchingLegacyNavigation = true
        // Consume the old delivery now, never lazily when a window next activates.
        legacyDeliveryPending = false
        pendingCallbackNavigation = nil
        pendingCaret.removeAll()
        selectedID = nil
        dispatchingLegacyNavigation = wasDispatching
        let backup = LibraryBackup(database: database, paths: paths)
        defer {
            hasNotePassword = (try? NotePrivacy(store: store).hasPassword) ?? hasNotePassword
            preferences = (try? settings.value(.mobilePreferences)) ?? preferences
            libraryGeneration += 1
        }
        let result = try await Task.detached(priority: .userInitiated) {
            try backup.restore(url, mode: mode, backupPassword: backupPassword, currentPassword: currentPassword)
        }.value
        try disableBiometrics()
        let navigations = sceneStates.values.compactMap(\.navigation)
        let referenced = Set(navigations.flatMap { navigation in
            Array(navigation.pendingCaret.keys) + [navigation.selectedID, navigation.pendingCallbackNavigation?.noteID].compactMap { $0 }
        })
        var missing = Set<String>()
        for id in referenced {
            if let note = try store.note(id: id), note.deletedAt == nil { continue }
            missing.insert(id)
        }
        clearNavigationTargets(missing)
        dispatchingLegacyNavigation = true
        workspace = nil; scope = .notes; query = ""; history = NoteHistory(); pendingCaret = [:]; tagUndo = nil
        dispatchingLegacyNavigation = wasDispatching
        observe()
        return result
    }

    func withSuspendedSketchWrites<T>(_ action: () async throws -> T) async throws -> T {
        let draftStore = sketchDraftStore
        let token = try await draftStore.suspendWrites()
        do {
            let result = try await action()
            await draftStore.resumeWrites(token)
            return result
        } catch {
            await draftStore.resumeWrites(token)
            throw error
        }
    }

    func withDrainedEditor<T>(deadline: Date? = nil, allowUnavailable: Bool = true, confirmedResetInvalidatedIDs: Set<String> = [],
                              _ action: () throws -> T) async throws -> T {
        if hasRegisteredSceneWindows {
            guard !sceneDrainInFlight, !attachmentWriteInFlight else { throw MobileEditorDrainError.busy }
            let registered = Set(sceneStates.values.compactMap { $0.editor.map(ObjectIdentifier.init) })
            guard editors.allObjects.filter({ $0.session != nil }).allSatisfy({ registered.contains(ObjectIdentifier($0)) }) else { throw MobileEditorDrainError.busy }
            sceneDrainInFlight = true
            defer { sceneDrainInFlight = false }
            let lease = try await sceneRegistry.freezeAll(deadline: deadline, confirmedResetInvalidatedIDs: confirmedResetInvalidatedIDs)
            activeSceneFreeze = lease
            defer { activeSceneFreeze = nil; lease.release() }
            try lease.validate(); try Task.checkCancellation()
            return try action()
        }
        let release: (() -> Void)?
        do { release = try await drainEditorForLibraryOperation?() }
        catch MobileEditorDrainError.unavailable {
            guard allowUnavailable else { throw MobileEditorDrainError.unavailable }
            return try action()
        }
        defer { release?() }
        return try action()
    }

    func withDrainedShareEditors<T>(_ action: () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let active = editors.allObjects.filter { $0.session != nil }
        guard !active.isEmpty else {
            return try await withDrainedEditor {
                try Task.checkCancellation()
                guard !editors.allObjects.contains(where: { $0.session != nil }) else { throw MobileEditorDrainError.busy }
                return try action()
            }
        }
        // An unready session may still have unacknowledged bridge edits; defer rather than skip it.
        guard active.allSatisfy(\.ready) else { throw MobileEditorDrainError.unavailable }
        let pages = active.map(\.webView)
        let loads = active.map(\.documentLoadGeneration)
        var frozen: [(MobileEditor, FrozenForClose)] = []
        defer { for (editor, reply) in frozen.reversed() { editor.endCaptureClose(reply) } }
        for editor in active {
            try Task.checkCancellation()
            guard let id = editor.session?.noteId else { throw MobileEditorDrainError.unavailable }
            frozen.append((editor, try await editor.prepareCaptureClose(id)))
            try Task.checkCancellation()
        }
        // A window may attach or replace its editor while another window is draining.
        let current = editors.allObjects.filter { $0.session != nil }
        guard current.count == active.count,
              current.allSatisfy({ editor in active.contains { $0 === editor } }),
              frozen.allSatisfy({ $0.0.session?.noteId == $0.1.noteId }),
              zip(active, pages).allSatisfy({ $0.0.webView === $0.1 }),
              zip(active, loads).allSatisfy({ $0.0.documentLoadGeneration == $0.1 }) else {
            throw MobileEditorDrainError.busy
        }
        try Task.checkCancellation()
        return try action()
    }

    /// Keep every editor frozen while an off-main attachment writer validates and commits.
    func withDrainedShareEditorsAsync<T: Sendable>(_ action: @MainActor () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard !attachmentWriteInFlight, !libraryOperationBusy, !isClosing, !isClosed else { throw MobileEditorDrainError.busy }
        attachmentWriteInFlight = true
        defer { attachmentWriteInFlight = false }
        let active = editors.allObjects.filter { $0.session != nil }
        guard !active.isEmpty, active.allSatisfy(\.ready) else { throw MobileEditorDrainError.unavailable }
        let pages = active.map(\.webView), loads = active.map(\.documentLoadGeneration)
        var frozen: [(MobileEditor, FrozenForClose)] = []
        defer { for (editor, reply) in frozen.reversed() { editor.endCaptureClose(reply) } }
        for editor in active {
            try Task.checkCancellation()
            guard let id = editor.session?.noteId else { throw MobileEditorDrainError.unavailable }
            frozen.append((editor, try await editor.prepareCaptureClose(id)))
        }
        let current = editors.allObjects.filter { $0.session != nil }
        guard current.count == active.count,
              current.allSatisfy({ editor in active.contains { $0 === editor } }),
              frozen.allSatisfy({ $0.0.session?.noteId == $0.1.noteId }),
              zip(active, pages).allSatisfy({ $0.0.webView === $0.1 }),
              zip(active, loads).allSatisfy({ $0.0.documentLoadGeneration == $0.1 }) else {
            throw MobileEditorDrainError.busy
        }
        try Task.checkCancellation()
        return try await action()
    }

    private var hasAttachmentReads: Bool { editors.allObjects.contains(where: \.hasAttachmentReads) }

    private func cancelAndWaitForAttachmentReads() async {
        while hasAttachmentReads {
            let current = editors.allObjects
            current.forEach { $0.cancelAttachmentReads() }
            for editor in current { await editor.waitForAttachmentReads() }
        }
    }

    private func beginLibraryOperationAfterDraining(allowConfirmedJournalReset: Bool = false,
                                                    allowCommittedRecoveryForSync: Bool = false,
                                                    confirmedResetIDs: Set<String> = []) async throws {
        guard !sceneOperationPending, !libraryOperationBusy, !isClosing, !isClosed else { throw BackupError.pendingFiles }
        sceneOperationPending = true
        do {
        try await stopAndDrainSceneObservations()
        await cancelAndWaitForAttachmentReads()
        await waitForAttachmentSweep()
        await widgetPublisher?.waitForBackgroundPreparations()
        await waitForSpotlightPreparation?()
        try Task.checkCancellation()
        try await withDrainedEditor(confirmedResetInvalidatedIDs: confirmedResetIDs) { try beginLibraryOperation(allowConfirmedJournalReset: allowConfirmedJournalReset,
                                                               allowCommittedRecoveryForSync: allowCommittedRecoveryForSync,
                                                               confirmedResetIDs: confirmedResetIDs) }
        } catch {
            sceneOperationPending = false
            restartSceneObservations()
            throw error
        }
    }

    private func beginLibraryOperation(allowConfirmedJournalReset: Bool = false,
                                       allowCommittedRecoveryForSync: Bool = false,
                                       confirmedResetIDs: Set<String> = []) throws {
        guard !libraryOperationBusy, !isClosing, !attachmentWriteInFlight, !hasAttachmentReads, attachmentSweepTask == nil, voiceCaptureStorage?.isBusy != true,
              widgetPublisher?.hasBackgroundPreparations != true, spotlightPreparationBusy?() != true else { throw BackupError.pendingFiles }
        if allowCommittedRecoveryForSync { try requireSyncRecoveryReady() }
        else if !allowConfirmedJournalReset { try requireMissingJournalRecoveryCleared() }
        for id in confirmedResetIDs {
            guard try store.note(id: id) == nil else { throw BackupError.pendingFiles }
        }
        try requireNoOrphanSessionsBeforeEviction(excludingConfirmedResetIDs: confirmedResetIDs)
        try prepareAllSceneEditors()
        try flush(excluding: confirmedResetIDs)
        try clearSharePublication()
        removeAllSessions(excluding: confirmedResetIDs)
        resetLinkMonitor()
        libraryOperationBusy = true
    }

    /// The only exception to the missing-journal gate is a fenced, key-bundle-only intake.
    /// It does not count as a backup and may not perform the ordinary sync cycle.
    func recoverPendingSyncKey<Found>(scan: () async throws -> Found?, install: (Found) async throws -> Bool) async throws -> Bool {
        guard awaitsMissingJournalSyncKey else { throw CancellationError() }
        // S7: the download runs unfenced. The install touches no session, so it skips the orphan
        // gate and eviction and only excludes other library operations; it re-checks in one write.
        guard let found = try await scan() else { return false }
        guard awaitsMissingJournalSyncKey, !sceneOperationPending, !libraryOperationBusy, !isClosing, !isClosed else { throw BackupError.pendingFiles }
        sceneOperationPending = true
        defer { sceneOperationPending = false }
        return try await install(found)
    }

    private func endLibraryOperation() {
        libraryOperationBusy = false
        sceneOperationPending = false
        resetLinkMonitor()
        publishRecentNotes()
        libraryGeneration += 1
        restartSceneObservations()
        if ocrActive { Task { await ocr.startBacklog() } }
    }

    @discardableResult
    func sweepAttachments() async -> Int {
        guard !isClosed, !isClosing, !libraryOperationBusy else { return 0 }
        if let attachmentSweepResult { return attachmentSweepResult }
        if let attachmentSweepTask { return await attachmentSweepTask.value }
        let store = store
        let task = Task.detached(priority: .utility) { store.removeUnreferencedAttachments() }
        attachmentSweepTask = task
        let result = await task.value
        attachmentSweepResult = result
        attachmentSweepTask = nil
        return result
    }

    private func waitForAttachmentSweep() async {
        guard let task = attachmentSweepTask else { return }
        attachmentSweepResult = await task.value
        attachmentSweepTask = nil
    }

    /// Await every database user before closing or deleting an isolated library.
    func closeAfterStopping() async throws {
        guard !libraryOperationBusy, !isClosing, !attachmentWriteInFlight else { throw BackupError.pendingFiles }
        isClosing = true
        sceneOperationPending = true
        var completed = false
        defer {
            isClosing = false; sceneOperationPending = false
            if !completed { libraryGeneration += 1; restartSceneObservations() }
        }
        try await stopAndDrainSceneObservations()
        voiceCaptureStorage?.prepareForBackground()
        await voiceCaptureStorage?.suspendForBackground()
        ocrActive = false
        await syncController?.shutdown()
        await ocr.cancel(); await ocr.waitUntilIdle()
        await dailyBackupTask?.value
        await cancelAndWaitForAttachmentReads()
        await waitForAttachmentSweep()
        await widgetPublisher?.waitForBackgroundPreparations()
        await waitForSpotlightPreparation?()
        searchTask?.cancel(); await searchTask?.value
        try await withDrainedEditor {
            try prepareAllSceneEditors()
            try close()
        }
        completed = true
    }

    /// Explicit teardown for isolated libraries; close SQLite before removing its files.
    func close() throws {
        guard !isClosed else { return }
        guard (!hasRegisteredSceneWindows || activeSceneFreeze != nil),
              !libraryOperationBusy, !attachmentWriteInFlight, !hasAttachmentReads, dailyBackupTask == nil, attachmentSweepTask == nil, syncController?.busy != true,
              voiceCaptureStorage?.isBusy != true, widgetPublisher?.hasBackgroundPreparations != true,
              spotlightPreparationBusy?() != true else { throw BackupError.pendingFiles }
        runPendingLinkRewrites(forced: true)
        try requireNoOrphanSessionsBeforeEviction()
        syncController?.stopScheduling()
        searchTask?.cancel()
        observation?.cancel()
        observation = nil
        try flush()
        removeAllSessions()
        linkMonitorStorage = nil
        privateAccess?.revoke(); privateAccess = nil
        try removePrivatePreviews()
        try clearSharePublication()
        try database.pool.close()
        isClosed = true
        pendingSceneDetaches.removeAll()
        sceneDetachRetryTask?.cancel(); sceneDetachRetryTask = nil
        voiceCaptureStorage = nil
    }

    private func recoverLockedExistingJournals() throws {
        var blockedVariant = false
        lastReplayError = nil
        let hadFailures = !existingReplayFailureIDs.isEmpty  // a retry that clears the last one must refresh too
        for file in try FileManager.default.contentsOfDirectory(at: paths.journal, includingPropertiesForKeys: nil)
            where file.pathExtension == "jsonl" {
            let id = file.deletingPathExtension().lastPathComponent
            guard try store.note(id: id)?.isLocked == true else { continue }
            do {
                try session(for: id).flush()
                existingReplayFailureIDs.remove(id)
            } catch let failure as JournalVariantRecovery.Failure {
                switch failure {
                case .requiresKey, .partialReplayBlocked, .unavailable: blockedVariant = true
                default: existingReplayFailureIDs.insert(id); lastReplayError = failure
                }
            } catch {
                // Failure belongs to this note. Keep its bytes, leave the vault open and
                // let the shared coordinator classify an eligible byte-preserving exit.
                existingReplayFailureIDs.insert(id); lastReplayError = error
            }
        }
        if hadFailures || !existingReplayFailureIDs.isEmpty {
            do { try recoverMissingJournals(access: privateAccess) }
            catch { recoveryMessage = recoveryFailureMessage(error) }
            if missingJournalBlock == nil, let lastReplayError { recoveryMessage = recoveryFailureMessage(lastReplayError) }
        } else if blockedVariant {
            recoveryMessage = "Some recovery files need separate handling before opening the affected note. Other notes remain available."
        }
    }

    func unlockNotes(password: String, createPassword: Bool = false) async throws {
        let generation = unlockGeneration
        let privacy = NotePrivacy(store: store)
        let access = try await Task.detached {
            try createPassword ? privacy.setPassword(password) : privacy.unlock(password: password)
        }.value
        hasNotePassword = try privacy.hasPassword
        guard generation == unlockGeneration else { access.revoke(); throw NotePrivacyError.accessRevoked }
        privateAccess = access
        do {
            try recoverMissingJournals(access: access)
            try recoverLockedExistingJournals()
        } catch {
            try? await lockVaultAfterDraining()
            throw error
        }
    }

    func lockApplication() {
        if appLockEnabled {
            suspendVoiceForBackground()
            unrecordedCaptureOpens.removeAll()
            appLocked = true
        }
    }

    func suspendVoiceForBackground() {
        guard let voiceCaptureStorage, voiceCaptureStorage.isBusy else { return }
        voiceCaptureStorage.prepareForBackground()
        Task { await voiceCaptureStorage.suspendForBackground() }
    }

    #if DEBUG && targetEnvironment(simulator)
    func enableAppLockForTesting() { appLockEnabled = true; publishRecentNotes() }
    func unlockAppForTesting() { appLocked = false }
    #endif

    private func authenticateDevice(reason: String) async throws {
        let generation = unlockGeneration
        authenticatingDevice = true
        defer { authenticatingDevice = false }
        let context = LAContext()
        let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        guard success, generation == unlockGeneration else { throw NotePrivacyError.accessRevoked }
    }

    func setAppLock(_ enabled: Bool) async throws {
        try await setAppLock(enabled) {
            try await authenticateDevice(reason: enabled ? "Protect access to your Theo Notes library" : "Change access protection for your Theo Notes library")
        }
    }

    func setAppLock(_ enabled: Bool, authenticate: () async throws -> Void) async throws {
        try await authenticate()
        if enabled {
            voiceCaptureStorage?.prepareForBackground()
            await voiceCaptureStorage?.suspendForBackground()
        }
        if enabled { watchWillRestrictAccess?(); try clearSharePublication() }
        try settings.set(.mobileAppLock, to: enabled)
        appLockEnabled = enabled; appLocked = false
        publishRecentNotes()
    }

    func unlockApplication() async throws {
        try await authenticateDevice(reason: "Open your Theo Notes library")
        appLocked = false
        voiceCaptureStorage?.retryRecoveryAfterActivation()
        Task { await drainShareInboxOnActivation() }
    }

    private var biometricAccount: String { paths.root.lastPathComponent }

    func enableBiometrics() throws {
        guard let privateAccess, let envelope = try NotePrivacy(store: store).envelope() else {
            throw NotePrivacyError.accessRevoked
        }
        let key = try privateAccess.journalKey().withUnsafeBytes { Data($0) }
        try MobileBiometricKeychain.store(.init(envelope: envelope, key: key), account: biometricAccount)
        try settings.set(.mobileBiometry, to: true)
        biometryEnabled = true
    }

    func disableBiometrics() throws {
        try MobileBiometricKeychain.remove(account: biometricAccount)
        try settings.set(.mobileBiometry, to: false)
        biometryEnabled = false
    }

    func unlockWithBiometrics() async throws {
        let generation = unlockGeneration, account = biometricAccount
        authenticatingDevice = true
        defer { authenticatingDevice = false }
        let cached = try await Task.detached { try MobileBiometricKeychain.read(account: account) }.value
        guard generation == unlockGeneration else { throw NotePrivacyError.accessRevoked }
        privateAccess = try NotePrivacy(store: store).restoreAccess(vaultKey: SymmetricKey(data: cached.key), matching: cached.envelope)
        do {
            try recoverMissingJournals(access: privateAccess)
            try recoverLockedExistingJournals()
        } catch { try? await lockVaultAfterDraining(); throw error }
    }

    func readableNote(_ id: String) throws -> Note? {
        guard let note = try store.note(id: id) else { return nil }
        if !note.isLocked { return note }
        return try privateAccess?.note(id: id)
    }

    func canRead(_ note: Note) -> Bool {
        !note.isLocked || (privateAccess != nil && note.encryptedPayload != nil)
    }

    func discardSession(_ id: String) throws {
        try sessions[id]?.flush()
        removeSession(id)
    }

    private func detachSceneEditorsForNotePrivacy(_ id: String) throws {
        guard hasRegisteredSceneWindows else { return } // Preserve legacy caller ownership.
        let matching = editors.allObjects.filter { $0.session?.noteId == id }
        guard !matching.isEmpty else { return }
        guard activeSceneFreeze != nil else { throw MobileEditorDrainError.busy }
        // Already frozen together: flush/detach every listener before the Core retention
        // guard and encrypted/plain session replacement, never only the focused window.
        for editor in matching { try editor.closeForPrivacy() }
    }

    func lockNote(_ id: String) throws {
        guard let privateAccess else { throw NotePrivacyError.accessRevoked }
        watchWillRestrictAccess?()
        try detachSceneEditorsForNotePrivacy(id)
        let draftStore = sketchDraftStore
        let transition = draftStore.beginProtectionTransition(noteID: id)
        defer {
            let protected = (try? store.note(id: id)?.isLocked) ?? true
            draftStore.completeProtectionTransition(transition, isProtected: protected)
        }
        try discardSession(id)
        try clearSharePublication()
        defer { publishRecentNotes() }
        try privateAccess.lock(noteId: id)
        // Lock immediately; a failed upgrade leaves the prior file-protected draft for unlock.
        let admission = draftStore.captureAdmission(for: id)
        Task { _ = try? await draftStore.upgradePlainDrafts(noteID: id, access: privateAccess, admission: admission) }
        spotlightDidChange?()
    }

    func removeNoteLock(_ id: String) throws {
        guard let privateAccess else { throw NotePrivacyError.accessRevoked }
        try detachSceneEditorsForNotePrivacy(id)
        let draftStore = sketchDraftStore
        let transition = draftStore.beginProtectionTransition(noteID: id)
        defer {
            let protected = (try? store.note(id: id)?.isLocked) ?? true
            draftStore.completeProtectionTransition(transition, isProtected: protected)
        }
        try discardSession(id)
        try privateAccess.removeLock(noteId: id)
        spotlightDidChange?()
    }

    func cancelPendingUnlock() { unlockGeneration += 1 }

    struct ConfirmedResetJournalPlan {
        let id = UUID()
        let libraryGeneration: Int
        let sceneGeneration: Int
        let discard: MissingJournalRecovery.ResetDiscardPlan
        var items: [(noteID: String, suffix: String, token: MissingJournalRecovery.DiscardToken)] { discard.items }
        var ramOnlyNoteIDs: [String] { discard.ramOnlyNoteIDs }
    }

    /// Explicit emergency-reset proposal; the core rejects plaintext, ambiguous and live files.
    func prepareResetJournalDiscard() throws -> ConfirmedResetJournalPlan {
        guard !isClosed, !isClosing, !libraryOperationBusy, !sceneOperationPending else { throw BackupError.pendingFiles }
        return .init(libraryGeneration: libraryGeneration, sceneGeneration: sceneRoutingGeneration,
                     discard: try MissingJournalRecovery.prepareResetDiscard(store: store))
    }

    func deleteNotesPasswordAfterConfirmedJournalDiscard(_ plan: ConfirmedResetJournalPlan) async throws {
        func requireCurrent() throws {
            guard plan.libraryGeneration == libraryGeneration, plan.sceneGeneration == sceneRoutingGeneration,
                  syncController?.busy != true, voiceCaptureStorage?.isBusy != true,
                  try NotePrivacy(store: store).passwordResetStatus().canReset else { throw BackupError.pendingFiles }
        }
        try requireCurrent()
        guard !(try await hasKeyDependentSketchDrafts()) else { throw BackupError.pendingFiles }
        // Re-check after the last await, then (under the writer) the tokens, source absence and the
        // live holders; invalidate them before the drain, which skips exactly these ids.
        try requireCurrent()
        try MissingJournalRecovery.validateDiscardsAndInvalidate(plan.items.map(\.token), store: store, matching: plan.discard.sessionFence)
        let confirmedIDs = Set(plan.items.map(\.noteID) + plan.ramOnlyNoteIDs)
        resetDeferredPlainOrphans = try plainOrphanIDs()
        defer { resetDeferredPlainOrphans = [] }
        try await beginLibraryOperationAfterDraining(allowConfirmedJournalReset: true, confirmedResetIDs: confirmedIDs.union(resetDeferredPlainOrphans))
        defer { endLibraryOperation() }
        try requireCurrent()
        let expected = Set(plan.items.map { "\($0.noteID).jsonl\($0.suffix)" })
        let names = try FileManager.default.contentsOfDirectory(atPath: paths.journal.path)
        for name in names where name.contains(".jsonl") {
            let url = paths.journal.appendingPathComponent(name)
            if (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0,
               !expected.contains(name) { throw BackupError.pendingFiles }
        }
        for id in confirmedIDs { removeSession(id) }
        for item in plan.items {
            try MissingJournalRecovery.discardLeftoverAfterConfirmation(item.token, store: store)
        }
        // Any additional, ambiguous or changed journal still blocks the key reset.
        try recoverMissingJournals(access: privateAccess)
        try requireMissingJournalRecoveryCleared()
        try await finishDeletingNotesPassword()
        savePlainOrphansAfterReset()
    }

    func deleteNotesPassword() async throws {
        guard syncController?.busy != true else { throw BackupError.pendingFiles }
        resetDeferredPlainOrphans = try plainOrphanIDs()
        defer { resetDeferredPlainOrphans = [] }
        try await beginLibraryOperationAfterDraining(confirmedResetIDs: resetDeferredPlainOrphans)
        defer { endLibraryOperation() }
        guard syncController?.busy != true else { throw BackupError.pendingFiles }
        try await finishDeletingNotesPassword()
        savePlainOrphansAfterReset()
    }

    /// Editorless dirty plain sessions whose note is gone (an editor keeps its own recovery flow).
    private func plainOrphanIDs() throws -> Set<String> {
        var ids: Set<String> = []
        for session in sessions.values where !session.wasOriginallyLocked && Data(session.text.utf8) != Data(session.committedText.utf8) &&
            !editors.allObjects.contains(where: { $0.session === session }) {
            if try store.note(id: session.noteId) == nil { ids.insert(session.noteId) }
        }
        return ids
    }

    /// With the vault gone the existing plain recovery path accepts a missing source. A crash
    /// before this point loses the RAM-only text (accepted residual, as for any RAM-only text).
    private func savePlainOrphansAfterReset() {
        for id in resetDeferredPlainOrphans.sorted() {
            guard let session = sessions[id] else { continue }
            do {
                _ = try session.preserveBrowserRecoveryResult(text: session.text, baseRevision: session.revision)
                removeSession(id)
            } catch {
                // The session stays cached; the orphan gate saves it before the next library operation.
                recoveryMessage = "Unsaved text from a removed note could not be saved yet. Keep Theo Notes open: the text is kept in memory and saving is tried again before the next library change or sync."
            }
        }
    }

    private func finishDeletingNotesPassword() async throws {
        try await withSuspendedSketchWrites {
            guard !(try await hasKeyDependentSketchDrafts()) else { throw MobileSketchDraftError.protectedDrafts }
            await syncController?.setPaused(true)
            try lockVault()
            syncNoteAccess?.revoke(); syncNoteAccess = nil
            try disableBiometrics()
            try NotePrivacy(store: store).deletePassword()
            hasNotePassword = false
        }
    }

    /// A formerly plain draft of a now-locked or missing note still needs the old vault.
    func hasKeyDependentSketchDrafts() async throws -> Bool {
        let drafts = sketchDraftStore
        if try await drafts.hasProtectedDrafts() { return true }
        // With no local vault there is no old key that a plain residual could lose.
        guard try NotePrivacy(store: store).hasPassword else { return false }
        for summary in try await drafts.discover() {
            guard !summary.isProtected, let draft = try await drafts.load(summary.id),
                  let noteID = draft.originalNoteID, let note = try store.note(id: noteID),
                  note.deletedAt == nil, !note.isLocked else { return true }
        }
        return false
    }

    /// Deadline/OS-expiration path only: privacy cannot wait for editor or disk I/O.
    /// Normal close first drains edits; this forced boundary may retain only the last
    /// durable checkpoint/journal and must never keep either in-memory access alive.
    func revokePrivateAccessForExpiredPrivacyClose() {
        privateAccess?.revoke()
        syncNoteAccess?.revoke()
    }

    /// Caller should use prepareScenePrivacyClose within its bounded background budget.
    /// Final revocation still detaches every view even if one journal flush fails.
    func lockVault() throws {
        unlockGeneration += 1
        syncNoteAccess?.revoke()
        defer {
            for id in Array(sessions.keys) where (try? store.note(id: id))?.isLocked == true {
                removeSession(id)
            }
            privateAccess?.revoke(); privateAccess = nil
            try? removePrivatePreviews()
        }
        var detachError: (any Error)?
        if hasRegisteredSceneWindows {
            for editor in editors.allObjects {
                do { try editor.closeForPrivacy() } catch { if detachError == nil { detachError = error } }
            }
        }
        if let detachError { throw detachError }
        try flush()
        try removePrivatePreviews()
    }

    /// Async callers which are not already inside a strict all-scene freeze use the
    /// same checkpoint-first, bounded privacy boundary as the scene background path.
    /// The key is revoked at the deadline even if a page/disk worker cannot finish.
    func lockVaultAfterDraining(timeout: TimeInterval = 2) async throws {
        guard !isClosed else { return }
        let interval = min(2, max(0, timeout)), deadline = Date().addingTimeInterval(min(2, max(0, timeout)))
        if hasRegisteredSceneWindows { MobilePrivacyShield.cover() }
        if scenePrivacyCloseToken != nil {
            // Another privacy owner already has the key/checkpoint deadline. Do not
            // revoke underneath its final sealed checkpoint merely to close twice.
            let completed = await MobileSketchPrivacyCloseBudget.wait(timeout: .seconds(interval)) {
                await self.waitForSceneAdmission()
            }
            if !completed {
                revokePrivateAccessForExpiredPrivacyClose()
                try lockVault()
                errorMessage = "Protected access closed before every recent edit finished saving. Recovery journals are kept."
                throw MobileEditorDrainError.timeout
            }
            return
        }
        let token = beginScenePrivacyClose()
        // An existing all-scene lease already owns admission and all page ACKs.
        // If someone else owns admission without such a lease, confidentiality still
        // wins; report the forced boundary rather than claiming the page was drained.
        guard token != nil || activeSceneFreeze != nil else {
            revokePrivateAccessForExpiredPrivacyClose()
            try lockVault()
            errorMessage = "Protected access closed while another operation was saving. Recovery journals are kept; some recent edits may need to be entered again."
            throw MobileEditorDrainError.busy
        }
        let hosts = token == nil ? sceneSketchHosts.allObjects : []
        hosts.forEach { $0.suspend() }
        var failure: (any Error)?
        var pagesDrained = activeSceneFreeze != nil
        let completed = await MobileSketchPrivacyCloseBudget.wait(timeout: .seconds(interval)) {
            await MobileSketchPrivacyCloseBudget.checkpointBeforePages(deadline: deadline, checkpoints: {
                if token != nil {
                    do { try await self.completeScenePrivacyCheckpoints() } catch { failure = error }
                } else {
                    for host in hosts {
                        do { try await host.completeSuspendedCheckpoint() } catch { if failure == nil { failure = error } }
                    }
                }
            }, pages: { deadline in
                if token != nil {
                    do {
                        try await self.prepareScenePrivacyClose(deadline: deadline.addingTimeInterval(-0.5))
                        pagesDrained = true
                    } catch {
                        if !Task.isCancelled, Date() < deadline {
                            pagesDrained = await self.preserveSceneBrowserTextBeforePrivacyClose(deadline: deadline)
                        }
                        if !pagesDrained, failure == nil { failure = error }
                    }
                }
            })
        }
        let drained = completed && pagesDrained
        if !drained { revokePrivateAccessForExpiredPrivacyClose() }
        do { try lockVault() } catch { if failure == nil { failure = error } }
        if let token { finishScenePrivacyClose(token) }
        if !drained {
            errorMessage = "Protected access closed before every recent edit finished saving. The last saved drafts and recovery journals are kept."
            throw MobileEditorDrainError.timeout
        }
        if let failure { errorMessage = failure.localizedDescription; throw failure }
    }

    func prepareScenePrivacyClose(deadline: Date? = nil) async throws {
        guard let token = scenePrivacyCloseToken else { throw MobileEditorDrainError.busy }
        if hasRegisteredSceneWindows { try await stopAndDrainSceneObservations() }
        guard scenePrivacyCloseToken == token else { throw CancellationError() }
        try await withDrainedEditor(deadline: deadline) {
            guard scenePrivacyCloseToken == token else { throw CancellationError() }
            try prepareAllSceneEditors()
        }
    }

    func preserveSceneBrowserTextBeforePrivacyClose(deadline: Date) async -> Bool {
        let active = editors.allObjects.filter { $0.session != nil }
        let attempts: [@MainActor () async -> Bool] = active.map { editor in
            {
                if !editor.ready {
                    do { try editor.drainUnreadyNativeSession(); return true } catch { return false }
                }
                return await editor.preserveBrowserTextBeforePrivacyClose(deadline: deadline)
            }
        }
        return await Self.attemptPrivacyRecoveries(attempts, deadline: deadline)
    }

    static func attemptPrivacyRecoveries(_ attempts: [@MainActor () async -> Bool], deadline: Date) async -> Bool {
        var succeeded = true
        for attempt in attempts {
            guard !Task.isCancelled, Date() < deadline else { return false }
            if !(await attempt()) { succeeded = false }
        }
        return succeeded
    }

    private var privatePreviewRoot: URL { paths.root.appendingPathComponent("UnlockedPreviews", isDirectory: true) }

    private func removePrivatePreviews() throws {
        if FileManager.default.fileExists(atPath: privatePreviewRoot.path) {
            try FileManager.default.removeItem(at: privatePreviewRoot)
        }
    }

    func attachmentURL(_ filename: String, noteID: String) throws -> URL? {
        guard let note = try store.note(id: noteID) else { return nil }
        if !note.isLocked { return AttachmentStore(paths: paths, database: database).url(for: filename, noteId: noteID) }
        guard let privateAccess else { return nil }
        // The note directory is private and excluded from backups; Quick Look needs the extension.
        guard !filename.contains("/"), !filename.contains("\u{0}"), filename != ".", filename != "..",
              !noteID.contains("/"), !noteID.contains("\u{0}"), noteID != ".", noteID != ".." else { return nil }
        let dir = privatePreviewRoot.appendingPathComponent(noteID, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        var root = privatePreviewRoot
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        let output = dir.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: output.path) {
            try privateAccess.decryptAttachment(filename, noteId: noteID, to: output)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: output.path)
        }
        return output
    }

    /// Selection is copied, never removed. Locked sources produce another encrypted note.
    @discardableResult
    func copySelectionToNewNote(_ text: String, sourceID: String) throws -> String {
        if hasRegisteredSceneWindows { try requireSceneMutation() }
        if let navigation = preferredLegacyScene?.navigation { let id = try copySelectionToNewNote(text, sourceID: sourceID, in: navigation); adoptSceneNavigationForLegacy(navigation); return id }
        guard !libraryOperationBusy, !isClosed else { throw NotePrivacyError.accessRevoked }
        try flush()
        let copy: Note
        if try store.note(id: sourceID)?.isLocked == true {
            guard let privateAccess else { throw NotePrivacyError.accessRevoked }
            copy = try privateAccess.createFromSelection(of: sourceID, text: text)
        } else {
            copy = try store.createFromSelection(of: sourceID, text: text)
        }
        try reveal(copy.id)
        return copy.id
    }

    func addAttachment(data: Data, filename: String, noteID: String) throws -> String {
        if try store.note(id: noteID)?.isLocked == true {
            guard let privateAccess else { throw NotePrivacyError.accessRevoked }
            return try privateAccess.addAttachment(data: data, filename: filename, to: noteID)
        }
        return try AttachmentStore(paths: paths, database: database).add(data: data, filename: filename, to: noteID)
    }

    func addAttachment(fileAt url: URL, noteID: String) throws -> String {
        if try store.note(id: noteID)?.isLocked == true {
            guard let privateAccess else { throw NotePrivacyError.accessRevoked }
            return try privateAccess.addAttachment(fileAt: url, to: noteID)
        }
        return try AttachmentStore(paths: paths, database: database).add(fileAt: url, to: noteID)
    }

    func perform(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }

    func setActive(_ requested: Bool) {
        guard !isClosed else { return }
        let active = hasRegisteredSceneWindows ? hasActiveSceneWindows : requested
        // Leaving the front may end the app before the pause is over (IOS-LINKS-R4).
        if !active { runPendingLinkRewrites(forced: false) }
        ocrActive = active
        if active {
            Task { await drainShareInboxOnActivation() }
        }
        if syncController != nil || MobileSyncController.hasSavedConnection(paths: paths) {
            sync.setActive(active)
        }
        Task { if active && !libraryOperationBusy { await ocr.startBacklog() } else { await ocr.pauseBacklog() } }
        if active, dailyBackupTask == nil {
            let backup = LibraryBackup(database: database, paths: paths)
            dailyBackupTask = Task { [weak self] in
                defer { self?.dailyBackupTask = nil }
                do { _ = try await Task.detached(priority: .utility) { try backup.createDailyDatabaseSnapshot() }.value }
                catch { self?.recoveryMessage = "The automatic recovery snapshot could not be saved. Your notes remain in the library." }
            }
        }
    }

    private func observe() {
        observation = LibraryQueries.observeSnapshot(scope: scope, workspace: workspace, database: database, calendar: .current, now: { .now },
            onError: { [weak self] in self?.errorMessage = $0.localizedDescription },
            onChange: { [weak self] value in
                guard let self else { return }
                snapshot = value
                publishRecentNotes()
                if ocrActive && !libraryOperationBusy { Task { await ocr.startBacklog() } }
                if !value.workspaceExists { workspace = nil; return }
                search()
            })
    }

    private func search() {
        searchTask?.cancel()
        guard !query.isEmpty else { items = snapshot.items; return }
        let query = query, scope = scope, workspace = workspace, sort = snapshot.sort, database = database
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
                let result = try await database.pool.read { db in
                    try LibraryQueries.search(query, in: scope, sort: sort, workspace: workspace, now: .now, calendar: .current, db: db)
                }
                try Task.checkCancellation()
                self?.items = result.items
            } catch is CancellationError {} catch { self?.errorMessage = error.localizedDescription }
        }
    }

    /// Match the shared picker and Mac default-template rules. A stale choice falls back
    /// to ordinary capture instead of opening a picker preselected to an unrelated template.
    func eligibleStartTemplateID() throws -> String? {
        let id = try settings.value(.startNoteTemplate)
        guard !id.isEmpty else { return nil }
        let eligible = try database.pool.read { db in try Templates.list(db: db).contains { $0.id == id } }
        guard eligible else {
            try settings.set(.startNoteTemplate, to: "")
            return nil
        }
        return id
    }

    private func requireSceneMutation() throws {
        if let lease = sceneRoutingLease, sceneStates[lease.sceneID]?.navigation == nil { throw MobileEditorDrainError.busy }
        guard !appLocked, !isClosed, !isClosing, !libraryOperationBusy, !sceneOperationPending, !sceneDrainInFlight, !attachmentWriteInFlight else { throw MobileEditorDrainError.busy }
    }
    @discardableResult func createNote(in navigation: MobileSceneNavigation) throws -> String {
        try requireSceneMutation(); try flush()
        let tags: [String] = if case .tag(let path) = navigation.scope { [path] } else { [] }
        let initial: String
        switch preferences.startContent {
        case "heading": initial = "# {{cursor}}"
        case "date": initial = "# {{date}}\n\n{{cursor}}"
        case "datetime": initial = "# {{datetime}}\n\n{{cursor}}"
        default: initial = ""
        }
        let created = try store.createFromTemplate(templateText: initial, context: TemplateContext(),
            workspace: navigation.workspace, tagPosition: settings.tagPosition, extraTags: tags)
        if let caret = created.caretOffset { navigation.pendingCaret[created.0.id] = caret }
        navigation.query = ""
        if case .tag = navigation.scope {} else { navigation.scope = .notes }
        navigation.selectedID = created.0.id
        return created.0.id
    }
    @discardableResult func createFromTemplate(_ id: String, title: String, clipboard: String?, in navigation: MobileSceneNavigation) throws -> String {
        try requireSceneMutation(); try flush()
        let tags: [String] = if case .tag(let path) = navigation.scope { [path] } else { [] }
        let (note, caret) = try store.createFromTemplate(templateId: id,
            context: TemplateContext(clipboard: clipboard, title: title), workspace: navigation.workspace,
            tagPosition: settings.tagPosition, extraTags: tags)
        if let caret { navigation.pendingCaret[note.id] = caret }
        preferences.recentTemplateIDs = Array(([id] + preferences.recentTemplateIDs.filter { $0 != id }).prefix(5))
        try savePreferences()
        navigation.query = ""
        if case .tag = navigation.scope {} else { navigation.scope = .notes }
        navigation.selectedID = note.id
        return note.id
    }
    @discardableResult func copySelectionToNewNote(_ text: String, sourceID: String, in navigation: MobileSceneNavigation) throws -> String {
        try requireSceneMutation(); try flush()
        let copy: Note
        if try store.note(id: sourceID)?.isLocked == true {
            guard let privateAccess else { throw NotePrivacyError.accessRevoked }
            copy = try privateAccess.createFromSelection(of: sourceID, text: text)
        } else { copy = try store.createFromSelection(of: sourceID, text: text) }
        try reveal(copy.id, in: navigation)
        return copy.id
    }
    func reveal(_ id: String, in navigation: MobileSceneNavigation) throws {
        try requireSceneMutation()
        guard let note = try store.note(id: id), note.deletedAt == nil else { throw StoreError.noteNotFound(id: id) }
        let contained = try navigation.workspace.map { workspace in
            try database.pool.read { try workspace.contains(noteId: id, db: $0) }
        } ?? true
        try navigation.reveal(note, containedInWorkspace: contained)
    }
    func enterWorkspace(_ path: String?, in navigation: MobileSceneNavigation) throws {
        try requireSceneMutation(); try flush()
        let next = path.map(Workspace.init(path:))
        if let next { try store.recordWorkspaceUse(next) }
        navigation.enterWorkspace(next)
    }
    func navigate(back: Bool, in navigation: MobileSceneNavigation) throws {
        try requireSceneMutation(); try flush()
        if let id = navigation.historyDestination(back: back, where: { [store] in
            guard let note = try? store.note(id: $0) else { return false }; return note.deletedAt == nil
        }) { try reveal(id, in: navigation) }
    }
    func headingLink(for request: HeadingMenuRequest, in navigation: MobileSceneNavigation) throws -> String? {
        guard navigation.selectedID == request.noteId, let note = try store.note(id: request.noteId), note.location != .trash, canRead(note) else { return nil }
        let text = try session(for: request.noteId).text
        let metadata = NoteParser.metadata(for: text)
        guard let heading = metadata.headings.first(where: { $0.line == request.line && $0.level == request.level }) else { return nil }
        let earlier = metadata.headings.prefix { $0.line < heading.line }.map(\.text)
        return try? NoteStore.headingLink(forTitle: metadata.title, heading: heading.text, earlierHeadings: earlier).get()
    }
    func togglePin(_ item: NoteListItem, in navigation: MobileSceneNavigation) throws {
        try requireSceneMutation(); try sessions[item.id]?.flush()
        let tag: String? = if case .tag(let path) = navigation.scope { path } else { nil }
        try store.setPinned([item.id], pinned: !item.isPinned, inTag: tag)
        _ = try sessions[item.id]?.handleExternalChange()
    }
    func trashDeletionCandidates(in navigation: MobileSceneNavigation) throws -> [String] {
        let ids = try store.allNotes(location: .trash).map(\.id)
        guard let workspace = navigation.workspace else { return ids }
        return try database.pool.read { db in try ids.filter { try workspace.contains(noteId: $0, db: db) } }
    }
    func renameTag(_ path: String, to replacement: String, in navigation: MobileSceneNavigation) throws {
        try requireSceneMutation(); try flush()
        tagUndo = try store.renameTag(path, to: replacement)
        for state in sceneStates.values {
            guard let scene = state.navigation else { continue }
            if let workspace = scene.workspace, Workspace(path: path).includes(tagPath: workspace.path) {
                scene.workspace = Workspace(path: replacement + workspace.path.dropFirst(path.count))
            }
            if case .tag(let tag) = scene.scope, Workspace(path: path).includes(tagPath: tag) {
                scene.scope = .tag(replacement + tag.dropFirst(path.count))
            }
        }
        navigation.scope = .tag(replacement)
        try refreshSessions()
    }
    func deleteTag(_ path: String, in navigation: MobileSceneNavigation) throws {
        try requireSceneMutation(); try flush()
        tagUndo = try store.deleteTag(path)
        for state in sceneStates.values {
            guard let scene = state.navigation else { continue }
            if let workspace = scene.workspace, Workspace(path: path).includes(tagPath: workspace.path) { scene.workspace = nil }
            if case .tag(let tag) = scene.scope, Workspace(path: path).includes(tagPath: tag) { scene.scope = .notes }
        }
        navigation.scope = .notes
        try refreshSessions()
    }

    @discardableResult
    func createNote() throws -> String {
        if hasRegisteredSceneWindows { try requireSceneMutation() }
        if let navigation = preferredLegacyScene?.navigation { let id = try createNote(in: navigation); adoptSceneNavigationForLegacy(navigation); return id }
        try flush()
        var tags: [String] = []
        if case .tag(let path) = scope { tags = [path] }
        let initial: String
        switch preferences.startContent {
        case "heading": initial = "# {{cursor}}"
        case "date": initial = "# {{date}}\n\n{{cursor}}"
        case "datetime": initial = "# {{datetime}}\n\n{{cursor}}"
        default: initial = ""
        }
        let created = try store.createFromTemplate(templateText: initial, context: TemplateContext(),
            workspace: workspace, tagPosition: settings.tagPosition, extraTags: tags)
        if let caret = created.caretOffset { pendingCaret[created.0.id] = caret }
        query = ""
        if case .tag = scope {} else { scope = .notes }
        selectedID = created.0.id
        return created.0.id
    }

    func captureThought(source: CaptureSource) async throws -> String {
        guard !appLocked, !libraryOperationBusy, !isClosed, !isClosing else { throw CocoaError(.fileReadNoPermission) }
        try flush()
        let note = try store.create(text: "", captureSource: source)
        unrecordedCaptureOpens.insert(note.id)
        activeCaptures.insert(note.id)
        pendingCaret[note.id] = 0
        workspace = nil; query = ""; scope = .notes; selectedID = note.id
        return note.id
    }

    func cancelCapture(noteId: String) throws {
        // Cancellation without an editor acknowledgement can never discard a capture.
        guard activeCaptures.contains(noteId) else { return }
        try sessions[noteId]?.flush()
    }

    /// `whileClosed` runs before the verified close is released: a ready page may only be replaced
    /// by another note's page inside it (P1, e3268f62), so a switch away from a capture goes there.
    func finishCapture(noteId: String, editor: MobileEditor, mayFinish: () -> Bool, whileClosed: () -> Void = {}) async throws {
        guard activeCaptures.contains(noteId) else { return }
        let reply = try await editor.prepareCaptureClose(noteId)
        defer { editor.endCaptureClose(reply) }
        guard mayFinish(), !appLocked, !libraryOperationBusy, !isClosed, !isClosing,
              editor.session?.noteId == noteId,
              !editors.allObjects.contains(where: { $0 !== editor && $0.session?.noteId == noteId }) else {
            throw CocoaError(.coderReadCorrupt)
        }
        let trashed: Bool
        if reply.editedSinceLoad { trashed = false }
        else { trashed = try store.cancelCapture(noteId: noteId, createdText: "") }
        activeCaptures.remove(noteId)
        unrecordedCaptureOpens.remove(noteId)
        if trashed {
            clearNavigationTargets([noteId], including: editor.sceneNavigation)
            _ = try sessions[noteId]?.handleExternalChange()
        }
        whileClosed()
    }

    /// Remove only an affected note intent. Never project legacy filters or nil
    /// selection into a different scene which has already selected another note.
    private func clearNavigationTargets(_ ids: Set<String>, including source: MobileSceneNavigation? = nil) {
        guard !ids.isEmpty else { return }
        var navigations = sceneStates.values.compactMap(\.navigation)
        if let source, !navigations.contains(where: { $0 === source }) { navigations.append(source) }
        for navigation in navigations {
            for id in ids { navigation.pendingCaret.removeValue(forKey: id) }
            if let selected = navigation.selectedID, ids.contains(selected) { navigation.selectedID = nil }
            if let callback = navigation.pendingCallbackNavigation, ids.contains(callback.noteID) { navigation.pendingCallbackNavigation = nil }
        }
        let wasDispatching = dispatchingLegacyNavigation
        dispatchingLegacyNavigation = true
        defer { dispatchingLegacyNavigation = wasDispatching }
        for id in ids { pendingCaret.removeValue(forKey: id) }
        if let selectedID, ids.contains(selectedID) { self.selectedID = nil }
        if let callback = pendingCallbackNavigation, ids.contains(callback.noteID) { pendingCallbackNavigation = nil }
    }

    func registerEditor(_ editor: MobileEditor) { editors.add(editor) }

    func isActiveCapture(_ noteId: String) -> Bool { activeCaptures.contains(noteId) }

    func recordEditorOpen(noteId: String) {
        guard !appLocked else { return }
        if unrecordedCaptureOpens.remove(noteId) != nil { return }
        do { try store.recordOpened(noteId: noteId); publishRecentNotes() }
        catch { errorMessage = error.localizedDescription }
    }

    @discardableResult
    func createFromTemplate(_ id: String, title: String, clipboard: String?) throws -> String {
        if hasRegisteredSceneWindows { try requireSceneMutation() }
        if let navigation = preferredLegacyScene?.navigation { let created = try createFromTemplate(id, title: title, clipboard: clipboard, in: navigation); adoptSceneNavigationForLegacy(navigation); return created }
        try flush()
        var tags: [String] = []
        if case .tag(let path) = scope { tags = [path] }
        let (note, caret) = try store.createFromTemplate(templateId: id,
            context: TemplateContext(clipboard: clipboard, title: title), workspace: workspace,
            tagPosition: settings.tagPosition, extraTags: tags)
        if let caret { pendingCaret[note.id] = caret }
        preferences.recentTemplateIDs = Array(([id] + preferences.recentTemplateIDs.filter { $0 != id }).prefix(5))
        try savePreferences()
        query = ""
        if case .tag = scope {} else { scope = .notes }
        selectedID = note.id
        return note.id
    }

    func reveal(_ id: String) throws {
        if hasRegisteredSceneWindows { try requireSceneMutation() }
        if let navigation = preferredLegacyScene?.navigation { try reveal(id, in: navigation); adoptSceneNavigationForLegacy(navigation); return }
        guard let note = try store.note(id: id), note.deletedAt == nil else { throw StoreError.noteNotFound(id: id) }
        if let workspace, try !database.pool.read({ try workspace.contains(noteId: id, db: $0) }) { self.workspace = nil }
        query = ""
        scope = note.location == .trash ? .trash : note.location == .archive ? .archive : .notes
        selectedID = id
    }

    func enterWorkspace(_ path: String?) throws {
        if hasRegisteredSceneWindows { try requireSceneMutation() }
        if let navigation = preferredLegacyScene?.navigation { try enterWorkspace(path, in: navigation); adoptSceneNavigationForLegacy(navigation); return }
        try flush()
        let next = path.map(Workspace.init(path:))
        if let next { try store.recordWorkspaceUse(next) }
        workspace = next; scope = .notes; query = ""; selectedID = nil
    }

    func navigate(back: Bool) throws {
        if hasRegisteredSceneWindows { try requireSceneMutation() }
        if let navigation = preferredLegacyScene?.navigation { try navigate(back: back, in: navigation); adoptSceneNavigationForLegacy(navigation); return }
        let available: (String) -> Bool = { [store] in (try? store.note(id: $0))?.deletedAt == nil && (try? store.note(id: $0)) != nil }
        let id = back ? history.goBack(where: available) : history.goForward(where: available)
        if let id { try reveal(id) }
    }

    func refreshSessions() throws {
        for session in sessions.values {
            guard let note = try store.note(id: session.noteId), note.deletedAt == nil,
                  note.isLocked == session.wasOriginallyLocked else { continue }
            _ = try session.handleExternalChange()
        }
    }

    func renameTag(_ path: String, to replacement: String) throws {
        try flush()
        tagUndo = try store.renameTag(path, to: replacement)
        if let workspace, Workspace(path: path).includes(tagPath: workspace.path) {
            self.workspace = Workspace(path: replacement + workspace.path.dropFirst(path.count))
        }
        scope = .tag(replacement)
        try refreshSessions()
    }

    func deleteTag(_ path: String) throws {
        try flush()
        tagUndo = try store.deleteTag(path)
        scope = .notes
        try refreshSessions()
    }

    func undoTagEdit() throws {
        guard let tagUndo else { return }
        try flush()
        let skipped = try store.undoTagRewrite(tagUndo)
        self.tagUndo = nil
        try refreshSessions()
        if !skipped.isEmpty { recoveryMessage = "Some notes changed since the tag edit and were kept as they are." }
    }

    func savePreferences() throws { try settings.set(.mobilePreferences, to: preferences) }

    /// User moves belong to the originating scene, never the legacy global projection.
    /// Drain every registered page before changing shared read-only/location metadata.
    func moveNotesAfterDraining(_ ids: [String], to location: NoteLocation, in navigation: MobileSceneNavigation) async throws {
        try requireSceneMutation()
        let owner = sceneStates[navigation.id]
        if hasRegisteredSceneWindows, owner?.navigation !== navigation { throw MobileEditorDrainError.busy }
        let action = {
            if let owner, self.sceneStates[navigation.id] !== owner || owner.navigation !== navigation { throw MobileEditorDrainError.busy }
            guard !self.appLocked, !self.isClosed, !self.isClosing, !self.libraryOperationBusy,
                  !self.sceneOperationPending, !self.attachmentWriteInFlight,
                  self.voiceCaptureStorage?.isBusy != true else { throw MobileEditorDrainError.busy }
            try self.moveNotesWhileDrained(ids, to: location, source: navigation)
        }
        if hasRegisteredSceneWindows { try await withDrainedEditor(action) }
        else { try await withDrainedShareEditors(action) }
    }

    /// Legacy callers without live pages may still move a note. A live scene must use
    /// the awaited API above so a location transition cannot discard unacknowledged text.
    func move(_ id: String, to location: NoteLocation) throws {
        try requireSceneMutation()
        guard !editors.allObjects.contains(where: { $0.session?.noteId == id }) else { throw MobileEditorDrainError.busy }
        try moveNotesWhileDrained([id], to: location, source: nil)
    }

    private func moveNotesWhileDrained(_ ids: [String], to location: NoteLocation, source: MobileSceneNavigation?) throws {
        let ids = Array(Set(ids)).sorted(), moved = Set(ids)
        guard !ids.isEmpty else { return }
        for id in ids { try sessions[id]?.flush() }
        if location != .notes { try clearSharePublication() }
        defer { if location != .notes { publishRecentNotes() } }
        switch location {
        case .notes: try store.restore(ids)
        case .archive: try store.archive(ids)
        case .trash: try store.trash(ids)
        }
        var navigations = sceneStates.values.compactMap(\.navigation)
        if let source, !navigations.contains(where: { $0 === source }) { navigations.append(source) }
        for navigation in navigations {
            if let selected = navigation.selectedID, moved.contains(selected) { navigation.selectedID = nil }
            if let callback = navigation.pendingCallbackNavigation, moved.contains(callback.noteID) { navigation.pendingCallbackNavigation = nil }
        }
        // Consume only matching legacy intent, without copying its stale filters or
        // nil selection into whichever other window most recently became frontmost.
        let wasDispatching = dispatchingLegacyNavigation
        dispatchingLegacyNavigation = true
        defer { dispatchingLegacyNavigation = wasDispatching }
        if let selectedID, moved.contains(selectedID) { self.selectedID = nil }
        if let callback = pendingCallbackNavigation, moved.contains(callback.noteID) { pendingCallbackNavigation = nil }
        // A refresh failure must not leave a successfully moved note selected.
        for id in ids { _ = try sessions[id]?.handleExternalChange() }
    }

    func deletePermanently(_ id: String) throws {
        _ = try deleteTrashedNotes([id])
    }

    /// Capture the confirmation's exact scope, including notes hidden by a search query.
    /// Newly trashed notes are never added to an already presented confirmation.
    func trashDeletionCandidates() throws -> [String] {
        let ids = try store.allNotes(location: .trash).map(\.id)
        guard let workspace else { return ids }
        return try database.pool.read { db in
            try ids.filter { try workspace.contains(noteId: $0, db: db) }
        }
    }

    @ObservationIgnored private var permanentDeletionDrainInFlight = false
    /// Deterministic transaction-boundary seam; nil in production.
    @ObservationIgnored var beforePermanentDeleteTransactionForTesting: (@MainActor () throws -> Void)?

    /// UI and automation must finish every live page's acknowledgement before deleting.
    /// The synchronous entry point remains available for callers with no live page.
    func deleteTrashedNotesAfterDraining(_ ids: [String]) async throws -> [String] {
        try requireSceneMutation()
        let action = {
            try self.requireSceneDeletionAdmission()
            self.permanentDeletionDrainInFlight = true
            defer { self.permanentDeletionDrainInFlight = false }
            return try self.deleteTrashedNotes(ids)
        }
        if hasRegisteredSceneWindows { return try await withDrainedEditor(action) }
        return try await withDrainedShareEditors(action)
    }

    private func requireSceneDeletionAdmission() throws {
        guard !appLocked, !isClosed, !isClosing, !libraryOperationBusy, !sceneOperationPending,
              !attachmentWriteInFlight, voiceCaptureStorage?.isBusy != true else { throw MobileEditorDrainError.busy }
    }

    @discardableResult
    func deleteTrashedNotes(_ ids: [String]) throws -> [String] {
        try requireSceneDeletionAdmission()
        let candidates = Array(Set(ids)).sorted()
        let candidateIDs = Set(candidates)
        let affected = editors.allObjects.filter { editor in
            editor.session.map { candidateIDs.contains($0.noteId) } ?? false
        }
        guard affected.isEmpty || permanentDeletionDrainInFlight || activeSceneFreeze != nil else {
            throw MobileEditorDrainError.busy
        }
        for id in candidates { try sessions[id]?.flush() }
        if !candidates.isEmpty { try clearSharePublication() }
        defer { if !candidates.isEmpty { publishRecentNotes() } }
        // Hide immediately: an asynchronous blank WebKit navigation is not a privacy fence.
        // A transaction failure leaves the saved note intact and the closed page reopenable.
        for editor in affected {
            editor.webView.isHidden = true
            try editor.closeForPrivacy()
        }
        // Fence ALL confirmed candidates, not a pre-read subset of Trash: a restored
        // candidate can be trashed again before the transaction. A skipped live note is
        // kept selected and its closed page can reopen from the shared durable session.
        try beforePermanentDeleteTransactionForTesting?()
        // Core rechecks location atomically. Still-restored notes and IDs outside the
        // confirmation remain untouched, regardless of which pages needed fencing.
        let deleted = try store.emptyTrash(ids: candidates)
        for id in deleted {
            removeSession(id)
            pendingCaret.removeValue(forKey: id)
        }
        for state in sceneStates.values {
            guard let navigation = state.navigation else { continue }
            for id in deleted { navigation.pendingCaret.removeValue(forKey: id) }
            if let callback = navigation.pendingCallbackNavigation, deleted.contains(callback.noteID) {
                navigation.pendingCallbackNavigation = nil
            }
            if let selected = navigation.selectedID, deleted.contains(selected) { navigation.selectedID = nil }
        }
        // Clearing an old automation slot must not broadcast nil into an unrelated scene.
        let wasDispatching = dispatchingLegacyNavigation
        dispatchingLegacyNavigation = true
        defer { dispatchingLegacyNavigation = wasDispatching }
        if let selectedID, deleted.contains(selectedID) { self.selectedID = nil }
        if let callback = pendingCallbackNavigation, deleted.contains(callback.noteID) { pendingCallbackNavigation = nil }
        for id in deleted {
            _ = try store.removeFilesIfDeleted(noteId: id)
            let preview = privatePreviewRoot.appendingPathComponent(id, isDirectory: true)
            if FileManager.default.fileExists(atPath: preview.path) {
                try FileManager.default.removeItem(at: preview)
            }
        }
        return deleted
    }

    /// Uses the same Markdown addressing rules as Mac. Reject stale menu requests and
    /// ambiguous repeated headings instead of copying a link to a different block.
    func headingLink(for request: HeadingMenuRequest) throws -> String? {
        guard selectedID == request.noteId, let note = try store.note(id: request.noteId),
              note.location != .trash, canRead(note) else { return nil }
        let text = try session(for: request.noteId).text
        let metadata = NoteParser.metadata(for: text)
        guard let heading = metadata.headings.first(where: { $0.line == request.line && $0.level == request.level }) else { return nil }
        let earlier = metadata.headings.prefix { $0.line < heading.line }.map(\.text)
        return try? NoteStore.headingLink(forTitle: metadata.title, heading: heading.text, earlierHeadings: earlier).get()
    }

    func togglePin(_ item: NoteListItem) throws {
        try sessions[item.id]?.flush()
        let tag: String? = if case .tag(let path) = scope { path } else { nil }
        try store.setPinned([item.id], pinned: !item.isPinned, inTag: tag)
        _ = try sessions[item.id]?.handleExternalChange()
    }
}
