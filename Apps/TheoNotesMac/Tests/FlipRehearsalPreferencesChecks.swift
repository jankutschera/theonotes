// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Testing

@testable import TheoNotes

/// Rehearsal 1 of the identity flip (stage-2 plan B6): the preferences row. The plan seeded a fake defaults
/// domain through `CFFIXED_USER_HOME`; on this macOS the preferences daemon ignores that variable (probed: a plist in a
/// fake home is not found by `CFPreferencesCopyAppValue`), so the legacy domain is a throw-away suite seeded from the
/// fixture plist instead, like `LegacyPreferencesMigrationTests`. `scripts/rehearse-identity-flip.sh` runs this inside
/// the build with the flipped bundle root and passes the fixture and the output path as `TEST_RUNNER_` variables.
/// Without them the test is skipped. The real `com.truebrewbirdie.*` domains are never read or written.
@Suite struct FlipRehearsalPreferencesChecks {
    private static let environment = ProcessInfo.processInfo.environment
    private static let fixture = environment["THEONOTES_REHEARSAL_PREFS_FIXTURE"]
    private static let output = environment["THEONOTES_REHEARSAL_PREFS_OUT"]

    @Test(.enabled(if: fixture != nil && output != nil, "set by scripts/rehearse-identity-flip.sh"))
    func test_fixture_preferences_are_copied_once_with_the_flipped_identity() throws {
        let fixtureURL = URL(fileURLWithPath: try #require(Self.fixture))
        let out = URL(fileURLWithPath: try #require(Self.output))
        let seed = try #require(
            PropertyListSerialization.propertyList(from: Data(contentsOf: fixtureURL), format: nil) as? [String: Any])

        let legacy = "test.theo.rehearsal.legacy.\(UUID().uuidString.prefix(8))"
        let current = "test.theo.rehearsal.current.\(UUID().uuidString.prefix(8))"
        let legacyDefaults = try #require(UserDefaults(suiteName: legacy))
        let currentDefaults = try #require(UserDefaults(suiteName: current))
        defer {
            legacyDefaults.removePersistentDomain(forName: legacy)
            currentDefaults.removePersistentDomain(forName: current)
        }
        legacyDefaults.setPersistentDomain(seed, forName: legacy)

        let expected = seed.keys.filter { key in
            LegacyPreferencesMigration.keys.contains(key)
                || LegacyPreferencesMigration.prefixes.contains { key.hasPrefix($0) }
        }
        let first = LegacyPreferencesMigration.run(
            from: legacy, to: currentDefaults, keys: LegacyPreferencesMigration.keys,
            prefixes: LegacyPreferencesMigration.prefixes)
        #expect(first == expected.count)
        for key in expected { #expect(currentDefaults.object(forKey: key) != nil, "allow-listed key \(key) was copied") }
        #expect(currentDefaults.object(forKey: "mac.library.connected") == nil, "sync flags are never copied")
        #expect(currentDefaults.object(forKey: "mac.library.paused") == nil)
        #expect(currentDefaults.object(forKey: "Unlisted.key") == nil, "only the allow-list is copied")
        #expect(currentDefaults.bool(forKey: LegacyPreferencesMigration.flagKey))

        // Once: a later change in the old domain is not copied, and the old domain itself is untouched.
        legacyDefaults.set("changed later", forKey: "MainWindow.scope")
        legacyDefaults.set("new key later", forKey: "Settings.tab")
        let second = LegacyPreferencesMigration.run(
            from: legacy, to: currentDefaults, keys: LegacyPreferencesMigration.keys,
            prefixes: LegacyPreferencesMigration.prefixes)
        #expect(second == 0)
        #expect(currentDefaults.string(forKey: "MainWindow.scope") == "inbox")
        #expect(legacyDefaults.object(forKey: LegacyPreferencesMigration.flagKey) == nil)

        // The flipped identity is what this build is, and the domain mapping reads the old domains of both identities.
        let bundle = Bundle.main.bundleIdentifier
        let report: [String: Any] = [
            "keysInFixture": seed.count, "allowListedInFixture": expected.count, "copiedFirstRun": first,
            "copiedSecondRun": second, "flagSet": currentDefaults.bool(forKey: LegacyPreferencesMigration.flagKey),
            "syncFlagsCopied": currentDefaults.object(forKey: "mac.library.connected") != nil,
            "unlistedCopied": currentDefaults.object(forKey: "Unlisted.key") != nil,
            "hostBundleIdentifier": bundle ?? "none",
            "identityIsDev": AppIdentity.current == .dev,
            "syncKeychainService": AppIdentity.syncKeychainService,
            "vaultKeychainService": KeychainVaultKeyCache.defaultService,
            "productionDomainMapsTo": LegacyPreferencesMigration.legacyDomain(forBundleIdentifier: "com.truebrewbirdie.theonotes") ?? "nil",
            "devDomainMapsTo": LegacyPreferencesMigration.legacyDomain(forBundleIdentifier: "com.truebrewbirdie.theonotes.dev") ?? "nil",
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: out)
    }
}
