// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import GRDB
@testable import TheoNotesCore

@Suite struct LibraryQueriesTests {
    let tmp: TempPaths
    let db: AppDatabase
    let store: NoteStore
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Helsinki")!
        return c
    }()
    /// 2026-10-22 12:00 Helsinki (UTC+3) -> local midnight is 2026-10-21T21:00:00Z.
    let now = Date(timeIntervalSince1970: 1_792_670_400)
    var midnight: Date { calendar.startOfDay(for: now) }

    init() throws {
        tmp = try TempPaths()
        db = try AppDatabase.inMemory()
        store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
    }

    @discardableResult
    private func seed(_ text: String, at date: Date? = nil) throws -> Note {
        try store.create(text: text, now: date ?? now)
    }

    private func notes(_ scope: SidebarScope, sort: NoteSort = .modifiedDescending) throws -> [NoteListItem] {
        try db.pool.read { try LibraryQueries.notes(in: scope, sort: sort, now: now, calendar: calendar, db: $0) }
    }

    private func titles(_ scope: SidebarScope, sort: NoteSort = .modifiedDescending) throws -> [String] {
        try notes(scope, sort: sort).map(\.title)
    }

    private func counts() throws -> SidebarCounts {
        try db.pool.read { try LibraryQueries.counts(now: now, calendar: calendar, db: $0) }
    }

    private func tree() throws -> [TagNode] {
        try db.pool.read { try LibraryQueries.tagTree(db: $0) }
    }

    // MARK: scopes

    @Test func testNotesScopeExcludesArchiveAndTrash() throws {
        try seed("Alpha")
        let b = try seed("Beta")
        let c = try seed("Gamma")
        try store.archive([b.id])
        try store.trash([c.id])
        #expect(try titles(.notes) == ["Alpha"])
        #expect(try titles(.archive) == ["Beta"])
        #expect(try titles(.trash) == ["Gamma"])
    }

    @Test func testUntaggedTodoLocked() throws {
        try seed("Plain")
        try seed("Tagged\n\n#work")
        try seed("Tasks\n\n- [ ] one\n- [x] two")
        try seed("Done\n\n- [x] only done")
        let locked = try seed("Secret")
        try db.pool.write { try $0.execute(sql: "UPDATE note SET isLocked = 1 WHERE id = ?", arguments: [locked.id]) }
        #expect(Set(try titles(.untagged)) == ["Plain", "Tasks", "Done", "Secret"])
        #expect(try titles(.todo) == ["Tasks"])
        #expect(try titles(.locked) == ["Secret"])
        #expect(try notes(.locked).first?.isLocked == true)
    }

    @Test func testTodoExcludesTrashedNotes() throws {
        let t = try seed("Tasks\n\n- [ ] one")
        try store.trash([t.id])
        #expect(try titles(.todo).isEmpty)
        #expect(try counts().todo == 0)
    }

    @Test func testTodayBoundaryAtLocalMidnight() throws {
        try seed("Just after", at: midnight)
        try seed("Just before", at: midnight.addingTimeInterval(-0.001))
        try seed("Next day", at: midnight.addingTimeInterval(86_400))
        #expect(try titles(.today) == ["Just after"])
        #expect(try counts().today == 1)
    }

    @Test func testTrashedNoteIsNotToday() throws {
        let n = try seed("Today note")
        try store.trash([n.id])
        #expect(try titles(.today).isEmpty)
    }

    /// Spec §4.10: templates (`Templates.list`'s condition) are not in Today or Todo, list or count.
    @Test func testTemplatesAreNotInTodoOrToday() throws {
        try seed("Meeting\n\n- [ ] Action items\n#template")
        try seed("Standup\n\n- [ ] Blockers\n#template/daily")
        try seed("Real\n\n- [ ] call Bob")
        // A locked `#template` note is a plain note (as in `Templates.list`): it stays.
        let locked = try seed("Locked template\n\n- [ ] x\n#template")
        try db.pool.write { try $0.execute(sql: "UPDATE note SET isLocked = 1 WHERE id = ?", arguments: [locked.id]) }
        #expect(Set(try titles(.todo)) == ["Real", "Locked template"])
        #expect(Set(try titles(.today)) == ["Real", "Locked template"])
        let c = try counts()
        #expect(c.todo == 2)
        #expect(c.today == 2)
        #expect(c.notes == 4, "templates stay in Notes")
        // The same within a workspace, and in a search scoped to Todo / Today.
        try seed("Work template\n\n- [ ] y\n#template #work")
        try seed("Work\n\n- [ ] z\n#work")
        let work = Workspace(path: "work")
        let inWorkspace = try db.pool.read {
            (try LibraryQueries.counts(workspace: work, now: now, calendar: calendar, db: $0),
             try LibraryQueries.notes(in: .todo, sort: .modifiedDescending, workspace: work, now: now, calendar: calendar, db: $0))
        }
        #expect(inWorkspace.0.todo == 1)
        #expect(inWorkspace.0.today == 1)
        #expect(inWorkspace.1.map(\.title) == ["Work"])
        let searched = try db.pool.read {
            try LibraryQueries.search("-zzz", in: .today, sort: .modifiedDescending, now: now, calendar: calendar, db: $0)
        }
        #expect(Set(searched.items.map(\.title)) == ["Real", "Locked template", "Work"])
    }

    // MARK: pins

    @Test func testGlobalPinFirstThenSort() throws {
        try seed("Old", at: now.addingTimeInterval(-300))
        let mid = try seed("Mid", at: now.addingTimeInterval(-200))
        try seed("New", at: now.addingTimeInterval(-100))
        try store.setPinned([mid.id], pinned: true)
        let items = try notes(.notes)
        #expect(items.map(\.title) == ["Mid", "New", "Old"])
        #expect(items.map(\.isPinned) == [true, false, false])
    }

    @Test func testSortOptions() throws {
        try seed("b note", at: now.addingTimeInterval(-300))
        try seed("A note", at: now.addingTimeInterval(-200))
        try seed("c note", at: now.addingTimeInterval(-100))
        #expect(try titles(.notes, sort: .titleAscending) == ["A note", "b note", "c note"])
        #expect(try titles(.notes, sort: .titleDescending) == ["c note", "b note", "A note"])
        #expect(try titles(.notes, sort: .modifiedAscending) == ["b note", "A note", "c note"])
        #expect(try titles(.notes, sort: .createdDescending) == ["c note", "A note", "b note"])
        #expect(try titles(.notes, sort: .createdAscending) == ["b note", "A note", "c note"])
    }

    @Test func testTagScopeUsesOnlyExactTagPin() throws {
        let a = try seed("One\n\n#proj/x", at: now.addingTimeInterval(-300))
        let b = try seed("Two\n\n#proj/x", at: now.addingTimeInterval(-200))
        try seed("Three\n\n#proj/x", at: now.addingTimeInterval(-100))
        try store.setPinned([a.id], pinned: true, inTag: "proj")
        try store.setPinned([b.id], pinned: true, inTag: "proj/x")
        // Selected tag proj/x: only b is pinned there (a's pin is on the ancestor).
        let inChild = try notes(.tag("proj/x"))
        #expect(inChild.map(\.title) == ["Two", "Three", "One"])
        #expect(inChild.map(\.isPinned) == [true, false, false])
        // Selected tag proj: only a is pinned there; descendants are included.
        let inParent = try notes(.tag("proj"))
        #expect(inParent.map(\.title) == ["One", "Three", "Two"])
        #expect(inParent.map(\.isPinned) == [true, false, false])
        // Global scope ignores per-tag pins.
        #expect(try notes(.notes).map(\.isPinned) == [false, false, false])
    }

    @Test func testPinnedScopeIncludesGlobalAndTagPins() throws {
        let g = try seed("Global", at: now.addingTimeInterval(-300))
        let t = try seed("InTag\n\n#a", at: now.addingTimeInterval(-200))
        try seed("Neither", at: now.addingTimeInterval(-100))
        try store.setPinned([g.id], pinned: true)
        try store.setPinned([t.id], pinned: true, inTag: "a")
        let items = try notes(.pinned)
        #expect(items.map(\.title) == ["InTag", "Global"])
        #expect(items.allSatisfy { $0.isPinned })
        #expect(try counts().pinned == 2)
    }

    // MARK: tags

    @Test func testTagScopeIncludesDescendantsAndExcludesTrash() throws {
        try seed("Parent only\n\n#a", at: now.addingTimeInterval(-300))
        try seed("Child\n\n#a/b", at: now.addingTimeInterval(-200))
        let gone = try seed("Trashed\n\n#a/b", at: now.addingTimeInterval(-100))
        try store.trash([gone.id])
        #expect(try titles(.tag("a")) == ["Child", "Parent only"])
        #expect(try titles(.tag("a/b")) == ["Child"])
        #expect(try titles(.tag("A/B")) == ["Child"])
        #expect(try titles(.tag("missing")).isEmpty)
    }

    @Test func testRemoveTagKeepsNoteUnderParentViaDescendants() throws {
        let n = try seed("Note\n\n#a #a/b")
        try store.removeTag("a", from: [n.id])
        #expect(try titles(.tag("a")) == ["Note"])
    }

    @Test func testTagTreeCountsAndSorting() throws {
        try seed("1\n\n#work/b")
        try seed("2\n\n#work/a")
        try seed("3\n\n#work/a")
        try seed("4\n\n#Apple")
        let nodes = try tree()
        #expect(nodes.map(\.name) == ["Apple", "work"])
        let work = nodes[1]
        #expect(work.noteCount == 3)
        #expect(work.children.map(\.name) == ["a", "b"])
        #expect(work.children.map(\.noteCount) == [2, 1])
        #expect(work.children[0].path == "work/a")
        #expect(work.children[0].id == "work/a")
    }

    @Test func testTagTreeCountsOnlyNotesLocation() throws {
        let n = try seed("Note\n\n#gone")
        try seed("Other\n\n#kept")
        try store.trash([n.id])
        #expect(try tree().map(\.name) == ["kept"])
        try store.restore([n.id])
        #expect(try tree().map(\.name) == ["gone", "kept"])
    }

    @Test func testTagTreeShowsPinnedTagWithZeroNotes() throws {
        let n = try seed("Note\n\n#pinme")
        try db.pool.write { try $0.execute(sql: "UPDATE tag SET isPinned = 1, iconName = 'star' WHERE pathKey = 'pinme'") }
        try store.trash([n.id])
        let nodes = try tree()
        #expect(nodes.map(\.name) == ["pinme"])
        #expect(nodes[0].noteCount == 0)
        #expect(nodes[0].isPinned)
        #expect(nodes[0].iconName == "star")
    }

    @Test func testTagTreeLabelsComeFromOwnRow() throws {
        try seed("A\n\n#Work/Sub")
        try db.pool.write {
            try $0.execute(sql: "UPDATE tag SET displayPath = 'WORK' WHERE pathKey = 'work'")
        }
        let work = try tree()[0]
        #expect(work.name == "WORK")
        #expect(work.children[0].name == "Sub")
    }

    @Test func testTagTreeToleratesMissingParentRow() throws {
        try seed("A\n\n#work/sub")
        try db.pool.write {
            try $0.execute(sql: "UPDATE tag SET isPinned = 1 WHERE pathKey = 'work/sub'")
            try $0.execute(sql: "PRAGMA foreign_keys = OFF")
            try $0.execute(sql: "DELETE FROM tag WHERE pathKey = 'work'")
        }
        let nodes = try tree()
        #expect(nodes.map(\.name) == ["work"])
        #expect(nodes[0].isPinned == false)
        #expect(nodes[0].noteCount == 1)
        #expect(nodes[0].children.map(\.path) == ["work/sub"])
    }

    @Test func testTagTreeNaturalSorting() throws {
        try seed("1\n\n#item10")
        try seed("2\n\n#item2")
        #expect(try tree().map(\.name) == ["item2", "item10"])
    }

    // MARK: list item fields

    @Test func testAttachmentsAndFirstImage() throws {
        try seed("Plain")
        try seed("Pics\n\n![](photo.jpg)\n![](other.png)")
        let items = try notes(.notes)
        let plain = try #require(items.first { $0.title == "Plain" })
        let pics = try #require(items.first { $0.title == "Pics" })
        #expect(!plain.hasAttachments)
        #expect(plain.firstImageFilename == nil)
        #expect(pics.hasAttachments)
        #expect(pics.firstImageFilename == "photo.jpg")
    }

    @Test func testReadOnlyAndSubtitle() throws {
        let n = try seed("Title\nSubtitle text")
        try db.pool.write { try $0.execute(sql: "UPDATE note SET isReadOnly = 1 WHERE id = ?", arguments: [n.id]) }
        let item = try #require(try notes(.notes).first)
        #expect(item.isReadOnly)
        #expect(item.subtitle == "Subtitle text")
        #expect(item.modifiedAt == n.modifiedAt)
        #expect(item.createdAt == n.createdAt)
    }

    // MARK: counts

    @Test func testCounts() throws {
        try seed("Plain")
        let pinned = try seed("Pinned\n\n#t")
        try seed("Todo\n\n- [ ] x", at: midnight.addingTimeInterval(-3_600))
        let archived = try seed("Arch")
        let trashed = try seed("Trash")
        let locked = try seed("Locked")
        try store.setPinned([pinned.id], pinned: true)
        try store.archive([archived.id])
        try store.trash([trashed.id])
        try db.pool.write { try $0.execute(sql: "UPDATE note SET isLocked = 1 WHERE id = ?", arguments: [locked.id]) }
        let c = try counts()
        #expect(c == SidebarCounts(notes: 4, pinned: 1, untagged: 3, todo: 1, today: 3, locked: 1, archive: 1, trash: 1, inbox: 3))
    }

    @Test func testEmptyLibraryCountsAreZero() throws {
        #expect(try counts() == SidebarCounts())
        #expect(try tree().isEmpty)
    }

    // MARK: migration

    @Test func testMigrationBackfillsFirstImage() throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        let old = Migrations.migrator
        try old.migrate(queue, upTo: "v2")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO note (id, text, createdAt, modifiedAt) VALUES ('n1', 'T' || char(10) || '![](pic.png)', '2026-01-01 00:00:00.000', '2026-01-01 00:00:00.000')
                """)
        }
        try Migrations.migrator.migrate(queue)
        let first = try queue.read { try String.fetchOne($0, sql: "SELECT firstImage FROM note_stats WHERE noteId = 'n1'") }
        #expect(first == "pic.png")
    }

    // MARK: snapshot + observation

    @Test func testSnapshotUsesSortSetting() throws {
        try seed("Beta", at: now.addingTimeInterval(-60))
        try seed("Alpha", at: now)
        try Settings(db: db).set(.noteSort, to: .titleAscending)
        let snapshot = try db.pool.read {
            try LibraryQueries.snapshot(scope: .notes, now: now, calendar: calendar, db: $0)
        }
        #expect(snapshot.sort == .titleAscending)
        #expect(snapshot.items.map(\.title) == ["Alpha", "Beta"])
        #expect(snapshot.counts.notes == 2)
    }

    @MainActor @Test func testSnapshotObservationFiresOnNoteAndSettingWrites() async throws {
        try seed("First #work")
        let fixedNow = now, calendar = calendar
        var received: [LibrarySnapshot] = []
        let token = LibraryQueries.observeSnapshot(
            scope: .tag("work"), database: db, calendar: calendar, now: { fixedNow },
            onError: { Issue.record("observation failed: \($0)") },
            onChange: { received.append($0) }
        )
        defer { token.cancel() }
        // `.immediate` scheduling: the initial value is delivered before observeSnapshot returns.
        #expect(received.map { $0.items.map(\.title) } == [["First #work"]])
        #expect(received.first?.tagTree.map(\.path) == ["work"])

        try seed("Second #work", at: now.addingTimeInterval(1))
        try await waitUntil { received.last?.items.count == 2 }
        try Settings(db: db).set(.noteSort, to: .titleDescending)
        try await waitUntil { received.last?.sort == .titleDescending }
        #expect(received.last?.items.map(\.title) == ["Second #work", "First #work"])
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("condition not met within 2 s")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: performance

    @Test(.tags(.perf), PerfGate.onlyInPerfPass) func testPerfLibraryWith10kNotes() throws {
        try db.pool.write { db in
            for i in 0..<10_000 {
                let id = UUIDv7.make()
                let stamp = Date(timeIntervalSince1970: 1_790_000_000 + Double(i) * 10)
                try db.execute(
                    sql: "INSERT INTO note (id, text, createdAt, modifiedAt, isPinnedGlobal) VALUES (?, '', ?, ?, ?)",
                    arguments: [id, stamp, stamp, i % 50 == 0]
                )
                try NoteIndexer.index(noteId: id, text: "Note \(i)\n\nbody text #t\(i % 40)/s\(i % 7)\n- [ ] todo", in: db)
            }
        }
        let clock = ContinuousClock()
        var listed: [NoteListItem] = []
        let listTime = try clock.measure { listed = try notes(.notes) }
        var c = SidebarCounts()
        let countTime = try clock.measure { c = try counts() }
        var nodes: [TagNode] = []
        let treeTime = try clock.measure { nodes = try tree() }
        #expect(listed.count == 10_000)
        #expect(c.notes == 10_000)
        #expect(!nodes.isEmpty)
        #expect(listTime < .milliseconds(100), "notes(in:) took \(listTime)")
        #expect(countTime < .milliseconds(100), "counts took \(countTime)")
        #expect(treeTime < .milliseconds(100), "tagTree took \(treeTime)")

        // The same with a workspace active (final fix wave, T8 carry 8): every statement also
        // needs the workspace tag.
        let workspace = Workspace(path: "t3")
        var snapshot = LibrarySnapshot()
        let snapshotTime = try clock.measure {
            snapshot = try db.pool.read {
                try LibraryQueries.snapshot(scope: .notes, workspace: workspace, now: now, calendar: calendar, db: $0)
            }
        }
        let workspaceCountTime = try clock.measure {
            c = try db.pool.read { try LibraryQueries.counts(workspace: workspace, now: now, calendar: calendar, db: $0) }
        }
        let workspaceTreeTime = try clock.measure {
            nodes = try db.pool.read { try LibraryQueries.tagTree(workspace: workspace, db: $0) }
        }
        print("[perf] library 10k in workspace #t3: snapshot \(snapshotTime), counts \(workspaceCountTime), tagTree \(workspaceTreeTime)")
        #expect(snapshot.items.count == 250)
        #expect(c.notes == 250)
        #expect(nodes.map(\.path) == ["t3"])
        #expect(snapshotTime < .milliseconds(100), "snapshot in a workspace took \(snapshotTime)")
        #expect(workspaceCountTime < .milliseconds(100), "counts in a workspace took \(workspaceCountTime)")
        #expect(workspaceTreeTime < .milliseconds(100), "tagTree in a workspace took \(workspaceTreeTime)")
    }
}
