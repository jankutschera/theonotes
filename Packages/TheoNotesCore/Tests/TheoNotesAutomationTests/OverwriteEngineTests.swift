// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesAutomation

/// The text engine behind `overwrite` and `overwrite_note`.
@Suite struct OverwriteEngineTests {
    @Test func wholeNoteIsReplacedVerbatim() throws {
        #expect(try OverwriteEngine.apply("# New\r\nbody", to: "# Old\nx\n", target: nil) == "# New\r\nbody")
        #expect(try OverwriteEngine.apply("", to: "# Old\nx\n", target: nil) == "")
    }

    @Test func overwriteSectionKeepsSeparatorAndRequiresHeading() throws {
        let t = "# T\n## Tasks\nold\n## Next\nx\n"
        let s = NoteSections(text: t)
        #expect(try OverwriteEngine.apply("## Tasks\nnew", to: t, target: s.resolve(.parse("## Tasks"))) == "# T\n## Tasks\nnew\n## Next\nx\n")
        #expect(try OverwriteEngine.apply("## Tasks\nnew\n", to: t, target: s.resolve(.parse("## Tasks"))) == "# T\n## Tasks\nnew\n## Next\nx\n")
        #expect(try OverwriteEngine.apply("## Renamed", to: t, target: s.resolve(.parse("## Tasks"))) == "# T\n## Renamed\n## Next\nx\n")
        #expect(try OverwriteEngine.apply("", to: t, target: s.resolve(.parse("## Tasks"))) == "# T\n## Next\nx\n")
        #expect(throws: AutomationError.self) { try OverwriteEngine.apply("new", to: t, target: s.resolve(.parse("## Tasks"))) }
        for bad in ["new", "### Tasks\nx", "\n## Tasks", "# Tasks"] {
            do {
                _ = try OverwriteEngine.apply(bad, to: t, target: s.resolve(.parse("## Tasks")))
                Issue.record("expected usage for \(bad)")
            } catch {
                #expect(error.code == .usage && error.message == "The new content has to start with the section's own heading (a level-2 heading)")
            }
        }
    }

    @Test func lastSectionAndSubsections() throws {
        let t = "# T\n## A\na\n### B\nb\n## C\nc"
        let s = NoteSections(text: t)
        // The section includes its subsections.
        #expect(try OverwriteEngine.apply("## A\nnew", to: t, target: s.resolve(.parse("## A"))) == "# T\n## A\nnew\n## C\nc")
        // Nothing follows the last section, so no line break is added.
        #expect(try OverwriteEngine.apply("## C\nnew", to: t, target: s.resolve(.parse("## C"))) == "# T\n## A\na\n### B\nb\n## C\nnew")
    }

    @Test func overwritePreamble() throws {
        let t = "# T\n\nlead\n## A\n"
        let s = NoteSections(text: t)
        let preamble = try s.resolve(.parse("# T\npreamble"))
        // The preamble's leading blank line stays (ruling M5-R76); only its non-blank lines change.
        #expect(try OverwriteEngine.apply("new lead\n", to: t, target: preamble) == "# T\n\nnew lead\n## A\n")
        #expect(try OverwriteEngine.apply("new lead", to: t, target: preamble) == "# T\n\nnew lead\n## A\n")
        let spaced = "# T\nlead\nmore\n\n## A\n"
        #expect(
            try OverwriteEngine.apply("new", to: spaced, target: NoteSections(text: spaced).resolve(.parse("# T\npreamble")))
                == "# T\nnew\n\n## A\n")
        // Empty content deletes the whole preamble, blank lines included.
        #expect(try OverwriteEngine.apply("", to: t, target: preamble) == "# T\n## A\n")
        do {
            _ = try OverwriteEngine.apply("## B\nx", to: t, target: preamble)
            Issue.record("expected usage")
        } catch {
            #expect(error.code == .usage && error.message == "Preamble content must not begin with a heading")
        }
        #expect(throws: AutomationError.self) { try OverwriteEngine.apply("# X", to: t, target: preamble) }
        // A tag is not a heading.
        #expect(try OverwriteEngine.apply("#tag", to: t, target: preamble) == "# T\n\n#tag\n## A\n")
    }

    /// The blank lines between a section and the next heading stay (ruling M5-R76).
    @Test func blankLineSeparatorBeforeTheNextHeadingIsKept() throws {
        let t = "# T\n## A\na\n\n## B\nb\n"
        let a = try NoteSections(text: t).resolve(.parse("## A"))
        #expect(try OverwriteEngine.apply("## A\nnew", to: t, target: a) == "# T\n## A\nnew\n\n## B\nb\n")
        #expect(try OverwriteEngine.apply("## A\nnew\n", to: t, target: a) == "# T\n## A\nnew\n\n## B\nb\n")
        #expect(try OverwriteEngine.apply("## A\n1\n\n2", to: t, target: a) == "# T\n## A\n1\n\n2\n\n## B\nb\n")
        // Deleting removes the section with its blank lines.
        #expect(try OverwriteEngine.apply("", to: t, target: a) == "# T\n## B\nb\n")
        let nested = "# T\n## A\na\n### S\ns\n\n\n## B\n"
        #expect(
            try OverwriteEngine.apply("## A\nall", to: nested, target: NoteSections(text: nested).resolve(.parse("## A")))
                == "# T\n## A\nall\n\n\n## B\n")
    }

    /// `cat --section` → overwrite with the same bytes is a no-op (ruling M5-R76 as amended in fix
    /// round 2): the write must never grow blank lines.
    @Test func writingBackACatResultLeavesTheNoteUnchanged() throws {
        let cases: [(text: String, address: String)] = [
            ("# T\n## A\na\n## B\nb\n", "## A"),
            ("# T\n## A\na\n\n## B\nb\n", "## A"),
            ("# T\n## A\na\n\n\n## B\nb\n", "## A"),
            ("# T\n## A\na\n### S\ns\n\n## B\n", "## A"),
            ("# T\nlead\n## A\nx\n", "# T\npreamble"),
            ("# T\n\nlead\n## A\nx\n", "# T\npreamble"),
            ("# T\n\n\nlead\n\n## A\nx\n", "# T\npreamble"),
            ("# T\n## A\nold", "## A"),
            ("# T\n## A\nold\n", "## A"),
            ("# T\n## A\nold\n\n\n", "## A"),
            ("# T\r\n## A\r\nold\r\n## B\r\n", "## A"),
            ("# T\r\n## A\r\nold\r\n\r\n## B\r\n", "## A"),
            ("# T\r\n\r\nlead\r\n\r\n## A\r\n", "# T\npreamble"),
            ("# T\r\n## A\r\nold\r\n\r\n", "## A"),
        ]
        for (text, address) in cases {
            let sections = NoteSections(text: text)
            let target = try sections.resolve(.parse(address))
            let read = String(decoding: Array(text.utf8)[sections.range(of: target)], as: UTF8.self)
            #expect(try OverwriteEngine.apply(read, to: text, target: target) == text, "\(text.debugDescription)")
        }
    }

    /// Content that brings its own edge blank lines replaces the old runs (ruling M5-R76).
    @Test func contentBlankLinesReplaceTheOldRuns() throws {
        let t = "# T\n## A\na\n\n## B\n"
        let a = try NoteSections(text: t).resolve(.parse("## A"))
        #expect(try OverwriteEngine.apply("## A\nnew\n\n\n", to: t, target: a) == "# T\n## A\nnew\n\n\n## B\n")
        #expect(try OverwriteEngine.apply("## A\nnew\n\n", to: t, target: a) == "# T\n## A\nnew\n\n## B\n")
        // A trailing blank line without its line break still keeps the next heading on its own line.
        #expect(try OverwriteEngine.apply("## A\nnew\n  ", to: t, target: a) == "# T\n## A\nnew\n  \n## B\n")
        let tight = "# T\n## A\na\n## B\n"
        #expect(
            try OverwriteEngine.apply("## A\nnew\n\n", to: tight, target: NoteSections(text: tight).resolve(.parse("## A")))
                == "# T\n## A\nnew\n\n## B\n")
        let p = "# T\n\n\nlead\n\n## A\n"
        let preamble = try NoteSections(text: p).resolve(.parse("# T\npreamble"))
        #expect(try OverwriteEngine.apply("\nnew\n", to: p, target: preamble) == "# T\n\nnew\n\n## A\n")
        #expect(try OverwriteEngine.apply("new\n\n\n", to: p, target: preamble) == "# T\n\n\nnew\n\n\n## A\n")
        #expect(try OverwriteEngine.apply("new", to: p, target: preamble) == "# T\n\n\nnew\n\n## A\n")
    }

    @Test func crlfSeparatorIsKept() throws {
        let t = "# T\r\n## A\r\nold\r\n## B\r\n"
        let s = NoteSections(text: t)
        #expect(try OverwriteEngine.apply("## A\r\nnew", to: t, target: s.resolve(.parse("## A"))) == "# T\r\n## A\r\nnew\r\n## B\r\n")
        let spaced = "# T\r\n## A\r\nold\r\n\r\n## B\r\n"
        #expect(
            try OverwriteEngine.apply("## A\r\nnew", to: spaced, target: NoteSections(text: spaced).resolve(.parse("## A")))
                == "# T\r\n## A\r\nnew\r\n\r\n## B\r\n")
    }

    @Test func lastSectionAtTheEndOfTheNote() throws {
        // No line break ends the note, so none is added.
        let bare = "# T\n## A\nold"
        let a = try NoteSections(text: bare).resolve(.parse("## A"))
        #expect(try OverwriteEngine.apply("## A\nnew", to: bare, target: a) == "# T\n## A\nnew")
        // The note's final line break ended the last replaced line, so it comes back.
        let ended = "# T\n## A\nold\n"
        #expect(
            try OverwriteEngine.apply("## A\nnew", to: ended, target: NoteSections(text: ended).resolve(.parse("## A")))
                == "# T\n## A\nnew\n")
        let trailing = "# T\n## A\nold\n\n\n"
        #expect(
            try OverwriteEngine.apply("## A\nnew", to: trailing, target: NoteSections(text: trailing).resolve(.parse("## A")))
                == "# T\n## A\nnew\n\n\n")
    }
}
