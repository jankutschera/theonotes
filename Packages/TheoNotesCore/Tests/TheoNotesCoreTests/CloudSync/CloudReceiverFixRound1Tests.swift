// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// Serves attachment ciphertext from the local cache and runs a hook before the first download (a version of the attachment
/// arrives while the note is being prepared).
final class InterceptingBlobs: SyncBlobTransport, @unchecked Sendable {
    let inner: CloudLocalBlobTransport
    private let lock = NSLock()
    private var fired = false
    var beforeFirstDownload: (@Sendable () -> Void)?
    init(_ inner: CloudLocalBlobTransport) { self.inner = inner }
    func ensureUploaded(_ hashes: [String]) async throws {}
    func download(hash: String) async throws -> URL {
        let hook = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { fired = true }
            return fired ? nil : beforeFirstDownload
        }
        hook?()
        return try await inner.download(hash: hash)
    }
}

extension Rec {
    /// A structurally valid, correctly sealed live note version, as another device would have saved it.
    static func sealedNote(_ device: PublisherDevice, id: String, ver: Int64, text: String, inc: String = "incA", incs: [String] = []) throws -> CloudRecord {
        var payload = SyncNotePayload(note: Note(id: id, text: text, title: "T", titleKey: "t", createdAt: .now, modifiedAt: .now), directTags: [], pinnedTags: [], attachmentIds: [])
        payload.attachmentNames = [:]
        let sealed = try device.sealer.sealLive(SyncPayloadCodec.encoder().encode(payload), type: .note, entityID: id)
        return entity(id, ver, inc: inc, incs: incs, payload: sealed)
    }
}

/// Fix round 1 of review point 2 (Codex, high): recovery across incarnations, the attachment pair, old-account work,
/// quarantine release, metadata across independent incarnations.
@Suite struct CloudReceiverFixRound1Tests {
    // MARK: C1 recovery can erase an acknowledged edit

    @Test func aLaggingDeviceRecoveringOlderContentNeverErasesACleanDevicesNewerEdit() async throws {
        let world = try await PublisherWorld.make(2); defer { world.cleanup() }
        let lagging = world.devices[0], current = world.devices[1]
        let note = try lagging.noteStore.create(text: "# Lag\nl1\nl2\n")
        try await lagging.sync(); try await current.sync()
        try current.edit(note.id, "# Lag\nl1\nl2\nNEWER-ACKNOWLEDGED-EDIT\n")
        try await current.sync()                                             // published and acknowledged; the lagging device never fetched it
        await world.account.removeRecord("e.note.\(note.id)")
        try await lagging.fullFetch(); try await current.fullFetch()
        _ = try lagging.incarnation.recover(entityType: "note", entityId: note.id)
        try await lagging.publish()                                          // older content becomes the new incarnation; it lists the old one
        // The current device is clean (nothing unpublished). It must not take the older content wholesale.
        try await current.fullFetch()
        _ = try await current.applyNotes()
        #expect(try current.snapshot().joined().contains("NEWER-ACKNOWLEDGED-EDIT"), "the acknowledged edit is still on the clean device")
        for _ in 0..<4 { try await current.sync(); try await lagging.sync() }
        for d in [current, lagging] { #expect(try d.snapshot().joined().contains("NEWER-ACKNOWLEDGED-EDIT"), "\(d.name) has it after convergence") }
        #expect(try current.snapshot() == lagging.snapshot())
    }

    @Test func aRecoveredRecordIdenticalToWhatThisDeviceHoldsMergesTheLocalEditCleanly() async throws {
        let world = try await PublisherWorld.make(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let note = try a.noteStore.create(text: "# Doc\nline one\nline two\nline three\n")
        try await a.sync(); try await b.sync()
        await world.account.removeRecord("e.note.\(note.id)")
        try await a.fullFetch()
        _ = try a.incarnation.recover(entityType: "note", entityId: note.id)
        try await a.sync()                                                    // same content under a new incarnation
        try b.edit(note.id, (try b.text(note.id) ?? "").replacingOccurrences(of: "line three", with: "line THREE from b"))
        try await b.sync(); try await a.sync(); try await b.sync()
        #expect(try a.text(note.id)?.contains("line THREE from b") == true, "ancestry is proven by equality: a clean merge, no copy")
        #expect(try a.snapshot() == b.snapshot() && a.notes().count == 1)
    }

    // MARK: C2 the attachment pair advances only to the bytes that were applied

    @Test func anAttachmentVersionThatArrivesWhileTheNoteDownloadsIsNeverRecordedAsApplied() async throws {
        let world = try await PublisherWorld.make(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let note = try a.noteStore.create(text: "# Files\n")
        _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: Data("attachment bytes v1".utf8), filename: "doc.txt", to: note.id)
        try a.edit(note.id, "# Files\n![doc](doc.txt)\n")
        try a.publishAttachments(of: note.id)
        try await a.sync()
        try b.copyBlobs(from: a)
        let attachmentName = try #require(await recordName(world, prefix: "e.attachment."))
        let id = attachmentName.replacingOccurrences(of: "e.attachment.", with: "")
        let v2 = try a.tombstone(after: try #require(await world.account.record(named: attachmentName)))
        try await b.fetch()
        let blobs = InterceptingBlobs(CloudLocalBlobTransport(database: b.db, paths: b.paths))
        blobs.beforeFirstDownload = { [sink = b.sink] in _ = try? sink.intake(v2, delivery: .incremental) }   // v2 arrives mid-download
        let reconciler = CloudReconciler(database: b.db, paths: b.paths, store: b.store, accountID: b.accountID, vaultKey: b.key,
                                         pinner: CloudAssetPinner(directory: b.paths.cloudPinned), blobs: blobs)
        let report = try await reconciler.applyPending(maxPasses: 1)
        let pair = try b.store.pair(for: b.ref(id, type: "attachment"))
        let installed = FileManager.default.fileExists(atPath: b.attachmentFile(note.id, "doc.txt").path)
        #expect(!(pair?.ver == 2 && installed), "the pair says version 2 was applied but version 1's bytes are on disk")
        #expect(report.retried.contains { $0.entityType == "note" }, "the note retries instead of installing a version that is no longer the newest")
        // Afterwards everything agrees: the tombstone is applied (the note's own pinned copy of the file may still be installed).
        _ = try await reconciler.applyPending()
        #expect(try b.store.pair(for: b.ref(id, type: "attachment"))?.ver == 2)
        #expect(try b.rowCount("ck_remote") == 0)
    }

    // MARK: I1 a quarantine is released only by a version that opens

    @Test func aNewerVersionWithAValidHeaderButACorruptPayloadLeavesTheQuarantinedRecordAndItsPinIntact() async throws {
        let world = try await PublisherWorld.make(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let note = try a.noteStore.create(text: bigText)
        try await a.sync()
        try await b.sync()
        let header = try await cloudHeader(world, note.id)
        await world.account.injectUnsupportedVersion(record: "e.note.\(note.id)")
        try await b.fetch()
        let row = try #require(try b.store.quarantineRows().first)
        let pin = try #require(row.pinnedAssets.first)
        #expect(try b.pinnedFiles().count == 1)
        // A newer version whose header is fine but whose ciphertext does not authenticate.
        _ = try b.sink.intake(Rec.entity(note.id, header.ver + 1, inc: header.inc, payload: Data(repeating: 7, count: 64)), delivery: .incremental)
        let report = try await b.reconciler.applyPending()
        #expect(report.applied.isEmpty)
        let after = try #require(try b.store.quarantineRows().first)
        #expect(after.rawFields == row.rawFields && after.pinnedAssets == [pin], "the earlier quarantined record is untouched")
        #expect(try CloudAssetPinner(directory: b.paths.cloudPinned).verify(pin).count > 200 * 1024, "and so is its pinned copy")
        #expect(try b.store.isFenced(entityType: "note", entityId: note.id))
        // A newer version that opens releases the fence and the pin together with the apply.
        _ = try b.sink.intake(try Rec.sealedNote(b, id: note.id, ver: header.ver + 2, text: "# Fixed\nvalid again\n", inc: header.inc), delivery: .incremental)
        let fixed = try await b.reconciler.applyPending()
        #expect(fixed.applied.map(\.entityId) == [note.id])
        #expect(try b.store.quarantineRows().isEmpty)
        #expect(try b.pinnedFiles().isEmpty)
        #expect(try b.text(note.id) == "# Fixed\nvalid again\n")
    }

    @Test func newerValidVerClearsQuarantineOnlyWhenItIsApplied() async throws {
        let d = try PublisherDevice("clears", account: nil); defer { d.cleanup() }
        var unsupported = Rec.entity("n1", 5)
        unsupported.fields["v"] = .int(99)
        #expect(try d.sink.intake(unsupported, delivery: .incremental) == .quarantined)
        // Stored, but the fence stays until it has been opened and applied.
        #expect(try d.sink.intake(try Rec.sealedNote(d, id: "n1", ver: 6, text: "# Six\n"), delivery: .incremental) == .stored)
        #expect(try d.store.isFenced(entityType: "note", entityId: "n1"))
        _ = try await d.reconciler.applyPending()
        #expect(!(try d.store.isFenced(entityType: "note", entityId: "n1")))
        #expect(try d.text("n1") == "# Six\n")
    }

    // MARK: I2 metadata across independent incarnations keeps the local value

    enum Kind: String, CaseIterable, Sendable { case setting, tag, externalRef }

    /// Sets this device's value `value` for the entity of `kind` (creating it when needed) and returns the cloud record prefix.
    func set(_ kind: Kind, _ value: String, on d: PublisherDevice, note: String) throws {
        switch kind {
        case .setting: try d.sql("INSERT INTO setting(key,value) VALUES('hideMarkdown',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [value])
        case .tag: try d.sql("UPDATE tag SET iconName=?, isPinned=1 WHERE pathKey='metatag'", [value])
        case .externalRef:
            try d.sql("INSERT INTO external_ref(source,externalId,noteId,lastSeenHash) VALUES('import','meta-1',?,?) ON CONFLICT(source,externalId) DO UPDATE SET lastSeenHash=excluded.lastSeenHash", [note, value])
        }
    }

    func read(_ kind: Kind, on d: PublisherDevice) throws -> String? {
        switch kind {
        case .setting: return try d.string("SELECT value FROM setting WHERE key='hideMarkdown'")
        case .tag: return try d.string("SELECT iconName FROM tag WHERE pathKey='metatag'")
        case .externalRef: return try d.string("SELECT lastSeenHash FROM external_ref WHERE externalId='meta-1'")
        }
    }

    func prefix(_ kind: Kind) -> String {
        switch kind { case .setting: return "e.setting."; case .tag: return "e.tagPreference."; case .externalRef: return "e.externalRef." }
    }

    func start(_ kind: Kind) async throws -> (PublisherWorld, Note) {
        let world = try await PublisherWorld.make(2)
        let a = world.devices[0], b = world.devices[1]
        let note = try a.noteStore.create(text: "# Meta\n#metatag\n")
        try set(kind, kind == .setting ? "false" : kind == .tag ? "star" : "hash-v0", on: a, note: note.id)
        try await a.sync(); try await b.sync()
        #expect(try read(kind, on: b) != nil)
        return (world, note)
    }

    @Test(arguments: Kind.allCases)
    func aCleanDeviceKeepsItsLocalMetadataWhenAnIndependentIncarnationDiffers(kind: Kind) async throws {
        let (world, note) = try await start(kind); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let local = try #require(try read(kind, on: b))
        let name = try #require(await recordName(world, prefix: prefix(kind)))
        await world.account.removeRecord(name)
        try await a.fullFetch(); try await b.fullFetch()
        try set(kind, kind == .setting ? "true" : kind == .tag ? "bolt" : "hash-v1", on: a, note: note.id)
        for (entity, _) in try a.incarnation.recoverAll() where entity.recordName == name { _ = entity }
        try await a.sync()                                                    // a's value becomes a new incarnation
        try await b.fullFetch()                                               // b is clean and holds the old value
        _ = try await b.applyNotes()
        #expect(try read(kind, on: b) == local, "the local value is kept")
        #expect(try b.dirtyCount() > 0, "and marked for republishing onto the new incarnation")
        for _ in 0..<4 { try await b.sync(); try await a.sync() }
        #expect(try read(kind, on: a) == local && read(kind, on: b) == local, "both converge on the kept value")
        #expect(try b.store.quarantineRows().isEmpty && a.store.quarantineRows().isEmpty)
    }

    @Test(arguments: Kind.allCases)
    func theLoserOfARecoveryRaceKeepsItsOwnMetadataAndTheRaceConverges(kind: Kind) async throws {
        let (world, note) = try await start(kind); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let name = try #require(await recordName(world, prefix: prefix(kind)))
        await world.account.removeRecord(name)
        try await a.fullFetch(); try await b.fullFetch()
        let mine = kind == .setting ? "true" : kind == .tag ? "bolt" : "hash-a", theirs = kind == .setting ? "false" : kind == .tag ? "heart" : "hash-b"
        try set(kind, mine, on: a, note: note.id)
        try set(kind, theirs == "false" ? "false" : theirs, on: b, note: note.id)
        // b's local value must differ from a's for the race to mean anything
        if kind == .setting { try set(kind, "false", on: b, note: note.id); try set(kind, "true", on: a, note: note.id) }
        _ = try a.incarnation.recoverAll(); _ = try b.incarnation.recoverAll()
        try await a.publish()                                                 // a wins
        try await b.publish()                                                 // b's create meets a's record
        for _ in 0..<5 { try await b.sync(); try await a.sync() }
        let valueA = try read(kind, on: a), valueB = try read(kind, on: b)
        #expect(valueA == valueB, "converged")
        #expect(valueB == (kind == .setting ? "false" : theirs), "the loser's value was kept (the winner's metadata change is the accepted cost)")
        #expect(try a.dirtyCount() == 0 && b.dirtyCount() == 0 && a.store.allMissing().isEmpty && b.store.allMissing().isEmpty)
    }

    // MARK: C3 old work cannot touch what belongs to the new account

    @Test func aDelayedOldAccountOperationDeletesNothingNotEvenThePinnedAsset() async throws {
        let world = try await PublisherWorld.make(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let note = try a.noteStore.create(text: bigText)
        try await a.sync()
        try await b.fetch()
        let remote = try #require(try b.store.remote(recordName: "e.note.\(note.id)"))
        let path = try #require(remote.sealedPath)
        let pinned = CloudAssetPinner(directory: b.paths.cloudPinned).url(for: path)
        let old = try b.store.generation()
        // a quarantine row for another record, looked at by the same old work
        var unsupported = Rec.entity("other", 5); unsupported.fields["v"] = .int(99)
        _ = try b.sink.intake(unsupported, delivery: .incremental)
        let quarantined = try #require(try b.store.quarantineRow(recordName: "e.note.other"))
        try b.store.bumpGeneration()                                          // the account changed
        let now = try b.store.generation()
        func intact() throws {
            #expect(try b.store.remote(recordName: remote.recordName) != nil && FileManager.default.fileExists(atPath: pinned.path))
            #expect(try b.store.quarantineRow(recordName: "e.note.other") != nil)
        }
        #expect(throws: CloudSyncStoreError.self) { try b.store.deleteRemote(remote, accountGeneration: old) }
        #expect(throws: CloudSyncStoreError.self) { try b.store.setWaiting(remote, .dependency, accountGeneration: old) }
        #expect(throws: CloudSyncStoreError.self) { try b.store.quarantineRemote(remote, reason: "late", accountGeneration: old) }
        #expect(throws: CloudSyncStoreError.self) { try b.store.releaseQuarantine(recordName: "e.note.other", matchingRaw: quarantined.rawFields, accountGeneration: old) }
        try intact()
        // The row predicate is exact: another version of the same name is not this row, even in the current generation.
        var anotherVersion = remote; anotherVersion.ver += 1
        #expect(try b.store.deleteRemote(anotherVersion, accountGeneration: now).isEmpty)
        #expect(try b.store.releaseQuarantine(recordName: "e.note.other", matchingRaw: Data("not the record".utf8), accountGeneration: now).isEmpty)
        try intact()
        // While the account fence is up nothing is written, whatever the generation.
        try b.store.setAccountFenced(true)
        #expect(throws: CloudSyncStoreError.accountFenced) { try b.store.deleteRemote(remote, accountGeneration: now) }
        #expect(throws: CloudSyncStoreError.accountFenced) { try b.store.setWaiting(remote, .unlock, accountGeneration: now) }
        #expect(throws: CloudSyncStoreError.accountFenced) { try b.store.releaseQuarantine(recordName: "e.note.other", matchingRaw: quarantined.rawFields, accountGeneration: now) }
        try b.store.setAccountFenced(false)
        try intact()
        // A receiver run that started before the change applies, drops and deletes nothing.
        let stale = CloudReconciler(database: b.db, paths: b.paths, store: b.store, accountID: b.accountID, vaultKey: b.key,
                                    pinner: CloudAssetPinner(directory: b.paths.cloudPinned), generation: { old })
        await #expect(throws: (any Error).self) { try await stale.applyPending() }
        #expect(try b.notes().isEmpty)
        try intact()
    }

    // MARK: the vault conversion error the settings UI maps

    @Test func convertingToAnotherVaultWhileSyncIsOnReturnsATypedErrorNotADifferentVaultsError() async throws {
        let d = try PublisherDevice("typed", account: nil); defer { d.cleanup() }
        let access = try NotePrivacy(store: d.noteStore).setPassword("local password"); defer { access.revoke() }
        let note = try d.noteStore.create(text: "# Local\nbody\n")
        try access.lock(noteId: note.id)
        d.access.update { $0 = access }
        try d.setEnabled(true)
        let (other, _) = try CryptoEnvelope.create(password: "other password")
        let payload = SyncLockEnvelopePayload(envelope: try JSONEncoder().encode(other))
        let sealed = try d.sealer.sealLive(try SyncPayloadCodec.encoder().encode(payload), type: .keyBundle, entityID: "kb1")
        var record = CloudRecordCodec.encode(CloudEntityHeader(entityType: .keyBundle, entityId: "kb1", inc: "incKB", incs: [], ver: 1, sid: "sid-kb", sids: ["sid-kb"],
                                                               payload: .inline(sealed), blobs: []))
        record.systemFields = Data("tag-kb".utf8)
        _ = try d.sink.intake(record, delivery: .incremental)
        d.password.update { $0 = "other password" }
        await #expect(throws: CloudVaultConversionError.syncMustBeOff) { try await d.reconciler.applyPending() }
        #expect(try NotePrivacy(store: d.noteStore).envelope() != other)
    }

    // MARK: parked for Task 10

    @Test
    func tagPreferencesSurviveATagLeavingEveryNoteAndReturning() async throws {
        let world = try await PublisherWorld.make(1); defer { world.cleanup() }
        let a = world.devices[0]
        let note = try a.noteStore.create(text: "# Tag\n#keepicon\n")
        try a.sql("UPDATE tag SET iconName='star', isPinned=1 WHERE pathKey='keepicon'")
        try await a.sync()
        try a.edit(note.id, "# Tag\nno tag any more\n")
        try await a.sync()
        try a.edit(note.id, "# Tag\n#keepicon\n")
        try await a.sync()
        #expect(try a.string("SELECT iconName FROM tag WHERE pathKey='keepicon'") == "star")
    }
}
