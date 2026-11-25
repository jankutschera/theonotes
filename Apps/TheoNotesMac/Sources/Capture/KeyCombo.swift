// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit

/// A global shortcut: a Carbon virtual key code plus `NSEvent.ModifierFlags` raw bits.
struct KeyCombo: Codable, Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: NSEvent.ModifierFlags.RawValue

    /// Control + Option + Command + N (`kVK_ANSI_N` = 45).
    static let defaultCapture = KeyCombo(
        keyCode: 45,
        modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue)

    // shortcut: fixed ANSI table (letters and digits), other keys have no character; extend when the recorder allows them.
    private static let characters: [UInt32: String] = [
        0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g", 4: "h", 34: "i", 38: "j", 40: "k", 37: "l", 46: "m",
        45: "n", 31: "o", 35: "p", 12: "q", 15: "r", 1: "s", 17: "t", 32: "u", 9: "v", 13: "w", 7: "x", 16: "y", 6: "z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
    ]

    /// Lower-case key character, also usable as a menu key equivalent.
    var keyCharacter: String? { Self.characters[keyCode] }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// "⌃⌥⇧⌘N" in the standard macOS modifier order.
    var displayString: String {
        let f = flags
        var text = ""
        if f.contains(.control) { text += "⌃" }
        if f.contains(.option) { text += "⌥" }
        if f.contains(.shift) { text += "⇧" }
        if f.contains(.command) { text += "⌘" }
        return text + (keyCharacter?.uppercased() ?? "?")
    }
}
