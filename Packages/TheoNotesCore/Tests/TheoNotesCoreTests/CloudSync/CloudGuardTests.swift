// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// The CloudKit-side guards (E0 section 5.5, review point 1): the Cloudflare guard before a password change or vault conversion
/// reads `sync_outbox` and `sync_shadow`, both always empty here, so it passes vacuously; the CloudKit copy reads `ck_record`,
/// `ck_inflight`, `ck_missing` and `ck_remote`. And the attachment preparer is fenced against `ck_inflight` snapshots.
@Suite struct CloudGuardTests {
    /// Delivers a password envelope of another vault (or the same vault under a new password) as a fetched key-bundle version.
    func deliverEnvelope(_ envelope: CryptoEnvelope, to d: PublisherDevice, ver: Int64 = 1) throws {
        let payload = SyncLockEnvelopePayload(envelope: try JSONEncoder().encode(envelope))
        let sealed = try d.sealer.sealLive(try SyncPayloadCodec.encoder().encode(payload), type: .keyBundle, entityID: "kb1")
        let sid = "sid-kb-\(ver)"
        var record = CloudRecordCodec.encode(CloudEntityHeader(entityType: .keyBundle, entityId: "kb1", inc: "incKB", incs: [], ver: ver, sid: sid, sids: [sid],
                                                               payload: .inline(sealed), blobs: []))
        record.systemFields = Data("tag-kb-\(ver)".utf8)
        _ = try d.sink.intake(record, delivery: .incremental)
    }

    struct Setup {
        let device: PublisherDevice
        let access: LockedNoteAccess
        let noteId: String
        let original: CryptoEnvelope
        let before: Data
    }

    /// A device with its own vault and one locked note that was never published.
    func lockedDevice(_ name: String) throws -> Setup {
        let d = try PublisherDevice(name, account: nil)
        let privacy = NotePrivacy(store: d.noteStore)
        let access = try privacy.setPassword("local password")
        let note = try d.noteStore.create(text: "# Local secret\nbody\n")
        try access.lock(noteId: note.id)
        d.access.update { $0 = access }
        // The inner guard of the reused conversion (`stageInitialVaultConversion`) refuses every library with `enabled = 1`, so
        // these tests run with it off: then only the CloudKit guard under test can tell published from unpublished.
        try d.setEnabled(false)
        let stored = try #require(try d.note(note.id)?.encryptedPayload)
        return Setup(device: d, access: access, noteId: note.id, original: try #require(try privacy.envelope()), before: stored)
    }

    func markPublished(_ s: Setup) throws {
        try s.device.sql("INSERT INTO ck_record(entityType,entityId,systemFields,ancestor,ver,inc,supersededIncs,sids) VALUES('note',?,x'01',x'02',1,'incN','[]','[]')", [s.noteId])
    }

    @Test func conversionToAnotherVaultIsRefusedForAPublishedProtectedNote() async throws {
        let s = try lockedDevice("published"); defer { s.device.cleanup(); s.access.revoke() }
        try markPublished(s)
        let (other, _) = try CryptoEnvelope.create(password: "other password")
        try deliverEnvelope(other, to: s.device)
        s.device.password.update { $0 = "other password" }
        await #expect(throws: SyncNotePasswordError.self) { try await s.device.reconciler.applyPending() }
        #expect(try NotePrivacy(store: s.device.noteStore).envelope() == s.original, "the vault key is unchanged")
        #expect(try s.device.note(s.noteId)?.encryptedPayload == s.before, "the published ciphertext is not rewritten")
        #expect(try s.device.store.pair(for: s.device.ref("kb1", type: "keyBundle")) == nil)
    }

    @Test func conversionToAnotherVaultIsRefusedWhileASnapshotOfAProtectedNoteIsInFlight() async throws {
        let s = try lockedDevice("inflight"); defer { s.device.cleanup(); s.access.revoke() }
        let d = s.device
        try d.store.insertInflight(CloudInflight(entity: d.ref(s.noteId), localId: s.noteId, generation: 1, attemptId: "att-1", baseVer: 0, inc: "incN",
                                                 sealed: Data([1]), state: .sending, accountGeneration: try d.store.generation()))
        let (other, _) = try CryptoEnvelope.create(password: "other password")
        try deliverEnvelope(other, to: d)
        d.password.update { $0 = "other password" }
        await #expect(throws: SyncNotePasswordError.self) { try await d.reconciler.applyPending() }
        #expect(try d.note(s.noteId)?.encryptedPayload == s.before)
        // A snapshot prepared by the publisher itself counts the same way: preparing first, converting second is refused.
        let prepared = try PublisherDevice("prepared", account: nil); defer { prepared.cleanup() }
        let privacy = NotePrivacy(store: prepared.noteStore)
        let access = try privacy.setPassword("local password"); defer { access.revoke() }
        let note = try prepared.noteStore.create(text: "# Mine\nbody\n")
        try access.lock(noteId: note.id)
        prepared.access.update { $0 = access }
        let made = try await prepared.publisher.prepare()
        #expect(made.contains { $0.entity.entityId == note.id })
        try prepared.setEnabled(false)
        try deliverEnvelope(other, to: prepared)
        prepared.password.update { $0 = "other password" }
        await #expect(throws: SyncNotePasswordError.self) { try await prepared.reconciler.applyPending() }
    }

    @Test func conversionToAnotherVaultWorksForAnUnpublishedLibraryAndIsRepublishedUnderTheNewKey() async throws {
        let s = try lockedDevice("unpublished"); defer { s.device.cleanup(); s.access.revoke() }
        let d = s.device
        let (other, _) = try CryptoEnvelope.create(password: "other password")
        try deliverEnvelope(other, to: d)
        d.password.update { $0 = "other password" }
        let report = try await d.reconciler.applyPending()
        #expect(report.passwordChanged)
        #expect(try NotePrivacy(store: d.noteStore).envelope() == other)
        #expect(try d.note(s.noteId)?.encryptedPayload != s.before, "the note was re-sealed under the shared vault")
        let reopened = try NotePrivacy(store: d.noteStore).unlock(password: "other password"); defer { reopened.revoke() }
        #expect(try reopened.note(id: s.noteId)?.text == "# Local secret\nbody\n")
        let backups = try FileManager.default.contentsOfDirectory(at: d.paths.backups, includingPropertiesForKeys: nil).filter { $0.pathExtension == "baerchen-backup" }
        #expect(!backups.isEmpty, "a recoverable backup exists before the conversion")
        #expect(try d.dirtyGeneration(s.noteId) != nil, "the converted ciphertext is still to be published")
    }

    @Test func aPasswordChangeOfTheSameVaultIsAdoptedEvenForPublishedNotes() async throws {
        let s = try lockedDevice("rewrap"); defer { s.device.cleanup(); s.access.revoke() }
        let d = s.device
        try markPublished(s)
        let remote = try s.original.rewrapped(oldPassword: "local password", newPassword: "new password")
        try deliverEnvelope(remote, to: d)
        d.password.update { $0 = "new password" }
        let report = try await d.reconciler.applyPending()
        #expect(report.applied.contains { $0.entityType == "keyBundle" } && !report.passwordChanged)
        #expect(try NotePrivacy(store: d.noteStore).envelope() == remote)
        #expect(try d.note(s.noteId)?.encryptedPayload == s.before, "same vault key: the published ciphertext stays valid")
    }

    @Test func aProtectedLibraryWaitsForThePasswordInsteadOfConverting() async throws {
        let s = try lockedDevice("wait"); defer { s.device.cleanup(); s.access.revoke() }
        let (other, _) = try CryptoEnvelope.create(password: "other password")
        try deliverEnvelope(other, to: s.device)
        s.device.access.update { $0 = nil }
        let report = try await s.device.reconciler.applyPending()
        #expect(report.waitingForUnlock.map(\.entityType) == ["keyBundle"])
        #expect(try NotePrivacy(store: s.device.noteStore).envelope() == s.original)
    }

    // MARK: attachment fence against snapshots in flight

    @Test func preparePendingIsFencedAgainstInflightSnapshots() async throws {
        let d = try PublisherDevice("fence", account: nil); defer { d.cleanup() }
        let note = try d.noteStore.create(text: "# Files\n")
        _ = try AttachmentStore(paths: d.paths, database: d.db).add(data: Data("v1".utf8), filename: "f.txt", to: note.id)
        try d.edit(note.id, "# Files\n![f](f.txt)\n")
        try d.publishAttachments(of: note.id)
        let id = try #require(try d.string("SELECT id FROM attachment WHERE noteId=?", [note.id]))
        let preparer = CloudAttachmentPreparer(database: d.db, preparer: SyncAttachmentPreparer(database: d.db, paths: d.paths, accountID: d.accountID, vaultKey: d.key))
        // A snapshot of the attachment is in flight: it is not prepared again, whatever happens to the file meanwhile.
        try d.store.insertInflight(CloudInflight(entity: d.ref(id, type: "attachment"), localId: id, generation: 1, attemptId: "att-a", baseVer: 0, inc: "incF",
                                                 sealed: Data([1]), accountGeneration: try d.store.generation()))
        #expect(try await preparer.preparePending() == 0)
        #expect(try d.rowCount("sync_attachment_cache") == 0 && d.rowCount("sync_blob_state") == 0)
        // A fetched version waiting for its merge, a quarantine row and a pause fence it too.
        try d.store.discardInflight(attemptId: "att-a")
        try d.sql("INSERT INTO ck_missing(entityType,entityId,lastVer,lastInc,detectedAt,reason) VALUES('attachment',?,1,'incF',?, 'test')", [id, Date()])
        #expect(try await preparer.preparePending() == 0)
        try d.sql("DELETE FROM ck_missing")
        try d.sql("INSERT INTO ck_quarantine(recordName,entityType,entityId,reason,rawFields,firstSeen) VALUES(?,'attachment',?, 'version:99', x'7b7d', ?)", ["e.attachment.\(id)", id, Date()])
        #expect(try await preparer.preparePending() == 0)
        try d.sql("DELETE FROM ck_quarantine")
        // Free again: the same call prepares it.
        #expect(try await preparer.preparePending() == 1)
        #expect(try d.rowCount("sync_attachment_cache") == 1)
    }

    @Test func aPublisherNeverPreparesAnAttachmentUnderASnapshotOfItsOwn() async throws {
        let world = try await PublisherWorld.make(1); defer { world.cleanup() }
        let a = world.devices[0]
        let note = try a.noteStore.create(text: "# Files\n")
        _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: Data("v1".utf8), filename: "f.txt", to: note.id)
        try a.edit(note.id, "# Files\n![f](f.txt)\n")
        try a.publishAttachments(of: note.id)
        _ = try await a.publisher.prepare()                                  // snapshot of the file and the note
        let id = try #require(try a.string("SELECT id FROM attachment WHERE noteId=?", [note.id]))
        let cached = try a.int("SELECT generation FROM sync_attachment_cache WHERE attachmentId=?", [id])
        try Data("v2 changed".utf8).write(to: a.attachmentFile(note.id, "f.txt"))      // the file changes while the snapshot is in flight
        try a.sql("UPDATE sync_dirty SET generation=generation+1 WHERE entityType='attachment' AND localId=?", [id])
        _ = try await a.publisher.prepare()
        #expect(try a.int("SELECT generation FROM sync_attachment_cache WHERE attachmentId=?", [id]) == cached, "not prepared again while a snapshot is in flight")
        #expect(try a.rowCount("sync_blob_state") == 1)
    }

    // MARK: the CloudKit version check for attachment downloads

    @Test func aNoteDoesNotConsumeAnAttachmentVersionThatIsNoLongerTheNewestOne() async throws {
        let world = try await PublisherWorld.make(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let note = try a.noteStore.create(text: "# Files\n")
        _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: Data("bytes".utf8), filename: "f.txt", to: note.id)
        try a.edit(note.id, "# Files\n![f](f.txt)\n")
        try a.publishAttachments(of: note.id)
        try await a.sync()
        try b.copyBlobs(from: a)
        let attachmentName = try #require(await recordName(world, prefix: "e.attachment."))
        let id = attachmentName.replacingOccurrences(of: "e.attachment.", with: "")
        try await b.fetch()
        // The pair of the attachment moved past the version the note would consume (applied meanwhile, from another path).
        try b.sql("INSERT INTO ck_record(entityType,entityId,systemFields,ancestor,ver,inc,supersededIncs,sids) VALUES('attachment',?,x'01',x'02',5,?, '[]', '[]')",
                  [id, try decodedEntity(try #require(await world.account.record(named: attachmentName))).inc])
        let report = try await b.reconciler.applyPending(maxPasses: 1)
        #expect(report.retried.map(\.entityType) == ["note"], "the note retries instead of installing a stale file version")
        #expect(try b.note(note.id) == nil)
    }
}

