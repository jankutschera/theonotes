// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Security
import Testing
@testable import TheoNotesCore
@testable import BaerchenIOS

/// The iOS identity cutover preserves App Intents and legacy data formats.
@MainActor @Suite(.serialized) struct MobileIdentityTests {
    @Test func appIntentTypeIdentitiesRemainStable() {
        let types: [Any.Type] = [SaveToBaerchen.self, OpenBaerchenShortcut.self, CreateShortcutNote.self,
            AppendToShortcutNote.self, FindShortcutNotes.self, ReadShortcutNote.self, OpenShortcutNote.self,
            ShortcutNote.self, ShortcutNoteQuery.self, BaerchenAppShortcuts.self]
        let names = ["SaveToBaerchen", "OpenBaerchenShortcut", "CreateShortcutNote", "AppendToShortcutNote",
            "FindShortcutNotes", "ReadShortcutNote", "OpenShortcutNote", "ShortcutNote", "ShortcutNoteQuery", "BaerchenAppShortcuts"]
        #expect(types.map { String(reflecting: $0) } == names.map { "BaerchenIOS." + $0 })
    }

    @Test func cutoverNamesUseTheNewIdentity() {
        #expect(MobileIdentity.bundleIdentifier == "com.truebrewbirdie.theonotes.dev.ios")
        #expect(MobileIdentity.noteVaultKeychainService == "com.truebrewbirdie.theonotes.dev.ios.note-vault")
        #expect(MobileIdentity.automationKeychainService == "com.truebrewbirdie.theonotes.dev.ios.automation")
        #expect(MobileIdentity.syncRefreshIdentifier == "com.truebrewbirdie.theonotes.dev.ios.sync-refresh")
        #expect(MobileIdentity.syncConnectivityQueueLabel == "com.truebrewbirdie.theonotes.dev.sync-connectivity")
        #expect(MobileIdentity.encryptedBlobsSessionIdentifier == "com.truebrewbirdie.theonotes.dev.ios.encrypted-blobs.v1")
        // The private-server sync service of the iPhone is the shared one: it already follows AppIdentity.
        #expect(AppIdentity.syncKeychainService == "com.truebrewbirdie.theonotes.sync")
    }

    @Test func everyNameIsBuiltFromTheNewRoot() {
        let root = AppIdentity.current.bundleIdentifier
        #expect(root == "com.truebrewbirdie.theonotes.dev")
        #expect(AppIdentity.current == .dev)
        #expect(MobileIdentity.bundleIdentifier == root + ".ios")
        #expect(MobileIdentity.noteVaultKeychainService == root + ".ios.note-vault")
        #expect(MobileIdentity.automationKeychainService == root + ".ios.automation")
        #expect(MobileIdentity.syncRefreshIdentifier == root + ".ios.sync-refresh")
        #expect(MobileIdentity.syncConnectivityQueueLabel == root + ".sync-connectivity")
        #expect(MobileIdentity.encryptedBlobsSessionIdentifier == root + ".ios.encrypted-blobs.v1")
    }

    @Test func theCallersReadTheNamesAndHoldNoLiteralOfTheirOwn() throws {
        #expect(MobileSyncScheduler.refreshIdentifier == MobileIdentity.syncRefreshIdentifier)
        #expect(MobileBlobFiles.identifier == MobileIdentity.encryptedBlobsSessionIdentifier)
        #expect(MobileBiometricKeychain.service == MobileIdentity.noteVaultKeychainService)

        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        #expect(files.count > 10, "the scan found the iOS sources")
        for file in files where file.lastPathComponent != "MobileIdentity.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("com.truebrewbirdie.baerchen"), "\(file.lastPathComponent) holds the bundle root as a literal; read MobileIdentity")
            #expect(!text.contains("com.truebrewbirdie.theonotes"), "\(file.lastPathComponent) holds the new bundle root as a literal")
        }
    }

    @Test func theAutomationTokenLivesUnderTheInstalledAppsKeychainService() throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("MobileIdentity-\(UUID().uuidString)"))
        defer { MobileAutomationToken.revoke(paths) }
        let token = try MobileAutomationToken.generate(paths)
        // The new app stores its automation token under the new service.
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "com.truebrewbirdie.theonotes.dev.ios.automation",
                                    kSecAttrAccount as String: MobileAutomationToken.credentialAccount(paths),
                                    kSecAttrSynchronizable as String: false, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess)
        #expect((value as? Data).flatMap { String(data: $0, encoding: .utf8) } == token)
    }

    @Test func theBundleAndTheInfoPlistFollowTheNewRoot() throws {
        // The test host is the app: its bundle id, the task identifier it may submit and the link name all come from build settings
        // (THEONOTES_IOS_BUNDLE_ROOT in project.yml), and the Swift names above must equal them.
        let info = try #require(Bundle.main.infoDictionary)
        #expect(Bundle.main.bundleIdentifier == MobileIdentity.bundleIdentifier)
        #expect(info["BGTaskSchedulerPermittedIdentifiers"] as? [String] == [MobileSyncScheduler.refreshIdentifier])
        #expect(info["NSUserActivityTypes"] as? [String] == [MobileIdentity.noteWindowActivityType])
        let types = try #require(info["CFBundleURLTypes"] as? [[String: Any]])
        #expect(types.compactMap { $0["CFBundleURLName"] as? String } == [AppIdentity.dev.bundleIdentifier])
        #expect(types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] } == AppIdentity.dev.urlSchemes)
    }

    @Test func embeddedShareUsesTheDebugAppGroupAndIdentity() throws {
        let group = try #require(Bundle.main.object(forInfoDictionaryKey: "THEONOTES_AppGroupIdentifier") as? String)
        #expect(group == "group." + AppIdentity.dev.bundleIdentifier + ".ios")
        let plugins = try #require(Bundle.main.builtInPlugInsURL)
        let share = try #require(Bundle(url: plugins.appendingPathComponent("TheoNotesIOSShare.appex")))
        #expect(share.bundleIdentifier == MobileIdentity.bundleIdentifier + ".share")
        #expect(share.object(forInfoDictionaryKey: "THEONOTES_AppGroupIdentifier") as? String == group)
        // The extension must carry the app's own build number (App Store Connect refuses a mismatch); no literal, it changes every release.
        #expect(share.object(forInfoDictionaryKey: "CFBundleVersion") as? String == Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }

    @Test func theBackupTypesAndTheDatabaseNameAreUnchanged() throws {
        // The database stays Baerchen.sqlite and the theme ids stay; exports the person chooses are
        // .theonotes-backup, the internal backups keep the legacy type, and both restore (the iOS picker takes any file). Nothing in
        // this task touches them; this pins that it stayed so.
        #expect(LegacyNames.databaseFile == "Baerchen.sqlite")
        #expect(LegacyNames.themeIDs["baerchen-red"] == "theo-red")
        #expect(LibraryBackup.backupExtension == "theonotes-backup")
        #expect(LegacyNames.backupExtension == "baerchen-backup")
        #expect(LegacyNames.backupUTI == "com.truebrewbirdie.baerchen.backup")
    }
}
