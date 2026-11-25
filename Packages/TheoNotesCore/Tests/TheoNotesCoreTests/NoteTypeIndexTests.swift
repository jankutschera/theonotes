// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import GRDB
@testable import TheoNotesCore

@Suite struct NoteTypeIndexTests {
    let tmp: TempPaths
    let db: AppDatabase
    let store: NoteStore
    let now = Date(timeIntervalSince1970: 1_792_670_400)

    init() throws {
        tmp = try TempPaths()
        db = try AppDatabase.inMemory()
        store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
    }

    private func storedType(_ id: String) throws -> String? {
        try db.pool.read { try String.fetchOne($0, sql: "SELECT noteType FROM note WHERE id = ?", arguments: [id]) }
    }

    @Test func indexerDerivesFirstReservedType() throws {
        let note = try store.create(text: "# A\n#log #idea")
        #expect(try storedType(note.id) == "log")
        let edited = try store.updateText(id: note.id, text: "# A\nplain", expectedRevision: note.revision)
        #expect(try storedType(edited.id) == nil)
    }

    @Test func lockedNoteKeepsItsType() throws {
        let note = try store.create(text: "# A\n#ref")
        #expect(try storedType(note.id) == "reference")
        let (envelope, key) = try CryptoEnvelope.create(password: "fixture-password", iterations: 1)
        try db.pool.write {
            try $0.execute(sql: "INSERT INTO crypto_envelope(id,envelope) VALUES(1,?)", arguments: [try JSONEncoder().encode(envelope)])
        }
        try LockedNoteAccess(store: store, key: key).lock(noteId: note.id)
        #expect(try db.pool.read { try Bool.fetchOne($0, sql: "SELECT isLocked FROM note WHERE id = ?", arguments: [note.id]) } == true)
        #expect(try storedType(note.id) == "reference")
    }

    @Test func migrationBackfillsExistingNotes() throws {
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue, upTo: "v18-cloudkit-key-bundle-cache")
        try queue.write { db in
            for (id, text) in [("n1", "# A\n#ref #idea"), ("n2", "# B\n#log\n#idea"), ("n3", "# C\n#a/idea #work"), ("n4", "# D\n```\n#idea\n```")] {
                try db.execute(sql: """
                    INSERT INTO note(id, text, title, titleKey, createdAt, modifiedAt, location, revision)
                    VALUES(?, ?, 'T', 't', ?, ?, 'notes', 1)
                    """, arguments: [id, text, now, now])
                try NoteIndexer.indexWithoutSearch(noteId: id, text: text, in: db)
            }
        }
        try Migrations.migrator.migrate(queue)
        let types = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, noteType FROM note ORDER BY id").map { ($0["id"] as String, $0["noteType"] as String?) }
        }
        // First in text order wins, as the indexer decides it; nested and code-fenced tags do not count.
        #expect(types.map(\.1) == ["reference", "log", nil, nil])
    }

    @Test func migrationBackfillsLockedNoteFromTags() throws {
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue, upTo: "v18-cloudkit-key-bundle-cache")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO note(id, text, title, titleKey, createdAt, modifiedAt, location, isLocked, revision)
                VALUES('n1', '', 'T', 't', ?, ?, 'notes', 1, 1)
                """, arguments: [now, now])
            try NoteIndexer.writeTags(["log", "idea"], noteId: "n1", in: db)
        }
        try Migrations.migrator.migrate(queue)
        // The text is not readable, so the tag rows decide: the alphabetically first reserved tag.
        #expect(try queue.read { try String.fetchOne($0, sql: "SELECT noteType FROM note WHERE id = 'n1'") } == "idea")
    }

    @Test func listItemsCarryType() throws {
        let typed = try store.create(text: "# Typed\n#ref", now: now)
        let plain = try store.create(text: "# Plain", now: now.addingTimeInterval(-60))
        let calendar = Calendar(identifier: .gregorian)
        let listed = try db.pool.read {
            try LibraryQueries.notes(in: .notes, sort: .modifiedDescending, now: now, calendar: calendar, db: $0)
        }
        #expect(listed.first { $0.id == typed.id }?.noteType == .reference)
        #expect(listed.first { $0.id == plain.id }?.noteType == nil)
        let found = try db.pool.read {
            try LibraryQueries.search("#ref", in: .notes, sort: .modifiedDescending, now: now, calendar: calendar, db: $0)
        }
        #expect(found.items.map(\.id) == [typed.id])
        #expect(found.items.first?.noteType == .reference)
    }

    @Test func migrationLeavesUntaggedLockedNoteUntyped() throws {
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue, upTo: "v18-cloudkit-key-bundle-cache")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO note(id, text, title, titleKey, createdAt, modifiedAt, location, isLocked, revision)
                VALUES('n1', '', 'T', 't', ?, ?, 'notes', 1, 1)
                """, arguments: [now, now])
            try NoteIndexer.writeTags(["work", "a/idea"], noteId: "n1", in: db)
        }
        try Migrations.migrator.migrate(queue)
        #expect(try queue.read { try String.fetchOne($0, sql: "SELECT noteType FROM note WHERE id = 'n1'") } == nil)
    }

    @Test func editingLockedNoteTagsUpdatesType() throws {
        let library = try SyncMaterializerTests.Library()
        defer { library.cleanup() }
        let note = try library.store.create(text: "# Secret\nbody")
        let access = LockedNoteAccess(store: library.store, key: library.key)
        defer { access.revoke() }
        try access.lock(noteId: note.id)
        func type() throws -> String? {
            try library.db.pool.read { try String.fetchOne($0, sql: "SELECT noteType FROM note WHERE id = ?", arguments: [note.id]) }
        }
        #expect(try type() == nil)
        var current = try #require(try library.store.note(id: note.id))
        current = try access.updateText(id: note.id, text: "# Secret\nbody #idea", expectedRevision: current.revision)
        #expect(try type() == "idea")
        _ = try access.updateText(id: note.id, text: "# Secret\nbody", expectedRevision: current.revision)
        #expect(try type() == nil)
    }

    @Test func lockedNoteArrivingBySyncCarriesItsType() throws {
        let library = try SyncMaterializerTests.Library()
        defer { library.cleanup() }
        let incoming = try SnapshotPrivacyTests.lockedPayload(library, id: "remote", text: "# Remote\n#log")
        try SnapshotPrivacyTests.write(incoming, in: library)
        let row = try library.db.pool.read { try Row.fetchOne($0, sql: "SELECT isLocked, noteType FROM note WHERE id = 'remote'") }
        #expect(row?["isLocked"] as Bool? == true)
        #expect(row?["noteType"] as String? == "log")
    }
}
