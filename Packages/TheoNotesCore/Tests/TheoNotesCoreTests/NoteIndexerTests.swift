// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import GRDB
@testable import TheoNotesCore

/// Temp data directory for stores (attachments + journal cleanup); removed on deinit.
final class TempPaths {
    let paths: AppPaths

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("baerchen-paths-\(UUID().uuidString)", isDirectory: true)
        paths = AppPaths(root: root)
        try paths.createDirectories()
    }

    deinit { try? FileManager.default.removeItem(at: paths.root) }
}

struct TagRow: Equatable {
    var path: String
    var isDirect: Bool
}

func tagRows(_ db: AppDatabase, _ noteId: String) throws -> [TagRow] {
    try db.pool.read { db in
        try Row.fetchAll(db, sql: """
            SELECT tag.displayPath, note_tag.isDirect FROM note_tag JOIN tag ON tag.id = note_tag.tagId
            WHERE note_tag.noteId = ? ORDER BY tag.pathKey
            """, arguments: [noteId])
            .map { TagRow(path: $0[0], isDirect: $0[1]) }
    }
}

func allTagPaths(_ db: AppDatabase) throws -> [String] {
    try db.pool.read { try String.fetchAll($0, sql: "SELECT displayPath FROM tag ORDER BY pathKey") }
}

@Suite struct NoteIndexerTests {
    @Test func testIndexWritesDerivedRows() throws {
        let tmp = try TempPaths()
        let db = try AppDatabase.inMemory()
        let store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
        let text = """
            # Plan for #work
            Body with [[Other Note/Section|see]] and [[/Local]]
            ## Steps
            - [ ] open
            - [x] done
            - [ ] another
            ```
            let x = 1
            ```
            ![](photo.jpg)
            [doc.pdf](doc.pdf)<!-- {"embed":"true"} -->
            """
        let note = try store.create(text: text)
        #expect(note.title == "Plan for #work")
        #expect(note.titleKey == CanonicalKey.make("Plan for #work"))
        #expect(note.subtitle.hasPrefix("Body with"))
        #expect(try tagRows(db, note.id) == [TagRow(path: "work", isDirect: true)])

        let links = try db.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT ordinal, targetKey, targetTitle, targetHeading, alias FROM wiki_link
                WHERE sourceNoteId = ? ORDER BY ordinal
                """, arguments: [note.id])
        }
        #expect(links.count == 2)
        #expect(links[0]["ordinal"] as Int == 0)
        #expect(links[0]["targetKey"] as String == "other note")
        #expect(links[0]["targetTitle"] as String == "Other Note")
        #expect(links[0]["targetHeading"] as String? == "Section")
        #expect(links[0]["alias"] as String? == "see")
        #expect(links[1]["targetTitle"] as String == "")
        #expect(links[1]["targetHeading"] as String? == "Local")

        let headings = try db.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT ordinal, level, text, line FROM heading WHERE noteId = ? ORDER BY ordinal",
                             arguments: [note.id])
        }
        #expect(headings.map { $0["text"] as String } == NoteParser.metadata(for: text).headings.map(\.text))
        #expect(headings.map { $0["ordinal"] as Int } == [0, 1])
        #expect(headings.map { $0["level"] as Int } == [1, 2])
        #expect(headings.map { $0["line"] as Int } == [1, 3])

        let stats = try #require(try db.pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM note_stats WHERE noteId = ?", arguments: [note.id])
        })
        #expect(stats["openTodos"] as Int == 2)
        #expect(stats["doneTodos"] as Int == 1)
        #expect(stats["hasCode"] as Bool == true)
        #expect(stats["hasImages"] as Bool == true)
        #expect(stats["hasFiles"] as Bool == true)
        #expect(stats["isEmpty"] as Bool == false)
        #expect(stats["attachmentNames"] as String == "photo.jpg\ndoc.pdf")

        // Re-indexing replaces (not appends) the derived rows.
        let updated = try store.updateText(id: note.id, text: "Plain\nno links", expectedRevision: note.revision)
        #expect(updated.title == "Plain")
        #expect(updated.subtitle == "no links")
        let counts = try db.pool.read { db in
            try [ "wiki_link WHERE sourceNoteId", "heading WHERE noteId", "note_tag WHERE noteId" ].map {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0) = ?", arguments: [note.id])!
            }
        }
        #expect(counts == [0, 0, 0])
        let empty = try store.create(text: "")
        let emptyStats = try db.pool.read { db in
            try Row.fetchOne(db, sql: "SELECT isEmpty, attachmentNames FROM note_stats WHERE noteId = ?", arguments: [empty.id])
        }
        #expect(emptyStats?["isEmpty"] as Bool? == true)
        #expect(emptyStats?["attachmentNames"] as String? == "")
    }

    @Test func testAncestorsMaterialized() throws {
        let tmp = try TempPaths()
        let db = try AppDatabase.inMemory()
        let store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
        let note = try store.create(text: "Title\n#Projects/Home/Kitchen and #projects/home")
        #expect(try tagRows(db, note.id) == [
            TagRow(path: "Projects", isDirect: false),
            TagRow(path: "Projects/Home", isDirect: true),
            TagRow(path: "Projects/Home/Kitchen", isDirect: true),
        ])
        // First-seen spelling wins across notes; identity is the canonical key.
        let other = try store.create(text: "x\n#PROJECTS/home/kitchen")
        #expect(try tagRows(db, other.id).map(\.path) == ["Projects", "Projects/Home", "Projects/Home/Kitchen"])
        #expect(try allTagPaths(db) == ["Projects", "Projects/Home", "Projects/Home/Kitchen"])
        let keys = try db.pool.read { try String.fetchAll($0, sql: "SELECT pathKey FROM tag ORDER BY pathKey") }
        #expect(keys == ["projects", "projects/home", "projects/home/kitchen"])
    }

    @Test func testOrphanTagsRemoved() throws {
        let tmp = try TempPaths()
        let db = try AppDatabase.inMemory()
        let store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
        let a = try store.create(text: "A\n#only/child #shared")
        let b = try store.create(text: "B\n#shared #kept")
        #expect(try allTagPaths(db) == ["kept", "only", "only/child", "shared"])
        try db.pool.write { try $0.execute(sql: "UPDATE tag SET isPinned = 1 WHERE pathKey = 'kept'") }

        // Deleting the text that carried the last `#only/child` removes the tag and its parent.
        _ = try store.updateText(id: a.id, text: "A\n#shared", expectedRevision: a.revision)
        #expect(try allTagPaths(db) == ["kept", "shared"])

        // A pinned tag survives without notes.
        let bNow = try #require(try store.note(id: b.id))
        _ = try store.updateText(id: b.id, text: "B", expectedRevision: bNow.revision)
        #expect(try allTagPaths(db) == ["kept", "shared"])

        // A per-tag pin is dropped when its note loses the tag, so the tag can go too.
        try store.setPinned([a.id], pinned: true, inTag: "shared")
        let aNow = try #require(try store.note(id: a.id))
        _ = try store.updateText(id: a.id, text: "A", expectedRevision: aNow.revision)
        #expect(try allTagPaths(db) == ["kept"])
        #expect(try db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note_pin") } == 0)
    }

    @Test func testMigrationBackfillsExistingNotes() throws {
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue, upTo: "v1")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO note (id, text, title, titleKey, createdAt, modifiedAt, revision)
                VALUES ('n1', '# Hello #tag/sub' || char(10) || 'body [[Link]]', 'stale', 'stale', '2026-01-01 00:00:00.000', '2026-01-02 00:00:00.000', 3),
                       ('n2', NULL, 'x', 'x', '2026-01-01 00:00:00.000', '2026-01-01 00:00:00.000', 1);
                INSERT INTO note_ui_state (noteId, scrollTop) VALUES ('n1', 12.5);
                """)
        }
        try Migrations.migrator.migrate(queue)
        try queue.read { db in
            let n1 = try #require(try Note.fetchOne(db, key: "n1"))
            #expect(n1.title == "Hello #tag/sub")
            #expect(n1.subtitle == "body Link")
            #expect(n1.revision == 3)
            #expect(n1.modifiedAt == Date(timeIntervalSince1970: 1_767_312_000))
            let n2 = try #require(try Note.fetchOne(db, key: "n2"))
            #expect(n2.text == "")
            #expect(n2.title == "")
            let paths = try String.fetchAll(db, sql: "SELECT displayPath FROM tag ORDER BY pathKey")
            #expect(paths == ["tag", "tag/sub"])
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM wiki_link WHERE sourceNoteId = 'n1'") == 1)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note_stats") == 2)
            #expect(try Double.fetchOne(db, sql: "SELECT scrollTop FROM note_ui_state WHERE noteId = 'n1'") == 12.5)
            // text is NOT NULL DEFAULT '' now.
            let column = try #require(try db.columns(in: "note").first { $0.name == "text" })
            #expect(column.isNotNull)
            #expect(column.defaultValueSQL == "''")
            let indexNames = try db.indexes(on: "note").map(\.name).filter { !$0.hasPrefix("sqlite_") }.sorted()
            #expect(indexNames == ["note_on_modifiedAt", "note_on_noteType", "note_on_titleKey"])
            #expect(try db.foreignKeyViolations().map { $0 }.isEmpty)
        }
        // Cascades still work against the rebuilt table.
        try queue.write { db in
            try db.execute(sql: "DELETE FROM note WHERE id = 'n1'")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note_ui_state") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note_tag") == 0)
        }
    }
}
