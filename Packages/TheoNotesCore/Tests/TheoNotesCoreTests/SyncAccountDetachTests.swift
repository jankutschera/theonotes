// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// Leaving a sync account never touches the person's notes (CK-R10, CK-R12): only engine
/// bookkeeping goes, `sync_dirty` stays so a later first sync still publishes everything.
@Suite struct SyncAccountDetachTests {
    /// A library with a tagged note, an attachment and a few queue rows.
    struct Fixture {
        let library: SyncMaterializerTests.Library
        let backupID: String
        let noteID: String
        let attachmentBytes = Data("attachment bytes \u{1F4CE}".utf8)
        var db: AppDatabase { library.db }

        init() throws {
            library = try SyncMaterializerTests.Library()
            let note = try library.store.create(text: "# Detach me\n#work/plans\nBody [file](f.txt)")
            noteID = note.id
            _ = try AttachmentStore(paths: library.paths, database: library.db).add(data: attachmentBytes, filename: "f.txt", to: note.id)
            _ = try library.store.create(text: "second note #work")
            while try library.queue.prepareNext(vaultKey: library.key) != nil {}      // fills outbox, entity state, blob state
            _ = try LibraryBackup(database: library.db, paths: library.paths).createRolling()
            backupID = try #require(try LibraryBackup(database: library.db, paths: library.paths).localBackups().first).id
        }
        func cleanup() { library.cleanup() }

        /// Everything the person owns, byte for byte.
        func ownedContent() throws -> [String] {
            let rows = try db.pool.read { db -> [String] in
                try Row.fetchAll(db, sql: "SELECT id, text, title, revision FROM note ORDER BY id").map { "note|\($0["id"] as String)|\($0["text"] as String)|\($0["revision"] as Int)" }
                + Row.fetchAll(db, sql: "SELECT id, noteId, filename, sha256, byteSize FROM attachment ORDER BY id").map { "att|\($0["id"] as String)|\($0["filename"] as String)|\($0["sha256"] as String? ?? "")|\($0["byteSize"] as Int)" }
                + Row.fetchAll(db, sql: "SELECT displayPath, pathKey FROM tag ORDER BY pathKey").map { "tag|\($0["displayPath"] as String)|\($0["pathKey"] as String)" }
                + Row.fetchAll(db, sql: "SELECT noteId, tagId FROM note_tag ORDER BY noteId, tagId").map { "nt|\($0["noteId"] as String)|\($0["tagId"] as String)" }
            }
            var files: [String] = []
            if let walker = FileManager.default.enumerator(at: library.paths.attachments, includingPropertiesForKeys: [.isRegularFileKey]) {
                for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    files.append("file|\(url.path.replacingOccurrences(of: library.paths.attachments.path, with: ""))|\(try Data(contentsOf: url).base64EncodedString())")
                }
            }
            return rows + files.sorted()
        }

        func dirty() throws -> [String] {
            try db.pool.read { db in
                try Row.fetchAll(db, sql: "SELECT entityType, localId, generation, tombstone FROM sync_dirty ORDER BY 1, 2").map {
                    "\($0["entityType"] as String)|\($0["localId"] as String)|\($0["generation"] as Int)|\($0["tombstone"] as Int)"
                }
            }
        }

        func count(_ table: String) throws -> Int { try db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)")! } }
        func control() throws -> Row { try db.pool.read { try Row.fetchOne($0, sql: "SELECT enabled, applying, accountId, backend FROM sync_control")! } }
    }

    @Test func aCloudflareDetachClearsTheQueueAndLeavesEveryNoteAttachmentTagAndTheJournalByteIdentical() throws {
        let f = try Fixture(); defer { f.cleanup() }
        #expect(try f.control()["backend"] as String == "cloudflare")
        #expect(try f.count("sync_outbox") > 0)
        #expect(try f.count("sync_entity_state") > 0)
        let owned = try f.ownedContent(), dirty = try f.dirty()
        #expect(owned.contains { $0.hasPrefix("file|") } && owned.contains { $0.hasPrefix("tag|") })

        try SyncAccountDetach.detach(database: f.db, expectedBackend: .cloudflare, verifiedBackupID: f.backupID)

        #expect(try f.ownedContent() == owned)
        #expect(try f.dirty() == dirty)
        for table in SyncAccountDetach.cloudflareClearedTables { #expect(try f.count(table) == 0, "\(table)") }
        let control = try f.control()
        #expect(control["enabled"] as Bool == false && control["accountId"] as String? == nil && control["backend"] as String == "none")
        #expect(try f.db.pool.read { try Int.fetchOne($0, sql: "SELECT sequence FROM sync_cursor") } == 0)
    }

    @Test func detachRequiresABackupTheLibraryKnows() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let owned = try f.ownedContent()
        for id in ["", "not-a-backup"] {
            #expect(throws: SyncAccountDetachError.backupNotVerified) {
                try SyncAccountDetach.detach(database: f.db, expectedBackend: .cloudflare, verifiedBackupID: id)
            }
        }
        #expect(try f.control()["backend"] as String == "cloudflare")
        #expect(try f.count("sync_outbox") > 0)
        #expect(try f.ownedContent() == owned)
    }

    @Test func detachIsRefusedMidPrivacyTransition() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.db.pool.write {
            try $0.execute(sql: "INSERT INTO privacy_transition(noteId,targetLocked,filenames) VALUES(?,1,'[]')", arguments: [f.noteID])
        }
        let outbox = try f.count("sync_outbox")
        #expect(throws: SyncAccountDetachError.privacyTransitionInProgress) {
            try SyncAccountDetach.detach(database: f.db, expectedBackend: .cloudflare, verifiedBackupID: f.backupID)
        }
        #expect(try f.control()["backend"] as String == "cloudflare")
        #expect(try f.count("sync_outbox") == outbox)
    }

    @Test func detachIsRefusedWhileASyncApplyIsRunning() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.db.pool.write { try $0.execute(sql: "UPDATE sync_control SET applying=1") }
        #expect(throws: SyncAccountDetachError.applying) {
            try SyncAccountDetach.detach(database: f.db, expectedBackend: .cloudflare, verifiedBackupID: f.backupID)
        }
        #expect(try f.control()["accountId"] as String? == "account")
    }

    @Test func detachChecksTheBackendTheCallerThinksItIsLeaving() throws {
        let f = try Fixture(); defer { f.cleanup() }
        #expect(throws: SyncAccountDetachError.backendMismatch(expected: .cloudkit, actual: .cloudflare)) {
            try SyncAccountDetach.detach(database: f.db, expectedBackend: .cloudkit, verifiedBackupID: f.backupID)
        }
        #expect(throws: SyncAccountDetachError.nothingToDetach) {
            try SyncAccountDetach.detach(database: f.db, expectedBackend: .none, verifiedBackupID: f.backupID)
        }
        #expect(try f.control()["backend"] as String == "cloudflare")
    }

    @Test func aCloudKitDetachClearsEveryCkTableBumpsTheGenerationAndLeavesTheLibraryAndJournal() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        // Re-home the fixture library on CloudKit: detach from Cloudflare first, as a person would.
        try SyncAccountDetach.detach(database: f.db, expectedBackend: .cloudflare, verifiedBackupID: f.backupID)
        let store = CloudSyncStore(database: f.db)
        try store.bind(accountId: "ck-1", containerId: "iCloud.test", zoneName: "TheoNotes", cloudUserHash: "u")
        try store.setZoneState(.created)
        try store.saveEngineState(Data("engine".utf8), accountGeneration: store.generation())
        let entity = CloudEntityRef(entityType: "note", entityId: f.noteID)
        try f.db.pool.write { db in
            try db.execute(sql: "INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('note',?,5,0) ON CONFLICT(entityType,localId) DO UPDATE SET generation=5", arguments: [f.noteID])
            try db.execute(sql: "INSERT INTO ck_record(entityType,entityId,systemFields,ancestor,ver,inc) VALUES('note',?,x'01',x'02',1,'i')", arguments: [f.noteID])
            try db.execute(sql: "INSERT INTO ck_blob_part(hash,part,parts,partBytes,totalBytes,partSha256,state) VALUES('h',0,1,1,1,'s','uploaded')")
            try db.execute(sql: "INSERT INTO sync_entity_state(entityType,localId,entityId) VALUES('note','x','y')")
        }
        try store.insertInflight(CloudInflight(entity: entity, localId: f.noteID, generation: 5, attemptId: "a", baseVer: 0, inc: "i",
                                               sealed: Data("s".utf8), accountGeneration: store.generation()))
        try store.recordSendResult(attemptId: "a", accountGeneration: store.generation(), outcome: .offline)
        try store.storeRemote(CloudRemoteVersion(entity: CloudEntityRef(entityType: "note", entityId: "zz"), inc: "i", ver: 1, sid: "s", systemFields: Data("t".utf8), sealed: Data("c".utf8)))
        try store.quarantine(record: CloudQuarantineRecord(recordName: "e.note.q", reason: "corrupt", rawFields: Data("r".utf8)), pinned: [CloudPinnedAsset(field: "f", path: "/tmp/pinned-x", size: 1, sha256: "a")])
        try store.markMissing(entityType: "note", entityId: f.noteID, reason: "x")
        let owned = try f.ownedContent(), dirty = try f.dirty(), generation = try store.generation()

        let result = try SyncAccountDetach.detach(database: f.db, expectedBackend: .cloudkit, verifiedBackupID: f.backupID)

        #expect(result.pinnedFilesToRemove == ["/tmp/pinned-x"])
        for table in SyncAccountDetach.cloudKitClearedTables + SyncAccountDetach.sharedTables { #expect(try f.count(table) == 0, "\(table)") }
        #expect(try store.generation() == generation + 1)
        let state = try f.db.pool.read { try Row.fetchOne($0, sql: "SELECT * FROM ck_state")! }
        #expect(state["accountId"] as String? == nil && state["zoneState"] as String == "unknown" && state["engineState"] as Data? == nil)
        #expect(try store.backend() == .none)
        #expect(try f.ownedContent() == owned)
        #expect(try f.dirty() == dirty)
    }

    @Test func everyCloudKitTableIsCoveredByDetach() throws {
        let db = try AppDatabase.inMemory()
        let tables = try db.pool.read { try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'ck\\_%' ESCAPE '\\' ORDER BY name") }
        #expect(tables == (SyncAccountDetach.cloudKitClearedTables + ["ck_state"]).sorted())
    }
}
