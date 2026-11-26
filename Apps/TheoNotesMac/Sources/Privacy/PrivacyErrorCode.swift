// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation

/// The only thing privacy code logs about a failure: a fixed code per error case. An
/// interpolated error can carry a note id, a protected attachment name or a path, so no log line
/// and no state shown to the UI ever contains `\(error)`. The switches over our own error types
/// have no `default`: adding a case does not compile until it is classified.
enum PrivacyErrorCode {
    static func code(for error: Error) -> String {
        switch error {
        case let error as NotePrivacyError: return code(error)
        case let error as CryptoError: return code(error)
        case let error as VaultKeyCacheError: return code(error)
        case let error as StoreError: return code(error)
        case let error as NoteLockChangeError: return code(error)
        case is CancellationError: return "cancelled"
        default: return "other"
        }
    }

    private static func code(_ error: NotePrivacyError) -> String {
        switch error {
        case .passwordAlreadySet: "passwordAlreadySet"
        case .passwordNotSet: "passwordNotSet"
        case .accessRevoked: "accessRevoked"
        case .pendingEdits: "pendingEdits"
        case .pendingAttachments: "pendingAttachments"
        case .cleanupPending: "cleanupPending"
        case .invalidPayload: "invalidPayload"
        case .attachmentMissing: "attachmentMissing"
        case .attachmentTooLarge: "attachmentTooLarge"
        }
    }

    private static func code(_ error: CryptoError) -> String {
        switch error {
        case .wrongPassword: "wrongPassword"
        case .tampered: "tampered"
        case .truncated: "truncated"
        case .malformed: "malformed"
        case .keyDerivationFailed: "keyDerivationFailed"
        case .emptyPassword: "emptyPassword"
        }
    }

    private static func code(_ error: VaultKeyCacheError) -> String {
        switch error {
        case .cancelled: "cacheCancelled"
        case .unavailableNow: "cacheUnavailableNow"
        case .corrupt: "cacheCorrupt"
        case .notRemoved: "cacheNotRemoved"
        case .failed(let status): "cacheStatus\(status)"
        }
    }

    private static func code(_ error: NoteLockChangeError) -> String {
        switch error {
        case .notFound: "lockNoteNotFound"
        case .alreadyLocked: "alreadyLocked"
        case .notLocked: "notLocked"
        case .inTrash: "inTrash"
        case .unsavedText: "unsavedText"
        }
    }

    private static func code(_ error: StoreError) -> String {
        switch error {
        case .revisionConflict: "revisionConflict"
        case .noteNotFound: "noteNotFound"
        case .noteLocked: "noteLocked"
        case .tagNotFound: "tagNotFound"
        case .noteNotTagged: "noteNotTagged"
        case .invalidTag: "invalidTag"
        case .tagNotRoot: "tagNotRoot"
        case .tagIntoOwnSubtree: "tagIntoOwnSubtree"
        case .reservedTagName: "reservedTagName"
        case .externalRefTombstoned: "externalRefTombstoned"
        }
    }
}
