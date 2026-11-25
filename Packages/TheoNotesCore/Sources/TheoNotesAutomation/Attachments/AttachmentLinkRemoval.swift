// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation

/// `attachments delete`: takes every link to one attachment file out of a note's text.
enum AttachmentLinkRemoval {
    /// `text` without the links to `filename` (compared with `AttachmentFiles.fileSystemKey`), each
    /// with the `<!-- {…} -->` metadata comment that follows it. A line the removal leaves blank
    /// goes with its line break (for the last line, the break before it). Nil when the text links
    /// no such file; `internal` when a link the parser found has a shape this cannot cut out.
    static func remove(_ filename: String, from text: String) throws(AutomationError) -> String? {
        let key = AttachmentFiles.fileSystemKey(filename)
        let starts = NoteParser.attachmentLinks(in: text)
            .filter { AttachmentFiles.fileSystemKey($0.filename) == key }
            .map(\.offset)
        guard !starts.isEmpty else { return nil }
        var bytes = Array(text.utf8)
        // Last link first: removing one never moves the offsets of those before it.
        for start in starts.sorted(by: >) {
            guard let end = extent(of: bytes, from: start) else {
                throw AutomationError(code: .internal, message: "The link to \(filename) could not be removed")
            }
            bytes.removeSubrange(start..<end)
            dropBlankLine(in: &bytes, at: start)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static let space = UInt8(ascii: " ")
    private static let tab = UInt8(ascii: "\t")
    private static let newline = UInt8(ascii: "\n")
    private static let carriageReturn = UInt8(ascii: "\r")

    private static func isBlank(_ byte: UInt8) -> Bool { byte == space || byte == tab }

    /// The end of the link starting at `start` (`[` or `![`), metadata comment included; the shape
    /// the parser accepts (`LinkDestination.parse`): `[title](destination "title")` on one line.
    private static func extent(of bytes: [UInt8], from start: Int) -> Int? {
        let n = bytes.count
        var i = start
        if i < n, bytes[i] == UInt8(ascii: "!") { i += 1 }
        guard i < n, bytes[i] == UInt8(ascii: "[") else { return nil }
        var depth = 0
        while i < n, bytes[i] != newline {
            let c = bytes[i]
            if c == UInt8(ascii: "\\") {
                i += 2
                continue
            }
            if c == UInt8(ascii: "[") {
                depth += 1
            } else if c == UInt8(ascii: "]") {
                depth -= 1
                if depth == 0 { break }
            }
            i += 1
        }
        guard i + 1 < n, bytes[i] == UInt8(ascii: "]"), bytes[i + 1] == UInt8(ascii: "(") else { return nil }
        i += 2
        while i < n, isBlank(bytes[i]) { i += 1 }
        if i < n, bytes[i] == UInt8(ascii: "<") {
            i += 1
            while i < n, bytes[i] != UInt8(ascii: ">"), bytes[i] != UInt8(ascii: "<"), bytes[i] != newline { i += 1 }
            guard i < n, bytes[i] == UInt8(ascii: ">") else { return nil }
            i += 1
        } else {
            var parens = 0
            while i < n {
                let c = bytes[i]
                if c == UInt8(ascii: "\\"), i + 1 < n {
                    i += 2
                    continue
                }
                if isBlank(c) || c == newline || c == carriageReturn { break }
                if c == UInt8(ascii: "(") {
                    parens += 1
                } else if c == UInt8(ascii: ")") {
                    if parens == 0 { break }
                    parens -= 1
                }
                i += 1
            }
            guard parens == 0 else { return nil }
        }
        let beforeTitle = i
        while i < n, isBlank(bytes[i]) { i += 1 }
        if i < n, i > beforeTitle, [UInt8(ascii: "\""), UInt8(ascii: "'"), UInt8(ascii: "(")].contains(bytes[i]) {
            let close = bytes[i] == UInt8(ascii: "(") ? UInt8(ascii: ")") : bytes[i]
            i += 1
            while i < n, bytes[i] != close, bytes[i] != newline { i += bytes[i] == UInt8(ascii: "\\") ? 2 : 1 }
            guard i < n, bytes[i] == close else { return nil }
            i += 1
            while i < n, isBlank(bytes[i]) { i += 1 }
        }
        guard i < n, bytes[i] == UInt8(ascii: ")") else { return nil }
        i += 1
        return commentEnd(bytes, after: i) ?? i
    }

    /// The end of a `<!-- {…} -->` comment right after the link (blanks allowed), if there is one.
    private static func commentEnd(_ bytes: [UInt8], after link: Int) -> Int? {
        let n = bytes.count
        var i = link
        while i < n, isBlank(bytes[i]) { i += 1 }
        let open = Array("<!--".utf8)
        guard i + open.count <= n, Array(bytes[i..<i + open.count]) == open else { return nil }
        i += open.count
        while i < n, isBlank(bytes[i]) || bytes[i] == newline || bytes[i] == carriageReturn { i += 1 }
        guard i < n, bytes[i] == UInt8(ascii: "{") else { return nil }
        let close = Array("-->".utf8)
        while i + close.count <= n {
            if Array(bytes[i..<i + close.count]) == close { return i + close.count }
            i += 1
        }
        return nil
    }

    /// If the line holding `position` is now blank, removes it with its line break.
    private static func dropBlankLine(in bytes: inout [UInt8], at position: Int) {
        var lineStart = position
        while lineStart > 0, bytes[lineStart - 1] != newline { lineStart -= 1 }
        var lineEnd = position
        while lineEnd < bytes.count, bytes[lineEnd] != newline { lineEnd += 1 }
        guard bytes[lineStart..<lineEnd].allSatisfy({ isBlank($0) || $0 == carriageReturn }) else { return }
        if lineEnd < bytes.count {
            bytes.removeSubrange(lineStart...lineEnd)
        } else if lineStart > 0 {
            // The last line, with no line break of its own: the break before it goes instead.
            var from = lineStart - 1
            if from > 0, bytes[from - 1] == carriageReturn { from -= 1 }
            bytes.removeSubrange(from..<bytes.count)
        } else {
            bytes.removeAll()
        }
    }
}
