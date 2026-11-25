// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct WatchCaptureMigrationTests {
    @Test func serializedSourcesStayUnchanged() {
        #expect(CaptureSource.allCases.map(\.rawValue) == ["share", "voice", "lockscreen", "shortcut", "command", "mcp"])
        #expect(CaptureSource(rawValue: "watch") == nil)
    }

    @Test func upgradePreservesRowsChildrenIndexesTriggersSearchAndSyncState() throws {
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue, upTo: "v19-note-type")
        let originalLegacy = try queue.read { try Int.fetchOne($0, sql: "PRAGMA legacy_alter_table") }
        try queue.write { db in
            try db.execute(sql: "UPDATE sync_control SET accountId='fixture-account' WHERE id=1")
            for (index, source) in ["share", "voice", "lockscreen", "shortcut", "command", "mcp"].enumerated() {
                try db.execute(sql: """
                    INSERT INTO note(rowid,id,text,title,createdAt,modifiedAt,captureSource,noteType,revision)
                    VALUES(?,?,'needle fixture','Before',100,200,?,'idea',7)
                    """, arguments: [index * 3 + 1, "n\(index)", source])
            }
            try db.execute(sql: """
                INSERT INTO note(id,text,createdAt,modifiedAt,isLocked,encryptedPayload)
                VALUES('locked','',100,200,1,X'010203');
                INSERT INTO note_ui_state(noteId,scrollTop,lastOpenedAt) VALUES('n0',42,300);
                INSERT INTO note_search_content(noteId,title,body) VALUES('n0','Before','needle fixture');
                CREATE TABLE watch_migration_child(noteId TEXT REFERENCES note(id) ON DELETE CASCADE);
                INSERT INTO watch_migration_child VALUES('n0');
                CREATE TABLE watch_migration_audit(value TEXT);
                CREATE TABLE watch_migration_incoming(noteId TEXT);
                CREATE INDEX watch_migration_index ON note(revision, captureSource);
                CREATE TRIGGER watch_migration_note AFTER UPDATE ON note BEGIN
                    INSERT INTO watch_migration_audit VALUES(new.id);
                END;
                CREATE TRIGGER watch_migration_incoming_trigger AFTER INSERT ON watch_migration_incoming BEGIN
                    UPDATE note SET title='Incoming trigger' WHERE id=new.noteId;
                END;
                CREATE VIEW watch_migration_view AS SELECT id FROM note;
                """)
        }
        let before = try queue.read { db in
            (try Row.fetchAll(db, sql: "SELECT rowid,* FROM note ORDER BY rowid"),
             try Row.fetchAll(db, sql: "SELECT type,name,tbl_name,sql FROM sqlite_master WHERE type IN ('table','index','trigger','view') ORDER BY type,name"),
             try Row.fetchAll(db, sql: "SELECT * FROM sync_dirty ORDER BY entityType,localId"))
        }
        try Migrations.migrator.migrate(queue)
        try queue.read { (db: Database) throws -> Void in
            #expect(try Row.fetchAll(db, sql: "SELECT rowid,* FROM note ORDER BY rowid") == before.0)
            #expect(try Row.fetchAll(db, sql: "SELECT type,name,tbl_name,sql FROM sqlite_master WHERE type IN ('table','index','trigger','view') AND tbl_name != 'watch_command_receipt' ORDER BY type,name") == before.1)
            #expect(try Row.fetchAll(db, sql: "SELECT * FROM sync_dirty ORDER BY entityType,localId") == before.2)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM watch_migration_child") == 1)
            #expect(try Double.fetchOne(db, sql: "SELECT scrollTop FROM note_ui_state WHERE noteId='n0'") == 42)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM watch_migration_audit") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note_fts WHERE note_fts MATCH 'needle'") == 1)
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            #expect(try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok")
            #expect(try Int.fetchOne(db, sql: "PRAGMA foreign_keys") == 1)
            #expect(try Int.fetchOne(db, sql: "PRAGMA legacy_alter_table") == originalLegacy)
        }
        try queue.write { db in
            try db.execute(sql: "UPDATE note SET captureSource='voice' WHERE id='n0'")
            #expect(try CaptureSource.fetchOne(db, sql: "SELECT captureSource FROM note WHERE id='n0'") == .voice)
            #expect(throws: DatabaseError.self) { try db.execute(sql: "UPDATE note SET captureSource='watch' WHERE id='n0'") }
            try db.execute(sql: "INSERT INTO watch_migration_incoming VALUES('n0')")
            #expect(try String.fetchOne(db, sql: "SELECT title FROM note WHERE id='n0'") == "Incoming trigger")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM watch_migration_audit") == 2)
            try db.execute(sql: "DELETE FROM note WHERE id='n0'")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM watch_migration_child") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note_ui_state WHERE noteId='n0'") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note_fts WHERE note_fts MATCH 'needle'") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT tombstone FROM sync_dirty WHERE entityType='note' AND localId='n0'") == 1)
        }
    }

    @Test func receiptsAreUniquePerEpochAndOutliveNotes() throws {
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue)
        let recordedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO watch_command_receipt(epoch,commandID,requestMetadata,result,recordedAt) VALUES('a','command','{}',X'01',?)", arguments: [recordedAt])
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: "INSERT INTO watch_command_receipt(epoch,commandID,requestMetadata,result,recordedAt) VALUES('a','command','other',X'02',?)", arguments: [recordedAt])
            }
            try db.execute(sql: "INSERT INTO watch_command_receipt(epoch,commandID,requestMetadata,result,recordedAt) VALUES('b','command','{}',X'01',?)", arguments: [recordedAt])
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: "INSERT INTO watch_command_receipt(epoch,commandID,requestMetadata,result) VALUES('c','missing-time','{}',X'01')")
            }
            #expect(try Date.fetchOne(db, sql: "SELECT recordedAt FROM watch_command_receipt WHERE epoch='a'") == recordedAt)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM watch_command_receipt") == 2)
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(watch_command_receipt)").isEmpty)
        }
    }

    // Both pinned builds use the same Database.swift, NoteSnapshots.swift and GRDB 7.11.1.
    @Test(arguments: ["7fcc0ee5", "455d0ca0"])
    func legacyGUIOpenPreservesV20FixtureAndStrictOpenRecognizesNewerSchema(build: String) throws {
        let tmp = try TempPaths()
        let fixture = try AppDatabase(path: tmp.paths.database)
        func contents(_ db: Database) throws -> [String: [Row]] {
            var result: [String: [Row]] = [:]
            for name in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name") {
                let quoted = "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                result[name] = try Row.fetchAll(db, sql: "SELECT * FROM \(quoted)")
            }
            return result
        }
        try fixture.pool.write { db in
            try db.execute(sql: """
                INSERT INTO note(id,text,createdAt,modifiedAt,captureSource) VALUES('fixture','Voice note',100,200,'voice');
                INSERT INTO note_snapshot(id,noteId,takenAt,text) VALUES('snapshot','fixture',200,'Voice note');
                INSERT INTO watch_command_receipt(epoch,commandID,requestMetadata,result,recordedAt)
                VALUES('epoch','command','{}',X'01','2026-11-06 00:00:00.000');
                """)
        }
        let before = try fixture.pool.read { try contents($0) }
        let schemaBefore = try fixture.pool.read { try SchemaSnapshotTests.dump($0) }
        try fixture.pool.close()

        var registered = DatabaseMigrator()
        let legacyIDs = Array(SchemaSnapshotTests.frozen.prefix(while: { $0 != "v20-watch-capture" }))
        #expect(legacyIDs.count == 21 && legacyIDs.last == "v19-note-type", "Pinned migration list for \(build)")
        for id in legacyIDs {
            registered.registerMigration(id) { _ in
                throw DatabaseError(resultCode: .SQLITE_ERROR, message: "An already-applied legacy migration ran")
            }
        }
        let legacy = registered
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { try $0.execute(sql: "PRAGMA secure_delete=ON") }
        let opened = try DatabasePool(path: tmp.paths.database.path, configuration: configuration)
        defer { try? opened.close() }
        // Exact GUI init sequence: migrate, then repair existing inconsistent snapshots.
        try legacy.migrate(opened)
        let repair = try opened.write { try NoteSnapshots.repairInconsistent(in: $0) }
        #expect(repair.isEmpty)
        let after = try opened.read { try contents($0) }
        let schemaAfter = try opened.read { try SchemaSnapshotTests.dump($0) }
        #expect(after == before, "Legacy GUI \(build) must preserve every fixture table")
        #expect(schemaAfter == schemaBefore)
        // CLI/MCP openExisting deliberately refuses this schema before any application write.
        let superseded = try opened.read { try legacy.hasBeenSuperseded($0) }
        #expect(superseded)
    }
}
