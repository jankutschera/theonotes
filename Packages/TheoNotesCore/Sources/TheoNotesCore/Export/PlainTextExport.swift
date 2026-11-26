// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// Plain-text export of a note: the Markdown without its markup.
///
/// Removed: front matter, heading markers (`# `), code fence lines (the code stays verbatim),
/// table delimiter rows (cell pipes become tabs) and attachment metadata comments. Every other
/// prose line goes through `InlineStripper` mode `.title`: tags stay as typed, emphasis and
/// highlight delimiters go, links become their text, wiki links their alias or title, images
/// vanish, file links keep their text. List, todo and quote markers stay as typed. Lines inside
/// `$$` math blocks stay verbatim, with their fences.
public enum PlainTextExport {
    private enum Block {
        case prose
        case fence(NoteParser.Fence)
        case math
    }

    private static let commentOpen: [Unicode.Scalar] = ["<", "!", "-", "-"]
    private static let commentClose: [Unicode.Scalar] = ["-", "-", ">"]

    public static func text(_ markdown: String) -> String {
        let lines = NoteParser.splitLines(markdown)
        let lastCommentCloseLine = lines.lastIndex { Chars.find(commentClose, in: $0, from: 0) != nil } ?? -1
        let lastMathFenceLine = lines.lastIndex(where: NoteParser.isMathFence) ?? -1
        var out: [String] = []
        var index = NoteParser.frontMatterEnd(lines) ?? 0
        var block = Block.prose
        var inComment = false
        var strayCloser: (marker: Unicode.Scalar, length: Int)?
        var table: TableScanner.RowShape?
        var delimiterLine = -1
        while index < lines.count {
            let line = lines[index]
            defer { index += 1 }
            if inComment {
                table = nil
                let result = prose(line, startsInComment: true, commentMayContinue: index < lastCommentCloseLine, tableRow: false)
                out.append(result.text)
                inComment = result.endsInComment
                continue
            }
            switch block {
            case .fence(let fence):
                switch fence.classify(line) {
                case .close:
                    block = .prose
                    continue
                case .content:
                    out.append(Chars.string(line[...]))
                    continue
                case .ended(let byIndent):
                    block = .prose
                    if byIndent { strayCloser = (fence.marker, fence.length) }
                }
            case .math:
                if NoteParser.isMathFence(line) { block = .prose }
                out.append(Chars.string(line[...]))
                continue
            case .prose:
                break
            }
            let inTable = table.map { TableScanner.isRow(of: $0, line) } ?? false
            if !inTable {
                table = TableScanner.header(line, next: index + 1 < lines.count ? lines[index + 1] : nil)
                if table != nil { delimiterLine = index + 1 }
            }
            if table != nil {
                if index != delimiterLine {
                    out.append(prose(line, startsInComment: false, commentMayContinue: false, tableRow: true).text)
                }
                continue
            }
            if let stray = strayCloser, NoteParser.Fence.isBareCloser(line, from: 0, marker: stray.marker, length: stray.length) {
                strayCloser = nil
            } else if let fence = NoteParser.Fence.open(line) {
                strayCloser = nil
                block = .fence(fence)
            } else if NoteParser.isMathFence(line) && index < lastMathFenceLine {
                block = .math
                out.append(Chars.string(line[...]))
            } else {
                let result = prose(line, startsInComment: false, commentMayContinue: index < lastCommentCloseLine, tableRow: false)
                out.append(result.text)
                inComment = result.endsInComment
            }
        }
        return out.joined(separator: "\n")
    }

    /// One prose line: markers kept as typed (a heading's dropped), the rest stripped.
    private static func prose(
        _ s: [Unicode.Scalar], startsInComment: Bool, commentMayContinue: Bool, tableRow: Bool
    ) -> (text: String, endsInComment: Bool) {
        let scan = InlineScanner.scan(s, startsInComment: startsInComment, commentMayContinue: commentMayContinue)
        let tags = TagScanner.find(in: s, mask: scan.mask, tableRow: tableRow && !startsInComment)
        func strip(_ range: Range<Int>) -> String {
            InlineStripper.strip(s, range: range, scan: scan, tags: tags, tableRow: false, mode: .title)
        }

        if tableRow, !startsInComment, let shape = TableScanner.rowShape(s),
           let separators = TableScanner.separators(s, shape) {
            var cells: [String] = []
            for (open, close) in zip(separators, separators.dropFirst()) {
                var lower = open + 1, upper = close
                while lower < upper, Chars.isBlank(s[lower]) { lower += 1 }
                while upper > lower, Chars.isBlank(s[upper - 1]) { upper -= 1 }
                cells.append(strip(lower..<upper))
            }
            return (Chars.string(s[0..<shape.from]) + cells.joined(separator: "\t"), scan.endsInComment)
        }

        let shape = startsInComment ? LineShape.plain(s) : LineShape.parse(s)
        let keep = startsInComment ? 0 : headingPrefixLength(s) ?? shape.content.lowerBound
        return (Chars.string(s[0..<keep]) + strip(shape.content), scan.endsInComment)
    }

    /// For an ATX heading, how much of the line before `#` is kept: the quote markers when the
    /// heading sits in a quote, otherwise nothing. Nil when the line is not a heading.
    private static func headingPrefixLength(_ s: [Unicode.Scalar]) -> Int? {
        let end = LineShape.trimmedEnd(s)
        var p = 0
        while p < end, Chars.isBlank(s[p]) { p += 1 }
        var quoted = false
        while p < end, s[p] == ">" {
            quoted = true
            p += 1
            while p < end, Chars.isBlank(s[p]) { p += 1 }
        }
        if quoted { p = LineShape.skipCalloutMarker(s, from: p, to: end) }
        guard LineShape.atxHeading(s, from: p, to: end) != nil else { return nil }
        return quoted ? p : 0
    }
}
