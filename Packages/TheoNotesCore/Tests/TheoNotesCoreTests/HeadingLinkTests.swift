// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

/// Copy Link to Here (M6 Task 9): `NoteStore.headingLink` builds `[[Title/Heading]]`, and the
/// link, parsed and resolved by the real `WikiLinkResolver` (R16), opens the heading it was made for.
@Suite struct HeadingLinkTests {
    let tmp: TempPaths
    let db: AppDatabase
    let store: NoteStore

    init() throws {
        tmp = try TempPaths()
        db = try AppDatabase.inMemory()
        store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
    }

    /// What linking one heading gave: the link, and where the resolver sends it.
    struct Linked {
        var heading: HeadingRef
        var result: Result<String, NoteStore.HeadingLinkFailure>
        var noteId: String?
        var ordinal: Int?
    }

    /// Every heading of a new note with `text`, linked like the menu does and resolved back from
    /// another note.
    private func roundTrip(_ text: String) throws -> (noteId: String, linked: [Linked]) {
        let note = try store.create(text: text)
        let metadata = NoteParser.metadata(for: text)
        var out: [Linked] = []
        for (index, heading) in metadata.headings.enumerated() {
            let result = NoteStore.headingLink(
                forTitle: metadata.title, heading: heading.text, earlierHeadings: metadata.headings[..<index].map(\.text))
            var target: WikiLinkResolver.Target?
            if case .success(let link) = result {
                // Pasted into some other note, the link is parsed like any wiki link.
                let ref = try #require(NoteParser.metadata(for: "pasted " + link).wikiLinks.first)
                target = try store.resolveWikiLink(ref, from: "elsewhere")
            }
            out.append(Linked(heading: heading, result: result, noteId: target?.noteId, ordinal: target?.headingOrdinal))
        }
        return (note.id, out)
    }

    private func link(_ title: String, _ heading: String, earlier: [String] = []) -> Result<String, NoteStore.HeadingLinkFailure> {
        NoteStore.headingLink(forTitle: title, heading: heading, earlierHeadings: earlier)
    }

    @Test func aPlainHeadingBecomesTheWikiLinkAndOpensThatHeading() throws {
        let (id, linked) = try roundTrip("# Plan\n\ntext\n\n## Tasks\n\n### Deep dive")
        #expect(linked.map(\.result) == [.success("[[Plan/Plan]]"), .success("[[Plan/Tasks]]"), .success("[[Plan/Deep dive]]")])
        #expect(linked.map(\.ordinal) == [0, 1, 2])
        #expect(linked.allSatisfy { $0.noteId == id })
    }

    @Test func aMarkupHeadingLinksItsDisplayedText() throws {
        let (id, linked) = try roundTrip("# Title\n\n## **Bold** and *soft* `code` heading\n\n## [site](https://example.com) link")
        #expect(linked.map(\.result) == [
            .success("[[Title/Title]]"), .success("[[Title/Bold and soft code heading]]"), .success("[[Title/site link]]"),
        ])
        #expect(linked.map(\.ordinal) == [0, 1, 2])
        #expect(linked.allSatisfy { $0.noteId == id })
    }

    @Test func aHeadingWithATagLinksItsDisplayedText() throws {
        // A tag is not heading text: `## #tag` has none left (no heading, no badge menu) and the index drops the tag from the others.
        let (id, linked) = try roundTrip("# Title\n\n## #tag\n\n## after #tag words")
        #expect(linked.map(\.result) == [.success("[[Title/Title]]"), .success("[[Title/after words]]")])
        #expect(linked.map(\.ordinal) == [0, 1])
        #expect(linked.allSatisfy { $0.noteId == id })
    }

    @Test func whitespaceRunsCollapseInTheHeadingAndSurroundingSpaceIsTrimmed() throws {
        #expect(link(" Big Title ", "  Some \t heading  ") == .success("[[Big Title/Some heading]]"))
        let (id, linked) = try roundTrip("# Big Title\n\n##   Spaced    out   heading  ")
        #expect(linked.map(\.result) == [.success("[[Big Title/Big Title]]"), .success("[[Big Title/Spaced out heading]]")])
        #expect(linked.map(\.ordinal) == [0, 1])
        #expect(linked.allSatisfy { $0.noteId == id })
    }

    @Test func aTitleWithAWhitespaceRunIsLinkedCollapsedAndOpensItsHeading() throws {
        // The title keeps its run (Bear oracle) and the link collapses it; `TitleKey` collapses both (fix B1).
        let (id, linked) = try roundTrip("# Big    Title\n\n## Section")
        #expect(linked.map(\.result) == [.success("[[Big Title/Big Title]]"), .success("[[Big Title/Section]]")])
        #expect(linked.map(\.ordinal) == [0, 1])
        #expect(linked.allSatisfy { $0.noteId == id })
        // The same through the spelling the user may type (runs, tab) and the stored key.
        for written in ["[[Big    Title/Section]]", "[[Big\tTitle/Section]]"] {
            let ref = try #require(NoteParser.metadata(for: written).wikiLinks.first)
            let target = try #require(try store.resolveWikiLink(ref, from: "elsewhere"))
            #expect(target.noteId == id && target.headingOrdinal == 1, "\(written)")
        }
    }

    @Test func aSlashInTheTitleIsEscapedAndInTheHeadingKept() throws {
        let (id, linked) = try roundTrip("# A/B\n\n## C/D")
        #expect(linked.map(\.result) == [.success(#"[[A\/B/A/B]]"#), .success(#"[[A\/B/C/D]]"#)])
        #expect(linked.map(\.ordinal) == [0, 1])
        #expect(linked.allSatisfy { $0.noteId == id })
    }

    @Test func bracketsAndPipesCannotBeSpelled() throws {
        for (title, heading) in [("[Draft] Plan", "Tasks"), ("Plan", "[x] done"), ("Plan", "a ] b"), ("Q3 | Plan", "Tasks"), ("Plan", "a | b")] {
            #expect(link(title, heading) == .failure(.unspellable), "\(title) / \(heading)")
        }
        // The same through a real note: the heading with a pipe offers no link.
        let (_, linked) = try roundTrip("# Plan\n\n## a | b\n\n## fine")
        #expect(linked.map(\.result) == [.success("[[Plan/Plan]]"), .failure(.unspellable), .success("[[Plan/fine]]")])
        #expect(linked.map(\.ordinal) == [0, nil, 2])
    }

    @Test func aBackslashAtTheEndNeverGivesALinkToTheWrongPlace() throws {
        // `a\` + `/H` would read `\/` as an escaped slash: one title "a/H" and no heading.
        #expect(link(#"a\"#, "H") == .failure(.unspellable))
        // A heading ending in a backslash is either refused or resolves to itself.
        let (id, linked) = try roundTrip("# Plan\n\n## ends\\")
        switch linked[1].result {
        case .failure(let reason): #expect(reason == .unspellable)
        case .success: #expect(linked[1].noteId == id && linked[1].ordinal == 1)
        }
        let (titleId, titled) = try roundTrip("# Path\\\n\n## Part")
        switch titled[1].result {
        case .failure(let reason): #expect(reason == .unspellable)
        case .success: #expect(titled[1].noteId == titleId && titled[1].ordinal == 1)
        }
    }

    @Test func anEmptyTitleOrHeadingHasNoLink() {
        #expect(link("", "Tasks") == .failure(.untitled))
        #expect(link("  \t ", "Tasks") == .failure(.untitled))
        #expect(link("Plan", "") == .failure(.unspellable))
        #expect(link("Plan", "   ") == .failure(.unspellable))
    }

    @Test func aRepeatedHeadingIsRefusedBecauseTheLinkWouldOpenTheFirst() throws {
        let (id, linked) = try roundTrip("# Plan\n\n## Notes\n\n##  notes \n\n### NOTES\n\n## Other")
        #expect(linked.map(\.result) == [
            .success("[[Plan/Plan]]"), .success("[[Plan/Notes]]"), .failure(.repeated), .failure(.repeated), .success("[[Plan/Other]]"),
        ])
        #expect(linked.map(\.ordinal) == [0, 1, nil, nil, 4])
        #expect(linked.allSatisfy { $0.noteId == nil || $0.noteId == id })
        // What the refusal protects against: the resolver sends the repeats to the first.
        let note = try store.create(text: "# Dup\n\n## Notes\n\n## Notes")
        let target = try store.resolveWikiLink(WikiLinkRef(target: "Dup", heading: "Notes"), from: "elsewhere")
        #expect(target?.noteId == note.id && target?.headingOrdinal == 1)
        // The first of the title and a heading with the same text counts too.
        #expect(link("Plan", "Plan", earlier: ["Plan"]) == .failure(.repeated))
        #expect(link("Plan", "Notes", earlier: ["Other"]) == .success("[[Plan/Notes]]"))
    }
}
