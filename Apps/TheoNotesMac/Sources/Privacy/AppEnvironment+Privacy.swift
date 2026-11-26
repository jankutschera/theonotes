// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation

/// Why a lock or a lock removal did not happen for one note.
enum NoteLockChangeError: Error, Equatable, Sendable {
    case notFound
    /// Lock Note on a note that is locked already.
    case alreadyLocked
    /// Remove Lock on a note that is not locked.
    case notLocked
    /// The note is in the Trash: restore it first.
    case inTrash
    /// The open note holds text that could not be committed.
    case unsavedText
}

/// What `AppEnvironment.lockNotes` did, by note.
struct NoteLockOutcome: Equatable {
    enum Skip: Equatable {
        case notFound, alreadyLocked, inTrash
        /// Unsaved text, attachments still being stored, edits still being replayed.
        case busy
        /// The store or the vault refused; the associated text is a `PrivacyErrorCode`.
        case failed(String)
    }

    /// In the order asked.
    var locked: [String] = []
    var skipped: [String: Skip] = [:]

    var skippedInTrash: Int { skipped.values.filter { $0 == .inTrash }.count }
    /// Notes skipped for a reason the user cannot see in the list (not "already locked").
    var skippedOther: Int { skipped.values.filter { $0 != .inTrash && $0 != .alreadyLocked }.count }
}

extension AppEnvironment {
    /// The vault facts the privacy commands depend on (observed through the vault).
    var privacyState: NoteCommandState.PrivacyState {
        .init(hasPassword: vault.hasPassword, isUnlocked: vault.isUnlocked)
    }

    /// Locks each note that can be locked (not locked yet, not in the Trash; the Archive is fine,
    ///) with the unlocked vault's access. An open note keeps its edits and its editor shows
    /// it again, keyed. One note failing does not stop the others. Throws `accessRevoked` when
    /// the vault is locked: ask for the password first.
    func lockNotes(ids: [String]) async throws -> NoteLockOutcome {
        let access = try vault.requireAccess()
        var outcome = NoteLockOutcome()
        var eligible: [String] = []
        for id in ids {
            guard let note = try store.note(id: id) else {
                outcome.skipped[id] = .notFound
                continue
            }
            if note.isLocked {
                outcome.skipped[id] = .alreadyLocked
            } else if note.location == .trash {
                outcome.skipped[id] = .inTrash
            } else {
                eligible.append(id)
            }
        }
        let failures = await changingLockState(of: eligible) { try access.lock(noteId: $0) }
        for id in eligible {
            guard let error = failures[id] else {
                outcome.locked.append(id)
                continue
            }
            outcome.skipped[id] = Self.skip(for: error)
            let code = PrivacyErrorCode.code(for: error)
            appLogger.error("lock of note \(id, privacy: .public) failed: \(code, privacy: .public)")
        }
        return outcome
    }

    /// Removes the lock of one note (the vault must be unlocked): its text and attachments are
    /// plain again. Not for a note in the Trash. Throws instead of skipping.
    func removeLock(noteId: String) async throws {
        let access = try vault.requireAccess()
        guard let note = try store.note(id: noteId) else { throw NoteLockChangeError.notFound }
        guard note.isLocked else { throw NoteLockChangeError.notLocked }
        guard note.location != .trash else { throw NoteLockChangeError.inTrash }
        let failures = await changingLockState(of: [noteId]) { try access.removeLock(noteId: $0) }
        // The plain note's attachments are served from disk again; nothing of it stays in memory.
        lockedAttachments.clear()
        if let error = failures[noteId] {
            let code = PrivacyErrorCode.code(for: error)
            appLogger.error("removing the lock of note \(noteId, privacy: .public) failed: \(code, privacy: .public)")
            throw error
        }
    }

    private static func skip(for error: Error) -> NoteLockOutcome.Skip {
        switch error {
        case NoteLockChangeError.unsavedText, NotePrivacyError.pendingEdits, NotePrivacyError.pendingAttachments:
            .busy
        case NoteLockChangeError.inTrash: .inTrash
        case NoteLockChangeError.alreadyLocked: .alreadyLocked
        case NoteLockChangeError.notFound: .notFound
        default: .failed(PrivacyErrorCode.code(for: error))
        }
    }
}
