// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct CloudDeletedParentAttachmentRecoveryTests {
    @Test(arguments: [false, true], [false, true])
    func attachmentOnlyEditAfterHardDeleteRecoversBytesAndSettles(unknownHistory: Bool, offlineLock: Bool) async throws {
        try await withBlobWorld(2) { world in
            let a = world.devices[0], b = world.devices[1]
            let rigA = BlobRig(a), rigB = BlobRig(b)
            a.publishThrough(rigA); b.publishThrough(rigB)
            let baseline = try SketchSyncPNGFixture.baseline()
            let edits = try SketchSyncPNGFixture.conflictEdits(baseline: baseline)
            let note = try a.noteStore.create(text: "# Delete versus lock\n![](sketch.png)\n")
            _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: baseline, filename: "sketch.png", to: note.id)
            let accessA = try NotePrivacy(store: a.noteStore).setPassword("fixture-password")
            defer { accessA.revoke() }
            try await a.publish()
            try await b.fetchEntities(); _ = try await b.receiver(rigB).applyPending()
            let accessB = try NotePrivacy(store: b.noteStore).unlock(password: "fixture-password")
            defer { accessB.revoke() }
            let receiverB = CloudReconciler(database: b.db, paths: b.paths, store: b.store, accountID: b.accountID,
                vaultKey: b.key, pinner: CloudAssetPinner(directory: b.paths.cloudPinned), blobs: rigB.transfer,
                crash: b.crash, noteAccess: { accessB })
            let receiverA = CloudReconciler(database: a.db, paths: a.paths, store: a.store, accountID: a.accountID,
                vaultKey: a.key, pinner: CloudAssetPinner(directory: a.paths.cloudPinned), blobs: rigA.transfer, noteAccess: { accessA })
            let id = try b.attachmentID(of: note.id)
            try SketchSyncPNGFixture.replace(edits.0, noteID: note.id, paths: b.paths, database: b.db)
            _ = try await b.publisher.prepare()
            #expect(try b.store.inflight(for: b.ref(id, type: "attachment")) != nil)
            if offlineLock { try accessB.lock(noteId: note.id) }
            try b.noteStore.trash([note.id])
            #expect(try b.noteStore.emptyTrash(ids: [note.id]) == [note.id])
            #expect(try b.noteStore.note(id: note.id) == nil)
            // A real competing attachment edit, not merely a privacy/representation change.
            try SketchSyncPNGFixture.replace(edits.1, noteID: note.id, paths: a.paths, database: a.db)
            try await a.publish()
            let rejected = try await b.publish()
            #expect(rejected.needsMerge.contains { $0.entityType == "attachment" && $0.entityId == id })
            try await b.fetchEntities()
            let attempt = try #require(try b.store.inflight(for: b.ref(id, type: "attachment")))
            let remote = try #require(try b.store.remote(recordName: "e.attachment.\(id)"))
            let copyID = SyncNoteMerge.conflictID(entityID: id, mutationID: attempt.attemptId, remoteRevision: remote.ver)
            if unknownHistory {
                try await b.db.pool.write { db in
                    try db.execute(sql: "DELETE FROM ck_record WHERE entityType='note' AND entityId=?", arguments: [note.id])
                }
            }
            for _ in 0..<6 {
                try await b.fetchEntities(); _ = try await receiverB.applyPending(); try await b.publish()
                try await a.fetchEntities(); _ = try await receiverA.applyPending(); try await a.publish()
            }
            for (device, access) in [(a, accessA), (b, accessB)] {
                #expect(try device.store.allRemote().isEmpty)
                #expect(try device.store.allInflight().isEmpty)
                #expect(try device.dirtyCount() == 0)
                #expect(try device.noteStore.allNotes().map(\.id) == [copyID])
                #expect(try device.noteStore.note(id: copyID)?.isLocked == true)
                #expect(try Self.recoveryBytes(copyID, on: device, access: access) == edits.1)
            }
            #expect(try b.noteStore.note(id: note.id) == nil) // Existing delete-vs-edit policy keeps local deletion.
            for _ in 0..<3 {
                try await b.fetchEntities(); _ = try await receiverB.applyPending(); try await b.publish()
                try await a.fetchEntities(); _ = try await receiverA.applyPending(); try await a.publish()
            }
            #expect(try a.noteStore.allNotes().map(\.id) == [copyID])
            #expect(try b.noteStore.allNotes().map(\.id) == [copyID])
            #expect(try Self.recoveryBytes(copyID, on: a, access: accessA) == edits.1)
            #expect(try Self.recoveryBytes(copyID, on: b, access: accessB) == edits.1)
        }
    }

    @Test
    func previouslyLockedHardDeletedParentRecoversRemoteUnlockedEditProtected() async throws {
        try await withBlobWorld(2) { world in
            let a = world.devices[0], b = world.devices[1]
            let rigA = BlobRig(a), rigB = BlobRig(b)
            a.publishThrough(rigA); b.publishThrough(rigB)
            let baseline = try SketchSyncPNGFixture.baseline()
            let edits = try SketchSyncPNGFixture.conflictEdits(baseline: baseline)
            let note = try a.noteStore.create(text: "# Delete versus lock\n![](sketch.png)\n")
            _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: baseline, filename: "sketch.png", to: note.id)
            let accessA = try NotePrivacy(store: a.noteStore).setPassword("fixture-password")
            defer { accessA.revoke() }
            try accessA.lock(noteId: note.id)
            try await a.publish()
            try await b.fetchEntities(); _ = try await b.receiver(rigB).applyPending()
            let accessB = try NotePrivacy(store: b.noteStore).unlock(password: "fixture-password")
            defer { accessB.revoke() }
            let receiverB = CloudReconciler(database: b.db, paths: b.paths, store: b.store, accountID: b.accountID,
                vaultKey: b.key, pinner: CloudAssetPinner(directory: b.paths.cloudPinned), blobs: rigB.transfer,
                crash: b.crash, noteAccess: { accessB })
            let receiverA = CloudReconciler(database: a.db, paths: a.paths, store: a.store, accountID: a.accountID,
                vaultKey: a.key, pinner: CloudAssetPinner(directory: a.paths.cloudPinned), blobs: rigA.transfer, noteAccess: { accessA })
            let id = try b.attachmentID(of: note.id)
            try accessB.removeLock(noteId: note.id)
            try SketchSyncPNGFixture.replace(edits.0, noteID: note.id, paths: b.paths, database: b.db)
            try accessB.lock(noteId: note.id)
            _ = try await b.publisher.prepare()
            #expect(try b.store.inflight(for: b.ref(id, type: "attachment")) != nil)
            try b.noteStore.trash([note.id])
            #expect(try b.noteStore.emptyTrash(ids: [note.id]) == [note.id])
            #expect(try b.noteStore.note(id: note.id) == nil)
            // A real competing attachment edit, not merely a privacy/representation change.
            try accessA.removeLock(noteId: note.id)
            try SketchSyncPNGFixture.replace(edits.1, noteID: note.id, paths: a.paths, database: a.db)
            try await a.publish()
            let rejected = try await b.publish()
            #expect(rejected.needsMerge.contains { $0.entityType == "attachment" && $0.entityId == id })
            try await b.fetchEntities()
            let noteAttempt = try #require(try b.store.inflight(for: b.ref(note.id)))
            let remoteNote = try #require(try b.store.remote(recordName: "e.note.\(note.id)"))
            let copyID = SyncNoteMerge.conflictID(entityID: note.id, mutationID: noteAttempt.attemptId, remoteRevision: remoteNote.ver)
            for _ in 0..<6 {
                try await b.fetchEntities(); _ = try await receiverB.applyPending(); try await b.publish()
                try await a.fetchEntities(); _ = try await receiverA.applyPending(); try await a.publish()
            }
            for (device, access) in [(a, accessA), (b, accessB)] {
                #expect(try device.store.allRemote().isEmpty)
                #expect(try device.store.allInflight().isEmpty)
                #expect(try device.dirtyCount() == 0)
                #expect(try device.noteStore.allNotes().map(\.id) == [copyID])
                #expect(try device.noteStore.note(id: copyID)?.isLocked == true)
                #expect(try Self.recoveryBytes(copyID, on: device, access: access) == edits.1)
            }
            #expect(try b.noteStore.note(id: note.id) == nil) // Existing delete-vs-edit policy keeps local deletion.
            for _ in 0..<3 {
                try await b.fetchEntities(); _ = try await receiverB.applyPending(); try await b.publish()
                try await a.fetchEntities(); _ = try await receiverA.applyPending(); try await a.publish()
            }
            #expect(try a.noteStore.allNotes().map(\.id) == [copyID])
            #expect(try b.noteStore.allNotes().map(\.id) == [copyID])
            #expect(try Self.recoveryBytes(copyID, on: a, access: accessA) == edits.1)
            #expect(try Self.recoveryBytes(copyID, on: b, access: accessB) == edits.1)
        }
    }

    @Test func acceptedParentTombstoneStillRecoversLaterAttachmentOnlyEditProtected() async throws {
        try await withBlobWorld(2) { world in
            let a = world.devices[0], b = world.devices[1]
            let rigA = BlobRig(a), rigB = BlobRig(b)
            a.publishThrough(rigA); b.publishThrough(rigB)
            let baseline = try SketchSyncPNGFixture.baseline()
            let remoteBytes = try SketchSyncPNGFixture.conflictEdits(baseline: baseline).1
            let note = try a.noteStore.create(text: "# Accepted deletion\n![](sketch.png)\n")
            _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: baseline, filename: "sketch.png", to: note.id)
            let accessA = try NotePrivacy(store: a.noteStore).setPassword("fixture-password")
            defer { accessA.revoke() }
            try await a.publish(); try await b.fetchEntities(); _ = try await b.receiver(rigB).applyPending()
            let accessB = try NotePrivacy(store: b.noteStore).unlock(password: "fixture-password")
            defer { accessB.revoke() }
            let receiverA = CloudReconciler(database: a.db, paths: a.paths, store: a.store, accountID: a.accountID,
                vaultKey: a.key, pinner: CloudAssetPinner(directory: a.paths.cloudPinned), blobs: rigA.transfer, noteAccess: { accessA })
            let receiverB = CloudReconciler(database: b.db, paths: b.paths, store: b.store, accountID: b.accountID,
                vaultKey: b.key, pinner: CloudAssetPinner(directory: b.paths.cloudPinned), blobs: rigB.transfer, noteAccess: { accessB })
            let id = try b.attachmentID(of: note.id)
            try b.noteStore.trash([note.id]); _ = try b.noteStore.emptyTrash(ids: [note.id])
            for _ in 0..<3 { try await b.publish() }
            #expect(try b.store.allInflight().isEmpty && b.dirtyCount() == 0)
            #expect(try b.store.pair(for: b.ref(note.id)) != nil)
            #expect(try b.store.pair(for: b.ref(id, type: "attachment")) != nil)
            // A remains offline with its original note, authors only new attachment bytes.
            try SketchSyncPNGFixture.replace(remoteBytes, noteID: note.id, paths: a.paths, database: a.db)
            for _ in 0..<10 {
                try await a.publish(); try await a.fetchEntities(); _ = try await receiverA.applyPending()
                try await b.fetchEntities(); _ = try await receiverB.applyPending(); try await b.publish()
            }
            let ids = try b.noteStore.allNotes().map(\.id).sorted()
            #expect(ids.count == 1)
            #expect(try a.noteStore.allNotes().map(\.id).sorted() == ids)
            for (device, access) in [(a, accessA), (b, accessB)] {
                #expect(try device.store.allRemote().isEmpty && device.store.allInflight().isEmpty && device.dirtyCount() == 0)
                for id in ids {
                    #expect(try device.noteStore.note(id: id)?.isLocked == true)
                    #expect(try Self.recoveryBytes(id, on: device, access: access) == remoteBytes)
                }
            }
            for _ in 0..<3 {
                try await a.fetchEntities(); _ = try await receiverA.applyPending(); try await a.publish()
                try await b.fetchEntities(); _ = try await receiverB.applyPending(); try await b.publish()
            }
            #expect(try a.noteStore.allNotes().map(\.id).sorted() == ids)
            #expect(try b.noteStore.allNotes().map(\.id).sorted() == ids)
        }
    }

    @Test func noVaultAcceptedParentTombstoneRecoversLaterAttachmentOnlyEditPlain() async throws {
        try await withBlobWorld(2) { world in
            let a = world.devices[0], b = world.devices[1]
            let rigA = BlobRig(a), rigB = BlobRig(b)
            a.publishThrough(rigA); b.publishThrough(rigB)
            let baseline = try SketchSyncPNGFixture.baseline()
            let remoteBytes = try SketchSyncPNGFixture.conflictEdits(baseline: baseline).1
            let note = try a.noteStore.create(text: "# Accepted deletion\n![](sketch.png)\n")
            _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: baseline, filename: "sketch.png", to: note.id)
            let accessA: LockedNoteAccess? = nil
            defer { accessA?.revoke() }
            try await a.publish(); try await b.fetchEntities(); _ = try await b.receiver(rigB).applyPending()
            let accessB: LockedNoteAccess? = nil
            defer { accessB?.revoke() }
            let receiverA = CloudReconciler(database: a.db, paths: a.paths, store: a.store, accountID: a.accountID,
                vaultKey: a.key, pinner: CloudAssetPinner(directory: a.paths.cloudPinned), blobs: rigA.transfer, noteAccess: { accessA })
            let receiverB = CloudReconciler(database: b.db, paths: b.paths, store: b.store, accountID: b.accountID,
                vaultKey: b.key, pinner: CloudAssetPinner(directory: b.paths.cloudPinned), blobs: rigB.transfer, noteAccess: { accessB })
            let id = try b.attachmentID(of: note.id)
            try b.noteStore.trash([note.id]); _ = try b.noteStore.emptyTrash(ids: [note.id])
            for _ in 0..<3 { try await b.publish() }
            #expect(try b.store.allInflight().isEmpty && b.dirtyCount() == 0)
            #expect(try b.store.pair(for: b.ref(note.id)) != nil)
            #expect(try b.store.pair(for: b.ref(id, type: "attachment")) != nil)
            // A remains offline with its original note, authors only new attachment bytes.
            try SketchSyncPNGFixture.replace(remoteBytes, noteID: note.id, paths: a.paths, database: a.db)
            for _ in 0..<10 {
                try await a.publish(); try await a.fetchEntities(); _ = try await receiverA.applyPending()
                try await b.fetchEntities(); _ = try await receiverB.applyPending(); try await b.publish()
            }
            let ids = try b.noteStore.allNotes().map(\.id).sorted()
            #expect(ids.count == 1)
            #expect(try a.noteStore.allNotes().map(\.id).sorted() == ids)
            for (device, access) in [(a, accessA), (b, accessB)] {
                #expect(try device.store.allRemote().isEmpty && device.store.allInflight().isEmpty && device.dirtyCount() == 0)
                for id in ids {
                    #expect(try device.noteStore.note(id: id)?.isLocked == false)
                    #expect(try Self.recoveryBytes(id, on: device, access: access) == remoteBytes)
                }
            }
            for _ in 0..<3 {
                try await a.fetchEntities(); _ = try await receiverA.applyPending(); try await a.publish()
                try await b.fetchEntities(); _ = try await receiverB.applyPending(); try await b.publish()
            }
            #expect(try a.noteStore.allNotes().map(\.id).sorted() == ids)
            #expect(try b.noteStore.allNotes().map(\.id).sorted() == ids)
        }
    }

    private static func recoveryBytes(_ noteID: String, on device: PublisherDevice, access: LockedNoteAccess?) throws -> Data {
        let persisted = try #require(try device.noteStore.note(id: noteID))
        let readable: Note
        if persisted.isLocked {
            let authorized = try #require(access)
            readable = try #require(try authorized.note(id: noteID))
        } else { readable = persisted }
        let link = try #require(NoteParser.attachmentLinks(in: readable.text).first)
        #expect(try device.int("SELECT COUNT(*) FROM attachment WHERE noteId=? AND deletedAt IS NULL", [noteID]) == 1)
        if persisted.isLocked {
            let output = device.paths.root.appendingPathComponent("readback-\(UUID()).png")
            defer { try? FileManager.default.removeItem(at: output) }
            let authorized = try #require(access)
            try authorized.decryptAttachment(link.filename, noteId: noteID, to: output)
            return try Data(contentsOf: output)
        }
        return try Data(contentsOf: device.installed(noteID: noteID, filename: link.filename))
    }

}
