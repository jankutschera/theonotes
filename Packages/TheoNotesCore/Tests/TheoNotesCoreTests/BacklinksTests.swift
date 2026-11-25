// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import GRDB
import Synchronization
@testable import TheoNotesCore

@Suite struct BacklinksTests {
    let tmp: TempPaths
    let db: AppDatabase
    let store: NoteStore

    init() throws {
        tmp = try TempPaths()
        db = try AppDatabase.inMemory()
        store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
    }

    private func text(_ id: String) throws -> String {
        try #require(try store.note(id: id)).text
    }

    private func update(_ id: String, _ newText: String) throws {
        let note = try #require(try store.note(id: id))
        _ = try store.updateText(id: id, text: newText, expectedRevision: note.revision)
    }

    private func setFlag(_ column: String, _ id: String) throws {
        try db.pool.write { try $0.execute(sql: "UPDATE note SET \(column) = 1 WHERE id = ?", arguments: [id]) }
    }

    private func unlinked(_ backlinks: Backlinks, _ id: String) -> MentioningNote? {
        backlinks.unlinked.first { $0.noteId == id }
    }

    // MARK: - Linked mentions

    @Test func testLinkedMentionsAreNotesLinkingToTheTitle() throws {
        let target = try store.create(text: "Apple Pie\nThe recipe")
        let a = try store.create(text: "Recipes\nI love [[apple pie]] a lot")
        let b = try store.create(text: "Menu\n- [[Apple Pie/Dough|the dough]]")
        _ = try store.create(text: "Other\n[[Apple Pies]] and [[Pie]]")
        let trashed = try store.create(text: "Old\n[[Apple Pie]]")
        try store.trash([trashed.id])
        try update(target.id, "Apple Pie\n[[Apple Pie]] links itself")

        let backlinks = try store.backlinks(to: target.id)
        #expect(Set(backlinks.linked.map(\.noteId)) == [a.id, b.id])
        let aMention = try #require(backlinks.linked.first { $0.noteId == a.id }?.mentions.first)
        #expect(aMention.snippet == "I love apple pie a lot")
        let bMention = try #require(backlinks.linked.first { $0.noteId == b.id }?.mentions.first)
        #expect(bMention.snippet == "the dough")
        #expect(backlinks.linked.first { $0.noteId == a.id }?.title == "Recipes")
    }

    @Test func testDuplicateTitlesResolveToTheMostRecentNoteOutsideTheTrash() throws {
        // R16: a linker is a backlink only of the note its link opens.
        let older = try store.create(text: "Topic\nfirst", now: Date(timeIntervalSince1970: 1_000))
        let newer = try store.create(text: "Topic\nsecond", now: Date(timeIntervalSince1970: 2_000))
        let linker = try store.create(text: "L\nsee [[Topic]]")
        let mentioner = try store.create(text: "M\nabout Topic")
        #expect(try store.backlinks(to: newer.id).linked.map(\.noteId) == [linker.id])
        let olderLinks = try store.backlinks(to: older.id)
        #expect(olderLinks.linked.isEmpty)
        #expect(!olderLinks.canLink)
        let mention = try #require(unlinked(olderLinks, mentioner.id)?.mentions.first)
        #expect(throws: MentionLinkError.resolvesElsewhere) { try store.linkMention(mention, to: older.id) }

        // A trashed duplicate never wins; archived notes do.
        try store.trash([newer.id])
        #expect(try store.backlinks(to: older.id).linked.map(\.noteId) == [linker.id])
        try store.archive([older.id])
        #expect(try store.backlinks(to: older.id).linked.map(\.noteId) == [linker.id])
    }

    @Test func testResolutionTieGoesToTheLargerId() throws {
        let a = try store.create(text: "Same")
        let b = try store.create(text: "Same")
        try db.pool.write { try $0.execute(sql: "UPDATE note SET modifiedAt = ? WHERE id IN (?, ?)", arguments: [Date(timeIntervalSince1970: 5_000), a.id, b.id]) }
        let winner = max(a.id, b.id)
        #expect(try db.pool.read { try NoteStore.resolvedLinkTargetId(key: CanonicalKey.make("Same"), in: $0) } == winner)
        #expect(try db.pool.read { try NoteStore.resolvedLinkTargetId(key: "", in: $0) } == nil)
    }

    @Test func testUntitledNoteHasNoBacklinks() throws {
        let target = try store.create(text: "\nbody")
        _ = try store.create(text: "x\n[[]] body")
        #expect(try store.backlinks(to: target.id) == Backlinks())
    }

    @Test func testLockedLinkingNoteShowsNoSnippet() throws {
        let target = try store.create(text: "Topic")
        let locked = try store.create(text: "Secret\nabout [[Topic]]")
        try setFlag("isLocked", locked.id)
        let note = try #require(try store.backlinks(to: target.id).linked.first)
        #expect(note.noteId == locked.id)
        #expect(note.isLocked)
        #expect(note.mentions.isEmpty)
        #expect(!note.canLink)
    }

    // MARK: - Unlinked mentions

    @Test func testUnlinkedMentionsMatchTheExactTitleAsPlainText() throws {
        let target = try store.create(text: "Apple Pie\nApple Pie again in its own note")
        let plain = try store.create(text: "Dessert\nApple pie is great. More apple PIE!")
        let linker = try store.create(text: "Recipes\n[[Apple Pie]] and apple pie in text")
        _ = try store.create(text: "Fruit\nPineapple pies and apple pied")
        let trashed = try store.create(text: "Old\napple pie")
        try store.trash([trashed.id])
        let archived = try store.create(text: "Archived\napple pie")
        try store.archive([archived.id])

        let backlinks = try store.backlinks(to: target.id)
        #expect(Set(backlinks.unlinked.map(\.noteId)) == [plain.id, archived.id])
        #expect(!backlinks.unlinked.contains { $0.noteId == linker.id })
        let mentions = try #require(unlinked(backlinks, plain.id)).mentions
        #expect(mentions.map(\.line) == [1, 1])
        #expect(mentions.map(\.range) == [0..<9, 25..<34])
        #expect(mentions[0].snippet == "Apple pie is great. More apple PIE!")
        #expect(try #require(unlinked(backlinks, plain.id)).canLink)
        // Archive notes are listed but not editable (spec §4.9).
        #expect(try #require(unlinked(backlinks, archived.id)).canLink == false)
        #expect(backlinks.canLink)
    }

    @Test func testOccurrencesInCodeLinksTagsMathCommentsAndFrontMatterAreSkipped() throws {
        let target = try store.create(text: "Topic")
        let source = try store.create(text: """
            ---
            title: Topic
            ---
            Notes
            `Topic` and $Topic$ and <!-- Topic --> and [Topic](https://x.y/Topic)
            [[Topic Two]] #Topic #Topic and more# https://example.com/Topic
            ```
            Topic
            ```
            $$
            Topic
            $$
            ![Topic](Topic.png) <https://Topic.com>
            The Topic here.
            """)
        let note = try #require(unlinked(try store.backlinks(to: target.id), source.id))
        #expect(note.mentions.count == 1)
        #expect(note.mentions.first?.line == 13)
        #expect(note.mentions.first?.range == 4..<9)
    }

    @Test func testMatchingIsCaseInsensitiveButDiacriticSensitive() throws {
        let target = try store.create(text: "Café")
        let exact = try store.create(text: "x\nat the CAFÉ today")
        let plain = try store.create(text: "y\nat the cafe today")
        let backlinks = try store.backlinks(to: target.id)
        #expect(unlinked(backlinks, exact.id) != nil)
        #expect(unlinked(backlinks, plain.id) == nil)
    }

    @Test func testCJKTitlesMatchWithoutWordBoundaries() throws {
        let target = try store.create(text: "日本語")
        let source = try store.create(text: "メモ\nこれは日本語です")
        let note = try #require(unlinked(try store.backlinks(to: target.id), source.id))
        #expect(note.mentions.first?.range == 3..<6)
    }

    @Test func testFTSSyntaxInTheTitleIsLiteral() throws {
        // Review Focus #1: FTS syntax characters never reach MATCH unquoted.
        for title in ["\"NEAR\" (x) -y*", "a:b AND c", "OR", "*", "\"", "-"] {
            let target = try store.create(text: title)
            let source = try store.create(text: "note\nsee \(title) here")
            let backlinks = try store.backlinks(to: target.id)
            #expect(backlinks.unlinked.map(\.noteId).contains(source.id) || !title.contains(where: \.isLetter),
                    "title \(title)")
        }
    }

    @Test func testLockedNotesAreNotSearchedAndReadOnlyNotesCannotLink() throws {
        let target = try store.create(text: "Topic")
        let locked = try store.create(text: "x\nTopic")
        try setFlag("isLocked", locked.id)
        let readOnly = try store.create(text: "y\nTopic")
        try setFlag("isReadOnly", readOnly.id)
        let backlinks = try store.backlinks(to: target.id)
        #expect(unlinked(backlinks, locked.id) == nil)
        #expect(try #require(unlinked(backlinks, readOnly.id)).canLink == false)
    }

    @Test func testUnlinkableTitles() throws {
        for title in ["a|b", "a [b]"] {
            let target = try store.create(text: title)
            #expect(try store.backlinks(to: target.id).canLink == false, "title \(title)")
        }
        for title in ["A/B", "back\\", "A  B"] {
            let target = try store.create(text: title)
            #expect(try store.backlinks(to: target.id).canLink, "title \(title)")
        }
    }

    @Test func testLongLinesAreCutAroundTheMention() throws {
        let before = String(repeating: "word ", count: 40)
        let after = String(repeating: " more", count: 40)
        let snippet = NoteStore.snippet(before + "Topic" + after, around: "topic")
        #expect(snippet.hasPrefix("…word "))
        #expect(snippet.hasSuffix("more…"))
        #expect(snippet.contains("Topic"))
        #expect(snippet.count <= Backlinks.snippetLength + 2)
        #expect(NoteStore.snippet("short Topic", around: "topic") == "short Topic")
        // No match: the line's beginning.
        #expect(NoteStore.snippet(before, around: "absent").hasPrefix("word word"))
    }

    @Test func testNoteWritesAreObserved() async throws {
        let count = Mutex(0)
        let token = store.observeNoteWrites(onError: { _ in }) { count.withLock { $0 += 1 } }
        _ = try store.create(text: "one")
        let deadline = ContinuousClock.now + .seconds(2)
        while count.withLock({ $0 }) == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(count.withLock { $0 } >= 1)
        token.cancel()
        let seen = count.withLock { $0 }
        _ = try store.create(text: "two")
        try await Task.sleep(for: .milliseconds(50))
        #expect(count.withLock { $0 } == seen)
    }

    @Test func testUnlinkedMentionsPageThroughCandidatesThatDoNotVerify() throws {
        // 500 newer notes only carry the title as a tag: FTS finds them, verification drops them;
        // the older prose mentions behind them are still found (no silent truncation).
        let target = try store.create(text: "Topic", now: Date(timeIntervalSince1970: 1))
        var prose: [String] = []
        for i in 0..<3 {
            prose.append(try store.create(text: "Old \(i)\nabout Topic", now: Date(timeIntervalSince1970: Double(10 + i))).id)
        }
        try db.pool.write { db in
            for i in 0..<500 {
                let id = "tag-\(i)", text = "Tagged \(i)\n#topic"
                let date = Date(timeIntervalSince1970: Double(1_000 + i))
                try db.execute(sql: "INSERT INTO note (id, text, createdAt, modifiedAt) VALUES (?, ?, ?, ?)", arguments: [id, text, date, date])
                try NoteIndexer.index(noteId: id, text: text, in: db)
            }
        }
        let backlinks = try store.backlinks(to: target.id)
        #expect(Set(backlinks.unlinked.map(\.noteId)) == Set(prose))
        #expect(!backlinks.unlinkedTruncated)
    }

    @Test func testUnlinkedMentionsStopAtTheLimitAndSaySo() throws {
        let target = try store.create(text: "Topic")
        for i in 0..<12 { _ = try store.create(text: "N\(i)\nTopic and Topic") }
        let backlinks = try store.backlinks(to: target.id, unlinkedLimit: 10)
        #expect(backlinks.unlinked.flatMap(\.mentions).count == 10)
        #expect(backlinks.unlinkedTruncated)
        let all = try store.backlinks(to: target.id, unlinkedLimit: 24)
        #expect(all.unlinked.flatMap(\.mentions).count == 24)
        #expect(!all.unlinkedTruncated)
    }

    @Test func testLinkedMentionsSayWhenTruncated() throws {
        let target = try store.create(text: "Topic", now: Date(timeIntervalSince1970: 9_999_999))
        for i in 0..<3 { _ = try store.create(text: "L\(i)\n[[Topic]]") }
        #expect(try store.backlinks(to: target.id, linkedLimit: 2).linkedTruncated)
        #expect(try store.backlinks(to: target.id, linkedLimit: 2).linked.count == 2)
        #expect(!(try store.backlinks(to: target.id).linkedTruncated))
    }

    @Test func testLineEndingsAreNormalizedBeforeScanning() throws {
        let target = try store.create(text: "Topic")
        let source = try store.create(text: "x")
        // CRLF and a lone CR, written raw (writeText would normalize them).
        try db.pool.write { db in
            let text = "x\r\nabout Topic\rmore Topic"
            try db.execute(sql: "UPDATE note SET text = ? WHERE id = ?", arguments: [text, source.id])
            try NoteIndexer.index(noteId: source.id, text: text, in: db)
        }
        let mentions = try #require(unlinked(try store.backlinks(to: target.id), source.id)).mentions
        #expect(mentions.map(\.line) == [1, 2])
        _ = try store.linkMention(try #require(mentions.last), to: target.id)
        #expect(try text(source.id) == "x\nabout Topic\nmore [[Topic]]")
    }

    @Test func testARejectedMatchDoesNotHideAnOverlappingOccurrence() throws {
        let target = try store.create(text: "ab ab")
        let source = try store.create(text: "x\nxab ab ab")
        let note = try #require(unlinked(try store.backlinks(to: target.id), source.id))
        #expect(note.mentions.map(\.range) == [4..<9])
    }

    @Test func testSingleWordTitlesNextToCJKAreFound() throws {
        // The word index tokenizes `Appleの新製品` as one token; candidates come from substrings.
        let target = try store.create(text: "Apple")
        let source = try store.create(text: "メモ\nAppleの新製品")
        let note = try #require(unlinked(try store.backlinks(to: target.id), source.id))
        #expect(note.mentions.first?.range == 0..<5)
    }

    @Test func testLinkingANoteToItselfIsRefusedAsSuch() throws {
        let target = try store.create(text: "Topic\nTopic again")
        let mention = Mention(noteId: target.id, line: 1, range: 0..<5, snippet: "")
        #expect(throws: MentionLinkError.sameNote) { try store.linkMention(mention, to: target.id) }
    }

    @Test func testTheBackgroundReadMatchesTheSynchronousOne() async throws {
        let target = try store.create(text: "Topic")
        let source = try store.create(text: "x\nabout Topic")
        _ = try store.create(text: "y\n[[Topic]]")
        let background = try await store.backlinksInBackground(to: target.id)
        #expect(background.unlinked.map(\.noteId) == [source.id])
        #expect(background == (try store.backlinks(to: target.id)))
    }

    // MARK: - Linking a mention

    @Test func testLinkRewritesOnlyThatOccurrence() throws {
        let target = try store.create(text: "Apple Pie")
        let source = try store.create(text: "Dessert\nApple pie is great. More apple PIE!")
        let mention = try #require(unlinked(try store.backlinks(to: target.id), source.id)?.mentions.last)

        let result = try store.linkMention(mention, to: target.id)
        #expect(result.changedNoteIds == [source.id])
        #expect(try text(source.id) == "Dessert\nApple pie is great. More [[Apple Pie]]!")
        #expect(result.previousTexts[source.id] == "Dessert\nApple pie is great. More apple PIE!")
        // The note is now a linked mention and the index knows the link.
        let after = try store.backlinks(to: target.id)
        #expect(after.linked.map(\.noteId) == [source.id])
        #expect(after.unlinked.isEmpty)

        #expect(try store.undoLinkRewrite(result) == [source.id])
        #expect(try text(source.id) == "Dessert\nApple pie is great. More apple PIE!")
        #expect(try store.redoLinkRewrite(result) == [source.id])
        #expect(try text(source.id) == "Dessert\nApple pie is great. More [[Apple Pie]]!")
    }

    @Test func testLinkEscapesSlashesInTheTitle() throws {
        let target = try store.create(text: "A/B")
        let source = try store.create(text: "x\nsee A/B now")
        let mention = try #require(unlinked(try store.backlinks(to: target.id), source.id)?.mentions.first)
        _ = try store.linkMention(mention, to: target.id)
        #expect(try text(source.id) == "x\nsee [[A\\/B]] now")
        #expect(try store.backlinks(to: target.id).linked.map(\.noteId) == [source.id])
    }

    @Test func testLinkKeepsAByteOrderMarkAndCRLFLinesIntact() throws {
        let target = try store.create(text: "Topic")
        let source = try store.create(text: "\u{FEFF}Topic first\r\nsecond")
        let mention = try #require(unlinked(try store.backlinks(to: target.id), source.id)?.mentions.first)
        #expect(mention.line == 0)
        #expect(mention.range == 0..<5)
        _ = try store.linkMention(mention, to: target.id)
        #expect(try text(source.id) == "\u{FEFF}[[Topic]] first\nsecond")
    }

    @Test func testLinkRefusesAStaleMention() throws {
        let target = try store.create(text: "Topic")
        let source = try store.create(text: "x\nabout Topic")
        let mention = try #require(unlinked(try store.backlinks(to: target.id), source.id)?.mentions.first)
        try update(source.id, "x\nabout the Topic")
        #expect(throws: MentionLinkError.stale) { try store.linkMention(mention, to: target.id) }
        #expect(try text(source.id) == "x\nabout the Topic")
    }

    @Test func testLinkRefusesLockedReadOnlyAndArchivedNotes() throws {
        let target = try store.create(text: "Topic")
        let source = try store.create(text: "x\nabout Topic")
        let mention = try #require(unlinked(try store.backlinks(to: target.id), source.id)?.mentions.first)
        try setFlag("isReadOnly", source.id)
        #expect(throws: MentionLinkError.notEditable) { try store.linkMention(mention, to: target.id) }
        try db.pool.write { try $0.execute(sql: "UPDATE note SET isReadOnly = 0, isLocked = 1 WHERE id = ?", arguments: [source.id]) }
        #expect(throws: MentionLinkError.notEditable) { try store.linkMention(mention, to: target.id) }
        try db.pool.write { try $0.execute(sql: "UPDATE note SET isLocked = 0 WHERE id = ?", arguments: [source.id]) }
        try store.archive([source.id])
        #expect(throws: MentionLinkError.notEditable) { try store.linkMention(mention, to: target.id) }
        #expect(try text(source.id) == "x\nabout Topic")
    }

    @Test func testLinkRefusesAnUnlinkableTitle() throws {
        let target = try store.create(text: "a|b")
        let source = try store.create(text: "x\nsee a|b")
        let mention = Mention(noteId: source.id, line: 1, range: 4..<7, snippet: "")
        #expect(throws: MentionLinkError.titleNotLinkable) { try store.linkMention(mention, to: target.id) }
    }
}
