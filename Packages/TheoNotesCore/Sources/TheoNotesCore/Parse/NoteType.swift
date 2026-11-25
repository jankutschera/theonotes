// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// A note's type, carried by one reserved direct tag (`#idea`, `#log`, `#ref`). Nested tags such
/// as `#ref/recipes` are ordinary tags.
public enum NoteType: String, CaseIterable, Sendable, Codable {
    case idea, log, reference

    public var tagName: String {
        switch self {
        case .idea: "idea"
        case .log: "log"
        case .reference: "ref"
        }
    }

    public var displayName: String {
        switch self {
        case .idea: "Idea"
        case .log: "Log"
        case .reference: "Reference"
        }
    }

    /// The type a whole tag path names (case-insensitive, exact: no nested path), else `nil`.
    public static func reserved(tagPath: String) -> NoteType? {
        let key = CanonicalKey.make(tagPath)
        return allCases.first { $0.tagName == key }
    }

    /// Whether `path` is exactly one of the three reserved tags (a workspace or tag rename may not use it).
    public static func isReservedWorkspace(path: String) -> Bool { reserved(tagPath: path) != nil }

    /// The first reserved tag in `directTags` (text order, as `NoteMetadata.tags` gives them).
    public static func of(directTags: [String]) -> NoteType? {
        directTags.lazy.compactMap(reserved(tagPath:)).first
    }
}

/// Text edits that set, change or clear a note's type tag. Tag ranges come from the indexer's
/// scan, so code, URLs and the like never count.
public enum NoteTypeText {
    /// The smallest span (common prefix and suffix cut off, on scalar boundaries) that turns `old`
    /// into `new`; `from`/`to` are UTF-16 offsets in `old`, the editor's unit. nil when equal.
    public static func smallestChange(from old: String, to new: String) -> (from: Int, to: Int, expect: String, text: String)? {
        guard old != new else { return nil }
        let a = Array(old.unicodeScalars), b = Array(new.unicodeScalars)
        var head = 0
        while head < min(a.count, b.count), a[head] == b[head] { head += 1 }
        var tail = 0
        while tail < min(a.count, b.count) - head, a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
        func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars)
            return String(view)
        }
        let from = a[..<head].reduce(0) { $0 + $1.utf16.count }
        let expect = string(a[head..<(a.count - tail)])
        return (from, from + expect.utf16.count, expect, string(b[head..<(b.count - tail)]))
    }

    /// `text` with exactly one type tag for `type` (none for `nil`): an existing reserved tag is
    /// replaced in place, further reserved tags go (with the line they leave empty; the blank line
    /// before it goes too only when a blank line or the end of the note follows, so two paragraphs
    /// never merge), and a note without one gets `#tag` on its own last line. A note with any CRLF
    /// line ending is written with CRLF throughout (mixed LF/CRLF notes become all CRLF).
    public static func setting(_ type: NoteType?, in text: String) -> String {
        let work = TextNormalization.normalizeLineEndings(text)
        let reserved = NoteParser.tagOccurrences(in: work)
            .filter { NoteType.reserved(tagPath: $0.name) != nil }
            .sorted { ($0.line, $0.range.lowerBound) < ($1.line, $1.range.lowerBound) }
        if reserved.isEmpty {
            guard let type else { return text }
            var body = work
            while body.last == "\n" { body.removeLast() }
            return restoringLineEndings(of: text, in: body.isEmpty ? "#" + type.tagName : body + "\n\n#" + type.tagName)
        }
        if let type, reserved.count == 1, NoteType.reserved(tagPath: reserved[0].name) == type { return text }

        var lines = work.split(separator: "\n", omittingEmptySubsequences: false).map { Array($0.unicodeScalars) }
        let kept = type == nil ? nil : reserved.first
        var emptied: [Int] = []
        for (lineIndex, group) in Dictionary(grouping: reserved.filter { $0 != kept }, by: \.line) {
            var line = lines[lineIndex]
            let offset = lineIndex == 0 && line.first == "\u{FEFF}" ? 1 : 0
            for occurrence in group.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
                var lower = occurrence.range.lowerBound + offset, upper = occurrence.range.upperBound + offset
                if lower > offset, Chars.isSpace(line[lower - 1]) {
                    lower -= 1
                } else if upper < line.count, Chars.isSpace(line[upper]) {
                    upper += 1
                }
                line.removeSubrange(lower..<upper)
            }
            if NoteStore.isBlankOrBareListMarker(line.dropFirst(offset)) { emptied.append(lineIndex) }
            lines[lineIndex] = line
        }
        var dropped = Set<Int>()
        for index in emptied.sorted() {
            dropped.insert(index)
            let endsParagraph = index == lines.count - 1 || emptied.contains(index + 1)
                || lines[index + 1].allSatisfy(Chars.isSpace)
            if endsParagraph, index > 0, !dropped.contains(index - 1), lines[index - 1].allSatisfy(Chars.isSpace) {
                dropped.insert(index - 1)
            }
        }
        if let first = kept, NoteType.reserved(tagPath: first.name) != type {
            let offset = first.line == 0 && lines[0].first == "\u{FEFF}" ? 1 : 0
            let range = (first.range.lowerBound + offset)..<(first.range.upperBound + offset)
            lines[first.line].replaceSubrange(range, with: Array(("#" + type!.tagName).unicodeScalars))
        }
        let result = lines.enumerated().filter { !dropped.contains($0.offset) }
            .map { String(String.UnicodeScalarView($0.element)) }.joined(separator: "\n")
        return restoringLineEndings(of: text, in: result)
    }

    /// `setting(type, in: text)`, or nil when the result would not carry `type` (the note ends inside
    /// an unclosed code fence or comment, so an appended tag is code, not a tag).
    public static func settingIfEffective(_ type: NoteType?, in text: String) -> String? {
        let result = setting(type, in: text)
        return NoteType.of(directTags: NoteParser.metadata(for: result).tags) == type ? result : nil
    }

    private static func restoringLineEndings(of original: String, in text: String) -> String {
        original.contains("\r\n") ? text.replacingOccurrences(of: "\n", with: "\r\n") : text
    }
}
