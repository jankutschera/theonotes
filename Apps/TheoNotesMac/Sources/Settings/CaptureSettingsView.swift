// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import Observation
import SwiftUI

/// Logic of Settings ▸ Capture, kept free of views so tests run without a window.
@MainActor
@Observable
final class CaptureSettingsModel {
    enum RecorderOutcome: Equatable { case recorded, cancelled, cleared, rejected }

    let settings: CaptureSettings
    private(set) var message: String? {
        // The approval button belongs to the approval message only.
        didSet { if message != Self.approvalMessage { needsLoginApproval = false } }
    }
    private static let approvalMessage = "Allow Theo Notes in System Settings ▸ General ▸ Login Items."
    /// Open at login was asked for but the user still has to allow it in System Settings.
    private(set) var needsLoginApproval = false

    @ObservationIgnored private let hotKey: () -> CaptureHotKeyController?
    @ObservationIgnored private let loginItem: LoginItemControlling

    /// `hotKey` is a closure because the controller is made after launch, the Settings window can be built earlier.
    init(settings: CaptureSettings, hotKey: @escaping () -> CaptureHotKeyController?, loginItem: LoginItemControlling) {
        self.settings = settings
        self.hotKey = hotKey
        self.loginItem = loginItem
    }

    func setShortcutEnabled(_ on: Bool) {
        settings.shortcutEnabled = on
        hotKey()?.apply()
        message = hotKey()?.lastError
    }

    /// Handles one key press while the recorder listens.
    func handle(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> RecorderOutcome {
        switch keyCode {
        case 53:  // Escape
            message = nil
            return .cancelled
        case 51, 117:  // Delete, Forward Delete
            setShortcutEnabled(false)
            return .cleared
        default: break
        }
        // Caps lock, fn and numeric-pad bits would break `KeyCombo ==` and the display.
        let flags = modifiers.intersection(.deviceIndependentFlagsMask).intersection([.control, .option, .command, .shift])
        // One of them alone would take ⌘W, ⌘Q … or ⌥L (an "@" on German keyboards) from every app.
        guard flags.intersection([.control, .option, .command]).rawValue.nonzeroBitCount >= 2 else {
            message = "Use at least two of ⌃ ⌥ ⌘."
            announce(message)
            return .rejected
        }
        let combo = KeyCombo(keyCode: UInt32(keyCode), modifiers: flags.rawValue)
        guard combo.keyCharacter != nil else {
            message = "Use a letter or a number key."
            announce(message)
            return .rejected
        }
        if let controller = hotKey() {
            guard controller.change(to: combo) else {
                message = controller.lastError
                announce(message)
                return .rejected
            }
        } else {
            settings.combo = combo
        }
        message = nil
        return .recorded
    }

    /// The message is red text; VoiceOver users need it spoken.
    private func announce(_ text: String?) {
        if let text { AccessibilityNotification.Announcement(text).post() }
    }

    /// The system is the truth for Open at login: the user can switch it off in System Settings.
    func refreshLoginItem() {
        settings.openAtLogin = loginItem.isEnabled
        if message == Self.approvalMessage { message = nil }
    }

    func openLoginItemsSettings() { loginItem.openSystemSettings() }

    func setOpenAtLogin(_ on: Bool) {
        var failed = false
        do {
            try loginItem.setEnabled(on)
            message = nil
        } catch {
            failed = true
            message = "Theo Notes could not change Open at login: \(error.localizedDescription)"
        }
        settings.openAtLogin = loginItem.isEnabled
        // A thrown error stays the message; approval is only asked for after a clean register.
        if !failed, on, loginItem.requiresApproval {
            message = Self.approvalMessage
            needsLoginApproval = true
            announce(message)
        }
    }
}

struct CaptureSettingsView: View {
    let model: CaptureSettingsModel

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle("Capture Thought shortcut", isOn: Binding(get: { settings.shortcutEnabled }, set: model.setShortcutEnabled))
                LabeledContent("Shortcut") {
                    ShortcutRecorder(model: model)
                }
                .disabled(!settings.shortcutEnabled)
            } footer: {
                Text("Works from any app and needs no extra permission. Press Delete while recording to turn it off.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Show in menu bar", isOn: $settings.showInMenuBar)
                Toggle("Open at login", isOn: Binding(get: { settings.openAtLogin }, set: model.setOpenAtLogin))
            }
            if let message = model.message {
                Section {
                    Text(message).foregroundStyle(.red)
                    if model.needsLoginApproval {
                        Button("Open Login Items Settings", action: model.openLoginItemsSettings)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshLoginItem() }
    }
}

/// A button that records the next key press. The monitor is local (this app only) and lives only while recording.
struct ShortcutRecorder: View {
    let model: CaptureSettingsModel
    @State private var monitor = KeyMonitor()

    var body: some View {
        let shortcut = model.settings.shortcutEnabled ? model.settings.combo.displayString : "Off"
        Button(monitor.isRecording ? "Type shortcut…" : shortcut) {
            monitor.isRecording ? monitor.stop() : monitor.start { event in
                model.handle(keyCode: event.keyCode, modifiers: event.modifierFlags) != .rejected
            }
        }
        .accessibilityLabel("Capture Thought shortcut, \(shortcut)")
        .accessibilityHint(monitor.isRecording ? "Press the new shortcut, Escape to cancel" : "Activate to record a new shortcut")
        .onDisappear { monitor.stop() }
    }
}

@MainActor
@Observable
final class KeyMonitor {
    private(set) var isRecording = false
    @ObservationIgnored private var token: Any?

    /// `onKey` returns whether recording is over (the key was used).
    func start(onKey: @escaping @MainActor (NSEvent) -> Bool) {
        stop()
        isRecording = true
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                if onKey(event) { self?.stop() }
            }
            return nil
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
        isRecording = false
    }

    isolated deinit { stop() }
}
