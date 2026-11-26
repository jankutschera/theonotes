// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Combine
import CryptoKit
import TheoNotesVoice
import Foundation
import os

let appLogger = Logger(subsystem: "com.truebrewbirdie.baerchen", category: "app")

/// Owns the database, the store and every open `NoteSession` (one per note, shared by all windows:
/// every editor showing a note listens to its one session).
@MainActor
final class AppEnvironment: ObservableObject {
    let paths: AppPaths
    let database: AppDatabase
    let store: NoteStore
    let notifier: ChangeNotifier
    /// Decided before the environment exists and fixed for the process.
    let syncPolicy: SyncLaunchPolicy
    /// Whether this build shows the sync setup; false means sync is never started, whatever the launch.
    let syncSetupAvailable: Bool
    private let syncServices: MacSyncServices
    lazy var sync = MacSyncController(
        library: self, policy: syncPolicy, available: syncSetupAvailable, services: syncServices)
    /// Whether this build offers iCloud sync (`ReleaseFeatures.cloudSyncAvailable`, CK-J2); false means nothing of it is ever made.
    let cloudSyncAvailable: Bool
    private let cloudSyncServices: CloudSyncServices
    private var cloudSyncStorage: CloudSyncController?
    /// The iCloud sync controller, made on first use. A build without the flag never asks for it (`cloudSyncStarted` stays false).
    var cloudSync: CloudSyncController {
        if let existing = cloudSyncStorage { return existing }
        let made = CloudSyncController(library: MacCloudSyncLibrary(environment: self), services: cloudSyncServices, available: cloudSyncAvailable)
        // "Move This Library to iCloud" needs the private-server sync of this build.
        if syncSetupAvailable, syncPolicy == .enabled {
            made.leavePrivateServer = { [weak self] withoutMissingFiles in
                guard let self else { throw CancellationError() }
                try await self.sync.leaveForICloud(withoutMissingFiles: withoutMissingFiles)
            }
        }
        cloudSyncStorage = made
        return made
    }
    var cloudSyncStarted: Bool { cloudSyncStorage != nil }
    /// A remote notification for the iCloud sync (`AppDelegate`). Nothing is made for a build without the flag or a switched-off library.
    @discardableResult
    func handleCloudRemoteNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        cloudSyncStorage?.handleRemoteNotification(userInfo) ?? false
    }
    private(set) var syncClosed = false
    /// Backup and restore runs (any window); imports and exports stay out while one is active.
    let operations = LibraryOperationGate()
    /// A restore holds every editor's writes (all windows): `changes` from any editor are refused
    /// until `endEditFreeze()`. Set by `beginEditFreeze()`.
    private(set) var editsFrozen = false
    /// The 24-hour database snapshot loop (`startDailyBackups`).
    private var dailyBackupTask: Task<Void, Never>?
    /// The last snapshot attempt failed; nil after a success. Shown in Settings.
    private(set) var dailyBackupFailure: String?
    /// The protected notes' unlock state for this library: password and Touch ID unlock,
    /// relock on resign, sleep and screen lock. Locked notes' sessions use `vault.access`.
    let vault: NoteVault
    /// The decrypted attachments of locked notes (memory only; emptied on every relock).
    let lockedAttachments: LockedAttachmentMemory
    /// The app-wide lock: at launch, after inactivity and on sleep or screen lock no window
    /// and no automation surface shows library content until the Mac has confirmed its owner.
    let appLock: AppLock
    /// The notification center reminders use; a no-op client unless the app passes the real one.
    let notificationCenter: any NotificationCenterClient
    /// Applies the reminder plan to `notificationCenter` (C14). Made on first use; `init` touches it
    /// to scrub the center before any window exists.
    private(set) lazy var reminders = MacNotificationScheduler(environment: self, center: notificationCenter, now: reminderNow)
    private let reminderNow: () -> Date
    /// The App Group folder the share extension drops items into; nil when this process has none.
    private let shareContainer: URL?
    /// The inbox in that folder, or nil when there is no container or it failed the probe.
    private(set) var shareInbox: CaptureInbox?
    /// What `recent-notes.json` holds now (nil inside: the file is absent), so unchanged lists are not rewritten.
    private var publishedRecentNotes: RecentNotesFile??

    private var sessions: [String: NoteSession] = [:]
    /// Each cached session's history recorder: one per session made by `session(for)`.
    private var recorders: [ObjectIdentifier: SnapshotRecorder] = [:]
    /// Test seams for the recorders made from now on: the idle timer's clock and the snapshots' wall clock.
    var snapshotClock: any Clock<Duration> = ContinuousClock()
    var snapshotNow: @Sendable () -> Date = { .now }
    /// The cached sessions of locked notes: they hold the vault key's copy and a sealed journal,
    /// and are closed on every relock.
    private var keyedSessions: Set<ObjectIdentifier> = []
    /// Each session's conflict-copy listener (removed when the session is dropped).
    private var conflictListeners: [ObjectIdentifier: NoteSession.ListenerToken] = [:]
    private var observation: ObservationToken?
    /// Notes shown in an editor, per window (reported by each window's model). Other sessions
    /// are evicted once they flush clean and no editor listens to them.
    private var openNoteIdsByWindow: [ObjectIdentifier: Set<String>] = [:]
    /// Identifies a conflict-copy observer (see `addConflictCopyObserver`).
    struct ObserverToken: Hashable {
        fileprivate let id: Int
    }
    private var nextObserverId = 0
    /// Every window's handler for the conflict copies sessions make. Copies made while there is
    /// none (launch recovery) wait in `takePendingConflictCopies()`.
    private var conflictCopyObservers: [(token: ObserverToken, handler: (String) -> Void)] = []
    private var pendingConflictCopies: [String] = []
    /// Each session's activity listener (forwarding to `linkUpdater`), by session.
    private var activityListeners: [ObjectIdentifier: NoteSession.ListenerToken] = [:]
    /// Follows in-editor title edits in every window and updates wiki links (spec §3.5, R15).
    private(set) var linkUpdater: LinkUpdater?
    private let editors = NSHashTable<EditorBridgeController>.weakObjects()
    /// The launch recovery steps in the order they ran: the voice recordings are adopted
    /// before the privacy cleanup, which would stop on a journal the voice recovery removes.
    enum LaunchStep: Equatable { case attachments, journals, voiceRecordings, privacyCleanup }
    private(set) var launchSteps: [LaunchStep] = []
    /// Told, on the main actor, whenever a note's lock state may just have changed: after this app locked
    /// or unlocked a note, and on every database change (sync, the CLI, another window). The voice note
    /// panel uses it to drop a locked note's transcript at once.
    private var noteLockStateHandlers: [@MainActor () -> Void] = []
    func addNoteLockStateHandler(_ handler: @escaping @MainActor () -> Void) { noteLockStateHandlers.append(handler) }
    private func noteLockStateMayHaveChanged() { for handler in noteLockStateHandlers { handler() } }

    /// Journals launch recovery could not replay in this launch (moved aside as `*.unreplayed`).
    private(set) var journalsMovedAsideAtLaunch: [URL] = []
    /// Launch recovery removed a voice recording that could not be played; the first window says
    /// so once.
    private var unplayableRecordingRemoved = false
    func takeUnplayableRecordingNotice() -> Bool {
        defer { unplayableRecordingRemoved = false }
        return unplayableRecordingRemoved
    }
    struct RecoveredVariantGroup {
        let noteId: String
        let notes: [Note]
        let retirement: JournalVariantRecovery.Retirement
    }
    struct RecoveredSingleJournal {
        let sourceID: String
        let suffix: String
        let note: Note
        let retirement: MissingJournalRecovery.Retirement
    }
    private(set) var recoveredSingleJournals: [RecoveredSingleJournal] = []
    static let revealRecoveredNote = Notification.Name("TheoNotes.revealRecoveredNote")
    private(set) var recoveredVariantGroups: [RecoveredVariantGroup] = []
    private(set) var variantQuarantineFiles: [String: [String]] = [:]
    private(set) var journalKeyState: JournalRecoveryCoordinator.KeyState?
    private var allowSealedJournalMoveAside = false
    private var keyUnavailableJournalFiles: Set<String> = []
    private(set) var variantRetryNoteIDs: [String] = []
    /// Blocking markers with a Move aside exit (S2/N9).
    private(set) var markerMoveNames: [String] = []
    private(set) var journalRecoveryUncommitted = false
    private var existingReplayFailureIDs: Set<String> = []
    private var unsavedOrphansLogged: Set<String> = []
    /// Set by the app model: a voice note is being set up or recorded.
    var voiceCaptureBusy: @MainActor () -> Bool = { false }
    /// The OCR scheduler (`startOCR`), nil until the app starts it; the CLI never has one.
    private(set) var ocr: OCRScheduler?
    /// Test counter: `handleExternalChange` calls made by `databaseDidChange()`.
    private(set) var externalChangeCallCount = 0

    /// The resolved theme, appearance and typography; every editor follows it (M7 Task 7).
    let appearance: AppearanceController
    /// The offscreen export page for PDF and print (M8 Task 11), made on first use.
    private(set) lazy var renderer = NoteRenderer(environment: self)

    /// The library this launch names (`AppPaths.resolveLaunch`), opened exactly as resolved, with
    /// the launch's sync policy: an explicit `--data-dir` / `BAERCHEN_DATA_DIR` copy is local-only.
    static func launching(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        production: AppPaths = .production,
        systemAppearance: any SystemAppearanceSource = StaticSystemAppearance(),
        applyAppAppearance: @escaping @MainActor (NSAppearance?) -> Void = { _ in },
        notificationCenter: any NotificationCenterClient = NullNotificationCenter(),
        shareContainerURL: @Sendable () -> URL? = { nil },
        afterResolve: () -> Void = {}
    ) throws -> AppEnvironment {
        let launch = try AppPaths.resolveLaunch(arguments: arguments, environment: environment, production: production)
        // The renamed app takes its window and layout preferences from the old defaults domain, once.
        // A no-op while the bundle id is still the old one. Only the default library's launch does it.
        if launch.syncPolicy == .enabled { LegacyPreferencesMigration.runAtLaunch() }
        afterResolve()  // tests remove the resolved folder here, as a competing launch could
        let opened = try AppEnvironment(
            paths: launch.paths, systemAppearance: systemAppearance, applyAppAppearance: applyAppAppearance,
            syncPolicy: launch.syncPolicy, createsLibraryFolder: launch.createsLibraryFolder,
            notificationCenter: notificationCenter,
            shareContainer: Self.shareContainer(
                syncPolicy: launch.syncPolicy, environment: environment, resolve: shareContainerURL))
        // Only a launch that created the library folder (a fresh install) makes the getting
        // started notes; an existing library, a moved one and a `--data-dir` copy never do.
        opened.seedGettingStartedNotes(isNewLibrary: launch.createsLibraryFolder)
        // An existing library gets the new texts for its untouched first-release starters, once.
        opened.upgradeGettingStartedNotes()
        return opened
    }

    /// `linkScheduler` times the link updater's debounce (tests pass a manual one). `systemAppearance` is the
    /// system the look follows; the app passes `LiveSystemAppearance`, tests a fixed (light) or fake one.
    /// `syncPolicy` defaults to `localOnly`: only the app's default-library launch enables sync.
    init(
        paths: AppPaths, linkScheduler: any DebounceScheduler = TaskDebounceScheduler(),
        systemAppearance: any SystemAppearanceSource = StaticSystemAppearance(),
        installedFontFamilies: @escaping @MainActor () -> Set<String> = { Set(NSFontManager.shared.availableFontFamilies) },
        applyAppAppearance: @escaping @MainActor (NSAppearance?) -> Void = { _ in },
        syncPolicy: SyncLaunchPolicy = .localOnly,
        syncSetup: Bool = ReleaseFeatures.syncSetupAvailable(),
        syncServices: MacSyncServices = .live,
        cloudSync: Bool = ReleaseFeatures.cloudSyncAvailable(),
        cloudSyncServices: CloudSyncServices = .live(),
        createsLibraryFolder: Bool = true,
        vaultCache: any VaultKeyCache = KeychainVaultKeyCache(),
        vaultLifecycle: (any VaultLifecycleSource)? = SystemVaultLifecycleSource(),
        appAuthenticator: any AppAuthenticator = LocalAuthenticator(),
        appLockLifecycle: (any VaultLifecycleSource)? = SystemVaultLifecycleSource(),
        appIdleSeconds: @escaping @Sendable () -> TimeInterval = AppLock.systemIdleSeconds,
        notificationCenter: any NotificationCenterClient = NullNotificationCenter(),
        reminderNow: @escaping () -> Date = { .now },
        shareContainer: URL? = nil
    ) throws {
        self.shareContainer = shareContainer
        self.notificationCenter = notificationCenter
        self.reminderNow = reminderNow
        self.syncPolicy = syncPolicy
        self.syncSetupAvailable = syncSetup
        self.syncServices = syncServices
        self.cloudSyncAvailable = cloudSync
        self.cloudSyncServices = cloudSyncServices
        // A launch that resolved an existing library never recreates it as an empty one
        // when it vanished meanwhile (another launch moved it): it is refused instead.
        if !createsLibraryFolder {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: paths.root.path, isDirectory: &isFolder), isFolder.boolValue else {
                throw AppPaths.DataDirectoryError.libraryVanished(paths.root.path)
            }
        }
        try paths.createDirectories()
        self.paths = paths
        database = try AppDatabase(path: paths.database)
        notifier = ChangeNotifier()
        store = NoteStore(db: database, notifier: notifier, paths: paths)
        vault = NoteVault(
            store: store, settings: TheoNotesCore.Settings(db: database), cache: vaultCache,
            account: Self.vaultAccount(for: paths), lifecycle: vaultLifecycle)
        lockedAttachments = LockedAttachmentMemory(store: store, vault: vault)
        appLock = AppLock(
            settings: TheoNotesCore.Settings(db: database), authenticator: appAuthenticator, lifecycle: appLockLifecycle,
            idleSeconds: appIdleSeconds)
        appearance = AppearanceController(
            settings: TheoNotesCore.Settings(db: database), system: systemAppearance,
            installedFamilies: installedFontFamilies, applyToApp: applyAppAppearance)
        observation = notifier.observe { [weak self] in
            Task { @MainActor in self?.databaseDidChange() }
        }
        // R30: a copied attachment link holds its file until the pasteboard changes.
        store.retention.setPasteboardToken { NSPasteboard.general.changeCount }
        recoverAttachments()
        launchSteps.append(.attachments)
        recoverJournals(lockedNotes: false)
        launchSteps.append(.journals)
        // Recordings a voice capture left behind (and the lock cleanups it could not finish) go before
        // the privacy cleanup below, which would stop on the journal of a note locked mid-capture.
        recoverVoiceRecordings()
        linkUpdater = LinkUpdater(environment: self, scheduler: linkScheduler)
        // A change of the resolved look reaches every open editor in place; a new editor starts with it.
        appearance.onLookChange = { [weak self] look in
            self?.editors.allObjects.forEach { $0.setEditorLook(look) }
        }
        // Acknowledged edits of open locked notes are committed (encrypted) before the key goes;
        // right after it is revoked their sessions close, every window shows the lock view and the
        // decrypted attachments are dropped. An unlock replays the sealed journals the launch
        // pass left alone and lets the lock views open their note.
        vault.addWillRelockHandler { [weak self] in
            self?.flushLockedSessions()
            // The history of every open locked note is sealed while the key still exists.
            self?.snapshotLockedSessions()
        }
        vault.addDidRelockHandler { [weak self] in
            self?.closeKeyedSessions()
            self?.scheduleReminderReconcile()
        }
        vault.addDidUnlockHandler { [weak self] in
            self?.vaultDidUnlock()
            self?.scheduleReminderReconcile()
        }
        vault.addRelockBarrier { [weak self] in await self?.waitForEditorsToClear() }
        // Engaging App Lock saves what was typed and takes the note key away, like a relock.
        appLock.addDidLockHandler { [weak self] in
            self?.flushAll()
            self?.vault.relock()
            // A capture window that was still being opened is stale now: no window will cancel the
            // empty note, so it is cancelled here.
            self?.cancelCapturesAwaitingAWindow()
            self?.scheduleReminderReconcile()
        }
        // Turning App Lock on or off in Settings redacts or restores the reminders at once.
        appLock.addEnabledChangeHandler { [weak self] enabled in
            guard let self else { return }
            if enabled { reminders.coldLaunchScrub() }
            scheduleReminderReconcile()
            // The picker's note titles leave the shared folder before this call returns.
            publishRecentNotes()
        }
        // A lock a crash left half finished is completed before the library is shown.
        launchSteps.append(.privacyCleanup)
        vault.recoverAtLaunch()
        // Locked and deleted notes' reminders (and all of them under App Lock) leave the notification
        // center by id, synchronously, before the first window.
        reminders.coldLaunchScrub()
        // The share extension's container is probed and, while App Lock is enabled, its titles file is
        // removed before any window exists.
        openShareContainer()
    }

    /// The Keychain account of a library's cached note key: a digest of its folder, so two
    /// libraries never share an item and the name carries no path.
    static func vaultAccount(for paths: AppPaths) -> String {
        let digest = SHA256.hash(data: Data(paths.root.standardizedFileURL.path.utf8))
        return "library-" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Commits the acknowledged text of every open session whose note is locked; run by the
    /// vault right before it revokes the access those sessions write through.
    private func flushLockedSessions() {
        for session in sessions.values where keyedSessions.contains(ObjectIdentifier(session)) {
            flush(session)
        }
    }

    /// Takes the closing snapshot of every open locked note's session, right before the vault revokes
    /// the key. The text was committed by `flushLockedSessions` just before.
    private func snapshotLockedSessions() {
        for session in sessions.values where keyedSessions.contains(ObjectIdentifier(session)) {
            recorders[ObjectIdentifier(session)]?.sessionWillClose()
        }
    }

    /// The recorder of a cached session; nil for a session `session(for:)` did not make.
    func recorder(for session: NoteSession) -> SnapshotRecorder? { recorders[ObjectIdentifier(session)] }
    var recorderCount: Int { recorders.count }

    /// The session is closing with its text saved: the history gets its closing snapshot, then the
    /// recorder is done. A failure (revoked access, a note that is gone) is swallowed by the recorder.
    private func closeRecorder(of session: NoteSession) {
        guard let recorder = recorders.removeValue(forKey: ObjectIdentifier(session)) else { return }
        recorder.sessionWillClose()
        recorder.stop()
    }

    /// The session is closing without a snapshot: its note is gone, locked elsewhere, or the key is.
    private func discardRecorder(of session: NoteSession) {
        recorders.removeValue(forKey: ObjectIdentifier(session))?.stop()
    }

    /// How many cached sessions are keyed (open locked notes).
    var keyedSessionCount: Int { keyedSessions.count }
    /// Sessions that exist now (none before a note is opened) and editors that registered (none before a window shows one).
    var openSessionCount: Int { sessions.count }
    var registeredEditorCount: Int { editors.count }

    func isKeyedSession(_ session: NoteSession) -> Bool { keyedSessions.contains(ObjectIdentifier(session)) }

    /// Test seam: makes the next commit of a session fail.
    var sessionFlushFault: ((String) -> Error?)?

    /// Test seam: makes opening a session for a note fail (not cached yet).
    var sessionOpenFault: ((String) -> Error?)?

    /// Test seam: what the sealed-journal replay after an unlock runs on each session.
    var journalReplayFlush: (NoteSession) throws -> Void = { try $0.flush() }

    /// Waits until every editor confirmed that its page dropped the locked note it showed (or
    /// replaced the page because it did not).
    func waitForEditorsToClear() async {
        for editor in editors.allObjects { await editor.waitUntilCleared() }
    }

    /// Logs a failure on a note's session. A keyed session's error can carry a protected file
    /// name, so only its case code is logged.
    func logSessionFailure(_ what: String, noteId: String, keyed: Bool, error: Error) {
        if keyed {
            appLogger.error("note \(noteId, privacy: .public): \(what, privacy: .public): \(PrivacyErrorCode.code(for: error), privacy: .public)")
        } else {
            appLogger.error("note \(noteId, privacy: .public): \(what, privacy: .public): \(error)")
        }
    }

    /// Whether `noteId` is a locked note and the vault is locked: it cannot be opened, so its
    /// editor shows the lock view.
    func isLockedBehindVault(_ noteId: String) -> Bool {
        let note = (try? store.note(id: noteId)) ?? nil
        if case .locked = EditorPaneContent.for(note: note, vaultUnlocked: vault.isUnlocked) { return true }
        return false
    }

    /// After a relock: every session of a locked note is dropped (its key copy with it), each
    /// editor showing one is replaced by the placeholder and the decrypted attachments go.
    private func closeKeyedSessions() {
        for session in sessions.values where keyedSessions.contains(ObjectIdentifier(session)) {
            discardRecorder(of: session)  // snapshotted in the will-relock handler; the key is gone now
            uncache(session, cleanUp: false)
            editors.allObjects.forEach { $0.sessionClosed(session) }
            release(session)
            session.removeAllListeners()
        }
        lockedAttachments.clear()
    }

    /// After an unlock: the sealed journals of locked notes are replayed and committed, then the
    /// editors waiting behind a lock view open their note.
    private func vaultDidUnlock() {
        recoverJournals(lockedNotes: true)
        editors.allObjects.forEach { $0.vaultDidUnlock() }
    }

    /// The launch sweep of the attachment cleanup (ruling R23), off the main thread; the app
    /// starts it once the UI is up (`AppDelegate.applicationDidFinishLaunching`). Notes that open
    /// meanwhile are skipped (`retention`), and fresh files stay for the grace period.
    @discardableResult
    func sweepAttachments() -> Task<Int, Never> {
        let store = store
        return Task.detached(priority: .utility) {
            let removed = store.removeUnreferencedAttachments()
            if removed > 0 { appLogger.notice("launch: \(removed) unreferenced attachment file(s) removed") }
            return removed
        }
    }

    /// Starts text recognition of attachments for `@ocr` search (app process only, off the main
    /// thread, throttled): see `OCRScheduler`. Called once the UI is up; tests do not call it.
    func startOCR(extractor: any TextExtracting = AttachmentTextExtractor()) {
        guard ocr == nil else { return }
        let texts = AttachmentTextStore(database: database)
        let queue = OCRQueue(
            store: texts, files: AttachmentStore(paths: paths, database: database), extractor: extractor)
        let scheduler = OCRScheduler(worker: queue, store: texts)
        scheduler.start()
        ocr = scheduler
    }

    /// Quit: stops the OCR triggers; the queue drops what waits (there is one library per run, so
    /// there is no library change to handle).
    func stopOCR() {
        ocr?.stop()
    }

    /// Completes or discards attachment batches a crash left in `Attachments/.staging/`, and
    /// repairs conflict copies whose files were not all copied. Batches another process (CLI, MCP)
    /// is still writing are locked and skipped (M2 ruling R9).
    private func recoverAttachments() {
        do {
            let recovery = try AttachmentFiles(paths: paths, database: database).recover()
            if recovery != AttachmentFiles.Recovery() {
                appLogger.notice("""
                    attachment recovery: \(recovery.installed) installed, \(recovery.discarded) discarded, \
                    \(recovery.skipped) skipped (locked), \(recovery.failedRenames) renames and \(recovery.failedCopies) copies failed
                    """)
            }
        } catch {
            appLogger.error("attachment recovery failed: \(error)")
        }
    }

    /// Attaches the recordings a voice capture left in `Recordings/` to their notes, deletes the rest
    /// and finishes the cleanups a capture could not finish after its note was locked
    ///). A file that cannot be removed stays for the next launch; that is logged (a count,
    /// no note) and the launch goes on.
    private func recoverVoiceRecordings() {
        launchSteps.append(.voiceRecordings)
        do {
            let attached = try VoiceRecordingRecovery.adoptLeftovers(
                store: store, attachments: AttachmentStore(paths: paths, database: database), directory: paths.recordings,
                onUnreadableRemoved: { _ in unplayableRecordingRemoved = true })
            if attached > 0 { appLogger.notice("voice recording recovery: \(attached) recording(s) attached") }
        } catch VoiceRecoveryError.notRemoved(let count, _) {
            appLogger.error("voice recording recovery: \(count) file(s) could not be removed; the next launch retries")
        } catch {
            appLogger.error("voice recording recovery failed: \(PrivacyErrorCode.code(for: error), privacy: .public)")
        }
    }

    /// After a crash, acked edits may sit only in `Journal/<noteId>.jsonl`. Replaying them now
    /// (instead of when the note is next opened) keeps the list, previews and indexer current.
    /// The journal of a locked note is sealed with the vault key: the launch pass leaves it alone
    /// (`lockedNotes: false`) and the unlock replays it (`lockedNotes: true`). Everything else
    /// (missing notes, moved-aside files, markers) is decided by the shared Core coordinator.
    private func recoverJournals(lockedNotes: Bool) {
        let movedAsideBefore = Set(movedAsideJournals())
        defer { journalsMovedAsideAtLaunch = movedAsideJournals().filter { !movedAsideBefore.contains($0) } }
        do { try resumeConfirmedJournalQuarantines() }
        catch { appLogger.notice("A confirmed recovery file move needs to finish") }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: paths.journal.path)) ?? [] where name.hasSuffix(".jsonl") {
            let noteId = String(name.dropLast(".jsonl".count))
            let size = (try? paths.journal.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            // A note this environment has open already replayed its journal; never open a second
            // writer for it (the foreground retry runs while notes are open).
            guard size ?? 0 > 0, sessions[noteId] == nil, let note = (try? store.note(id: noteId)) ?? nil,
                  note.isLocked == lockedNotes else { continue }
            do {
                // Opening the session replays the journal; the flush commits what it recovered.
                let session = try makeSession(noteId)
                defer { release(session) }
                try (lockedNotes ? journalReplayFlush : { try $0.flush() })(session)
                existingReplayFailureIDs.remove(noteId)
            } catch JournalVariantRecovery.Failure.requiresKey, JournalVariantRecovery.Failure.partialReplayBlocked,
                    JournalVariantRecovery.Failure.unavailable {
                // A variant marker fences this note only; the coordinator reports it.
            } catch {
                // Ruling 12: one note's failure never stops the others or relocks the vault.
                existingReplayFailureIDs.insert(noteId)
                appLogger.error("journal replay of note \(noteId, privacy: .public) failed: \(PrivacyErrorCode.code(for: error), privacy: .public)")
            }
        }
        refreshJournalRecovery()
    }

    /// Thin adapter over `JournalRecoveryCoordinator` (the same one iOS uses): it publishes the
    /// report for Settings ▸ Advanced and the sync gate; no classification happens here.
    func refreshJournalRecovery() {
        // N12: a kept-open deleted note's text is retried here too (launch, unlock, foreground,
        // sync gate), not only on a database change.
        closeSessionsOfDeletedNotes()
        let live = NoteSession.liveSessionIDs(journalDirectory: paths.journal)
        do {
            let report = try JournalRecoveryCoordinator.recover(store: store, access: vault.access, liveSessionIDs: live,
                dirtyLiveSessionIDs: live, existingReplayFailureIDs: existingReplayFailureIDs,
                allowSealedMoveAside: allowSealedJournalMoveAside)
            recoveredSingleJournals = report.singles.map { .init(sourceID: $0.sourceID, suffix: $0.suffix, note: $0.note, retirement: $0.retirement) }
            recoveredVariantGroups = report.variants.map { .init(noteId: $0.sourceID, notes: $0.notes, retirement: $0.retirement) }
            variantQuarantineFiles = Dictionary(grouping: report.quarantineFiles) {
                $0.components(separatedBy: ".jsonl")[0].components(separatedBy: ".base")[0]
            }
            keyUnavailableJournalFiles = Set(report.keyUnavailableFiles)
            journalKeyState = report.keyState
            variantRetryNoteIDs = report.failedSourceIDs
            markerMoveNames = report.markerMoves
            journalRecoveryUncommitted = report.hasUncommittedRecovery
        } catch {
            journalRecoveryUncommitted = true
            appLogger.error("journal recovery could not run: \(PrivacyErrorCode.code(for: error), privacy: .public)")
        }
    }

    func offerSealedJournalMoveAside() {
        allowSealedJournalMoveAside = true
        refreshJournalRecovery()
    }

    /// Q2: right after a password reset removed the vault, plain unsaved text of deleted notes is
    /// saved through the existing plain recovery path and its session closes normally. A crash
    /// before this loses the RAM-only text (accepted residual).
    func savePlainOrphansAfterPasswordReset() {
        var saved: [String] = []
        for session in sessions.values where !session.wasOriginallyLocked && !session.isInvalidated &&
            Data(session.text.utf8) != Data(session.committedText.utf8) && ((try? store.note(id: session.noteId)) ?? nil) == nil {
            do {
                let copy = try session.preserveBrowserRecoveryResult(text: session.text, baseRevision: session.revision)
                if copy.created { reportConflictCopy(copy.note.id) }
                saved.append(session.noteId)
            } catch {
                appLogger.error("unsaved text of a removed note was not saved after the reset: \(PrivacyErrorCode.code(for: error), privacy: .public)")
            }
        }
        _ = try? closeSessions(ids: saved) {}
    }
    func hasCachedSession(for id: String) -> Bool { sessions[id] != nil }

    enum JournalRecoverySyncBlock: LocalizedError {
        case unlockRequired, waitingForSyncKey, uncommitted
        var errorDescription: String? {
            switch self {
            case .unlockRequired: "Some recovered edits need your notes password. Unlock your notes, then sync again."
            case .waitingForSyncKey: "Some recovered edits are waiting for the notes key from another device. Enter your notes password in Sync settings."
            case .uncommitted: "Some edits could not be recovered yet. See Settings ▸ Advanced; sync resumes once they are saved."
            }
        }
    }

    /// Ruling 6/S9: only an uncommitted recovery or a journal that still lacks a key blocks a sync;
    /// saved recovery copies with an open notice do not.
    func requireJournalRecoveryReadyForSync() throws {
        refreshJournalRecovery()
        if let journalKeyState { throw journalKeyState == .waitingForSyncKey ? JournalRecoverySyncBlock.waitingForSyncKey : .unlockRequired }
        if journalRecoveryUncommitted { throw JournalRecoverySyncBlock.uncommitted }
    }

    /// Forgotten-password reset (ruling 7, round 4): refuse during a voice capture; under the writer
    /// re-check every pair, source and live holder and invalidate the holders; close their editors;
    /// unlink journal before base. The caller flushed and quiesced sync before.
    func discardJournalsForPasswordReset(_ plan: MissingJournalRecovery.ResetDiscardPlan) throws {
        guard !voiceCaptureBusy() else { throw BackupError.pendingFiles }
        try MissingJournalRecovery.validateDiscardsAndInvalidate(plan.items.map(\.token), store: store, matching: plan.sessionFence)
        for session in plan.noteIDs.compactMap({ sessions[$0] }) {
            discardRecorder(of: session)
            uncache(session, cleanUp: false)
            editors.allObjects.forEach { $0.sessionClosed(session) }
            release(session)
            session.removeAllListeners()
        }
        for item in plan.items { try MissingJournalRecovery.discardLeftoverAfterConfirmation(item.token, store: store) }
        refreshJournalRecovery()
    }

    /// The cached session for `noteId`, created (and recovered from its journal) on first use.
    /// While cached, the session's note keeps its attachment files (`NoteStore.retention`): its
    /// unsaved text or the editor's undo history may link them again.
    func session(for noteId: String) throws -> NoteSession {
        if let session = sessions[noteId] { return session }
        if let error = sessionOpenFault?(noteId) { throw error }
        // Retained before the session exists: its recovery may already link files.
        store.retention.retain(noteId)
        let session: NoteSession
        do {
            session = try makeSession(noteId)
        } catch {
            store.retention.release(noteId)
            throw error
        }
        sessions[noteId] = session
        recorders[ObjectIdentifier(session)] = SnapshotRecorder(
            session: session, writer: snapshotWriter(for: session), clock: snapshotClock, now: snapshotNow)
        return session
    }

    /// `NoteStore` takes the plaintext history of an unlocked note and refuses a locked one; a keyed
    /// session writes through the vault's access, which seals.
    private func snapshotWriter(for session: NoteSession) -> any SnapshotWriting {
        if keyedSessions.contains(ObjectIdentifier(session)), let access = vault.access { return access }
        return store
    }

    /// Drops a cached session; its note's unreferenced attachment files may go now (the cleanup
    /// on eviction, ruling R23). Only sessions without an attached editor are evicted, flushed
    /// and clean (`evictUnopenedSessions`), so no editor can have un-acked changes for them; a
    /// file whose link is still on its way is covered by the cleanup's 10-minute grace period.
    private func uncache(_ session: NoteSession, cleanUp: Bool) {
        guard sessions[session.noteId] === session else { return }
        sessions[session.noteId] = nil
        store.retention.release(session.noteId)
        if cleanUp { store.removeUnreferencedAttachments(noteId: session.noteId) }
    }

    private func makeSession(_ noteId: String) throws -> NoteSession {
        let session: NoteSession
        if ((try? store.note(id: noteId)) ?? nil)?.isLocked == true {
            // A locked note edits through the vault's access: encrypted commits, sealed journal.
            guard let access = vault.access else { throw StoreError.noteLocked(id: noteId) }
            session = try NoteSession(
                noteId: noteId, store: access, journalDirectory: paths.journal, journalKey: try access.journalKey())
            keyedSessions.insert(ObjectIdentifier(session))
        } else {
            session = try NoteSession(noteId: noteId, store: store, journalDirectory: paths.journal)
        }
        conflictListeners[ObjectIdentifier(session)] = session.addConflictCopyListener { [weak self] in
            self?.reportConflictCopy($0)
        }
        activityListeners[ObjectIdentifier(session)] = session.addActivityListener { [weak self] activity in
            self?.linkUpdater?.sessionActivity(noteId, activity)
            self?.ocr?.sessionActivity(noteId, activity)
        }
        if let copy = session.recoveryConflictCopyId { reportConflictCopy(copy) }
        return session
    }

    /// A session that is no longer cached stops reporting conflict copies.
    private func release(_ session: NoteSession) {
        closeRecorder(of: session)
        keyedSessions.remove(ObjectIdentifier(session))
        if let token = conflictListeners.removeValue(forKey: ObjectIdentifier(session)) {
            session.removeListener(token)
        }
        if let token = activityListeners.removeValue(forKey: ObjectIdentifier(session)) {
            session.removeListener(token)
        }
    }

    func reportConflictCopy(_ noteId: String) {
        appLogger.notice("conflict copy \(noteId, privacy: .public) created")
        guard !conflictCopyObservers.isEmpty else { return pendingConflictCopies.append(noteId) }
        for observer in conflictCopyObservers {
            guard conflictCopyObservers.contains(where: { $0.token == observer.token }) else { continue }
            observer.handler(noteId)
        }
    }

    /// Every main window registers one; each gets every conflict copy made from now on.
    @discardableResult
    func addConflictCopyObserver(_ handler: @escaping (String) -> Void) -> ObserverToken {
        nextObserverId += 1
        let token = ObserverToken(id: nextObserverId)
        conflictCopyObservers.append((token, handler))
        return token
    }

    func removeConflictCopyObserver(_ token: ObserverToken) {
        conflictCopyObservers.removeAll { $0.token == token }
    }

    /// Every main window's handler for a tag rename (or its undo) made in any window: its
    /// selected tag and workspace follow (instead of the window losing them).
    private var tagRenameObservers: [(token: ObserverToken, handler: (_ old: String, _ new: String) -> Void)] = []

    @discardableResult
    func addTagRenameObserver(_ handler: @escaping (_ old: String, _ new: String) -> Void) -> ObserverToken {
        nextObserverId += 1
        let token = ObserverToken(id: nextObserverId)
        tagRenameObservers.append((token, handler))
        return token
    }

    func removeTagRenameObserver(_ token: ObserverToken) {
        tagRenameObservers.removeAll { $0.token == token }
    }

    /// Tag `old` (and its descendants) is now called `new`: every main window follows.
    func tagRenamed(from old: String, to new: String) {
        for observer in tagRenameObservers {
            guard tagRenameObservers.contains(where: { $0.token == observer.token }) else { continue }
            observer.handler(old, new)
        }
    }

    /// Conflict copies made while no observer was registered; cleared by the call.
    func takePendingConflictCopies() -> [String] {
        defer { pendingConflictCopies = [] }
        return pendingConflictCopies
    }

    /// Every journal kept for manual recovery (`<noteId>.jsonl.unreplayed[.n]`; its base record
    /// sits beside it as `<noteId>.base.unreplayed[.n]`).
    func movedAsideJournals() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.journal.path)) ?? []
        return names.filter { $0.contains(".jsonl.unreplayed") }.sorted().map { paths.journal.appendingPathComponent($0) }
    }

    func abortedJournalNoteIDs() throws -> [String] {
        try JournalVariantRecovery.abortedNoteIDs(store: store)
    }
    func pendingVariantNoteIDs() throws -> [String] {
        try JournalVariantRecovery.pendingNoteIDs(store: store)
    }
    func retryJournalRecovery() { recoverJournals(lockedNotes: vault.isUnlocked) }
    func openRecoveredSingle(_ notice: RecoveredSingleJournal) throws {
        guard recoveredSingleJournals.contains(where: { $0.sourceID == notice.sourceID && $0.suffix == notice.suffix && $0.note.id == notice.note.id }),
              let row = try store.note(id: notice.note.id), row.deletedAt == nil else { throw JournalVariantRecovery.Failure.changed }
        NotificationCenter.default.post(name: Self.revealRecoveredNote, object: self, userInfo: ["noteID": notice.note.id])
    }
    func removeRecoveredSingleAfterConfirmation(_ notice: RecoveredSingleJournal) throws {
        guard sessions[notice.sourceID] == nil, try store.note(id: notice.sourceID) == nil,
              recoveredSingleJournals.contains(where: { $0.sourceID == notice.sourceID && $0.suffix == notice.suffix && $0.note.id == notice.note.id }) else { throw JournalVariantRecovery.Failure.changed }
        guard let row = try store.note(id: notice.note.id), row.deletedAt == nil else {
            // The saved copy was removed after review. Preserve the source and create a fresh
            // generation before asking the user to review another removal.
            recoverJournals(lockedNotes: vault.isUnlocked)
            throw JournalVariantRecovery.Failure.changed
        }
        try MissingJournalRecovery.removeLeftover(notice.retirement, access: vault.access)
        recoverJournals(lockedNotes: vault.isUnlocked)
    }
    func removeVariantGroupAfterConfirmation(_ group: RecoveredVariantGroup) throws {
        guard sessions[group.noteId] == nil,
              recoveredVariantGroups.contains(where: { $0.noteId == group.noteId && $0.notes.map(\.id) == group.notes.map(\.id) }) else { throw JournalVariantRecovery.Failure.changed }
        try JournalVariantRecovery.removeAfterConfirmation(group.retirement, store: store, access: vault.access)
        recoverJournals(lockedNotes: vault.isUnlocked)
    }
    struct VariantQuarantinePlan {
        let noteId: String
        let files: [String]
        let includesUnavailableKeyFiles: Bool
        let selection: JournalQuarantine.Selection
    }
    func prepareVariantQuarantine(noteId: String) throws -> VariantQuarantinePlan {
        guard sessions[noteId] == nil, let files = variantQuarantineFiles[noteId], !files.isEmpty else { throw JournalVariantRecovery.Failure.changed }
        return VariantQuarantinePlan(noteId: noteId, files: files, includesUnavailableKeyFiles: !keyUnavailableJournalFiles.isDisjoint(with: files), selection: try JournalQuarantine.inspect(libraryRoot: paths.root, fileNames: files))
    }
    func prepareMarkerQuarantine(markerName: String) throws -> VariantQuarantinePlan {
        guard markerMoveNames.contains(markerName) else { throw JournalVariantRecovery.Failure.changed }
        return VariantQuarantinePlan(noteId: markerName, files: [markerName], includesUnavailableKeyFiles: false,
                                     selection: try JournalQuarantine.inspectMarker(store: store, markerName: markerName))
    }
    func moveVariantFilesAfterConfirmation(_ plan: VariantQuarantinePlan) throws -> URL {
        // The coordinator offers Move aside only after recovery was tried; nothing is probed here.
        refreshJournalRecovery()
        guard sessions[plan.noteId] == nil, variantQuarantineFiles[plan.noteId] == plan.files ||
                (plan.files == [plan.noteId] && markerMoveNames.contains(plan.noteId)) else { throw JournalVariantRecovery.Failure.changed }
        let directory = try JournalQuarantine.moveAfterConfirmation(plan.selection, store: store)
        if try JournalVariantRecovery.abortedSourceFiles(noteId: plan.noteId, store: store).isEmpty {
            try JournalVariantRecovery.clearResolvedAbortedSourceFiles(noteId: plan.noteId, store: store)
        }
        existingReplayFailureIDs.remove(plan.noteId)
        recoverJournals(lockedNotes: vault.isUnlocked)
        return directory
    }
    func resumeConfirmedJournalQuarantines() throws {
        guard sessions.isEmpty else { throw JournalVariantRecovery.Failure.unavailable }
        let root = paths.root.appendingPathComponent("Recovery/Quarantine", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        for directory in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(".confirmation.json").path),
                  !FileManager.default.fileExists(atPath: directory.appendingPathComponent(".completed").path) else { continue }
            try JournalQuarantine.resumeConfirmed(JournalQuarantine.confirmed(libraryRoot: paths.root, directory: directory), store: store)
        }
        for id in try abortedJournalNoteIDs() where try JournalVariantRecovery.abortedSourceFiles(noteId: id, store: store).isEmpty {
            try JournalVariantRecovery.clearResolvedAbortedSourceFiles(noteId: id, store: store)
        }
    }

    /// Permanently deleting notes that may be open: flushes their sessions, runs `delete`, and only
    /// if it succeeds drops the sessions of notes that are gone and tells every editor showing one
    /// of them to let go (so late edits cannot recreate a journal). A note `delete` skipped (Empty
    /// Trash on a note restored meanwhile) keeps its session. If `delete` throws, every session
    /// stays cached and attached — still one session per note.
    func closeSessions<T>(ids: [String], deleting delete: () throws -> T) throws -> T {
        let closing = ids.compactMap { sessions[$0] }
        closing.forEach { flush($0) }
        let result = try delete()
        for session in closing where Self.noteIsGone({ try store.revision(id: session.noteId) }) {
            discardRecorder(of: session)
            uncache(session, cleanUp: false)
            editors.allObjects.forEach { $0.sessionClosed(session) }
            release(session)
            session.removeAllListeners()
        }
        return result
    }

    /// Runs `change` (a lock or a lock removal) on each note with its open session closed around
    /// it, in two phases. Phase 1: the text is committed (an uncommitted one skips the
    /// note), every editor showing the note switches to the placeholder and its page confirms it
    /// dropped the text (or is replaced and the replacement committed). Phase 2: the session is
    /// dropped so the store no longer holds the note's files (`retention`), `change` runs, and
    /// every editor that showed the note opens it again, keyed or plain as it now is. Returns the
    /// errors by note id; a failed change leaves the note as it was and its editors reopen it.
    func changingLockState(of ids: [String], _ change: (String) throws -> Void) async -> [String: Error] {
        var failures: [String: Error] = [:]
        for id in ids {
            guard let session = sessions[id] else {
                do { try change(id) } catch { failures[id] = error }
                noteLockStateMayHaveChanged()
                publishRecentNotes()
                continue
            }
            guard flush(session), TextNormalization.identical(session.text, session.committedText) else {
                failures[id] = NoteLockChangeError.unsavedText
                continue
            }
            let showing = editors.allObjects.filter { $0.suspendForLockChange(session) }
            for editor in showing { await editor.waitUntilCleared() }
            // Edits that arrived while the pages were clearing are committed too. If they cannot
            // be, the session stays cached and the editors take it up again unchanged.
            guard sessions[id] === session, flush(session), TextNormalization.identical(session.text, session.committedText) else {
                failures[id] = NoteLockChangeError.unsavedText
                for editor in showing { editor.resumeAfterLockChange(noteId: id) }
                continue
            }
            // The history gets the text as it is, through the writer of the lock state it has now: a
            // lock seals it in its own transaction, a removal opens it.
            closeRecorder(of: session)
            uncache(session, cleanUp: false)
            do { try change(id) } catch { failures[id] = error }
            noteLockStateMayHaveChanged()
            // A locked note's title leaves the share list before this call returns; an unlocked one is offered again.
            publishRecentNotes()
            for editor in showing { editor.resumeAfterLockChange(noteId: id) }
            release(session)
            session.removeAllListeners()
        }
        return failures
    }

    /// Whether a note is gone after a delete: only a successful read without the note says so. A
    /// read error keeps the session (treating it as deleted would drop unsaved text).
    static func noteIsGone(_ revision: () throws -> Int?) -> Bool {
        do {
            return try revision() == nil
        } catch {
            appLogger.error("could not check a note after a delete; its session stays: \(error)")
            return false
        }
    }

    /// Sessions whose note is gone although nobody went through `closeSessions` (another process
    /// deleted it): dropped the same way, so every editor lets go and late edits find no session
    /// (and write no journal).
    func closeSessionsOfDeletedNotes() {
        let gone = sessions.keys.filter { id in
            do {
                return try store.note(id: id) == nil
            } catch {
                return false // unreadable right now: keep the session
            }
        }
        guard !gone.isEmpty else { return }
        // Q3: unsaved text of a deleted note is saved as a recovery note first, through the same
        // calls iOS uses (sealed with the key; plain only where the plain path allows it). A session
        // whose text cannot be saved yet stays open; the recovery notice and the next pass take over.
        let closable = gone.filter { id in
            guard let session = sessions[id], Data(session.text.utf8) != Data(session.committedText.utf8) else { return true }
            do {
                let copy: BrowserRecoveryResult
                // S7: the store revision the journal's base records, so a later journal pass finds
                // this copy instead of making a second one.
                let base = session.committedStoreRevision
                if let access = vault.access {
                    copy = session.wasOriginallyLocked
                        ? try access.preserveProtectedBrowserRecovery(noteId: id, text: session.text, baseRevision: base, now: .now)
                        : try access.preserveBrowserRecovery(noteId: id, text: session.text, baseRevision: base, now: .now)
                } else {
                    guard !session.wasOriginallyLocked else { return false }  // protected text never goes plain
                    copy = try session.preserveBrowserRecoveryResult(text: session.text, baseRevision: base)
                }
                if copy.created { reportConflictCopy(copy.note.id) }
                unsavedOrphansLogged.remove(id)
                return true
            } catch {
                if unsavedOrphansLogged.insert(id).inserted {  // N14: once per note
                    appLogger.notice("unsaved text of a deleted note stays open until it can be saved: \(PrivacyErrorCode.code(for: error), privacy: .public)")
                }
                return false
            }
        }
        guard !closable.isEmpty else { return }
        appLogger.notice("\(closable.count) open notes were deleted elsewhere; closing their sessions")
        _ = try? closeSessions(ids: closable) {}
    }

    /// Editors to notify when a session they may show is closed (held weakly).
    func registerEditor(_ controller: EditorBridgeController) {
        editors.add(controller)
    }

    /// The notes shown in all windows.
    var openNoteIds: Set<String> {
        openNoteIdsByWindow.values.reduce(into: Set<String>()) { $0.formUnion($1) }
    }

    /// The notes `window` shows now (empty once it closed). Sessions no window shows and no
    /// editor listens to are evicted once they flush clean.
    func setOpenNoteIds(_ ids: Set<String>, for window: ObjectIdentifier) {
        openNoteIdsByWindow[window] = ids.isEmpty ? nil : ids
        linkUpdater?.watch(openNoteIds)
        evictUnopenedSessions()
    }

    private func evictUnopenedSessions() {
        let open = openNoteIds
        for (id, session) in sessions where !open.contains(id) && session.textListenerCount == 0 {
            guard flush(session), TextNormalization.identical(session.text, session.committedText) else { continue }
            uncache(session, cleanUp: true)
            release(session)
        }
    }

    @discardableResult
    private func flush(_ session: NoteSession) -> Bool {
        do {
            if let fault = sessionFlushFault?(session.noteId) { throw fault }
            try session.flush()
            return true
        } catch {
            // Code only: the error of a locked note's session can carry a protected attachment name.
            appLogger.error("flush of note \(session.noteId, privacy: .public) failed: \(PrivacyErrorCode.code(for: error), privacy: .public)")
            return false
        }
    }

    /// Commits the acknowledged text of `noteId`'s open session and nothing else: other sessions stay
    /// as they are and none is evicted, so no history snapshot is taken as a side effect. True when
    /// the note has no open session or its session is clean afterwards.
    @discardableResult
    func flushSession(noteId: String) -> Bool {
        guard let session = sessions[noteId] else { return true }
        return flush(session) && TextNormalization.identical(session.text, session.committedText)
    }

    /// Asks every editor showing `noteId` whether its document is the session's text, so an editor
    /// transaction still on its way (typed, not yet acknowledged) is not missed. False
    /// when an editor differs or cannot answer in time.
    func confirmEditorsInSync(noteId: String) async -> Bool {
        for editor in editors.allObjects where editor.session?.noteId == noteId {
            guard await editor.confirmInSync() else { return false }
        }
        return true
    }

    /// True when an editor other than `editor` shows `noteId` (another window of the same note).
    func anotherEditorShows(noteId: String, besides editor: EditorBridgeController) -> Bool {
        editors.allObjects.contains { $0 !== editor && $0.session?.noteId == noteId }
    }

    /// Notes whose open session holds text the store does not have yet (e.g. a flush failed).
    var unsavedNoteIds: Set<String> {
        Set(sessions.values.filter { !TextNormalization.identical($0.text, $0.committedText) }.map(\.noteId))
    }

    /// An already open session; never creates one.
    func existingSession(for noteId: String) -> NoteSession? {
        sessions[noteId]
    }

    // MARK: - Opened and captured notes (focus layer)

    /// Notes whose next editor load is not an open: the load that directly follows a capture.
    private var unrecordedOpens: Set<String> = []
    /// Notes Capture Thought just made whose window has been requested but is not open yet.
    private var capturesAwaitingAWindow: Set<String> = []
    /// Notes made by Capture Thought whose own window is open (it cancels the capture when it closes).
    private var captureWindows: Set<String> = []

    /// The next editor load of `noteId` is not an open.
    func suppressOpenRecord(noteId: String) {
        unrecordedOpens.insert(noteId)
    }

    /// True once, if `noteId`'s load was suppressed; it is spent either way.
    func consumeOpenRecordSuppression(_ noteId: String) -> Bool {
        unrecordedOpens.remove(noteId) != nil
    }

    /// An editor loaded `noteId`: stores `lastOpenedAt`. A failure is logged and ignored;
    /// opening a note never fails because of it.
    func recordOpened(noteId: String) {
        do {
            try store.recordOpened(noteId: noteId)
        } catch {
            appLogger.error("could not record that note \(noteId, privacy: .public) was opened: \(error)")
        }
    }

    /// `noteId` was just made by Capture Thought and its window is on the way.
    func registerCaptureWindow(noteId: String) {
        capturesAwaitingAWindow.insert(noteId)
    }

    /// The window of `noteId` opened: from now on closing it cancels an untouched capture.
    func captureWindowOpened(noteId: String) {
        if capturesAwaitingAWindow.remove(noteId) != nil { captureWindows.insert(noteId) }
    }

    /// True once, if `noteId` has an open capture window that was not closed yet.
    func takeCaptureWindow(noteId: String) -> Bool {
        captureWindows.remove(noteId) != nil
    }

    /// True while `noteId` is a capture whose window is on the way or open.
    func holdsCapture(noteId: String) -> Bool {
        capturesAwaitingAWindow.contains(noteId) || captureWindows.contains(noteId)
    }

    /// Drops the capture bookkeeping of `noteId` (its window could not be requested).
    func abandonCapture(noteId: String) {
        unrecordedOpens.remove(noteId)
        capturesAwaitingAWindow.remove(noteId)
        captureWindows.remove(noteId)
    }

    /// App Lock engaged: the window requests of that moment are stale and never open, so no window
    /// will close and cancel their empty notes. Cancels them now (a note someone typed into stays).
    private func cancelCapturesAwaitingAWindow() {
        let waiting = capturesAwaitingAWindow
        capturesAwaitingAWindow = []
        unrecordedOpens = []
        for noteId in waiting { cancelCapture(noteId: noteId) }
    }

    /// The one entry point for cancelling a capture in the app: moves the captured note
    /// to the Trash if its stored text is still the empty text the capture was created with. The
    /// note's session is committed first and a note whose session cannot be committed stays, so
    /// text that only the session holds is never cancelled away. Callers decide *whether* a
    /// capture may be cancelled (a window that never opened: nothing could have been typed; a
    /// closed capture window: `AppModel.captureWindowClosed`, after its editor answered).
    func cancelCapture(noteId: String) {
        guard flushSession(noteId: noteId) else { return }
        do {
            try store.cancelCapture(noteId: noteId, createdText: "")
        } catch {
            appLogger.error("could not cancel a captured note: \(error)")
        }
    }

    /// Commits the acknowledged text of every open session. Editor transactions still in flight
    /// (sent but not yet acked) are not covered; the editor sends each transaction immediately.
    func flushAll() {
        for session in sessions.values {
            flush(session)
        }
        evictUnopenedSessions()
    }

    /// Sync only holds the main actor for the acknowledged-edit flush and local commit.
    /// Downloads and cryptography happen outside this boundary, so writing stays responsive.
    func flushForSync() throws {
        guard !syncClosed else { throw CancellationError() }
        for session in sessions.values { try session.flush() }
    }

    func makeBackup() async throws -> URL {
        try flushForSync()
        let backup = LibraryBackup(database: database, paths: paths)
        // LibraryBackup takes a consistent writer snapshot and verifies every manifest hash
        // before it publishes the rolling backup. A journal arriving meanwhile aborts safely.
        return try await Task.detached(priority: .userInitiated) {
            let archive = try backup.createRolling()
            _ = try backup.inspect(archive)
            return archive
        }.value
    }

    /// Stops every editor in every window from writing, then commits what the sessions hold. From
    /// here to `endEditFreeze()` an editor transaction gets `needsFullText` and reaches neither a
    /// session nor a journal, so a restore cannot be overwritten by a late edit from another
    /// window. Main-actor and synchronous: no editor message is handled between the freeze and the
    /// flush. Returns whether every session is clean now.
    @discardableResult
    func beginEditFreeze() -> Bool {
        editsFrozen = true
        flushAll()
        return unsavedNoteIds.isEmpty
    }

    /// Lifts the freeze and reconciles every window at once: sessions of notes that vanished
    /// close, sessions of changed notes take the external change, and an editor that had an edit
    /// refused reloads its note.
    func endEditFreeze() {
        guard editsFrozen else { return }
        editsFrozen = false
        databaseDidChange()
        editors.allObjects.forEach { $0.editsUnfrozen() }
    }

    /// The daily database snapshot (`LibraryBackup.createDailyDatabaseSnapshot`, newest 7 kept):
    /// taken now when the newest one is older than 24 hours, otherwise nothing. Runs off the main
    /// actor. A failure is logged and kept in `dailyBackupFailure`; the notes are not affected.
    @discardableResult
    func runDailyBackupIfDue() async -> URL? {
        let backup = LibraryBackup(database: database, paths: paths)
        do {
            let url = try await Task.detached(priority: .utility) { try backup.createDailyDatabaseSnapshot() }.value
            dailyBackupFailure = nil
            if let url { appLogger.notice("daily snapshot saved: \(url.lastPathComponent, privacy: .public)") }
            return url
        } catch {
            dailyBackupFailure = error.localizedDescription
            appLogger.error("daily snapshot failed: \(error)")
            return nil
        }
    }

    /// At launch and then every `interval` while the app runs (the app passes the default 24 h).
    func startDailyBackups(interval: Duration = .seconds(86_400)) {
        guard dailyBackupTask == nil else { return }
        dailyBackupTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runDailyBackupIfDue()
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    func stopDailyBackups() {
        dailyBackupTask?.cancel()
        dailyBackupTask = nil
    }

    /// An explicit note-unlock action: unlocks the protected notes with the Note Password and
    /// keeps them unlocked until the vault relocks.
    func unlockNotes(password: String) async throws {
        try await vault.unlock(password: password)
    }

    /// Password check without unlocking anything (the first-sync safety step): a
    /// temporary access is made and revoked at once; the vault and its Keychain cache are untouched.
    func verifyNotePassword(_ password: String) async throws {
        let privacy = NotePrivacy(store: store)
        let access = try await Task.detached(priority: .userInitiated) { try privacy.unlock(password: password) }.value
        access.revoke()
    }

    func synchronize(using engine: SyncEngine, notePassword: String? = nil,
                     remoteNotePassword: String? = nil, exclusive: Bool = false) async throws -> SyncRunSummary {
        try flushForSync()
        try requireJournalRecoveryReadyForSync()
        let privacy = NotePrivacy(store: store)
        let access: LockedNoteAccess?
        if let notePassword {
            access = try await Task.detached(priority: .userInitiated) {
                do { return try privacy.unlock(password: notePassword) }
                catch CryptoError.wrongPassword {
                    guard let remoteNotePassword, remoteNotePassword != notePassword else { throw CryptoError.wrongPassword }
                    return try privacy.unlock(password: remoteNotePassword)
                }
            }.value
        } else { access = nil }
        defer { access?.revoke() }
        return try await engine.synchronize(noteAccess: access, remoteNotePassword: remoteNotePassword ?? notePassword)
    }

    func commitSyncedChange(_ change: @Sendable () throws -> SyncApplyResult) throws -> SyncApplyResult {
        try flushForSync()
        let before = try Dictionary(uniqueKeysWithValues: sessions.keys.compactMap { id in
            try store.note(id: id).map { (id, $0.isLocked) }
        })
        let envelopeBefore = try? NotePrivacy(store: store).envelope()
        // Even a file-install error can follow a durable database write. Reconcile on either path.
        defer {
            // A password envelope adopted or changed by sync makes the cached note key stale.
            if (try? NotePrivacy(store: store).envelope()) != envelopeBefore {
                do { try vault.envelopeReplaced() } catch {
                    appLogger.error("cached note key not removed after an envelope change: \(PrivacyErrorCode.code(for: error), privacy: .public)")
                }
            }
            for (id, wasLocked) in before {
                guard let session = sessions[id] else { continue }
                if let next = try? store.note(id: id), next.isLocked == wasLocked { continue }
                discardRecorder(of: session)  // the lock state changed under it; sync owns the history now
                uncache(session, cleanUp: false)
                editors.allObjects.forEach { $0.sessionClosed(session) }
                release(session)
                session.removeAllListeners()
            }
            databaseDidChange()
            notifier.post()
        }
        return try change()
    }

    /// A local-only library, or a build without the sync setup, starts nothing: no scheduler, observer, timer or retry loop.
    func startSync() {
        guard syncPolicy == .enabled else { return }
        if syncSetupAvailable { sync.setActive(true) }
        // iCloud sync: made only in a build with the flag, and it does nothing until the person has turned it on.
        if cloudSyncAvailable { Task { await cloudSync.start() } }
    }
    func stopSync() {
        syncClosed = true
        sync.stopScheduling()
        Task { await sync.shutdown() }
        if let cloud = cloudSyncStorage { Task { await cloud.shutdown() } }
    }

    /// Another process (or this one) wrote to the database; open sessions reconcile with the store.
    /// A session already at the store's revision is skipped (e.g. the echo of its own commit).
    /// Brings the notification center in line with the reminders, off the caller's turn. Typing alone
    /// (`sweep: false`) does not enumerate the center.
    func scheduleReminderReconcile(sweep: Bool = true) {
        Task { [weak self] in await self?.reminders.reconcile(sweep: sweep) }
    }

    // MARK: - Share inbox (focus layer C17,...)

    /// The App Group of the macOS share extension: the team id, a dot and the group name, which is how
    /// a macOS group is written. Both entitlements files take it from the build setting
    /// `THEONOTES_APP_GROUP`, which the build configuration sets for the identity: the dev
    /// build never shares a container with the installed app.
    nonisolated static var shareGroupIdentifier: String { AppIdentity.current.appGroupIdentifier }
    /// Set to `1` to give a launch with its own `--data-dir` library the shared container (testing).
    static let shareContainerEnvironmentKey = "THEONOTES_SHARE_CONTAINER"

    /// The container this launch uses: the default library's, or any other library's only when asked
    /// for, so a throw-away library never takes the items meant for the real one.
    static func shareContainer(
        syncPolicy: SyncLaunchPolicy, environment: [String: String], resolve: @Sendable () -> URL?
    ) -> URL? {
        guard syncPolicy == .enabled || environment[shareContainerEnvironmentKey] == "1" else { return nil }
        return resolve()
    }

    /// The system's folder for `shareGroupIdentifier`. On macOS the URL comes back even for a group the
    /// app is not part of, so `openShareContainer` probes it.
    nonisolated static func liveShareContainer() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: shareGroupIdentifier)
    }

    var sharingEnabled: Bool { shareInbox != nil }

    /// Probes the container (a write, read and delete of a probe file) and, when it works, publishes the
    /// titles file for the current App Lock setting. A container that fails the probe turns sharing off
    /// for this run: logged, never fatal.
    private func openShareContainer() {
        guard let shareContainer else { return }
        guard SharedContainerFiles.validate(container: shareContainer) else {
            appLogger.error("sharing is off: the App Group container could not be used")
            return
        }
        shareInbox = CaptureInbox(directory: shareContainer.appendingPathComponent("CaptureInbox", isDirectory: true))
        publishRecentNotes(force: true)
    }

    /// Writes (or, with App Lock enabled, deletes) `recent-notes.json`. `force` writes even when the list
    /// is the one published before; launch uses it to replace a file an earlier run left.
    func publishRecentNotes(force: Bool = false) {
        guard shareInbox != nil, let shareContainer else { return }
        do {
            let file = try RecentNotesFile.make(store: store, appLockEnabled: appLock.isEnabled)
            if !force, let published = publishedRecentNotes, published == file { return }
            try SharedContainerFiles.publish(file, in: shareContainer)
            publishedRecentNotes = .some(file)
        } catch {
            appLogger.error("could not update the share list: \(PrivacyErrorCode.code(for: error), privacy: .public)")
        }
    }

    /// Applies what the extension queued: at launch and whenever the app becomes active. Open
    /// sessions are committed first, so an append to an open note merges into a clean session instead of
    /// racing the typed text; every window then follows through `databaseDidChange`. Returns the ids of
    /// the notes the items ended in.
    @discardableResult
    func drainShareInbox() -> [String] {
        guard let shareInbox else { return [] }
        // A note whose open session cannot be committed keeps its appends in the inbox.
        var unsaved: Set<String> = []
        for session in sessions.values where !(flush(session) && TextNormalization.identical(session.text, session.committedText)) {
            unsaved.insert(session.noteId)
        }
        do {
            let ids = try shareInbox.drain(
                into: store, attachments: AttachmentStore(paths: paths, database: database), holdingAppendsTo: unsaved)
            if !ids.isEmpty { databaseDidChange() }
            return ids
        } catch {
            appLogger.error("share inbox drain failed: \(PrivacyErrorCode.code(for: error), privacy: .public)")
            return []
        }
    }

    /// The app came to the front.
    func applicationDidBecomeActive() {
        drainShareInbox()
        retryJournalRecovery()  // ruling 5: a failed or waiting recovery retries on every foreground
    }

    func databaseDidChange() {
        noteLockStateMayHaveChanged()
        closeSessionsOfDeletedNotes()
        scheduleReminderReconcile(sweep: false)
        publishRecentNotes()
        // Note titles (completion) and tags (TagCons) in the editors may be stale.
        editors.allObjects.forEach { $0.databaseDidChange() }
        for session in sessions.values {
            do {
                guard let revision = try store.revision(id: session.noteId),
                      revision != session.committedStoreRevision else { continue }
                externalChangeCallCount += 1
                let outcome = try session.handleExternalChange()
                if outcome != .unchanged {
                    appLogger.notice("note \(session.noteId, privacy: .public): external change \(String(describing: outcome), privacy: .public)")
                }
            } catch {
                logSessionFailure("external change failed", noteId: session.noteId, keyed: isKeyedSession(session), error: error)
            }
        }
    }
}
