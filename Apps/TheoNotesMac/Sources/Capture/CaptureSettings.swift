// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Observation
import TheoNotesCore

/// Per-Mac capture preferences: `UserDefaults`, not the synced library.
@MainActor
@Observable
final class CaptureSettings {
    private let defaults: UserDefaults

    var shortcutEnabled: Bool { didSet { defaults.set(shortcutEnabled, forKey: Key.shortcutEnabled) } }
    var combo: KeyCombo {
        didSet { defaults.set(try? JSONEncoder().encode(combo), forKey: Key.combo) }
    }
    var showInMenuBar: Bool { didSet { defaults.set(showInMenuBar, forKey: Key.showInMenuBar) } }
    var openAtLogin: Bool { didSet { defaults.set(openAtLogin, forKey: Key.openAtLogin) } }

    init(defaults: UserDefaults = .standard, identity: AppIdentity = .current) {
        self.defaults = defaults
        // The dev build never steals the real shortcut.
        shortcutEnabled = defaults.object(forKey: Key.shortcutEnabled) as? Bool ?? (identity != .dev)
        combo = defaults.data(forKey: Key.combo).flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) }
            ?? .defaultCapture
        showInMenuBar = defaults.object(forKey: Key.showInMenuBar) as? Bool ?? true
        openAtLogin = defaults.object(forKey: Key.openAtLogin) as? Bool ?? false
    }

    private enum Key {
        static let shortcutEnabled = "Capture.shortcutEnabled"
        static let combo = "Capture.combo"
        static let showInMenuBar = "Capture.showInMenuBar"
        static let openAtLogin = "Capture.openAtLogin"
    }
}
