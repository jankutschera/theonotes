// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// Bear tables (ruling M6-R1): a header row, then a delimiter row with the same cell count, then
/// body rows. Every row's trimmed text starts with `|` and ends with a `|` that separates cells.
/// The table ends at the first line that is not a row of it; a header row can interrupt a
/// paragraph. Tables can sit in quotes and list items; `NoteParser.scan` only asks about prose
/// lines, so never inside code, math, comments or front matter. The editor's BearTable parser
/// (web/editor/src/editor/dialect-grammar.ts, dialect-blocks.ts) applies the same rules.
enum TableScanner {
    /// A line that can be a table row: `|` … `|` after optional quotes, blanks and a list marker.
    struct RowShape {
        var quoteDepth: Int
        /// Columns from the end of the quote markers to the leading `|`.
        var column: Int
        var hasListMarker: Bool
        /// Offset of the leading `|`.
        var from: Int
        /// Trimmed end (after the trailing `|`).
        var to: Int
    }

    static func rowShape(_ s: [Unicode.Scalar]) -> RowShape? {
        let to = LineShape.trimmedEnd(s)
        guard to >= 2, s[to - 1] == "|" else { return nil }
        let quotes = NoteParser.Fence.quotePrefix(s)
        var p = quotes.end
        while p < to && Chars.isBlank(s[p]) { p += 1 }
        let afterMarker = LineShape.bulletEnd(s, from: p, to: to) ?? LineShape.orderedMarkerEnd(s, from: p, to: to)
        if let afterMarker { p = afterMarker }
        guard p < to, s[p] == "|", to - 1 > p else { return nil }
        return RowShape(
            quoteDepth: quotes.depth, column: NoteParser.Fence.columns(s[quotes.end..<p]),
            hasListMarker: afterMarker != nil, from: p, to: to
        )
    }

    /// Offsets of the cell separators: every `|` outside escapes, code spans, math, wiki links,
    /// link destinations, URLs and comments of the line. Nil when the row's first or last `|` is
    /// not one (`… \|`).
    static func separators(_ s: [Unicode.Scalar], _ shape: RowShape) -> [Int]? {
        let mask = InlineScanner.scan(s, startsInComment: false, commentMayContinue: false).mask
        let out = (shape.from..<shape.to).filter { s[$0] == "|" && !mask[$0] }
        return out.first == shape.from && out.last == shape.to - 1 ? out : nil
    }

    /// Cell count of a delimiter row (`|---|:-:|`), or -1 when the row is not one.
    static func delimiterCells(_ s: [Unicode.Scalar], _ shape: RowShape) -> Int {
        var i = shape.from + 1
        var cells = 0
        while i < shape.to {
            while i < shape.to && Chars.isBlank(s[i]) { i += 1 }
            if i < shape.to && s[i] == ":" { i += 1 }
            var dashes = 0
            while i < shape.to && s[i] == "-" { dashes += 1; i += 1 }
            guard dashes > 0 else { return -1 }
            if i < shape.to && s[i] == ":" { i += 1 }
            while i < shape.to && Chars.isBlank(s[i]) { i += 1 }
            guard i < shape.to, s[i] == "|" else { return -1 }
            i += 1
            cells += 1
        }
        return cells
    }

    /// Whether `row` is in the table `header` starts: same quotes, no list marker, not outdented.
    static func inTable(_ header: RowShape, _ row: RowShape) -> Bool {
        row.quoteDepth == header.quoteDepth && !row.hasListMarker && row.column >= header.column
    }

    /// Whether `line` is a body row (or the delimiter row) of the table `header` starts.
    static func isRow(of header: RowShape, _ line: [Unicode.Scalar]) -> Bool {
        guard let row = rowShape(line), inTable(header, row) else { return false }
        return separators(line, row) != nil
    }

    /// The header shape when `line` followed by `next` starts a table.
    static func header(_ line: [Unicode.Scalar], next: [Unicode.Scalar]?) -> RowShape? {
        guard let next, let header = rowShape(line), let row = rowShape(next), inTable(header, row) else { return nil }
        let cells = delimiterCells(next, row)
        guard cells >= 1, let separators = separators(line, header), separators.count - 1 == cells else { return nil }
        return header
    }
}
