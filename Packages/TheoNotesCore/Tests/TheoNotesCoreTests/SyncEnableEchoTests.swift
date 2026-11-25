// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

struct SyncEnableEchoTests {
    private func seed(_ library: SyncMaterializerTests.Library, serverRevision: Int64?) throws {
        try library.queue.applyRemote(cursor: 0) { db in
            try db.execute(sql: """
                INSERT INTO note(id,text,createdAt,modifiedAt) VALUES('note','downloaded',1,1);
                INSERT INTO attachment(id,noteId,filename,filenameKey,createdAt,updatedAt)
                  VALUES('attachment','note','file.txt','file.txt',1,1);
                INSERT INTO tag(id,pathKey,displayPath) VALUES('tag','work','Work');
                INSERT INTO setting(key,value) VALUES('hideMarkdown','false');
                INSERT INTO external_ref(source,externalId,noteId) VALUES('source','external','note');
                INSERT INTO crypto_envelope(id,envelope) VALUES(1,X'01');
                """)
            if let serverRevision {
                for (type, id) in [
                    ("note", "note"), ("attachment", "attachment"), ("tagPreference", "tag"),
                    ("setting", "hideMarkdown"), ("externalRef", "[\"source\",\"external\"]"),
                    ("keyBundle", "lock-vault"),
                ] {
                    try db.execute(sql: "INSERT INTO sync_entity_state(entityType,localId,entityId,serverRevision) VALUES(?,?,?,?)",
                        arguments: [type, id, type + "-remote", serverRevision])
                }
            }
        }
    }

    @Test(arguments: [nil, Int64(0), Int64(2)])
    func enableSeedsOnlyEntitiesWithoutAcceptedServerRevision(serverRevision: Int64?) throws {
        let library = try SyncMaterializerTests.Library(enabled: false)
        defer { library.cleanup() }
        try seed(library, serverRevision: serverRevision)
        #expect(try library.queue.pendingCount() == 0)
        try library.queue.enable(accountID: "account")
        #expect(try library.queue.pendingCount() == (serverRevision == 2 ? 0 : 6))
        try library.queue.enable(accountID: "account")
        #expect(try library.queue.pendingCount() == (serverRevision == 2 ? 0 : 6))
    }

    @Test func preEnableEditsAndTombstonesSurviveForEveryEntityType() throws {
        let library = try SyncMaterializerTests.Library(enabled: false)
        defer { library.cleanup() }
        try seed(library, serverRevision: 2)
        try library.db.pool.write { db in
            try db.execute(sql: """
                UPDATE note SET text='edited' WHERE id='note';
                UPDATE attachment SET ocrText='edited' WHERE id='attachment';
                UPDATE tag SET iconName='star' WHERE id='tag';
                UPDATE setting SET value='true' WHERE key='hideMarkdown';
                UPDATE external_ref SET lastSeenHash='edited';
                UPDATE crypto_envelope SET envelope=X'02';
                DELETE FROM external_ref;
                """)
        }
        func dirty() throws -> [String] {
            try library.db.pool.read { db in
                try String.fetchAll(db, sql: "SELECT entityType || ':' || localId || ':' || generation || ':' || tombstone FROM sync_dirty ORDER BY entityType,localId")
            }
        }
        let before = try dirty()
        #expect(before.count == 6)
        #expect(before.contains("externalRef:[\"source\",\"external\"]:2:1"))
        try library.queue.enable(accountID: "account")
        #expect(try dirty() == before)
    }

    @Test func enablingPreservesPreparedMutationAndItsNewerDirtyGeneration() throws {
        let library = try SyncMaterializerTests.Library(enabled: false)
        defer { library.cleanup() }
        try seed(library, serverRevision: 2)
        try library.db.pool.write { db in
            try db.execute(sql: "UPDATE crypto_envelope SET envelope=X'02'")
        }
        try library.queue.enable(accountID: "account")
        let mutation = try #require(try library.queue.prepareNext(vaultKey: library.key) { _, _ in
            SyncContent(payload: Data("prepared".utf8))
        })
        try library.db.pool.write { db in
            try db.execute(sql: "UPDATE sync_control SET enabled=0; UPDATE crypto_envelope SET envelope=X'03'")
        }
        try library.queue.enable(accountID: "account")
        #expect(try library.queue.pendingMutations() == [mutation])
        try library.queue.accept(SyncEntity(mutation: mutation, revision: 3, sequence: 3, receivedAt: 3))
        #expect(try library.queue.pendingCount() == 1)
        #expect(try library.db.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT generation FROM sync_dirty WHERE entityType='keyBundle'")
        } == 2)
    }
}
