// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

public enum TextNormalization {
    /// "\r\n" and lone "\r" become "\n". CodeMirror's EditorState splits on all three and rejoins
    /// with "\n", so only normalised text has the same UTF-16 length on both sides of the bridge.
    public static func normalizeLineEndings(_ text: String) -> String {
        let cr = UInt8(ascii: "\r"), lf = UInt8(ascii: "\n")
        guard text.utf8.contains(cr) else { return text }
        var out: [UInt8] = []
        out.reserveCapacity(text.utf8.count)
        var previousWasCR = false
        for byte in text.utf8 {
            if byte == cr {
                out.append(lf)
                previousWasCR = true
            } else {
                if !(byte == lf && previousWasCR) { out.append(byte) }
                previousWasCR = false
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Byte-exact equality. Swift's `==` uses canonical equivalence (NFC "é" == NFD "e\u{301}"),
    /// which must never decide whether text changed.
    public static func identical(_ a: String, _ b: String) -> Bool {
        a.utf8.elementsEqual(b.utf8)
    }
}
