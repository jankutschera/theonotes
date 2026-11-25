// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import GRDB
@testable import TheoNotesCore

/// Fix B1 (ruling R38): a title's whitespace runs are kept in `title`, but a link target and a title
/// are the same key once runs are collapsed and the ends trimmed (`TitleKey`), so a note titled
/// `Big    Title` is the target of `[[Big Title]]` and `[[Big    Title]]`.
@Suite struct WikiLinkWhitespaceTests {
    let tmp: TempPaths
    let db: AppDatabase
    let store: NoteStore

    init() throws {
        tmp = try TempPaths()
        db = try AppDatabase.inMemory()
        store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
    }

    /// The first wiki link of `text`, as the indexer sees it.
    private func link(_ text: String) throws -> WikiLinkRef {
        try #require(NoteParser.metadata(for: text).wikiLinks.first)
    }

    @Test func titleKeyCollapsesRunsTrimsAndFoldsCase() {
        let key = TitleKey.make("Big Title")
        for spelling in ["Big    Title", "  big\ttitle ", "BIG\u{00A0}\u{2003}TITLE", "Big\nTitle"] {
            #expect(TitleKey.make(spelling) == key, "\(spelling.debugDescription)")
        }
        #expect(TitleKey.make("BigTitle") != key)
        #expect(TitleKey.make("A\u{308}  b") == TitleKey.make("\u{C4} b"))
        #expect(TitleKey.make(" \t ") == "")
    }

    @Test func theIndexerStoresTheCollapsedKeyAndKeepsTheTitle() throws {
        let note = try store.create(text: "# Big    Title\nbody")
        let stored = try #require(try store.note(id: note.id))
        #expect(stored.title == "Big    Title")
        #expect(stored.titleKey == "big title")
    }

    @Test func everySpellingOfALinkResolvesToATitleWithARun() throws {
        let note = try store.create(text: "# Big    Title\nbody")
        for target in ["Big    Title", "Big Title", "big\ttitle", " BIG TITLE "] {
            #expect(try store.resolveWikiLink(WikiLinkRef(target: target), from: "elsewhere")?.noteId == note.id, "\(target.debugDescription)")
            #expect(try store.noteId(forWikiTitle: target) == note.id)
        }
        // Parsed from text, as a click does.
        for written in ["[[Big    Title]]", "[[Big Title]]", "[[big \t title]]"] {
            let ref = try link("see \(written)")
            #expect(try store.resolveWikiLink(ref, from: "elsewhere")?.noteId == note.id, "\(written)")
        }
        #expect(try store.noteId(forWikiTitle: "Big Titles") == nil)
    }

    @Test func aTitleWithoutARunResolvesFromALinkWithOne() throws {
        let note = try store.create(text: "# Big Title\nbody")
        #expect(try store.resolveWikiLink(try link("[[Big    Title]]"), from: "elsewhere")?.noteId == note.id)
    }

    @Test func aHeadingOfATitleWithARunResolves() throws {
        let note = try store.create(text: "# Big    Title\n\n## Part   one\n\n## Part two")
        for written in ["[[Big    Title/Part   one]]", "[[Big Title/Part one]]"] {
            let target = try #require(try store.resolveWikiLink(try link(written), from: "elsewhere"))
            #expect(target.noteId == note.id && target.headingOrdinal == 1, "\(written)")
        }
    }

    @Test func linkedMentionsAndTheAtBacklinksSearchFindATitleWithARun() throws {
        let target = try store.create(text: "# Big    Title\nbody")
        let spaced = try store.create(text: "A\nsee [[Big    Title]]")
        let single = try store.create(text: "B\nsee [[big title/Heading]]")
        _ = try store.create(text: "C\nsee [[Big Titles]]")
        let backlinks = try store.backlinks(to: target.id)
        #expect(Set(backlinks.linked.map(\.noteId)) == [spaced.id, single.id])
        #expect(backlinks.linked.allSatisfy { $0.mentions.count == 1 })
        #expect(backlinks.canLink)
        let hits = try db.pool.read {
            try LibraryQueries.search("@backlinks", in: .notes, sort: .modifiedDescending, now: .now, calendar: .current,
                                      locale: .current, limit: nil, db: $0)
        }
        #expect(hits.items.map(\.id) == [target.id])
    }

    @Test func plainTextMentionsOfATitleWithARunAreStillFound() throws {
        let target = try store.create(text: "# Big    Title\nbody")
        let mention = try store.create(text: "D\nthe Big    Title is here")
        #expect(try store.backlinks(to: target.id).unlinked.map(\.noteId) == [mention.id])
    }

    @Test func renamingANoteWithARunRewritesItsLinks() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let target = try store.create(text: "# Big    Title\nbody", now: t0)
        let source = try store.create(text: "S\nsee [[Big    Title]] and [[big title/Part]]", now: t0)
        let before = try #require(try store.linkTargetState(id: target.id))
        let current = try #require(try store.note(id: target.id))
        _ = try store.updateText(id: target.id, text: "# Renamed\nbody", expectedRevision: current.revision, now: t0.addingTimeInterval(10))
        let result = try store.rewriteWikiLinks(to: target.id, from: before, now: t0.addingTimeInterval(20))
        #expect(result.changedNoteIds == [source.id])
        #expect(try #require(try store.note(id: source.id)).text == "S\nsee [[Renamed]] and [[Renamed/Part]]")
    }
}
