// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// Where search terms occur in a note's source text, for highlighting and scroll-to-match.
///
/// Recomputed on demand from the text instead of persisting a body→source offset map: a match is
/// only needed for the one note being opened or previewed, scanning its text is linear and fast,
/// and nothing can go stale when the stripping rules change.
public enum SearchOffsets {
    /// UTF-16 ranges in `text` where any of `terms` occurs, matched like the search indexes:
    /// case- and diacritic-insensitive, anywhere (substring, so CJK and as-you-type prefixes
    /// match). A match covers whole source characters. Overlapping matches are merged (adjacent
    /// ones are not); the result is sorted. Blank terms are ignored. Matches inside markup the
    /// search body drops (e.g. a link URL) are included.
    public static func sourceRanges(for terms: [String], in text: String) -> [Range<Int>] {
        let needles = terms
            .map { trimmed(Array(fold($0).unicodeScalars)) }
            .filter { !$0.isEmpty }
        guard !needles.isEmpty else { return [] }

        // Folded scalars of the text, each with the UTF-16 range of the character it came from.
        var folded: [Unicode.Scalar] = []
        var origin: [Range<Int>] = []
        folded.reserveCapacity(text.utf16.count)
        origin.reserveCapacity(text.utf16.count)
        var offset = 0
        for character in text {
            let length = character.utf16.count
            let range = offset..<offset + length
            if character.isASCII {  // fast path: ASCII folds to its lowercase
                for scalar in character.unicodeScalars {
                    folded.append((65...90).contains(scalar.value) ? Unicode.Scalar(scalar.value + 32)! : scalar)
                    origin.append(range)
                }
            } else {
                for scalar in fold(String(character)).unicodeScalars {
                    folded.append(scalar)
                    origin.append(range)
                }
            }
            offset += length
        }

        var ranges: [Range<Int>] = []
        for needle in needles where needle.count <= folded.count {
            let first = needle[0]
            for start in 0...(folded.count - needle.count) where folded[start] == first {
                var k = 1
                while k < needle.count && folded[start + k] == needle[k] { k += 1 }
                if k == needle.count {
                    ranges.append(origin[start].lowerBound..<origin[start + needle.count - 1].upperBound)
                }
            }
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = []
        for range in ranges {
            if let last = merged.last, range.lowerBound < last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// The range to scroll to when a result opens: the first match that starts a word (so `art`
    /// scrolls to `art`, not into `start`), else the first match (Bear's terms match inside words).
    public static func firstMatch(for terms: [String], in text: String) -> Range<Int>? {
        let ranges = sourceRanges(for: terms, in: text)
        let wordStart = ranges.first { range in
            let index = String.Index(utf16Offset: range.lowerBound, in: text)
            guard let before = text[..<index].last else { return true }
            return !(before.isLetter || before.isNumber)
        }
        return wordStart ?? ranges.first
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func trimmed(_ s: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var lo = 0, hi = s.count
        while lo < hi && Chars.isSpace(s[lo]) { lo += 1 }
        while hi > lo && Chars.isSpace(s[hi - 1]) { hi -= 1 }
        return Array(s[lo..<hi])
    }
}
