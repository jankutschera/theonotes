// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import GRDB
@testable import TheoNotesCore

/// Workspaces (spec §3.5, inventory §2.1): a tag predicate applied to every list, count, the
/// sidebar tag tree and search; recently used workspaces in the `workspace` table (last 5).
@Suite struct WorkspaceTests {
    let tmp: TempPaths
    let db: AppDatabase
    let store: NoteStore
    let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Helsinki")!
        return c
    }()
    let now = Date(timeIntervalSince1970: 1_792_670_400)
    let work = Workspace(path: "work")

    init() throws {
        tmp = try TempPaths()
        db = try AppDatabase.inMemory()
        store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
    }

    /// Work A (#work), Work proj (#work/projects #home, open todo), Workshop, Home, Plain, Ideas
    /// (#ideas, pinned root tag), Work archived, Work trashed, Home archived.
    @discardableResult
    private func seedLibrary() throws -> [String: String] {
        var ids: [String: String] = [:]
        let texts: [(String, String)] = [
            ("workA", "Work A\n\n#work"),
            ("proj", "Work proj\n\n- [ ] ship it\n\n#work/projects #home"),
            ("workshop", "Workshop\n\n#workshop"),
            ("home", "Home\n\n#home"),
            ("plain", "Plain"),
            ("ideas", "Ideas\n\n#ideas"),
            ("workArchived", "Work archived\n\n#work"),
            ("workTrashed", "Work trashed\n\n#Work"),
            ("homeArchived", "Home archived\n\n#home"),
        ]
        for (offset, (key, text)) in texts.enumerated() {
            ids[key] = try store.create(text: text, now: now.addingTimeInterval(-Double(offset))).id
        }
        try store.archive([ids["workArchived"]!, ids["homeArchived"]!])
        try store.trash([ids["workTrashed"]!])
        try store.setTagPinned("ideas", pinned: true)
        return ids
    }

    private func titles(_ scope: SidebarScope, _ workspace: Workspace?) throws -> [String] {
        try db.pool.read {
            try LibraryQueries.notes(in: scope, sort: .modifiedDescending, workspace: workspace, now: now, calendar: calendar, db: $0)
        }.map(\.title)
    }

    private func search(_ query: String, _ scope: SidebarScope = .notes, _ workspace: Workspace?, limit: Int? = nil) throws -> [String] {
        try db.pool.read {
            try LibraryQueries.search(query, in: scope, sort: .modifiedDescending, workspace: workspace, now: now,
                                      calendar: calendar, locale: Locale(identifier: "en_US"), limit: limit, db: $0)
        }.items.map(\.title)
    }

    private func paths(_ nodes: [TagNode]) -> [String] {
        nodes.flatMap { [$0.path] + paths($0.children) }
    }

    // MARK: lists

    @Test func testNotesListHasOnlyNotesWithTheTagOrADescendant() throws {
        try seedLibrary()
        #expect(try titles(.notes, work) == ["Work A", "Work proj"])
        #expect(try titles(.notes, Workspace(path: "WORK")) == ["Work A", "Work proj"])
        #expect(try titles(.notes, Workspace(path: "work/projects")) == ["Work proj"])
        #expect(try titles(.notes, nil).count == 6)
    }

    @Test func testArchiveTrashAndSectionsAreFiltered() throws {
        try seedLibrary()
        #expect(try titles(.archive, work) == ["Work archived"])
        #expect(try titles(.trash, work) == ["Work trashed"])
        #expect(try titles(.todo, work) == ["Work proj"])
        #expect(try titles(.today, work) == ["Work A", "Work proj"])
        #expect(try titles(.untagged, work).isEmpty)
        #expect(try titles(.tag("home"), work) == ["Work proj"])
        #expect(try titles(.archive, Workspace(path: "home")) == ["Home archived"])
    }

    @Test func testPinnedSectionIsFiltered() throws {
        let ids = try seedLibrary()
        try store.setPinned([ids["home"]!, ids["workA"]!], pinned: true)
        #expect(try titles(.pinned, work) == ["Work A"])
        let counts = try db.pool.read { try LibraryQueries.counts(workspace: work, now: now, calendar: calendar, db: $0) }
        #expect(counts.pinned == 1)
    }

    @Test func testCountsAreWithinTheWorkspace() throws {
        try seedLibrary()
        let counts = try db.pool.read { try LibraryQueries.counts(workspace: work, now: now, calendar: calendar, db: $0) }
        #expect(counts == SidebarCounts(notes: 2, pinned: 0, untagged: 0, todo: 1, today: 2, locked: 0, archive: 1, trash: 1, inbox: 2))
        let all = try db.pool.read { try LibraryQueries.counts(now: now, calendar: calendar, db: $0) }
        #expect(all.notes == 6)
        #expect(all.archive == 2)
    }

    @Test func testTagTreeShowsOnlyTagsOfWorkspaceNotes() throws {
        try seedLibrary()
        let tree = try db.pool.read { try LibraryQueries.tagTree(workspace: work, db: $0) }
        // No `workshop` (prefix only), no pinned `ideas` (not in a workspace note).
        #expect(paths(tree) == ["home", "work", "work/projects"])
        #expect(tree.map(\.noteCount) == [1, 2])
        #expect(tree[1].children.map(\.noteCount) == [1])
        let full = try db.pool.read { try LibraryQueries.tagTree(db: $0) }
        #expect(paths(full) == ["home", "ideas", "work", "work/projects", "workshop"])
    }

    @Test func testWorkspaceOfAMissingTagIsEmpty() throws {
        try seedLibrary()
        let gone = Workspace(path: "nothing")
        #expect(try titles(.notes, gone).isEmpty)
        #expect(try titles(.trash, gone).isEmpty)
        #expect(try db.pool.read { try LibraryQueries.tagTree(workspace: gone, db: $0) }.isEmpty)
        #expect(try db.pool.read { try LibraryQueries.counts(workspace: gone, now: now, calendar: calendar, db: $0) } == SidebarCounts())
        #expect(try db.pool.read { try gone.exists(db: $0) } == false)
        #expect(try db.pool.read { try work.exists(db: $0) })
    }

    @Test func testWorkspacePathIsBoundNotConcatenated() throws {
        try seedLibrary()
        let hostile = Workspace(path: "work') OR 1=1 --")
        #expect(try titles(.notes, hostile).isEmpty)
        #expect(try search("work", .notes, hostile).isEmpty)
    }

    @Test func testContainsNote() throws {
        let ids = try seedLibrary()
        let contains = { (id: String) in try db.pool.read { try work.contains(noteId: id, db: $0) } }
        #expect(try contains(ids["proj"]!))
        #expect(try contains(ids["workTrashed"]!))
        #expect(try contains(ids["workshop"]!) == false)
        #expect(try contains("missing") == false)
    }

    // MARK: search

    @Test func testSearchIsWithinTheWorkspace() throws {
        try seedLibrary()
        #expect(try search("work", .notes, work) == ["Work A", "Work proj"])
        #expect(try search("home", .notes, work) == ["Work proj"])
        #expect(try search("#home", .notes, work) == ["Work proj"])
        #expect(try search("archived", .archive, work) == ["Work archived"])
        #expect(try search("work", .trash, work) == ["Work trashed"])
        #expect(try search("@todo", .notes, work, limit: 1) == ["Work proj"])
        #expect(try search("home", .notes, nil) == ["Work proj", "Home"])
    }

    // MARK: snapshot

    @Test func testSnapshotAppliesTheWorkspaceEverywhere() throws {
        try seedLibrary()
        let snapshot = try db.pool.read { try LibraryQueries.snapshot(scope: .notes, workspace: work, now: now, calendar: calendar, db: $0) }
        #expect(snapshot.items.map(\.title) == ["Work A", "Work proj"])
        #expect(paths(snapshot.tagTree) == ["home", "work", "work/projects"])
        #expect(snapshot.counts.notes == 2)
        #expect(snapshot.workspaceExists)
        // The switcher lists every pinned root tag, whatever the workspace.
        #expect(snapshot.workspaceChoices.pinned == [Workspace(path: "ideas")])
        let gone = try db.pool.read { try LibraryQueries.snapshot(scope: .notes, workspace: Workspace(path: "gone"), now: now, calendar: calendar, db: $0) }
        #expect(!gone.workspaceExists)
        let none = try db.pool.read { try LibraryQueries.snapshot(scope: .notes, now: now, calendar: calendar, db: $0) }
        #expect(none.workspaceExists)
    }

    @MainActor
    @Test func testObservationFollowsTheWorkspace() async throws {
        try seedLibrary()
        var received: [LibrarySnapshot] = []
        let fixedNow = now
        let token = LibraryQueries.observeSnapshot(
            scope: .notes, workspace: work, database: db, calendar: calendar, now: { fixedNow },
            onError: { Issue.record("observation failed: \($0)") },
            onChange: { received.append($0) }
        )
        defer { token.cancel() }
        #expect(received.last?.items.map(\.title) == ["Work A", "Work proj"])
        _ = try store.create(text: "Elsewhere #home", now: now.addingTimeInterval(1))
        _ = try store.create(text: "More #work/x", now: now.addingTimeInterval(2))
        let deadline = ContinuousClock.now + .seconds(2)
        while received.last?.items.count != 3, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(received.last?.items.map(\.title) == ["More #work/x", "Work A", "Work proj"])
    }

    // MARK: recents

    @Test func testRecentsKeepTheLastFiveNewestFirst() throws {
        for (i, tag) in ["a", "b", "c", "d", "e", "f"].enumerated() {
            _ = try store.create(text: "Note #\(tag)")
            try store.recordWorkspaceUse(Workspace(path: tag), now: now.addingTimeInterval(Double(i)))
        }
        #expect(try db.pool.read { try Workspace.recent(db: $0) }.map(\.path) == ["f", "e", "d", "c", "b"])
        #expect(try db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM workspace") } == 5)

        // Using one again moves it to the front and takes the spelling used.
        try store.recordWorkspaceUse(Workspace(path: "C"), now: now.addingTimeInterval(10))
        #expect(try db.pool.read { try Workspace.recent(db: $0) }.map(\.path) == ["C", "f", "e", "d", "b"])
    }

    @Test func testRecentsSkipTagsThatNoLongerExist() throws {
        let gone = try store.create(text: "Gone #gone")
        _ = try store.create(text: "Kept #kept")
        try store.recordWorkspaceUse(Workspace(path: "gone"), now: now)
        try store.recordWorkspaceUse(Workspace(path: "kept"), now: now.addingTimeInterval(1))
        try store.deletePermanently([gone.id])
        #expect(try db.pool.read { try Workspace.recent(db: $0) }.map(\.path) == ["kept"])
        let snapshot = try db.pool.read { try LibraryQueries.snapshot(scope: .notes, now: now, calendar: calendar, db: $0) }
        #expect(snapshot.workspaceChoices.recent == [Workspace(path: "kept")])
    }

    private func recent() throws -> [String] {
        try db.pool.read { try Workspace.recent(db: $0) }.map(\.path)
    }

    /// Final fix wave (T8 carry 1): the trim keeps five live workspaces; a row whose tag is gone
    /// does not take a live one's place (it stays while it is newer than the fifth live one, so it
    /// can come back with its tag).
    @Test func testTrimIgnoresWorkspacesWhoseTagIsGone() throws {
        var notes: [String: String] = [:]
        for tag in ["a", "b", "c", "d", "e", "f", "g", "h"] { notes[tag] = try store.create(text: "Note #\(tag)").id }
        for (i, tag) in ["c", "d", "e", "a", "b"].enumerated() {
            try store.recordWorkspaceUse(Workspace(path: tag), now: now.addingTimeInterval(Double(i)))
        }
        try store.deletePermanently([notes["a"]!, notes["b"]!])
        try store.recordWorkspaceUse(Workspace(path: "f"), now: now.addingTimeInterval(10))
        #expect(try recent() == ["f", "e", "d", "c"], "c is not evicted by the gone a and b")
        // a comes back with its tag.
        _ = try store.create(text: "Again #a")
        #expect(try recent() == ["f", "a", "e", "d", "c"])
        // Five live ones newer than a row: it goes, gone tag or not.
        try store.recordWorkspaceUse(Workspace(path: "g"), now: now.addingTimeInterval(11))
        try store.recordWorkspaceUse(Workspace(path: "h"), now: now.addingTimeInterval(12))
        #expect(try recent() == ["h", "g", "f", "a", "e"])
        let kept = try db.pool.read { try String.fetchAll($0, sql: "SELECT pathKey FROM workspace ORDER BY pathKey") }
        #expect(kept == ["a", "b", "e", "f", "g", "h"], "b (gone) is newer than the fifth live one, d and c are not")
    }

    /// Final fix wave (T8 carry 1): renaming a tag moves its recent workspaces (descendants too,
    /// merging onto an existing one); undo moves them back. Deleting a tag keeps the row, so the
    /// workspace is recent again after an undo.
    @Test func testRenameMovesRecentWorkspacesAndUndoRestoresThem() throws {
        _ = try store.create(text: "A #work #work/projects")
        _ = try store.create(text: "B #home")
        try store.recordWorkspaceUse(Workspace(path: "Work"), now: now)
        try store.recordWorkspaceUse(Workspace(path: "work/projects"), now: now.addingTimeInterval(1))
        try store.recordWorkspaceUse(Workspace(path: "home"), now: now.addingTimeInterval(2))

        let renamed = try store.renameTag("work", to: "job")
        #expect(try recent() == ["home", "job/projects", "job"])
        try store.undoTagRewrite(renamed)
        #expect(try recent() == ["home", "work/projects", "Work"])

        let merged = try store.renameTag("work", to: "home")
        #expect(try recent() == ["home", "home/projects"])
        try store.undoTagRewrite(merged)
        #expect(try recent() == ["home", "work/projects", "Work"])

        let deleted = try store.deleteTag("work")
        #expect(try recent() == ["home"])
        try store.undoTagRewrite(deleted)
        #expect(try recent() == ["home", "work/projects", "Work"])
    }

    /// Final fix wave (T8 carry 8): a multi-word workspace (`#my tag#`) narrows like any other.
    @Test func testMultiWordWorkspace() throws {
        _ = try store.create(text: "Inside\n\n#my tag# #other", now: now)
        _ = try store.create(text: "Nested\n\n#my tag/sub part#", now: now.addingTimeInterval(-1))
        _ = try store.create(text: "Outside\n\n#my", now: now.addingTimeInterval(-2))
        let multi = Workspace(path: "My Tag")
        #expect(try titles(.notes, multi) == ["Inside", "Nested"])
        #expect(try search("inside OR nested OR outside", .notes, multi) == ["Inside", "Nested"])
        let tree = try db.pool.read { try LibraryQueries.tagTree(workspace: multi, db: $0) }
        #expect(paths(tree).sorted() == ["my tag", "my tag/sub part", "other"])
        #expect(try db.pool.read { try LibraryQueries.counts(workspace: multi, now: now, calendar: calendar, db: $0) }.notes == 2)
        #expect(try NoteStore.newNoteTagTokens(carrying: [], extraTags: [], workspace: multi) == ["#My Tag#"])
    }

    /// Final fix wave (T8 carry 8): a locked note carrying the tag stays in the workspace (its tag
    /// rows stay while locked), in its Locked section and its counts.
    @Test func testLockedNoteInAWorkspace() throws {
        let locked = try store.create(text: "Secret\n\nbody words\n\n#work", now: now)
        _ = try store.create(text: "Open\n\nbody words\n\n#work", now: now.addingTimeInterval(-1))
        _ = try store.create(text: "Other\n\nbody words\n\n#home", now: now.addingTimeInterval(-2))
        try db.pool.write { try $0.execute(sql: "UPDATE note SET isLocked = 1 WHERE id = ?", arguments: [locked.id]) }
        #expect(try titles(.notes, work) == ["Secret", "Open"])
        #expect(try titles(.locked, work) == ["Secret"])
        #expect(try titles(.locked, Workspace(path: "home")).isEmpty)
        let counts = try db.pool.read { try LibraryQueries.counts(workspace: work, now: now, calendar: calendar, db: $0) }
        #expect(counts.locked == 1)
        #expect(counts.notes == 2)
        #expect(try db.pool.read { try work.contains(noteId: locked.id, db: $0) })
    }

    @Test func testWorkspaceKeyIsCanonical() {
        #expect(Workspace(path: "Work") == Workspace(path: "work"))
        #expect(Workspace(path: "Work").path == "Work")
        #expect(Workspace(path: "work/Projects").key == "work/projects")
        #expect(Workspace(path: "work").includes(tagPath: "Work/Projects"))
        #expect(Workspace(path: "work").includes(tagPath: "work"))
        #expect(!Workspace(path: "work").includes(tagPath: "workshop"))
    }
}
