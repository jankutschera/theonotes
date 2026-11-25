// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct SyncAttachmentTests {
    @Test func purgingRetainedAttachmentPublishesNoteWithoutOldBlobPins() async throws {
        let library = try Library(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Retained\n![File](retained.txt)")
        _ = try AttachmentStore(paths: library.paths, database: library.db)
            .add(data: Data("old bytes".utf8), filename: "retained.txt", to: note.id)
        _ = try library.store.updateText(id: note.id, text: "# Retained\nNo link",
            expectedRevision: #require(try library.store.note(id: note.id)).revision)
        let attachmentID = try library.attachment(note)
        try library.queue.enable(accountID: "account")
        #expect(try await library.preparer.preparePending() == 1)
        let oldHash = try library.cached(attachmentID).0.blobHash
        var sequence: Int64 = 0
        var original: SyncMutation?
        while let mutation = try library.queue.prepareNext(vaultKey: library.key) {
            if mutation.entityType == .note { original = mutation }
            sequence += 1
            try library.queue.accept(SyncEntity(mutation: mutation, revision: mutation.parentRevision + 1,
                sequence: sequence, receivedAt: 1))
        }
        #expect(try #require(original).blobRefs.contains(oldHash))
        let modifiedAt = try library.store.note(id: note.id)?.modifiedAt
        #expect(library.store.removeUnreferencedAttachments(noteId: note.id,
            now: .now.addingTimeInterval(NoteStore.attachmentGracePeriod + 60)) == ["retained.txt"])
        var replacement: SyncMutation?, deletion: SyncMutation?
        while let mutation = try library.queue.prepareNext(vaultKey: library.key) {
            if mutation.entityType == .note { replacement = mutation }
            if mutation.entityType == .attachment { deletion = mutation }
            sequence += 1
            try library.queue.accept(SyncEntity(mutation: mutation, revision: mutation.parentRevision + 1,
                sequence: sequence, receivedAt: 2))
        }
        #expect(try #require(deletion).tombstone)
        let refreshed = try #require(replacement)
        #expect(!refreshed.tombstone && refreshed.blobRefs.isEmpty)
        let context = try SyncWire.cipherContext(accountID: "account", type: .note, entityID: note.id)
        let payload = try SyncPayloadCodec.decode(SyncNotePayload.self,
            from: NoteCipher.open(SyncWire.decode64(#require(refreshed.ciphertext)), vaultKey: library.key, context: context))
        #expect(payload.attachmentIds.isEmpty && payload.attachmentSnapshots?.isEmpty == true)
        #expect(try library.store.note(id: note.id)?.modifiedAt == modifiedAt)
    }

    @Test func protectedRetainedFileSurvivesSyncAndCanBeDecryptedOnAnotherDevice() async throws {
        let source = try Library(); defer { source.cleanup() }
        let target = try SyncMaterializerTests.Library(key: source.key); defer { target.cleanup() }
        let note = try source.store.create(text: "# Private\nNo current attachment link")
        let bytes = Data("retained bytes".utf8)
        _ = try AttachmentStore(paths: source.paths, database: source.db).add(data: bytes, filename: "retained.txt", to: note.id)
        let access = try NotePrivacy(store: source.store).setPassword("test password")
        try access.lock(noteId: note.id)
        let id = try source.attachment(note)
        #expect(try await source.db.pool.read { try Bool.fetchOne($0, sql: "SELECT deletedAt IS NOT NULL FROM attachment WHERE id=?", arguments: [id]) } == true)
        try source.queue.enable(accountID: "account")
        #expect(try await source.preparer.preparePending() == 1)
        let (descriptor, cipher) = try source.cached(id)
        var received: [SyncEntity] = []
        while let mutation = try source.queue.prepareNext(vaultKey: source.key) {
            let receipt = SyncEntity(mutation: mutation, revision: 1, sequence: Int64(received.count + 1), receivedAt: 1)
            received.append(receipt); try source.queue.accept(receipt)
        }
        try target.receive(received)
        let apply = target.materializer(.init(files: [descriptor.blobHash: cipher]))
        for entity in received { _ = try await apply.apply(entity) }
        #expect(try target.inbox.pending().isEmpty)
        let targetAccess = try NotePrivacy(store: target.store).unlock(password: "test password")
        try targetAccess.removeLock(noteId: note.id)
        #expect(try Data(contentsOf: target.paths.attachments.appendingPathComponent(note.id + "/retained.txt")) == bytes)
        #expect(try target.store.note(id: note.id)?.text == "# Private\nNo current attachment link")
    }

    @Test func missingLegacyFilesDoNotStarveNotesOrAvailableAttachmentsAndCanArriveLater() async throws {
        let source = try Library(); defer { source.cleanup() }
        let target = try SyncMaterializerTests.Library(key: source.key); defer { target.cleanup() }
        let note = try source.store.create(text: "# Incomplete import\n" + AttachmentMarkdown.link(for: "absent.txt") + "\n"
            + AttachmentMarkdown.link(for: "present.txt") + "\ne\u{301} 🐻\n")
        let missingDirectory = try source.store.create(text: "# Another import\n" + AttachmentMarkdown.link(for: "later.txt"))
        let presentBytes = Data("available bytes 🐻".utf8)
        _ = try AttachmentStore(paths: source.paths, database: source.db)
            .add(data: presentBytes, filename: "present.txt", to: note.id)
        let ids = try await source.db.pool.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id,filename FROM attachment")
                .map { ($0["filename"] as String, $0["id"] as String) })
        }
        try #require(ids.count == 3)
        try source.queue.enable(accountID: "account")
        let dirtyBefore = try await source.db.pool.read { try String.fetchAll($0, sql: "SELECT json_array(entityType,localId,generation,tombstone) FROM sync_dirty ORDER BY entityType,localId") }
        let counts = try source.queue.pendingUploadCounts(paths: source.paths)
        #expect(counts.pendingUploads == 3 && counts.unavailableAttachments == 2)
        #expect(try source.queue.pendingCount() == 5)
        #expect(try await source.db.pool.read { try String.fetchAll($0, sql: "SELECT json_array(entityType,localId,generation,tombstone) FROM sync_dirty ORDER BY entityType,localId") } == dirtyBefore)
        let preparer = source.preparer
        // A bounded scan must advance past unavailable files instead of retrying only its head.
        var prepared = 0
        for _ in 0..<ids.count { prepared += try await preparer.preparePending(limit: 1) }
        #expect(prepared == 1)
        let (present, presentCipher) = try source.cached(#require(ids["present.txt"]))
        var sequence: Int64 = 0
        func drain() throws -> [SyncEntity] {
            var batch: [SyncEntity] = []
            while let mutation = try source.queue.prepareNext(vaultKey: source.key) {
                sequence += 1
                let receipt = SyncEntity(mutation: mutation, revision: mutation.parentRevision + 1,
                    sequence: sequence, receivedAt: sequence)
                batch.append(receipt); try source.queue.accept(receipt)
            }
            return batch
        }
        let initial = try drain()
        #expect(Set(initial.filter { $0.mutation.entityType == .note }.map { $0.mutation.entityId }) == Set([note.id, missingDirectory.id]))
        #expect(initial.filter { $0.mutation.entityType == .attachment }.map { $0.mutation.entityId } == [present.id])
        #expect(try source.queue.pendingCount() == 2)
        let remaining = try source.queue.pendingUploadCounts(paths: source.paths)
        #expect(remaining.pendingUploads == 0 && remaining.unavailableAttachments == 2)
        try target.receive(initial)
        let apply = target.materializer(.init(files: [present.blobHash: presentCipher]))
        for entity in initial where entity.mutation.entityType == .note { _ = try await apply.apply(entity) }
        for entity in initial where entity.mutation.entityType != .note { _ = try await apply.apply(entity) }
        #expect(try target.inbox.pending().isEmpty)
        #expect(try target.store.note(id: note.id).map { Data($0.text.utf8) } == Data(note.text.utf8))
        #expect(try target.store.note(id: missingDirectory.id)?.text == missingDirectory.text)
        #expect(try Data(contentsOf: target.paths.attachments.appendingPathComponent(note.id + "/present.txt")) == presentBytes)
        #expect(!FileManager.default.fileExists(atPath: target.paths.attachments.appendingPathComponent(note.id + "/absent.txt").path))

        // Restore only synthetic, known bytes at the exact referenced path, without editing the note.
        let recoveredBytes = Data("recovered exact bytes".utf8)
        try AttachmentFiles(paths: source.paths, database: source.db).write(
            [ImportedAttachment(filename: "later.txt", data: recoveredBytes)], noteId: missingDirectory.id,
            replacing: false) { _ in }
        #expect(try await preparer.preparePending() == 1)
        let (recovered, recoveredCipher) = try source.cached(#require(ids["later.txt"]))
        let later = try drain()
        #expect(later.contains { $0.mutation.entityType == .attachment && $0.mutation.entityId == recovered.id })
        #expect(try source.queue.pendingCount() == 1)
        let laterCounts = try source.queue.pendingUploadCounts(paths: source.paths)
        #expect(laterCounts.pendingUploads == 0 && laterCounts.unavailableAttachments == 1)
        try target.receive(later)
        let applyLater = target.materializer(.init(files: [present.blobHash: presentCipher, recovered.blobHash: recoveredCipher]))
        for entity in later where entity.mutation.entityType == .note { _ = try await applyLater.apply(entity) }
        for entity in later where entity.mutation.entityType != .note { _ = try await applyLater.apply(entity) }
        #expect(try target.inbox.pending().isEmpty)
        #expect(try Data(contentsOf: target.paths.attachments.appendingPathComponent(missingDirectory.id + "/later.txt")) == recoveredBytes)
        #expect(try target.store.note(id: missingDirectory.id)?.text == missingDirectory.text)
        #expect(try source.store.note(id: missingDirectory.id)?.revision == missingDirectory.revision)
    }


    @Test func summaryRetainsCurrentCiphertextAndAcknowledgedBlobsButRejectsStaleGenerations() async throws {
        let library = try Library(); defer { library.cleanup() }
        let note = try library.store.create(text: "![](one.bin)")
        _ = try AttachmentStore(paths: library.paths, database: library.db)
            .add(data: Data("bytes".utf8), filename: "one.bin", to: note.id)
        try library.queue.enable(accountID: "account")
        let id = try library.attachment(note)
        #expect(try await library.preparer.preparePending() == 1)
        let (descriptor, cipher) = try library.cached(id)
        try FileManager.default.removeItem(at: library.paths.attachments.appendingPathComponent(note.id + "/one.bin"))
        let before = try await library.db.pool.read { try String.fetchAll($0, sql: "SELECT json_array(hash,localPath,byteSize,uploaded,length(data),multipartId,completedParts) FROM sync_blob_state") }
        #expect(try library.queue.pendingUploadCounts(paths: library.paths).unavailableAttachments == 0)
        // Counting must not rewrite a cache pointer or acknowledge any bytes.
        #expect(try await library.db.pool.read { try String.fetchAll($0, sql: "SELECT json_array(hash,localPath,byteSize,uploaded,length(data),multipartId,completedParts) FROM sync_blob_state") } == before)
        let cipherBytes = try Data(contentsOf: cipher)
        let storedPath = try SyncBlobLocation.relative(cipher.path)
        // Legacy sandbox prefixes can be safely rebound without rewriting the stored path.
        try await library.db.pool.write { try $0.execute(sql: "UPDATE sync_blob_state SET localPath=? WHERE hash=?",
            arguments: ["/previous/container/" + storedPath, descriptor.blobHash]) }
        #expect(try library.queue.pendingUploadCounts(paths: library.paths).unavailableAttachments == 0)
        #expect(try await library.db.pool.read { try String.fetchOne($0, sql: "SELECT localPath FROM sync_blob_state WHERE hash=?", arguments: [descriptor.blobHash]) } == "/previous/container/" + storedPath)
        try Data(cipherBytes.dropLast()).write(to: cipher)
        #expect(try library.queue.pendingUploadCounts(paths: library.paths).unavailableAttachments == 1)
        try FileManager.default.removeItem(at: cipher)
        #expect(try library.queue.pendingUploadCounts(paths: library.paths).unavailableAttachments == 1)
        let outside = library.paths.root.appendingPathComponent("outside-cipher")
        try cipherBytes.write(to: outside)
        try FileManager.default.createSymbolicLink(at: cipher, withDestinationURL: outside)
        #expect(try library.queue.pendingUploadCounts(paths: library.paths).unavailableAttachments == 1)
        try FileManager.default.removeItem(at: cipher)
        try await library.db.pool.write { try $0.execute(sql: "UPDATE sync_blob_state SET localPath='../outside-cipher' WHERE hash=?", arguments: [descriptor.blobHash]) }
        #expect(try library.queue.pendingUploadCounts(paths: library.paths).unavailableAttachments == 1)
        // Storage enforces exactly one of path/data; inline bytes can also preserve this generation.
        try await library.db.pool.write { try $0.execute(sql: "UPDATE sync_blob_state SET localPath=NULL,data=? WHERE hash=?", arguments: [cipherBytes, descriptor.blobHash]) }
        #expect(try library.queue.pendingUploadCounts(paths: library.paths).unavailableAttachments == 0)
        try await library.db.pool.write { try $0.execute(sql: "UPDATE sync_blob_state SET data=? WHERE hash=?", arguments: [Data(cipherBytes.dropLast()), descriptor.blobHash]) }
        #expect(try library.queue.pendingUploadCounts(paths: library.paths).unavailableAttachments == 1)
        try await library.db.pool.write { try $0.execute(sql: "UPDATE sync_blob_state SET uploaded=1 WHERE hash=?", arguments: [descriptor.blobHash]) }
        #expect(try library.queue.pendingUploadCounts(paths: library.paths).unavailableAttachments == 0)
        try await library.db.pool.write { try $0.execute(sql: "UPDATE attachment SET ocrText='new generation' WHERE id=?", arguments: [id]) }
        #expect(try library.queue.pendingUploadCounts(paths: library.paths).unavailableAttachments == 1)
        #expect(try library.queue.pendingCount() == 2)
    }

    @Test func immutableOutboxRemainsPendingUntilReceiptThenMissingNewGenerationIsUnavailable() async throws {
        let library = try Library(); defer { library.cleanup() }
        let note = try library.store.create(text: "![](one.bin)")
        _ = try AttachmentStore(paths: library.paths, database: library.db)
            .add(data: Data("bytes".utf8), filename: "one.bin", to: note.id)
        try library.queue.enable(accountID: "account")
        let id = try library.attachment(note)
        #expect(try await library.preparer.preparePending() == 1)
        let mutation = try #require(try library.queue.prepareNext(vaultKey: library.key))
        #expect(mutation.entityType == .attachment)
        try FileManager.default.removeItem(at: library.paths.attachments.appendingPathComponent(note.id + "/one.bin"))
        try await library.db.pool.write { db in
            try db.execute(sql: "DELETE FROM sync_attachment_cache WHERE attachmentId=?", arguments: [id])
            try db.execute(sql: "UPDATE attachment SET ocrText='new generation' WHERE id=?", arguments: [id])
        }
        let dirtyBefore = try await library.db.pool.read { try String.fetchAll($0, sql: "SELECT json_array(entityType,localId,generation,tombstone) FROM sync_dirty ORDER BY entityType,localId") }
        let counts = try library.queue.pendingUploadCounts(paths: library.paths)
        #expect(counts.pendingUploads == 2 && counts.unavailableAttachments == 0)
        #expect(try library.queue.pendingMutations() == [mutation])
        #expect(try await library.db.pool.read { try String.fetchAll($0, sql: "SELECT json_array(entityType,localId,generation,tombstone) FROM sync_dirty ORDER BY entityType,localId") } == dirtyBefore)
        try library.queue.accept(SyncEntity(mutation: mutation, revision: 1, sequence: 1, receivedAt: 1))
        let after = try library.queue.pendingUploadCounts(paths: library.paths)
        #expect(after.pendingUploads == 1 && after.unavailableAttachments == 1)
        #expect(try library.queue.pendingCount() == 2)
    }

    @Test func tombstonesArePendingAndSummaryNeverFollowsSourceDirectorySymlinksOrInvalidPaths() throws {
        let library = try Library(); defer { library.cleanup() }
        let note = try library.store.create(text: "![](one.bin)")
        try library.queue.enable(accountID: "account")
        let id = try library.attachment(note)
        #expect(try library.queue.pendingUploadCounts(paths: library.paths).unavailableAttachments == 1)
        let elsewhere = library.paths.root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: elsewhere.appendingPathComponent("one.bin"))
        let directory = library.paths.attachments.appendingPathComponent(note.id)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: elsewhere)
        #expect(try library.queue.pendingUploadCounts(paths: library.paths).unavailableAttachments == 1)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try library.db.pool.write { try $0.execute(sql: "UPDATE attachment SET filename='../elsewhere/one.bin' WHERE id=?", arguments: [id]) }
        #expect(try library.queue.pendingUploadCounts(paths: library.paths).unavailableAttachments == 1)
        try library.db.pool.write { try $0.execute(sql: "UPDATE sync_dirty SET tombstone=1 WHERE entityType='attachment' AND localId=?", arguments: [id]) }
        let tombstone = try library.queue.pendingUploadCounts(paths: library.paths)
        #expect(tombstone.pendingUploads == 2 && tombstone.unavailableAttachments == 0)
        #expect(try library.queue.pendingCount() == 2)
    }

    private struct Library: Sendable {
        let paths: AppPaths
        let db: AppDatabase
        let store: NoteStore
        let key = SymmetricKey(size: .bits256)
        var queue: SyncQueue { SyncQueue(database: db) }
        var preparer: SyncAttachmentPreparer { SyncAttachmentPreparer(database: db, paths: paths, accountID: "account", vaultKey: key) }
        init() throws {
            paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("sync-attachments-\(UUID())"))
            try paths.createDirectories(); db = try AppDatabase(path: paths.database)
            store = NoteStore(db: db, notifier: nil, paths: paths)
        }
        func cleanup() { try? db.pool.close(); try? FileManager.default.removeItem(at: paths.root) }
        func attachment(_ note: Note) throws -> String {
            try db.pool.read { try #require(try String.fetchOne($0, sql: "SELECT id FROM attachment WHERE noteId=?", arguments: [note.id])) }
        }
        func cached(_ id: String) throws -> (SyncAttachmentPayload, URL) {
            try db.pool.read { db in
                let row = try #require(try Row.fetchOne(db, sql: "SELECT c.encryptedDescriptor,b.localPath FROM sync_attachment_cache c JOIN sync_blob_state b ON b.hash=c.blobHash WHERE c.attachmentId=?", arguments: [id]))
                let context = try SyncWire.cipherContext(accountID: "account", type: .attachment, entityID: id)
                let plain = try NoteCipher.open(row["encryptedDescriptor"], vaultKey: key, context: context + ":cache")
                return (try SyncPayloadCodec.decode(SyncAttachmentPayload.self, from: plain), paths.root.appendingPathComponent(try SyncBlobLocation.relative(row["localPath"])))
            }
        }
    }

    @Test func retriesReuseCiphertextAndQueueReferencesDurableBlob() async throws {
        let library = try Library(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Photo\n![](photo.png)")
        let bytes = Data(String(repeating: "binary\0🐻", count: 18_000).utf8)
        _ = try AttachmentStore(paths: library.paths, database: library.db).add(data: bytes, filename: "photo.png", to: note.id)
        try library.queue.enable(accountID: "account")
        let id = try library.attachment(note), preparer = library.preparer
        #expect(try await preparer.preparePending() == 1)
        let (first, url) = try library.cached(id)
        #expect(try await preparer.preparePending() == 1)
        let (second, sameURL) = try library.cached(id)
        #expect(first == second && sameURL == url)
        let output = library.paths.root.appendingPathComponent("verified.bin")
        try ChunkedCipher.decrypt(input: url, output: output, keyEncryptionKey: library.key,
            context: SyncWire.cipherContext(accountID: "account", type: .attachment, entityID: id))
        #expect(try Data(contentsOf: output) == bytes)
        let mutation = try #require(try library.queue.prepareNext(vaultKey: library.key))
        #expect(mutation.entityType == .attachment && mutation.blobRefs == [first.blobHash])
        let size = try await library.db.pool.read { try Int64.fetchOne($0, sql: "SELECT byteSize FROM sync_blob_state WHERE hash=? AND uploaded=0", arguments: [first.blobHash]) }
        #expect(size == first.cipherBytes)
    }

    @Test func editsAndFileReplacementDuringEncryptionCannotPublishStaleSnapshot() async throws {
        let library = try Library(); defer { library.cleanup() }
        let note = try library.store.create(text: "![](one.bin)")
        _ = try AttachmentStore(paths: library.paths, database: library.db).add(data: Data("original".utf8), filename: "one.bin", to: note.id)
        try library.queue.enable(accountID: "account")
        let id = try library.attachment(note), preparer = library.preparer
        await #expect(throws: SyncQueueError.snapshotUnavailable) {
            try await preparer.prepare(id: id) {
                try library.db.pool.write { try $0.execute(sql: "UPDATE attachment SET ocrText='new OCR' WHERE id=?", arguments: [id]) }
            }
        }
        #expect(try await library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_attachment_cache") } == 0)
        let source = library.paths.attachments.appendingPathComponent(note.id).appendingPathComponent("one.bin")
        await #expect(throws: SyncQueueError.snapshotUnavailable) {
            try await preparer.prepare(id: id) { try Data("replaced".utf8).write(to: source, options: .atomic) }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.paths.root.appendingPathComponent("SyncBlobs").path).isEmpty)
        #expect(try await preparer.preparePending() == 1)
        #expect(try library.cached(id).0.fileHash == SyncWire.hash(Data("replaced".utf8)))
    }

    @Test func protectedAttachmentOuterDecryptionOnlyRevealsInnerCiphertext() async throws {
        let library = try Library(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Private\n![](secret-name.png)")
        let bytes = Data("private attachment bytes".utf8)
        _ = try AttachmentStore(paths: library.paths, database: library.db).add(data: bytes, filename: "secret-name.png", to: note.id)
        let access = try NotePrivacy(store: library.store).setPassword("test password")
        try access.lock(noteId: note.id)
        try library.queue.enable(accountID: "account")
        let id = try library.attachment(note)
        #expect(try await library.preparer.preparePending() == 1)
        let (payload, url) = try library.cached(id)
        #expect(payload.isLocked && payload.filename == id + ".bch" && payload.ocrText == nil)
        let output = library.paths.root.appendingPathComponent("outer-decrypted.bch")
        try ChunkedCipher.decrypt(input: url, output: output, keyEncryptionKey: library.key,
            context: SyncWire.cipherContext(accountID: "account", type: .attachment, entityID: id))
        let inner = try Data(contentsOf: output)
        #expect(inner.starts(with: Data("BCH1".utf8)) && inner.range(of: bytes) == nil)
        #expect(inner == (try Data(contentsOf: library.paths.attachments.appendingPathComponent(note.id).appendingPathComponent(payload.filename))))
    }

    @Test func symlinksAreDeferredAndStagedFileReplacementMarksGenerationEvenWithoutKnownHash() async throws {
        let library = try Library(); defer { library.cleanup() }
        let note = try library.store.create(text: "![](one.bin)")
        let dir = library.paths.attachments.appendingPathComponent(note.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let elsewhere = library.paths.root.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("one.bin"), withDestinationURL: elsewhere)
        try library.queue.enable(accountID: "account")
        let id = try library.attachment(note)
        #expect(try await library.preparer.preparePending() == 0)
        #expect(try library.queue.pendingUploadCounts(paths: library.paths).unavailableAttachments == 1)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("one.bin"))
        let before = try await library.db.pool.read { try Int64.fetchOne($0, sql: "SELECT generation FROM sync_dirty WHERE entityType='attachment' AND localId=?", arguments: [id]) }
        try AttachmentFiles(paths: library.paths, database: library.db).write([ImportedAttachment(filename: "one.bin", data: Data("fresh".utf8))], noteId: note.id, replacing: false) { _ in }
        let after = try await library.db.pool.read { try Int64.fetchOne($0, sql: "SELECT generation FROM sync_dirty WHERE entityType='attachment' AND localId=?", arguments: [id]) }
        #expect(try #require(after) > #require(before))
        #expect(try await library.preparer.preparePending() == 1)
    }
}
