// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// `v15-focus`: the device-local state of the capture-and-next-up layer
///). Constraints are part of the contract, so each is pinned here.
@Suite struct FocusMigrationTests {
    let tmp: TempPaths
    let db: AppDatabase
    let store: NoteStore
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        tmp = try TempPaths()
        db = try AppDatabase.inMemory()
        store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
    }

    private func count(_ table: String, noteId: String? = nil) throws -> Int {
        try db.pool.read { db in
            if let noteId {
                return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE noteId = ?", arguments: [noteId])!
            }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)")!
        }
    }

    private func ping(_ id: String, noteId: String, line: Int?, hash: String?, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO note_ping(id, noteId, anchorLine, anchorHash, fireAt, createdAt) VALUES(?,?,?,?,?,?)
            """, arguments: [id, noteId, line, hash, t0, t0])
    }

    @Test func existingNotesKeepNullCaptureSource() throws {
        // A library that ran v14 and then upgrades: the old notes read back with no source.
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue, upTo: "v14-sync-capture-before-upload")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO note(id, text, title, titleKey, createdAt, modifiedAt, location, revision)
                VALUES('n1', 'body', 'T', 't', ?, ?, 'notes', 1)
                """, arguments: [t0, t0])
        }
        try Migrations.migrator.migrate(queue)
        try queue.read { db in
            let row = try #require(try Row.fetchOne(db, sql: "SELECT captureSource FROM note WHERE id = 'n1'"))
            #expect(row.hasNull(atIndex: 0))
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pragma_table_info('note_ui_state') WHERE name = 'lastOpenedAt'") == 1)
        }
    }

    @Test(arguments: ["share", "voice", "lockscreen", "shortcut", "command", "mcp"])
    func captureSourceAcceptsTheSixValues(_ value: String) throws {
        let note = try store.create(text: "# A", now: t0)
        try db.pool.write { db in
            try db.execute(sql: "UPDATE note SET captureSource = ? WHERE id = ?", arguments: [value, note.id])
        }
        #expect(try db.pool.read { try String.fetchOne($0, sql: "SELECT captureSource FROM note WHERE id = ?", arguments: [note.id]) } == value)
    }

    @Test func captureSourceRejectsUnknownValues() throws {
        let note = try store.create(text: "# A", now: t0)
        #expect(throws: DatabaseError.self) {
            try db.pool.write { db in
                try db.execute(sql: "UPDATE note SET captureSource = 'telepathy' WHERE id = ?", arguments: [note.id])
            }
        }
    }

    @Test func onePingPerTarget() throws {
        let note = try store.create(text: "# A\nline", now: t0)
        try db.pool.write { db in
            try ping("p1", noteId: note.id, line: nil, hash: nil, in: db)
            try ping("p3", noteId: note.id, line: 3, hash: "abcd1234", in: db)
        }
        #expect(try count("note_ping", noteId: note.id) == 2)
        // A second whole-note row and a second row for the same line are both refused.
        #expect(throws: DatabaseError.self) {
            try db.pool.write { try ping("p2", noteId: note.id, line: nil, hash: nil, in: $0) }
        }
        #expect(throws: DatabaseError.self) {
            try db.pool.write { try ping("p4", noteId: note.id, line: 3, hash: "abcd1234", in: $0) }
        }
        // A different hash on the same line is a different target.
        try db.pool.write { try ping("p5", noteId: note.id, line: 3, hash: "deadbeef", in: $0) }
        #expect(try count("note_ping", noteId: note.id) == 3)
    }

    @Test func aPingAnchorIsBothOrNeither() throws {
        let note = try store.create(text: "# A", now: t0)
        #expect(throws: DatabaseError.self) {
            try db.pool.write { try ping("half", noteId: note.id, line: 2, hash: nil, in: $0) }
        }
        #expect(throws: DatabaseError.self) {
            try db.pool.write { try ping("half2", noteId: note.id, line: nil, hash: "abcd1234", in: $0) }
        }
    }

    @Test func snapshotNeedsExactlyOneBody() throws {
        let note = try store.create(text: "# A", now: t0)
        try db.pool.write { db in
            try db.execute(sql: "INSERT INTO note_snapshot(id, noteId, takenAt, text) VALUES('s1', ?, ?, 'plain')", arguments: [note.id, t0])
            try db.execute(sql: "INSERT INTO note_snapshot(id, noteId, takenAt, sealedText) VALUES('s2', ?, ?, ?)",
                           arguments: [note.id, t0, Data([1, 2, 3])])
        }
        #expect(throws: DatabaseError.self) {
            try db.pool.write { try $0.execute(sql: "INSERT INTO note_snapshot(id, noteId, takenAt) VALUES('none', ?, ?)", arguments: [note.id, t0]) }
        }
        #expect(throws: DatabaseError.self) {
            try db.pool.write { try $0.execute(sql: "INSERT INTO note_snapshot(id, noteId, takenAt, text, sealedText) VALUES('both', ?, ?, 'x', ?)",
                                               arguments: [note.id, t0, Data([1])]) }
        }
        #expect(try count("note_snapshot", noteId: note.id) == 2)
    }

    @Test func deletingANoteCascades() throws {
        let note = try store.create(text: "# A\n- [ ] todo", now: t0)
        let keep = try store.create(text: "# B", now: t0)
        try db.pool.write { db in
            for id in [note.id, keep.id] {
                try db.execute(sql: "INSERT INTO focus_hide(candidateKey, noteId, hiddenUntil) VALUES(?, ?, ?)",
                               arguments: ["note:\(id)", id, t0])
                try ping("ping-\(id)", noteId: id, line: nil, hash: nil, in: db)
                try db.execute(sql: "INSERT INTO note_snapshot(id, noteId, takenAt, text) VALUES(?, ?, ?, 'x')", arguments: ["snap-\(id)", id, t0])
            }
            try db.execute(sql: "DELETE FROM note WHERE id = ?", arguments: [note.id])
        }
        for table in ["focus_hide", "note_ping", "note_snapshot"] {
            #expect(try count(table) == 1, "\(table) keeps only the other note's row")
            #expect(try count(table, noteId: note.id) == 0)
        }
    }

    @Test func ledgerRowsOutliveADeletedNote() throws {
        let note = try store.create(text: "# A", now: t0)
        try db.pool.write { db in
            try db.execute(sql: """
                INSERT INTO notification_ledger(identifier, kind, pingId, noteId, contentHash, recordedAt)
                VALUES('reminder:p1:u1', 'reminder', 'p1', ?, 'abc', ?), ('timer:u2', 'timer', NULL, NULL, NULL, ?)
                """, arguments: [note.id, t0, t0])
            try db.execute(sql: "DELETE FROM note WHERE id = ?", arguments: [note.id])
        }
        #expect(try count("notification_ledger") == 2)
        #expect(try db.pool.read { try String.fetchOne($0, sql: "SELECT noteId FROM notification_ledger WHERE identifier = 'reminder:p1:u1'") } == note.id)
    }

    @Test func ledgerKindIsReminderOrTimer() throws {
        #expect(throws: DatabaseError.self) {
            try db.pool.write { try $0.execute(sql: "INSERT INTO notification_ledger(identifier, kind, recordedAt) VALUES('x', 'banner', ?)", arguments: [t0]) }
        }
    }

    @Test func captureReceiptKeepsItsItemId() throws {
        try db.pool.write { try $0.execute(sql: "INSERT INTO capture_receipt(itemId, noteId, processedAt) VALUES('i1', 'n', ?)", arguments: [t0]) }
        #expect(throws: DatabaseError.self) {
            try db.pool.write { try $0.execute(sql: "INSERT INTO capture_receipt(itemId, noteId, processedAt) VALUES('i1', 'n', ?)", arguments: [t0]) }
        }
    }
}
