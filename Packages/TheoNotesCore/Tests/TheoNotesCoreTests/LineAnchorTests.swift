// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

@Suite struct LineAnchorTests {
    struct HashCase: Decodable { let text: String; let hash: String }
    struct HashFixture: Decodable { let cases: [HashCase] }

    static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/folds/line-hash.json")

    private func lines(_ n: Int, prefix: String = "line") -> String {
        (1...n).map { "\(prefix) \($0)" }.joined(separator: "\n")
    }

    @Test func hashMatchesTheSharedFixture() throws {
        let data = try Data(contentsOf: Self.fixture)
        let cases = try JSONDecoder().decode(HashFixture.self, from: data).cases
        #expect(cases.count >= 10)
        for c in cases {
            #expect(LineAnchor.hash(c.text) == c.hash, "\(c.text)")
        }
    }

    @Test func resolvesAtTheStoredLine() {
        let text = "alpha\nbeta\ngamma"
        let anchor = LineAnchor.at(line: 2, in: text)
        #expect(anchor == LineAnchor(line: 2, hash: LineAnchor.hash("beta")))
        #expect(anchor?.resolve(in: text) == 2)
        #expect(LineAnchor.at(line: 0, in: text) == nil)
        #expect(LineAnchor.at(line: 4, in: text) == nil)
        #expect(LineAnchor.at(line: 3, in: text)?.resolve(in: text) == 3)
    }

    @Test func resolvesAfterLinesInsertedAbove() {
        let before = "alpha\nbeta\ngamma"
        let anchor = LineAnchor.at(line: 2, in: before)!
        let after = "x\ny\nz\n" + before
        #expect(anchor.resolve(in: after) == 5)
        let down = LineAnchor.at(line: 5, in: after)!
        #expect(down.resolve(in: before) == 2)
    }

    @Test func equalDistanceDuplicatesResolveToTheEarlierLine() {
        // Stored line 3 no longer matches; "dup" sits 2 lines above and 2 lines below.
        let anchor = LineAnchor(line: 3, hash: LineAnchor.hash("dup"))
        let text = "dup\nb\nc\nd\ndup"
        #expect(anchor.resolve(in: text) == 1)
        // A nearer copy wins over an earlier, farther one.
        let nearer = "dup\nb\nc\nd\ne\nf\ng\ndup\ni\nj\nk"
        let far = LineAnchor(line: 9, hash: LineAnchor.hash("dup"))
        #expect(far.resolve(in: nearer) == 8)
    }

    @Test func outsideTheWindowIsNil() {
        let text = lines(10)
        let anchor = LineAnchor.at(line: 5, in: text)!
        let shifted50 = String(repeating: "x\n", count: 50) + text
        #expect(anchor.resolve(in: shifted50) == 55)
        let shifted51 = String(repeating: "x\n", count: 51) + text
        #expect(anchor.resolve(in: shifted51) == nil)
    }

    @Test func deletedLineIsNil() {
        let text = "alpha\nbeta\ngamma"
        let anchor = LineAnchor.at(line: 2, in: text)!
        #expect(anchor.resolve(in: "alpha\ngamma") == nil)
        #expect(anchor.resolve(in: "") == nil)
    }

    @Test func utf16OffsetMapsToTheLineOfTheCaret() {
        let text = "😀 日本語\nsecond ñ\n\nfourth"
        let firstEnd = ("😀 日本語" as NSString).length
        // Offset 0 and the end of line 1 (before the newline) are line 1.
        #expect(LineAnchor.at(utf16Offset: 0, in: text)?.line == 1)
        #expect(LineAnchor.at(utf16Offset: firstEnd, in: text)?.line == 1)
        #expect(LineAnchor.at(utf16Offset: firstEnd + 1, in: text)?.line == 2)
        #expect(LineAnchor.at(utf16Offset: firstEnd + 1, in: text)?.hash == LineAnchor.hash("second ñ"))
        let blank = firstEnd + 1 + ("second ñ" as NSString).length + 1
        #expect(LineAnchor.at(utf16Offset: blank, in: text)?.line == 3)
        let end = (text as NSString).length
        #expect(LineAnchor.at(utf16Offset: end, in: text)?.line == 4)
        #expect(LineAnchor.at(utf16Offset: end + 1, in: text) == nil)
        #expect(LineAnchor.at(utf16Offset: -1, in: text) == nil)
        #expect(LineAnchor.utf16Offset(ofLine: 2, in: text) == firstEnd + 1)
        #expect(LineAnchor.utf16Offset(ofLine: 1, in: text) == 0)
        #expect(LineAnchor.utf16Offset(ofLine: 5, in: text) == nil)
        #expect(LineAnchor.lineText(2, in: text) == "second ñ")
        #expect(LineAnchor.lineText(3, in: text) == "")
        #expect(LineAnchor.lineText(0, in: text) == nil)
    }

    @Test func aCarriageReturnIsNotPartOfTheLineText() {
        let text = "one\r\ntwo\r\n"
        #expect(LineAnchor.lineText(1, in: text) == "one")
        #expect(LineAnchor.lineText(2, in: text) == "two")
        #expect(LineAnchor.at(line: 2, in: text)?.hash == LineAnchor.hash("two"))
    }

    @Test func isValidHashAcceptsOnlyEightLowercaseHex() {
        #expect(LineAnchor.isValidHash("811c9dc5"))
        #expect(LineAnchor.isValidHash("00000000"))
        #expect(!LineAnchor.isValidHash("811C9DC5"))
        #expect(!LineAnchor.isValidHash("811c9dc"))
        #expect(!LineAnchor.isValidHash("811c9dc55"))
        #expect(!LineAnchor.isValidHash("811c9dcg"))
        #expect(!LineAnchor.isValidHash(""))
        #expect(!LineAnchor.isValidHash("٨11c9dc5"))
    }
}
