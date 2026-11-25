// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct SyncAttachmentCacheAliasTests {
    @Test func metadataOnlyEditMustNotReusePreviouslyAcceptedGenerationOneCache() async throws {
        let library = try SyncMaterializerTests.Library()
        defer { library.cleanup() }
        let fixtures = SyncInitialCaptureRegressionTests()
        let blobs = SyncInitialCaptureRegressionTests.BlobStore(directory: library.paths.root.appendingPathComponent("shared-blobs"))
        let server = SyncEngineTests.Server()
        let engine = fixtures.engine(library, server: server, blobs: blobs)
        let note = try library.store.create(text: "# File\n" + AttachmentMarkdown.link(for: "file.txt"))
        _ = try AttachmentStore(paths: library.paths, database: library.db).add(data: Data("unchanged file".utf8), filename: "file.txt", to: note.id)
        _ = try await engine.synchronize()
        let attachmentID = try #require(try await library.db.pool.read {
            try String.fetchOne($0, sql: "SELECT id FROM attachment WHERE noteId=?", arguments: [note.id])
        })
        // A real metadata update starts a new dirty generation after acceptance removed the old one.
        try await library.db.pool.write { try setDerivedMetadata(200, attachmentID: attachmentID, in: $0) }
        let generations = try await library.db.pool.read { db -> (dirty: Int64, cached: Int64) in
            let row = try #require(try Row.fetchOne(db, sql: """
                SELECT d.generation AS dirty,c.generation AS cached FROM sync_dirty d
                JOIN sync_attachment_cache c ON c.attachmentId=d.localId
                WHERE d.entityType='attachment' AND d.localId=?
                """, arguments: [attachmentID]))
            return (row["dirty"], row["cached"])
        }
        #expect(generations.dirty == 1)
        #expect(generations.cached == 1)
        let preparer = SyncAttachmentPreparer(database: library.db, paths: library.paths, accountID: "account", vaultKey: library.key)
        _ = try await preparer.preparePending()
        let queued = try #require(try library.queue.prepareNext(vaultKey: library.key))
        let reader = SyncPayloadReader(accountID: "account", vaultKey: library.key,
            blobs: SyncInitialCaptureRegressionTests.Blobs(database: library.db, paths: library.paths, remote: blobs))
        let entity = SyncEntity(mutation: queued, revision: 2, sequence: 1, receivedAt: 1)
        guard case .attachment(let payload) = try await reader.read(entity) else {
            Issue.record("Expected new attachment descriptor"); return
        }
        #expect(payload.ocrText == "derived 200")
        #expect(payload.updatedAt == 200_000)
        #expect(payload.uti == "public.derived-200" && payload.width == 200 && payload.height == 201)
        await engine.shutdown()
    }

    @Test func unchangedCacheHitKeepsCiphertextAndNoteVersionPins() async throws {
        let library = try SyncMaterializerTests.Library()
        defer { library.cleanup() }
        let note = try library.store.create(text: "# File\n" + AttachmentMarkdown.link(for: "file.txt"))
        _ = try AttachmentStore(paths: library.paths, database: library.db).add(data: Data("same bytes".utf8), filename: "file.txt", to: note.id)
        let id = try #require(try await library.db.pool.read {
            try String.fetchOne($0, sql: "SELECT id FROM attachment WHERE noteId=?", arguments: [note.id])
        })
        let preparer = SyncAttachmentPreparer(database: library.db, paths: library.paths, accountID: "account", vaultKey: library.key)
        #expect(try await preparer.prepare(id: id))
        let before = try #require(try await library.db.pool.read {
            try Data.fetchOne($0, sql: "SELECT encryptedDescriptor FROM sync_attachment_cache WHERE attachmentId=?", arguments: [id])
        })
        let blobCount = try await library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_blob_state") }
        #expect(try await preparer.prepare(id: id))
        #expect(try await library.db.pool.read {
            try Data.fetchOne($0, sql: "SELECT encryptedDescriptor FROM sync_attachment_cache WHERE attachmentId=?", arguments: [id])
        } == before)
        #expect(try await library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_blob_state") } == blobCount)
        let noteContent = try await library.db.pool.read { db in
            try SyncNoteSnapshot.capture(SyncDirty(type: .note, localID: note.id, generation: 1, tombstone: false),
                accountID: "account", vaultKey: library.key, in: db)
        }
        let payload = try SyncPayloadCodec.decode(SyncNotePayload.self, from: #require(noteContent.payload))
        #expect(payload.attachmentSnapshots?[id]?.id == id)
    }

    @Test func cacheHitRejectsMetadataChangedBeforeCommitAndRetriesFreshSnapshot() async throws {
        let library = try SyncMaterializerTests.Library()
        defer { library.cleanup() }
        let note = try library.store.create(text: "# File\n" + AttachmentMarkdown.link(for: "file.txt"))
        _ = try AttachmentStore(paths: library.paths, database: library.db).add(data: Data("same bytes".utf8), filename: "file.txt", to: note.id)
        let id = try #require(try await library.db.pool.read {
            try String.fetchOne($0, sql: "SELECT id FROM attachment WHERE noteId=?", arguments: [note.id])
        })
        let preparer = SyncAttachmentPreparer(database: library.db, paths: library.paths, accountID: "account", vaultKey: library.key)
        #expect(try await preparer.prepare(id: id))
        await #expect(throws: SyncQueueError.snapshotUnavailable) {
            try await preparer.prepare(id: id) {
                try library.db.pool.write { try setDerivedMetadata(300, attachmentID: id, in: $0) }
            }
        }
        #expect(try await preparer.prepare(id: id))
        let content = try await library.db.pool.read { db in
            let generation = try #require(try Int64.fetchOne(db, sql: "SELECT generation FROM sync_dirty WHERE entityType='attachment' AND localId=?", arguments: [id]))
            return try SyncAttachmentPreparer.capture(SyncDirty(type: .attachment, localID: id, generation: generation, tombstone: false),
                accountID: "account", vaultKey: library.key, in: db)
        }
        let payload = try SyncPayloadCodec.decode(SyncAttachmentPayload.self, from: #require(content.payload))
        #expect(payload.ocrText == "derived 300" && payload.updatedAt == 300_000)
    }

    private func setDerivedMetadata(_ value: Int, attachmentID: String, in db: Database) throws {
        try db.execute(sql: """
            UPDATE attachment SET ocrText=?,updatedAt=?,uti=?,width=?,height=? WHERE id=?
            """, arguments: ["derived \(value)", Date(timeIntervalSince1970: Double(value)),
                              "public.derived-\(value)", value, value + 1, attachmentID])
    }

}
