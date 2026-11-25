// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import UIKit
@testable import TheoNotesCore
@testable import BaerchenIOS

// Task 16 (CK-R175 to CK-R179): the shipped services build the live gateway only behind the release flag and a valid container, the
// Info.plist carries the flag and the container the way the Mac's does, and every word of the page is in one strings file.
// Nothing here reaches the real iCloud: the live gateway is only constructed (it touches CloudKit on its first call).

@MainActor @Suite(.serialized) struct MobileCloudSyncWiringTests {
    private let containerKey = ReleaseFeatures.cloudKitContainerInfoKey
    private let flagKey = ReleaseFeatures.iCloudSyncInfoKey
    private let container = "iCloud.com.truebrewbirdie.theonotes"

    private func library() throws -> (MobileLibrary, URL) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("CloudIOSWire-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return (try MobileLibrary(paths: AppPaths(root: parent.appendingPathComponent("Library", isDirectory: true))), parent)
    }

    // MARK: only the flag AND a valid container build the live gateway

    @Test func flagOffAndEmptyContainerBuildsConstructNothing() throws {
        let (library, parent) = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: parent) }
        let request = MobileCloudSyncGatewayRequest(store: CloudSyncStore(database: library.database), paths: library.paths)
        let pins = library.paths.root.appendingPathComponent("CloudGatewayPins")
        let builds: [(String, [String: Any]?)] = [
            ("no Info.plist", nil),
            ("empty", [:]),
            ("container, flag missing", [containerKey: container]),
            ("container, flag NO", [containerKey: container, flagKey: "NO"]),
            ("flag YES, container empty (config/release.env today)", [containerKey: "", flagKey: "YES"]),
            ("flag YES, container unsubstituted", [containerKey: "$(THEONOTES_CLOUDKIT_CONTAINER)", flagKey: "YES"]),
            ("flag YES, container missing", [flagKey: "YES"]),
            ("flag YES, container malformed", [containerKey: "com.example.nope", flagKey: "YES"]),
        ]
        for (name, info) in builds {
            let services = MobileCloudSyncServices.live(infoDictionary: info)
            #expect(services.configuration == nil, "\(name): no configuration")
            let parts = services.gateway(request)
            #expect(parts.gateway is MobileUnavailableCloudKitGateway, "\(name): the gateway is the one that answers 'not available'")
            #expect(parts.handleRemoteNotification == nil, "\(name): nothing to forward to")
            #expect(!FileManager.default.fileExists(atPath: pins.path), "\(name): no folder was made")
        }
    }

    @Test func aBuildWithTheFlagAndAContainerGetsTheLiveGatewayOnADurablePinFolder() async throws {
        let (library, parent) = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: parent) }
        let request = MobileCloudSyncGatewayRequest(store: CloudSyncStore(database: library.database), paths: library.paths)
        let services = MobileCloudSyncServices.live(infoDictionary: [containerKey: container, flagKey: "YES"])
        #expect(services.configuration?.containerIdentifier == container)
        let parts = services.gateway(request)
        #expect(parts.gateway is LiveCloudKitGateway)
        #expect(parts.handleRemoteNotification != nil)

        // The pin folder is inside the library folder (Application Support in a real run), not tmp, and out of backups.
        let pins = MobileCloudSyncServices.livePinDirectory(for: library.paths)
        #expect(pins.deletingLastPathComponent().standardizedFileURL == library.paths.root.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: pins.path))
        #expect(try pins.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(pins.standardizedFileURL != library.paths.cloudPinned.standardizedFileURL, "not the receiver's own folder")

        // The fence closure is the gateway's own: with no engine yet it is a no-op, never a trap.
        await parts.cancelOperations()
        // A payload that is not a CloudKit notification is not one of ours, and CloudKit is not touched to find out.
        #expect(parts.handleRemoteNotification?(["aps": ["alert": "hello"]]) == false)

        // The seed store is the data-protection keychain item of the app's access group (the Mac's, so the item is one item).
        let seeds = try #require(services.keychain("ios-test") as? KeychainCloudKeySeedStore)
        #expect(seeds.accessGroup == AppIdentity.current.keychainAccessGroup)
        #expect(seeds.namespace == "ios-test")
        let other = try #require(MobileCloudSyncServices.live(infoDictionary: [containerKey: container, flagKey: "YES"], accessGroup: "ABCDE12345.x")
            .keychain("n") as? KeychainCloudKeySeedStore)
        #expect(other.accessGroup == "ABCDE12345.x")
    }

    @Test func theKeychainNamespaceOfALibraryIsStable() {
        let root = URL(fileURLWithPath: "/tmp/Library-A")
        #expect(MobileCloudSyncController.namespace(for: root) == MobileCloudSyncController.namespace(for: root))
        #expect(MobileCloudSyncController.namespace(for: root) != MobileCloudSyncController.namespace(for: URL(fileURLWithPath: "/tmp/Library-B")))
        #expect(MobileCloudSyncController.namespace(for: root).hasPrefix("ios-"))
    }

    // MARK: the Info.plist (REL-R9 mirror, REL-R13)

    @Test func theInfoPlistEnablesTheConfiguredContainer() throws {
        let info = try #require(Bundle.main.infoDictionary)
        #expect(info[flagKey] as? String == "YES", "Debug turns the flag on, like the Mac's dev identity (project.yml)")
        #expect(info[containerKey] as? String == container)
        #expect(ReleaseFeatures.cloudSyncAvailable())
        #expect(MobileCloudSyncServices.live().configuration?.containerIdentifier == container)
    }

    @Test func remoteNotificationIsAnAllowedBackgroundModeExactlyWhenTheFlagIsOn() throws {
        let info = try #require(Bundle.main.infoDictionary)
        let modes = try #require(info["UIBackgroundModes"] as? [String])
        let flagOn = info[flagKey] as? String == "YES"
        #expect(modes.contains("remote-notification") == flagOn, "REL-R13: the push mode is declared only where the flag is on; modes: \(modes)")
        #expect(modes.contains("fetch"), "the background refresh of the existing sync still works")
    }

    @Test func iOSEntitlementsKeepPrivateAndSharedKeychainGroups() throws {
        let ios = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: ios.appendingPathComponent("TheoNotesIOS.entitlements"))
        let entitlements = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(entitlements["keychain-access-groups"] as? [String] == ["$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)", "$(AppIdentifierPrefix)$(THEONOTES_IOS_BUNDLE_ROOT)"])
        #expect(entitlements["com.apple.developer.icloud-container-identifiers"] as? [String] == ["$(THEONOTES_CLOUDKIT_CONTAINER)"])
        #expect(entitlements["com.apple.developer.icloud-services"] as? [String] == ["CloudKit"])
        #expect(entitlements["com.apple.security.application-groups"] as? [String] == ["$(THEONOTES_IOS_APP_GROUP)"])
        #expect(entitlements["aps-environment"] as? String == "$(THEONOTES_IOS_APS_ENVIRONMENT)")
    }

    // MARK: wording

    @Test func noWordOfThePageOrItsSheetsUsesABannedWord() throws {
        for text in MobileCloudSyncStrings.all {
            let lower = text.lowercased()
            for banned in MobileCloudSyncStrings.bannedWords {
                #expect(!lower.contains(banned), "“\(text)” contains “\(banned)”")
            }
            #expect(!text.contains("Mac"), "an iPhone sentence names a Mac: “\(text)”")
        }
        for state in [CloudSyncState.needsRecoveryKey, .recoveryNotSaved, .needsNotePassword] {
            #expect(!MobileCloudSyncStrings.status(for: state).lowercased().contains("recovery key"))
        }
        // The views carry no wording of their own beyond the strings file: banned words, and no fixed text in a string literal at all
        // (accessibility labels included). What may stay: identifiers, symbol names, URLs, interpolations of strings-file values.
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        for file in ["MobileCloudSyncSettings.swift"] {
            let source = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
            for banned in MobileCloudSyncStrings.bannedWords { #expect(!source.lowercased().contains(banned), "\(file) contains “\(banned)”") }
            #expect(Self.hardCodedWording(in: source).isEmpty, "\(file) has wording outside the strings file: \(Self.hardCodedWording(in: source))")
        }
    }

    @Test func theKeychainSentenceNamesSettingsAndEveryKeyFailureHasItsOwnPlainSentence() {
        #expect(MobileCloudSyncStrings.status(for: .keychainUnavailable).contains("turned on in Settings"))
        let plain = Set(["keyBundleUnreadable", "keyRollback", "keyMismatch", "keyBundleMissing"].map {
            MobileCloudSyncStrings.status(for: .failed(kind: $0))
        })
        #expect(plain.count == 4)
        #expect(!plain.contains(CloudSyncState.message(for: .failed(kind: "other"))))
        #expect(MobileCloudSyncStrings.keychainWaitDetail.contains("ten minutes"), "the wait names the 10-minute route to the recovery words")
        #expect(MobileCloudSyncStrings.keychainWaitDetail.contains("recovery words"))
        #expect(MobileCloudSyncStrings.replaceRecoveryDetail.contains("keep working"), "replacing the words is not revocation (CK-R89)")
    }

    /// String literals with fixed words in them, minus the code-ish ones (ids like "cloud-sync-switch", symbol names like "icloud.slash",
    /// URLs). Comments are skipped.
    static func hardCodedWording(in source: String) -> [String] {
        var found: [String] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let code = line.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            var rest = Substring(code)
            while let open = rest.firstIndex(of: "\"") {
                let after = rest[rest.index(after: open)...]
                guard let close = after.firstIndex(of: "\"") else { break }
                let literal = String(after[..<close])
                rest = after[after.index(after: close)...]
                var fixed = literal
                while let start = fixed.range(of: "\\(") {
                    guard let end = fixed[start.upperBound...].firstIndex(of: ")") else { break }
                    fixed.removeSubrange(start.lowerBound...end)
                }
                let codeish = fixed.allSatisfy { $0.isLowercase || $0.isNumber || ".-_:".contains($0) } || fixed.hasPrefix("x-apple.")
                if !codeish && fixed.contains(where: \.isLetter) { found.append(literal) }
            }
        }
        return found
    }
}
