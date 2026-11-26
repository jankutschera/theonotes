// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

extension PublisherDevice {
    func sql(_ statement: String, _ arguments: StatementArguments = []) throws {
        try db.pool.write { try $0.execute(sql: statement, arguments: arguments) }
    }

    func string(_ statement: String, _ arguments: StatementArguments = []) throws -> String? {
        try db.pool.read { try String.fetchOne($0, sql: statement, arguments: arguments) }
    }

    func int(_ statement: String, _ arguments: StatementArguments = []) throws -> Int? {
        try db.pool.read { try Int.fetchOne($0, sql: statement, arguments: arguments) }
    }

    func strings(_ statement: String, _ arguments: StatementArguments = []) throws -> [String] {
        try db.pool.read { try String.fetchAll($0, sql: statement, arguments: arguments) }
    }

    /// Stands in for Task 7's download: the attachment ciphertext this device does not have yet is copied from the other device's cache.
    func copyBlobs(from other: PublisherDevice) throws {
        let rows = try other.db.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT hash, localPath, byteSize FROM sync_blob_state WHERE localPath IS NOT NULL").map {
                ($0["hash"] as String, $0["localPath"] as String, $0["byteSize"] as Int64)
            }
        }
        for (hash, path, size) in rows {
            let source = try SyncBlobLocation.verified(path, paths: other.paths, hash: hash, size: size).url
            let directory = paths.root.appendingPathComponent("SyncDownloads", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent(hash)
            if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: source, to: target) }
            try sql("INSERT INTO sync_blob_state(hash,localPath,byteSize,uploaded) VALUES(?,?,?,1) ON CONFLICT(hash) DO NOTHING", [hash, "SyncDownloads/\(hash)", size])
        }
    }

    /// What `SyncQueue.enable` does for existing files: every attachment of the note is dirty and gets published.
    func publishAttachments(of noteId: String) throws {
        try sql("INSERT INTO sync_dirty(entityType,localId,generation,tombstone) SELECT 'attachment',id,1,0 FROM attachment WHERE noteId=? ON CONFLICT DO NOTHING", [noteId])
    }

    func attachmentFile(_ noteId: String, _ name: String) -> URL { paths.attachments.appendingPathComponent(noteId).appendingPathComponent(name) }

    /// The next version of a cloud record as a deletion, sealed with this device's key.
    func tombstone(after record: CloudRecord) throws -> CloudRecord {
        guard case .entity(let header) = try CloudRecordCodec.decode(record) else { throw CloudIntakeError.notAnEntity(record.name) }
        let sid = UUIDv7.make()
        let sealed = try sealer.sealDeleted(atMillis: 1_793_188_800_000, type: header.entityType, entityID: header.entityId)
        var next = CloudRecordCodec.encode(CloudEntityHeader(entityType: header.entityType, entityId: header.entityId, inc: header.inc, incs: header.incs,
                                                             ver: header.ver + 1, sid: sid, sids: Array(([sid] + header.sids).prefix(8)),
                                                             payload: .inline(sealed), blobs: []))
        next.systemFields = Data("tomb-\(sid)".utf8)
        return next
    }
}

func recordName(_ world: PublisherWorld, prefix: String) async -> String? {
    await world.account.recordNames.first { $0.hasPrefix(prefix) }
}

/// The six entity types through the real publisher and the real receiver.
@Suite struct CloudApplierTests {
    func two() async throws -> PublisherWorld { try await PublisherWorld.make(2) }

    // MARK: all six types

    @Test func notesTagsSettingsExternalRefsAndLockEnvelopeApplyAndRoundTrip() async throws {
        let world = try await two(); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let note = try a.noteStore.create(text: "# Round\nbody #roundtrip\n")
        try a.sql("UPDATE tag SET iconName='star', isPinned=1, sortIndex=3 WHERE pathKey='roundtrip'")
        try a.sql("INSERT INTO setting(key,value) VALUES('hideMarkdown','true') ON CONFLICT(key) DO UPDATE SET value=excluded.value")
        try a.sql("INSERT INTO external_ref(source,externalId,noteId) VALUES('import','ext-1',?)", [note.id])
        let access = try NotePrivacy(store: a.noteStore).setPassword("pw"); defer { access.revoke() }
        try await a.sync(); try await b.sync()
        #expect(try b.text(note.id) == "# Round\nbody #roundtrip\n")
        #expect(try b.string("SELECT iconName FROM tag WHERE pathKey='roundtrip'") == "star")
        #expect(try b.string("SELECT value FROM setting WHERE key='hideMarkdown'") == "true")
        #expect(try b.string("SELECT noteId FROM external_ref WHERE source='import' AND externalId='ext-1'") == note.id)
        #expect(try b.string("SELECT hex(envelope) FROM crypto_envelope WHERE id=1") == a.string("SELECT hex(envelope) FROM crypto_envelope WHERE id=1"))
        #expect(try b.dirtyCount() == 0, "applying is not an edit and is not echoed")
        // And back: an edit on B reaches A.
        try b.sql("UPDATE setting SET value='false' WHERE key='hideMarkdown'")
        try b.edit(note.id, "# Round\nbody changed #roundtrip\n")
        try await b.sync(); try await a.sync()
        #expect(try a.string("SELECT value FROM setting WHERE key='hideMarkdown'") == "false")
        #expect(try a.text(note.id) == "# Round\nbody changed #roundtrip\n")
        #expect(try a.dirtyCount() == 0)
        // Every applied entity moved its base pair.
        for type in ["note", "tagPreference", "setting", "externalRef", "keyBundle"] {
            #expect(try b.rowCount("ck_record") > 0)
            #expect((try b.int("SELECT COUNT(*) FROM ck_record WHERE entityType=?", [type]) ?? 0) >= 1, "\(type) has a pair")
        }
    }

    @Test func attachmentBeforeNoteWaitsThenApplies() async throws {
        let world = try await two(); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let note = try a.noteStore.create(text: "# Files\n")
        let bytes = Data("attachment bytes".utf8)
        _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: bytes, filename: "doc.txt", to: note.id)
        try a.edit(note.id, "# Files\n![doc](doc.txt)\n")                  // the text save indexes the link and creates the row
        try a.publishAttachments(of: note.id)
        try await a.sync()
        try b.copyBlobs(from: a)
        let attachmentName = try #require(await recordName(world, prefix: "e.attachment."))
        let attachment = try #require(await world.account.record(named: attachmentName))
        let noteRecord = try #require(await world.account.record(named: "e.note.\(note.id)"))
        _ = try b.sink.intake(attachment, delivery: .incremental)
        let first = try await b.reconciler.applyPending()
        #expect(first.waitingForDependency.map(\.entityType) == ["attachment"], "no note yet")
        #expect(try b.note(note.id) == nil)
        _ = try b.sink.intake(noteRecord, delivery: .incremental)
        let second = try await b.reconciler.applyPending()
        #expect(second.applied.map(\.entityType).contains("note"))
        #expect(try b.store.pair(for: CloudEntityRef(entityType: "attachment", entityId: attachmentName.replacingOccurrences(of: "e.attachment.", with: ""))) != nil,
                "the attachment version folded into the note's transaction moved its pair too")
        #expect(try Data(contentsOf: b.attachmentFile(note.id, "doc.txt")) == bytes)
        #expect(try b.dirtyCount() == 0, "a file applied from its own entity is not republished")
        #expect(try b.rowCount("ck_remote") == 0)
    }

    @Test func externalRefBeforeNoteWaits() async throws {
        let world = try await two(); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let note = try a.noteStore.create(text: "# Ref\nx\n")
        try a.sql("INSERT INTO external_ref(source,externalId,noteId) VALUES('import','ext-2',?)", [note.id])
        try await a.sync()
        let refName = try #require(await recordName(world, prefix: "e.externalRef."))
        _ = try b.sink.intake(try #require(await world.account.record(named: refName)), delivery: .incremental)
        let first = try await b.reconciler.applyPending()
        #expect(first.waitingForDependency.map(\.entityType) == ["externalRef"])
        #expect(try b.int("SELECT COUNT(*) FROM external_ref") == 0)
        _ = try b.sink.intake(try #require(await world.account.record(named: "e.note.\(note.id)")), delivery: .incremental)
        _ = try await b.reconciler.applyPending()
        #expect(try b.string("SELECT noteId FROM external_ref WHERE externalId='ext-2'") == note.id)
    }

    // MARK: locked notes

    @Test func lockedNoteWaitsForUnlockThenMergesAfter() async throws {
        let world = try await two(); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let privacyA = NotePrivacy(store: a.noteStore)
        let accessA = try privacyA.setPassword("pw"); defer { accessA.revoke() }
        let note = try a.noteStore.create(text: "# Secret\nl1\nl2\nl3\n")
        try accessA.lock(noteId: note.id)
        try await a.sync(); try await b.sync()
        let accessB = try NotePrivacy(store: b.noteStore).unlock(password: "pw"); defer { accessB.revoke() }
        // Both edit the protected body, different lines.
        let mineA = try #require(try accessA.note(id: note.id))
        _ = try accessA.updateText(id: note.id, text: mineA.text.replacingOccurrences(of: "l1", with: "L1 from a"), expectedRevision: mineA.revision)
        let mineB = try #require(try accessB.note(id: note.id))
        _ = try accessB.updateText(id: note.id, text: mineB.text.replacingOccurrences(of: "l3", with: "L3 from b"), expectedRevision: mineB.revision)
        try await a.sync()
        try await b.fetch()
        let waiting = try await b.reconciler.applyPending()                 // no access handed to the receiver
        #expect(waiting.waitingForUnlock.map(\.entityId) == [note.id])
        #expect(try b.store.remote(recordName: "e.note.\(note.id)")?.waitingFor == .unlock)
        #expect(try b.store.pair(for: b.ref(note.id))?.ver == 1)
        b.access.update { $0 = accessB }
        let merged = try await b.reconciler.applyPending()
        #expect(merged.applied.map(\.entityId) == [note.id])
        let text = try #require(try accessB.note(id: note.id)?.text)
        #expect(text.contains("L1 from a") && text.contains("L3 from b"))
        #expect(try b.note(note.id)?.text == "", "the stored text of a protected note stays empty")
    }

    @Test func protectedNoteConflictCopyIsSealedAgain() async throws {
        let world = try await two(); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let accessA = try NotePrivacy(store: a.noteStore).setPassword("pw"); defer { accessA.revoke() }
        let note = try a.noteStore.create(text: "# Secret\nsame line\n")
        try accessA.lock(noteId: note.id)
        try await a.sync(); try await b.sync()
        let accessB = try NotePrivacy(store: b.noteStore).unlock(password: "pw"); defer { accessB.revoke() }
        b.access.update { $0 = accessB }
        let ma = try #require(try accessA.note(id: note.id)), mb = try #require(try accessB.note(id: note.id))
        _ = try accessA.updateText(id: note.id, text: ma.text.replacingOccurrences(of: "same line", with: "CANARY-A-LINE"), expectedRevision: ma.revision)
        _ = try accessB.updateText(id: note.id, text: mb.text.replacingOccurrences(of: "same line", with: "CANARY-B-LINE"), expectedRevision: mb.revision)
        try await a.sync(); try await b.sync()
        let copies = try b.notes().filter { $0.id != note.id }
        #expect(copies.count == 1, "one deterministic conflict copy")
        let copy = try #require(copies.first)
        #expect(copy.isLocked && copy.text.isEmpty && copy.encryptedPayload != nil, "the copy is sealed again")
        #expect(try accessB.note(id: copy.id)?.text.contains("CANARY-A-LINE") == true)
        #expect(try accessB.note(id: note.id)?.text.contains("CANARY-B-LINE") == true)
        let stored = try b.strings("SELECT text FROM note").joined()
        #expect(!stored.contains("CANARY"), "no plaintext of a protected note reaches the library table")
    }

    @Test func aLockedNoteWithAnAttachmentApplies() async throws {
        let world = try await two(); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let accessA = try NotePrivacy(store: a.noteStore).setPassword("pw"); defer { accessA.revoke() }
        let note = try a.noteStore.create(text: "# Vault\n[f](secret.txt)\n")
        let bytes = Data("secret attachment bytes".utf8)
        _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: bytes, filename: "secret.txt", to: note.id)
        try accessA.lock(noteId: note.id)
        try a.publishAttachments(of: note.id)
        try await a.sync()
        try b.copyBlobs(from: a)
        try await b.sync()
        let accessB = try NotePrivacy(store: b.noteStore).unlock(password: "pw"); defer { accessB.revoke() }
        #expect(try accessB.note(id: note.id)?.text.contains("secret.txt") == true)
        let output = b.paths.root.appendingPathComponent("decrypted")
        try accessB.decryptAttachment("secret.txt", noteId: note.id, to: output)
        #expect(try Data(contentsOf: output) == bytes)
        #expect(try b.dirtyCount() == 0)
    }

    // MARK: deletion versus edit

    @Test func remoteDeletionVersusLocalEditKeepsTheEdit() async throws {
        let world = try await two(); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let note = try a.noteStore.create(text: "# Keep\nbody\n")
        try await a.sync(); try await b.sync()
        try a.noteStore.deletePermanently([note.id])
        try await a.sync()                                                 // the tombstone is in the cloud
        try b.edit(note.id, "# Keep\nbody plus my edit\n")
        try await b.sync()
        #expect(try b.text(note.id) == "# Keep\nbody plus my edit\n", "the edit is kept")
        try await a.sync(); try await b.sync()
        #expect(try a.text(note.id) == "# Keep\nbody plus my edit\n", "and it reaches the deleting device")
    }

    @Test func localDeletionVersusRemoteEditKeepsTheEdit() async throws {
        let world = try await two(); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let note = try a.noteStore.create(text: "# Keep\nbody\n")
        try await a.sync(); try await b.sync()
        try b.noteStore.deletePermanently([note.id])
        try a.edit(note.id, "# Keep\nbody plus remote edit\n")
        try await a.sync()
        try await b.sync()
        #expect(try b.snapshot().joined().contains("remote edit"), "the remote edit survives on the deleting device")
        try await a.sync(); try await b.sync()
        #expect(try a.snapshot().joined().contains("remote edit"))
    }

    @Test func appliedMergeThatDiffersFromRemoteKeepsLocalDirty() async throws {
        let world = try await two(); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let note = try a.noteStore.create(text: "# Merge\nl1\nl2\nl3\n")
        try await a.sync(); try await b.sync()
        try a.edit(note.id, "# Merge\nL1 from a\nl2\nl3\n")
        try await a.sync()
        try b.edit(note.id, "# Merge\nl1\nl2\nL3 from b\n")
        try await b.fetch()
        _ = try await b.reconciler.applyPending()
        #expect(try b.text(note.id) == "# Merge\nL1 from a\nl2\nL3 from b\n")
        #expect(try b.dirtyGeneration(note.id) != nil, "the merged text is not what the cloud holds: it is still to be published")
        #expect(try b.store.pair(for: b.ref(note.id))?.ver == 2, "the next publish builds on the new pair")
        try await b.sync(); try await a.sync()
        #expect(try a.text(note.id) == "# Merge\nL1 from a\nl2\nL3 from b\n")
        #expect(try b.dirtyCount() == 0 && a.dirtyCount() == 0)
    }

    // MARK: tombstones of settings, tags, external references and attachments

    @Test func tombstonesOfSettingsTagsExternalRefsAndAttachmentsApply() async throws {
        let world = try await two(); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let note = try a.noteStore.create(text: "# Gone\n#gone\n")
        _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: Data("f".utf8), filename: "f.txt", to: note.id)
        try a.edit(note.id, "# Gone\n![f](f.txt) #gone\n")
        try a.publishAttachments(of: note.id)
        try a.sql("UPDATE tag SET iconName='bolt', isPinned=1 WHERE pathKey='gone'")
        try a.sql("INSERT INTO setting(key,value) VALUES('showNoteCounts','true') ON CONFLICT(key) DO UPDATE SET value=excluded.value")
        try a.sql("INSERT INTO external_ref(source,externalId,noteId) VALUES('import','ext-3',?)", [note.id])
        try await a.sync()
        try b.copyBlobs(from: a)
        try await b.sync()
        #expect(try b.string("SELECT iconName FROM tag WHERE pathKey='gone'") == "bolt")
        for prefix in ["e.setting.", "e.tagPreference.", "e.externalRef.", "e.attachment."] {
            let name = try #require(await recordName(world, prefix: prefix))
            let record = try #require(await world.account.record(named: name))
            _ = try b.sink.intake(try a.tombstone(after: record), delivery: .incremental)
        }
        let report = try await b.reconciler.applyPending()
        #expect(report.quarantined.isEmpty && report.applied.count == 4)
        #expect(try b.int("SELECT COUNT(*) FROM setting WHERE key='showNoteCounts'") == 0)
        #expect(try b.string("SELECT iconName FROM tag WHERE pathKey='gone'") == nil, "preferences reset; the tag stays on the note")
        #expect(try b.int("SELECT COUNT(*) FROM external_ref WHERE externalId='ext-3'") == 0)
        #expect(try b.int("SELECT COUNT(*) FROM attachment WHERE noteId=? AND deletedAt IS NOT NULL", [note.id]) == 1)
        #expect(try b.text(note.id)?.contains("#gone") == true)
        #expect(try b.dirtyCount() == 0)
    }

    @Test func aTagRowRecreatedUnderANewLocalIdStillReceivesItsPreferences() async throws {
        let world = try await two(); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let note = try a.noteStore.create(text: "# Tag\n#recreated\n")
        try a.sql("UPDATE tag SET iconName='star', isPinned=1 WHERE pathKey='recreated'")
        try await a.sync(); try await b.sync()
        let oldId = try #require(try b.string("SELECT id FROM tag WHERE pathKey='recreated'"))
        // On B the row left every note and came back: same path, new local id; the id map still names the old row.
        try b.sql("UPDATE sync_control SET applying=1 WHERE id=1")
        try b.sql("DELETE FROM note_tag WHERE tagId=?", [oldId])
        try b.sql("DELETE FROM tag WHERE id=?", [oldId])
        try b.sql("INSERT INTO tag(id,pathKey,displayPath) VALUES('new-local-id','recreated','recreated')")
        try b.sql("UPDATE sync_control SET applying=0 WHERE id=1")
        try a.sql("UPDATE tag SET iconName='bolt' WHERE pathKey='recreated'")
        try await a.sync(); try await b.fetch()
        let report = try await b.reconciler.applyPending()
        #expect(report.quarantined.isEmpty, "the original would report an identity collision for ever")
        #expect(try b.string("SELECT iconName FROM tag WHERE id='new-local-id'") == "bolt")
        #expect(try b.store.quarantineRows().isEmpty)
        _ = note
    }

    @Test func aSettingDeletedRemotelyAndEditedLocallyKeepsTheLocalValue() async throws {
        let world = try await two(); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        try a.sql("INSERT INTO setting(key,value) VALUES('autocomplete','true') ON CONFLICT(key) DO UPDATE SET value=excluded.value")
        try await a.sync(); try await b.sync()
        let name = try #require(await recordName(world, prefix: "e.setting."))
        let tomb = try a.tombstone(after: try #require(await world.account.record(named: name)))
        try b.sql("UPDATE setting SET value='false' WHERE key='autocomplete'")
        _ = try b.sink.intake(tomb, delivery: .incremental)
        _ = try await b.reconciler.applyPending()
        #expect(try b.string("SELECT value FROM setting WHERE key='autocomplete'") == "false", "pending local preference wins")
        #expect(try b.dirtyCount() > 0)
    }

    // MARK: one transaction with the base pair

    @Test func applyIsOneTransactionWithTheBasePair() async throws {
        for boundary in ["applier.afterLibraryWrite", "recordApplied.afterLibraryWrite", "recordApplied.afterPair"] {
            let world = try await two(); defer { world.cleanup() }
            let a = world.devices[0], b = world.devices[1]
            let note = try a.noteStore.create(text: "# Atomic\nv1\n")
            try await a.sync(); try await b.sync()
            try a.edit(note.id, "# Atomic\nv2\n")
            try await a.sync()
            try await b.fetch()
            let crash = CrashPoint()
            let pair = try #require(try b.store.pair(for: b.ref(note.id)))
            let store = CloudSyncStore(database: b.db, boundary: { try crash.hit($0) })
            let reconciler = CloudReconciler(database: b.db, paths: b.paths, store: store, accountID: b.accountID, vaultKey: b.key,
                                             pinner: CloudAssetPinner(directory: b.paths.cloudPinned), crash: crash)
            crash.arm(boundary)
            await #expect(throws: CrashInjected.self) { try await reconciler.applyPending() }
            #expect(try b.text(note.id) == "# Atomic\nv1\n", "\(boundary): the old library")
            #expect(try b.store.pair(for: b.ref(note.id)) == pair, "\(boundary): the old pair")
            #expect(try b.store.remote(recordName: "e.note.\(note.id)")?.ver == 2, "\(boundary): the fetched version is still waiting")
            #expect(try b.dirtyCount() == 0)
            _ = try await reconciler.applyPending()
            #expect(try b.text(note.id) == "# Atomic\nv2\n")
            #expect(try b.store.pair(for: b.ref(note.id))?.ver == 2)
        }
    }
}
