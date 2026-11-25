// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation

enum AppendPosition: String {
    case beginning, end
}

/// `append` / `append_to_note` over note text.
enum AppendEngine {
    /// Inserts `content` on lines of its own: a line break goes before it when the insertion point
    /// is not at a line start, and after it when it does not end in `\n`. Added line breaks are
    /// `\r\n` when the note's first line break is, else `\n`; `content` itself is kept as given.
    /// Empty content changes nothing. `insertedAt` is the UTF-8 byte offset of `content` in the
    /// result.
    ///
    /// Whole note: `beginning` is after the title line (the first line after front matter) and the
    /// tag-only lines directly below it; `end` is after the last line that is not part of the
    /// trailing run of blank, tag-only and footnote-definition lines (`[^…]:` and their indented
    /// continuations), so bottom-placed tags, footnotes and the blank lines before them stay last.
    /// A section: `beginning` is after its heading line, `end` after its last non-blank line
    /// (subsections included), keeping the blank lines before the next heading. A preamble: its
    /// start, or after its last non-blank line.
    ///
    /// `tagPosition` (the user's setting) only matters for a note with no body, whose tag lines
    /// below the title are both "top" and "bottom": with `.bottom` they are bottom tags (both
    /// positions go right after the title), with `.top` top tags (both go after them).
    static func apply(
        _ content: String, position: AppendPosition, target: SectionTarget?, to text: String,
        tagPosition: TagPosition = .bottom
    ) -> (text: String, insertedAt: Int) {
        let lines = NoteLines(text)
        let point = insertionPoint(position, target: target, in: text, lines: lines, tagPosition: tagPosition)
        guard !content.isEmpty else { return (text, point) }
        let lineBreak = lines.lineBreak
        var insert: [UInt8] = []
        if point > 0, lines.bytes[point - 1] != UInt8(ascii: "\n") { insert += lineBreak }
        let insertedAt = point + insert.count
        insert += Array(content.utf8)
        if insert.last != UInt8(ascii: "\n") { insert += lineBreak }
        let bytes = lines.bytes
        return (String(decoding: bytes[..<point] + insert + bytes[point...], as: UTF8.self), insertedAt)
    }

    /// The UTF-8 byte offset `apply` inserts at: see `apply` for where each position goes.
    static func insertionPoint(
        _ position: AppendPosition, target: SectionTarget?, in text: String, tagPosition: TagPosition = .bottom
    ) -> Int {
        insertionPoint(position, target: target, in: text, lines: NoteLines(text), tagPosition: tagPosition)
    }

    private static func insertionPoint(
        _ position: AppendPosition, target: SectionTarget?, in text: String, lines: NoteLines,
        tagPosition: TagPosition
    ) -> Int {
        switch target {
        case nil:
            return wholeNotePoint(position, text, lines, tagPosition: tagPosition)
        case .some(let target):
            let sections = NoteSections(text: text)
            let range = sections.range(of: target)
            if position == .beginning {
                if case .section(let i) = target { return sections.sections[i].headingEnd }
                return range.lowerBound
            }
            return lines.endOfLastNonBlankLine(in: range) ?? range.lowerBound
        }
    }

    private static func wholeNotePoint(
        _ position: AppendPosition, _ text: String, _ lines: NoteLines, tagPosition: TagPosition
    ) -> Int {
        let body = NoteParser.bodyStartLine(in: text)
        guard body < lines.count else { return lines.bytes.count }
        let tagLines = Set(NoteParser.tagOnlyLines(in: text))
        // The title line and the tag-only lines directly below it.
        var topEnd = body
        while topEnd + 1 < lines.count, tagLines.contains(topEnd + 1) { topEnd += 1 }
        // Footnote definitions and the indented lines that continue them.
        var footnote = Array(repeating: false, count: lines.count)
        var inFootnote = false
        for i in body..<lines.count where !lines.isBlank(i) {
            inFootnote = lines.isFootnoteDefinition(i) || (inFootnote && lines.isIndented(i))
            footnote[i] = inFootnote
        }
        // The last line before the trailing run of blank, tag-only and footnote lines. With top
        // tags the run never reaches into the tag lines below the title.
        var last = lines.count - 1
        let floor = tagPosition == .top ? topEnd : body
        while last > floor, lines.isBlank(last) || tagLines.contains(last) || footnote[last] { last -= 1 }
        switch position {
        case .end: return lines.end(last)
        case .beginning: return tagPosition == .bottom && last == body ? lines.end(body) : lines.end(topEnd)
        }
    }
}

/// A note's lines, split on `\n` like `NoteParser`, as UTF-8 byte offsets.
struct NoteLines {
    let bytes: [UInt8]
    /// The first byte of each line; a text ending in `\n` has a last, empty line at its end.
    let starts: [Int]

    init(_ text: String) {
        bytes = Array(text.utf8)
        var starts = [0]
        for (i, byte) in bytes.enumerated() where byte == UInt8(ascii: "\n") { starts.append(i + 1) }
        self.starts = starts
    }

    var count: Int { starts.count }

    /// After the line's line break (the end of the text for the last line).
    func end(_ line: Int) -> Int { line + 1 < starts.count ? starts[line + 1] : bytes.count }

    /// The line's bytes without its `\n` or `\r\n`.
    func content(_ line: Int) -> ArraySlice<UInt8> {
        var upper = end(line)
        if upper > starts[line], bytes[upper - 1] == UInt8(ascii: "\n") { upper -= 1 }
        if upper > starts[line], bytes[upper - 1] == UInt8(ascii: "\r") { upper -= 1 }
        return bytes[starts[line]..<upper]
    }

    func isBlank(_ line: Int) -> Bool {
        content(line).allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0B || $0 == 0x0C || $0 == 0x0D }
    }

    /// Starts with a tab or four spaces.
    func isIndented(_ line: Int) -> Bool {
        let c = content(line)
        return c.first == 0x09 || c.prefix(4).elementsEqual([0x20, 0x20, 0x20, 0x20])
    }

    /// `[^label]:` after at most three spaces.
    func isFootnoteDefinition(_ line: Int) -> Bool {
        var c = content(line)
        var spaces = 0
        while spaces < 3, c.first == 0x20 {
            c = c.dropFirst()
            spaces += 1
        }
        guard c.starts(with: Array("[^".utf8)) else { return false }
        let label = c.dropFirst(2)
        guard let close = label.firstIndex(of: UInt8(ascii: "]")), close > label.startIndex else { return false }
        return close + 1 < label.endIndex && label[close + 1] == UInt8(ascii: ":")
    }

    /// The start of the first line inside `range` (line-aligned at its start) that is not blank.
    func startOfFirstNonBlankLine(in range: Range<Int>) -> Int? {
        guard !range.isEmpty else { return nil }
        var low = 0
        var high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] < range.lowerBound { low = mid + 1 } else { high = mid }
        }
        var line = low
        while line < starts.count, starts[line] < range.upperBound {
            if !isBlank(line) { return starts[line] }
            line += 1
        }
        return nil
    }

    /// After the last line inside `range` (line-aligned at its start) that is not blank.
    func endOfLastNonBlankLine(in range: Range<Int>) -> Int? {
        guard !range.isEmpty else { return nil }
        // The line holding the range's last byte, then upwards.
        var low = 0
        var high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= range.upperBound - 1 { low = mid + 1 } else { high = mid }
        }
        var line = low - 1
        while line >= 0, starts[line] >= range.lowerBound {
            if !isBlank(line) { return min(end(line), range.upperBound) }
            line -= 1
        }
        return nil
    }

    /// `\r\n` when the first line break is one, else `\n`.
    var lineBreak: [UInt8] {
        guard starts.count > 1 else { return [0x0A] }
        let first = starts[1] - 1
        return first > 0 && bytes[first - 1] == 0x0D ? [0x0D, 0x0A] : [0x0A]
    }
}
