// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation

/// `mode` of `add-text` and `add-file`.
enum XCallbackMode: String {
    case append, prepend
    case replaceAll = "replace_all"
    case replace

    static func parse(_ raw: String?) throws(XCallbackFailure) -> XCallbackMode {
        guard let raw, !raw.isEmpty else { return .append }
        guard let mode = XCallbackMode(rawValue: raw.lowercased()) else {
            throw .invalid("Invalid mode: \(raw) (use prepend, append, replace_all or replace)")
        }
        return mode
    }
}

/// The text change behind `add-text` / `add-file`, built on `AppendEngine` and `OverwriteEngine`.
/// Pure: the service does the lock check, the write and the retry.
enum XCallbackTextEdit {
    /// The first heading whose text equals `header`, ignoring case and runs of spaces (`#` marks
    /// and closing `#` removed). `usage` (x-callback code 1) when there is none.
    static func section(header: String, in text: String) throws(AutomationError) -> SectionTarget {
        let wanted = SectionAddress.normalize(Substring(header)).lowercased()
        let sections = NoteSections(text: text)
        for (index, section) in sections.sections.enumerated() where headingText(section.headingLine) == wanted {
            return .section(index)
        }
        throw AutomationError(code: .usage, message: "Header not found: \(header)")
    }

    private static func headingText(_ line: String) -> String {
        var text = Substring(line.trimmingCharacters(in: .whitespaces))
        while text.first == "#" { text = text.dropFirst() }
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if let hashes = trimmed.lastIndex(where: { $0 != "#" }), hashes != trimmed.index(before: trimmed.endIndex),
            trimmed[hashes] == " "
        {
            trimmed = String(trimmed[...hashes])
        }
        return SectionAddress.normalize(Substring(trimmed)).lowercased()
    }

    /// `content` added to `text` as `mode` says.
    ///
    /// - `append`: at the end of the note (or of the header's section, subsections included).
    ///   Without `newLine` the text continues the last line (ruling M5-R22), except when that line
    ///   is the title or the section's heading, which are never extended: the text then goes on
    ///   its own line. With `newLine` it always goes on its own line.
    /// - `prepend`: after the title line and the tag lines below it (after the heading line).
    /// - `replace_all`: the whole note (the header's section body, heading kept).
    /// - `replace`: everything after the title line (the header's section body, heading kept).
    static func apply(
        _ content: String, mode: XCallbackMode, newLine: Bool, header: String?, to text: String,
        tagPosition: TagPosition
    ) throws(AutomationError) -> String {
        let target = try header.map { h throws(AutomationError) in try section(header: h, in: text) }
        switch mode {
        case .prepend:
            return AppendEngine.apply(content, position: .beginning, target: target, to: text, tagPosition: tagPosition).text
        case .append:
            if !newLine, let text = continued(content, target: target, in: text, tagPosition: tagPosition) { return text }
            return AppendEngine.apply(content, position: .end, target: target, to: text, tagPosition: tagPosition).text
        case .replaceAll, .replace:
            if case .section(let i)? = target {
                let heading = NoteSections(text: text).sections[i].headingLine
                return try OverwriteEngine.apply(heading + "\n" + content, to: text, target: target)
            }
            if mode == .replaceAll { return content }
            return keepingTitle(content, in: text)
        }
    }

    /// `content` glued to the end of the last body line, nil when that line is the title or the
    /// section's heading.
    private static func continued(
        _ content: String, target: SectionTarget?, in text: String, tagPosition: TagPosition
    ) -> String? {
        let point = AppendEngine.insertionPoint(.end, target: target, in: text, tagPosition: tagPosition)
        let lines = NoteLines(text)
        switch target {
        case nil:
            if point <= lines.end(NoteParser.bodyStartLine(in: text)) { return nil }
        case .section(let i)?:
            if point <= NoteSections(text: text).sections[i].headingEnd { return nil }
        case .preamble?, .lead?:
            return nil
        }
        var at = point
        let bytes = lines.bytes
        if at > 0, bytes[at - 1] == UInt8(ascii: "\n") {
            at -= 1
            if at > 0, bytes[at - 1] == UInt8(ascii: "\r") { at -= 1 }
        }
        return String(decoding: bytes[..<at] + Array(content.utf8) + bytes[at...], as: UTF8.self)
    }

    private static func keepingTitle(_ content: String, in text: String) -> String {
        let lines = NoteLines(text)
        let title = NoteParser.bodyStartLine(in: text)
        guard title < lines.count, !text.isEmpty else { return content }
        var head = Array(lines.bytes[..<lines.end(title)])
        if head.last != UInt8(ascii: "\n") { head += lines.lineBreak }
        return String(decoding: head, as: UTF8.self) + content
    }
}
