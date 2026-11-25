// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

/// `Fixtures/search/fold.json`: where search terms match in a note's text. The editor's search
/// highlight (web/editor/src/editor/features/search.ts) passes the same cases, so the list, the
/// scroll target and the editor agree.
@Suite struct SearchOffsetsFixtureTests {
    struct Case: Decodable {
        let name: String
        let text: String
        let terms: [String]
        let matches: [String]
    }

    static let cases: [Case] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/search/fold.json")
        return (try? JSONDecoder().decode([Case].self, from: Data(contentsOf: url))) ?? []
    }()

    @Test func testFixturesLoad() {
        #expect(Self.cases.count >= 20)
    }

    @Test(arguments: cases.map(\.name))
    func testSourceRangesMatchTheFixture(_ name: String) throws {
        let fixture = try #require(Self.cases.first { $0.name == name })
        let text = fixture.text as NSString
        let found = SearchOffsets.sourceRanges(for: fixture.terms, in: fixture.text)
            .map { text.substring(with: NSRange(location: $0.lowerBound, length: $0.count)) }
        #expect(found == fixture.matches, "\(name)")
    }
}
