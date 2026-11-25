// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
#if os(macOS)
import Security
#endif

/// Which build this process is (FOC-R360). Two identities exist side by side on one Mac:
/// - `production`: the build Jan installs. Its values are pinned by `AppIdentityTests`; they are the
///   keys to his locked-note keychain items, notification permission, App Group and links.
/// - `dev`: every build used by tests, agents and GUI checks. It shares nothing with production:
///   its own bundle id (so its own notification center, keychain access group, LaunchServices record
///   and defaults), App Group, URL schemes, display name and default library folder.
///
/// The identity is read from the bundle identifier the build was signed with, so there is one source
/// of truth (the build configuration) and no flag that can disagree with it.
public enum AppIdentity: String, CaseIterable, Sendable {
    case production
    case dev

    /// Info.plist key that carries the build setting `THEONOTES_TEAM_ID` (REL-R20, REL-R21).
    public static let teamInfoKey = "THEONOTES_TeamID"

    /// The team used when the process shows neither a signed application identifier nor the Info.plist key
    /// (`swift test`, the command line tool). It equals `THEONOTES_TEAM_ID` in `config/release.env`;
    /// `scripts/check-identities.sh` fails when they differ, and it is the only literal of the team in the sources.
    public static let fallbackTeamPrefix = "Q446J364FH"

    /// The team prefix every macOS App Group and keychain access group starts with (REL-R21): the team of the
    /// signature this process runs with, else the Info.plist value written from the build setting, else
    /// `fallbackTeamPrefix`. Resolved once.
    public static let teamPrefix: String = teamPrefix(
        signedApplicationIdentifier: signedApplicationIdentifier(),
        infoDictionary: Bundle.main.infoDictionary)

    /// The resolution rule behind `teamPrefix`, separate from the process so it can be tested. The signed
    /// `com.apple.application-identifier` is `<team>.<bundle id>`; its first component is the team. A value that
    /// is not a 10-character upper-case alphanumeric Team ID (an unsubstituted build setting, an empty string,
    /// the wrong type) is ignored and the next source is tried.
    public static func teamPrefix(signedApplicationIdentifier: Any?, infoDictionary: [String: Any]?) -> String {
        if let identifier = signedApplicationIdentifier as? String,
           let team = identifier.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init),
           identifier.contains("."), isTeamID(team) {
            return team
        }
        if let team = infoDictionary?[teamInfoKey] as? String, isTeamID(team) { return team }
        return fallbackTeamPrefix
    }

    static func isTeamID(_ text: String) -> Bool {
        text.utf8.count == 10 && text.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) }
    }

    /// The `com.apple.application-identifier` entitlement of this process, when it was signed with one.
    private static func signedApplicationIdentifier() -> String? {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, "com.apple.application-identifier" as CFString, nil) as? String
        #else
        return nil
        #endif
    }

    public static let productionBundleIdentifier = LegacyNames.bundleRoot
    public static let devBundleIdentifier = LegacyNames.bundleRoot + ".dev"

    /// The identity of a process whose main bundle has this identifier. The share extension of the
    /// dev app (`<dev id>.share`) is dev too. Anything that is not exactly the dev id or one of its
    /// children, including no bundle at all (`swift test`, the command line tool), is production.
    public static func identity(forBundleIdentifier identifier: String?) -> AppIdentity {
        guard let identifier else { return .production }
        if identifier == devBundleIdentifier || identifier.hasPrefix(devBundleIdentifier + ".") { return .dev }
        return .production
    }

    /// The identity of this process.
    public static var current: AppIdentity { identity(forBundleIdentifier: Bundle.main.bundleIdentifier) }

    public var bundleIdentifier: String {
        switch self {
        case .production: Self.productionBundleIdentifier
        case .dev: Self.devBundleIdentifier
        }
    }

    public var shareExtensionBundleIdentifier: String { bundleIdentifier + ".share" }

    public var displayName: String {
        switch self {
        case .production: "Theo Notes"
        case .dev: "Theo Notes Dev"
        }
    }

    /// The shared container of the app and its share extension, written the macOS way
    /// (`<team id>.<name>`).
    public var appGroupIdentifier: String { appGroupIdentifier(team: Self.teamPrefix) }

    public func appGroupIdentifier(team: String) -> String {
        switch self {
        case .production: team + ".com.truebrewbirdie.notes"
        case .dev: team + ".com.truebrewbirdie.notes.dev"
        }
    }

    /// The URL schemes the app registers. `dev` has its own pair so a link never opens the other build.
    public var urlSchemes: [String] {
        switch self {
        case .production: ["theonotes", LegacyNames.urlScheme]
        case .dev: ["theonotes-dev", LegacyNames.urlScheme + "-dev"]
        }
    }

    /// The access group the app's keychain items live in: its entitlement is
    /// `$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)`, and an item without an explicit group goes
    /// into the first group of the entitlement. Locked-note keys of one identity are therefore
    /// unreadable to the other.
    public var keychainAccessGroup: String { keychainAccessGroup(team: Self.teamPrefix) }

    public func keychainAccessGroup(team: String) -> String { team + "." + bundleIdentifier }

    /// The Keychain services (REN2-R51, task B3). One name per kind of item for both identities: what separates the
    /// dev build from the installed app is the access group above, not the service. Both follow the production
    /// bundle root, so the cutover (B7) flips them with the bundle id and no store holds a literal of its own.
    /// Today's values are pinned by `IdentityPinsTests`: the installed app's items live under them.
    /// The sync session and keys (`KeychainSyncStore`).
    public static var syncKeychainService: String { LegacyNames.syncKeychainService }
    /// The Touch ID copy of the note vault key (`KeychainVaultKeyCache`, Mac app).
    public static var vaultKeychainService: String { LegacyNames.vaultKeychainService }

    /// The folder in Application Support that holds this identity's library.
    public var libraryFolderName: String {
        switch self {
        case .production: AppPaths.productionLibraryFolderName
        case .dev:
            #if os(macOS)
            "Theo Notes Dev"
            #else
            "Baerchen Dev"
            #endif
        }
    }
}
