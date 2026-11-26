// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// What the person sees about iCloud sync. One enum and one place for its words, shared by the Mac and iOS
/// apps. Policy code (`CloudAccountPolicy`, `CloudErrorPolicy`) decides which state applies; this file only names the states
/// and says what each means in plain language.
public enum CloudSyncState: Sendable, Equatable {
    case off
    case notAvailableInThisBuild
    case signedOutOfICloud
    case restricted
    case waitingForICloud
    case waitingForKeychain
    case keychainUnavailable
    case needsRecoveryKey
    case recoveryNotSaved
    /// A library with protected notes needs the note password once, before its first sync (Task 10).
    case needsNotePassword
    /// A different iCloud user is signed in than the one this library syncs with. `previousHash` is the stored user hash.
    case accountChanged(previousHash: String)
    /// The synced copy is gone (the person removed it, or encrypted iCloud data was reset). Never re-created automatically.
    case zoneRemoved(reason: ZoneRemoval)
    case itemsMissingInCloud(count: Int)
    case quotaFull
    case offline(retryAt: Date?)
    case syncing
    case upToDate(lastSync: Date?)
    case paused
    case needsAppUpdate
    case itemsUnreadable(count: Int)
    case failed(kind: String)

    public var message: String { Self.message(for: self) }

    /// Plain words for a non-technical person: one or two short sentences, no internal vocabulary. A test pins that no message
    /// contains the words "CloudKit", "zone", "record", "token" or "quarantine".
    public static func message(for state: CloudSyncState) -> String {
        switch state {
        case .off:
            return "Sync is off. Your notes stay on this device."
        case .notAvailableInThisBuild:
            return "iCloud sync is not part of this version of Theo Notes. Your notes stay on this device."
        case .signedOutOfICloud:
            return "You are not signed in to iCloud on this device. Sign in to sync; your notes here are safe."
        case .restricted:
            return "iCloud is switched off for this device by a restriction, such as Screen Time or a device profile. Sync starts once that changes."
        case .waitingForICloud:
            return "Waiting for iCloud to become ready. Sync continues by itself."
        case .waitingForKeychain:
            return "Waiting for iCloud Keychain to bring over the encryption key from your other device. This can take a few minutes."
        case .keychainUnavailable:
            return "Theo Notes cannot reach iCloud Keychain. Check that iCloud Keychain is turned on in System Settings."
        case .needsRecoveryKey:
            return "Enter your 24 recovery words to unlock your synced notes on this device."
        case .recoveryNotSaved:
            return "Your recovery words are not saved yet. Save them somewhere safe so you can get your notes back if you lose every device."
        case .needsNotePassword:
            return "Enter your note password to start syncing. This library has protected notes."
        case .accountChanged:
            return "This device is signed in to a different iCloud account. Sync is paused so your notes do not end up in the wrong account."
        case .zoneRemoved(let reason):
            switch reason {
            case .encryptedDataReset:
                return "Your encrypted iCloud data was reset, which removed the synced copy of your notes. Your notes on this device are safe; you can upload them again."
            case .deleted, .userDeletedZone, .purged:
                return "The synced copy of your notes was removed from iCloud. Your notes on this device are safe; you can upload them again."
            }
        case .itemsMissingInCloud(let count):
            return count == 1
                ? "1 note that this device synced before can no longer be found in iCloud. It is on hold until you decide what to do."
                : "\(count) notes that this device synced before can no longer be found in iCloud. They are on hold until you decide what to do."
        case .quotaFull:
            return "Your iCloud storage is full, so new changes cannot be uploaded. Changes from your other devices still arrive."
        case .offline:
            return "You are offline. Sync will try again by itself."
        case .syncing:
            return "Syncing your notes."
        case .upToDate:
            return "Everything is up to date."
        case .paused:
            return "Sync is paused."
        case .needsAppUpdate:
            return "Some synced notes come from a newer version of Theo Notes. Update the app to read them."
        case .itemsUnreadable(let count):
            return count == 1
                ? "1 item from iCloud could not be read. It is kept safe, and Theo Notes will try again."
                : "\(count) items from iCloud could not be read. They are kept safe, and Theo Notes will try again."
        case .failed(let kind):
            if kind.hasPrefix("vaultPartial:"), let count = Int(kind.dropFirst("vaultPartial:".count)), count > 0 {
                return VaultIntakeLockedNotesMismatch.partialMessage(count: count)
            }
            if kind.hasPrefix("vaultMismatch:"), let count = Int(kind.dropFirst("vaultMismatch:".count)), count > 0 {
                return VaultIntakeLockedNotesMismatch(count: count).localizedDescription
            }
            if kind == "journalKeyUnavailable" {
                return "The notes key for this sync account is not available on this device yet. Keep sync on, or use the recovery notice to move the affected files aside; they will be kept unchanged."
            }
            if kind == "journalRecoveryBlocked" {
                return "Unsaved edits need attention before sync can continue. Use the recovery notice to retry or move the affected files aside; the files will be kept."
            }
            return "Sync ran into a problem. Theo Notes will try again."
        }
    }
}
