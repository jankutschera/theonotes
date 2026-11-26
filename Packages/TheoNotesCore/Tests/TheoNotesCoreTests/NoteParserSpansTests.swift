// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing

@testable import TheoNotesCore

/// The two scans the automation layer needs beyond `metadata(for)`
/// every heading line, empty ones included, and every tag occurrence with its UTF-8 byte range.
@Suite struct NoteParserSpansTests {
    @Test func sectionHeadingsKeepEmptyOnesInDocumentOrder() {
        let text = "# A\nx\n#\n## \ny\n### B\n```\n# not a heading\n```\n# ![](a.png)\n"
        let all = NoteParser.sectionHeadings(in: text)
        #expect(all.map(\.line) == [1, 3, 4, 6, 10])
        #expect(all.map(\.level) == [1, 1, 2, 3, 1])
        #expect(all.map(\.text) == ["A", "", "", "B", ""])
        // `metadata(for:)` still leaves the empty ones out.
        #expect(NoteParser.metadata(for: text).headings.map(\.text) == ["A", "B"])
        #expect(NoteParser.sectionHeadings(in: "no headings\n").isEmpty)
    }

    @Test func tagSpansAreUTF8ByteRangesInTextOrderWithRepeats() {
        let text = "Ä #a/b ✓ #multi word#\n#a/b"
        let spans = NoteParser.tagSpans(in: text)
        #expect(spans.map(\.name) == ["a/b", "multi word", "a/b"])
        let bytes = Array(text.utf8)
        #expect(spans.map { String(decoding: bytes[$0.bytes], as: UTF8.self) } == ["#a/b", "#multi word#", "#a/b"])
        #expect(NoteParser.tagSpans(in: "`#code` and\n```\n#fenced\n```\n").isEmpty)
        #expect(NoteParser.tagSpans(in: "\u{FEFF}#bom").map { $0.bytes } == [3..<7])
    }
}
