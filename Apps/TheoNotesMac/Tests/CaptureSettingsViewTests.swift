// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import Foundation
import Testing
import TheoNotesCore
@testable import TheoNotes

@MainActor
private final class FakeRegistrar: HotKeyRegistering {
    var failFor: Set<UInt32> = []
    var current: KeyCombo?
    var unregisterCount = 0

    func register(_ combo: KeyCombo, handler: @escaping @MainActor () -> Void) throws {
        if failFor.contains(combo.keyCode) { throw GlobalHotKeyError.taken }
        current = combo
    }

    func unregister() {
        unregisterCount += 1
        current = nil
    }
}

@MainActor
private final class FakeLoginItem: LoginItemControlling {
    var isEnabled: Bool
    var failure: (any Error)?
    var requiresApproval = false
    var settingsOpened = 0
    var calls: [Bool] = []

    init(isEnabled: Bool = false) { self.isEnabled = isEnabled }

    func openSystemSettings() { settingsOpened += 1 }

    func setEnabled(_ on: Bool) throws {
        calls.append(on)
        if let failure { throw failure }
        isEnabled = on
    }
}

private struct LoginFailure: LocalizedError {
    var errorDescription: String? { "denied" }
}

@MainActor
@Suite(.serialized)
struct CaptureSettingsViewTests {
    @MainActor private struct Rig {
        let settings: CaptureSettings
        let registrar = FakeRegistrar()
        let login: FakeLoginItem
        let controller: CaptureHotKeyController
        let model: CaptureSettingsModel

        init(loginEnabled: Bool = false) {
            let name = "CaptureSettingsViewTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
            settings = CaptureSettings(defaults: defaults, identity: .production)
            login = FakeLoginItem(isEnabled: loginEnabled)
            controller = CaptureHotKeyController(settings: settings, registrar: registrar, onPress: {})
            model = CaptureSettingsModel(settings: settings, hotKey: { [controller] in controller }, loginItem: login)
        }
    }

    @Test func captureTabFollowsGeneral() {
        #expect(SettingsTab.order(syncSetup: false).prefix(2).map(\.title) == ["General", "Capture"])
        #expect(SettingsTab.capture.systemImage == "bolt")
        #expect(SettingsTab.capture.shown(syncSetup: false) == .capture)
    }

    @Test func recorderRejectsCombosWithoutTwoModifiers() {
        let rig = Rig()
        for flags: NSEvent.ModifierFlags in [[], [.shift], [.command], [.option], [.command, .shift], [.option, .shift]] {
            #expect(rig.model.handle(keyCode: 45, modifiers: flags) == .rejected)
            #expect(rig.model.message == "Use at least two of ⌃ ⌥ ⌘.")
        }
        #expect(rig.model.handle(keyCode: 13, modifiers: [.command]) == .rejected)  // ⌘W
        #expect(rig.model.handle(keyCode: 37, modifiers: [.option]) == .rejected)  // ⌥L
        #expect(rig.settings.combo == .defaultCapture)
        #expect(rig.model.handle(keyCode: 45, modifiers: [.control, .option, .command]) == .recorded)  // ⌃⌥⌘N
        #expect(rig.model.handle(keyCode: 45, modifiers: [.command, .option]) == .recorded)
    }

    @Test func recorderRefusesKeysItCannotShow() {
        let rig = Rig()
        // 122 = F1, not in the character table.
        #expect(rig.model.handle(keyCode: 122, modifiers: [.command, .option]) == .rejected)
        #expect(rig.model.message == "Use a letter or a number key.")
    }

    @Test func recordedComboKeepsOnlyTheFourModifiers() {
        let rig = Rig()
        let noisy: NSEvent.ModifierFlags = [.control, .option, .capsLock, .function, .numericPad]
        #expect(rig.model.handle(keyCode: 11, modifiers: noisy) == .recorded)
        #expect(rig.settings.combo == KeyCombo(keyCode: 11, modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue))
        #expect(rig.registrar.current == rig.settings.combo)
        #expect(rig.model.message == nil)
    }

    @Test func escapeCancelsAndDeleteTurnsTheShortcutOff() {
        let rig = Rig()
        rig.controller.apply()
        #expect(rig.model.handle(keyCode: 53, modifiers: []) == .cancelled)
        #expect(rig.settings.shortcutEnabled)
        #expect(rig.model.handle(keyCode: 51, modifiers: []) == .cleared)
        #expect(!rig.settings.shortcutEnabled)
        #expect(rig.registrar.current == nil)
    }

    @Test func takenComboShowsTheMessage() {
        let rig = Rig()
        rig.controller.apply()
        rig.registrar.failFor = [11]
        #expect(rig.model.handle(keyCode: 11, modifiers: [.command, .option]) == .rejected)
        #expect(rig.model.message == "This shortcut is used by another app.")
        #expect(rig.settings.combo == .defaultCapture)
    }

    @Test func shortcutToggleRegistersAtOnce() {
        let rig = Rig()
        rig.model.setShortcutEnabled(true)
        #expect(rig.registrar.current == .defaultCapture)
        rig.model.setShortcutEnabled(false)
        #expect(rig.registrar.current == nil)
        #expect(!rig.settings.shortcutEnabled)
    }

    @Test func loginItemNeedingApprovalShowsAMessageAndAButton() {
        let rig = Rig()
        rig.login.requiresApproval = true
        rig.model.setOpenAtLogin(true)
        #expect(rig.model.needsLoginApproval)
        #expect(rig.model.message == "Allow Theo Notes in System Settings ▸ General ▸ Login Items.")
        rig.model.openLoginItemsSettings()
        #expect(rig.login.settingsOpened == 1)
        rig.login.requiresApproval = false
        rig.model.setOpenAtLogin(false)
        #expect(!rig.model.needsLoginApproval)
    }

    @Test func approvalButtonDoesNotOutliveItsMessage() {
        let rig = Rig()
        rig.login.requiresApproval = true
        rig.model.setOpenAtLogin(true)
        #expect(rig.model.needsLoginApproval)
        // A later recorder error is unrelated to Login Items.
        #expect(rig.model.handle(keyCode: 45, modifiers: [.command]) == .rejected)
        #expect(!rig.model.needsLoginApproval)
        // Coming back to the pane clears a stale approval request.
        rig.model.setOpenAtLogin(true)
        #expect(rig.model.needsLoginApproval)
        rig.model.refreshLoginItem()
        #expect(!rig.model.needsLoginApproval && rig.model.message == nil)
        // A thrown error is not replaced by the approval message.
        rig.login.failure = LoginFailure()
        rig.model.setOpenAtLogin(true)
        #expect(!rig.model.needsLoginApproval)
        #expect(rig.model.message == "Theo Notes could not change Open at login: denied")
    }

    @Test func openAtLoginReflectsTheSystem() {
        let rig = Rig(loginEnabled: true)
        #expect(!rig.settings.openAtLogin)
        rig.model.refreshLoginItem()
        #expect(rig.settings.openAtLogin, "the system says enabled, so the toggle is on")

        let other = Rig()
        other.model.setOpenAtLogin(true)
        #expect(other.login.calls == [true])
        #expect(other.settings.openAtLogin)

        other.login.failure = LoginFailure()
        other.model.setOpenAtLogin(false)
        #expect(other.settings.openAtLogin == other.login.isEnabled)

        let failing = Rig()
        failing.login.failure = LoginFailure()
        failing.model.setOpenAtLogin(true)
        #expect(!failing.settings.openAtLogin)
        #expect(failing.model.message == "Theo Notes could not change Open at login: denied")
    }
}

/// A login item that never touches the system, for tests that only render the pane.
@MainActor
final class InertLoginItem: LoginItemControlling {
    var isEnabled = false
    var requiresApproval: Bool { false }
    func setEnabled(_ on: Bool) throws { isEnabled = on }
    func openSystemSettings() {}
}
