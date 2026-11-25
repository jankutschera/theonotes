// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation

/// `overwrite` / `overwrite_note` over note text. The hash check (`--base`) is the command's.
enum OverwriteEngine {
    /// Whole note: `content`. A section (heading line through its subsections): `content` must be
    /// empty or begin with a heading of the section's level. A preamble: `content` must not begin
    /// with a heading. Empty content deletes the whole section or preamble, blank lines included.
    /// Other content replaces the target (ruling M5-R76), except that each edge run of blank lines
    /// (before the next heading, and leading a preamble) is kept unless the content supplies its
    /// own: content ending in blank lines replaces the old trailing run, content starting with a
    /// blank line the old leading run. Writing back exactly what `cat --section` returned therefore
    /// leaves the note byte-identical. When content does not end in `\n`, the line break that
    /// ended the last replaced line (`\n` or `\r\n`) is re-added; there is none at the end of the
    /// note.
    static func apply(_ content: String, to text: String, target: SectionTarget?) throws(AutomationError) -> String {
        guard let target else { return content }
        let sections = NoteSections(text: text)
        let firstHeading = content.isEmpty ? nil : NoteParser.metadata(for: content).headings.first { $0.line == 1 }
        switch target {
        case .section(let i):
            let level = sections.sections[i].level
            if !content.isEmpty, firstHeading?.level != level {
                throw AutomationError(
                    code: .usage, message: "The new content has to start with the section's own heading (a level-\(level) heading)")
            }
        case .preamble, .lead:
            if firstHeading != nil {
                throw AutomationError(code: .usage, message: "Preamble content must not begin with a heading")
            }
        }
        var range = sections.range(of: target)
        let lines = NoteLines(text)
        let bytes = lines.bytes
        var replacement = Array(content.utf8)
        if !replacement.isEmpty {
            // An edge run of blank lines (leading a preamble, or before the next heading) is
            // replaced only when the content brings its own; otherwise it stays.
            let given = NoteLines(content)
            let whole = 0..<given.bytes.count
            let ownLeading = (given.startOfFirstNonBlankLine(in: whole) ?? 1) > 0
            let ownTrailing = (given.endOfLastNonBlankLine(in: whole) ?? 0) < given.bytes.count
            let lower = ownLeading ? range.lowerBound : lines.startOfFirstNonBlankLine(in: range) ?? range.lowerBound
            let upper = ownTrailing ? range.upperBound : lines.endOfLastNonBlankLine(in: range) ?? range.upperBound
            range = lower..<upper
            if replacement.last != UInt8(ascii: "\n"), range.upperBound > range.lowerBound,
                bytes[range.upperBound - 1] == UInt8(ascii: "\n")
            {
                let crlf = range.upperBound - 2 >= range.lowerBound && bytes[range.upperBound - 2] == UInt8(ascii: "\r")
                replacement += crlf ? Array("\r\n".utf8) : [UInt8(ascii: "\n")]
            }
        }
        return String(decoding: bytes[..<range.lowerBound] + replacement + bytes[range.upperBound...], as: UTF8.self)
    }
}
