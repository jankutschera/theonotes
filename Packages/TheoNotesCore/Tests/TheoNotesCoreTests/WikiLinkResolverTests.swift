// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import GRDB
@testable import TheoNotesCore

/// Ruling R16: one resolution rule for navigation, backlinks and the rewrite.
@Suite struct WikiLinkResolverTests {
    let tmp: TempPaths
    let db: AppDatabase
    let store: NoteStore
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let t1 = Date(timeIntervalSince1970: 1_800_000_100)
    let t2 = Date(timeIntervalSince1970: 1_800_000_200)

    init() throws {
        tmp = try TempPaths()
        db = try AppDatabase.inMemory()
        store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
    }

    private func resolve(_ link: WikiLinkRef, from source: String = "source") throws -> WikiLinkResolver.Target? {
        try store.resolveWikiLink(link, from: source)
    }

    private func setModifiedAt(_ note: Note, _ date: Date) throws {
        try db.pool.write { try $0.execute(sql: "UPDATE note SET modifiedAt = ? WHERE id = ?", arguments: [date, note.id]) }
    }

    @Test func testCaseInsensitiveAndMostRecentDuplicateWins() throws {
        let older = try store.create(text: "Müller Plan", now: t0)
        let newer = try store.create(text: "MÜLLER plan", now: t1)
        #expect(try resolve(WikiLinkRef(target: "müller plan"))?.noteId == newer.id)
        try setModifiedAt(older, t2)
        #expect(try resolve(WikiLinkRef(target: "Müller Plan"))?.noteId == older.id)
        #expect(try resolve(WikiLinkRef(target: "Muller Plan")) == nil)  // diacritics count
        #expect(try resolve(WikiLinkRef(target: "Absent")) == nil)
    }

    @Test func testTrashExcludedArchiveIncluded() throws {
        let archived = try store.create(text: "Dup", now: t0)
        let trashed = try store.create(text: "Dup", now: t1)
        try store.archive([archived.id])
        try store.trash([trashed.id])
        #expect(try resolve(WikiLinkRef(target: "Dup"))?.noteId == archived.id)
        try store.trash([archived.id])
        #expect(try resolve(WikiLinkRef(target: "Dup")) == nil)
    }

    @Test func testEqualModifiedAtPicksTheLargerId() throws {
        let a = try store.create(text: "Same", now: t0)
        let b = try store.create(text: "Same", now: t0)
        try setModifiedAt(a, t1)
        try setModifiedAt(b, t1)
        #expect(try resolve(WikiLinkRef(target: "Same"))?.noteId == max(a.id, b.id))
    }

    @Test func testNavigationAndRewritePickTheSameDuplicate() throws {
        let older = try store.create(text: "Dup\nolder", now: t0)
        let newer = try store.create(text: "Dup\nnewer", now: t1)
        let trashed = try store.create(text: "Dup\ntrashed", now: t2)
        try store.trash([trashed.id])
        let linker = try store.create(text: "L [[Dup]]", now: t0)

        // Navigation (the click, M3 Task 6) goes to the most recently modified live note.
        let clicked = try store.resolveOrCreateWikiLink(title: "dup", heading: nil, from: linker.id)
        #expect(clicked == WikiLinkTarget(noteId: newer.id, headingIndex: nil, created: false))
        #expect(try resolve(WikiLinkRef(target: "Dup"), from: linker.id)?.noteId == newer.id)

        // The rewrite (M4 Task 7) only follows a rename of that same note.
        for note in [older, trashed] {
            let before = try #require(try store.linkTargetState(id: note.id))
            let current = try #require(try store.note(id: note.id))
            _ = try store.updateText(id: note.id, text: "Renamed \(note.id)", expectedRevision: current.revision, now: t1)
            #expect(!(try store.rewriteWikiLinks(to: note.id, from: before, now: t1)).didChange)
        }
        let before = try #require(try store.linkTargetState(id: clicked.noteId))
        let current = try #require(try store.note(id: clicked.noteId))
        _ = try store.updateText(id: clicked.noteId, text: "Fresh\nnewer", expectedRevision: current.revision, now: t2)
        #expect(try store.rewriteWikiLinks(to: clicked.noteId, from: before, now: t2).changedNoteIds == [linker.id])
        #expect(try store.note(id: linker.id)?.text == "L [[Fresh]]")
    }

    @Test func testOneHeadingMatcherForNavigationRewriteAndBacklinks() throws {
        let note = try store.create(text: "Note\n## Intro\n## a  b\nbody", now: t0)
        let linker = try store.create(text: "L [[Note/a  b]]", now: t0)

        // Navigation: the click (M3 Task 6) and the resolver (M4 Task 7) find the same heading.
        #expect(try store.headingIndex(noteId: note.id, heading: "a  b") == 1)
        #expect(try store.resolveOrCreateWikiLink(title: "Note", heading: "a  b", from: linker.id).headingIndex == 1)
        #expect(try resolve(WikiLinkRef(target: "Note", heading: "a  b"), from: linker.id)
            == .init(noteId: note.id, headingOrdinal: 1))
        #expect(try resolve(WikiLinkRef(target: "Note", heading: " A \t B "), from: linker.id)?.headingOrdinal == 1)
        #expect(try store.headingIndex(noteId: note.id, heading: " A \t B ") == 1)
        // Heading completion (M3 Task 7) offers only headings this matcher finds again.
        #expect(WikiLinkResolver.headingKey("  A \t B ") == WikiLinkResolver.headingKey("a b"))
        #expect(CompletionProvider.isLinkableHeading("a b"))

        // Backlinks list the link as a linked mention of the note.
        #expect(try store.backlinks(to: note.id).linked.map(\.noteId) == [linker.id])

        // The rewrite follows a rename of that heading.
        let before = try #require(try store.linkTargetState(id: note.id))
        let current = try #require(try store.note(id: note.id))
        _ = try store.updateText(id: note.id, text: "Note\n## Intro\n## c  d\nbody", expectedRevision: current.revision, now: t1)
        #expect(try store.rewriteWikiLinks(to: note.id, from: before, now: t1).changedNoteIds == [linker.id])
        let rewritten = try #require(try store.note(id: linker.id)?.text)
        #expect(try resolve(WikiLinkParser.parse(Array(rewritten.unicodeScalars), at: 2)!.ref, from: linker.id)
            == .init(noteId: note.id, headingOrdinal: 1))
    }

    @Test func testHeadingsAndSameNoteLinks() throws {
        let note = try store.create(text: "Note\n## Intro\n## Details\n## intro", now: t0)
        #expect(try resolve(WikiLinkRef(target: "note", heading: "INTRO")) == .init(noteId: note.id, headingOrdinal: 0))
        #expect(try resolve(WikiLinkRef(target: "Note", heading: "Details")) == .init(noteId: note.id, headingOrdinal: 1))
        #expect(try resolve(WikiLinkRef(target: "Note", heading: "Missing")) == .init(noteId: note.id, headingOrdinal: nil))
        #expect(try resolve(WikiLinkRef(target: "", heading: "Details"), from: note.id)
            == .init(noteId: note.id, headingOrdinal: 1))
        #expect(try db.pool.read { try WikiLinkResolver.resolve(titleKey: "", in: $0) } == nil)
    }
}
