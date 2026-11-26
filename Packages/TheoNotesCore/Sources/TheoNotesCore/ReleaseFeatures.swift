// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// What a build offers, decided when it is built. The build setting
/// `THEONOTES_SYNC_SETUP` is written into the Info.plist as `THEONOTES_SyncSetupAvailable`: YES in Jan's own
/// builds (Debug and Production), NO in the public Release build. The code behind it is compiled in either
/// way; this only decides whether anything reaches it.
public enum ReleaseFeatures {
    public static let syncSetupInfoKey = "THEONOTES_SyncSetupAvailable"

    /// True only when the bundle was built with THEONOTES_SYNC_SETUP = YES. A missing key, an unsubstituted
    /// `$(THEONOTES_SYNC_SETUP)` or any other text is false, so a build that loses the setting ships without sync.
    public static func syncSetupAvailable(bundle: Bundle = .main) -> Bool {
        syncSetupAvailable(infoDictionary: bundle.infoDictionary)
    }

    public static func syncSetupAvailable(infoDictionary: [String: Any]?) -> Bool {
        switch infoDictionary?[syncSetupInfoKey] {
        case let text as String: text == "YES"
        case let flag as Bool: flag
        default: false
        }
    }

    // MARK: private sync server host

    public static let privateSyncHostInfoKey = "THEONOTES_PrivateSyncHost"
    /// Where an unconfigured build points: the reserved `.invalid` name never resolves (RFC 6761).
    public static let unconfiguredPrivateSyncEndpoint = URL(string: "https://sync.invalid")!

    /// The private sync server of this build: `https://` plus `THEONOTES_PRIVATE_SYNC_HOST`, which only the
    /// owner's never-exported `config/private-sync.xcconfig` sets. The server is not part of the public
    /// source, so a build without the setting (empty, unsubstituted or not a plain host) gets the `.invalid` address.
    public static func privateSyncEndpoint(bundle: Bundle = .main) -> URL {
        privateSyncEndpoint(infoDictionary: bundle.infoDictionary)
    }

    public static func privateSyncEndpoint(infoDictionary: [String: Any]?) -> URL {
        guard let host = infoDictionary?[privateSyncHostInfoKey] as? String,
              host.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil,
              let url = URL(string: "https://" + host) else { return unconfiguredPrivateSyncEndpoint }
        return url
    }

    // MARK: iCloud sync

    public static let cloudKitContainerInfoKey = "THEONOTES_CloudKitContainer"
    public static let iCloudSyncInfoKey = "THEONOTES_ICloudSyncAvailable"

    /// The CloudKit container this build was configured for (`THEONOTES_CLOUDKIT_CONTAINER` in config/release.env),
    /// or nil when the key is missing, empty, unsubstituted or not a container identifier. A container is `iCloud.`
    /// followed by at least two dot-separated segments of letters, digits and hyphens. Empty is the state of every
    /// build until the publishing team's account exists.
    public static func cloudKitContainer(bundle: Bundle = .main) -> String? {
        cloudKitContainer(infoDictionary: bundle.infoDictionary)
    }

    public static func cloudKitContainer(infoDictionary: [String: Any]?) -> String? {
        guard let text = infoDictionary?[cloudKitContainerInfoKey] as? String, isValidContainerIdentifier(text) else { return nil }
        return text
    }

    /// True only when the container is valid AND the build was made with THEONOTES_ICLOUD_SYNC = YES. Either alone
    /// is false, so an empty container keeps iCloud sync off even in a build whose flag says YES.
    public static func cloudSyncAvailable(bundle: Bundle = .main) -> Bool {
        cloudSyncAvailable(infoDictionary: bundle.infoDictionary)
    }

    public static func cloudSyncAvailable(infoDictionary: [String: Any]?) -> Bool {
        guard cloudKitContainer(infoDictionary: infoDictionary) != nil else { return false }
        switch infoDictionary?[iCloudSyncInfoKey] {
        case let text as String: return text == "YES"
        case let flag as Bool: return flag
        default: return false
        }
    }

    private static func isValidContainerIdentifier(_ text: String) -> Bool {
        let prefix = "iCloud."
        guard text.hasPrefix(prefix) else { return false }
        let segments = text.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return false }
        return segments.allSatisfy { segment in
            !segment.isEmpty && segment.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-")
            }
        }
    }
}
