// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Testing

@testable import TheoNotes

/// The renamed app takes its window and layout preferences from the old defaults domain, once.
/// Both domains are throw-away suites; the real `com.truebrewbirdie.*` domains are never read or written.
@MainActor
@Suite struct LegacyPreferencesMigrationTests {
    private struct Domains {
        let legacy = "test.theo.legacy.\(UUID().uuidString.prefix(8))"
        let current = "test.theo.current.\(UUID().uuidString.prefix(8))"
        let legacyDefaults: UserDefaults
        let currentDefaults: UserDefaults

        init() {
            legacyDefaults = UserDefaults(suiteName: legacy)!
            currentDefaults = UserDefaults(suiteName: current)!
        }

        func remove() {
            legacyDefaults.removePersistentDomain(forName: legacy)
            currentDefaults.removePersistentDomain(forName: current)
        }
    }

    @Test func test_preferences_copied_once_not_overwriting_new_values() {
        let d = Domains()
        defer { d.remove() }
        d.legacyDefaults.set("sidebar", forKey: "MainWindow.layout")
        d.legacyDefaults.set("archive", forKey: "MainWindow.scope")
        d.legacyDefaults.set(["T1": 5.0], forKey: "Templates.lastUsed")
        d.legacyDefaults.set("not on the list", forKey: "Unlisted.key")
        // The new domain already has one of them: it is never overwritten.
        d.currentDefaults.set("list", forKey: "MainWindow.layout")

        let copied = LegacyPreferencesMigration.run(
            from: d.legacy, to: d.currentDefaults, keys: LegacyPreferencesMigration.keys)
        #expect(copied == 2)
        #expect(d.currentDefaults.string(forKey: "MainWindow.layout") == "list")
        #expect(d.currentDefaults.string(forKey: "MainWindow.scope") == "archive")
        #expect(d.currentDefaults.dictionary(forKey: "Templates.lastUsed") as? [String: Double] == ["T1": 5.0])
        #expect(d.currentDefaults.object(forKey: "Unlisted.key") == nil, "only the allow-list is copied")
        #expect(d.currentDefaults.bool(forKey: LegacyPreferencesMigration.flagKey))

        // Once: a later change in the old domain, or a key the person removed since, is not copied again.
        d.legacyDefaults.set("workspace", forKey: "MainWindow.workspace")
        d.currentDefaults.removeObject(forKey: "MainWindow.scope")
        #expect(LegacyPreferencesMigration.run(from: d.legacy, to: d.currentDefaults, keys: LegacyPreferencesMigration.keys) == 0)
        #expect(d.currentDefaults.object(forKey: "MainWindow.workspace") == nil)
        #expect(d.currentDefaults.object(forKey: "MainWindow.scope") == nil)

        // The old domain is only read.
        #expect(d.legacyDefaults.string(forKey: "MainWindow.layout") == "sidebar")
        #expect(d.legacyDefaults.string(forKey: "MainWindow.scope") == "archive")
        #expect(d.legacyDefaults.object(forKey: LegacyPreferencesMigration.flagKey) == nil)
    }

    @Test func windowFramesAreCopiedByPrefixAndSyncFlagsNever() {
        let d = Domains()
        defer { d.remove() }
        d.legacyDefaults.set("100 100 900 700 0 0 1440 900 ", forKey: "NSWindow Frame main-AppWindow-1")
        d.legacyDefaults.set("something", forKey: "NSWindowFrameNotOurs")
        d.legacyDefaults.set(true, forKey: "mac.production.v1.connected")
        d.legacyDefaults.set("a message", forKey: "mac.production.v1.recoveryNotice")
        let copied = LegacyPreferencesMigration.run(
            from: d.legacy, to: d.currentDefaults, keys: LegacyPreferencesMigration.keys,
            prefixes: LegacyPreferencesMigration.prefixes)
        #expect(copied == 1)
        #expect(d.currentDefaults.string(forKey: "NSWindow Frame main-AppWindow-1") == "100 100 900 700 0 0 1440 900 ")
        #expect(d.currentDefaults.object(forKey: "NSWindowFrameNotOurs") == nil)
        #expect(d.currentDefaults.object(forKey: "mac.production.v1.connected") == nil)
        #expect(d.currentDefaults.object(forKey: "mac.production.v1.recoveryNotice") == nil)
    }

    @Test func anEmptyOldDomainStillSetsTheFlagAndCopiesNothing() {
        let d = Domains()
        defer { d.remove() }
        #expect(LegacyPreferencesMigration.run(from: d.legacy, to: d.currentDefaults, keys: LegacyPreferencesMigration.keys) == 0)
        #expect(d.currentDefaults.bool(forKey: LegacyPreferencesMigration.flagKey))
    }

    /// The old ids are their own domain: nothing to do. Since the flip (B7) the new ids read the old domain.
    @Test func theLegacyDomainFollowsTheBundleIdentifier() {
        let d = Domains()
        defer { d.remove() }
        #expect(LegacyPreferencesMigration.legacyDomain(forBundleIdentifier: "com.truebrewbirdie.baerchen") == nil)
        #expect(LegacyPreferencesMigration.legacyDomain(forBundleIdentifier: "com.truebrewbirdie.baerchen.dev") == nil)
        #expect(LegacyPreferencesMigration.legacyDomain(forBundleIdentifier: nil) == nil)
        #expect(LegacyPreferencesMigration.legacyDomain(forBundleIdentifier: "com.example.other") == nil)
        #expect(LegacyPreferencesMigration.legacyDomain(forBundleIdentifier: "com.truebrewbirdie.theonotes") == "com.truebrewbirdie.baerchen")
        #expect(LegacyPreferencesMigration.legacyDomain(forBundleIdentifier: "com.truebrewbirdie.theonotes.dev") == "com.truebrewbirdie.baerchen.dev")
        // The launch hook with an old id touches nothing, and does not even set the flag.
        d.currentDefaults.set("keep", forKey: "MainWindow.layout")
        #expect(LegacyPreferencesMigration.runAtLaunch(bundleIdentifier: "com.truebrewbirdie.baerchen", defaults: d.currentDefaults) == 0)
        #expect(d.currentDefaults.object(forKey: LegacyPreferencesMigration.flagKey) == nil)
        #expect(d.currentDefaults.string(forKey: "MainWindow.layout") == "keep")
    }
}
