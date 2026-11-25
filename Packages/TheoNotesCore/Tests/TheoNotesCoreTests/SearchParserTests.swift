// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

/// `Fixtures/search/parse.json`: `[{ "name", "query", "expected": SearchExpr JSON }]`, parsed
/// with the en_US locale (device-local date format `M/d/y`). Semantics were measured on real Bear
/// (docs/oracle/m4-search.md).
@Suite struct SearchParserTests {
    struct Case: Decodable {
        let name: String
        let query: String
        let expected: SearchExpr
    }

    static let fixtureDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/search")

    @Test func testParseFixtures() throws {
        let data = try Data(contentsOf: Self.fixtureDir.appendingPathComponent("parse.json"))
        let cases = try JSONDecoder().decode([Case].self, from: data)
        #expect(cases.count >= 100)
        #expect(Set(cases.map(\.name)).count == cases.count, "duplicate case names")
        for c in cases {
            let actual = SearchParser.parse(c.query, locale: Locale(identifier: "en_US"))
            #expect(actual == c.expected, "\(c.name): \(c.query)")
        }
    }

    @Test func testCanonicalSpecialsRoundTrip() {
        let specials: [SpecialSearch] = [
            .lastDays(3), .createdDays(12), .modified(DateFilter(.before, year: 2026, month: 5, day: 29)),
            .created(DateFilter(.after, year: 2025)), .modified(DateFilter(.on, year: 2024, month: 2)),
        ]
        for special in specials {
            #expect(SearchParser.parse(special.canonical) == .special(special), "\(special.canonical)")
        }
    }

    @Test func testDeviceLocaleDateFormat() {
        let de = SearchParser.parse("@date(29.5.2026)", locale: Locale(identifier: "de_DE"))
        #expect(de == .special(.modified(DateFilter(.on, year: 2026, month: 5, day: 29))))
        let us = SearchParser.parse("@date(29.5.2026)", locale: Locale(identifier: "en_US"))
        #expect(us == .term("@date(29.5.2026)"))
    }

    @Test func testDecomposedInputIsNormalized() {
        #expect(SearchParser.parse("@생성됨60일".decomposedStringWithCanonicalMapping) == .special(.createdDays(60)))
        #expect(SearchParser.parse("@タグなし".decomposedStringWithCanonicalMapping) == .special(.untagged))
    }

    @Test func testChineseNumerals() {
        #expect(SearchParser.chineseNumber("十") == 10)
        #expect(SearchParser.chineseNumber("十五") == 15)
        #expect(SearchParser.chineseNumber("二十") == 20)
        #expect(SearchParser.chineseNumber("四十五") == 45)
        #expect(SearchParser.chineseNumber("一百二十") == 120)
        #expect(SearchParser.chineseNumber("三") == 3)
        #expect(SearchParser.chineseNumber("") == nil)
        #expect(SearchParser.chineseNumber("十x") == nil)
    }

    @Test func testParserNeverCrashesOnArbitraryInput() {
        let samples = ["\"", "\"\"\"", "-\"", "#\"a b\"#", "!#", "-!#", "#*/", "@date(", "@date(<)", "@last", "@lastdays",
                       "@last99999999999999999999days", "@前天", "@前百天", "-#", "a\u{0}b", "\u{FEFF}", "🐻 #🐻 @🐻",
                       "@date(99999999999999999999)", "@cdate(<1-99999999999999999999)", "@date(99999999999999999999-1-1)",
                       "@date(1/99999999999999999999)", "@날짜(99999999999999999999)", "@дата(>99999999999999999999)",
                       "@日期（99999999999999999999）", "@сдата(1-1-99999999999999999999)", "@date(123456789)"]
        for s in samples { _ = SearchParser.parse(s) }
        #expect(SearchParser.parse("@date(99999999999999999999)") == .term("@date(99999999999999999999)"))
        #expect(SearchParser.parse("@cdate(<1-99999999999999999999)") == .term("@cdate(<1-99999999999999999999)"))
    }

    /// Dates are stored as `YYYY-…` text, so years outside 1...9999 would compare wrongly.
    @Test func testYearsOutside1To9999AreTerms() {
        #expect(SearchParser.parse("@date(0000)") == .term("@date(0000)"))
        #expect(SearchParser.parse("@date(0000-01-01)") == .term("@date(0000-01-01)"))
        #expect(SearchParser.parse("@date(>9999)") == .special(.modified(DateFilter(.after, year: 9999))))
        #expect(SearchParser.parse("@date(1/1/10000)", locale: Locale(identifier: "en_US")) == .term("@date(1/1/10000)"))
    }

    /// U+0000 would end the FTS5 MATCH string early ("unterminated string").
    @Test func testNULBecomesASpace() {
        #expect(SearchParser.parse("abc\u{0}def") == .and([.term("abc"), .term("def")]))
        #expect(SearchParser.parse("\"abc\u{0}def\"") == .phrase("abc def"))
    }

    /// Long flat chains stay within the parser's operand cap (`SearchParser.maxOperands`).
    @Test func testOperandCap() {
        let words = (0..<2000).map { "w\($0)" }
        guard case .and(let list) = SearchParser.parse(words.joined(separator: " ")) else { Issue.record("not and"); return }
        #expect(list.count == SearchParser.maxOperands)
        guard case .or(let groups) = SearchParser.parse(words.joined(separator: " or ")) else { Issue.record("not or"); return }
        #expect(groups.count == SearchParser.maxOperands)
    }
}
