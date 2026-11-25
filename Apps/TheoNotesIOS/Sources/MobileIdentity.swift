// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation

/// Names registered by the new iOS identity; the old app and its container remain separate.
enum MobileIdentity {
    private static let root = AppIdentity.current.bundleIdentifier
    /// `<root>.ios`. `project.yml` gives the iOS target `$(THEONOTES_IOS_BUNDLE_ROOT).ios`, so this equals `Bundle.main.bundleIdentifier`.
    static let bundleIdentifier = root + ".ios"
    /// The Keychain service of the Face ID / Touch ID copy of the note vault key (`MobileBiometricKeychain`).
    static let noteVaultKeychainService = bundleIdentifier + ".note-vault"
    /// The Keychain service of the automation token (`MobileAutomationToken`).
    static let automationKeychainService = bundleIdentifier + ".automation"
    /// The `BGAppRefreshTask` identifier; `Info.plist` lists `$(PRODUCT_BUNDLE_IDENTIFIER).sync-refresh`, which is the same string.
    static let syncRefreshIdentifier = bundleIdentifier + ".sync-refresh"
    /// The queue that watches connectivity for the private-server sync (`MobileSyncScheduler`). It never carried the `.ios` part.
    static let syncConnectivityQueueLabel = root + ".sync-connectivity"
    /// The background URL session of encrypted attachment transfers (`MobileBlobFiles`).
    static let encryptedBlobsSessionIdentifier = bundleIdentifier + ".encrypted-blobs.v1"
    static let noteWindowActivityType = bundleIdentifier + ".note-window"
}
