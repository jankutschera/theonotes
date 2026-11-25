// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// Wiki-link resolution (spec §3.5, ruling R16), heading targets, Bear note URLs and which URLs may
/// leave the app.
@Suite struct LinkResolutionTests {
    private final class Env {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TheoNotesLinks-\(UUID().uuidString)")
        let store: NoteStore

        init() throws {
            let paths = AppPaths(root: root)
            try paths.createDirectories()
            store = NoteStore(db: try AppDatabase(path: paths.database), notifier: nil, paths: paths)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func note(_ text: String, at seconds: TimeInterval) throws -> String {
            try store.create(text: text, now: Date(timeIntervalSince1970: 1_800_000_000 + seconds)).id
        }
    }

    // MARK: - Titles (R16)

    @Test func titlesMatchByTitleKeyCaseInsensitiveAndUnicodeNormalized() throws {
        let env = try Env()
        let id = try env.note("# My Café Note\nbody", at: 0)
        #expect(try env.store.noteId(forWikiTitle: "My Café Note") == id)
        #expect(try env.store.noteId(forWikiTitle: "my café NOTE") == id)
        // Decomposed é (e + U+0301) is the same title.
        #expect(try env.store.noteId(forWikiTitle: "My Cafe\u{301} Note") == id)
        // Diacritics are kept: "Cafe" is another title.
        #expect(try env.store.noteId(forWikiTitle: "My Cafe Note") == nil)
        #expect(try env.store.noteId(forWikiTitle: "Other") == nil)
    }

    @Test func duplicatesResolveToTheMostRecentlyModifiedTiesToTheLargerId() throws {
        let env = try Env()
        _ = try env.note("Plan", at: 0)
        let newer = try env.note("plan", at: 60)
        _ = try env.note("PLAN", at: 30)
        #expect(try env.store.noteId(forWikiTitle: "Plan") == newer)

        let a = try env.note("Tie", at: 100)
        let b = try env.note("Tie", at: 100)
        #expect(try env.store.noteId(forWikiTitle: "tie") == max(a, b))
    }

    @Test func trashedNotesAreNeverTargetsArchivedNotesAre() throws {
        let env = try Env()
        let notes = try env.note("Kept", at: 0)
        let trashed = try env.note("Kept", at: 50)
        try env.store.trash([trashed])
        #expect(try env.store.noteId(forWikiTitle: "Kept") == notes)

        let archived = try env.note("Archived", at: 0)
        try env.store.archive([archived])
        #expect(try env.store.noteId(forWikiTitle: "Archived") == archived)
    }

    // MARK: - Headings

    @Test func headingTargetsResolveToTheHeadingsIndex() throws {
        let env = try Env()
        let id = try env.note("# Project\n## Goals\ntext\n## Next **Steps**\n### Goals", at: 0)
        let target = try env.store.resolveOrCreateWikiLink(title: "project", heading: "next steps", from: "source")
        #expect(target == WikiLinkTarget(noteId: id, headingIndex: 2, created: false))
        // The first matching heading wins.
        #expect(try env.store.headingIndex(noteId: id, heading: "GOALS") == 1)
        #expect(try env.store.resolveOrCreateWikiLink(title: "Project", heading: "Missing", from: "source").headingIndex == nil)
        #expect(try env.store.resolveOrCreateWikiLink(title: "Project", heading: nil, from: "source").headingIndex == nil)
    }

    @Test func anEmptyTitleIsTheSourceNote() throws {
        let env = try Env()
        let id = try env.note("# Here\n## Part", at: 0)
        #expect(try env.store.resolveOrCreateWikiLink(title: "", heading: "part", from: id) == WikiLinkTarget(noteId: id, headingIndex: 1, created: false))
    }

    // MARK: - Missing targets

    @Test func aMissingTargetCreatesTheNoteOnceWithThatTitle() throws {
        let env = try Env()
        let first = try env.store.resolveOrCreateWikiLink(title: "Brand New", heading: "Section", from: "source")
        #expect(first.created)
        #expect(first.headingIndex == nil)
        let note = try #require(try env.store.note(id: first.noteId))
        #expect(note.text == "# Brand New")
        #expect(note.title == "Brand New")
        // The next click finds it.
        let second = try env.store.resolveOrCreateWikiLink(title: "brand new", heading: nil, from: "source")
        #expect(second == WikiLinkTarget(noteId: first.noteId, headingIndex: nil, created: false))
        #expect(try env.store.allNotes().count == 1)
    }

    /// R31 (M4 final review I2): a note a click creates in a workspace carries the workspace's tag
    /// (under the title, so the title stays the link's), by the rule ⌘N and templates use.
    @Test func aNoteCreatedInAWorkspaceGetsTheWorkspaceTag() throws {
        let env = try Env()
        let founder = Workspace(path: "adhd-founder")
        let target = try env.store.resolveOrCreateWikiLink(title: "Launch plan", heading: nil, from: "source", workspace: founder)
        #expect(target.created)
        let note = try #require(try env.store.note(id: target.noteId))
        #expect(note.text == "# Launch plan\n#adhd-founder")
        #expect(note.title == "Launch plan")
        #expect(target.caretOffset == "# Launch plan".utf16.count, "the caret ends the title line")
        #expect(try env.store.resolveOrCreateWikiLink(title: "launch plan", heading: nil, from: "source", workspace: founder)
            == WikiLinkTarget(noteId: target.noteId, headingIndex: nil, created: false))

        // A multi-word workspace is written closed; a title tag inside the workspace is enough.
        let multi = try env.store.resolveOrCreateWikiLink(
            title: "Kickoff", heading: nil, from: "source", workspace: Workspace(path: "my project"))
        #expect(try env.store.note(id: multi.noteId)?.text == "# Kickoff\n#my project#")
        let tagged = try env.store.resolveOrCreateWikiLink(
            title: "Q3 #adhd-founder/q3", heading: nil, from: "source", workspace: founder)
        #expect(try env.store.note(id: tagged.noteId)?.text == "# Q3 #adhd-founder/q3")

        // An existing note is only found, never tagged; without a workspace nothing is added.
        let plain = try env.store.resolveOrCreateWikiLink(title: "Plain", heading: nil, from: "source")
        #expect(try env.store.note(id: plain.noteId)?.text == "# Plain")
        #expect(plain.caretOffset == "# Plain".utf16.count)
    }

    @Test func newNoteTagTokensFollowOneRule() throws {
        let work = Workspace(path: "work")
        #expect(try NoteStore.newNoteTagTokens(carrying: [], extraTags: [], workspace: nil) == [])
        #expect(try NoteStore.newNoteTagTokens(carrying: [], extraTags: [], workspace: work) == ["#work"])
        #expect(try NoteStore.newNoteTagTokens(carrying: [], extraTags: ["home", "Home"], workspace: work) == ["#home", "#work"])
        #expect(try NoteStore.newNoteTagTokens(carrying: [], extraTags: ["work/p"], workspace: work) == ["#work/p"])
        #expect(try NoteStore.newNoteTagTokens(carrying: ["Work/x"], extraTags: ["home"], workspace: work) == ["#home"])
        #expect(try NoteStore.newNoteTagTokens(carrying: ["home"], extraTags: ["home", "my tag"], workspace: nil) == ["#my tag#"])
        #expect(throws: StoreError.self) { try NoteStore.newNoteTagTokens(carrying: [], extraTags: ["  "], workspace: nil) }
    }

    /// I2: `[[**Plan**]]` creates `# **Plan**`, titled "Plan"; the next click finds that note.
    @Test func creatingAMarkupTitleIsIdempotent() throws {
        let env = try Env()
        let first = try env.store.resolveOrCreateWikiLink(title: "**Plan**", heading: nil, from: "source")
        #expect(first.created)
        #expect(try env.store.note(id: first.noteId)?.title == "Plan")
        let second = try env.store.resolveOrCreateWikiLink(title: "**Plan**", heading: nil, from: "source")
        #expect(second == WikiLinkTarget(noteId: first.noteId, headingIndex: nil, created: false))
        #expect(try env.store.allNotes().count == 1)
        // An existing note titled like the rendered markup is found too.
        let plain = try env.note("Budget", at: 0)
        #expect(try env.store.resolveOrCreateWikiLink(title: "_Budget_", heading: nil, from: "source").noteId == plain)
    }

    /// M3: tombstoned rows (`deletedAt`) are never targets.
    @Test func deletedNotesAreNeverTargets() throws {
        let env = try Env()
        let live = try env.note("Ghost", at: 0)
        let gone = try env.note("Ghost", at: 50)
        try env.store.db.pool.write { db in
            try db.execute(sql: "UPDATE note SET deletedAt = ? WHERE id = ?", arguments: [Date(), gone])
        }
        #expect(try env.store.noteId(forWikiTitle: "Ghost") == live)
    }

    @Test func blankTitlesNeverCreateNotes() throws {
        let env = try Env()
        #expect(throws: StoreError.self) { try env.store.resolveOrCreateWikiLink(title: "  ", heading: nil, from: "") }
        #expect(try env.store.allNotes().isEmpty)
    }

    // MARK: - Bear notes

    @Test func bearNoteIdsMapThroughExternalRefs() throws {
        let env = try Env()
        let id = try env.note("Imported", at: 0)
        try env.store.db.pool.write { db in
            try db.execute(sql: "INSERT INTO external_ref (source, externalId, noteId) VALUES ('bear', 'ABC-1', ?)", arguments: [id])
            try db.execute(sql: "INSERT INTO external_ref (source, externalId, noteId) VALUES ('bear', 'GONE', NULL)")
        }
        #expect(try env.store.noteId(forBearId: "ABC-1") == id)
        #expect(try env.store.noteId(forBearId: "GONE") == nil)
        #expect(try env.store.noteId(forBearId: "nope") == nil)
    }

    // MARK: - URLs

    @Test func onlyWebAndMailURLsLeaveTheApp() throws {
        for raw in ["https://example.com/faq", "http://example.com", "HTTPS://Example.com", "mailto:a@b.c", "  https://x.y/a%20b  "] {
            guard case .openExternally = LinkRouting.action(for: raw) else {
                Issue.record("\(raw) should open externally")
                continue
            }
        }
        for raw in [
            "file:///etc/passwd", "javascript:alert(1)", "ftp://x.y", "data:text/html,hi", "x-apple.systempreferences:x",
            "baerchen://open", "bear://x-callback-url/create?text=hi", "bear://x-callback-url/open-note", "http://", "https:",
            "", "relative.pdf", "vnc://host", "smb://server/share", "ssh://host",
        ] {
            #expect(LinkRouting.action(for: raw) == .ignore, "\(raw)")
        }
        #expect(LinkRouting.action(for: "https://example.com") == .openExternally(URL(string: "https://example.com")!))
    }

    @Test func bearOpenNoteURLsCarryTheBearIdAndARebuiltFallback() {
        #expect(LinkRouting.action(for: "bear://x-callback-url/open-note?id=7E4B-1") == .openBearNote(
            bearId: "7E4B-1", header: nil, fallbackURL: URL(string: "bear://x-callback-url/open-note?id=7E4B-1")!
        ))
        // The header (Bear's "Copy Link to Here") passes as plain text.
        #expect(LinkRouting.action(for: "bear://x-callback-url/open-note?id=a&header=Next%20Steps") == .openBearNote(
            bearId: "a", header: "Next Steps", fallbackURL: URL(string: "bear://x-callback-url/open-note?id=a&header=Next%20Steps")!
        ))
        // Scheme and host case do not matter; the fallback is always the canonical form.
        #expect(LinkRouting.action(for: "BEAR://X-CALLBACK-URL/open-note?id=a") == .openBearNote(
            bearId: "a", header: nil, fallbackURL: URL(string: "bear://x-callback-url/open-note?id=a")!
        ))
        // A percent-encoded id round-trips.
        guard case let .openBearNote(id, _, fallback) = LinkRouting.action(for: "bear://x-callback-url/open-note?id=A%20B%26C%3D1") else {
            Issue.record("encoded id not accepted")
            return
        }
        #expect(id == "A B&C=1")
        let items = URLComponents(url: fallback, resolvingAgainstBaseURL: false)?.queryItems
        #expect(items == [URLQueryItem(name: "id", value: "A B&C=1")])
    }

    /// Security: a Bear URL never carries callbacks or extra parameters out of the app (the fallback
    /// URL goes to NSWorkspace, and Bear would call x-success/x-error/x-cancel back).
    @Test func bearURLsWithCallbacksOrExtraParametersAreIgnored() {
        for raw in [
            "bear://x-callback-url/open-note?id=X&x-success=evil-scheme://run",
            "bear://x-callback-url/open-note?id=X&x-error=evil://e",
            "bear://x-callback-url/open-note?id=X&x-cancel=evil://c",
            "bear://x-callback-url/open-note?x-success=evil://s&id=X",
            "bear://x-callback-url/open-note?id=X&new_window=yes",
            "bear://x-callback-url/open-note?id=X&id=Y",
            "bear://x-callback-url/open-note?id=X&header=a%0Ab",
            "bear://x-callback-url/open-note?id=%00X",
            "bear://x-callback-url/open-note?id=" + String(repeating: "a", count: 129),
            "bear://x-callback-url/open-note?id=",
            "bear://x-callback-url/open-note",
            "bear://x-callback-url/open-note/extra?id=X",
            "bear://user@x-callback-url/open-note?id=X",
            "bear://x-callback-url:99/open-note?id=X",
            "bear://x-callback-url/open-note?id=X#frag",
        ] {
            #expect(LinkRouting.action(for: raw) == .ignore, "\(raw)")
        }
        #expect(LinkRouting.action(for: "bear://x-callback-url/open-note?id=" + String(repeating: "a", count: 128)) != .ignore)
    }

    @Test func schemeChecksAreCaseInsensitive() {
        for raw in ["JavaScript:alert(1)", "FILE:///etc/hosts", "Data:text/html,x", "JAVASCRIPT://x.y/%0Aalert(1)"] {
            #expect(LinkRouting.action(for: raw) == .ignore, "\(raw)")
        }
        #expect(LinkRouting.action(for: "MAILTO:a@b.c") == .openExternally(URL(string: "MAILTO:a@b.c")!))
    }
}
