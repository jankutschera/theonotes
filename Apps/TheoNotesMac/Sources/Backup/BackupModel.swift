// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import GRDB
import Observation
import Synchronization
import UniformTypeIdentifiers

/// The file type of a full backup (`.theonotes-backup`, declared in Info.plist). Backups made before
/// stage 2 (`.baerchen-backup`) are still opened: the old type is an imported declaration in Info.plist.
enum BackupFileType {
    static let identifier = "com.truebrewbirdie.theonotes.backup"
    static let fileExtension = "theonotes-backup"
    static let legacyIdentifier = LegacyNames.backupUTI
    static let legacyFileExtension = LegacyNames.backupExtension

    /// The declared types; the extension types are added to the panels as well, so a panel still
    /// accepts the files when Launch Services has not learnt the declarations yet.
    static var allowedTypes: [UTType] {
        [UTType(exportedAs: identifier, conformingTo: .zip), UTType(importedAs: legacyIdentifier, conformingTo: .zip)]
            + [fileExtension, legacyFileExtension].compactMap { UTType(filenameExtension: $0) }
    }
}

/// Counts the backup and restore runs of all windows of one library. Observable, so menu items
/// that read it re-validate when a run starts or ends.
@MainActor
@Observable
final class LibraryOperationGate {
    private(set) var active = 0
    var isBusy: Bool { active > 0 }

    func begin() { active += 1 }
    func end() { active = max(0, active - 1) }
}

/// File ▸ Backup Notes… and File ▸ Restore Backup…, on the one backup format
/// (`LibraryBackup`). One run at a time per library; the store work runs on a detached
/// task, like `ImportModel`. Open editors are flushed first.
@MainActor
@Observable
final class BackupModel {
    /// A chosen backup that passed `LibraryBackup.inspect`.
    struct OpenedBackup: Equatable, Sendable {
        let url: URL
        let summary: BackupSummary

        /// "12 notes (2 archived, 3 in Trash, 1 locked), 3 attachments, made 26 Oct 2026 at 14:05".
        /// The note count includes archived and trashed notes; the bracket only names what is there.
        var summaryLine: String {
            var notes = Self.count(summary.noteCount, "note")
            var kinds: [String] = []
            if summary.archivedNoteCount > 0 { kinds.append("\(summary.archivedNoteCount) archived") }
            if summary.trashedNoteCount > 0 { kinds.append("\(summary.trashedNoteCount) in Trash") }
            if summary.lockedNoteCount > 0 { kinds.append("\(summary.lockedNoteCount) locked") }
            if !kinds.isEmpty { notes += " (\(kinds.joined(separator: ", ")))" }
            let made = summary.createdAt.formatted(date: .abbreviated, time: .shortened)
            return "\(notes), \(Self.count(summary.attachmentCount, "attachment")), made \(made)"
        }

        /// Set when the backup was made without some attachment files.
        var missingFilesLine: String? {
            summary.missingAttachmentCount == 0
                ? nil
                : "\(Self.count(summary.missingAttachmentCount, "attachment file")) were already missing when this backup was made. Their links are kept, the files are not in the backup."
        }

        private static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
    }

    /// What the report sheet shows after a restore.
    struct RestoreReport: Equatable {
        let mode: BackupRestoreMode
        let restored: Int
        let keptExisting: Int
        let safetyBackup: URL?

        var headline: String {
            switch mode {
            case .merge:
                return "Added \(restored) \(restored == 1 ? "note" : "notes"). \(keptExisting) already here and stayed as they were."
            case .replaceAll:
                return "Replaced the library with \(restored) \(restored == 1 ? "note" : "notes") from the backup."
            }
        }
    }

    /// The question Replace All asks before it deletes anything.
    struct ReplaceConfirmation: Equatable {
        let currentCount: Int
        let backupCount: Int

        var title: String { "Replace all notes?" }
        private static func notes(_ n: Int) -> String { n == 1 ? "1 note" : "\(n) notes" }
        var message: String {
            "All \(Self.notes(currentCount)) in this library, including the Trash, will be deleted and replaced with the \(Self.notes(backupCount)) in the backup. A safety backup of your current notes is saved to the Backups folder first."
        }
    }

    enum Phase: Equatable {
        case idle
        /// A save or open panel is up.
        case choosing
        case backingUp
        case backedUp(URL)
        /// A chosen archive is being verified.
        case reading(URL)
        /// The restore sheet: summary and the Merge / Replace All choice.
        case review(OpenedBackup)
        case restoring(BackupRestoreMode)
        case restored(RestoreReport)
        /// Cancel stopped a restore before it wrote anything; the notes are as they were.
        case cancelled
        /// The run did not finish; the message is shown. For a restore the library is unchanged,
        /// except when the message says notes were restored already.
        case failed(String)
    }

    typealias SavePanel = @MainActor (_ suggestedName: String) async -> URL?
    typealias OpenPanel = @MainActor () async -> URL?
    /// Runs the restore off the main actor, inside the calling task (so cancelling the task
    /// cancels it); `afterCommit` is called once the database transaction has committed.
    typealias RestoreRunner = @Sendable (
        LibraryBackup, URL, BackupRestoreMode, String?, String?, @escaping @Sendable () -> Void
    ) throws -> BackupRestoreResult

    nonisolated static let liveRestoreRunner: RestoreRunner = { backup, url, mode, backupPassword, currentPassword, afterCommit in
        try backup.restore(
            url, mode: mode, backupPassword: backupPassword, currentPassword: currentPassword,
            afterCommit: afterCommit)
    }

    private(set) var phase: Phase = .idle
    /// The choice in the restore sheet. Merge is the default.
    var mode: BackupRestoreMode = .merge
    /// Replace All was chosen and waits for the answer.
    private(set) var confirmation: ReplaceConfirmation?
    /// A merge needs the passwords of a backup with locked notes under another password.
    private(set) var needsPasswords = false
    var backupPassword = ""
    var currentPassword = ""
    /// Cancel works until the restore commits; false from then on (and outside a restore).
    /// Read synchronously off the commit flag, which the commit callback sets on its own thread
    /// before anything else can run, so no Cancel is offered or accepted after the commit.
    var canCancelRestore: Bool { cancelOffered && !commitFlag.isSet }
    private var cancelOffered = false
    @ObservationIgnored private let commitFlag = CommitFlag()

    @ObservationIgnored private let restoreRunner: RestoreRunner
    @ObservationIgnored private let environment: AppEnvironment
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let savePanel: SavePanel
    @ObservationIgnored private let openPanel: OpenPanel
    @ObservationIgnored private let didChange: @MainActor () -> Void
    @ObservationIgnored private let isBlockedElsewhere: @MainActor () -> Bool
    @ObservationIgnored private var holdsGate = false
    @ObservationIgnored private(set) var runTask: Task<Void, Never>?

    /// - Parameters:
    ///   - didChange: runs after a restore changed the library (refreshes the window).
    ///   - isBlockedElsewhere: an import or an export of this window runs.
    init(
        environment: AppEnvironment, now: @escaping () -> Date = { .now },
        savePanel: @escaping SavePanel = { await BackupPanels.save(suggestedName: $0) },
        openPanel: @escaping OpenPanel = { await BackupPanels.open() },
        didChange: @escaping @MainActor () -> Void = {},
        isBlockedElsewhere: @escaping @MainActor () -> Bool = { false },
        restoreRunner: @escaping RestoreRunner = BackupModel.liveRestoreRunner
    ) {
        self.restoreRunner = restoreRunner
        self.environment = environment
        self.now = now
        self.savePanel = savePanel
        self.openPanel = openPanel
        self.didChange = didChange
        self.isBlockedElsewhere = isBlockedElsewhere
    }

    /// A run, a panel or a sheet of this window is up.
    var isBusy: Bool { phase != .idle }

    /// Another backup or restore (in any window), an import or an export blocks a start.
    var canStart: Bool { phase == .idle && !environment.operations.isBusy && !isBlockedElsewhere() }

    /// The sheet shows for every phase except idle and the panels.
    var showsSheet: Bool {
        switch phase {
        case .idle, .choosing: false
        default: true
        }
    }

    /// Whether the sheet can be closed now (not while a backup or restore writes).
    var canDismiss: Bool {
        switch phase {
        case .backingUp, .restoring: false
        default: true
        }
    }

    // MARK: - Backup Notes…

    static func defaultFileName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "Theo Notes Backup \(formatter.string(from: date)).\(BackupFileType.fileExtension)"
    }

    /// File ▸ Backup Notes…: asks where to save, then writes the whole library.
    func backUp() {
        guard canStart else { return }
        setPhase(.choosing)
        let name = Self.defaultFileName(now())
        runTask = Task { [weak self] in
            guard let self else { return }
            guard let destination = await self.savePanel(name) else { return self.setPhase(.idle) }
            await self.write(to: destination)
        }
    }

    private func write(to destination: URL) async {
        environment.flushAll()
        guard environment.unsavedNoteIds.isEmpty else { return setPhase(.failed(BackupError.pendingEdits.localizedDescription)) }
        setPhase(.backingUp)
        let backup = LibraryBackup(database: environment.database, paths: environment.paths)
        let result = await Task.detached(priority: .userInitiated) { () -> Result<Void, BackupFailure> in
            do { return .success(try Self.publish(backup, to: destination)) }
            catch { return .failure(BackupFailure(error)) }
        }.value
        switch result {
        case .success: setPhase(.backedUp(destination))
        case .failure(let failure): setPhase(.failed(failure.message))
        }
    }

    /// Writes next to the destination under a temporary name, checks the archive, then moves it
    /// into place (replacing a file the save panel let the user overwrite). A failure leaves the
    /// previous file untouched.
    nonisolated static func publish(_ backup: LibraryBackup, to destination: URL) throws {
        let fm = FileManager.default
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")
        defer { try? fm.removeItem(at: partial) }
        try backup.create(at: partial)
        _ = try backup.inspect(partial)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: partial)
        } else {
            try fm.moveItem(at: partial, to: destination)
        }
    }

    // MARK: - Restore Backup…

    /// File ▸ Restore Backup…: asks for the file, verifies it, then shows the restore sheet.
    func chooseBackupToRestore() {
        guard canStart else { return }
        setPhase(.choosing)
        runTask = Task { [weak self] in
            guard let self else { return }
            guard let url = await self.openPanel() else { return self.setPhase(.idle) }
            await self.open(url)
        }
    }

    func open(_ url: URL) async {
        setPhase(.reading(url))
        let backup = LibraryBackup(database: environment.database, paths: environment.paths)
        let result = await Task.detached(priority: .userInitiated) { () -> Result<BackupSummary, BackupFailure> in
            do { return .success(try backup.inspect(url)) }
            catch { return .failure(BackupFailure(error)) }
        }.value
        switch result {
        case .success(let summary):
            mode = .merge
            needsPasswords = false
            clearPasswords()
            setPhase(.review(OpenedBackup(url: url, summary: summary)))
        case .failure(let failure):
            setPhase(.failed(failure.message))
        }
    }

    /// The sheet's Restore button: Merge runs now, Replace All asks first.
    func requestRestore() {
        guard case .review(let opened) = phase else { return }
        switch mode {
        case .merge:
            restore(opened, mode: .merge)
        case .replaceAll:
            confirmation = ReplaceConfirmation(
                currentCount: (try? liveNoteCount()) ?? 0, backupCount: opened.summary.noteCount)
        }
    }

    func confirmReplace() {
        guard confirmation != nil, case .review(let opened) = phase else { return }
        confirmation = nil
        restore(opened, mode: .replaceAll)
    }

    func cancelReplace() { confirmation = nil }

    /// Merge adds the notes the library lacks and keeps everything else. Replace All first saves a
    /// safety backup of the current notes (inside `LibraryBackup.restore`, before anything is
    /// written; if that fails nothing is restored), then replaces the library.
    func restore(_ opened: OpenedBackup, mode: BackupRestoreMode) {
        guard case .review = phase else { return }
        confirmation = nil
        // Every window's editors stop writing first, then the sessions commit.
        guard environment.beginEditFreeze() else {
            environment.endEditFreeze()
            return setPhase(.failed(BackupError.pendingEdits.localizedDescription))
        }
        setPhase(.restoring(mode))
        commitFlag.reset()
        cancelOffered = true
        let backup = LibraryBackup(database: environment.database, paths: environment.paths)
        let backupPassword = self.backupPassword.isEmpty ? nil : self.backupPassword
        let currentPassword = self.currentPassword.isEmpty ? nil : self.currentPassword
        let runner = restoreRunner, flag = commitFlag
        runTask = Task { [weak self] in
            let result = await Self.runOffMain(
                runner, backup, opened.url, mode, backupPassword, currentPassword,
                afterCommit: {
                    flag.set() // synchronous: Cancel is a no-op from this instant
                    Task { @MainActor in self?.restoreCommitted() }
                })
            self?.finishRestore(result, opened: opened, mode: mode)
        }
    }

    /// Structured: runs in the awaiting task, so `runTask.cancel()` reaches the restore's
    /// cooperative checks. A nonisolated async function runs off the main actor.
    private nonisolated static func runOffMain(
        _ runner: RestoreRunner, _ backup: LibraryBackup, _ url: URL, _ mode: BackupRestoreMode,
        _ backupPassword: String?, _ currentPassword: String?, afterCommit: @escaping @Sendable () -> Void
    ) async -> Result<BackupRestoreResult, BackupFailure> {
        do {
            return .success(try runner(backup, url, mode, backupPassword, currentPassword, afterCommit))
        } catch { return .failure(BackupFailure(error)) }
    }

    private func restoreCommitted() {
        cancelOffered = false // lets the sheet re-render; `canCancelRestore` was already false
    }

    /// The sheet's Cancel while restoring: stops the restore if it has not committed yet. After the
    /// commit the restore finishes (the button is disabled then).
    func cancelRestore() {
        guard case .restoring = phase, canCancelRestore else { return }
        runTask?.cancel()
    }

    private func finishRestore(_ result: Result<BackupRestoreResult, BackupFailure>, opened: OpenedBackup, mode: BackupRestoreMode) {
        clearPasswords()
        cancelOffered = false
        // One central reconcile for every window: vanished notes close, changed ones reload.
        defer { environment.endEditFreeze() }
        switch result {
        case .success(let restored):
            environment.databaseDidChange()
            didChange()
            setPhase(.restored(RestoreReport(
                mode: mode, restored: restored.restored, keptExisting: restored.keptExisting,
                safetyBackup: restored.safetyBackup)))
        case .failure(let failure):
            if failure.isCancellation {
                didChange()
                setPhase(.cancelled)
            } else if failure.needsPasswords {
                needsPasswords = true
                setPhase(.review(opened))
            } else {
                // The files of a restore that already committed can still be pending.
                environment.databaseDidChange()
                didChange()
                setPhase(.failed(failure.message))
            }
        }
    }

    /// Closes the sheet; not while a backup or restore writes.
    func dismiss() {
        guard canDismiss else { return }
        confirmation = nil
        needsPasswords = false
        clearPasswords()
        setPhase(.idle)
    }

    // MARK: - Helpers

    /// The notes a Replace All deletes: every note of the library, the Trash included.
    func liveNoteCount() throws -> Int {
        try environment.database.pool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note WHERE deletedAt IS NULL") ?? 0
        }
    }

    private func clearPasswords() {
        backupPassword = ""
        currentPassword = ""
    }

    private func setPhase(_ next: Phase) {
        phase = next
        if next == .idle {
            if holdsGate { environment.operations.end(); holdsGate = false }
        } else if !holdsGate {
            environment.operations.begin()
            holdsGate = true
        }
    }
}

/// Set once by the restore's commit callback (any thread), read by the main actor.
final class CommitFlag: Sendable {
    private let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    func reset() { value.withLock { $0 = false } }
    var isSet: Bool { value.withLock { $0 } }
}

/// A failure as plain text (an `Error` does not cross the detached task as a value).
struct BackupFailure: Error, Sendable {
    let message: String
    let needsPasswords: Bool
    let isCancellation: Bool

    init(_ error: any Error) {
        message = error.localizedDescription
        needsPasswords = (error as? BackupError) == .passwordsRequired
        isCancellation = error is CancellationError
    }
}

extension AppEnvironment {
    /// When the newest daily database snapshot was taken (Settings ▸ Advanced ▸ Backups).
    func lastDailyBackupDate() -> Date? {
        try? database.pool.read {
            try Date.fetchOne($0, sql: "SELECT MAX(createdAt) FROM backup_catalog WHERE filename LIKE '%.sqlite'")
        }
    }
}

/// The save and open panels of the two commands.
@MainActor
enum BackupPanels {
    static func save(suggestedName: String) async -> URL? {
        let panel = NSSavePanel()
        panel.title = "Backup Notes"
        panel.message = "Save a full copy of your notes, tags and attachments."
        panel.prompt = "Save Backup"
        panel.allowedContentTypes = BackupFileType.allowedTypes
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        return await present(panel) { $0.url }
    }

    static func open() async -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Restore Backup"
        panel.message = "Choose a Theo Notes backup file."
        panel.prompt = "Choose"
        panel.allowedContentTypes = BackupFileType.allowedTypes
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return await present(panel) { $0.url }
    }

    private static func present<P: NSSavePanel>(_ panel: P, url: @escaping (P) -> URL?) async -> URL? {
        await withCheckedContinuation { continuation in
            let handler: (NSApplication.ModalResponse) -> Void = { response in
                let chosen = response == .OK ? url(panel) : nil
                continuation.resume(returning: chosen)
            }
            if let window = NSApp.keyWindow {
                panel.beginSheetModal(for: window, completionHandler: handler)
            } else {
                panel.begin(completionHandler: handler)
            }
        }
    }
}
