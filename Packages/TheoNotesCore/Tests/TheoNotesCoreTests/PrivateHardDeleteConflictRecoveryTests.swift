// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// Full private-server engine reproduction, independent of CloudKit applier/commit seams.
@Suite struct PrivateHardDeleteConflictRecoveryTests {
    @Test func immutableAttachmentAndHardDeleteRecoverConcurrentProtectedRemoteBytesAndSettle() async throws {
        let key = SymmetricKey(size: .bits256)
        let a = try SyncMaterializerTests.Library(key: key, enabled: false)
        let b = try SyncMaterializerTests.Library(key: key, enabled: false)
        defer { a.cleanup(); b.cleanup() }
        let baseline = Data("initial attachment bytes".utf8)
        let localEdit = Data("offline bytes explicitly deleted after snapshot".utf8)
        let remoteEdit = Data("competing REMOTE attachment bytes MUST survive exactly\0".utf8) + Data([0, 255, 19, 128])
        let note = try a.store.create(text: "# Delete versus remote lock\n" + AttachmentMarkdown.link(for: "file.bin"))
        _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: baseline, filename: "file.bin", to: note.id)
        let accessA = try NotePrivacy(store: a.store).setPassword("fixture-password")
        defer { accessA.revoke() }
        let server = SyncEngineTests.Server()
        let blobs = SyncPrivacyTransitionTests.SharedBlobs(libraries: [(a.db, a.paths), (b.db, b.paths)])
        let left = SyncEngine(database: a.db, paths: a.paths, accountID: "account", vaultKey: key, transport: server, blobs: blobs)
        let right = SyncEngine(database: b.db, paths: b.paths, accountID: "account", vaultKey: key, transport: server, blobs: blobs)
        try a.queue.enable(accountID: "account")
        _ = try await left.synchronize()
        _ = try await right.synchronize()
        let accessB = try NotePrivacy(store: b.store).unlock(password: "fixture-password")
        defer { accessB.revoke() }
        try b.queue.enable(accountID: "account")
        _ = try await right.synchronize(); _ = try await left.synchronize()
        let attachmentID = try #require(try await b.db.pool.read {
            try String.fetchOne($0, sql: "SELECT id FROM attachment WHERE noteId=?", arguments: [note.id])
        })
        try AttachmentFiles(paths: b.paths, database: b.db).write(
            [ImportedAttachment(filename: "file.bin", data: localEdit)], noteId: note.id, replacing: true) { _ in }
        _ = try await SyncAttachmentPreparer(database: b.db, paths: b.paths, accountID: "account", vaultKey: key).preparePending()
        for _ in 0..<20 { if try b.queue.prepareNext(vaultKey: key) == nil { break } }
        let immutable = try #require(try b.queue.pendingMutations().first { $0.entityType == .attachment && $0.entityId == attachmentID })
        try b.store.trash([note.id])
        #expect(try b.store.emptyTrash(ids: [note.id]) == [note.id])
        #expect(try b.store.note(id: note.id) == nil)
        #expect(try b.queue.pendingMutations().contains(immutable))
        for _ in 0..<20 { if try b.queue.prepareNext(vaultKey: key) == nil { break } }
        let deletion = try #require(try b.queue.pendingMutations().first { $0.entityType == .note && $0.entityId == note.id })
        // An older immutable NOTE snapshot may also predate deletion. The actual deletion
        // intent is the current dirty tombstone, not the immutable wire snapshot's flag.
        #expect(try await b.db.pool.read {
            try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM sync_dirty WHERE entityType='note' AND localId=? AND tombstone=1)", arguments: [note.id])
        } == true)
        try AttachmentFiles(paths: a.paths, database: a.db).write(
            [ImportedAttachment(filename: "file.bin", data: remoteEdit)], noteId: note.id, replacing: true) { _ in }
        try accessA.lock(noteId: note.id)
        _ = try await left.synchronize(noteAccess: accessA)
        let remoteNote = try #require(await server.entities["note:" + note.id])
        let copyID = SyncNoteMerge.conflictID(entityID: note.id, mutationID: deletion.mutationId, remoteRevision: remoteNote.revision)
        let remoteAttachment = try #require(await server.entities["attachment:" + attachmentID])
        let standaloneID = SyncNoteMerge.conflictID(entityID: attachmentID, mutationID: immutable.mutationId, remoteRevision: remoteAttachment.revision)
        let allowedIDs: Set<String> = [copyID, standaloneID]
        var leftSummary = SyncRunSummary(), rightSummary = SyncRunSummary()
        for _ in 0..<8 {
            rightSummary = try await right.synchronize(noteAccess: accessB)
            leftSummary = try await left.synchronize(noteAccess: accessA)
        }
        #expect(leftSummary.pendingUploads == 0 && leftSummary.pendingDownloads == 0)
        #expect(rightSummary.pendingUploads == 0 && rightSummary.pendingDownloads == 0)
        #expect(leftSummary.deferredConflicts == 0 && rightSummary.deferredConflicts == 0)
        for (library, access) in [(a, accessA), (b, accessB)] {
            #expect(try library.queue.pendingMutations().isEmpty)
            #expect(try library.queue.pendingCount() == 0)
            #expect(try library.inbox.pending().isEmpty)
            let recovered = try library.store.allNotes().map(\.id)
            #expect(Set(recovered).isSubset(of: allowedIDs) && recovered.contains(copyID))
            for id in recovered { #expect(try Self.protectedBytes(id, library: library, access: access) == remoteEdit) }
            #expect(try Self.protectedBytes(copyID, library: library, access: access) == remoteEdit)
        }
        #expect(try b.store.note(id: note.id) == nil)
        let settledIDs = try a.store.allNotes().map(\.id).sorted()
        #expect(try b.store.allNotes().map(\.id).sorted() == settledIDs)
        for _ in 0..<3 {
            _ = try await right.synchronize(noteAccess: accessB)
            _ = try await left.synchronize(noteAccess: accessA)
        }
        #expect(try a.store.allNotes().map(\.id).sorted() == settledIDs)
        #expect(try b.store.allNotes().map(\.id).sorted() == settledIDs)
        #expect(try Self.protectedBytes(copyID, library: a, access: accessA) == remoteEdit)
        #expect(try Self.protectedBytes(copyID, library: b, access: accessB) == remoteEdit)
        await left.shutdown(); await right.shutdown()
    }

    @Test func previouslyLockedHardDeletedParentRecoversRemoteUnlockedEditProtected() async throws {
        let key = SymmetricKey(size: .bits256)
        let a = try SyncMaterializerTests.Library(key: key, enabled: false)
        let b = try SyncMaterializerTests.Library(key: key, enabled: false)
        defer { a.cleanup(); b.cleanup() }
        let baseline = Data("initial attachment bytes".utf8)
        let localEdit = Data("offline bytes explicitly deleted after snapshot".utf8)
        let remoteEdit = Data("competing REMOTE attachment bytes MUST survive exactly\0".utf8) + Data([0, 255, 19, 128])
        let note = try a.store.create(text: "# Delete versus remote lock\n" + AttachmentMarkdown.link(for: "file.bin"))
        _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: baseline, filename: "file.bin", to: note.id)
        let accessA = try NotePrivacy(store: a.store).setPassword("fixture-password")
        defer { accessA.revoke() }
        try accessA.lock(noteId: note.id)
        let server = SyncEngineTests.Server()
        let blobs = SyncPrivacyTransitionTests.SharedBlobs(libraries: [(a.db, a.paths), (b.db, b.paths)])
        let left = SyncEngine(database: a.db, paths: a.paths, accountID: "account", vaultKey: key, transport: server, blobs: blobs)
        let right = SyncEngine(database: b.db, paths: b.paths, accountID: "account", vaultKey: key, transport: server, blobs: blobs)
        try a.queue.enable(accountID: "account")
        _ = try await left.synchronize()
        _ = try await right.synchronize()
        let accessB = try NotePrivacy(store: b.store).unlock(password: "fixture-password")
        defer { accessB.revoke() }
        try b.queue.enable(accountID: "account")
        _ = try await right.synchronize(); _ = try await left.synchronize()
        let attachmentID = try #require(try await b.db.pool.read {
            try String.fetchOne($0, sql: "SELECT id FROM attachment WHERE noteId=?", arguments: [note.id])
        })
        try accessB.removeLock(noteId: note.id)
        try AttachmentFiles(paths: b.paths, database: b.db).write(
            [ImportedAttachment(filename: "file.bin", data: localEdit)], noteId: note.id, replacing: true) { _ in }
        try accessB.lock(noteId: note.id)
        _ = try await SyncAttachmentPreparer(database: b.db, paths: b.paths, accountID: "account", vaultKey: key).preparePending()
        for _ in 0..<20 { if try b.queue.prepareNext(vaultKey: key) == nil { break } }
        let immutable = try #require(try b.queue.pendingMutations().first { $0.entityType == .attachment && $0.entityId == attachmentID })
        try b.store.trash([note.id])
        #expect(try b.store.emptyTrash(ids: [note.id]) == [note.id])
        #expect(try b.store.note(id: note.id) == nil)
        #expect(try b.queue.pendingMutations().contains(immutable))
        for _ in 0..<20 { if try b.queue.prepareNext(vaultKey: key) == nil { break } }
        let deletion = try #require(try b.queue.pendingMutations().first { $0.entityType == .note && $0.entityId == note.id })
        // An older immutable NOTE snapshot may also predate deletion. The actual deletion
        // intent is the current dirty tombstone, not the immutable wire snapshot's flag.
        #expect(try await b.db.pool.read {
            try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM sync_dirty WHERE entityType='note' AND localId=? AND tombstone=1)", arguments: [note.id])
        } == true)
        try accessA.removeLock(noteId: note.id)
        try AttachmentFiles(paths: a.paths, database: a.db).write(
            [ImportedAttachment(filename: "file.bin", data: remoteEdit)], noteId: note.id, replacing: true) { _ in }
        _ = try await left.synchronize(noteAccess: accessA)
        let remoteNote = try #require(await server.entities["note:" + note.id])
        let copyID = SyncNoteMerge.conflictID(entityID: note.id, mutationID: deletion.mutationId, remoteRevision: remoteNote.revision)
        let remoteAttachment = try #require(await server.entities["attachment:" + attachmentID])
        let standaloneID = SyncNoteMerge.conflictID(entityID: attachmentID, mutationID: immutable.mutationId, remoteRevision: remoteAttachment.revision)
        let allowedIDs: Set<String> = [copyID, standaloneID]
        var leftSummary = SyncRunSummary(), rightSummary = SyncRunSummary()
        for _ in 0..<8 {
            rightSummary = try await right.synchronize(noteAccess: accessB)
            leftSummary = try await left.synchronize(noteAccess: accessA)
        }
        #expect(leftSummary.pendingUploads == 0 && leftSummary.pendingDownloads == 0)
        #expect(rightSummary.pendingUploads == 0 && rightSummary.pendingDownloads == 0)
        #expect(leftSummary.deferredConflicts == 0 && rightSummary.deferredConflicts == 0)
        for (library, access) in [(a, accessA), (b, accessB)] {
            #expect(try library.queue.pendingMutations().isEmpty)
            #expect(try library.queue.pendingCount() == 0)
            #expect(try library.inbox.pending().isEmpty)
            let recovered = try library.store.allNotes().map(\.id)
            #expect(Set(recovered).isSubset(of: allowedIDs) && recovered.contains(copyID))
            for id in recovered { #expect(try Self.protectedBytes(id, library: library, access: access) == remoteEdit) }
            #expect(try Self.protectedBytes(copyID, library: library, access: access) == remoteEdit)
        }
        #expect(try b.store.note(id: note.id) == nil)
        let settledIDs = try a.store.allNotes().map(\.id).sorted()
        #expect(try b.store.allNotes().map(\.id).sorted() == settledIDs)
        for _ in 0..<3 {
            _ = try await right.synchronize(noteAccess: accessB)
            _ = try await left.synchronize(noteAccess: accessA)
        }
        #expect(try a.store.allNotes().map(\.id).sorted() == settledIDs)
        #expect(try b.store.allNotes().map(\.id).sorted() == settledIDs)
        #expect(try Self.protectedBytes(copyID, library: a, access: accessA) == remoteEdit)
        #expect(try Self.protectedBytes(copyID, library: b, access: accessB) == remoteEdit)
        await left.shutdown(); await right.shutdown()
    }

    @Test(arguments: [false, true], [false, true]) func attachmentOnlyEditAfterHardDeleteRecoversBytesAndSettles(unknownHistory: Bool, offlineLock: Bool) async throws {
        let key = SymmetricKey(size: .bits256)
        let a = try SyncMaterializerTests.Library(key: key, enabled: false)
        let b = try SyncMaterializerTests.Library(key: key, enabled: false)
        defer { a.cleanup(); b.cleanup() }
        let baseline = Data("initial attachment bytes".utf8)
        let localEdit = Data("offline bytes explicitly deleted after snapshot".utf8)
        let remoteEdit = Data("competing REMOTE attachment bytes MUST survive exactly\0".utf8) + Data([0, 255, 19, 128])
        let note = try a.store.create(text: "# Delete versus remote lock\n" + AttachmentMarkdown.link(for: "file.bin"))
        _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: baseline, filename: "file.bin", to: note.id)
        let accessA = try NotePrivacy(store: a.store).setPassword("fixture-password")
        defer { accessA.revoke() }
        let server = SyncEngineTests.Server()
        let blobs = SyncPrivacyTransitionTests.SharedBlobs(libraries: [(a.db, a.paths), (b.db, b.paths)])
        let left = SyncEngine(database: a.db, paths: a.paths, accountID: "account", vaultKey: key, transport: server, blobs: blobs)
        let right = SyncEngine(database: b.db, paths: b.paths, accountID: "account", vaultKey: key, transport: server, blobs: blobs)
        try a.queue.enable(accountID: "account")
        _ = try await left.synchronize()
        _ = try await right.synchronize()
        let accessB = try NotePrivacy(store: b.store).unlock(password: "fixture-password")
        defer { accessB.revoke() }
        try b.queue.enable(accountID: "account")
        _ = try await right.synchronize(); _ = try await left.synchronize()
        let attachmentID = try #require(try await b.db.pool.read {
            try String.fetchOne($0, sql: "SELECT id FROM attachment WHERE noteId=?", arguments: [note.id])
        })
        try AttachmentFiles(paths: b.paths, database: b.db).write(
            [ImportedAttachment(filename: "file.bin", data: localEdit)], noteId: note.id, replacing: true) { _ in }
        _ = try await SyncAttachmentPreparer(database: b.db, paths: b.paths, accountID: "account", vaultKey: key).preparePending()
        for _ in 0..<20 { if try b.queue.prepareNext(vaultKey: key) == nil { break } }
        let immutable = try #require(try b.queue.pendingMutations().first { $0.entityType == .attachment && $0.entityId == attachmentID })
        if offlineLock { try accessB.lock(noteId: note.id) }
        try b.store.trash([note.id])
        #expect(try b.store.emptyTrash(ids: [note.id]) == [note.id])
        #expect(try b.store.note(id: note.id) == nil)
        #expect(try b.queue.pendingMutations().contains(immutable))
        for _ in 0..<20 { if try b.queue.prepareNext(vaultKey: key) == nil { break } }
        let noteAttempt = try #require(try b.queue.pendingMutations().first { $0.entityType == .note && $0.entityId == note.id })
        // An older immutable NOTE snapshot may also predate deletion. The actual deletion
        // intent is the current dirty tombstone, not the immutable wire snapshot's flag.
        #expect(try await b.db.pool.read {
            try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM sync_dirty WHERE entityType='note' AND localId=? AND tombstone=1)", arguments: [note.id])
        } == true)
        if unknownHistory {
            try await b.db.pool.write { db in
                try db.execute(sql: "DELETE FROM sync_shadow WHERE entityType='note' AND entityId=?", arguments: [note.id])
            }
        }
        try AttachmentFiles(paths: a.paths, database: a.db).write(
            [ImportedAttachment(filename: "file.bin", data: remoteEdit)], noteId: note.id, replacing: true) { _ in }
        _ = try await left.synchronize(noteAccess: accessA)
        let remoteAttachment = try #require(await server.entities["attachment:" + attachmentID])
        let copyID = SyncNoteMerge.conflictID(entityID: attachmentID, mutationID: immutable.mutationId, remoteRevision: remoteAttachment.revision)
        let remoteNote = try #require(await server.entities["note:" + note.id])
        let noteCopyID = SyncNoteMerge.conflictID(entityID: note.id, mutationID: noteAttempt.mutationId, remoteRevision: remoteNote.revision)
        let pulledNoteCopyID = SyncNoteMerge.conflictID(entityID: note.id, mutationID: remoteNote.mutation.mutationId, remoteRevision: remoteNote.revision)
        let allowedIDs: Set<String> = unknownHistory ? [copyID, noteCopyID, pulledNoteCopyID] : [copyID]
        var leftSummary = SyncRunSummary(), rightSummary = SyncRunSummary()
        for _ in 0..<8 {
            rightSummary = try await right.synchronize(noteAccess: accessB)
            leftSummary = try await left.synchronize(noteAccess: accessA)

        }
        #expect(leftSummary.pendingUploads == 0 && leftSummary.pendingDownloads == 0)
        #expect(rightSummary.pendingUploads == 0 && rightSummary.pendingDownloads == 0)
        #expect(leftSummary.deferredConflicts == 0 && rightSummary.deferredConflicts == 0)
        for (library, access) in [(a, accessA), (b, accessB)] {
            #expect(try library.queue.pendingMutations().isEmpty)
            #expect(try library.queue.pendingCount() == 0)
            #expect(try library.inbox.pending().isEmpty)
            let actualIDs = Set(try library.store.allNotes().map(\.id))
            #expect(actualIDs.count == (unknownHistory ? 2 : 1) && actualIDs.contains(copyID) && actualIDs.isSubset(of: allowedIDs))
            for id in actualIDs { #expect(try Self.protectedBytes(id, library: library, access: access) == remoteEdit) }
            #expect(try Self.protectedBytes(copyID, library: library, access: access) == remoteEdit)
        }
        #expect(try b.store.note(id: note.id) == nil)
        let settledIDs = try a.store.allNotes().map(\.id).sorted()
        #expect(try b.store.allNotes().map(\.id).sorted() == settledIDs)
        for _ in 0..<3 {
            _ = try await right.synchronize(noteAccess: accessB)
            _ = try await left.synchronize(noteAccess: accessA)
        }
        #expect(try a.store.allNotes().map(\.id).sorted() == settledIDs)
        #expect(try b.store.allNotes().map(\.id).sorted() == settledIDs)
        #expect(try Self.protectedBytes(copyID, library: a, access: accessA) == remoteEdit)
        #expect(try Self.protectedBytes(copyID, library: b, access: accessB) == remoteEdit)
        await left.shutdown(); await right.shutdown()
    }

    @Test func missingParentHistoryPreservesNewerRemoteNoteEdit() async throws {
        let unknownHistory = true
        let key = SymmetricKey(size: .bits256)
        let a = try SyncMaterializerTests.Library(key: key, enabled: false)
        let b = try SyncMaterializerTests.Library(key: key, enabled: false)
        defer { a.cleanup(); b.cleanup() }
        let baseline = Data("initial attachment bytes".utf8)
        let localEdit = Data("offline bytes explicitly deleted after snapshot".utf8)
        let remoteEdit = Data("competing REMOTE attachment bytes MUST survive exactly\0".utf8) + Data([0, 255, 19, 128])
        let note = try a.store.create(text: "# Delete versus remote lock\n" + AttachmentMarkdown.link(for: "file.bin"))
        _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: baseline, filename: "file.bin", to: note.id)
        let accessA = try NotePrivacy(store: a.store).setPassword("fixture-password")
        defer { accessA.revoke() }
        let server = SyncEngineTests.Server()
        let blobs = SyncPrivacyTransitionTests.SharedBlobs(libraries: [(a.db, a.paths), (b.db, b.paths)])
        let left = SyncEngine(database: a.db, paths: a.paths, accountID: "account", vaultKey: key, transport: server, blobs: blobs)
        let right = SyncEngine(database: b.db, paths: b.paths, accountID: "account", vaultKey: key, transport: server, blobs: blobs)
        try a.queue.enable(accountID: "account")
        _ = try await left.synchronize()
        _ = try await right.synchronize()
        let accessB = try NotePrivacy(store: b.store).unlock(password: "fixture-password")
        defer { accessB.revoke() }
        try b.queue.enable(accountID: "account")
        _ = try await right.synchronize(); _ = try await left.synchronize()
        let attachmentID = try #require(try await b.db.pool.read {
            try String.fetchOne($0, sql: "SELECT id FROM attachment WHERE noteId=?", arguments: [note.id])
        })
        try AttachmentFiles(paths: b.paths, database: b.db).write(
            [ImportedAttachment(filename: "file.bin", data: localEdit)], noteId: note.id, replacing: true) { _ in }
        _ = try await SyncAttachmentPreparer(database: b.db, paths: b.paths, accountID: "account", vaultKey: key).preparePending()
        for _ in 0..<20 { if try b.queue.prepareNext(vaultKey: key) == nil { break } }
        let immutable = try #require(try b.queue.pendingMutations().first { $0.entityType == .attachment && $0.entityId == attachmentID })
        try b.store.trash([note.id])
        #expect(try b.store.emptyTrash(ids: [note.id]) == [note.id])
        #expect(try b.store.note(id: note.id) == nil)
        #expect(try b.queue.pendingMutations().contains(immutable))
        for _ in 0..<20 { if try b.queue.prepareNext(vaultKey: key) == nil { break } }
        let noteAttempt = try #require(try b.queue.pendingMutations().first { $0.entityType == .note && $0.entityId == note.id })
        // An older immutable NOTE snapshot may also predate deletion. The actual deletion
        // intent is the current dirty tombstone, not the immutable wire snapshot's flag.
        #expect(try await b.db.pool.read {
            try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM sync_dirty WHERE entityType='note' AND localId=? AND tombstone=1)", arguments: [note.id])
        } == true)
        if unknownHistory {
            try await b.db.pool.write { db in
                try db.execute(sql: "DELETE FROM sync_shadow WHERE entityType='note' AND entityId=?", arguments: [note.id])
            }
        }
        let before = try #require(try a.store.note(id: note.id))
        _ = try a.store.updateText(id: note.id, text: "# NEWER remote note edit must survive\n" + AttachmentMarkdown.link(for: "file.bin"), expectedRevision: before.revision)
        try AttachmentFiles(paths: a.paths, database: a.db).write(
            [ImportedAttachment(filename: "file.bin", data: remoteEdit)], noteId: note.id, replacing: true) { _ in }
        _ = try await left.synchronize(noteAccess: accessA)
        let remoteAttachment = try #require(await server.entities["attachment:" + attachmentID])
        let copyID = SyncNoteMerge.conflictID(entityID: attachmentID, mutationID: immutable.mutationId, remoteRevision: remoteAttachment.revision)
        let remoteNote = try #require(await server.entities["note:" + note.id])
        let noteCopyID = SyncNoteMerge.conflictID(entityID: note.id, mutationID: noteAttempt.mutationId, remoteRevision: remoteNote.revision)
        let pulledNoteCopyID = SyncNoteMerge.conflictID(entityID: note.id, mutationID: remoteNote.mutation.mutationId, remoteRevision: remoteNote.revision)
        let allowedIDs: Set<String> = unknownHistory ? [copyID, noteCopyID, pulledNoteCopyID] : [copyID]
        var leftSummary = SyncRunSummary(), rightSummary = SyncRunSummary()
        for _ in 0..<8 {
            rightSummary = try await right.synchronize(noteAccess: accessB)
            leftSummary = try await left.synchronize(noteAccess: accessA)
        }
        #expect(leftSummary.pendingUploads == 0 && leftSummary.pendingDownloads == 0)
        #expect(rightSummary.pendingUploads == 0 && rightSummary.pendingDownloads == 0)
        #expect(leftSummary.deferredConflicts == 0 && rightSummary.deferredConflicts == 0)
        for (library, access) in [(a, accessA), (b, accessB)] {
            #expect(try library.queue.pendingMutations().isEmpty)
            #expect(try library.queue.pendingCount() == 0)
            #expect(try library.inbox.pending().isEmpty)
            let actualIDs = Set(try library.store.allNotes().map(\.id))
            #expect(!actualIDs.isEmpty && actualIDs.count <= 2 && actualIDs.isSubset(of: allowedIDs))
            let texts = try actualIDs.map { try #require(try access.note(id: $0)).text }
            #expect(texts.contains { $0.contains("NEWER remote note edit must survive") })
            if unknownHistory { for id in actualIDs { #expect(try Self.protectedBytes(id, library: library, access: access) == remoteEdit) } }

        }
        #expect(try b.store.note(id: note.id) == nil)
        let settledIDs = try a.store.allNotes().map(\.id).sorted()
        #expect(try b.store.allNotes().map(\.id).sorted() == settledIDs)
        for _ in 0..<3 {
            _ = try await right.synchronize(noteAccess: accessB)
            _ = try await left.synchronize(noteAccess: accessA)
        }
        #expect(try a.store.allNotes().map(\.id).sorted() == settledIDs)
        #expect(try b.store.allNotes().map(\.id).sorted() == settledIDs)


        await left.shutdown(); await right.shutdown()
    }

    @Test func acceptedParentTombstoneStillRecoversLaterAttachmentOnlyEditProtected() async throws {
        let key = SymmetricKey(size: .bits256)
        let a = try SyncMaterializerTests.Library(key: key, enabled: false)
        let b = try SyncMaterializerTests.Library(key: key, enabled: false)
        defer { a.cleanup(); b.cleanup() }
        let remoteBytes = Data("attachment edit authored offline before seeing accepted parent deletion".utf8)
        let note = try a.store.create(text: "# Accepted deletion\n" + AttachmentMarkdown.link(for: "file.bin"))
        _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: Data("baseline".utf8), filename: "file.bin", to: note.id)
        let accessA = try NotePrivacy(store: a.store).setPassword("fixture-password")
        defer { accessA.revoke() }
        let server = SyncEngineTests.Server()
        let blobs = SyncPrivacyTransitionTests.SharedBlobs(libraries: [(a.db, a.paths), (b.db, b.paths)])
        let left = SyncEngine(database: a.db, paths: a.paths, accountID: "account", vaultKey: key, transport: server, blobs: blobs)
        let right = SyncEngine(database: b.db, paths: b.paths, accountID: "account", vaultKey: key, transport: server, blobs: blobs)
        try a.queue.enable(accountID: "account")
        _ = try await left.synchronize(); _ = try await right.synchronize()
        let accessB = try NotePrivacy(store: b.store).unlock(password: "fixture-password")
        defer { accessB.revoke() }
        try b.queue.enable(accountID: "account")
        _ = try await right.synchronize(); _ = try await left.synchronize()
        let attachmentID = try #require(try await b.db.pool.read {
            try String.fetchOne($0, sql: "SELECT id FROM attachment WHERE noteId=?", arguments: [note.id])
        })
        try b.store.trash([note.id]); _ = try b.store.emptyTrash(ids: [note.id])
        for _ in 0..<3 { _ = try await right.synchronize(noteAccess: accessB) }
        #expect(try b.queue.pendingCount() == 0 && b.queue.pendingMutations().isEmpty)
        #expect(try #require(await server.entities["note:" + note.id]).mutation.tombstone)
        #expect(try #require(await server.entities["attachment:" + attachmentID]).mutation.tombstone)
        // The other peer still has its offline parent/file. No NOTE record is authored here.
        try AttachmentFiles(paths: a.paths, database: a.db).write(
            [ImportedAttachment(filename: "file.bin", data: remoteBytes)], noteId: note.id, replacing: true) { _ in }
        var ls = SyncRunSummary(), rs = SyncRunSummary()
        for _ in 0..<10 {
            ls = try await left.synchronize(noteAccess: accessA)
            rs = try await right.synchronize(noteAccess: accessB)
        }
        #expect(ls.pendingUploads == 0 && ls.pendingDownloads == 0 && ls.deferredConflicts == 0)
        #expect(rs.pendingUploads == 0 && rs.pendingDownloads == 0 && rs.deferredConflicts == 0)
        let ids = try b.store.allNotes().map(\.id).sorted()
        #expect(ids.count == 1)
        #expect(try a.store.allNotes().map(\.id).sorted() == ids)
        for (library, access) in [(a, accessA), (b, accessB)] {
            for id in ids { #expect(try Self.protectedBytes(id, library: library, access: access) == remoteBytes) }
            #expect(try library.queue.pendingCount() == 0 && library.queue.pendingMutations().isEmpty)
            #expect(try library.inbox.pending().isEmpty)
        }
        for _ in 0..<3 { _ = try await left.synchronize(noteAccess: accessA); _ = try await right.synchronize(noteAccess: accessB) }
        #expect(try a.store.allNotes().map(\.id).sorted() == ids)
        #expect(try b.store.allNotes().map(\.id).sorted() == ids)
        await left.shutdown(); await right.shutdown()
    }

    @Test func noVaultAcceptedParentTombstoneRecoversLaterAttachmentOnlyEditPlain() async throws {
        let key = SymmetricKey(size: .bits256)
        let a = try SyncMaterializerTests.Library(key: key, enabled: false)
        let b = try SyncMaterializerTests.Library(key: key, enabled: false)
        defer { a.cleanup(); b.cleanup() }
        let remoteBytes = Data("attachment edit authored offline before seeing accepted parent deletion".utf8)
        let note = try a.store.create(text: "# Accepted deletion\n" + AttachmentMarkdown.link(for: "file.bin"))
        _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: Data("baseline".utf8), filename: "file.bin", to: note.id)
        let accessA: LockedNoteAccess? = nil
        defer { accessA?.revoke() }
        let server = SyncEngineTests.Server()
        let blobs = SyncPrivacyTransitionTests.SharedBlobs(libraries: [(a.db, a.paths), (b.db, b.paths)])
        let left = SyncEngine(database: a.db, paths: a.paths, accountID: "account", vaultKey: key, transport: server, blobs: blobs)
        let right = SyncEngine(database: b.db, paths: b.paths, accountID: "account", vaultKey: key, transport: server, blobs: blobs)
        try a.queue.enable(accountID: "account")
        _ = try await left.synchronize(); _ = try await right.synchronize()
        let accessB: LockedNoteAccess? = nil
        defer { accessB?.revoke() }
        try b.queue.enable(accountID: "account")
        _ = try await right.synchronize(); _ = try await left.synchronize()
        let attachmentID = try #require(try await b.db.pool.read {
            try String.fetchOne($0, sql: "SELECT id FROM attachment WHERE noteId=?", arguments: [note.id])
        })
        try b.store.trash([note.id]); _ = try b.store.emptyTrash(ids: [note.id])
        for _ in 0..<3 { _ = try await right.synchronize(noteAccess: accessB) }
        #expect(try b.queue.pendingCount() == 0 && b.queue.pendingMutations().isEmpty)
        #expect(try #require(await server.entities["note:" + note.id]).mutation.tombstone)
        #expect(try #require(await server.entities["attachment:" + attachmentID]).mutation.tombstone)
        // The other peer still has its offline parent/file. No NOTE record is authored here.
        try AttachmentFiles(paths: a.paths, database: a.db).write(
            [ImportedAttachment(filename: "file.bin", data: remoteBytes)], noteId: note.id, replacing: true) { _ in }
        var ls = SyncRunSummary(), rs = SyncRunSummary()
        for _ in 0..<10 {
            ls = try await left.synchronize(noteAccess: accessA)
            rs = try await right.synchronize(noteAccess: accessB)
        }
        #expect(ls.pendingUploads == 0 && ls.pendingDownloads == 0 && ls.deferredConflicts == 0)
        #expect(rs.pendingUploads == 0 && rs.pendingDownloads == 0 && rs.deferredConflicts == 0)
        let ids = try b.store.allNotes().map(\.id).sorted()
        #expect(ids.count == 1)
        #expect(try a.store.allNotes().map(\.id).sorted() == ids)
        for (library, access) in [(a, accessA), (b, accessB)] {
            for id in ids { #expect(try Self.plainBytes(id, library: library, access: access) == remoteBytes) }
            #expect(try library.queue.pendingCount() == 0 && library.queue.pendingMutations().isEmpty)
            #expect(try library.inbox.pending().isEmpty)
        }
        for _ in 0..<3 { _ = try await left.synchronize(noteAccess: accessA); _ = try await right.synchronize(noteAccess: accessB) }
        #expect(try a.store.allNotes().map(\.id).sorted() == ids)
        #expect(try b.store.allNotes().map(\.id).sorted() == ids)
        await left.shutdown(); await right.shutdown()
    }

    @Test func legacyEmptyAttachmentMapRecoversDeletedRemoteDocumentProtected() throws {
        let key = SymmetricKey(size: .bits256)
        let original = Note(id: UUID().uuidString.lowercased(), text: "# Legacy body\nretained verbatim", title: "Legacy body", titleKey: "legacy body", createdAt: .now, modifiedAt: .now)
        var remote = SyncNotePayload(note: original, directTags: [], pinnedTags: [], attachmentIds: [])
        remote.attachmentNames = nil
        let result = try SyncLockedNoteMerge.deletedUnknownParentConflict(remote: remote,
            entityID: original.id, mutationID: UUID().uuidString.lowercased(), revision: 2, key: key)
        guard case .conflict(let local, let copy) = result, let copy else { Issue.record("Expected protected deleted-parent recovery"); return }
        #expect(local == nil && copy.id != original.id && copy.isLocked && copy.text.isEmpty)
        try copy.validate()
        let body = try JSONDecoder().decode(LockedNotePayload.self,
            from: NoteCipher.open(try #require(copy.encryptedPayload), vaultKey: key, context: copy.id))
        #expect(body.text == original.text && body.attachments.isEmpty && body.attachmentIDs?.isEmpty == true)
    }

    @Test func incompleteLegacyAttachmentMapFailsClosedWithoutInventingFilename() throws {
        let key = SymmetricKey(size: .bits256)
        let note = Note(id: UUID().uuidString.lowercased(), text: "# Missing mapping", title: "Missing mapping", titleKey: "missing mapping", createdAt: .now, modifiedAt: .now)
        let first = UUID().uuidString.lowercased(), second = UUID().uuidString.lowercased()
        var copy = SyncNotePayload(note: note, directTags: [], pinnedTags: [], attachmentIds: [first, second])
        copy.attachmentNames = nil
        #expect(throws: SyncQueueError.snapshotUnavailable) {
            try SyncLockedNoteMerge.protectDeletedRecovery(copy, key: key)
        }
        #expect(throws: SyncQueueError.snapshotUnavailable) {
            try SyncLockedNoteMerge.protectDeletedRecovery(copy, key: key, sourceNames: [first: "known.bin"])
        }
        let protected = try SyncLockedNoteMerge.protectDeletedRecovery(copy, key: key,
            sourceNames: [first: "known.bin", second: "other.bin"])
        let body = try JSONDecoder().decode(LockedNotePayload.self,
            from: NoteCipher.open(try #require(protected.encryptedPayload), vaultKey: key, context: protected.id))
        #expect(Set(body.attachments.keys) == ["known.bin", "other.bin"])
    }

    private static func plainBytes(_ id: String, library: SyncMaterializerTests.Library, access: LockedNoteAccess?) throws -> Data {
        let persisted = try #require(try library.store.note(id: id))
        #expect(!persisted.isLocked)
        let reference = try #require(NoteParser.attachmentLinks(in: persisted.text).first)
        return try Data(contentsOf: AttachmentFiles(paths: library.paths, database: library.db).directory(for: id).appendingPathComponent(reference.filename))
    }

    private static func protectedBytes(_ id: String, library: SyncMaterializerTests.Library, access: LockedNoteAccess) throws -> Data {
        let persisted = try #require(try library.store.note(id: id))
        #expect(persisted.isLocked && persisted.text.isEmpty)
        let readable = try #require(try access.note(id: id))
        let reference = try #require(NoteParser.attachmentLinks(in: readable.text).first)
        #expect(try library.db.pool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM attachment WHERE noteId=? AND deletedAt IS NULL", arguments: [id])
        } == 1)
        return try access.attachmentData(reference.filename, noteId: id, maximumBytes: 1024)
    }
}
