// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

// Shared dialect conformance suite: Fixtures/dialect/<file>.json is an array of
// { "name": String, "input": String /* whole note text */, "expected": … }.
// The JS editor parser must pass the same files. Expected shape per file:
//   title.json        String — NoteMetadata.title ("" = untitled)
//   preview.json      String — NoteMetadata.subtitle
//   tags.json         [String] — direct tags without "#", display spelling, first-seen order,
//                     deduped by CanonicalKey (ancestors are not listed)
//   todos.json        {"open": Int, "done": Int}
//   wikilinks.json    [{"target": String, "heading": String|null, "alias": String|null}]
//   headings.json     [{"level": Int, "text": String, "line": Int /* 1-based */}]
//   attachments.json  [{"filename": String, "isImage": Bool, "metadata": {String: String}}]
//   flags.json        {"hasCode": Bool, "hasInlineCode": Bool, "isEmpty": Bool}
//   tables.json       [Int] — 1-based lines of every table header, delimiter and body row
//   urls.json         [String] — bare URLs (InlineScanner `.url` spans, line by line; no code
//                     blocks in these inputs)
@Suite struct NoteParserFixtureTests {
    struct Case<Expected: Decodable>: Decodable {
        let name: String
        let input: String
        let expected: Expected
    }

    struct Todos: Decodable, Equatable { let open: Int; let done: Int }
    struct Flags: Decodable, Equatable { let hasCode: Bool; let hasInlineCode: Bool; let isEmpty: Bool }

    static let fixtureDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/dialect")

    private func check<E: Decodable & Equatable>(
        _ file: String, _ type: E.Type, _ field: (NoteMetadata) -> E
    ) throws {
        try check(file, type, input: { field(NoteParser.metadata(for: $0)) })
    }

    private func check<E: Decodable & Equatable>(
        _ file: String, _ type: E.Type, input actualFor: (String) -> E
    ) throws {
        let data = try Data(contentsOf: Self.fixtureDir.appendingPathComponent(file))
        let cases = try JSONDecoder().decode([Case<E>].self, from: data)
        #expect(cases.count >= 15, "\(file) has only \(cases.count) cases")
        #expect(Set(cases.map(\.name)).count == cases.count, "\(file) has duplicate case names")
        for c in cases {
            let actual = actualFor(c.input)
            #expect(actual == c.expected, "\(file): \(c.name)")
        }
    }

    @Test func testTitleFixtures() throws { try check("title.json", String.self) { $0.title } }
    @Test func testPreviewFixtures() throws { try check("preview.json", String.self) { $0.subtitle } }
    @Test func testTagFixtures() throws { try check("tags.json", [String].self) { $0.tags } }
    @Test func testTodoFixtures() throws {
        try check("todos.json", Todos.self) { Todos(open: $0.openTodos, done: $0.doneTodos) }
    }
    @Test func testWikiLinkFixtures() throws { try check("wikilinks.json", [WikiLinkRef].self) { $0.wikiLinks } }
    @Test func testHeadingFixtures() throws { try check("headings.json", [HeadingRef].self) { $0.headings } }
    @Test func testSelectiveScansPreserveDialect() throws {
        try check("headings.json", [HeadingRef].self, input: { NoteParser.headings(in: $0) })
        try check("tags.json", [String].self, input: { NoteParser.tagsAndAttachments(in: $0).tags })
        try check("attachments.json", [AttachmentRef].self, input: { NoteParser.tagsAndAttachments(in: $0).attachments })
    }
    @Test func testAttachmentFixtures() throws {
        try check("attachments.json", [AttachmentRef].self) { $0.attachments }
    }
    @Test func testTableFixtures() throws {
        try check("tables.json", [Int].self, input: { NoteParser.tableRowLines(in: $0) })
    }
    @Test func testURLFixtures() throws {
        try check("urls.json", [String].self, input: { text in
            text.split(separator: "\n", omittingEmptySubsequences: false).flatMap { line -> [String] in
                let scalars = Array(line.unicodeScalars)
                let scan = InlineScanner.scan(scalars, startsInComment: false, commentMayContinue: false)
                return scan.spans.compactMap { span in
                    span.kind == .url ? String(String.UnicodeScalarView(scalars[span.range])) : nil
                }
            }
        })
    }
    @Test func testFlagFixtures() throws {
        try check("flags.json", Flags.self) {
            Flags(hasCode: $0.hasCode, hasInlineCode: $0.hasInlineCode, isEmpty: $0.isEmpty)
        }
    }
}

@Suite struct NoteParserBehaviorTests {
    @Test func testTagScannerLine() {
        #expect(TagScanner.tags(inLine: "see #tag. and #my tag# `#no`") == ["tag", "my tag"])
    }

    @Test func testAncestorPaths() {
        #expect(TagScanner.ancestorPaths(of: "a/b/c") == ["a", "a/b", "a/b/c"])
        #expect(TagScanner.ancestorPaths(of: "solo") == ["solo"])
    }

    @Test func testMetadataCodableRoundTrip() throws {
        let meta = NoteParser.metadata(for: "# T #x\n- [ ] a\n[[N/H|al]] ![](p.jpg)<!-- {\"width\":\"9\"} -->")
        let decoded = try JSONDecoder().decode(NoteMetadata.self, from: JSONEncoder().encode(meta))
        #expect(decoded == meta)
        #expect(meta.tags == ["x"])
        #expect(meta.openTodos == 1)
    }

    @Test func testLargeNoteParsesQuickly() {
        let block = """
        ## Section #work/projects
        Some **bold** text with a [link](https://example.com/a#b) and `code` and $x$.
        - [ ] open item #todo
        - [x] done item [[Other Note/Heading|alias]]
        ![](photo%202.jpg)<!-- {"width":"320"} -->

        """
        let text = "# Big note\n" + String(repeating: block, count: 300)
        #expect(text.utf8.count > 59_000)
        let start = ContinuousClock.now
        let meta = NoteParser.metadata(for: text)
        let elapsed = ContinuousClock.now - start
        #expect(meta.openTodos == 300)
        #expect(meta.headings.count == 301)
        #expect(elapsed < .seconds(1), "parsing took \(elapsed)")
    }

    @Test func testPathologicalLineIsLinear() {
        let line = String(repeating: "[`$ #a <!-- ** _ (", count: 4_000)
        let start = ContinuousClock.now
        _ = NoteParser.metadata(for: line)
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(1), "parsing took \(elapsed)")
    }
}
