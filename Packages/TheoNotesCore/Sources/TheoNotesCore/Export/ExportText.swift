// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// The two text rewrites a Markdown / TextBundle export may apply. Everything
/// else in the note stays byte for byte.
public enum ExportText {
    /// Drops every tag occurrence the indexer counts (`NoteParser.tagSpans`), the lines that held
    /// only tags (with their line break; a last line takes the break before it), and collapses
    /// the double space an inline tag leaves: `see #a here` becomes `see here`, `x #a` becomes
    /// `x`. Tags in code, links, comments and front matter are not tags and stay.
    public static func removingTags(_ text: String) -> String {
        let spans = NoteParser.tagSpans(in: text)
        guard !spans.isEmpty else { return text }
        let starts = NoteParser.lineStartBytes(of: text)
        let total = text.utf8.count
        let tagOnly = Set(NoteParser.tagOnlyLines(in: text))

        func line(containing offset: Int) -> Int {
            var lo = 0, hi = starts.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
            }
            return lo
        }

        enum Edit {
            case line(Range<Int>)
            case tag(Range<Int>)

            var start: Int {
                switch self {
                case .line(let r), .tag(let r): r.lowerBound
                }
            }
        }
        var edits: [Edit] = tagOnly.sorted().map { index in
            let end = index + 1 < starts.count ? starts[index + 1] - 1 : total
            return .line(starts[index]..<end)
        }
        for span in spans where !tagOnly.contains(line(containing: span.bytes.lowerBound)) {
            edits.append(.tag(span.bytes))
        }
        edits.sort { $0.start > $1.start }

        let newline = UInt8(ascii: "\n"), space = UInt8(ascii: " "), tab = UInt8(ascii: "\t"), cr = UInt8(ascii: "\r")
        var bytes = Array(text.utf8)
        for edit in edits {
            switch edit {
            case .line(let original):
                // A later edit may have taken this line's own CR along with the break before it.
                let range = original.lowerBound..<min(original.upperBound, bytes.count)
                if range.upperBound < bytes.count, bytes[range.upperBound] == newline {
                    bytes.removeSubrange(range.lowerBound...range.upperBound)
                } else if range.lowerBound > 0, bytes[range.lowerBound - 1] == newline {
                    // The break before a last line goes with it, a CR of CRLF included.
                    let breakStart = range.lowerBound >= 2 && bytes[range.lowerBound - 2] == cr
                        ? range.lowerBound - 2 : range.lowerBound - 1
                    bytes.removeSubrange(breakStart..<range.upperBound)
                } else {
                    bytes.removeSubrange(range)
                }
            case .tag(let range):
                let before: UInt8? = range.lowerBound > 0 ? bytes[range.lowerBound - 1] : nil
                let after: UInt8? = range.upperBound < bytes.count ? bytes[range.upperBound] : nil
                let atLineStart = before == nil || before == newline
                let spaceBefore = before == space || before == tab
                let spaceAfter = after == space || after == tab
                let atLineEnd = after == nil || after == newline || after == cr
                if (atLineStart || spaceBefore) && spaceAfter {
                    bytes.removeSubrange(range.lowerBound...range.upperBound)
                } else if spaceBefore && atLineEnd {
                    bytes.removeSubrange(range.lowerBound - 1..<range.upperBound)
                } else {
                    bytes.removeSubrange(range)
                }
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Inserts `prefix` (already percent-encoded, ending in `/`) at the start of every attachment
    /// link destination, as written. A destination whose file is in `replacing` (keyed by
    /// `AttachmentFiles.fileSystemKey`) is swapped for that value instead (a `data:` URI). Nothing
    /// else changes.
    public static func prefixingAttachmentLinks(
        _ text: String, with prefix: String, replacing: [String: String] = [:]
    ) -> String {
        let targets = NoteParser.attachmentLinkTargets(in: text)
        guard !targets.isEmpty, !prefix.isEmpty || !replacing.isEmpty else { return text }
        var bytes = Array(text.utf8)
        let inserted = Array(prefix.utf8)
        for target in targets.reversed() {
            if let value = replacing[AttachmentFiles.fileSystemKey(target.filename)] {
                bytes.replaceSubrange(target.bytes, with: Array(value.utf8))
            } else {
                bytes.insert(contentsOf: inserted, at: target.bytes.lowerBound)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
