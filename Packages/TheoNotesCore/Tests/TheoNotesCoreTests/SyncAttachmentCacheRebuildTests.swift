// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct SyncAttachmentCacheRebuildTests {
    @Test(arguments: ["aead", "json", "version", "identity", "hash", "missingSource", "database", "cancel"])
    func corruptDescriptorRebuildsAndPublishesFreshPins(corruption: String) async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try paths.createDirectories()
        let database = try AppDatabase(path: paths.database)
        defer { try? database.pool.close(); try? FileManager.default.removeItem(at: paths.root) }
        let store = NoteStore(db: database, notifier: nil, paths: paths)
        let note = try store.create(text: "![](real.txt)")
        let bytes = Data("verified real attachment".utf8)
        _ = try AttachmentStore(paths: paths, database: database).add(data: bytes, filename: "real.txt", to: note.id)
        let queue = SyncQueue(database: database), key = SymmetricKey(size: .bits256)
        try queue.enable(accountID: "account")
        let preparer = SyncAttachmentPreparer(database: database, paths: paths, accountID: "account", vaultKey: key)
        #expect(try await preparer.preparePending() == 1)
        let cached = try await database.pool.read { db in
            let row = try #require(try Row.fetchOne(db, sql: "SELECT * FROM sync_attachment_cache"))
            return (row["attachmentId"] as String, row["blobHash"] as String, row["encryptedDescriptor"] as Data)
        }
        let id = cached.0, oldHash = cached.1
        let context = try SyncWire.cipherContext(accountID: "account", type: .attachment, entityID: id)
        var sealed = cached.2
        if ["aead", "missingSource", "database", "cancel"].contains(corruption) { sealed[sealed.count - 1] ^= 1 }
        else {
            let plain = try NoteCipher.open(sealed, vaultKey: key, context: context + ":cache")
            var json = try #require(JSONSerialization.jsonObject(with: plain) as? [String: Any])
            if corruption == "version" { json["version"] = 999 }
            if corruption == "identity" { json["id"] = UUIDv7.make() }
            if corruption == "hash" { json["blobHash"] = String(repeating: "a", count: 64) }
            sealed = try NoteCipher.seal(corruption == "json" ? Data("not JSON".utf8) : JSONSerialization.data(withJSONObject: json),
                vaultKey: key, context: context + ":cache")
        }
        let damaged = sealed
        try await database.pool.write { try $0.execute(sql: "UPDATE sync_attachment_cache SET encryptedDescriptor=?", arguments: [damaged]) }
        if corruption == "missingSource" {
            try FileManager.default.removeItem(at: paths.attachments.appendingPathComponent(note.id + "/real.txt"))
            await #expect(throws: SyncQueueError.snapshotUnavailable) { try await preparer.prepare(id: id) }
            let independent = try store.create(text: "# Independent")
            let next = try #require(try queue.prepareNext(vaultKey: key))
            #expect(next.entityType == .note && next.entityId == independent.id)
            #expect(try queue.pendingMutations().contains { $0.entityId == independent.id })
        } else if corruption == "database" {
            try await database.pool.write { try $0.execute(sql: "CREATE TRIGGER reject_cache_update BEFORE UPDATE ON sync_attachment_cache BEGIN SELECT RAISE(ABORT, 'test database failure'); END") }
            await #expect(throws: DatabaseError.self) { try await preparer.prepare(id: id) }
        } else if corruption == "cancel" {
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await preparer.prepare(id: id)
            }
            await #expect(throws: CancellationError.self) { try await task.value }
        }
        if ["missingSource", "database", "cancel"].contains(corruption) {
            let unchanged = try await database.pool.read { try Data.fetchOne($0, sql: "SELECT encryptedDescriptor FROM sync_attachment_cache") }
            #expect(unchanged == damaged)
            #expect(try await database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_blob_state") } == 1)
            return
        }
        #expect(try await preparer.preparePending() == 1)
        let rebuilt = try await database.pool.read { db in
            let row = try #require(try Row.fetchOne(db, sql: "SELECT c.*,b.localPath FROM sync_attachment_cache c JOIN sync_blob_state b ON b.hash=c.blobHash"))
            let plain = try NoteCipher.open(row["encryptedDescriptor"], vaultKey: key, context: context + ":cache")
            return (try SyncPayloadCodec.decode(SyncAttachmentPayload.self, from: plain), row["localPath"] as String)
        }
        try rebuilt.0.validate()
        #expect(rebuilt.0.blobHash != oldHash)
        #expect(rebuilt.0.fileHash == SyncWire.hash(bytes))
        let output = paths.root.appendingPathComponent("decrypted")
        try ChunkedCipher.decrypt(input: paths.root.appendingPathComponent(rebuilt.1), output: output, keyEncryptionKey: key, context: context)
        #expect(try Data(contentsOf: output) == bytes)
        var mutations: [SyncMutation] = []
        while let mutation = try queue.prepareNext(vaultKey: key) {
            mutations.append(mutation)
            try queue.accept(SyncEntity(mutation: mutation, revision: mutation.parentRevision + 1,
                sequence: Int64(mutations.count), receivedAt: 1))
        }
        #expect(mutations.contains { $0.entityType == .attachment && $0.blobRefs == [rebuilt.0.blobHash] })
        #expect(mutations.contains { $0.entityType == .note && $0.blobRefs == [rebuilt.0.blobHash] })
        #expect(try queue.pendingCount() == 0)
    }
    @Test(arguments: ["aead", "json", "version"]) func corruptCleanAttachmentDescriptorDoesNotBlockIndependentNotes(corruption: String) async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try paths.createDirectories()
        let database = try AppDatabase(path: paths.database)
        defer { try? database.pool.close(); try? FileManager.default.removeItem(at: paths.root) }
        let store = NoteStore(db: database, notifier: nil, paths: paths)
        let note = try store.create(text: "![](real.txt)")
        _ = try AttachmentStore(paths: paths, database: database).add(data: Data("source".utf8), filename: "real.txt", to: note.id)
        let queue = SyncQueue(database: database), key = SymmetricKey(size: .bits256)
        try queue.enable(accountID: "account")
        let preparer = SyncAttachmentPreparer(database: database, paths: paths, accountID: "account", vaultKey: key)
        #expect(try await preparer.preparePending() == 1)
        let attachment = try #require(try queue.prepareNext(vaultKey: key))
        #expect(attachment.entityType == .attachment)
        try queue.accept(SyncEntity(mutation: attachment, revision: 1, sequence: 1, receivedAt: 1))
        try await database.pool.write { db in
            let data = try #require(try Data.fetchOne(db, sql: "SELECT encryptedDescriptor FROM sync_attachment_cache"))
            let broken: Data
            if corruption == "aead" {
                var altered = data
                altered[altered.count - 1] ^= 1
                broken = altered
            } else {
                let id = attachment.entityId
                let context = try SyncWire.cipherContext(accountID: "account", type: .attachment, entityID: id) + ":cache"
                let plain = try NoteCipher.open(data, vaultKey: key, context: context)
                var object = try #require(try JSONSerialization.jsonObject(with: plain) as? [String: Any])
                if corruption == "version" { object["version"] = 999 }
                let replacement = corruption == "json" ? Data("bad JSON".utf8) : try JSONSerialization.data(withJSONObject: object)
                broken = try NoteCipher.seal(replacement, vaultKey: key, context: context)
            }
            try db.execute(sql: "UPDATE sync_attachment_cache SET encryptedDescriptor=?", arguments: [broken])
        }
        let independent = try store.create(text: "# Independent")
        let next = try #require(try queue.prepareNext(vaultKey: key))
        #expect(next.entityType == .note && next.entityId == independent.id)
        #expect(try await database.pool.read { try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM sync_dirty WHERE entityType='note' AND localId=?)", arguments: [note.id]) } == true)
    }

    @Test func cachedBlobReadErrorRebuildsAndCancellationPropagates() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try paths.createDirectories()
        let database = try AppDatabase(path: paths.database)
        defer { try? database.pool.close(); try? FileManager.default.removeItem(at: paths.root) }
        let store = NoteStore(db: database, notifier: nil, paths: paths)
        let note = try store.create(text: "![](real.txt)")
        let bytes = Data("real source".utf8)
        _ = try AttachmentStore(paths: paths, database: database).add(data: bytes, filename: "real.txt", to: note.id)
        let key = SymmetricKey(size: .bits256)
        let queue = SyncQueue(database: database)
        try queue.enable(accountID: "account")
        let preparer = SyncAttachmentPreparer(database: database, paths: paths, accountID: "account", vaultKey: key)
        #expect(try await preparer.preparePending() == 1)
        let id = try #require(try await database.pool.read { try String.fetchOne($0, sql: "SELECT attachmentId FROM sync_attachment_cache") })
        await #expect(throws: CancellationError.self) { try await preparer.prepare(id: id, verifyCached: { _, _, _, _ in throw CancellationError() }) }
        #expect(try await preparer.prepare(id: id, verifyCached: { _, _, _, _ in throw POSIXError(.EIO) }))
        let mutation = try #require(try queue.prepareNext(vaultKey: key))
        #expect(mutation.entityType == .attachment && !mutation.blobRefs.isEmpty)
    }

}
