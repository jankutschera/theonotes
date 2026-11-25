// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// Generic attachment regression: no PencilKit/PNG-specific behavior or fixture dependency.
@Suite struct AttachmentPrivacyMismatchProtectionTests {
    private struct Library {
        let paths: AppPaths
        let db: AppDatabase
        let key: SymmetricKey
        var store: NoteStore { NoteStore(db: db, notifier: nil, paths: paths) }
        init(key: SymmetricKey) throws {
            self.key = key
            paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("privacy-copy-\(UUID())"))
            try paths.createDirectories(); db = try AppDatabase(path: paths.database)
        }
        func cleanup() { try? db.pool.close(); try? FileManager.default.removeItem(at: paths.root) }
        func prepared(_ id: String) async throws -> (SyncAttachmentPayload, URL) {
            _ = try await SyncAttachmentPreparer(database: db, paths: paths, accountID: "account", vaultKey: key).prepare(id: id)
            return try await db.pool.read { db in
                let row = try #require(try Row.fetchOne(db, sql: "SELECT c.encryptedDescriptor,b.localPath FROM sync_attachment_cache c JOIN sync_blob_state b ON b.hash=c.blobHash WHERE c.attachmentId=?", arguments: [id]))
                let context = try SyncWire.cipherContext(accountID: "account", type: .attachment, entityID: id)
                let body = try NoteCipher.open(row["encryptedDescriptor"], vaultKey: key, context: context + ":cache")
                return (try SyncPayloadCodec.decode(SyncAttachmentPayload.self, from: body),
                    paths.root.appendingPathComponent(try SyncBlobLocation.relative(row["localPath"])))
            }
        }
    }
    private struct Fixture {
        let remote: Library
        let local: Library
        let noteID: String
        let attachmentID: String
        let access: LockedNoteAccess
        let remoteBytes = Data("remote-attachment-content-private-marker".utf8)
        let localBytes = Data("offline-local-attachment-content-private-marker".utf8)
        let ocrMarker = "OCR-MUST-NOT-LEAK-IN-PROTECTED-RECOVERY"
        init(remoteLocked: Bool) throws {
            let key = SymmetricKey(size: .bits256)
            remote = try Library(key: key); local = try Library(key: key)
            let note = try remote.store.create(text: "# Privacy transition\n" + AttachmentMarkdown.link(for: "source.bin"))
            noteID = note.id
            _ = try AttachmentStore(paths: remote.paths, database: remote.db).add(data: remoteBytes, filename: "source.bin", to: note.id)
            let remoteAccess = try NotePrivacy(store: remote.store).setPassword("test-password")
            let archive = remote.paths.root.appendingPathComponent("initial.baerchen-backup")
            try LibraryBackup(database: remote.db, paths: remote.paths).create(at: archive)
            _ = try LibraryBackup(database: local.db, paths: local.paths).restore(archive, mode: .replaceAll)
            try SyncQueue(database: remote.db).enable(accountID: "account")
            try SyncQueue(database: local.db).enable(accountID: "account")
            attachmentID = try remote.db.pool.read { try #require(try String.fetchOne($0, sql: "SELECT id FROM attachment WHERE noteId=?", arguments: [note.id])) }
            access = try NotePrivacy(store: local.store).unlock(password: "test-password")
            try AttachmentFiles(paths: local.paths, database: local.db).write(
                [ImportedAttachment(filename: "source.bin", data: localBytes)], noteId: note.id, replacing: true) { _ in }
            let plain = remoteLocked ? local : remote
            let plainBytes = remoteLocked ? localBytes : remoteBytes
            try AttachmentTextStore(database: plain.db).record(OCRJob(noteId: note.id, filename: "source.bin"),
                result: .text(ocrMarker, sha256: SyncWire.hash(plainBytes), byteSize: plainBytes.count, modifiedAt: .now))
            try plain.db.pool.write { db in
                try db.execute(sql: "UPDATE attachment SET uti='public.data',width=23,height=29 WHERE id=?", arguments: [attachmentID])
            }
            if remoteLocked { try remoteAccess.lock(noteId: note.id) }
            else { try access.lock(noteId: note.id) }
            remoteAccess.revoke()
        }
        func cleanup() { access.revoke(); remote.cleanup(); local.cleanup() }
        func copyID(local: Bool) -> String {
            SyncNoteMerge.conflictID(entityID: (local ? "local:" : "") + attachmentID,
                mutationID: "privacy-rejected", remoteRevision: 2)
        }
        func assertProtectedCopy(_ id: String, bytes: Data, knownName: Bool) throws {
            let note = try #require(try local.store.note(id: id))
            #expect(note.isLocked && note.text.isEmpty && note.encryptedPayload != nil)
            let readable = try #require(try access.note(id: id))
            let link = try #require(NoteParser.attachmentLinks(in: readable.text).first)
            #expect(link.filename == (knownName ? "source.bin" : "Attachment"))
            #expect(try access.attachmentData(link.filename, noteId: id, maximumBytes: 1024) == bytes)
            try local.db.pool.read { db in
                let row = try #require(try Row.fetchOne(db, sql: "SELECT filename,uti,width,height,ocrText,ocrState,sha256,byteSize FROM attachment WHERE noteId=? AND deletedAt IS NULL", arguments: [id]))
                #expect((row["filename"] as String).hasSuffix(".bch"))
                #expect(row["uti"] as String? == nil && row["width"] as Int? == nil && row["height"] as Int? == nil)
                #expect(row["ocrText"] as String? == nil && row["sha256"] as String? == nil && row["byteSize"] as Int? == nil)
                #expect(row["ocrState"] as String == "locked")
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note_search_content WHERE noteId=?", arguments: [id]) == 0)
            }
            let directory = local.paths.attachments.appendingPathComponent(id)
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            #expect(files.count == 1)
            for file in files {
                let ciphertext = try Data(contentsOf: file)
                #expect(ciphertext.range(of: bytes) == nil)
                #expect(ciphertext.range(of: Data(ocrMarker.utf8)) == nil)
            }
        }
    }

    @Test(arguments: [true, false])
    func privateServerMismatchProtectsBothCopiesIncludingPlainSideMetadata(remoteLocked: Bool) async throws {
        let fixture = try Fixture(remoteLocked: remoteLocked); defer { fixture.cleanup() }
        let (payload, cipher) = try await fixture.remote.prepared(fixture.attachmentID)
        let context = try SyncWire.cipherContext(accountID: "account", type: .attachment, entityID: payload.id)
        let sealed = try NoteCipher.seal(SyncPayloadCodec.encoder().encode(payload), vaultKey: fixture.local.key, context: context)
        let entity = SyncEntity(mutation: SyncMutation(mutationId: "remote", entityType: .attachment, entityId: payload.id,
            parentRevision: 1, ciphertext: SyncWire.base64(sealed), blobRefs: [payload.blobHash]), revision: 2, sequence: 1, receivedAt: 1)
        let inbox = SyncInbox(database: fixture.local.db)
        try inbox.persist(SyncPullResult(changes: [entity], cursor: 1, hasMore: false), requestedAfter: 0)
        let applier = SyncMaterializer(database: fixture.local.db, paths: fixture.local.paths, accountID: "account",
            vaultKey: fixture.local.key, blobs: SyncPayloadReaderTests.Blobs(files: [payload.blobHash: cipher]))
        #expect(try await applier.apply(entity, rejectedMutationID: "privacy-rejected", noteAccess: fixture.access) == .applied)
        try fixture.assertProtectedCopy(fixture.copyID(local: false), bytes: fixture.remoteBytes, knownName: !remoteLocked)
        try fixture.assertProtectedCopy(fixture.copyID(local: true), bytes: fixture.localBytes, knownName: remoteLocked)
        #expect(try fixture.local.store.allNotes().count == 3)
        #expect(try inbox.pending().isEmpty)
    }

    @Test(arguments: [true, false])
    func cloudMismatchProtectsBothCopiesIncludingPlainSideMetadata(remoteLocked: Bool) async throws {
        let fixture = try Fixture(remoteLocked: remoteLocked); defer { fixture.cleanup() }
        let (payload, cipher) = try await fixture.remote.prepared(fixture.attachmentID)
        let input = CloudApplyInput(version: RemoteVersion(entityType: .attachment, entityId: payload.id, ver: 2,
            sid: "remote", sealed: Data(), blobRefs: [payload.blobHash], lineage: "fixture"), value: .attachment(payload),
            base: nil, hasBase: true, mergeIdentity: ("privacy-rejected", 2), mergingInflight: true,
            siblings: { _, _ in nil }, precondition: { _ in }, siblingStillCurrent: { _, _, _, _ in true },
            lockEnvelopeWaiting: false, independent: false, consumeSiblings: { _, _ in },
            requireUnpublishedProtectedLibrary: { _ in }, isUnpublishedNote: { _, _ in false },
            noteAccess: fixture.access, remoteNotePassword: nil)
        let applier = CloudApplier(database: fixture.local.db, paths: fixture.local.paths, accountID: "account",
            vaultKey: fixture.local.key, blobs: SyncPayloadReaderTests.Blobs(files: [payload.blobHash: cipher]))
        let db = fixture.local.db
        #expect(try await applier.apply(input, commit: { write in try db.pool.write { try write($0) } }) == .applied(consumed: []))
        try fixture.assertProtectedCopy(fixture.copyID(local: false), bytes: fixture.remoteBytes, knownName: !remoteLocked)
        try fixture.assertProtectedCopy(fixture.copyID(local: true), bytes: fixture.localBytes, knownName: remoteLocked)
        #expect(try fixture.local.store.allNotes().count == 3)
    }
    @Test(arguments: ["hash", "short", "long"])
    func streamedProtectionRejectsDescriptorMismatchAtomicallyWithoutPlaintextTemps(fault: String) throws {
        let library = try Library(key: SymmetricKey(size: .bits256)); defer { library.cleanup() }
        let plain = Data(repeating: 0x5b, count: 2 * 1024 * 1024 + 7)
        let source = library.paths.root.appendingPathComponent("source.bch")
        let output = library.paths.root.appendingPathComponent("existing.bch")
        let sentinel = Data("existing-output-must-survive".utf8)
        try ChunkedCipher.encrypt(data: plain, output: source, keyEncryptionKey: library.key, context: "sync-source")
        try sentinel.write(to: output)
        let expectedHash = fault == "hash" ? String(repeating: "0", count: 64) : SyncWire.hash(plain)
        let expectedBytes = Int64(plain.count) + (fault == "short" ? -1 : fault == "long" ? 1 : 0)
        #expect(throws: CryptoError.tampered) {
            try ChunkedCipher.reencrypt(input: source, output: output, fromKey: library.key,
                toKey: SymmetricKey(size: .bits256), fromContext: "sync-source", toContext: "protected-copy",
                expectedPlaintextHash: expectedHash, expectedPlaintextBytes: expectedBytes)
        }
        #expect(try Data(contentsOf: output) == sentinel)
        let files = try #require(FileManager.default.enumerator(at: library.paths.root, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let file as URL in files where (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            #expect(!file.lastPathComponent.hasSuffix(".tmp"))
            #expect(try Data(contentsOf: file).range(of: plain.prefix(128)) == nil)
        }
    }

    @Test func streamedProtectionKeepsLargePlaintextExactWithOnlyEncryptedOutputs() throws {
        let library = try Library(key: SymmetricKey(size: .bits256)); defer { library.cleanup() }
        let key = SymmetricKey(size: .bits256)
        let plain = Data((0..<(2 * 1024 * 1024 + 11)).map { UInt8(truncatingIfNeeded: $0) })
        let source = library.paths.root.appendingPathComponent("source.bch")
        let output = library.paths.root.appendingPathComponent("protected.bch")
        try ChunkedCipher.encrypt(data: plain, output: source, keyEncryptionKey: library.key, context: "sync-source")
        try ChunkedCipher.reencrypt(input: source, output: output, fromKey: library.key, toKey: key,
            fromContext: "sync-source", toContext: "protected-copy", expectedPlaintextHash: SyncWire.hash(plain),
            expectedPlaintextBytes: Int64(plain.count))
        #expect(try ChunkedCipher.decrypt(input: output, keyEncryptionKey: key, context: "protected-copy", maximumBytes: plain.count) == plain)
        #expect(try Data(contentsOf: output).range(of: plain.prefix(128)) == nil)
    }

    @Test(arguments: ["live-note", "no-note-tombstone", "active-attachment-edit", "missing-blob"])
    func deletedNoteRecoveryDoesNotBypassUnprovenDirtyWorkOrMissingBytes(fault: String) async throws {
        let fixture = try Fixture(remoteLocked: true); defer { fixture.cleanup() }
        let (attachment, cipher) = try await fixture.remote.prepared(fixture.attachmentID)
        _ = try await fixture.local.prepared(fixture.attachmentID)
        let remote = try await fixture.remote.db.pool.read {
            try #require(try SyncNotePayload.capture(id: fixture.noteID, includeRetained: true, in: $0))
        }
        let base = try await fixture.local.db.pool.read {
            try #require(try SyncNotePayload.capture(id: fixture.noteID, includeRetained: true, in: $0))
        }
        if fault != "live-note" {
            try fixture.local.store.trash([fixture.noteID])
            _ = try fixture.local.store.emptyTrash(ids: [fixture.noteID])
        }
        try await fixture.local.db.pool.write { db in
            if fault == "no-note-tombstone" {
                try db.execute(sql: "DELETE FROM sync_dirty WHERE entityType='note' AND localId=?", arguments: [fixture.noteID])
            }
            if fault == "active-attachment-edit" {
                try db.execute(sql: "UPDATE sync_dirty SET tombstone=0 WHERE entityType='attachment' AND localId=?", arguments: [fixture.attachmentID])
            }
        }
        let sibling = CloudSibling(value: .attachment(attachment), lineage: "fixture", ver: 2,
            sid: "remote-attachment", sealed: Data(), pending: false)
        let input = CloudApplyInput(version: RemoteVersion(entityType: .note, entityId: fixture.noteID, ver: 2,
            sid: "remote-note", sealed: Data(), blobRefs: [attachment.blobHash], lineage: "fixture"),
            value: .note(remote), base: .note(base), hasBase: true, mergeIdentity: ("delete-conflict", 2),
            mergingInflight: true, siblings: { type, id in type == .attachment && id == attachment.id ? sibling : nil },
            precondition: { _ in }, siblingStillCurrent: { _, _, _, _ in true }, lockEnvelopeWaiting: false,
            independent: false, consumeSiblings: { _, _ in }, requireUnpublishedProtectedLibrary: { _ in },
            isUnpublishedNote: { _, _ in false }, noteAccess: fixture.access, remoteNotePassword: nil)
        let available = fault == "missing-blob" ? [:] : [attachment.blobHash: cipher]
        let applier = CloudApplier(database: fixture.local.db, paths: fixture.local.paths, accountID: "account",
            vaultKey: fixture.local.key, blobs: SyncPayloadReaderTests.Blobs(files: available))
        let db = fixture.local.db
        let outcome = try await applier.apply(input, commit: { write in try db.pool.write { database in
            try write(database)
            try database.execute(sql: "INSERT INTO setting(key,value) VALUES('test-recovery-acked','true')")
        } })
        #expect(outcome == (fault == "missing-blob" ? .waitingForDependencies : .waitingForUpload))
        let copyID = SyncNoteMerge.conflictID(entityID: fixture.noteID, mutationID: "delete-conflict", remoteRevision: 2)
        #expect(try fixture.local.store.note(id: copyID) == nil)
        let ack = try await db.pool.read { try String.fetchOne($0, sql: "SELECT value FROM setting WHERE key='test-recovery-acked'") }
        let staged = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM staging_batch") }
        #expect(ack == nil && staged == 0)
    }

}
