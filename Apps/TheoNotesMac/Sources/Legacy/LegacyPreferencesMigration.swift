// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CoreFoundation
import Foundation
import os

private let preferencesLogger = Logger(subsystem: "com.truebrewbirdie.baerchen", category: "preferences-migration")

/// Copies the window and layout preferences of the pre-stage-2 app (defaults domain
/// `com.truebrewbirdie.baerchen`) into the domain of the renamed app, once (REN2-R38).
///
/// - Only an allow-list is copied (`keys`, and every key that starts with one of `prefixes`: the window
///   frames AppKit saves under `NSWindow Frame <autosave name>`). Nothing else is read.
/// - A key the new domain already has is never overwritten.
/// - The old domain is only read through `CFPreferencesCopyAppValue`; it is never written or deleted.
/// - The flag `didMigrateLegacyPreferences` is set after the first pass, whatever it copied, so it never
///   runs twice. A pass that had no old domain to read from does not set it (see `runAtLaunch`).
///
/// Before the identity flip (B7) the app's own domain IS the old domain, so `runAtLaunch` finds no
/// different legacy domain and does nothing. After it, the renamed bundle id reads the old domain once.
enum LegacyPreferencesMigration {
    /// Set in the new domain once the copy has run.
    static let flagKey = "didMigrateLegacyPreferences"

    /// What the Mac app stores in its defaults that is worth keeping: the last window layout, scope and note,
    /// the export panel's settings, the last-used templates and the Settings tab. Not copied on purpose:
    /// the Cloudflare sync flags (`mac.*.connected`, `.paused`, `.recoveryNotice`), because the sync identity
    /// lives in the Keychain and is re-enrolled after the team move (a copied `connected` would claim a
    /// connection the new app cannot make).
    static let keys = [
        "MainWindow.layout", "MainWindow.scope", "MainWindow.note", "MainWindow.workspace",
        "Export.settings", "Templates.lastUsed", "Settings.tab",
    ]

    /// Saved window frames and split positions (AppKit's autosave keys).
    static let prefixes = ["NSWindow Frame ", "NSSplitView Subview Frames "]

    /// The domain the renamed app takes its old preferences from, or nil when the bundle id is not a renamed
    /// one (the pre-flip ids, anything unknown): then there is nothing to migrate.
    /// // LegacyNames (A2)
    static func legacyDomain(forBundleIdentifier identifier: String?) -> String? {
        guard let identifier else { return nil }
        switch identifier {
        case "com.truebrewbirdie.theonotes": return "com.truebrewbirdie.baerchen"
        case "com.truebrewbirdie.theonotes.dev": return "com.truebrewbirdie.baerchen.dev"
        default: return nil
        }
    }

    /// The launch hook: migrates when this process runs under a renamed bundle id. Returns the number of keys copied.
    @discardableResult
    static func runAtLaunch(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier, defaults: UserDefaults = .standard
    ) -> Int {
        guard let legacy = legacyDomain(forBundleIdentifier: bundleIdentifier) else { return 0 }
        return run(from: legacy, to: defaults, keys: keys, prefixes: prefixes)
    }

    /// Copies `keys` (and keys with one of `prefixes`) that `domain` has and `defaults` has not. Returns how many.
    @discardableResult
    static func run(from domain: String, to defaults: UserDefaults, keys: [String], prefixes: [String] = []) -> Int {
        guard !defaults.bool(forKey: flagKey) else { return 0 }
        var wanted = keys
        if !prefixes.isEmpty,
           let present = CFPreferencesCopyKeyList(
               domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] {
            wanted += present.filter { key in prefixes.contains { key.hasPrefix($0) } }
        }
        var copied = 0
        for key in wanted where defaults.object(forKey: key) == nil {
            guard let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString) else { continue }
            defaults.set(value, forKey: key)
            copied += 1
        }
        defaults.set(true, forKey: flagKey)
        preferencesLogger.notice("legacy preferences copied once: \(copied, privacy: .public) keys")
        return copied
    }
}
