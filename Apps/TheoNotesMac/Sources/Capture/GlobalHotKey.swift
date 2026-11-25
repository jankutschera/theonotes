// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import Carbon.HIToolbox

enum GlobalHotKeyError: Error { case taken }

@MainActor
protocol HotKeyRegistering: AnyObject {
    func register(_ combo: KeyCombo, handler: @escaping @MainActor () -> Void) throws
    func unregister()
}

/// One Carbon hot key on the application event target. Needs no Accessibility or Input Monitoring permission.
@MainActor
final class GlobalHotKey: HotKeyRegistering {
    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var handlerRef: EventHandlerRef?
    private var handler: (@MainActor () -> Void)?

    func register(_ combo: KeyCombo, handler: @escaping @MainActor () -> Void) throws {
        unregister()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var installed: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in hotKey.handler?() }
                return noErr
            },
            1, &spec, Unmanaged.passUnretained(self).toOpaque(), &installed)
        guard installStatus == noErr else { throw GlobalHotKeyError.taken }

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x544E_4348), id: 1)  // 'TNCH'
        let status = RegisterEventHotKey(
            combo.keyCode, Self.carbonModifiers(combo.flags), id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            if let installed { RemoveEventHandler(installed) }
            throw GlobalHotKeyError.taken
        }
        handlerRef = installed
        hotKeyRef = ref
        self.handler = handler
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
        handler = nil
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}

/// Keeps the registration in step with `CaptureSettings`.
@MainActor
final class CaptureHotKeyController {
    static let takenMessage = "This shortcut is used by another app."

    private let settings: CaptureSettings
    private let registrar: HotKeyRegistering
    private let onPress: @MainActor () -> Void
    private(set) var lastError: String?

    init(settings: CaptureSettings, registrar: HotKeyRegistering, onPress: @escaping @MainActor () -> Void) {
        self.settings = settings
        self.registrar = registrar
        self.onPress = onPress
    }

    /// Registers the current combo when the shortcut is enabled, else unregisters.
    func apply() {
        guard settings.shortcutEnabled else {
            registrar.unregister()
            lastError = nil
            return
        }
        do {
            try registrar.register(settings.combo, handler: onPress)
            lastError = nil
        } catch {
            lastError = Self.takenMessage
        }
    }

    /// Switches to `combo`; on failure the previous combo stays registered and in settings.
    @discardableResult
    func change(to combo: KeyCombo) -> Bool {
        guard settings.shortcutEnabled else {
            settings.combo = combo
            lastError = nil
            return true
        }
        let previous = settings.combo
        do {
            try registrar.register(combo, handler: onPress)
            settings.combo = combo
            lastError = nil
            return true
        } catch {
            try? registrar.register(previous, handler: onPress)
            lastError = Self.takenMessage
            return false
        }
    }
}
