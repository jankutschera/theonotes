// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// Bear tag grammar. Each rule is one small function so the oracle task can adjust it.
public enum TagScanner {
    struct Match: Equatable {
        /// Covers the opening `#` through the end of the tag (closing `#` included).
        var range: Range<Int>
        var name: String
    }

    /// Tags in a single line of prose, in order (not deduped).
    public static func tags(inLine line: String) -> [String] {
        let s = Array(line.unicodeScalars)
        let scan = InlineScanner.scan(s, startsInComment: false, commentMayContinue: false)
        return find(in: s, mask: scan.mask).map(\.name)
    }

    /// `a/b/c` → `a`, `a/b`, `a/b/c` (materialized parents of a nested tag).
    public static func ancestorPaths(of path: String) -> [String] {
        var result: [String] = []
        var current = ""
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            current = current.isEmpty ? String(component) : current + "/" + component
            result.append(current)
        }
        return result
    }

    /// In a table row (`tableRow`) an unmasked `|` separates cells: it ends a tag.
    static func find(in s: [Unicode.Scalar], mask: [Bool], tableRow: Bool = false) -> [Match] {
        var matches: [Match] = []
        var p = 0
        while p < s.count {
            guard opensTag(s, mask, at: p) else { p += 1; continue }
            if let close = multiWordCloser(s, mask, openerAt: p, tableRow: tableRow) {
                let name = normalize(s[p + 1..<close])
                if !name.isEmpty { matches.append(Match(range: p..<close + 1, name: name)) }
                p = close + 1
                continue
            }
            var end = p + 1
            while end < s.count && !mask[end] && !endsSingleWord(s[end]) && !(tableRow && s[end] == "|") { end += 1 }
            while end > p + 1 && isTrailingTrim(s[end - 1]) { end -= 1 }
            let name = normalize(s[p + 1..<end])
            if !name.isEmpty && !needsClosedForm(name) {
                matches.append(Match(range: p..<end, name: name))
            }
            p = max(end, p + 1)
        }
        return matches
    }

    /// `#` at line start or after whitespace, `(` or `|` (Bear oracle: `a|#b`), followed by a
    /// character that is not whitespace, `#`, or a keycap/variation selector (`#️⃣`).
    static func opensTag(_ s: [Unicode.Scalar], _ mask: [Bool], at p: Int) -> Bool {
        guard s[p] == "#", !mask[p], p + 1 < s.count, !mask[p + 1] else { return false }
        if p > 0 {
            let before = s[p - 1]
            guard Chars.isSpace(before) || before == "(" || before == "|" else { return false }
        }
        let next = s[p + 1]
        return !Chars.isSpace(next) && next != "#" && next != "\u{FE0F}" && next != "\u{20E3}"
    }

    /// Closing `#` of `#words with spaces#` on the same line: preceded by a non-space and
    /// followed by end/whitespace/punctuation. Gives up at a masked span or at a `#` that opens
    /// another tag.
    static func multiWordCloser(_ s: [Unicode.Scalar], _ mask: [Bool], openerAt p: Int, tableRow: Bool = false) -> Int? {
        var j = p + 1
        while j < s.count && !mask[j] && !(tableRow && s[j] == "|") {
            if s[j] == "#" {
                if closesMultiWord(s, at: j) { return j }
                if opensTag(s, mask, at: j) { return nil }
            }
            j += 1
        }
        return nil
    }

    static func closesMultiWord(_ s: [Unicode.Scalar], at j: Int) -> Bool {
        guard !Chars.isSpace(s[j - 1]) else { return false }
        return j + 1 == s.count || endsSingleWord(s[j + 1]) || isTrailingTrim(s[j + 1])
    }

    /// `:`, `+` and `|` may appear inside a single-word tag but are dropped from its end
    /// (Bear oracle: `#+a-b:+c+(1.2)` → `+a-b:+c`, `#a|b|` → `a|b`).
    static func isTrailingTrim(_ c: Unicode.Scalar) -> Bool { c == ":" || c == "+" || c == "|" }

    /// Characters that end a single-word tag. `/`, `-`, `_`, letters, digits, emoji and other
    /// symbols (`+`, `&`, `@`, `:`, …) stay part of the tag.
    static func endsSingleWord(_ c: Unicode.Scalar) -> Bool {
        if Chars.isSpace(c) { return true }
        if c.isASCII {
            switch c {
            case ".", ",", ";", "!", "?", "\"", "'", "(", ")", "[", "]", "{", "}", "<", ">",
                 "#", "*", "~", "=", "`", "\\":
                return true
            default:
                return false
            }
        }
        return Chars.isNonASCIIPunct(c)
    }

    /// Path components trimmed, inner whitespace collapsed, empty components dropped
    /// (`#a//b/` → `a/b`, `#my  tag#` → `my tag`).
    static func normalize(_ raw: ArraySlice<Unicode.Scalar>) -> String {
        var components: [String] = []
        var current = String.UnicodeScalarView()
        var pendingSpace = false
        for c in raw {
            if c == "/" {
                if !current.isEmpty { components.append(String(current)) }
                current = String.UnicodeScalarView()
                pendingSpace = false
            } else if Chars.isSpace(c) {
                pendingSpace = !current.isEmpty
            } else {
                if pendingSpace { current.append(" "); pendingSpace = false }
                current.append(c)
            }
        }
        if !current.isEmpty { components.append(String(current)) }
        return components.joined(separator: "/")
    }

    /// Numbers, slash dates and times (`#2021`, `#10/04`, `#9:30`) and bare separators (`#-`)
    /// are tags only in the closed `#…#` form. Dash dates are open tags (`#2026-07-09`, Bear oracle).
    static func needsClosedForm(_ name: String) -> Bool {
        let scalars = name.unicodeScalars
        return scalars.allSatisfy { Chars.isDigit($0) || $0 == "/" || $0 == "." || $0 == ":" }
            || scalars.allSatisfy { $0 == "-" || $0 == "/" || $0 == "." }
    }
}
