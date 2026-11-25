// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// Occurrences of a literal string in note text, as UTF-8 byte ranges.
enum NoteFind {
    /// Non-overlapping, left to right, inside `within` (UTF-8 bytes; the whole text when nil).
    /// `ignoreCase` compares case-insensitively but diacritic-sensitively; canonically equivalent
    /// spellings (`é` and `e` + U+0301) match either way. A needle with `\r` or `\n` is compared
    /// literally (scalar by scalar), because `\r\n` is one grapheme cluster and would otherwise
    /// never match a lone `\n` (ruling M5-R65). `word`: the match starts and ends on a Unicode
    /// word boundary (`WordBoundaries`). An empty needle has no occurrences. `limit` stops after
    /// that many occurrences (a first-only edit asks for one).
    static func occurrences(
        of needle: String, in text: String, within: Range<Int>?, ignoreCase: Bool, word: Bool, limit: Int? = nil
    ) -> [Range<Int>] {
        guard !needle.isEmpty else { return [] }
        let utf8 = text.utf8
        let count = utf8.count
        let bounds = (within ?? 0..<count).clamped(to: 0..<count)
        guard !bounds.isEmpty else { return [] }
        let lower = scalarIndex(atOrAfter: bounds.lowerBound, in: text)
        let upper = scalarIndex(atOrBefore: bounds.upperBound, in: text)
        guard lower < upper else { return [] }
        var options: String.CompareOptions = ignoreCase ? [.caseInsensitive] : []
        if needle.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) { options.insert(.literal) }
        var result: [Range<Int>] = []
        var boundaries = WordBoundaries(text: text)
        var start = lower
        while start < upper, result.count < (limit ?? .max), let found = text.range(of: needle, options: options, range: start..<upper) {
            let aligned =
                found.lowerBound.samePosition(in: text.unicodeScalars) != nil
                && found.upperBound.samePosition(in: text.unicodeScalars) != nil
            guard aligned, !found.isEmpty, !word || boundaries.isBoundary(found.lowerBound) && boundaries.isBoundary(found.upperBound) else {
                start = text.unicodeScalars.index(after: max(found.lowerBound, start))
                continue
            }
            result.append(utf8.distance(from: utf8.startIndex, to: found.lowerBound)
                ..< utf8.distance(from: utf8.startIndex, to: found.upperBound))
            start = found.upperBound
        }
        return result
    }

    /// The scalar boundary at `offset`, or the next one when `offset` is inside a scalar.
    static func scalarIndex(atOrAfter offset: Int, in text: String) -> String.Index {
        let bytes = text.utf8
        var n = min(max(offset, 0), bytes.count)
        var index = bytes.index(bytes.startIndex, offsetBy: n)
        while n < bytes.count, bytes[index] & 0xC0 == 0x80 {
            n += 1
            index = bytes.index(after: index)
        }
        return index
    }

    /// The scalar boundary at `offset`, or the previous one when `offset` is inside a scalar.
    static func scalarIndex(atOrBefore offset: Int, in text: String) -> String.Index {
        let bytes = text.utf8
        var n = min(max(offset, 0), bytes.count)
        var index = bytes.index(bytes.startIndex, offsetBy: n)
        while n > 0, n < bytes.count, bytes[index] & 0xC0 == 0x80 {
            n -= 1
            index = bytes.index(before: index)
        }
        return index
    }
}
