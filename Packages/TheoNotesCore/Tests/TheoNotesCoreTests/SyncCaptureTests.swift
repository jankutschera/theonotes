// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct SyncCaptureTests {
    private let types: Set<String> = ["note", "attachment", "tagPreference", "setting", "externalRef", "keyBundle"]

    private func seed(_ db: Database) throws {
        try db.execute(sql: """
            INSERT INTO note(id,text,createdAt,modifiedAt) VALUES('note','before',0,0);
            INSERT INTO attachment(id,noteId,filename,filenameKey,createdAt,updatedAt) VALUES('attachment','note','file','file',0,0);
            INSERT INTO tag(id,pathKey,displayPath) VALUES('tag','tag','tag');
            INSERT INTO setting(key,value) VALUES('hideMarkdown','false');
            INSERT INTO external_ref(source,externalId,noteId) VALUES('source','external','note');
            INSERT INTO crypto_envelope(id,envelope) VALUES(1,X'00');
            """)
    }
    private func edit(_ db: Database) throws {
        try db.execute(sql: """
            UPDATE note SET text='after' WHERE id='note';
            UPDATE attachment SET ocrText='recognized' WHERE id='attachment';
            UPDATE tag SET iconName='star' WHERE id='tag';
            UPDATE setting SET value='true' WHERE key='hideMarkdown';
            UPDATE external_ref SET lastSeenHash='changed' WHERE source='source';
            UPDATE crypto_envelope SET envelope=X'01' WHERE id=1;
            """)
    }
    private func delete(_ db: Database) throws {
        try db.execute(sql: """
            DELETE FROM attachment;
            DELETE FROM tag;
            DELETE FROM setting WHERE key='hideMarkdown';
            DELETE FROM external_ref;
            DELETE FROM crypto_envelope;
            DELETE FROM note;
            """)
    }
    private func markers(_ db: Database) throws -> [Row] {
        try Row.fetchAll(db, sql: "SELECT * FROM sync_dirty")
    }
    private func withLibrary(_ body: (AppDatabase, SyncQueue) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-capture-\(UUID())")
        let paths = AppPaths(root: root)
        try paths.createDirectories()
        let database = try AppDatabase(path: paths.database)
        defer { try? database.pool.close(); try? FileManager.default.removeItem(at: root) }
        try body(database, SyncQueue(database: database))
    }

    @Test func configuredLibraryCapturesAllSemanticTypesBeforeUploadsAreEnabled() throws {
        try withLibrary { database, queue in
            try queue.configure(accountID: "account")
            #expect(try !queue.isEnabled())
            try database.pool.write { db in
                try seed(db)
                let inserted = try markers(db)
                #expect(Set(inserted.map { $0["entityType"] as String }) == types)
                #expect(inserted.allSatisfy { ($0["tombstone"] as Bool) == false })
                try db.execute(sql: "DELETE FROM sync_dirty")
                try edit(db)
                let updated = try markers(db)
                #expect(Set(updated.map { $0["entityType"] as String }) == types)
                #expect(updated.allSatisfy { ($0["tombstone"] as Bool) == false })
                try db.execute(sql: "DELETE FROM sync_dirty")
                try delete(db)
                let deleted = try markers(db)
                #expect(Set(deleted.map { $0["entityType"] as String }) == types)
                #expect(deleted.allSatisfy { ($0["tombstone"] as Bool) == true })
            }
            #expect(throws: SyncQueueError.notEnabled) {
                try queue.prepareNext(vaultKey: SymmetricKey(size: .bits256))
            }
            #expect(try queue.pendingMutations().isEmpty)
            #expect(try !queue.isEnabled())
        }
    }

    @Test func unconfiguredAndRemoteApplyingWritesDoNotCapture() throws {
        for configured in [false, true] {
            try withLibrary { database, queue in
                if configured { try queue.configure(accountID: "account") }
                try database.pool.write { db in
                    if configured { try db.execute(sql: "UPDATE sync_control SET applying=1 WHERE id=1") }
                    try seed(db)
                    try db.execute(sql: "INSERT INTO note_pin(noteId,tagId) VALUES('note','tag')")
                    try db.execute(sql: "DELETE FROM note_pin")
                    try db.execute(sql: "INSERT INTO staging_batch(id,noteId,replacing,filenames,createdAt) VALUES('batch','note',0,'[]',0)")
                    try edit(db)
                    try delete(db)
                    #expect(try markers(db).isEmpty)
                }
            }
        }
    }

    @Test func pinsStagedFilesAndAttachmentPurgeCaptureWhileUploadsWait() throws {
        try withLibrary { database, queue in
            try queue.configure(accountID: "account")
            try database.pool.write { db in
                try seed(db)
                try db.execute(sql: "DELETE FROM sync_dirty")
                try db.execute(sql: "INSERT INTO note_pin(noteId,tagId) VALUES('note','tag')")
                #expect(try String.fetchAll(db, sql: "SELECT entityType FROM sync_dirty") == ["note"])
                try db.execute(sql: "DELETE FROM sync_dirty; DELETE FROM note_pin")
                #expect(try String.fetchAll(db, sql: "SELECT entityType FROM sync_dirty") == ["note"])
                try db.execute(sql: "DELETE FROM sync_dirty")
                try db.execute(sql: "INSERT INTO staging_batch(id,noteId,replacing,filenames,createdAt) VALUES('batch','note',0,'[]',0)")
                #expect(try String.fetchAll(db, sql: "SELECT entityType FROM sync_dirty") == ["attachment"])
                try db.execute(sql: "DELETE FROM sync_dirty; DELETE FROM attachment")
                #expect(Set(try String.fetchAll(db, sql: "SELECT entityType FROM sync_dirty")) == ["note", "attachment"])
                #expect(try Bool.fetchOne(db, sql: "SELECT tombstone FROM sync_dirty WHERE entityType='attachment'") == true)
                #expect(try Bool.fetchOne(db, sql: "SELECT tombstone FROM sync_dirty WHERE entityType='note'") == false)
            }
        }
    }

    @Test func configurationIsIdempotentAndCannotSwitchAccountsOrLoseCapturedWork() throws {
        try withLibrary { database, queue in
            try queue.configure(accountID: "account")
            try database.pool.write { try seed($0) }
            let before = try queue.pendingCount()
            try queue.configure(accountID: "account")
            #expect(try queue.pendingCount() == before)
            #expect(throws: SyncQueueError.accountMismatch) { try queue.configure(accountID: "other") }
            #expect(try queue.pendingCount() == before)
            #expect(try !queue.isEnabled())
            #expect(try database.pool.read { try String.fetchOne($0, sql: "SELECT accountId FROM sync_control") } == "account")
        }
    }

    @Test func upgradingV13PreservesExistingNotesAndDirtyGenerations() throws {
        let database = try DatabaseQueue()
        try Migrations.migrator.migrate(database, upTo: "v13-sync-attachment-purge")
        try database.write { db in
            try db.execute(sql: "UPDATE sync_control SET accountId='account',enabled=0 WHERE id=1")
            try seed(db)
            try db.execute(sql: "INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('note','note',7,0),('setting','deleted',4,1)")
        }
        try Migrations.migrator.migrate(database)
        try database.write { db in
            #expect(try String.fetchOne(db, sql: "SELECT text FROM note WHERE id='note'") == "before")
            #expect(try Int.fetchOne(db, sql: "SELECT generation FROM sync_dirty WHERE entityType='note'") == 7)
            #expect(try Int.fetchOne(db, sql: "SELECT generation FROM sync_dirty WHERE localId='deleted' AND tombstone=1") == 4)
            #expect(try Bool.fetchOne(db, sql: "SELECT enabled FROM sync_control") == false)
            try edit(db)
            #expect(try Int.fetchOne(db, sql: "SELECT generation FROM sync_dirty WHERE entityType='note'") == 8)
            #expect(Set(try String.fetchAll(db, sql: "SELECT DISTINCT entityType FROM sync_dirty")) == types)
        }
    }
}
