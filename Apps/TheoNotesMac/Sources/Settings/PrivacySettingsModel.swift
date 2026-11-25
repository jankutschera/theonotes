// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Observation

/// The state and actions behind Settings ▸ Privacy (M9M-R65..R70). Every action goes through the
/// vault and the core, never around them; nothing here logs a password or a note.
@MainActor
@Observable
final class PrivacySettingsModel {
    enum ChangeResult: Equatable {
        case changed, noPassword, emptyNew, mismatch, wrongOld
        /// Anything else; the pane says the password was not changed.
        case failed
    }

    /// What typing it takes to reset: a word on purpose, not a button.
    static let resetPhrase = "reset"

    private(set) var usesTouchID: Bool
    private(set) var touchIDError: String?
    private(set) var noteRelockDelay: Int
    private(set) var appLockDelay: Int
    private(set) var appLockMessage: String?
    private(set) var status: NotePasswordResetStatus?
    private(set) var resetError: String?
    private(set) var isResetting = false
    var resetPhrase = ""

    @ObservationIgnored private let vault: NoteVault
    @ObservationIgnored private let privacy: NotePrivacy
    @ObservationIgnored private let settings: TheoNotesCore.Settings
    @ObservationIgnored private let appLock: AppLock
    @ObservationIgnored private let flush: @MainActor () -> Void
    @ObservationIgnored private let quiesceSync: @MainActor () async -> Bool
    @ObservationIgnored private let resumeSync: @MainActor () -> Void
    @ObservationIgnored private let prepareJournalDiscard: @MainActor () -> MissingJournalRecovery.ResetDiscardPlan?
    @ObservationIgnored private let discardJournals: @MainActor (MissingJournalRecovery.ResetDiscardPlan) throws -> Void
    @ObservationIgnored private let afterPasswordRemoved: @MainActor () -> Void
    /// Protected recovery files or unsaved text of deleted notes that only a confirmed reset may
    /// discard (ruling 7); the sheet asks once, naming the notes.
    private(set) var pendingJournalDiscard: MissingJournalRecovery.ResetDiscardPlan?

    /// `quiesceSync`, `flush` and `resumeSync` are what a reset must do around the vault. The barrier
    /// comes first: it blocks new sync runs and returns once the running one has ended (false: it did
    /// not end), so nothing syncs a half-finished reset; then open edits are saved; `resumeSync`
    /// balances the barrier whatever happened.
    init(
        vault: NoteVault, store: NoteStore, settings: TheoNotesCore.Settings, appLock: AppLock,
        flush: @escaping @MainActor () -> Void = {}, quiesceSync: @escaping @MainActor () async -> Bool = { true },
        resumeSync: @escaping @MainActor () -> Void = {},
        prepareJournalDiscard: @escaping @MainActor () -> MissingJournalRecovery.ResetDiscardPlan? = { nil },
        discardJournals: @escaping @MainActor (MissingJournalRecovery.ResetDiscardPlan) throws -> Void = { _ in },
        afterPasswordRemoved: @escaping @MainActor () -> Void = {}
    ) {
        self.vault = vault
        privacy = NotePrivacy(store: store)
        self.settings = settings
        self.appLock = appLock
        self.flush = flush
        self.quiesceSync = quiesceSync
        self.resumeSync = resumeSync
        self.prepareJournalDiscard = prepareJournalDiscard
        self.discardJournals = discardJournals
        self.afterPasswordRemoved = afterPasswordRemoved
        usesTouchID = settings.useTouchIDForNotes
        noteRelockDelay = settings.noteRelockDelay
        appLockDelay = appLock.delay
        refreshStatus()
    }

    convenience init(environment: AppEnvironment) {
        self.init(
            vault: environment.vault, store: environment.store, settings: TheoNotesCore.Settings(db: environment.database),
            appLock: environment.appLock,
            flush: { environment.flushAll() },
            quiesceSync: { await environment.sync.quiesce() },
            resumeSync: { environment.sync.endQuiesce() },
            prepareJournalDiscard: { try? MissingJournalRecovery.prepareResetDiscard(store: environment.store) },
            discardJournals: { try environment.discardJournalsForPasswordReset($0) },
            afterPasswordRemoved: { environment.savePlainOrphansAfterPasswordReset() })
    }

    // MARK: Note Password

    var hasPassword: Bool { vault.hasPassword }
    var canChangePassword: Bool { vault.hasPassword }

    /// Checks the three fields, then changes the password through the vault (the stored Touch ID key
    /// is replaced or removed there). Only the wrapped key changes; locked notes stay as they are.
    func changePassword(old: String, new: String, confirm: String) async -> ChangeResult {
        guard vault.hasPassword else { return .noPassword }
        guard !new.isEmpty else { return .emptyNew }
        guard new == confirm else { return .mismatch }
        do {
            try await vault.changePassword(old: old, new: new)
            return .changed
        } catch CryptoError.wrongPassword {
            return .wrongOld
        } catch {
            appLogger.error("note password change failed: \(PrivacyErrorCode.code(for: error), privacy: .public)")
            return .failed
        }
    }

    // MARK: Touch ID for notes

    var touchIDSupported: Bool { vault.biometricUnlockSupported }

    func setUsesTouchID(_ enabled: Bool) {
        touchIDError = nil
        do {
            try vault.setUsesBiometricUnlock(enabled)
        } catch {
            appLogger.error("touch id option not changed: \(PrivacyErrorCode.code(for: error), privacy: .public)")
            touchIDError = enabled
                ? "Touch ID could not be turned on. Your Note Password still works."
                : "The stored key could not be removed, so Touch ID stays on. Try again."
        }
        usesTouchID = settings.useTouchIDForNotes
    }

    // MARK: Delays

    var noteRelockOptions: [Int] { TheoNotesCore.Settings.noteRelockDelayOptions }
    var appLockOptions: [Int] { TheoNotesCore.Settings.appLockDelayOptions }

    func setNoteRelockDelay(_ seconds: Int) {
        settings.noteRelockDelay = seconds
        noteRelockDelay = settings.noteRelockDelay
    }

    func setAppLockDelay(_ seconds: Int) {
        appLock.setDelay(seconds)
        appLockDelay = appLock.delay
    }

    static func label(forDelay seconds: Int) -> String {
        switch seconds {
        case 0: "Immediately"
        case 60: "1 minute"
        case 3600: "1 hour"
        default: "\(seconds / 60) minutes"
        }
    }

    // MARK: App Lock

    var appLockEnabled: Bool { appLock.isEnabled }

    func setAppLockEnabled(_ enabled: Bool) async {
        appLockMessage = nil
        switch await appLock.setEnabled(enabled) {
        case .enabled, .disabled, .cancelled: break
        case .unavailable:
            appLockMessage = "This Mac cannot confirm who you are, so App Lock stays off. Set a login password in System Settings first."
        case .failed:
            appLockMessage = "That did not work, so nothing changed."
        }
    }

    // MARK: Reset

    func refreshStatus() {
        status = try? privacy.passwordResetStatus()
    }

    var canReset: Bool { status?.canReset == true }

    /// What stands in the way of a reset right now, in plain words; empty when nothing does.
    var resetBlockers: [String] {
        guard let status else { return ["The library could not be read."] }
        var blockers: [String] = []
        if !status.hasPassword { blockers.append("No Note Password is set.") }
        if status.lockedNotes > 0 {
            let count = status.lockedNotes
            blockers.append("\(count) locked \(count == 1 ? "note" : "notes") remain. Take the lock off each one you can open and delete the ones you cannot, Trash included.")
        }
        if status.trashedNotes > 0 {
            let count = status.trashedNotes
            blockers.append("Trash holds \(count) \(count == 1 ? "note" : "notes"). Empty it yourself first.")
        }
        return blockers
    }

    /// The typed confirmation is right and nothing blocks the reset.
    var canConfirmReset: Bool {
        canReset && resetPhrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == Self.resetPhrase
    }

    /// Deletes the Note Password for good. Order matters: sync is quieted (new runs blocked, the running one ended), open edits are
    /// saved, the preconditions are looked at again, then the vault revokes every key it holds, waits for the privacy cleanup and removes the Touch ID
    /// key, and only then does the core delete the envelope. A failure on the way stops before the
    /// envelope is touched. No note or attachment is deleted by this; the core refuses while any
    /// locked note or Trash content remains.
    func cancelJournalDiscard() { pendingJournalDiscard = nil }

    func resetNotePassword(discarding plan: MissingJournalRecovery.ResetDiscardPlan? = nil) async -> Bool {
        resetError = nil
        pendingJournalDiscard = nil
        guard !isResetting else { return false }
        refreshStatus()
        guard canReset else {
            resetError = resetBlockers.first ?? "The password cannot be reset right now."
            return false
        }
        guard canConfirmReset else {
            resetError = "Type “\(Self.resetPhrase)” to confirm."
            return false
        }
        isResetting = true
        defer {
            isResetting = false
            resumeSync()
        }
        // 1. No sync run may be going while the envelope goes. 2. What was typed is saved. 3. What
        // a run that just ended brought in (a locked note, Trash content) is looked at again.
        guard await quiesceSync() else {
            resetError = "Sync is still busy. Wait a moment and try again. Nothing was changed."
            return false
        }
        flush()
        refreshStatus()
        guard canReset else {
            resetError = resetBlockers.first ?? "The password cannot be reset right now."
            return false
        }
        if plan == nil, let found = prepareJournalDiscard() {
            pendingJournalDiscard = found  // nothing changed yet; the sheet asks first
            return false
        }
        do {
            if let plan { try discardJournals(plan) }
            try await vault.resetForRemovePassword()
            try privacy.deletePassword()
            afterPasswordRemoved()
            vault.refresh()
            resetPhrase = ""
            refreshStatus()
            return true
        } catch {
            appLogger.error("note password reset stopped: \(PrivacyErrorCode.code(for: error), privacy: .public)")
            resetError = Self.message(forResetError: error)
            vault.refresh()
            refreshStatus()
            return false
        }
    }

    static func message(forResetError error: any Error) -> String {
        if let error = error as? NotePasswordResetError { return error.errorDescription ?? "The password was not reset." }
        switch error {
        case MissingJournalRecovery.RetirementError.changed, NoteSessionFenceError.stale, BackupError.pendingFiles:
            return "The recovery files or an open note changed, or a voice note is recording. Nothing was discarded; try again."
        case NotePrivacyError.pendingEdits, NotePrivacyError.pendingAttachments, NotePrivacyError.cleanupPending:
            return "Some notes have edits waiting or are finishing a lock. Unlock the notes vault, then try again. Nothing was deleted."
        default:
            return "The password was not reset. Nothing was deleted."
        }
    }
}
