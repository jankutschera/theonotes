// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesAutomation

/// The text engine behind `edit` and `edit_note`.
@Suite struct EditEngineTests {
    @Test func batchWithOneMissWritesNothingAndReportsEachEdit() {
        do {
            _ = try EditEngine.apply(
                [.init(find: "a", action: .replace("b")), .init(find: "zz", action: .delete), .init(find: "c", action: .delete)],
                to: "a c", within: nil)
            Issue.record("expected not_found")
        } catch {
            #expect(error.code == .notFound)
            #expect(error.message == "No match for 1 of 3 edits; nothing was written.")
            #expect(
                error.details?["edits"] == .array([
                    .object([("index", .int(0)), ("matched", .bool(true))]),
                    .object([("index", .int(1)), ("matched", .bool(false))]),
                    .object([("index", .int(2)), ("matched", .bool(true))]),
                ]))
        }
    }

    @Test func editsApplySequentially() throws {
        let result = try EditEngine.apply(
            [.init(find: "alpha", action: .replace("BETA")), .init(find: "BETA", action: .insertAfter("!"))],
            to: "alpha", within: nil)
        #expect(result.text == "BETA!")
        #expect(result.ops.map(\.index) == [0, 1] && result.ops.map(\.firstMatch) == [0, 0])  // insertAfter reports the match start
        // A find that only exists after an earlier edit misses when run first.
        #expect(throws: AutomationError.self) {
            try EditEngine.apply(
                [.init(find: "BETA", action: .delete), .init(find: "alpha", action: .replace("BETA"))], to: "alpha",
                within: nil)
        }
    }

    @Test func actionsAndFirstOccurrenceOnly() throws {
        func run(_ action: EditAction, all: Bool = false) throws -> String {
            try EditEngine.apply([.init(find: "x", action: action, all: all)], to: "a x b x", within: nil).text
        }
        #expect(try run(.replace("Y")) == "a Y b x")
        #expect(try run(.insertBefore("[")) == "a [x b x")
        #expect(try run(.insertAfter("]")) == "a x] b x")
        #expect(try run(.delete) == "a  b x")
        #expect(try run(.delete, all: true) == "a  b ")
        #expect(try run(.insertAfter("x"), all: true) == "a xx b xx")
    }

    @Test func firstMatchOffsetsFollowLaterEdits() throws {
        let result = try EditEngine.apply(
            [
                .init(find: "c", action: .replace("CC")), .init(find: "a", action: .insertBefore("é")),
                .init(find: "CC", action: .replace("D")),
            ], to: "a b c", within: nil)
        #expect(result.text == "éa b D")
        // "CC" landed at 4, moved by the two-byte "é" to 6, then was replaced by "D" at 6. The
        // insert-before edit reports its match "a", now after "é" (ruling M5-R74).
        #expect(result.ops.map(\.firstMatch) == [6, 2, 6])
    }

    /// `firstMatch` is the match start, so the section an edit landed in is the match's, even when
    /// the inserted text crosses a heading boundary (ruling M5-R74).
    @Test func firstMatchIsTheMatchStartAtHeadingBoundaries() throws {
        let t = "# T\n## A\nx\n## Notes\ny\n"
        let before = try EditEngine.apply([.init(find: "## Notes", action: .insertBefore("Intro\n\n"))], to: t, within: nil)
        #expect(before.text == "# T\n## A\nx\nIntro\n\n## Notes\ny\n" && before.ops[0].firstMatch == 18)
        #expect(NoteSections(text: before.text).innermost(at: before.ops[0].firstMatch)?.address == "## Notes")
        let after = try EditEngine.apply([.init(find: "x\n", action: .insertAfter("## C\n"))], to: t, within: nil)
        #expect(after.text == "# T\n## A\nx\n## C\n## Notes\ny\n" && after.ops[0].firstMatch == 9)
        #expect(NoteSections(text: after.text).innermost(at: after.ops[0].firstMatch)?.address == "## A")
        let replaced = try EditEngine.apply([.init(find: "y", action: .replace("Y"), all: true)], to: t, within: nil)
        #expect(replaced.ops[0].firstMatch == 20)
        let deleted = try EditEngine.apply([.init(find: "x\n", action: .delete)], to: t, within: nil)
        #expect(deleted.text == "# T\n## A\n## Notes\ny\n" && deleted.ops[0].firstMatch == 9)
    }

    @Test func allIgnoreCaseWordAndSectionConfinement() throws {
        #expect(
            try EditEngine.apply([.init(find: "cat", action: .replace("dog"), all: true, word: true)], to: "cat catalog Cat", within: nil)
                .text == "dog catalog Cat")
        #expect(
            try EditEngine.apply(
                [.init(find: "cat", action: .replace("dog"), all: true, ignoreCase: true, word: true)], to: "cat catalog Cat",
                within: nil
            ).text == "dog catalog dog")
        let t = "# A\ndone\n# B\ndone\n"
        #expect(
            try EditEngine.apply([.init(find: "done", action: .replace("DONE"))], to: t, within: NoteSections(text: t).resolve(.parse("# B")))
                .text == "# A\ndone\n# B\nDONE\n")
    }

    @Test func sectionRangeFollowsEarlierEdits() throws {
        let t = "# A\nx\n# B\nx\n"
        let within = try NoteSections(text: t).resolve(.parse("# A"))
        // The first edit grows "# A" by three bytes; the second still finds both x inside it, none in "# B".
        let result = try EditEngine.apply(
            [.init(find: "x", action: .insertAfter("\nx\n")), .init(find: "x", action: .replace("y"), all: true)], to: t,
            within: within)
        #expect(result.text == "# A\ny\ny\n\n# B\nx\n")
    }

    @Test func findCannotEscapeSection() throws {
        let t = "# A\ndone\n# B\ndone\n"
        let s = NoteSections(text: t)
        #expect(throws: AutomationError.self) {
            try EditEngine.apply([.init(find: "done\n# B", action: .delete)], to: t, within: s.resolve(.parse("# A")))
        }
        // Inside the section a find may cross a nested heading.
        let nested = "# A\nx\n## B\ny\n# C\n"
        #expect(
            try EditEngine.apply([.init(find: "x\n## B", action: .replace("z"))], to: nested, within: NoteSections(text: nested).resolve(.parse("# A")))
                .text == "# A\nz\ny\n# C\n")
    }

    @Test func crlfNotesKeepTheirLineEndings() throws {
        let t = "# T\r\none\r\ntwo\r\n"
        // Matching is byte-exact: a bare `\n` between two words is not `\r\n`.
        #expect(throws: AutomationError.self) { try EditEngine.apply([.init(find: "one\ntwo", action: .delete)], to: t, within: nil) }
        #expect(try EditEngine.apply([.init(find: "\ntwo", action: .replace("\nTWO"))], to: t, within: nil).text == "# T\r\none\r\nTWO\r\n")
        #expect(try EditEngine.apply([.init(find: "one", action: .replace("1"))], to: t, within: nil).text == "# T\r\n1\r\ntwo\r\n")
    }

    @Test func nonASCIIOffsetsAreUTF8Bytes() throws {
        let result = try EditEngine.apply([.init(find: "😀", action: .replace("x"))], to: "ä 👩‍👩‍👧 😀", within: nil)
        #expect(result.text == "ä 👩‍👩‍👧 x" && result.ops[0].firstMatch == 22)
    }

    /// UAX #29 word boundaries (ruling M5-R63 as proposed by Task 6).
    @Test func wordUsesUnicodeWordBoundaries() throws {
        func words(_ needle: String, _ text: String) -> [Range<Int>] {
            NoteFind.occurrences(of: needle, in: text, within: nil, ignoreCase: false, word: true)
        }
        #expect(words("can", "can can't cannot") == [0..<3])  // `can't` is one word
        #expect(words("dog's", "the dog's bone") == [4..<9])
        #expect(words("3", "3 3.14") == [0..<1])
        #expect(words("東京", "東京都に行きます") == [0..<6])  // dictionary segmentation: 東京|都|に…
        #expect(words("語", "日本語を話す") == [6..<9])
        #expect(words("#tag", "a#tag #tag") == [1..<5, 6..<10])
        #expect(words("e", "e\u{301} e") == [4..<5])  // a combining mark joins its base
        #expect(words("cat", "cat concat cat_x cats (cat)") == [0..<3, 23..<26])
        // Next to a line break is always a boundary, so CRLF text matches a find with `\n`.
        #expect(words("\nb", "a\r\nb") == [2..<4])
        #expect(words("long", String(repeating: "long ", count: 2000)).count == 2000)
    }

    /// Words are segmented line by line; the cache must follow the matches from line to line.
    @Test func wordOnManyLines() throws {
        let lines = (0..<1500).map { i in i % 3 == 0 ? "cat \(i)" : i % 3 == 1 ? "catalog \(i)" : "\(i) can't cat" }
        let text = lines.joined(separator: "\n")
        let hits = NoteFind.occurrences(of: "cat", in: text, within: nil, ignoreCase: false, word: true)
        #expect(hits.count == 1000)
        let bytes = Array(text.utf8)
        #expect(hits.allSatisfy { String(decoding: bytes[$0], as: UTF8.self) == "cat" })
        #expect(NoteFind.occurrences(of: "can", in: text, within: nil, ignoreCase: false, word: true).isEmpty)
        #expect(NoteFind.occurrences(of: "cat", in: text, within: nil, ignoreCase: false, word: true, limit: 1) == [0..<3])
        let edited = try EditEngine.apply([.init(find: "cat", action: .replace("dog"), all: true, word: true)], to: text, within: nil)
        #expect(edited.text.components(separatedBy: "\n")[0...2] == ["dog 0", "catalog 1", "2 can't dog"])
        // A first-only edit changes just the first whole word.
        let first = try EditEngine.apply([.init(find: "cat", action: .replace("dog"), word: true)], to: "catalog\nx cat\ncat", within: nil)
        #expect(first.text == "catalog\nx dog\ncat" && first.ops[0].firstMatch == 10)
    }

    @Test func cliPairingOfMixedActions() throws {
        func specs(_ args: [String]) throws(AutomationError) -> [EditSpec] {
            guard case .command(let p) = try ArgvParser.parse(["baerchen", "edit", "ID"] + args) else {
                Issue.record("expected a command")
                return []
            }
            return try EditSpec.fromCLI(p)
        }
        #expect(
            try specs([
                "--find", "a", "--replace", "x\\ny", "--all", "--find", "b\\t", "--delete", "--find", "c", "--insert-before",
                "q\\\\",
            ]) == [
                EditSpec(find: "a", action: .replace("x\ny"), all: true),
                EditSpec(find: "b\t", action: .delete, all: true),
                EditSpec(find: "c", action: .insertBefore("q\\"), all: true),
            ])
        #expect(try specs(["--word", "--find", "a", "--insert-after", "z", "--ignore-case"]) == [
            EditSpec(find: "a", action: .insertAfter("z"), ignoreCase: true, word: true)
        ])
        for bad in [
            ["--find", "a"], ["--find", "a", "--find", "b", "--delete"], ["--find", "a", "--delete", "--replace", "x"],
            ["--delete", "--find", "a"],
        ] {
            do {
                _ = try specs(bad)
                Issue.record("expected usage for \(bad)")
            } catch {
                #expect(error.code == .usage && error.message == EditSpec.pairingMessage, "\(bad)")
            }
        }
        do {
            _ = try specs([])
            Issue.record("expected usage")
        } catch {
            #expect(error.code == .usage && error.message.hasPrefix("Missing expected argument '--find <find>'"))
        }
    }
}
