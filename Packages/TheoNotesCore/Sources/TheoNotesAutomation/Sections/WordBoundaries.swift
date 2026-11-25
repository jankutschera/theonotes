// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// Unicode word boundaries (UAX #29, as `enumerateSubstrings(options: .byWords)` segments text:
/// `dog's`, `can't`, `3.14` and `x_y` are one word each, CJK is split by dictionary), the
/// `--word` rule of `edit` and `edit_note` (ruling M5-R63). A position is a boundary unless it lies
/// strictly inside a word. The start and end of the text, and every position next to `\n` or `\r`,
/// are boundaries, so a find that begins or ends with a line break matches CRLF text (M5-R65).
///
/// Every line break is a boundary, so words are segmented one line at a time; the last line is
/// cached, which keeps `--all` over a long line linear.
struct WordBoundaries {
    let text: String
    private var line: Range<String.Index>?
    /// Words of `line`, in order.
    private var words: [Range<String.Index>] = []

    init(text: String) { self.text = text }

    /// `index` must be a unicode scalar boundary of `text`.
    mutating func isBoundary(_ index: String.Index) -> Bool {
        let scalars = text.unicodeScalars
        guard index > scalars.startIndex, index < scalars.endIndex else { return true }
        if Self.isLineBreak(scalars[scalars.index(before: index)]) || Self.isLineBreak(scalars[index]) { return true }
        if !(line.map { $0.lowerBound <= index && index <= $0.upperBound } ?? false) { load(around: index) }
        // The last word starting before `index`; the position is inside it when it ends after.
        var low = 0
        var high = words.count
        while low < high {
            let mid = (low + high) / 2
            if words[mid].lowerBound < index { low = mid + 1 } else { high = mid }
        }
        return low == 0 || words[low - 1].upperBound <= index
    }

    private static func isLineBreak(_ scalar: Unicode.Scalar) -> Bool { scalar == "\n" || scalar == "\r" }

    private mutating func load(around index: String.Index) {
        let bytes = text.utf8
        var lower = index
        while lower > bytes.startIndex {
            let previous = bytes.index(before: lower)
            if bytes[previous] == UInt8(ascii: "\n") { break }
            lower = previous
        }
        var upper = index
        while upper < bytes.endIndex, bytes[upper] != UInt8(ascii: "\n") { upper = bytes.index(after: upper) }
        line = lower..<upper
        var found: [Range<String.Index>] = []
        text.enumerateSubstrings(in: lower..<upper, options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            found.append(range)
        }
        words = found
    }
}
