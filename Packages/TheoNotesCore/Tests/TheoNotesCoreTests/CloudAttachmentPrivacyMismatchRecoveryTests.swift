// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// The Cloud applier's transaction seam, with real files/crypto/preparation. This deliberately
/// delivers the locked attachment before its note bundle, while the plain receiver has edited
/// the same attachment offline. No CloudKit account/server or user data is involved.
@Suite struct CloudAttachmentPrivacyMismatchRecoveryTests {
    private struct Library: Sendable {
        let paths: AppPaths
        let db: AppDatabase
        let key: SymmetricKey
        var store: NoteStore { NoteStore(db: db, notifier: nil, paths: paths) }
        init(key: SymmetricKey) throws {
            self.key = key
            paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("cloud-privacy-recovery-\(UUID())"))
            try paths.createDirectories(); db = try AppDatabase(path: paths.database)
        }
        func cleanup() { try? db.pool.close(); try? FileManager.default.removeItem(at: paths.root) }
        func prepare(_ id: String) async throws -> (SyncAttachmentPayload, URL) {
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
        let remoteBytes: Data
        let localBytes: Data
        let access: LockedNoteAccess
        init(remoteLocked: Bool = true) throws {
            let key = SymmetricKey(size: .bits256)
            remote = try Library(key: key); local = try Library(key: key)
            remoteBytes = try SketchSyncPNGFixture.baseline()
            localBytes = try SketchSyncPNGFixture.conflictEdits(baseline: remoteBytes).0
            let note = try remote.store.create(text: "# Lock versus offline sketch\n![](sketch.png)\n")
            noteID = note.id
            _ = try AttachmentStore(paths: remote.paths, database: remote.db).add(data: remoteBytes, filename: "sketch.png", to: note.id)
            let remoteAccess = try NotePrivacy(store: remote.store).setPassword("fixture-password")
            let backup = remote.paths.root.appendingPathComponent("initial.baerchen-backup")
            try LibraryBackup(database: remote.db, paths: remote.paths).create(at: backup)
            _ = try LibraryBackup(database: local.db, paths: local.paths).restore(backup, mode: .replaceAll)
            try SyncQueue(database: remote.db).enable(accountID: "account")
            try SyncQueue(database: local.db).enable(accountID: "account")
            attachmentID = try remote.db.pool.read { try #require(try String.fetchOne($0, sql: "SELECT id FROM attachment WHERE noteId=?", arguments: [note.id])) }
            access = try NotePrivacy(store: local.store).unlock(password: "fixture-password")
            try SketchSyncPNGFixture.replace(localBytes, noteID: note.id, paths: local.paths, database: local.db)
            if remoteLocked { try remoteAccess.lock(noteId: note.id) }
            else { try access.lock(noteId: note.id) }
            remoteAccess.revoke()
        }
        func cleanup() { access.revoke(); remote.cleanup(); local.cleanup() }
        var remoteCopyID: String { SyncNoteMerge.conflictID(entityID: attachmentID, mutationID: "rejected-offline-edit", remoteRevision: 2) }
        var localCopyID: String { SyncNoteMerge.conflictID(entityID: "local:" + attachmentID, mutationID: "rejected-offline-edit", remoteRevision: 2) }
        func bytes(in copyID: String) throws -> Data {
            let persisted = try #require(try local.store.note(id: copyID))
            let readable = persisted.isLocked ? try #require(try access.note(id: copyID)) : persisted
            let link = try #require(NoteParser.attachmentLinks(in: readable.text).first)
            let liveRows = try local.db.pool.read {
                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM attachment WHERE noteId=? AND deletedAt IS NULL", arguments: [copyID])
            }
            #expect(liveRows == 1, "Recovery needs a live attachment row, not only retained bytes")
            if persisted.isLocked {
                let output = local.paths.root.appendingPathComponent("readback-\(UUID()).png")
                defer { try? FileManager.default.removeItem(at: output) }
                try access.decryptAttachment(link.filename, noteId: copyID, to: output)
                return try Data(contentsOf: output)
            }
            return try Data(contentsOf: local.paths.attachments.appendingPathComponent(copyID).appendingPathComponent(link.filename))
        }
        func input(_ payload: SyncAttachmentPayload, unlocked: Bool = true) -> CloudApplyInput {
            CloudApplyInput(version: RemoteVersion(entityType: .attachment, entityId: attachmentID,
                ver: 2, sid: "remote-lock", sealed: Data(), blobRefs: [payload.blobHash], lineage: "fixture"),
                value: .attachment(payload), base: nil, hasBase: true,
                mergeIdentity: ("rejected-offline-edit", 2), mergingInflight: true,
                siblings: { _, _ in nil }, precondition: { _ in }, siblingStillCurrent: { _, _, _, _ in true },
                lockEnvelopeWaiting: false, independent: false, consumeSiblings: { _, _ in },
                requireUnpublishedProtectedLibrary: { _ in }, isUnpublishedNote: { _, _ in false },
                noteAccess: unlocked ? access : nil, remoteNotePassword: nil)
        }
    }

    @Test(arguments: [true, false])
    func lockMismatchPreservesBothVersionsBeforeConsumingAndRetryIsIdempotent(remoteLocked: Bool) async throws {
        let fixture = try Fixture(remoteLocked: remoteLocked); defer { fixture.cleanup() }
        let (payload, cipher) = try await fixture.remote.prepare(fixture.attachmentID)
        #expect(payload.isLocked == remoteLocked)
        let applier = CloudApplier(database: fixture.local.db, paths: fixture.local.paths, accountID: "account",
            vaultKey: fixture.local.key, blobs: SyncPayloadReaderTests.Blobs(files: [payload.blobHash: cipher]))
        let db = fixture.local.db
        let commit: CloudApplyCommit = { write in try db.pool.write { try write($0) } }
        #expect(try await applier.apply(fixture.input(payload), commit: commit) == .applied(consumed: []))
        #expect(try fixture.bytes(in: fixture.remoteCopyID) == fixture.remoteBytes)
        #expect(try fixture.bytes(in: fixture.localCopyID) == fixture.localBytes)
        #expect(try fixture.local.store.note(id: fixture.remoteCopyID)?.isLocked == true)
        #expect(try fixture.local.store.note(id: fixture.localCopyID)?.isLocked == true)
        #expect(try fixture.local.store.note(id: fixture.noteID)?.isLocked == !remoteLocked)
        #expect(try fixture.bytes(in: fixture.noteID) == fixture.localBytes)
        let ids = try fixture.local.store.allNotes().map(\.id).sorted()
        #expect(try await applier.apply(fixture.input(payload), commit: commit) == .applied(consumed: []))
        #expect(try fixture.local.store.allNotes().map(\.id).sorted() == ids)
        #expect(try fixture.bytes(in: fixture.remoteCopyID) == fixture.remoteBytes)
        #expect(try fixture.bytes(in: fixture.localCopyID) == fixture.localBytes)
    }

    @Test func unavailableNoteKeyDefersWithoutAcknowledgingOrChangingOriginal() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let (payload, cipher) = try await fixture.remote.prepare(fixture.attachmentID)
        let applier = CloudApplier(database: fixture.local.db, paths: fixture.local.paths, accountID: "account",
            vaultKey: fixture.local.key, blobs: SyncPayloadReaderTests.Blobs(files: [payload.blobHash: cipher]))
        let db = fixture.local.db
        #expect(try await applier.apply(fixture.input(payload, unlocked: false), commit: { write in try db.pool.write { try write($0) } }) == .waitingForUnlock)
        #expect(try fixture.local.store.allNotes().count == 1)
        #expect(try Data(contentsOf: fixture.local.paths.attachments.appendingPathComponent(fixture.noteID).appendingPathComponent("sketch.png")) == fixture.localBytes)
    }
    @Test func recoveryCommitFailureRollsBackCopiesAndStagingThenRetryPreservesBoth() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let (payload, cipher) = try await fixture.remote.prepare(fixture.attachmentID)
        let applier = CloudApplier(database: fixture.local.db, paths: fixture.local.paths, accountID: "account",
            vaultKey: fixture.local.key, blobs: SyncPayloadReaderTests.Blobs(files: [payload.blobHash: cipher]))
        let db = fixture.local.db
        await #expect(throws: CocoaError.self) {
            try await applier.apply(fixture.input(payload), commit: { write in
                try db.pool.write { database in
                    try write(database)
                    throw CocoaError(.fileWriteNoPermission) // After both recovery writes, before commit.
                }
            })
        }
        #expect(try fixture.local.store.allNotes().count == 1)
        let staged = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM staging_batch") }
        let applying = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT applying FROM sync_control WHERE id=1") }
        #expect(staged == 0 && applying == 0)
        let staging = fixture.local.paths.attachments.appendingPathComponent(".staging")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []).isEmpty)
        #expect(try Data(contentsOf: fixture.local.paths.attachments.appendingPathComponent(fixture.noteID).appendingPathComponent("sketch.png")) == fixture.localBytes)
        #expect(try await applier.apply(fixture.input(payload), commit: { write in try db.pool.write { try write($0) } }) == .applied(consumed: []))
        #expect(try fixture.bytes(in: fixture.remoteCopyID) == fixture.remoteBytes)
        #expect(try fixture.bytes(in: fixture.localCopyID) == fixture.localBytes)
    }

    @Test func unavailableLocalSourceDefersAndCanRetryAfterSourceReturns() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let (payload, cipher) = try await fixture.remote.prepare(fixture.attachmentID)
        let source = fixture.local.paths.attachments.appendingPathComponent(fixture.noteID).appendingPathComponent("sketch.png")
        let held = fixture.local.paths.root.appendingPathComponent("temporarily-unavailable.png")
        try FileManager.default.moveItem(at: source, to: held)
        let applier = CloudApplier(database: fixture.local.db, paths: fixture.local.paths, accountID: "account",
            vaultKey: fixture.local.key, blobs: SyncPayloadReaderTests.Blobs(files: [payload.blobHash: cipher]))
        let db = fixture.local.db
        let commit: CloudApplyCommit = { write in try db.pool.write { try write($0) } }
        #expect(try await applier.apply(fixture.input(payload), commit: commit) == .waitingForDependencies)
        #expect(try fixture.local.store.allNotes().count == 1)
        try FileManager.default.moveItem(at: held, to: source)
        #expect(try await applier.apply(fixture.input(payload), commit: commit) == .applied(consumed: []))
        #expect(try fixture.bytes(in: fixture.remoteCopyID) == fixture.remoteBytes)
        #expect(try fixture.bytes(in: fixture.localCopyID) == fixture.localBytes)
    }

    @Test(arguments: [true, false])
    func tombstoneKeepsDirtyPlainOrLockedLocalEditWithoutUnlockOrBlobDownload(remoteLocked: Bool) async throws {
        let fixture = try Fixture(remoteLocked: remoteLocked); defer { fixture.cleanup() }
        let (payload, _) = try await fixture.remote.prepare(fixture.attachmentID)
        var input = fixture.input(payload, unlocked: false)
        input.value = .deleted
        input.version.blobRefs = []
        // This transport has no files: an accidental tombstone download must fail this test.
        let applier = CloudApplier(database: fixture.local.db, paths: fixture.local.paths, accountID: "account",
            vaultKey: fixture.local.key, blobs: SyncPayloadReaderTests.Blobs())
        let db = fixture.local.db
        #expect(try await applier.apply(input, commit: { write in try db.pool.write { try write($0) } }) == .applied(consumed: []))
        #expect(try fixture.local.store.allNotes().count == 1)
        #expect(try fixture.bytes(in: fixture.noteID) == fixture.localBytes)
        let dirty = try await db.pool.read {
            try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM sync_dirty WHERE entityType='attachment' AND localId=? AND tombstone=0)", arguments: [fixture.attachmentID])
        }
        #expect(dirty == true)
    }

    @Test func fullCloudLifecycleKeepsNewerOfflineEditAfterStaleInflightAndLaterLockedNoteBundle() async throws {
        try await withBlobWorld(2) { world in
            let a = world.devices[0], b = world.devices[1]
            let rigA = BlobRig(a), rigB = BlobRig(b)
            a.publishThrough(rigA); b.publishThrough(rigB)
            let baseline = try SketchSyncPNGFixture.baseline()
            let edits = try SketchSyncPNGFixture.conflictEdits(baseline: baseline)
            let note = try a.noteStore.create(text: "# Delayed lock bundle\n![](sketch.png)\n")
            _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: baseline, filename: "sketch.png", to: note.id)
            let accessA = try NotePrivacy(store: a.noteStore).setPassword("fixture-password")
            defer { accessA.revoke() }
            try await a.publish()
            try await b.fetchEntities(); _ = try await b.receiver(rigB).applyPending()
            let accessB = try NotePrivacy(store: b.noteStore).unlock(password: "fixture-password")
            defer { accessB.revoke() }
            let receiverB = CloudReconciler(database: b.db, paths: b.paths, store: b.store,
                accountID: b.accountID, vaultKey: b.key, pinner: CloudAssetPinner(directory: b.paths.cloudPinned),
                blobs: rigB.transfer, noteAccess: { accessB })
            let receiverA = CloudReconciler(database: a.db, paths: a.paths, store: a.store,
                accountID: a.accountID, vaultKey: a.key, pinner: CloudAssetPinner(directory: a.paths.cloudPinned),
                blobs: rigA.transfer, noteAccess: { accessA })
            let id = try b.attachmentID(of: note.id)
            try SketchSyncPNGFixture.replace(edits.0, noteID: note.id, paths: b.paths, database: b.db)
            _ = try await b.publisher.prepare() // Real immutable Cloud snapshot of the first offline edit.
            let stale = try #require(try b.store.inflight(for: b.ref(id, type: "attachment")))
            try SketchSyncPNGFixture.replace(edits.1, noteID: note.id, paths: b.paths, database: b.db)
            let newer = try #require(try b.int("SELECT generation FROM sync_dirty WHERE entityType='attachment' AND localId=?", [id]))
            #expect(newer > stale.generation)
            try accessA.lock(noteId: note.id)
            try await a.publish()
            let rejected = try await b.publish()
            #expect(rejected.needsMerge.contains { $0.entityType == "attachment" && $0.entityId == id })
            try await b.fetchEntities()
            let heldNote = try #require(try b.store.remote(recordName: "e.note.\(note.id)"))
            let noteRecord = try #require(await world.account.record(named: "e.note.\(note.id)"))
            let remoteAttachment = try #require(try b.store.remote(recordName: "e.attachment.\(id)"))
            // Deliberately vary delivery order, as real incremental feeds may do. Restore the
            // exact server version below; no custom applier commit or invented acknowledgement.
            _ = try b.store.deleteRemote(heldNote, accountGeneration: try b.store.generation())
            let first = try await receiverB.applyPending()
            #expect(first.applied.contains { $0.entityType == "attachment" && $0.entityId == id })
            #expect(try b.store.inflight(for: b.ref(id, type: "attachment")) == nil)
            #expect(try b.store.remote(recordName: "e.attachment.\(id)") == nil)
            let remoteCopy = SyncNoteMerge.conflictID(entityID: id, mutationID: stale.attemptId, remoteRevision: remoteAttachment.ver)
            let localCopy = SyncNoteMerge.conflictID(entityID: "local:" + id, mutationID: stale.attemptId, remoteRevision: remoteAttachment.ver)
            #expect(try Self.recoveryBytes(remoteCopy, on: b, access: accessB) == baseline)
            #expect(try Self.recoveryBytes(localCopy, on: b, access: accessB) == edits.1)
            _ = try b.sink.intake(noteRecord, delivery: .incremental)
            let bundleReport = try await receiverB.applyPending()
            // Current dirty attachment generation must publish before the lock's note bundle
            // can overwrite its original. Recovery copies already exist independently here.
            #expect(bundleReport.waitingForUpload.contains { $0.entityType == "note" && $0.entityId == note.id })
            #expect(try b.store.remote(recordName: "e.note.\(note.id)") != nil)
            #expect(try Self.recoveryBytes(remoteCopy, on: b, access: accessB) == baseline)
            #expect(try Self.recoveryBytes(localCopy, on: b, access: accessB) == edits.1)
            for _ in 0..<6 {
                try await b.fetchEntities(); _ = try await receiverB.applyPending(); try await b.publish()
                #expect(try Self.recoveryBytes(remoteCopy, on: b, access: accessB) == baseline)
                #expect(try Self.recoveryBytes(localCopy, on: b, access: accessB) == edits.1)
                try await a.fetchEntities(); _ = try await receiverA.applyPending(); try await a.publish()
                #expect(try a.noteStore.allNotes().count == 3)
                #expect(try b.noteStore.allNotes().count == 3)
                for device in [a, b] {
                    #expect(try device.noteStore.note(id: remoteCopy)?.isLocked == true)
                    #expect(try device.noteStore.note(id: localCopy)?.isLocked == true)
                }
            }
            for (device, access) in [(a, accessA), (b, accessB)] {
                #expect(try Self.recoveryBytes(remoteCopy, on: device, access: access) == baseline)
                #expect(try Self.recoveryBytes(localCopy, on: device, access: access) == edits.1)
                #expect(try device.noteStore.note(id: note.id)?.isLocked == true)
                #expect(try device.store.allRemote().isEmpty)
                #expect(try device.store.allInflight().isEmpty)
                #expect(try device.dirtyCount() == 0)
            }
        }
    }

    @Test(arguments: [false, true])
    func hardDeleteAfterImmutableAttachmentSnapshotPreservesConcurrentRemoteEdit(injectRollback: Bool) async throws {
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
            try b.noteStore.trash([note.id])
            #expect(try b.noteStore.emptyTrash(ids: [note.id]) == [note.id])
            #expect(try b.noteStore.note(id: note.id) == nil)
            // A real competing attachment edit, not merely a privacy/representation change.
            try SketchSyncPNGFixture.replace(edits.1, noteID: note.id, paths: a.paths, database: a.db)
            try accessA.lock(noteId: note.id)
            try await a.publish()
            let rejected = try await b.publish()
            #expect(rejected.needsMerge.contains { $0.entityType == "attachment" && $0.entityId == id })
            try await b.fetchEntities()
            let noteAttempt = try #require(try b.store.inflight(for: b.ref(note.id)))
            let remoteNote = try #require(try b.store.remote(recordName: "e.note.\(note.id)"))
            let copyID = SyncNoteMerge.conflictID(entityID: note.id, mutationID: noteAttempt.attemptId, remoteRevision: remoteNote.ver)
            if injectRollback {
                b.crash.arm("applier.afterLibraryWrite")
                await #expect(throws: CrashInjected.self) { _ = try await receiverB.applyPending() }
                #expect(try b.noteStore.note(id: copyID) == nil)
                #expect(try b.store.remote(recordName: "e.note.\(note.id)") != nil)
                #expect(try b.store.remote(recordName: "e.attachment.\(id)") != nil)
                #expect(try b.store.inflight(for: b.ref(id, type: "attachment")) != nil)
                #expect(try b.int("SELECT COUNT(*) FROM staging_batch") == 0)
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

    private static func recoveryBytes(_ noteID: String, on device: PublisherDevice, access: LockedNoteAccess) throws -> Data {
        let persisted = try #require(try device.noteStore.note(id: noteID))
        let readable = persisted.isLocked ? try #require(try access.note(id: noteID)) : persisted
        let link = try #require(NoteParser.attachmentLinks(in: readable.text).first)
        #expect(try device.int("SELECT COUNT(*) FROM attachment WHERE noteId=? AND deletedAt IS NULL", [noteID]) == 1)
        if persisted.isLocked {
            let output = device.paths.root.appendingPathComponent("readback-\(UUID()).png")
            defer { try? FileManager.default.removeItem(at: output) }
            try access.decryptAttachment(link.filename, noteId: noteID, to: output)
            return try Data(contentsOf: output)
        }
        return try Data(contentsOf: device.installed(noteID: noteID, filename: link.filename))
    }

}
