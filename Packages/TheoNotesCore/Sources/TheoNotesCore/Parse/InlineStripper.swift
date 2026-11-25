// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

/// Visible text of a line for titles, previews and heading text: inline markup delimiters,
/// HTML comments, images, attachments and tags removed; links become their text, wiki links
/// their alias (or target). Whitespace is not collapsed here.
enum InlineStripper {
    enum Mode {
        /// Preview and heading text.
        case text
        /// Bear's title (oracle): tags and HTML comments stay verbatim, a file attachment keeps
        /// its link text; its metadata comment and images are still removed.
        case title
        /// Search body: like `.text`, but tags stay as their names (no `#`, no closing `#`).
        case search
    }

    /// 🟢 🔴 🔵 🟡 🟣 — color marker right after a `==` highlight opener.
    static let highlightColors: Set<UInt32> = [0x1F7E2, 0x1F534, 0x1F535, 0x1F7E1, 0x1F7E3]

    static func strip(
        _ s: [Unicode.Scalar], range: Range<Int>, scan: InlineScan,
        tags: [TagScanner.Match], tableRow: Bool, mode: Mode = .text
    ) -> String {
        let lo = range.lowerBound, hi = range.upperBound
        guard lo < hi else { return "" }
        let blocked = blockedPositions(s, range: range, mask: scan.mask, tags: tags)
        let removed = emphasisDelimiters(s, range: range, blocked: blocked)
        var out = String.UnicodeScalarView()
        var p = lo
        var k = 0
        var t = 0
        while p < hi {
            while k < scan.spans.count && scan.spans[k].range.lowerBound < p { k += 1 }
            while t < tags.count && tags[t].range.lowerBound < p { t += 1 }
            if k < scan.spans.count && scan.spans[k].range.lowerBound == p {
                p = emit(scan.spans[k], s, upTo: hi, mode: mode, into: &out)
                k += 1
                continue
            }
            if mode != .title && t < tags.count && tags[t].range.lowerBound == p {
                if mode == .search { out.append(contentsOf: tags[t].name.unicodeScalars) }
                p = tags[t].range.upperBound
                t += 1
                continue
            }
            if !removed[p - lo] {
                out.append(tableRow && s[p] == "|" ? " " : s[p])
            }
            p += 1
        }
        return String(out)
    }

    /// Appends the visible text of a span and returns the position after it.
    private static func emit(
        _ span: InlineSpan, _ s: [Unicode.Scalar], upTo hi: Int, mode: Mode,
        into out: inout String.UnicodeScalarView
    ) -> Int {
        let r = span.range
        func append(_ range: Range<Int>) {
            let clamped = range.clamped(to: r.lowerBound..<hi)
            out.append(contentsOf: s[clamped])
        }
        switch span.kind {
        case .escape:
            append(r.lowerBound + 1..<r.upperBound)
        case .code(let content), .math(let content), .autolink(let content):
            append(content)
        case .url:
            append(r)
        case .comment(let isAttachmentMetadata):
            if mode == .title && !isAttachmentMetadata { append(r) }
        case .linkClose:
            break
        case .wikiLink(let display):
            out.append(contentsOf: display.unicodeScalars)
        case .linkOpen(let dropUntil, let isFile):
            if mode == .title && isFile { return r.upperBound }
            return dropUntil ?? r.upperBound
        }
        return r.upperBound
    }

    private static func blockedPositions(
        _ s: [Unicode.Scalar], range: Range<Int>, mask: [Bool], tags: [TagScanner.Match]
    ) -> [Bool] {
        var blocked = Array(mask[range])
        for tag in tags {
            for i in tag.range where range.contains(i) { blocked[i - range.lowerBound] = true }
        }
        return blocked
    }

    /// Paired emphasis delimiter runs to remove (indexed relative to `range`): `*`/`_` runs of
    /// 1–3, `~` of 1–2, `==` (plus a following color emoji). `_` does not open or close
    /// intraword (`snake_case`). A closer pairs with the nearest opener of the same character
    /// and length; openers above it are discarded.
    static func emphasisDelimiters(_ s: [Unicode.Scalar], range: Range<Int>, blocked: [Bool]) -> [Bool] {
        let lo = range.lowerBound, hi = range.upperBound
        var removed = [Bool](repeating: false, count: hi - lo)
        var stack: [(char: Unicode.Scalar, start: Int, length: Int)] = []
        var p = lo
        while p < hi {
            let c = s[p]
            guard !blocked[p - lo], c == "*" || c == "_" || c == "~" || c == "=" else { p += 1; continue }
            var q = p
            while q < hi && s[q] == c && !blocked[q - lo] { q += 1 }
            let length = q - p
            defer { p = q }
            guard isDelimiterLength(c, length) else { continue }
            let prev: Unicode.Scalar? = p > lo ? s[p - 1] : nil
            let next: Unicode.Scalar? = q < hi ? s[q] : nil
            var canOpen = next.map { !Chars.isSpace($0) } ?? false
            var canClose = prev.map { !Chars.isSpace($0) } ?? false
            if c == "_" {
                canOpen = canOpen && !(prev.map(Chars.isAlnum) ?? false)
                canClose = canClose && !(next.map(Chars.isAlnum) ?? false)
            }
            if canClose, let k = matchingOpener(in: stack, char: c, length: length) {
                let opener = stack[k]
                for i in opener.start..<opener.start + length { removed[i - lo] = true }
                for i in p..<q { removed[i - lo] = true }
                if c == "=" { removeColorMarker(s, at: opener.start + length, lo: lo, hi: q, blocked: blocked, removed: &removed) }
                stack.removeSubrange(k...)
            } else if canOpen {
                stack.append((c, p, length))
            }
        }
        return removed
    }

    private static func isDelimiterLength(_ c: Unicode.Scalar, _ length: Int) -> Bool {
        switch c {
        case "*", "_": return length <= 3
        case "~": return length <= 2
        default: return length == 2
        }
    }

    /// Searches at most 64 entries so pathological lines stay linear.
    private static func matchingOpener(
        in stack: [(char: Unicode.Scalar, start: Int, length: Int)], char: Unicode.Scalar, length: Int
    ) -> Int? {
        var k = stack.count - 1
        var budget = 64
        while k >= 0 && budget > 0 {
            if stack[k].char == char && stack[k].length == length { return k }
            k -= 1
            budget -= 1
        }
        return nil
    }

    private static func removeColorMarker(
        _ s: [Unicode.Scalar], at i: Int, lo: Int, hi: Int, blocked: [Bool], removed: inout [Bool]
    ) {
        guard i < hi, !blocked[i - lo], highlightColors.contains(s[i].value) else { return }
        removed[i - lo] = true
        if i + 1 < hi, s[i + 1] == "\u{FE0F}" { removed[i + 1 - lo] = true }
    }
}
