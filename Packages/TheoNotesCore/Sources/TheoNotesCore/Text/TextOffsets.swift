// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

public enum TextOffsetError: Error, Equatable, Sendable {
    case outOfBounds
    case splitsScalar
}

/// Conversions between UTF-16 code-unit offsets (bridge/CodeMirror) and UTF-8 byte offsets (CLI).
public enum TextOffsets {
    public static func utf8Offset(fromUTF16 offset: Int, in text: String) throws -> Int {
        let utf16 = text.utf16
        guard offset >= 0, offset <= utf16.count else { throw TextOffsetError.outOfBounds }
        let idx = utf16.index(utf16.startIndex, offsetBy: offset)
        guard idx.samePosition(in: text.unicodeScalars) != nil else {
            throw TextOffsetError.splitsScalar
        }
        return text.utf8.distance(from: text.utf8.startIndex, to: idx)
    }

    public static func utf16Offset(fromUTF8 offset: Int, in text: String) throws -> Int {
        let utf8 = text.utf8
        guard offset >= 0, offset <= utf8.count else { throw TextOffsetError.outOfBounds }
        let idx = utf8.index(utf8.startIndex, offsetBy: offset)
        guard idx.samePosition(in: text.unicodeScalars) != nil else {
            throw TextOffsetError.splitsScalar
        }
        return text.utf16.distance(from: text.utf16.startIndex, to: idx)
    }

    /// False when out of range or between a high and a low surrogate.
    public static func isValidUTF16Boundary(_ offset: Int, in text: String) -> Bool {
        let utf16 = text.utf16
        guard offset >= 0, offset <= utf16.count else { return false }
        guard offset > 0, offset < utf16.count else { return true }
        let before = utf16[utf16.index(utf16.startIndex, offsetBy: offset - 1)]
        let after = utf16[utf16.index(utf16.startIndex, offsetBy: offset)]
        return !(UTF16.isLeadSurrogate(before) && UTF16.isTrailSurrogate(after))
    }
}
