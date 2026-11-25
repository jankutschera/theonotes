// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import Foundation
import Testing
import TheoNotesCore
@testable import TheoNotes

@MainActor
private final class FakeRegistrar: HotKeyRegistering {
    var registered: [KeyCombo] = []
    var unregisterCount = 0
    var failFor: Set<UInt32> = []
    var current: KeyCombo?

    func register(_ combo: KeyCombo, handler: @escaping @MainActor () -> Void) throws {
        if failFor.contains(combo.keyCode) { throw GlobalHotKeyError.taken }
        registered.append(combo)
        current = combo
    }

    func unregister() {
        unregisterCount += 1
        current = nil
    }
}

@MainActor
@Suite(.serialized)
struct GlobalCaptureSettingsTests {
    private func freshDefaults() -> UserDefaults {
        let name = "GlobalCaptureSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func defaultsForProduction() {
        let settings = CaptureSettings(defaults: freshDefaults(), identity: .production)
        #expect(settings.shortcutEnabled)
        #expect(settings.combo == .defaultCapture)
        #expect(settings.showInMenuBar)
        #expect(!settings.openAtLogin)
    }

    @Test func devIdentityDefaultsShortcutOff() {
        let settings = CaptureSettings(defaults: freshDefaults(), identity: .dev)
        #expect(!settings.shortcutEnabled)
        #expect(settings.showInMenuBar)
    }

    @Test func comboRoundTripsAndDisplays() throws {
        let data = try JSONEncoder().encode(KeyCombo.defaultCapture)
        #expect(try JSONDecoder().decode(KeyCombo.self, from: data) == .defaultCapture)
        #expect(KeyCombo.defaultCapture.displayString == "⌃⌥⌘N")
        #expect(KeyCombo.defaultCapture.keyCharacter == "n")
    }

    @Test func settingsPersistAcrossInstances() {
        let defaults = freshDefaults()
        let first = CaptureSettings(defaults: defaults, identity: .production)
        let other = KeyCombo(keyCode: 0, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue)
        first.combo = other
        first.shortcutEnabled = false
        first.openAtLogin = true
        let second = CaptureSettings(defaults: defaults, identity: .production)
        #expect(second.combo == other)
        #expect(!second.shortcutEnabled)
        #expect(second.openAtLogin)
    }

    @Test func applyRegistersOnlyWhenEnabled() {
        let registrar = FakeRegistrar()
        let settings = CaptureSettings(defaults: freshDefaults(), identity: .production)
        let controller = CaptureHotKeyController(settings: settings, registrar: registrar, onPress: {})
        controller.apply()
        #expect(registrar.registered == [.defaultCapture])
        settings.shortcutEnabled = false
        controller.apply()
        #expect(registrar.registered.count == 1)
        #expect(registrar.current == nil)
        #expect(registrar.unregisterCount >= 1)
    }

    @Test func failedReRegistrationKeepsThePreviousCombo() {
        let registrar = FakeRegistrar()
        let settings = CaptureSettings(defaults: freshDefaults(), identity: .production)
        let controller = CaptureHotKeyController(settings: settings, registrar: registrar, onPress: {})
        controller.apply()
        let taken = KeyCombo(keyCode: 0, modifiers: NSEvent.ModifierFlags([.command]).rawValue)
        registrar.failFor = [0]
        #expect(!controller.change(to: taken))
        #expect(settings.combo == .defaultCapture)
        #expect(registrar.current == .defaultCapture)
        #expect(controller.lastError == "This shortcut is used by another app.")
        let free = KeyCombo(keyCode: 1, modifiers: NSEvent.ModifierFlags([.command]).rawValue)
        #expect(controller.change(to: free))
        #expect(settings.combo == free)
        #expect(controller.lastError == nil)
    }
}
