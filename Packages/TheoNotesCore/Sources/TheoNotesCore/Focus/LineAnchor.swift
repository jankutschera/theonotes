// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// Points at one line of a note: `line` (1-based) and `hash` (8 lowercase hex, FNV-1a 32 over the
/// line's UTF-8 bytes, the same rule the editor's folds use, FOC-R6). The hash lets the anchor
/// follow its line when lines are added or removed above it.
///
/// Lines are split on `\n`; a trailing `\r` is not part of the line (CRLF text). The text is
/// otherwise taken as typed, so the stored Markdown is never normalised.
public struct LineAnchor: Codable, Equatable, Hashable, Sendable {
    public let line: Int
    public let hash: String

    /// How far from the stored line `resolve(in:)` looks for the hash (FOC-R6).
    static let window = 50

    public init(line: Int, hash: String) {
        self.line = line
        self.hash = hash
    }

    /// FNV-1a 32-bit of the UTF-8 bytes of `lineText`, as 8 lowercase hex characters.
    public static func hash(_ lineText: String) -> String {
        hex(fnv(lineText.utf8[...]))
    }

    /// The anchor of 1-based `line`, or nil when the note has no such line.
    public static func at(line: Int, in text: String) -> LineAnchor? {
        let index = LineIndex(text)
        guard let range = index.range(ofLine: line) else { return nil }
        return LineAnchor(line: line, hash: hex(fnv(text.utf8[range])))
    }

    /// The anchor of the line holding the caret at `utf16Offset` (0...length). An offset just before
    /// a line break is still on that line; just after it, on the next one.
    public static func at(utf16Offset: Int, in text: String) -> LineAnchor? {
        let utf16 = text.utf16
        guard utf16Offset >= 0, utf16Offset <= utf16.count else { return nil }
        let newlines = utf16.prefix(utf16Offset).reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
        return at(line: newlines + 1, in: text)
    }

    /// The current 1-based line of this anchor: the stored line when its hash still matches,
    /// otherwise the nearest line within 50 lines that has the hash (the earlier one when two are
    /// equally near), otherwise nil.
    public func resolve(in text: String) -> Int? {
        let index = LineIndex(text)
        func matches(_ candidate: Int) -> Bool {
            guard let range = index.range(ofLine: candidate) else { return false }
            return Self.hex(Self.fnv(text.utf8[range])) == hash
        }
        if matches(line) { return line }
        for distance in 1...Self.window {
            if matches(line - distance) { return line - distance }
            if matches(line + distance) { return line + distance }
        }
        return nil
    }

    /// The text of 1-based `line` without its line break, or nil when there is no such line.
    public static func lineText(_ line: Int, in text: String) -> String? {
        let index = LineIndex(text)
        return index.range(ofLine: line).map { String(text[$0]) }
    }

    /// UTF-16 offset where 1-based `line` starts (what the editor bridge uses), or nil.
    public static func utf16Offset(ofLine line: Int, in text: String) -> Int? {
        let index = LineIndex(text)
        guard line >= 1, line <= index.count else { return nil }
        return text.utf16.distance(from: text.startIndex, to: index.starts[line - 1])
    }

    /// Exactly 8 lowercase hexadecimal ASCII characters.
    public static func isValidHash(_ s: String) -> Bool {
        let bytes = s.utf8
        return bytes.count == 8 && bytes.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    private static func fnv(_ bytes: Substring.UTF8View) -> UInt32 {
        var hash: UInt32 = 0x811c9dc5
        for byte in bytes {
            hash ^= UInt32(byte)
            hash = hash &* 0x01000193
        }
        return hash
    }

    private static func hex(_ value: UInt32) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: 8 - digits.count) + digits
    }
}

/// Where each `\n`-separated line of a text starts (and ends, without `\r`).
struct LineIndex {
    let text: String
    /// Start of each line; always at least one entry.
    let starts: [String.Index]

    init(_ text: String) {
        self.text = text
        var starts = [text.startIndex]
        let utf8 = text.utf8
        var i = utf8.startIndex
        while i != utf8.endIndex {
            let next = utf8.index(after: i)
            if utf8[i] == 10 { starts.append(next) }
            i = next
        }
        self.starts = starts
    }

    var count: Int { starts.count }

    /// The 1-based line without its `\n` and a `\r` before it.
    func range(ofLine line: Int) -> Range<String.Index>? {
        guard line >= 1, line <= starts.count else { return nil }
        let utf8 = text.utf8
        let start = starts[line - 1]
        var end = line < starts.count ? utf8.index(before: starts[line]) : text.endIndex
        if end > start, utf8[utf8.index(before: end)] == 13 { end = utf8.index(before: end) }
        return start..<end
    }
}
