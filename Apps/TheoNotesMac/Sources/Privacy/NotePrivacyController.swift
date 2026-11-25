// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Observation

/// One main window's privacy commands: Lock Note, Remove Lock from Note, Change Password… and
/// the sheets they need. The window presents `sheet`. The vault does the cryptography; the
/// environment closes and reopens the sessions around a lock change.
@MainActor
@Observable
final class NotePrivacyController {
    /// The password sheet on screen, if any. At most one.
    private(set) var sheet: PasswordSheetModel?

    /// A lock change is running (its pages are clearing); commands wait for it to finish.
    private(set) var isChangingLocks = false

    @ObservationIgnored private let library: LibraryModel
    private var environment: AppEnvironment { library.environment }
    private var vault: NoteVault { environment.vault }

    init(library: LibraryModel) {
        self.library = library
    }

    // MARK: Commands

    /// Lock Note: the selected notes that are not locked yet. No password yet: the create sheet
    /// (then the notes are locked); a locked vault: the unlock sheet; otherwise at once.
    func lockSelectedNotes() async {
        guard !isChangingLocks else { return }
        library.refresh()
        guard library.commandState.canLockNote else { return }
        let ids = listedSelection().filter { id in library.items.first { $0.id == id }?.isLocked == false }
        await lock(ids: ids)
    }

    /// Lock the notes with these ids (see `lockSelectedNotes`).
    func lock(ids: [String]) async {
        guard !ids.isEmpty, !isChangingLocks else { return }
        if !vault.hasPassword {
            present(.create) { [weak self] in await self?.performLock(ids) }
        } else if !vault.isUnlocked {
            present(.unlock(.lockNotes)) { [weak self] in await self?.performLock(ids) }
        } else {
            await performLock(ids)
        }
    }

    /// Remove Lock from Note: the one selected locked note. A locked vault asks for the password.
    func removeLockFromSelectedNote() async {
        guard !isChangingLocks else { return }
        library.refresh()
        guard library.commandState.canRemoveLock, let id = listedSelection().first else { return }
        if vault.isUnlocked {
            await performRemoveLock(id)
        } else {
            present(.unlock(.removeLock)) { [weak self] in await self?.performRemoveLock(id) }
        }
    }

    /// Change Password…: asks for the current password, the new one and its confirmation.
    func changePassword() {
        guard vault.hasPassword else { return }
        present(.change) { [weak self] in self?.library.refresh() }
    }

    /// Lock Now: every locked note closes at once and its editor shows the lock view.
    func lockNow() async {
        await vault.relockAndFinishCleanup()
        library.refresh()
    }

    /// Closes the sheet (Cancel, Escape, or the window going away): fields are wiped and the
    /// authentication scope ends.
    func dismissSheet() {
        guard let current = sheet else { return }
        sheet = nil
        current.clearFields()
        current.onSuccess = {}
        current.onCancel = {}
        current.endAuthenticationScope()
    }

    // MARK: Private

    /// The selected notes that are listed, in list order.
    private func listedSelection() -> [String] {
        library.items.map(\.id).filter(library.selectedNoteIDs.contains)
    }

    private func present(_ kind: PasswordSheetModel.Kind, then proceed: @escaping @MainActor () async -> Void) {
        dismissSheet()
        let model = PasswordSheetModel(kind: kind, vault: vault)
        model.beginAuthenticationScope()
        model.onSuccess = { [weak self, weak model] in
            // The work runs inside the sheet's authentication scope: a relock cannot slip in
            // between the password and the lock.
            await proceed()
            if let model, self?.sheet === model { self?.dismissSheet() }
        }
        model.onCancel = { [weak self] in self?.dismissSheet() }
        sheet = model
    }

    private func performLock(_ ids: [String]) async {
        isChangingLocks = true
        defer { isChangingLocks = false }
        do {
            let outcome = try await environment.lockNotes(ids: ids)
            library.refresh()
            if outcome.skippedInTrash > 0 || outcome.skippedOther > 0 {
                library.showNotice(.notesNotLocked(inTrash: outcome.skippedInTrash, other: outcome.skippedOther))
            }
        } catch NotePrivacyError.accessRevoked {
            // Relocked while the sheet was up: ask again.
            isChangingLocks = false
            await lock(ids: ids)
        } catch {
            appLogger.error("lock failed: \(PrivacyErrorCode.code(for: error), privacy: .public)")
            library.showNotice(.commandFailed(action: "lock"))
        }
    }

    private func performRemoveLock(_ id: String) async {
        isChangingLocks = true
        defer { isChangingLocks = false }
        do {
            try await environment.removeLock(noteId: id)
        } catch NotePrivacyError.accessRevoked {
            present(.unlock(.removeLock)) { [weak self] in await self?.performRemoveLock(id) }
            return
        } catch {
            library.showNotice(.commandFailed(action: "remove lock"))
        }
        library.refresh()
    }
}
