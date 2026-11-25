// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import GRDB
@testable import TheoNotesCore

@Suite struct WikiLinkRewriteTests {
    let tmp: TempPaths
    let db: AppDatabase
    let store: NoteStore
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let t1 = Date(timeIntervalSince1970: 1_800_000_100)
    let t2 = Date(timeIntervalSince1970: 1_800_000_200)
    let t3 = Date(timeIntervalSince1970: 1_800_000_300)

    init() throws {
        tmp = try TempPaths()
        db = try AppDatabase.inMemory()
        store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
    }

    private func text(_ note: Note) throws -> String {
        try #require(try store.note(id: note.id)).text
    }

    private func state(_ note: Note) throws -> LinkTargetState {
        try #require(try store.linkTargetState(id: note.id))
    }

    /// Changes the note's text (as the editor's commit would) and returns its state before.
    @discardableResult
    private func edit(_ note: Note, to newText: String, at date: Date) throws -> LinkTargetState {
        let before = try state(note)
        let current = try #require(try store.note(id: note.id))
        _ = try store.updateText(id: note.id, text: newText, expectedRevision: current.revision, now: date)
        return before
    }

    private func rule(
        target: String? = nil, newTitle: String? = nil, heading: (String, String)? = nil, sameNote: Bool = false
    ) -> NoteStore.WikiLinkRewriteRule {
        NoteStore.WikiLinkRewriteRule(
            targetKey: target.map(CanonicalKey.make), newTitle: newTitle,
            heading: heading.map { (CanonicalKey.make($0.0), $0.1) }, sameNote: sameNote
        )
    }

    private func setFlag(_ column: String, _ note: Note) throws {
        try db.pool.write { try $0.execute(sql: "UPDATE note SET \(column) = 1 WHERE id = ?", arguments: [note.id]) }
    }

    // MARK: - Text rewriting

    @Test func testRewriteKeepsHeadingAliasEscapingAndSpacing() throws {
        // Review Focus #4: `[[Title/Heading|alias]]` keeps heading and alias.
        let rewrite = { (s: String) in NoteStore.rewritingWikiLinks(in: s, self.rule(target: "Old", newTitle: "New")) }
        #expect(rewrite("See [[Old/Heading|alias]].") == "See [[New/Heading|alias]].")
        #expect(rewrite("[[Old]] [[old|x]] [[OLD/h]]") == "[[New]] [[New|x]] [[New/h]]")
        #expect(rewrite("[[ Old  / Heading | alias ]]") == "[[ New  / Heading | alias ]]")
        #expect(rewrite("| [[Old\\|alias]] |") == "| [[New\\|alias]] |")
        #expect(rewrite("[[Older]] [[Ol]] [[/Old]]") == nil)
        #expect(NoteStore.rewritingWikiLinks(in: "[[Old/h]]", rule(target: "Old", newTitle: "a/b")) == "[[a\\/b/h]]")
        #expect(NoteStore.rewritingWikiLinks(in: "[[a\\/b]]", rule(target: "a/b", newTitle: "c")) == "[[c]]")
        #expect(NoteStore.rewritingWikiLinks(in: "x\r\n[[Old]]", rule(target: "Old", newTitle: "New")) == "x\n[[New]]")
        #expect(NoteStore.rewritingWikiLinks(in: "\u{FEFF}[[Old]] and [[Old]]", rule(target: "Old", newTitle: "Ünï 日本"))
            == "\u{FEFF}[[Ünï 日本]] and [[Ünï 日本]]")
    }

    @Test func testRewriteNeverTouchesCodeMathCommentsOrFrontMatter() throws {
        let source = """
            ---
            link: [[Old]]
            ---
            Text [[Old]]
            Inline `[[Old]]` and $[[Old]]$ and <!-- [[Old]] -->
            ```
            [[Old]]
            ```
            $$
            [[Old]]
            $$
            <!--
            [[Old]]
            -->
            \\[[Old]]
            """
        let expected = source.replacingOccurrences(of: "Text [[Old]]", with: "Text [[New]]")
        #expect(NoteStore.rewritingWikiLinks(in: source, rule(target: "Old", newTitle: "New")) == expected)
    }

    @Test func testUnlinkableTitleLeavesTheLinkAlone() throws {
        for title in ["a|b", "a]b", "a[b", "x\\"] {
            #expect(NoteStore.rewritingWikiLinks(in: "[[Old/h]]", rule(target: "Old", newTitle: title)) == nil, "\(title)")
        }
    }

    @Test func testHeadingRewrite() throws {
        let headingOnly = rule(target: "Note", heading: ("Old heading", "New heading"))
        #expect(NoteStore.rewritingWikiLinks(in: "[[Note/old HEADING|a]] [[Note/Other]] [[Note]]", headingOnly)
            == "[[Note/New heading|a]] [[Note/Other]] [[Note]]")
        // `[[/heading]]` belongs to the note it is in: only the renamed note's own ones change.
        #expect(NoteStore.rewritingWikiLinks(in: "[[/Old heading]]", headingOnly) == nil)
        let own = rule(target: "Note", heading: ("Old heading", "New heading"), sameNote: true)
        #expect(NoteStore.rewritingWikiLinks(in: "[[/Old heading]] [[ / Old heading|x]]", own)
            == "[[/New heading]] [[ / New heading|x]]")
        // Title and heading together; a slash in the new heading stays plain unless the link escaped one.
        let both = rule(target: "Old", newTitle: "New", heading: ("A", "B/C"))
        #expect(NoteStore.rewritingWikiLinks(in: "[[Old/A]] [[Old/A\\/x]] [[Old/x]]", both) == "[[New/B/C]] [[New/A\\/x]] [[New/x]]")
        #expect(NoteStore.rewritingWikiLinks(in: "[[Old/a\\/b]]", rule(target: "Old", heading: ("a/b", "c/d")))
            == "[[Old/c\\/d]]")
    }

    @Test func testRenamedHeadingOnlyWhenUnambiguous() {
        #expect(NoteStore.renamedHeading(from: ["A", "B", "C"], to: ["A", "X", "C"]).map { [$0.old, $0.new] } == ["B", "X"])
        #expect(NoteStore.renamedHeading(from: ["A", "B"], to: ["A", "b"]) == nil)  // same key
        #expect(NoteStore.renamedHeading(from: ["A", "B"], to: ["X", "Y"]) == nil)  // two renamed
        #expect(NoteStore.renamedHeading(from: ["A", "B"], to: ["A", "B", "C"]) == nil)  // count changed
        #expect(NoteStore.renamedHeading(from: ["A", "B"], to: ["A"]) == nil)
        #expect(NoteStore.renamedHeading(from: ["A", "A"], to: ["A", "X"]) == nil)  // which `A` did links mean?
        #expect(NoteStore.renamedHeading(from: ["A", "B"], to: ["A", "a"]) == nil)  // the new one is not unique
        #expect(NoteStore.renamedHeading(from: [], to: []) == nil)
    }

    // MARK: - Store

    @Test func testTitleRenameRewritesLinksInOtherNotes() throws {
        let target = try store.create(text: "Old Title\nbody", now: t0)
        let a = try store.create(text: "A [[Old Title/Heading|alias]] and [[old title]]", now: t0)
        let b = try store.create(text: "B [[Other]]", now: t0)
        let c = try store.create(text: "C `[[Old Title]]` [[Old Title]]", now: t0)
        let before = try edit(target, to: "New Title\nbody", at: t1)
        let revisionA = try #require(try store.note(id: a.id)).revision

        let result = try store.rewriteWikiLinks(to: target.id, from: before, now: t2)
        #expect(result.changedNoteIds == [a.id, c.id].sorted())
        #expect(result.didChange)
        #expect(try text(a) == "A [[New Title/Heading|alias]] and [[New Title]]")
        #expect(try text(b) == "B [[Other]]")
        #expect(try text(c) == "C `[[Old Title]]` [[New Title]]")
        #expect(try text(target) == "New Title\nbody")
        #expect(result.previousTexts[a.id] == "A [[Old Title/Heading|alias]] and [[old title]]")
        #expect(result.rewrittenTexts[a.id] == "A [[New Title/Heading|alias]] and [[New Title]]")
        let rewritten = try #require(try store.note(id: a.id))
        #expect(rewritten.revision == revisionA + 1)
        #expect(rewritten.modifiedAt == t2)
        // The indexer re-resolved: the links now point at the new title.
        let keys = try db.pool.read {
            try String.fetchAll($0, sql: "SELECT targetKey FROM wiki_link WHERE sourceNoteId = ? ORDER BY ordinal", arguments: [a.id])
        }
        #expect(keys == ["new title", "new title"])
    }

    @Test func testDuplicatesRewriteOnlyLinksThatResolvedToTheNote() throws {
        let older = try store.create(text: "Dup\nolder", now: t0)
        let newer = try store.create(text: "Dup\nnewer", now: t1)
        let linker = try store.create(text: "L [[Dup]]", now: t0)

        // Links resolve to the most recently modified `Dup`: renaming the older one leaves them.
        let olderBefore = try edit(older, to: "Renamed older\nolder", at: t2)
        let none = try store.rewriteWikiLinks(to: older.id, from: olderBefore, now: t2)
        #expect(!none.didChange && none.changedNoteIds.isEmpty)
        #expect(try text(linker) == "L [[Dup]]")

        let newerBefore = try edit(newer, to: "Renamed newer\nnewer", at: t3)
        let result = try store.rewriteWikiLinks(to: newer.id, from: newerBefore, now: t3)
        #expect(result.changedNoteIds == [linker.id])
        #expect(try text(linker) == "L [[Renamed newer]]")
    }

    @Test func testResolutionIsJudgedBeforeTheChange() throws {
        // The renamed note's own edit makes it the most recent note — judged by its time before.
        let renamed = try store.create(text: "Dup\nA", now: t0)
        _ = try store.create(text: "Dup\nB", now: t1)
        let linker = try store.create(text: "L [[Dup]]", now: t0)
        let before = try edit(renamed, to: "Fresh\nA", at: t3)
        #expect(before.modifiedAt == t0)
        #expect(!(try store.rewriteWikiLinks(to: renamed.id, from: before, now: t3)).didChange)
        #expect(try text(linker) == "L [[Dup]]")
    }

    @Test func testTrashedDuplicateDoesNotWinResolution() throws {
        let note = try store.create(text: "Dup\nA", now: t0)
        let trashed = try store.create(text: "Dup\nB", now: t1)
        try store.trash([trashed.id])
        let linker = try store.create(text: "L [[Dup]]", now: t0)
        let before = try edit(note, to: "Live\nA", at: t2)
        #expect(try store.rewriteWikiLinks(to: note.id, from: before, now: t2).changedNoteIds == [linker.id])
    }

    @Test func testCaseOnlyAndEmptyTitlesDoNotRewrite() throws {
        let note = try store.create(text: "Title\n", now: t0)
        let linker = try store.create(text: "L [[Title]]", now: t0)

        let caseOnly = try edit(note, to: "TITLE\n", at: t1)
        #expect(!(try store.rewriteWikiLinks(to: note.id, from: caseOnly, now: t1)).didChange)

        let emptied = try edit(note, to: "\nbody", at: t2)
        #expect(!(try store.rewriteWikiLinks(to: note.id, from: emptied, now: t2)).didChange)
        #expect(try text(linker) == "L [[Title]]")

        // Old title empty (an untitled note gets its first title).
        let untitled = try store.create(text: "", now: t0)
        _ = try store.create(text: "[[]] [[ ]]", now: t0)
        let first = try edit(untitled, to: "Named", at: t1)
        #expect(!(try store.rewriteWikiLinks(to: untitled.id, from: first, now: t1)).didChange)
    }

    @Test func testHeadingRenameRewritesOtherNotesAndOwnLinks() throws {
        let note = try store.create(text: "Note\n## Intro\n## Old heading\nsee [[/Old heading]] and [[/Intro]]", now: t0)
        let other = try store.create(text: "[[Note/Old heading|x]] [[Note/Intro]] [[/Old heading]]", now: t0)
        let before = try edit(note, to: "Note\n## Intro\n## New heading\nsee [[/Old heading]] and [[/Intro]]", at: t1)

        let result = try store.rewriteWikiLinks(to: note.id, from: before, now: t2)
        #expect(Set(result.changedNoteIds) == [note.id, other.id])
        #expect(try text(note) == "Note\n## Intro\n## New heading\nsee [[/New heading]] and [[/Intro]]")
        // The other note's `[[/Old heading]]` is a link into that note itself.
        #expect(try text(other) == "[[Note/New heading|x]] [[Note/Intro]] [[/Old heading]]")
    }

    @Test func testAmbiguousHeadingChangeRewritesNothing() throws {
        let note = try store.create(text: "Note\n## A\n## B", now: t0)
        let other = try store.create(text: "[[Note/A]] [[Note/B]]", now: t0)
        let before = try edit(note, to: "Note\n## X\n## Y", at: t1)
        #expect(!(try store.rewriteWikiLinks(to: note.id, from: before, now: t1)).didChange)
        #expect(try text(other) == "[[Note/A]] [[Note/B]]")
    }

    @Test func testTitleAndHeadingTogether() throws {
        // `# Old` is both the title and the first heading: `[[Old/Old]]` follows both.
        let note = try store.create(text: "# Old\n## Sub", now: t0)
        let other = try store.create(text: "[[Old/Old]] [[Old/Sub]] [[Old]]", now: t0)
        let before = try edit(note, to: "# New\n## Sub", at: t1)
        _ = try store.rewriteWikiLinks(to: note.id, from: before, now: t2)
        #expect(try text(other) == "[[New/New]] [[New/Sub]] [[New]]")
    }

    @Test func testLockedReadOnlyAndSkippedNotesAreLeftAndReported() throws {
        let note = try store.create(text: "Old", now: t0)
        let plain = try store.create(text: "P [[Old]]", now: t0)
        let locked = try store.create(text: "[[Old]] L", now: t0)
        let readOnly = try store.create(text: "[[Old]] R", now: t0)
        let open = try store.create(text: "[[Old]] O", now: t0)
        try setFlag("isLocked", locked)
        try setFlag("isReadOnly", readOnly)
        let before = try edit(note, to: "New", at: t1)

        let result = try store.rewriteWikiLinks(to: note.id, from: before, skipping: [open.id], now: t2)
        #expect(result.changedNoteIds == [plain.id])
        #expect(result.skippedLocked == [locked.id])
        #expect(result.skippedReadOnly == [readOnly.id])
        #expect(try text(locked) == "[[Old]] L")
        #expect(try text(readOnly) == "[[Old]] R")
        #expect(try text(open) == "[[Old]] O")
        #expect(result.skippedUnsaved == [open.id])
    }

    @Test func testABusyNoteDefersTheWholeRewrite() throws {
        let note = try store.create(text: "Note\n## Old\nsee [[/Old]]", now: t0)
        let other = try store.create(text: "O [[Note/Old]]", now: t0)
        let unrelated = try store.create(text: "U", now: t0)
        let before = try edit(note, to: "Note\n## New\nsee [[/Old]]", at: t1)

        let deferred = try store.rewriteWikiLinks(to: note.id, from: before, deferringIfTouching: [note.id], now: t2)
        #expect(deferred.deferred && !deferred.didChange)
        #expect(try text(other) == "O [[Note/Old]]")
        #expect(try text(note) == "Note\n## New\nsee [[/Old]]")

        // A busy note the rewrite does not touch does not hold it up.
        let result = try store.rewriteWikiLinks(to: note.id, from: before, deferringIfTouching: [unrelated.id], now: t2)
        #expect(!result.deferred)
        #expect(Set(result.changedNoteIds) == [note.id, other.id])
    }

    @Test func testUndoRestoresOnlyNotesStillAtTheRewrittenTextAndRedoReapplies() throws {
        let note = try store.create(text: "Old", now: t0)
        let a = try store.create(text: "[[Old]] a", now: t0)
        let b = try store.create(text: "[[Old]] b", now: t0)
        let before = try edit(note, to: "New", at: t1)
        let result = try store.rewriteWikiLinks(to: note.id, from: before, now: t2)
        #expect(result.changedNoteIds.count == 2)

        let edited = try #require(try store.note(id: b.id))
        _ = try store.updateText(id: b.id, text: "[[New]] b edited", expectedRevision: edited.revision, now: t2)
        #expect(try store.undoLinkRewrite(result, now: t3) == [a.id])
        #expect(try text(a) == "[[Old]] a")
        #expect(try text(b) == "[[New]] b edited")
        #expect(try text(note) == "New")

        #expect(try store.redoLinkRewrite(result, now: t3) == [a.id])
        #expect(try text(a) == "[[New]] a")
    }

    @Test func testLinkTargetState() throws {
        let note = try store.create(text: "# Title\n## One\n### Two", now: t0)
        let state = try state(note)
        #expect(state.title == "Title")
        #expect(state.headings == ["Title", "One", "Two"])
        #expect(state.modifiedAt == t0)
        #expect(state.changeKey == ["title", "title", "one", "two"])
        #expect(try store.linkTargetState(id: "missing") == nil)
        #expect(LinkTargetState(text: "# Title\n## One\n### Two", modifiedAt: t0) == state)
        #expect(state.headingLevels == [1, 2, 3])
        let retyping = LinkTargetState(text: "# Title\n## \n```\n### \n```\n#### Four", modifiedAt: t0)
        #expect(retyping.headings == ["Title", "Four"] && retyping.headingLevels == [1, 4])
        #expect(retyping.emptyHeadingLevels == [2])  // not the one in the code block
    }
}
