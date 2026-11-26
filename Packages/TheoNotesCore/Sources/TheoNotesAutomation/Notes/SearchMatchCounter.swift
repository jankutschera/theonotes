// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation

/// `matches` of a search hit: how many places in the raw note text the
/// positive terms, phrases and tags of the query mark, places that overlap counted once.
/// Observed against Bear (234 notes, 121 queries):
/// - case is ignored, diacritics are not (`fur` does not count `für`, although the note matches);
/// - a needle with `ss` or `ß` also counts `ß` and `ss` in the text, and only then;
/// - a quoted single word counts whole words only (`"build"` skips `building`; `_` and digits are
///   word characters); a phrase with white space counts plain substrings;
/// - a positive tag (`#type`, `!#type`) counts its occurrences in the text, nested tags included
///   for `#type` (the help says 0, but Bear counts them); `#*/ref` counts the text `/ref`;
/// - a term inside a counted tag adds nothing (`#adhd-founder founder` counts the tag once).
/// A query with neither text terms nor tags counts 0.
enum SearchMatchCounter {
    struct Needle: Equatable {
        var text: String
        var isPhrase: Bool
        /// Set for a tag: how it matches the tags of the text.
        var tag: TagMode?

        init(text: String, isPhrase: Bool, tag: TagMode? = nil) {
            self.text = text
            self.isPhrase = isPhrase
            self.tag = tag
        }
    }

    /// The positive terms, phrases and tags of `expr`, each once, in query order.
    static func needles(_ expr: SearchExpr) -> [Needle] {
        var found: [Needle] = []
        func add(_ needle: Needle) { if !found.contains(needle) { found.append(needle) } }
        func walk(_ e: SearchExpr) {
            switch e {
            case .term(let s): add(Needle(text: s, isPhrase: false))
            case .phrase(let s): add(Needle(text: s, isPhrase: true))
            // `#*/ref` highlights the literal `/ref`, wherever it stands in the text.
            case .tag(let name, .subtagsOnly): add(Needle(text: "/" + name, isPhrase: false))
            case .tag(let name, let mode): add(Needle(text: name, isPhrase: false, tag: mode))
            case .special, .not: break
            case .and(let list), .or(let list): list.forEach(walk)
            }
        }
        walk(expr)
        return found
    }

    /// Text folded for matching: lowercased scalar by scalar, with `ß` written `ss` when asked, and
    /// for each folded byte the UTF-8 range of the scalar it came from.
    private struct Folded {
        var bytes: [UInt8] = []
        var starts: [Int] = []
        var ends: [Int] = []

        init(_ text: String, widened: Bool) {
            bytes.reserveCapacity(text.utf8.count)
            starts.reserveCapacity(text.utf8.count)
            ends.reserveCapacity(text.utf8.count)
            var offset = 0
            for scalar in text.unicodeScalars {
                let width = UTF8.width(scalar)
                if scalar.value < 0x80 {
                    let v = UInt8(scalar.value)
                    bytes.append(v >= 0x41 && v <= 0x5A ? v + 0x20 : v)
                    starts.append(offset)
                    ends.append(offset + width)
                } else {
                    var piece = String(scalar).lowercased()
                    if widened, piece == "ß" { piece = "ss" }
                    for byte in piece.utf8 {
                        bytes.append(byte)
                        starts.append(offset)
                        ends.append(offset + width)
                    }
                }
                offset += width
            }
        }
    }

    static func count(_ needles: [Needle], in text: String) -> Int {
        guard !needles.isEmpty, !text.isEmpty else { return 0 }
        let normalized = text.precomposedStringWithCanonicalMapping
        var plain: Folded?
        var wide: Folded?
        var ranges: [Range<Int>] = []
        var spans: [(name: String, bytes: Range<Int>)]?
        for needle in needles {
            if let mode = needle.tag {
                if spans == nil { spans = NoteParser.tagSpans(in: normalized) }
                let key = CanonicalKey.make(needle.text)
                ranges += spans!.filter { matches(tag: CanonicalKey.make($0.name), key: key, mode: mode) }.map(\.bytes)
                continue
            }
            let term = Folded(needle.text.precomposedStringWithCanonicalMapping, widened: false).bytes
            guard !term.isEmpty else { continue }
            let widened = String(decoding: term, as: UTF8.self).contains("ss") || String(decoding: term, as: UTF8.self).contains("ß")
            let haystack: Folded
            let needleBytes: [UInt8]
            if widened {
                if wide == nil { wide = Folded(normalized, widened: true) }
                haystack = wide!
                needleBytes = Folded(needle.text.precomposedStringWithCanonicalMapping, widened: true).bytes
            } else {
                if plain == nil { plain = Folded(normalized, widened: false) }
                haystack = plain!
                needleBytes = term
            }
            let wholeWord = needle.isPhrase && isWord(String(decoding: term, as: UTF8.self))
            ranges += occurrences(of: needleBytes, in: haystack, wholeWord: wholeWord)
        }
        return mergedCount(ranges)
    }

    /// The number of groups of overlapping ranges.
    private static func mergedCount(_ ranges: [Range<Int>]) -> Int {
        var total = 0
        var reach = -1
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if range.lowerBound >= reach {
                total += 1
                reach = range.upperBound
            } else {
                reach = max(reach, range.upperBound)
            }
        }
        return total
    }

    private static func matches(tag: String, key: String, mode: TagMode) -> Bool {
        switch mode {
        case .withDescendants: tag == key || tag.hasPrefix(key + "/")
        case .exact: tag == key
        case .subtagsOnly: false  // counted as the plain text `/key` (see `needles`)
        }
    }

    /// A single word with at least one letter or digit: the case where a quoted phrase is a word.
    private static func isWord(_ term: String) -> Bool {
        var hasWordCharacter = false
        for scalar in term.unicodeScalars {
            if scalar.properties.isWhitespace { return false }
            if isWordScalar(scalar) { hasWordCharacter = true }
        }
        return hasWordCharacter
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || scalar.properties.numericType != nil || scalar == "_"
    }

    /// Non-overlapping occurrences of `needle`, as UTF-8 ranges of the original text.
    private static func occurrences(of needle: [UInt8], in folded: Folded, wholeWord: Bool) -> [Range<Int>] {
        let haystack = folded.bytes
        guard needle.count <= haystack.count else { return [] }
        var found: [Range<Int>] = []
        var index = 0
        let first = needle[0]
        let last = haystack.count - needle.count
        while index <= last {
            if haystack[index] == first, matches(needle, in: haystack, at: index),
                !wholeWord || (!wordBefore(haystack, index) && !wordAfter(haystack, index + needle.count))
            {
                found.append(folded.starts[index]..<folded.ends[index + needle.count - 1])
                index += needle.count
            } else {
                index += 1
            }
        }
        return found
    }

    private static func matches(_ needle: [UInt8], in haystack: [UInt8], at start: Int) -> Bool {
        var k = 1
        while k < needle.count {
            if haystack[start + k] != needle[k] { return false }
            k += 1
        }
        return true
    }

    private static func wordBefore(_ bytes: [UInt8], _ index: Int) -> Bool {
        guard index > 0 else { return false }
        var start = index - 1
        while start > 0, bytes[start] & 0xC0 == 0x80 { start -= 1 }
        guard let scalar = String(decoding: bytes[start..<index], as: UTF8.self).unicodeScalars.first else { return false }
        return isWordScalar(scalar)
    }

    private static func wordAfter(_ bytes: [UInt8], _ index: Int) -> Bool {
        guard index < bytes.count else { return false }
        var end = index + 1
        while end < bytes.count, bytes[end] & 0xC0 == 0x80 { end += 1 }
        guard let scalar = String(decoding: bytes[index..<end], as: UTF8.self).unicodeScalars.first else { return false }
        return isWordScalar(scalar)
    }
}
