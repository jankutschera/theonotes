// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct SyncPrivacyTransitionTests {
    struct SharedBlobs: SyncBlobTransport {
        let libraries: [(AppDatabase, AppPaths)]
        func ensureUploaded(_ hashes: [String]) async throws {
            for hash in hashes { _ = try await download(hash: hash) }
        }
        func download(hash: String) async throws -> URL {
            for (database, paths) in libraries {
                if let path = try await database.pool.read({ try String.fetchOne($0, sql: "SELECT localPath FROM sync_blob_state WHERE hash=?", arguments: [hash]) }) {
                    return paths.root.appendingPathComponent(try SyncBlobLocation.relative(path))
                }
            }
            throw SyncQueueError.snapshotUnavailable
        }
    }

    @Test(arguments: [false, true]) func offlineUnlockAndProtectedEditPreserveBothBodiesAndTheirFiles(unlockingReceiver: Bool) async throws {
        let key = SymmetricKey(size: .bits256)
        let a = try SyncMaterializerTests.Library(key: key, enabled: false)
        let b = try SyncMaterializerTests.Library(key: key, enabled: false)
        defer { a.cleanup(); b.cleanup() }
        let original = try a.store.create(text: "# Original\n[asset](secret.txt)")
        let bytes = Data("file that survives a privacy conflict".utf8)
        _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: bytes, filename: "secret.txt", to: original.id)
        let leftAccess = try NotePrivacy(store: a.store).setPassword("note password"); defer { leftAccess.revoke() }
        try leftAccess.lock(noteId: original.id)
        let server = SyncEngineTests.Server(), blobs = SharedBlobs(libraries: [(a.db, a.paths), (b.db, b.paths)])
        let left = SyncEngine(database: a.db, paths: a.paths, accountID: "account", vaultKey: key, transport: server, blobs: blobs)
        let right = SyncEngine(database: b.db, paths: b.paths, accountID: "account", vaultKey: key, transport: server, blobs: blobs)
        try a.queue.enable(accountID: "account")
        _ = try await left.synchronize()
        #expect(try await right.synchronize().pendingDownloads == 0)
        let rightAccess = try NotePrivacy(store: b.store).unlock(password: "note password"); defer { rightAccess.revoke() }
        try b.queue.enable(accountID: "account")
        _ = try await right.synchronize(); _ = try await left.synchronize()
        let protectedText = "# Protected edit\n[asset](secret.txt)"
        let plainText = "# Unlocked edit\n[asset](secret.txt)"
        let unlockedLibrary = unlockingReceiver ? b : a
        let unlockedAccess = unlockingReceiver ? rightAccess : leftAccess
        let protectedLibrary = unlockingReceiver ? a : b
        let protectedAccess = unlockingReceiver ? leftAccess : rightAccess
        try unlockedAccess.removeLock(noteId: original.id)
        let unlocked = try #require(try unlockedLibrary.store.note(id: original.id))
        _ = try unlockedLibrary.store.updateText(id: original.id, text: plainText, expectedRevision: unlocked.revision)
        let protected = try #require(try protectedLibrary.store.note(id: original.id))
        _ = try protectedAccess.updateText(id: original.id, text: protectedText, expectedRevision: protected.revision)
        _ = try await left.synchronize(noteAccess: leftAccess)
        let reconciled = try await right.synchronize(noteAccess: rightAccess)
        #expect(reconciled.pendingUploads == 0 && reconciled.pendingDownloads == 0 && reconciled.waitingForUnlock == 0)
        _ = try await left.synchronize(noteAccess: leftAccess)
        _ = try await right.synchronize(noteAccess: rightAccess)
        let leftNotes = try await a.db.pool.read { try Note.fetchAll($0).sorted { $0.id < $1.id } }
        let rightNotes = try await b.db.pool.read { try Note.fetchAll($0).sorted { $0.id < $1.id } }
        #expect(leftNotes.count == 2 && leftNotes.map(\.id) == rightNotes.map(\.id))
        #expect(leftNotes.map(\.isLocked) == rightNotes.map(\.isLocked))
        for (library, access, notes) in [(a, leftAccess, leftNotes), (b, rightAccess, rightNotes)] {
            #expect(try Set(notes.compactMap { try access.note(id: $0.id)?.text }) == [protectedText, plainText])
            for note in notes {
                let output = library.paths.root.appendingPathComponent("verified-" + note.id)
                if note.isLocked {
                    #expect(note.text.isEmpty)
                    #expect(try access.note(id: note.id)?.text == protectedText)
                    try access.decryptAttachment("secret.txt", noteId: note.id, to: output)
                    #expect(try Data(contentsOf: output) == bytes)
                } else {
                    #expect(note.text == plainText)
                    #expect(try Data(contentsOf: library.paths.attachments.appendingPathComponent(note.id + "/secret.txt")) == bytes)
                }
            }
        }
        let reader = SyncPayloadReader(accountID: "account", vaultKey: key, blobs: blobs)
        for entity in await server.history where entity.mutation.entityType == .note {
            guard case .note(let payload) = try await reader.read(entity) else { Issue.record("Expected a live note"); continue }
            #expect(payload.attachmentSnapshots?.count == 1)
            #expect(payload.attachmentSnapshots?.values.allSatisfy { entity.mutation.blobRefs.contains($0.blobHash) } == true)
        }
        await left.shutdown(); await right.shutdown()
    }

}
