// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct SyncAttachmentPrivacyConflictRegressionTests {
    @Test(arguments: [false, true], [false, true])
    func staleAttachmentPreservesRemoteBytesAcrossPrivacy(localLocked: Bool, differentBytes: Bool) async throws {
        try await checkStaleAttachment(localLocked: localLocked, differentBytes: differentBytes)
    }

    @Test(arguments: [false, true]) func largeEqualAttachmentsPreserveCopiesAndContinue(localLocked: Bool) async throws {
        try await checkStaleAttachment(localLocked: localLocked, differentBytes: false, large: true)
    }

    @Test(arguments: [false, true]) func newerEditBehindImmutableUploadRemainsRecoverable(localLocked: Bool) async throws {
        try await checkStaleAttachment(localLocked: localLocked, differentBytes: true, newerEdit: true)
    }

    private func checkStaleAttachment(localLocked: Bool, differentBytes: Bool, large: Bool = false, newerEdit: Bool = false) async throws {
        let library = try SyncMaterializerTests.Library()
        defer { library.cleanup() }
        let note = try library.store.create(text: "# Local\n" + AttachmentMarkdown.link(for: "file.txt"))
        var localBytes = large ? Data(repeating: 42, count: 16 * 1024 * 1024 + 1) : Data("local different bytes".utf8)
        _ = try AttachmentStore(paths: library.paths, database: library.db).add(
            data: localBytes, filename: "file.txt", to: note.id)
        let access = try NotePrivacy(store: library.store).setPassword("password")
        defer { access.revoke() }
        if localLocked { try access.lock(noteId: note.id) }
        let attachmentID = try #require(try await library.db.pool.read {
            try String.fetchOne($0, sql: "SELECT id FROM attachment WHERE noteId=?", arguments: [note.id])
        })
        try await library.db.pool.write {
            try $0.execute(sql: "INSERT INTO sync_entity_state(entityType,localId,entityId,serverRevision) VALUES('attachment',?,?,1)",
                           arguments: [attachmentID, attachmentID])
        }
        let preparer = SyncAttachmentPreparer(database: library.db, paths: library.paths, accountID: "account", vaultKey: library.key)
        _ = try await preparer.preparePending()
        var pending: SyncMutation?
        for _ in 0..<10 {
            guard let mutation = try library.queue.prepareNext(vaultKey: library.key) else { break }
            if mutation.entityType == .attachment { pending = mutation; break }
        }
        let stale = try #require(pending)
        #expect(stale.parentRevision == 1)
        if newerEdit {
            let preparedGeneration = try #require(try await library.db.pool.read {
                try Int64.fetchOne($0, sql: "SELECT generation FROM sync_outbox WHERE mutationId=?", arguments: [stale.mutationId])
            })
            localBytes = Data("newer edit behind immutable upload".utf8)
            let filename = localLocked ? attachmentID + ".bch" : "file.txt"
            let replacement: Data
            if localLocked {
                let inner = library.paths.root.appendingPathComponent("new-local.bch")
                try ChunkedCipher.encrypt(data: localBytes, output: inner, keyEncryptionKey: access.journalKey(), context: filename)
                replacement = try Data(contentsOf: inner)
            } else { replacement = localBytes }
            try AttachmentFiles(paths: library.paths, database: library.db).write(
                [ImportedAttachment(filename: filename, data: replacement)], noteId: note.id, replacing: true) { _ in }
            #expect(try library.queue.pendingMutations().contains(stale))
            let generation = try #require(try await library.db.pool.read {
                try Int64.fetchOne($0, sql: "SELECT generation FROM sync_dirty WHERE entityType='attachment' AND localId=?", arguments: [attachmentID])
            })
            #expect(generation > preparedGeneration)
        }
        let remoteBytes = differentBytes ? Data("newer remote bytes".utf8) : localBytes
        let remoteLocked = !localLocked
        let remoteName = remoteLocked ? attachmentID + ".bch" : "file.txt"
        let sourceBytes: Data
        if remoteLocked {
            let inner = library.paths.root.appendingPathComponent("remote-inner.bch")
            try ChunkedCipher.encrypt(data: remoteBytes, output: inner, keyEncryptionKey: access.journalKey(), context: remoteName)
            sourceBytes = try Data(contentsOf: inner)
        } else { sourceBytes = remoteBytes }
        let cipher = library.paths.root.appendingPathComponent("remote.bch")
        try ChunkedCipher.encrypt(data: sourceBytes, output: cipher, keyEncryptionKey: library.key,
            context: SyncWire.cipherContext(accountID: "account", type: .attachment, entityID: attachmentID))
        let facts = try SyncAttachmentPreparer.hashFile(cipher)
        let descriptor = SyncAttachmentPayload(id: attachmentID, noteId: note.id, filename: remoteName, isLocked: remoteLocked,
            blobHash: facts.hash, cipherBytes: facts.size, fileBytes: Int64(sourceBytes.count), fileHash: SyncWire.hash(sourceBytes),
            uti: nil, width: nil, height: nil, ocrText: nil, createdAt: 1, updatedAt: 2)
        let remote = try library.entity(descriptor, type: .attachment, id: attachmentID, revision: 2, sequence: 20, refs: [facts.hash])
        try library.receive([remote])
        let result = try await library.materializer(.init(files: [facts.hash: cipher])).apply(
            remote, rejectedMutationID: stale.mutationId, noteAccess: access)
        #expect(result == .applied)
        let copyID = SyncNoteMerge.conflictID(entityID: attachmentID, mutationID: stale.mutationId, remoteRevision: 2)
        let expectedCopy = differentBytes || large
        if expectedCopy {
            let copy = try #require(try library.store.note(id: copyID))
            #expect(copy.isLocked && copy.text.isEmpty)
            let localCopyID = SyncNoteMerge.conflictID(entityID: "local:" + attachmentID, mutationID: stale.mutationId, remoteRevision: 2)
            let localCopy = try #require(try library.store.note(id: localCopyID))
            #expect(localCopy.isLocked && localCopy.text.isEmpty)
            // Either side's lock protects BOTH copies, without changing their exact bytes.
            let localName = localLocked ? "Attachment" : "file.txt"
            let remoteCopyName = remoteLocked ? "Attachment" : "file.txt"
            #expect(try access.attachmentData(localName, noteId: localCopyID, maximumBytes: localBytes.count) == localBytes)
            #expect(try access.attachmentData(remoteCopyName, noteId: copyID, maximumBytes: remoteBytes.count) == remoteBytes)
        } else {
            #expect(try library.store.note(id: copyID) == nil)
        }
        #expect(try !library.queue.pendingMutations().contains(stale))
        if localLocked {
            let output = library.paths.root.appendingPathComponent("local-verified")
            try access.decryptAttachment("file.txt", noteId: note.id, to: output)
            #expect(try Data(contentsOf: output) == localBytes)
        } else {
            #expect(try Data(contentsOf: library.paths.attachments.appendingPathComponent(note.id + "/file.txt")) == localBytes)
        }
        #expect(try await library.materializer(.init(files: [facts.hash: cipher])).apply(remote) == .unchanged)
        #expect(try await library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note") } == (expectedCopy ? 3 : 1))
        _ = try await preparer.preparePending()
        var rebased: SyncMutation?
        for _ in 0..<10 {
            guard let next = try library.queue.prepareNext(vaultKey: library.key) else { break }
            if next.entityType == .attachment && next.entityId == attachmentID { rebased = next; break }
        }
        #expect(try #require(rebased).parentRevision == 2)
    }

    @Test(arguments: [false, true]) func differentBytesEventuallyConvergeWithReadableCopies(lockedReceiver: Bool) async throws {
        let key = SymmetricKey(size: .bits256)
        let a = try SyncMaterializerTests.Library(key: key, enabled: false)
        let b = try SyncMaterializerTests.Library(key: key, enabled: false)
        defer { a.cleanup(); b.cleanup() }
        let note = try a.store.create(text: "# File\n" + AttachmentMarkdown.link(for: "file.txt"))
        _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: Data("base".utf8), filename: "file.txt", to: note.id)
        let leftAccess = try NotePrivacy(store: a.store).setPassword("password")
        defer { leftAccess.revoke() }
        let server = SyncEngineTests.Server()
        let blobs = SyncPrivacyTransitionTests.SharedBlobs(libraries: [(a.db, a.paths), (b.db, b.paths)])
        let left = SyncEngine(database: a.db, paths: a.paths, accountID: "account", vaultKey: key, transport: server, blobs: blobs)
        let right = SyncEngine(database: b.db, paths: b.paths, accountID: "account", vaultKey: key, transport: server, blobs: blobs)
        try a.queue.enable(accountID: "account")
        _ = try await left.synchronize()
        _ = try await right.synchronize()
        let rightAccess = try NotePrivacy(store: b.store).unlock(password: "password")
        defer { rightAccess.revoke() }
        try b.queue.enable(accountID: "account")
        _ = try await right.synchronize(); _ = try await left.synchronize()
        let protectedLibrary = lockedReceiver ? b : a
        let plainLibrary = lockedReceiver ? a : b
        let protectedAccess = lockedReceiver ? rightAccess : leftAccess
        try protectedAccess.lock(noteId: note.id)
        let protectedBytes = Data("changed protected bytes".utf8)
        let plainBytes = Data("changed plain bytes".utf8)
        let protectedName = try #require(try await protectedLibrary.db.pool.read {
            try String.fetchOne($0, sql: "SELECT filename FROM attachment WHERE noteId=?", arguments: [note.id])
        })
        let replacement = protectedLibrary.paths.root.appendingPathComponent("protected-replacement.bch")
        try ChunkedCipher.encrypt(data: protectedBytes, output: replacement,
            keyEncryptionKey: protectedAccess.journalKey(), context: protectedName)
        try AttachmentFiles(paths: protectedLibrary.paths, database: protectedLibrary.db).write(
            [ImportedAttachment(filename: protectedName, data: try Data(contentsOf: replacement))], noteId: note.id, replacing: true) { _ in }
        try AttachmentFiles(paths: plainLibrary.paths, database: plainLibrary.db).write(
            [ImportedAttachment(filename: "file.txt", data: plainBytes)], noteId: note.id, replacing: true) { _ in }
        for library in [protectedLibrary, plainLibrary] {
            #expect(try await library.db.pool.read {
                try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM sync_dirty d JOIN attachment a ON a.id=d.localId WHERE d.entityType='attachment' AND a.noteId=? AND d.generation>0 AND d.tombstone=0)", arguments: [note.id])
            } == true)
        }
        _ = try await left.synchronize(noteAccess: leftAccess)
        var leftSummary = SyncRunSummary(), rightSummary = SyncRunSummary()
        for _ in 0..<6 {
            rightSummary = try await right.synchronize(noteAccess: rightAccess)
            leftSummary = try await left.synchronize(noteAccess: leftAccess)
            if leftSummary.pendingUploads == 0 && leftSummary.pendingDownloads == 0 && rightSummary.pendingUploads == 0 && rightSummary.pendingDownloads == 0 { break }
        }
        #expect(leftSummary.pendingUploads == 0 && leftSummary.pendingDownloads == 0)
        #expect(rightSummary.pendingUploads == 0 && rightSummary.pendingDownloads == 0)
        let leftIDs = try await a.db.pool.read { try String.fetchAll($0, sql: "SELECT id FROM note ORDER BY id") }
        let rightIDs = try await b.db.pool.read { try String.fetchAll($0, sql: "SELECT id FROM note ORDER BY id") }
        #expect(leftIDs == rightIDs)
        for (library, access) in [(a, leftAccess), (b, rightAccess)] {
            var recovered = Set<Data>()
            for id in leftIDs {
                let stored = try #require(try library.store.note(id: id))
                if stored.isLocked {
                    let unlocked = try #require(try access.note(id: id))
                    for ref in NoteParser.metadata(for: unlocked.text).attachments {
                        recovered.insert(try access.attachmentData(ref.filename, noteId: id, maximumBytes: 1024))
                    }
                } else {
                    let names = try await library.db.pool.read {
                        try String.fetchAll($0, sql: "SELECT filename FROM attachment WHERE noteId=? AND deletedAt IS NULL", arguments: [id])
                    }
                    for name in names {
                        recovered.insert(try Data(contentsOf: library.paths.attachments.appendingPathComponent(id + "/" + name)))
                    }
                }
            }
            #expect(recovered.contains(protectedBytes))
            #expect(recovered.contains(plainBytes))
        }
        await left.shutdown(); await right.shutdown()
    }

}
