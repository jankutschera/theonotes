// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesAutomation
import TheoNotesCore

/// The text engine behind `append` and `append_to_note`.
@Suite struct AppendEngineTests {
    private func append(_ content: String, _ position: AppendPosition, _ text: String, section: String? = nil) throws -> String {
        let target = try section.map { a throws(AutomationError) in try NoteSections(text: text).resolve(.parse(a)) }
        return AppendEngine.apply(content, position: position, target: target, to: text).text
    }

    @Test func appendWholeNoteRespectsTitleTopTagsBottomTagsAndFootnotes() throws {
        #expect(AppendEngine.apply("X", position: .beginning, target: nil, to: "# T\n#a #b\nbody\n").text == "# T\n#a #b\nX\nbody\n")
        #expect(AppendEngine.apply("X", position: .end, target: nil, to: "# T\nbody\n\n#a\n[^1]: n\n").text == "# T\nbody\nX\n\n#a\n[^1]: n\n")
        #expect(AppendEngine.apply("X", position: .end, target: nil, to: "body").text == "body\nX\n")
    }

    @Test func wholeNoteEdgeCases() throws {
        #expect(try append("X", .beginning, "") == "X\n")
        #expect(try append("X", .end, "") == "X\n")
        #expect(try append("X", .beginning, "# T") == "# T\nX\n")
        #expect(try append("X", .end, "# T\n") == "# T\nX\n")
        // Front matter: the title is the first line after it.
        #expect(try append("X", .beginning, "---\na: 1\n---\n# T\nbody\n") == "---\na: 1\n---\n# T\nX\nbody\n")
        // A line with text besides its tags is body, not a tag line.
        #expect(try append("X", .beginning, "# T\n#a text\nbody\n") == "# T\nX\n#a text\nbody\n")
        #expect(try append("X", .end, "# T\nbody\n#a text\n") == "# T\nbody\n#a text\nX\n")
        // Trailing blank lines stay last; the title line is never part of the bottom run.
        #expect(try append("X", .end, "# T\nbody\n\n\n") == "# T\nbody\nX\n\n\n")
        #expect(try append("X", .end, "# T\n#a\n") == "# T\nX\n#a\n")
        // A footnote's indented continuation belongs to it; a tag inside code is no tag.
        #expect(try append("X", .end, "# T\nbody\n[^1]: n\n    more\n") == "# T\nbody\nX\n[^1]: n\n    more\n")
        #expect(try append("X", .end, "# T\n```\n#a\n```\n") == "# T\n```\n#a\n```\nX\n")
        #expect(try append("X", .end, "# T\nbody\n#a #b\n[^n]: one\n\n#c") == "# T\nbody\nX\n#a #b\n[^n]: one\n\n#c")
    }

    /// The tag-placement setting decides only for a note with no body.
    @Test func tagPositionDecidesForNotesWithoutBody() {
        func run(_ position: AppendPosition, _ text: String, _ tags: TagPosition) -> String {
            AppendEngine.apply("X", position: position, target: nil, to: text, tagPosition: tags).text
        }
        let bodiless = "# T\n#a\n"
        #expect(run(.end, bodiless, .top) == "# T\n#a\nX\n")
        #expect(run(.beginning, bodiless, .top) == "# T\n#a\nX\n")
        #expect(run(.end, bodiless, .bottom) == "# T\nX\n#a\n")
        #expect(run(.beginning, bodiless, .bottom) == "# T\nX\n#a\n")
        #expect(AppendEngine.apply("X", position: .beginning, target: nil, to: bodiless).text == "# T\nX\n#a\n")
        #expect(run(.end, "# T\n#a\n\n[^1]: n\n", .top) == "# T\n#a\nX\n\n[^1]: n\n")
        // With a body the setting changes nothing.
        let full = "# T\n#a\nbody\n\n#b\n"
        for tags in [TagPosition.top, .bottom] {
            #expect(run(.beginning, full, tags) == "# T\n#a\nX\nbody\n\n#b\n")
            #expect(run(.end, full, tags) == "# T\n#a\nbody\nX\n\n#b\n")
        }
    }

    @Test func contentKeepsItsOwnLineAndIsNotRewritten() throws {
        #expect(try append("X\n", .end, "# T\nbody\n") == "# T\nbody\nX\n")
        #expect(try append("X\\n", .end, "# T\n") == "# T\nX\\n\n")
        #expect(try append("", .end, "# T\nbody") == "# T\nbody")
        let result = AppendEngine.apply("ü", position: .end, target: nil, to: "# Tä\nbody")
        #expect(result.text == "# Tä\nbody\nü\n" && result.insertedAt == 11)
    }

    @Test func crlfNotesGetCRLFSeparators() throws {
        #expect(try append("X", .end, "# T\r\nbody") == "# T\r\nbody\r\nX\r\n")
        #expect(try append("X", .beginning, "# T\r\n#a\r\nbody\r\n") == "# T\r\n#a\r\nX\r\nbody\r\n")
        #expect(try append("X", .end, "# T\r\nbody\r\n\r\n#a\r\n") == "# T\r\nbody\r\nX\r\n\r\n#a\r\n")
        // Content's own line breaks are the caller's.
        #expect(try append("A\nB", .end, "# T\r\n") == "# T\r\nA\nB\r\n")
    }

    @Test func appendToSectionEndAfterSubsectionsKeepsBlankLines() throws {
        let t = "## A\na\n### B\nb\n\n## C\n"
        let result = AppendEngine.apply("X", position: .end, target: try NoteSections(text: t).resolve(.parse("## A")), to: t)
        #expect(result.text == "## A\na\n### B\nb\nX\n\n## C\n" && result.insertedAt == 15)
    }

    @Test func sectionBeginningAndPreamble() throws {
        let t = "# T\n## A\na\n## B\n"
        #expect(try append("X", .beginning, t, section: "## A") == "# T\n## A\nX\na\n## B\n")
        #expect(try append("X", .end, t, section: "## A") == "# T\n## A\na\nX\n## B\n")
        #expect(try append("X", .end, "# T\n## A", section: "## A") == "# T\n## A\nX\n")
        #expect(try append("X", .beginning, "# T\n## A", section: "## A") == "# T\n## A\nX\n")
        let p = "# T\nlead\n\n## A\n"
        #expect(try append("X", .beginning, p, section: "# T\npreamble") == "# T\nX\nlead\n\n## A\n")
        #expect(try append("X", .end, p, section: "# T\npreamble") == "# T\nlead\nX\n\n## A\n")
    }
}
