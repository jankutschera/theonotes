// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// A recognized inline construct in one line (scalar offsets).
struct InlineSpan {
    enum Kind: Equatable {
        /// `\x` — the backslash is dropped, `x` is literal.
        case escape
        case code(content: Range<Int>)
        case math(content: Range<Int>)
        /// `isAttachmentMetadata`: the `<!-- {…} -->` right after an attachment link.
        case comment(isAttachmentMetadata: Bool)
        case autolink(content: Range<Int>)
        case url
        case wikiLink(display: String)
        /// `[` or `![`; `dropUntil` set for images and attachments (whole link hidden from text).
        /// `isFile`: a non-image attachment, whose link text titles keep (Bear oracle).
        case linkOpen(dropUntil: Int?, isFile: Bool)
        /// `](destination "title")`
        case linkClose
    }

    var range: Range<Int>
    var kind: Kind
}

struct InlineScan {
    /// Sorted by start. Spans are disjoint except those inside link text.
    var spans: [InlineSpan] = []
    /// `true` where tags and emphasis must not be recognized.
    var mask: [Bool]
    var wikiLinks: [WikiLinkRef] = []
    /// The same links with their extents in the line (parallel to `wikiLinks`).
    var wikiLinkSpans: [WikiLinkParser.Link] = []
    var attachments: [AttachmentRef] = []
    /// Scalar offset of each attachment link's `[` or `![` (parallel to `attachments`).
    var attachmentStarts: [Int] = []
    /// Scalar range of each attachment link's destination as written, inside the parentheses and
    /// without `<…>` (parallel to `attachments`).
    var attachmentDestinations: [Range<Int>] = []
    var hasInlineCode = false
    /// The line ends inside an unclosed `<!--` that continues on a later line.
    var endsInComment = false
}

/// Inline pass over one prose line: escapes, code spans, math, HTML comments, autolinks,
/// bare URLs, wiki links and links/images (CommonMark precedence: code spans first, then
/// left-to-right). Linear in the line length.
enum InlineScanner {
    /// `? ! . , : * _ ~`: trailing punctuation that ends a sentence, not the URL (GFM autolinks).
    private static let urlTrailing: Set<Unicode.Scalar> = ["?", "!", ".", ",", ":", "*", "_", "~"]

    /// Where a bare URL running from `bodyFrom` (after `://`) to `to` really ends (M6-R43, GFM's
    /// extended autolink rule; JS `urlEnd`): trailing `? ! . , : * _ ~` are dropped, and a trailing
    /// `)` only while the URL has more `)` than `(`. Never before `bodyFrom`.
    static func urlEnd(_ s: [Unicode.Scalar], bodyFrom: Int, to: Int) -> Int {
        var open = 0
        var close = 0
        for i in bodyFrom..<max(bodyFrom, to) {
            if s[i] == "(" { open += 1 } else if s[i] == ")" { close += 1 }
        }
        var end = to
        while end > bodyFrom {
            let c = s[end - 1]
            if urlTrailing.contains(c) {
                end -= 1
            } else if c == ")" && close > open {
                end -= 1
                close -= 1
            } else {
                break
            }
        }
        return end
    }

    private static let commentOpen: [Unicode.Scalar] = ["<", "!", "-", "-"]
    private static let commentClose: [Unicode.Scalar] = ["-", "-", ">"]
    private static let doubleDollar: [Unicode.Scalar] = ["$", "$"]

    /// - Parameters:
    ///   - startsInComment: the line begins inside a multi-line HTML comment.
    ///   - commentMayContinue: a `-->` exists on a later line, so an unclosed `<!--` runs on.
    static func scan(_ s: [Unicode.Scalar], startsInComment: Bool, commentMayContinue: Bool) -> InlineScan {
        var state = State(s: s, commentMayContinue: commentMayContinue)
        state.run(startsInComment: startsInComment)
        return state.finish()
    }

    private struct State {
        let s: [Unicode.Scalar]
        let n: Int
        let commentMayContinue: Bool
        var result: InlineScan
        var p = 0
        /// End of the last recognized span; bare-URL schemes never extend before it.
        var floor = 0
        var brackets: [(pos: Int, isImage: Bool)] = []
        var ticks: BacktickRuns
        var noSingleDollarCloser = false
        var noDoubleDollarCloser = false
        var noCommentCloseInLine = false
        /// Offsets of `<!--` that carry attachment metadata (found when the link closes).
        var metadataComments: Set<Int> = []

        init(s: [Unicode.Scalar], commentMayContinue: Bool) {
            self.s = s
            self.n = s.count
            self.commentMayContinue = commentMayContinue
            self.result = InlineScan(mask: [Bool](repeating: false, count: s.count))
            self.ticks = BacktickRuns(s)
        }

        mutating func add(_ kind: InlineSpan.Kind, _ range: Range<Int>) {
            result.spans.append(InlineSpan(range: range, kind: kind))
            floor = max(floor, range.upperBound)
        }

        mutating func run(startsInComment: Bool) {
            if startsInComment {
                if let close = Chars.find(InlineScanner.commentClose, in: s, from: 0) {
                    add(.comment(isAttachmentMetadata: false), 0..<close + 3)
                    p = close + 3
                } else {
                    add(.comment(isAttachmentMetadata: false), 0..<n)
                    result.endsInComment = true
                    return
                }
            }
            while p < n {
                switch s[p] {
                case "\\": escape()
                case "`": codeSpan()
                case "$": math()
                case "<": angle()
                case ":": bareURL()
                case "!": bang()
                case "[": openBracket()
                case "]": closeBracket()
                default: p += 1
                }
            }
        }

        mutating func escape() {
            if p + 1 < n, Chars.isASCIIPunct(s[p + 1]) {
                add(.escape, p..<p + 2)
                p += 2
            } else {
                p += 1
            }
        }

        mutating func codeSpan() {
            var len = 0
            while p + len < n && s[p + len] == "`" { len += 1 }
            if let close = ticks.closer(length: len, from: p + len) {
                add(.code(content: p + len..<close), p..<close + len)
                result.hasInlineCode = true
                p = close + len
            } else {
                p += len
            }
        }

        /// `$$…$$` on one line, or `$…$` where the opener is not followed by whitespace and the
        /// closer is not preceded by whitespace nor followed by a digit (so `$5 and $10` is text).
        mutating func math() {
            if p + 1 < n && s[p + 1] == "$" {
                if !noDoubleDollarCloser, let close = Chars.find(InlineScanner.doubleDollar, in: s, from: p + 2),
                   close > p + 2 {
                    add(.math(content: p + 2..<close), p..<close + 2)
                    p = close + 2
                } else {
                    noDoubleDollarCloser = true
                    p += 2
                }
                return
            }
            guard p + 1 < n, !Chars.isSpace(s[p + 1]), !noSingleDollarCloser else { p += 1; return }
            var q = p + 2
            while q < n {
                if s[q] == "$", !Chars.isSpace(s[q - 1]), s[q - 1] != "\\",
                   q + 1 == n || (!Chars.isDigit(s[q + 1]) && s[q + 1] != "$") {
                    add(.math(content: p + 1..<q), p..<q + 1)
                    p = q + 1
                    return
                }
                q += 1
            }
            noSingleDollarCloser = true
            p += 1
        }

        mutating func angle() {
            if p + 3 < n, s[p + 1] == "!", s[p + 2] == "-", s[p + 3] == "-" {
                if !noCommentCloseInLine, let close = Chars.find(InlineScanner.commentClose, in: s, from: p + 4) {
                    add(.comment(isAttachmentMetadata: metadataComments.contains(p)), p..<close + 3)
                    p = close + 3
                    return
                }
                noCommentCloseInLine = true
                if commentMayContinue {
                    add(.comment(isAttachmentMetadata: metadataComments.contains(p)), p..<n)
                    result.endsInComment = true
                    p = n
                } else {
                    p += 1
                }
                return
            }
            // Autolink `<scheme:…>`.
            var q = p + 1
            while q < n && Chars.isSchemeChar(s[q]) { q += 1 }
            let schemeLength = q - p - 1
            guard schemeLength >= 2, schemeLength <= 32, Chars.isASCIILetter(s[p + 1]), q < n, s[q] == ":" else {
                p += 1
                return
            }
            while q < n && s[q] != ">" && s[q] != "<" && !Chars.isSpace(s[q]) { q += 1 }
            guard q < n, s[q] == ">" else { p += 1; return }
            add(.autolink(content: p + 1..<q), p..<q + 1)
            p = q + 1
        }

        /// A bare `scheme://…` token (ends at whitespace, `<`, `>`, `"` or `]`).
        mutating func bareURL() {
            guard p + 2 < n, s[p + 1] == "/", s[p + 2] == "/", p > floor, Chars.isSchemeChar(s[p - 1]) else {
                p += 1
                return
            }
            var start = p
            while start > floor && Chars.isSchemeChar(s[start - 1]) { start -= 1 }
            while start < p && !Chars.isASCIILetter(s[start]) { start += 1 }
            guard start < p else { p += 1; return }
            var q = p + 3
            while q < n {
                let c = s[q]
                if Chars.isSpace(c) || c == "<" || c == ">" || c == "\"" || c == "]" { break }
                q += 1
            }
            q = InlineScanner.urlEnd(s, bodyFrom: p + 3, to: q)
            add(.url, start..<q)
            p = q
        }

        mutating func bang() {
            if p + 1 < n, s[p + 1] == "[", !(p + 2 < n && s[p + 2] == "[") {
                brackets.append((p, true))
                p += 2
            } else {
                p += 1
            }
        }

        mutating func openBracket() {
            if p + 1 < n, s[p + 1] == "[", let link = WikiLinkParser.parse(s, at: p) {
                add(.wikiLink(display: link.display), p..<link.end)
                result.wikiLinks.append(link.ref)
                result.wikiLinkSpans.append(link)
                p = link.end
            } else {
                brackets.append((p, false))
                p += 1
            }
        }

        mutating func closeBracket() {
            guard let opener = brackets.popLast(), p + 1 < n, s[p + 1] == "(",
                  let dest = LinkDestination.parseWithRange(s, from: p + 2) else {
                p += 1
                return
            }
            let metadataStart = LinkDestination.metadataCommentStart(s, after: dest.end)
            let isAttachment = LinkDestination.isRelative(dest.text) && (opener.isImage || metadataStart != nil)
            let drop = opener.isImage || isAttachment
            let openLength = opener.isImage ? 2 : 1
            add(.linkOpen(dropUntil: drop ? dest.end : nil, isFile: isAttachment && !opener.isImage),
                opener.pos..<opener.pos + openLength)
            add(.linkClose, p..<dest.end)
            if isAttachment {
                if let metadataStart { metadataComments.insert(metadataStart) }
                result.attachments.append(AttachmentRef(
                    filename: dest.text.removingPercentEncoding ?? dest.text,
                    isImage: opener.isImage,
                    metadata: LinkDestination.metadata(s, after: dest.end)
                ))
                result.attachmentStarts.append(opener.pos)
                result.attachmentDestinations.append(dest.textRange)
            }
            if !opener.isImage { brackets.removeAll { !$0.isImage } }
            p = dest.end
        }

        mutating func finish() -> InlineScan {
            result.spans.sort { $0.range.lowerBound < $1.range.lowerBound }
            for span in result.spans {
                let masked: Range<Int>
                if case .linkOpen(let dropUntil, _) = span.kind {
                    masked = span.range.lowerBound..<(dropUntil ?? span.range.upperBound)
                } else {
                    masked = span.range
                }
                for i in masked where i < n { result.mask[i] = true }
            }
            return result
        }
    }
}

/// Positions of maximal backtick runs, queried monotonically for a closer of exact length.
struct BacktickRuns {
    private var startsByLength: [Int: [Int]] = [:]
    private var cursor: [Int: Int] = [:]

    init(_ s: [Unicode.Scalar]) {
        var i = 0
        while i < s.count {
            guard s[i] == "`" else { i += 1; continue }
            var j = i
            while j < s.count && s[j] == "`" { j += 1 }
            startsByLength[j - i, default: []].append(i)
            i = j
        }
    }

    mutating func closer(length: Int, from position: Int) -> Int? {
        guard let starts = startsByLength[length] else { return nil }
        var k = cursor[length, default: 0]
        while k < starts.count && starts[k] < position { k += 1 }
        cursor[length] = k
        return k < starts.count ? starts[k] : nil
    }
}

enum WikiLinkParser {
    /// A parsed link with the raw (as written) extents of its parts, in scalar offsets.
    struct Link {
        var end: Int
        var ref: WikiLinkRef
        var display: String
        /// From after `[[` to the first unescaped `/` (or the alias separator, or `]]`).
        var targetRange: Range<Int>
        /// After that `/` up to the alias separator (or `]]`); nil without a `/`.
        var headingRange: Range<Int>?
    }

    /// `[[target/heading|alias]]` at `p`. `\/` keeps a slash in the target; `\|` (tables) and `|`
    /// both separate the alias. The first unescaped `/` separates the heading.
    static func parse(_ s: [Unicode.Scalar], at p: Int) -> Link? {
        var q = p + 2
        while q < s.count && s[q] != "]" && s[q] != "[" { q += 1 }
        guard q + 1 < s.count, s[q] == "]", s[q + 1] == "]" else { return nil }
        let bodyStart = p + 2
        var targetEnd = q
        var aliasStart: Int?
        var i = bodyStart
        while i < q {
            if s[i] == "|" {
                targetEnd = (i > bodyStart && s[i - 1] == "\\") ? i - 1 : i
                aliasStart = i + 1
                break
            }
            i += 1
        }
        var target = String.UnicodeScalarView()
        var heading: String.UnicodeScalarView?
        var slash: Int?
        i = bodyStart
        while i < targetEnd {
            let c = s[i]
            if c == "\\", i + 1 < targetEnd, s[i + 1] == "/" {
                if heading != nil { heading!.append("/") } else { target.append("/") }
                i += 2
                continue
            }
            if c == "/", heading == nil {
                heading = String.UnicodeScalarView()
                slash = i
            } else if heading != nil {
                heading!.append(c)
            } else {
                target.append(c)
            }
            i += 1
        }
        let targetText = Chars.collapse(String(target))
        let headingText = heading.map { Chars.collapse(String($0)) }.flatMap { $0.isEmpty ? nil : $0 }
        let aliasText = aliasStart.map { Chars.collapse(Chars.string(s[$0..<q])) }.flatMap { $0.isEmpty ? nil : $0 }
        guard !(targetText.isEmpty && headingText == nil) else { return nil }
        let ref = WikiLinkRef(target: targetText, heading: headingText, alias: aliasText)
        let display: String
        if let aliasText {
            display = aliasText
        } else if let headingText {
            display = targetText.isEmpty ? headingText : targetText + "/" + headingText
        } else {
            display = targetText
        }
        return Link(
            end: q + 2, ref: ref, display: display,
            targetRange: bodyStart..<(slash ?? targetEnd),
            headingRange: slash.map { $0 + 1..<targetEnd }
        )
    }
}

enum LinkDestination {
    /// Parses `destination "title")` starting right after `(`.
    static func parse(_ s: [Unicode.Scalar], from start: Int) -> (text: String, end: Int)? {
        parseWithRange(s, from: start).map { ($0.text, $0.end) }
    }

    /// `parse` plus the scalar range of the destination text in `s` (inside `<…>` when angled).
    static func parseWithRange(
        _ s: [Unicode.Scalar], from start: Int
    ) -> (text: String, end: Int, textRange: Range<Int>)? {
        let n = s.count
        var q = start
        while q < n && Chars.isBlank(s[q]) { q += 1 }
        let text: String
        let textRange: Range<Int>
        if q < n && s[q] == "<" {
            var r = q + 1
            while r < n && s[r] != ">" && s[r] != "<" { r += 1 }
            guard r < n, s[r] == ">" else { return nil }
            text = Chars.string(s[q + 1..<r])
            textRange = q + 1..<r
            q = r + 1
        } else {
            let destStart = q
            var depth = 0
            while q < n {
                let c = s[q]
                if c == "\\" && q + 1 < n { q += 2; continue }
                if Chars.isSpace(c) { break }
                if c == "(" {
                    depth += 1
                } else if c == ")" {
                    if depth == 0 { break }
                    depth -= 1
                }
                q += 1
            }
            guard depth == 0 else { return nil }
            text = Chars.string(s[destStart..<min(q, n)])
            textRange = destStart..<min(q, n)
        }
        let beforeTitle = q
        while q < n && Chars.isBlank(s[q]) { q += 1 }
        if q < n, q > beforeTitle, s[q] == "\"" || s[q] == "'" || s[q] == "(" {
            let close: Unicode.Scalar = s[q] == "(" ? ")" : s[q]
            var r = q + 1
            while r < n && s[r] != close {
                r += (s[r] == "\\" && r + 1 < n) ? 2 : 1
            }
            guard r < n else { return nil }
            q = r + 1
            while q < n && Chars.isBlank(s[q]) { q += 1 }
        }
        guard q < n, s[q] == ")" else { return nil }
        return (text, q + 1, textRange)
    }

    /// Relative destination: not empty, no `scheme:`, not `#…`, `/…` or `?…`. An image with a
    /// relative destination is an attachment; any other link only when a `<!-- {…} -->` metadata
    /// comment follows it (Bear writes one for every file; plain `[x.com](x.com)` or
    /// `[notes.md](notes.md)` links are not files — Bear oracle).
    static func isRelative(_ dest: String) -> Bool {
        guard let first = dest.unicodeScalars.first, first != "#", first != "/", first != "?" else { return false }
        guard Chars.isASCIILetter(first) else { return true }
        for c in dest.unicodeScalars.dropFirst() {
            if c == ":" { return false }
            if !Chars.isSchemeChar(c) { return true }
        }
        return true
    }

    /// Offset of a `<!-- {` comment right after the link (blanks allowed), if any.
    static func metadataCommentStart(_ s: [Unicode.Scalar], after end: Int) -> Int? {
        var q = end
        while q < s.count && Chars.isBlank(s[q]) { q += 1 }
        guard q + 3 < s.count, s[q] == "<", s[q + 1] == "!", s[q + 2] == "-", s[q + 3] == "-" else { return nil }
        var r = q + 4
        while r < s.count && Chars.isSpace(s[r]) { r += 1 }
        return r < s.count && s[r] == "{" ? q : nil
    }

    /// `<!-- {"width":"320"} -->` right after the link (blanks allowed); values stringified.
    static func metadata(_ s: [Unicode.Scalar], after end: Int) -> [String: String] {
        var q = end
        while q < s.count && Chars.isBlank(s[q]) { q += 1 }
        guard q + 3 < s.count, s[q] == "<", s[q + 1] == "!", s[q + 2] == "-", s[q + 3] == "-",
              let close = Chars.find(["-", "-", ">"], in: s, from: q + 4) else { return [:] }
        let json = Chars.string(s[q + 4..<close])
        guard let values = try? JSONDecoder().decode([String: MetadataValue].self, from: Data(json.utf8)) else {
            return [:]
        }
        return values.compactMapValues(\.text)
    }

    private struct MetadataValue: Decodable {
        let text: String?

        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let v = try? c.decode(String.self) {
                text = v
            } else if let v = try? c.decode(Bool.self) {
                text = v ? "true" : "false"
            } else if let v = try? c.decode(Int.self) {
                text = String(v)
            } else if let v = try? c.decode(Double.self) {
                text = String(v)
            } else {
                text = nil
            }
        }
    }
}
