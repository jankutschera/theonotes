// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesAutomation
@testable import TheoNotesCore

/// The section model behind `cat --section`, `outline` and `search-in`.
@Suite struct NoteSectionsTests {
    static let doc = "# Guide\n\nIntro\n\n## Install\nA\n### Mac\nm\n## Install\nB\n# Build\n## Install\nC\n```\n# not a heading\n```\n"

    @Test func outlineAddressesOffsetsAndPreambles() {
        #expect(
            NoteSections(text: Self.doc).outline(within: nil) == [
                OutlineEntry(address: "# Guide", offset: 0, length: 52),
                OutlineEntry(address: "# Guide\npreamble", offset: 8, length: 8),
                OutlineEntry(address: "## Install\n1", offset: 16, length: 23),
                OutlineEntry(address: "## Install\n1\npreamble", offset: 27, length: 2),
                OutlineEntry(address: "### Mac", offset: 29, length: 10),
                OutlineEntry(address: "## Install\n2", offset: 39, length: 13),
                // No preamble row: "## Install" follows directly.
                OutlineEntry(address: "# Build", offset: 52, length: 45),
                // The fenced "# not a heading" is not a heading.
                OutlineEntry(address: "# Build\n## Install", offset: 60, length: 37),
            ])
    }

    @Test func resolveUniqueAncestorIndexAndPreamble() throws {
        let s = NoteSections(text: Self.doc)
        #expect(try s.resolve(.parse("### Mac")) == .section(2))
        #expect(try s.resolve(.parse("# Build\n## Install")) == .section(5))
        #expect(try s.resolve(.parse("## Install\n2")) == .section(3))
        #expect(try s.resolve(.parse("## Install\n1\npreamble")) == .preamble(1))
        #expect(try s.resolve(.parse("# Guide\n### Mac")) == .section(2))  // ancestors need not be adjacent
        #expect(try s.resolve(.parse("  ##   Install \n 3 ")) == .section(5))  // spaces do not matter
        #expect(try s.resolve(.parse("# Guide\npreamble")) == .preamble(0))
        #expect(s.range(of: .preamble(0)) == 8..<16 && s.range(of: .section(5)) == 60..<97)
        do {
            _ = try s.resolve(.parse("## Install\npreamble"))
            Issue.record("expected ambiguous")
        } catch {
            #expect(error.code == .ambiguous)
            let candidates = error.details?["candidates"]?.array ?? []
            #expect(candidates.compactMap { $0["address"]?.string } == ["## Install\n1\npreamble", "## Install\n2", "# Build\n## Install"])
        }
        // Every canonical address resolves back to its own section.
        for (i, section) in s.sections.enumerated() {
            #expect(try s.resolve(.parse(section.address)) == .section(i))
        }
    }

    @Test func missingAndAmbiguousAddressesMatchBearcli() throws {
        let s = NoteSections(text: Self.doc)
        let missing = AutomationError(code: .notFound, message: "No section matched the address.", details: nil)
        #expect(throws: missing) { try s.resolve(.parse("## Nope")) }
        #expect(throws: missing) { try s.resolve(.parse("## install")) }  // case matters
        #expect(throws: missing) { try s.resolve(.parse("## Install\n4")) }
        #expect(throws: missing) { try s.resolve(.parse("# Build\npreamble")) }  // empty lead
        #expect(throws: missing) { try s.resolve(.parse("### Mac\npreamble")) }  // no subheading
        #expect(throws: missing) { try s.resolve(.parse("2")) }
        do {
            _ = try s.resolve(.parse("## Install"))
            Issue.record("expected ambiguous")
        } catch {
            #expect(error.code == .ambiguous && error.message == "3 sections match that address; repeat the call with one of the candidates.")
            let candidates = error.details?["candidates"]?.array ?? []
            #expect(candidates.count == 3)  // {address, offset, length, snippet}
            #expect(candidates.first?.keys == ["address", "offset", "length", "snippet"])
            #expect(candidates.compactMap { $0["offset"]?.intValue } == [16, 39, 60])
            #expect(candidates.compactMap { $0["length"]?.intValue } == [23, 13, 37])
            #expect(candidates.compactMap { $0["snippet"]?.string } == ["A\n### Mac\nm\n", "B\n", "C\n```\n# not a heading\n```\n"])
        }
    }

    @Test func addressParsing() throws {
        #expect(try SectionAddress.parse("## Install\n1\npreamble") == SectionAddress(lines: ["## Install"], index: 1, preamble: true))
        #expect(try SectionAddress.parse("# A\n\n## B\n") == SectionAddress(lines: ["# A", "## B"], index: nil, preamble: false))
        #expect(try SectionAddress.parse("## B\n0") == SectionAddress(lines: ["## B", "0"], index: nil, preamble: false))
        #expect(try SectionAddress.parse("preamble") == SectionAddress(lines: ["preamble"], index: nil, preamble: false))
        let empty = AutomationError(code: .usage, message: "Address must not be empty")
        #expect(throws: empty) { try SectionAddress.parse("") }
        #expect(throws: empty) { try SectionAddress.parse(" \n\t\n") }
    }

    @Test func outlineWithinASectionOrPreamble() {
        let s = NoteSections(text: Self.doc)
        #expect(s.outline(within: .section(1)).map(\.address) == ["## Install\n1", "## Install\n1\npreamble", "### Mac"])
        #expect(s.outline(within: .section(4)).map(\.address) == ["# Build", "# Build\n## Install"])
        #expect(s.outline(within: .preamble(0)) == [OutlineEntry(address: "# Guide\npreamble", offset: 8, length: 8)])
        #expect(NoteSections(text: "no headings\n").outline(within: nil).isEmpty)
    }

    @Test func innermostSectionOfAnOffset() {
        let s = NoteSections(text: Self.doc)
        #expect(s.innermost(at: 9)?.address == "# Guide\npreamble")
        #expect(s.innermost(at: 27)?.address == "## Install\n1\npreamble")
        #expect(s.innermost(at: 16)?.address == "## Install\n1")  // the heading line is not the lead
        #expect(s.innermost(at: 37)?.address == "### Mac")
        #expect(s.innermost(at: 80)?.address == "# Build\n## Install")
        let lead = NoteSections(text: "pre\n# H\nx\n")
        #expect(lead.innermost(at: 0)?.address == "preamble" && lead.innermost(at: 4)?.address == "# H")
        #expect(
            lead.outline(within: nil)
                == [OutlineEntry(address: "preamble", offset: 0, length: 4), OutlineEntry(address: "# H", offset: 4, length: 6)])
    }

    @Test func offsetsAreUTF8BytesForEmojiCJKAndCombiningMarks() throws {
        let t = "# 👩‍👩‍👧 Ünïcödé — 日本\nx\n## e\u{301}tude\ny\n"
        let o = NoteSections(text: t).outline(within: nil)
        #expect(o.last!.offset == t.utf8.count - "## e\u{301}tude\ny\n".utf8.count)
        #expect(o.map(\.address) == ["# 👩‍👩‍👧 Ünïcödé — 日本", "# 👩‍👩‍👧 Ünïcödé — 日本\npreamble", "## e\u{301}tude"])
        #expect(o.first!.length == t.utf8.count)
        let s = NoteSections(text: t)
        #expect(try s.resolve(.parse("## e\u{301}tude")) == .section(1))
    }

    @Test func headingLinesKeepCRLFAndFrontMatterOut() throws {
        let t = "---\ntitle: x\n---\n# A\r\nbody\r\n## B\r\n"
        let s = NoteSections(text: t)
        #expect(s.sections.map(\.headingLine) == ["# A", "## B"])
        #expect(s.sections.first?.range == 17..<t.utf8.count)
    }

    /// Observed against Bear: a blank lead is a preamble too; only an empty one is not.
    @Test func blankLeadIsAPreambleAndAnEmptyOneIsNot() throws {
        let s = NoteSections(text: "# A\n\n \t\n## B\nx\n")
        #expect(s.outline(within: nil).map(\.address) == ["# A", "# A\npreamble", "## B"])
        #expect(try s.resolve(.parse("# A\npreamble")) == .preamble(0))
        let tight = NoteSections(text: "# A\n## B\nx\n")
        #expect(tight.outline(within: nil).map(\.address) == ["# A", "## B"])
        #expect(throws: AutomationError(code: .notFound, message: "No section matched the address.")) {
            try tight.resolve(.parse("# A\npreamble"))
        }
        // The range of a real preamble includes its leading blank lines.
        #expect(NoteSections(text: "# A\n\nlead\n## B\n").outline(within: nil)[1] == OutlineEntry(address: "# A\npreamble", offset: 4, length: 6))
    }

    /// Observed against Bear: `preamble` is the text above the first heading (a blank line
    /// counts), only in a note that has a heading; empty headings are sections; no-break spaces
    /// in a heading are plain spaces in its address.
    @Test func leadEmptyHeadingsAndNoBreakSpacesFollowBear() throws {
        let t = "intro\n# A\nx\n#\n## \ny\n"
        let s = NoteSections(text: t)
        #expect(s.outline(within: nil).map(\.address) == ["preamble", "# A", "#", "## "].map { SectionAddress.normalize(Substring($0)) })
        #expect(s.lead == 0..<6)
        #expect(try s.resolve(.parse("preamble")) == .lead)
        #expect(s.range(of: .lead) == 0..<6 && s.address(of: .lead) == "preamble")
        #expect(s.outline(within: .lead) == [OutlineEntry(address: "preamble", offset: 0, length: 6)])
        #expect(NoteSections(text: "\n# A\n").outline(within: nil).first == OutlineEntry(address: "preamble", offset: 0, length: 1))
        #expect(NoteSections(text: "# A\nx\n").lead == nil)
        #expect(NoteSections(text: "just text\n").outline(within: nil).isEmpty)
        #expect(throws: AutomationError(code: .notFound, message: "No section matched the address.")) {
            try NoteSections(text: "# A\nx\n").resolve(.parse("preamble"))
        }
        let nbsp = NoteSections(text: "## Head\u{00A0}one:\u{00A0}\nx\n")
        #expect(nbsp.sections[0].address == "## Head one:")
        #expect(try nbsp.resolve(.parse("## Head one:")) == .section(0))
    }

    @Test func lastSectionWithoutTrailingNewline() {
        let t = "# A\nx\n## B\ny"
        #expect(
            NoteSections(text: t).outline(within: nil) == [
                OutlineEntry(address: "# A", offset: 0, length: 12),
                OutlineEntry(address: "# A\npreamble", offset: 4, length: 2),
                OutlineEntry(address: "## B", offset: 6, length: 6),
            ])
        #expect(NoteSections(text: "# Only").outline(within: nil) == [OutlineEntry(address: "# Only", offset: 0, length: 6)])
    }

    @Test func canonicallyEquivalentSpellingsAddressTheSameSection() throws {
        let nfc = NoteSections(text: "# Caf\u{E9}\nx\n")
        let nfd = NoteSections(text: "# Cafe\u{301}\nx\n")
        #expect(try nfc.resolve(.parse("# Cafe\u{301}")) == .section(0))
        #expect(try nfd.resolve(.parse("# Caf\u{E9}")) == .section(0))
        #expect(nfd.sections[0].address.unicodeScalars.count == "# Cafe\u{301}".unicodeScalars.count)  // as written
    }

    @Test func findMatchesLineBreaksInCRLFText() {
        func find(_ needle: String, _ text: String, ignoreCase: Bool = true) -> [Range<Int>] {
            NoteFind.occurrences(of: needle, in: text, within: nil, ignoreCase: ignoreCase, word: false)
        }
        #expect(find("\n", "xx\r\nyy") == [3..<4])
        #expect(find("\r\nYY", "xx\r\nyy") == [2..<6])
        #expect(find("x\nyy", "xx\nyy\r\nx\nYY") == [1..<5, 7..<11])
        #expect(find("x\nyy", "xx\nyy\r\nx\nYY", ignoreCase: false) == [1..<5])
        #expect(find("a\nb", "a\r\nb") == [])  // a CR is a character of its own here
    }

    @Test func attachmentLinkOffsetsAreUTF8Bytes() {
        let text = "\u{FEFF}Ä ![](a.png)\r\n```\n![](code.png)\n```\n日 [b.pdf](b.pdf)<!-- {\"embed\":\"true\"} --> ![](a.png)\n"
        let links = NoteParser.attachmentLinks(in: text)
        let tail = "日 [b.pdf](b.pdf)<!-- {\"embed\":\"true\"} --> ![](a.png)\n"
        let lineStart = text.utf8.count - tail.utf8.count
        #expect(
            links == [
                NoteParser.AttachmentLink(filename: "a.png", offset: 3 + "Ä ".utf8.count),
                NoteParser.AttachmentLink(filename: "b.pdf", offset: lineStart + "日 ".utf8.count),
                NoteParser.AttachmentLink(
                    filename: "a.png", offset: lineStart + "日 [b.pdf](b.pdf)<!-- {\"embed\":\"true\"} --> ".utf8.count),
            ])
        #expect(NoteParser.attachmentLinks(in: "no links") == [])
    }

    @Test func contentHashIsSevenHexDigitsOfSHA256() {
        #expect(ContentHash.of("") == "e3b0c44")
        #expect(ContentHash.of("abc") == "ba7816b")
        #expect(ContentHash.of("xabcx".utf8.dropFirst().dropLast()) == "ba7816b")
    }

    @Test func findIsNonOverlappingCaseAndWordAware() {
        func find(_ needle: String, _ text: String, within: Range<Int>? = nil, ignoreCase: Bool = false, word: Bool = false)
            -> [Range<Int>]
        { NoteFind.occurrences(of: needle, in: text, within: within, ignoreCase: ignoreCase, word: word) }
        #expect(find("aa", "aaaa") == [0..<2, 2..<4])
        #expect(find("AB", "ab Ab") == [])
        #expect(find("AB", "ab Ab", ignoreCase: true) == [0..<2, 3..<5])
        #expect(find("É", "école École", ignoreCase: true) == [0..<2, 7..<9])
        #expect(find("ecole", "École", ignoreCase: true) == [])  // diacritic-sensitive
        #expect(find("cat", "cat concat cat_x cats (cat)", word: true) == [0..<3, 23..<26])
        #expect(find("ab", "ab ab ab", within: 1..<8) == [3..<5, 6..<8])
        #expect(find("x", "😀x", within: 1..<5) == [4..<5])
        #expect(find("", "abc") == [])
    }
}
