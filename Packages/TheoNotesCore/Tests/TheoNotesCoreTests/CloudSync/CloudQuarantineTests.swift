// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// Wraps the production sink and records what the disk looked like when the engine state was about to be saved.
final class ProbeSink: CloudChangeSink, @unchecked Sendable {
    let inner: CloudFeedSink
    let pinnedFilesAtStateSave = LockedBox<[Int]>([])
    let pinnedCount: @Sendable () -> Int
    init(inner: CloudFeedSink, pinnedCount: @escaping @Sendable () -> Int) { self.inner = inner; self.pinnedCount = pinnedCount }
    func commit(changed: [CloudRecord], deletedNames: [String]) throws { try inner.commit(changed: changed, deletedNames: deletedNames) }
    func saveEngineState(_ state: Data) throws {
        pinnedFilesAtStateSave.update { $0.append(pinnedCount()) }
        try inner.saveEngineState(state)
    }
    func beginFullRefetch() throws { try inner.beginFullRefetch() }
    func endFullRefetch() throws { try inner.endFullRefetch() }
}

/// Deletes the staged asset files of a batch before the real sink can copy them.
final class EvictingSink: CloudChangeSink, @unchecked Sendable {
    let inner: CloudFeedSink
    init(inner: CloudFeedSink) { self.inner = inner }
    func commit(changed: [CloudRecord], deletedNames: [String]) throws {
        for record in changed { for case .asset(let url) in record.fields.values { try? FileManager.default.removeItem(at: url) } }
        try inner.commit(changed: changed, deletedNames: deletedNames)
    }
    func saveEngineState(_ state: Data) throws { try inner.saveEngineState(state) }
    func beginFullRefetch() throws { try inner.beginFullRefetch() }
    func endFullRefetch() throws { try inner.endFullRefetch() }
}

let bigText = String(repeating: "lorem ipsum dolor sit amet ", count: 12_000)   // about 320 KB: the sealed payload travels as an asset

/// Unreadable records, assets pinned before the token advances, the fence (CK-R5).
@Suite struct CloudQuarantineTests {
    struct Lab {
        let world: PublisherWorld
        var a: PublisherDevice { world.devices[0] }
        var b: PublisherDevice { world.devices[1] }
        func quarantine(_ device: PublisherDevice? = nil) -> CloudQuarantine {
            let d = device ?? b
            return CloudQuarantine(store: d.store, pinner: CloudAssetPinner(directory: d.paths.cloudPinned), sink: d.sink)
        }
    }

    func lab() async throws -> Lab { Lab(world: try await PublisherWorld.make(2)) }

    /// The sink of `device` with a build that understands record format 99 (it reads it as 1).
    func taught(_ d: PublisherDevice) -> CloudFeedSink {
        CloudFeedSink(store: d.store, pinner: CloudAssetPinner(directory: d.paths.cloudPinned),
                      decode: { record in var copy = record; if case .int(99)? = copy.fields["v"] { copy.fields["v"] = .int(1) }; return try CloudRecordCodec.decode(copy) })
    }

    // MARK: fail closed

    @Test func unsupportedVersionFollowedByValidRecordsAppliesTheValidOnesAndKeepsTheOtherQuarantined() async throws {
        let l = try await lab(); defer { l.world.cleanup() }
        let one = try l.a.noteStore.create(text: "# One\nx\n"), two = try l.a.noteStore.create(text: "# Two\ny\n")
        try await l.a.sync()
        await l.world.account.injectUnsupportedVersion(record: "e.note.\(one.id)")
        try await l.b.fetch()
        let report = try await l.b.reconciler.applyPending()
        #expect(try l.b.notes().map(\.id) == [two.id])
        #expect(report.applied.map(\.entityId) == [two.id])
        let rows = try l.b.store.quarantineRows()
        #expect(rows.map(\.recordName) == ["e.note.\(one.id)"] && rows[0].reason == "version:99")
        #expect(try l.b.store.isFenced(entityType: "note", entityId: one.id))
        #expect(try l.quarantine().summary().needsAppUpdate == 1)
        #expect(try l.b.store.engineState() != nil, "the state moved on: the unreadable record is kept, not refetched forever")
    }

    @Test func quarantinedRecordIsAppliedAfterTheAppLearnsTheVersion() async throws {
        let l = try await lab(); defer { l.world.cleanup() }
        let note = try l.a.noteStore.create(text: "# Later\nbody\n")
        try await l.a.sync()
        await l.world.account.injectUnsupportedVersion(record: "e.note.\(note.id)")
        try await l.b.fetch()
        _ = try await l.b.reconciler.applyPending()
        #expect(try l.b.notes().isEmpty)
        // A newer build: the same quarantine, retried with a decoder that knows the version.
        let newer = CloudQuarantine(store: l.b.store, pinner: CloudAssetPinner(directory: l.b.paths.cloudPinned), sink: taught(l.b))
        let retry = try newer.retryAll()
        #expect(retry.released == ["e.note.\(note.id)"])
        #expect(try l.b.store.quarantineRows().count == 1, "handed to the receiver, but the fence stays until the payload opened and was applied")
        _ = try await l.b.reconciler.applyPending()
        #expect(try l.b.store.quarantineRows().isEmpty)
        #expect(try l.b.note(note.id)?.text == "# Later\nbody\n")
        // The old build keeps it quarantined, every time.
        let old = try await lab(); defer { old.world.cleanup() }
        let n2 = try old.a.noteStore.create(text: "# Old\nz\n")
        try await old.a.sync()
        await old.world.account.injectUnsupportedVersion(record: "e.note.\(n2.id)")
        try await old.b.fetch()
        #expect(try old.quarantine().retryAll().stillQuarantined == ["e.note.\(n2.id)"])
    }

    @Test func corruptCiphertextIsQuarantinedNeverApplied() async throws {
        let l = try await lab(); defer { l.world.cleanup() }
        let note = try l.a.noteStore.create(text: "# Secret\nbody\n")
        try await l.a.sync()
        await l.world.account.corrupt(record: "e.note.\(note.id)", field: "cipher")
        try await l.b.fetch()
        let report = try await l.b.reconciler.applyPending()
        #expect(try l.b.notes().isEmpty)
        #expect(report.quarantined.map(\.entityId) == [note.id])
        #expect(try l.b.store.quarantineRows().first?.reason.hasPrefix("payload:") == true)
        #expect(try l.b.rowCount("ck_remote") == 0 && l.b.store.pair(for: l.b.ref(note.id)) == nil)
        #expect(try l.b.store.isFenced(entityType: "note", entityId: note.id))
        #expect(try l.quarantine().summary().unreadable == 1)
    }

    @Test func wrongAccountContextIsQuarantined() async throws {
        let l = try await lab(); defer { l.world.cleanup() }
        let note = try l.a.noteStore.create(text: "# Mine\nbody\n")
        try await l.a.sync()
        // A record whose ciphertext was sealed for another entity id is not a copy of this one.
        var moved = try #require(await l.world.account.record(named: "e.note.\(note.id)"))
        moved.name = "e.note.other"; moved.fields["eid"] = .string("other")
        _ = try l.b.sink.intake(moved, delivery: .incremental)
        let report = try await l.b.reconciler.applyPending()
        #expect(report.quarantined.map(\.entityId) == ["other"])
        #expect(try l.b.notes().isEmpty)
        #expect(try l.b.store.quarantineRows().first?.reason == "payload:authentication")
    }

    @Test func newerValidVerClearsQuarantine() async throws {
        let d = try PublisherDevice("newer", account: nil); defer { d.cleanup() }
        var unsupported = Rec.entity("n1", 5)
        unsupported.fields["v"] = .int(99)
        #expect(try d.sink.intake(unsupported, delivery: .incremental) == .quarantined)
        #expect(try d.store.isFenced(entityType: "note", entityId: "n1"))
        // An older valid version does not lift it, the quarantined one is newer.
        _ = try d.sink.intake(try Rec.sealedNote(d, id: "n1", ver: 3, text: "# Three\n"), delivery: .incremental)
        _ = try await d.reconciler.applyPending()
        #expect(try d.store.isFenced(entityType: "note", entityId: "n1"))
        #expect(try d.note("n1") == nil)
        // A newer valid version lifts it, once it has been opened and applied.
        #expect(try d.sink.intake(try Rec.sealedNote(d, id: "n1", ver: 6, text: "# Six\n"), delivery: .incremental) == .stored)
        _ = try await d.reconciler.applyPending()
        #expect(try d.store.quarantineRows().isEmpty)
        #expect(!(try d.store.isFenced(entityType: "note", entityId: "n1")))
        #expect(try d.text("n1") == "# Six\n")
    }

    // MARK: assets

    @Test func quarantinePinsAssetsBeforeTheTokenAdvances() async throws {
        let l = try await lab(); defer { l.world.cleanup() }
        let note = try l.a.noteStore.create(text: bigText)
        try await l.a.sync()
        await l.world.account.injectUnsupportedVersion(record: "e.note.\(note.id)")
        let b = l.b
        let probe = ProbeSink(inner: b.sink, pinnedCount: { (try? b.pinnedFiles().count) ?? -1 })
        try await b.gateway.fetchChanges(into: probe)
        #expect(probe.pinnedFilesAtStateSave.value.allSatisfy { $0 == 1 }, "the copy exists before every state save")
        #expect(!probe.pinnedFilesAtStateSave.value.isEmpty)
        let row = try #require(try b.store.quarantineRows().first)
        let pin = try #require(row.pinnedAssets.first)
        #expect(pin.field == "cipherAsset")
        #expect(try CloudAssetPinner(directory: b.paths.cloudPinned).verify(pin).count > 200 * 1024)
    }

    @Test func copyFailureAbortsTheBatchAndTheStateSave() async throws {
        let l = try await lab(); defer { l.world.cleanup() }
        let note = try l.a.noteStore.create(text: bigText)
        try await l.a.sync()
        // The system empties the staging area between the fetch and the copy.
        let evicting = EvictingSink(inner: l.b.sink)
        await #expect(throws: (any Error).self) { try await l.b.gateway.fetchChanges(into: evicting) }
        #expect(try l.b.store.engineState() == nil, "the token did not advance")
        #expect(try l.b.rowCount("ck_remote") == 0 && l.b.rowCount("ck_quarantine") == 0)
        #expect(try l.b.pinnedFiles().isEmpty)
        try await l.b.fetch()                                    // redelivered, staged again
        #expect(try l.b.remoteVersions().keys.contains("e.note.\(note.id)"))
        #expect(try l.b.store.engineState() != nil)
    }

    @Test func restartAfterQuarantineKeepsPinnedAssets() async throws {
        let l = try await lab(); defer { l.world.cleanup() }
        let note = try l.a.noteStore.create(text: bigText)
        try await l.a.sync()
        await l.world.account.injectUnsupportedVersion(record: "e.note.\(note.id)")
        try await l.b.fetch()
        // A new process: new objects over the same library folder; the staging area is gone.
        await l.b.gateway.evictStagedAssets()
        let store = CloudSyncStore(database: l.b.db)
        let pinner = CloudAssetPinner(directory: l.b.paths.cloudPinned)
        let row = try #require(try store.quarantineRows().first)
        #expect(try pinner.verify(try #require(row.pinnedAssets.first)).count > 200 * 1024)
        try pinner.sweep(store: store, minimumAge: 0)
        #expect(try l.b.pinnedFiles().count == 1, "a referenced file is never swept")
    }

    @Test func stagingFileEvictionBeforeALaterSuccessfulRetryStillApplies() async throws {
        let l = try await lab(); defer { l.world.cleanup() }
        let note = try l.a.noteStore.create(text: bigText)
        try await l.a.sync()
        await l.world.account.injectUnsupportedVersion(record: "e.note.\(note.id)")
        try await l.b.fetch()
        await l.b.gateway.evictStagedAssets()
        let newer = CloudQuarantine(store: l.b.store, pinner: CloudAssetPinner(directory: l.b.paths.cloudPinned), sink: taught(l.b))
        #expect(try newer.retryAll().released.count == 1)
        _ = try await l.b.reconciler.applyPending()
        #expect(try l.b.note(note.id)?.text == bigText)
        #expect(try l.b.pinnedFiles().isEmpty, "the pinned file goes with the applied row")
    }

    @Test func crashBetweenAssetCopyAndCommitLeavesNoRowAndTheFileIsSwept() async throws {
        let crash = CrashPoint()
        let account = FakeCloudKitAccount()
        let a = try PublisherDevice("a", account: account), b = try PublisherDevice("b", account: account, crash: crash)
        defer { a.cleanup(); b.cleanup() }
        try await a.prepareGateway(); try await b.prepareGateway()
        _ = try a.noteStore.create(text: bigText)
        try await a.sync()
        crash.arm("sink.afterPin")
        await #expect(throws: CrashInjected.self) { try await b.fetch() }
        #expect(try b.rowCount("ck_remote") == 0 && b.store.engineState() == nil)
        #expect(try b.pinnedFiles().count == 1, "the file exists, no row names it")
        let pinner = CloudAssetPinner(directory: b.paths.cloudPinned)
        #expect(try pinner.sweep(store: b.store).isEmpty, "a fresh file is kept for a day")
        #expect(try pinner.sweep(store: b.store, minimumAge: 86_400, now: Date().addingTimeInterval(2 * 86_400)).count == 1)
        #expect(try b.pinnedFiles().isEmpty)
    }

    @Test func pinnedFilesRemovedWhenQuarantineClearsOrIsIgnored() async throws {
        let l = try await lab(); defer { l.world.cleanup() }
        let one = try l.a.noteStore.create(text: bigText + "one")
        try await l.a.sync()
        let header = try await cloudHeader(l.world, one.id)
        await l.world.account.injectUnsupportedVersion(record: "e.note.\(one.id)")
        try await l.b.fetch()
        #expect(try l.b.pinnedFiles().count == 1)
        // Cleared by a newer valid version of the entity (a version the app understands replaces it): files go.
        let valid = try Rec.sealedNote(l.b, id: one.id, ver: header.ver + 1, text: "# Newer\nvalid\n", inc: header.inc)
        _ = try l.b.sink.intake(valid, delivery: .incremental)
        _ = try await l.b.reconciler.applyPending()
        #expect(try l.b.store.quarantineRows().isEmpty)
        #expect(try l.b.pinnedFiles().isEmpty)
    }

    @Test func pinnedCopyHashMismatchAbortsTheBatch() async throws {
        let l = try await lab(); defer { l.world.cleanup() }
        _ = try l.a.noteStore.create(text: bigText)
        try await l.a.sync()
        struct Flip: Error {}
        let corrupting = CloudAssetPinner(directory: l.b.paths.cloudPinned, afterCopy: { url in
            var data = try Data(contentsOf: url); data[0] ^= 0xFF; try data.write(to: url)
        })
        let sink = CloudFeedSink(store: l.b.store, pinner: corrupting)
        await #expect(throws: CloudIntakeError.self) { try await l.b.gateway.fetchChanges(into: sink) }
        #expect(try l.b.store.engineState() == nil && l.b.rowCount("ck_remote") == 0)
        #expect(try l.b.pinnedFiles().isEmpty, "the bad copy is removed")
    }

    @Test func goodEntityWithCipherAssetIsPinnedBeforeTheStateSave() async throws {
        let l = try await lab(); defer { l.world.cleanup() }
        let note = try l.a.noteStore.create(text: bigText)
        try await l.a.sync()
        let b = l.b
        let probe = ProbeSink(inner: b.sink, pinnedCount: { (try? b.pinnedFiles().count) ?? -1 })
        try await b.gateway.fetchChanges(into: probe)
        #expect(probe.pinnedFilesAtStateSave.value == [1])
        let row = try #require(try b.store.remote(recordName: "e.note.\(note.id)"))
        #expect(row.sealed == nil && row.sealedPath != nil && row.sealedSha256 != nil)
        _ = try await b.reconciler.applyPending()
        #expect(try b.note(note.id)?.text == bigText)
    }

    @Test func blobPartAssetsAreNotPinnedAtFetch() async throws {
        let account = FakeCloudKitAccount()
        let b = try PublisherDevice("b", account: account); defer { b.cleanup() }
        try await b.prepareGateway()
        let store = InMemoryCloudGatewayStore()
        let writer = try await Peer.make(account)
        _ = store
        let part = CloudRecordCodec.encode(CloudBlobPartHeader(
            hash: String(repeating: "a", count: 64), part: 0, parts: 1, partBytes: 33_554_432, totalBytes: 3,
            partSha256: String(repeating: "b", count: 64), asset: try tempFile(Data([1, 2, 3]))))
        try await writer.save(part)
        await b.gateway.setFetchesBlobZone(true)      // a peer that puts parts into the fetched zone: the receiver still skips them
        await b.gateway.setDeliversBlobPartAssets(true)
        try await b.fetch()
        #expect(try b.pinnedFiles().isEmpty)
        #expect(try b.rowCount("ck_blob_part") == 0)
        #expect(try b.rowCount("ck_remote") == 0 && b.rowCount("ck_quarantine") == 0, "a part is skipped, never stored or quarantined")
    }

    @Test func aBatchMixingEntitiesAndBlobPartsAppliesTheEntitiesAndStoresNothingForTheParts() async throws {
        let l = try await lab(); defer { l.world.cleanup() }
        let note = try l.a.noteStore.create(text: "# Mixed\nbody\n")
        try await l.a.sync()
        let writer = try await Peer.make(l.world.account)
        // One part with a valid shape and one that is damaged: neither is stored, pinned or quarantined.
        let part = CloudRecordCodec.encode(CloudBlobPartHeader(
            hash: String(repeating: "c", count: 64), part: 0, parts: 1, partBytes: 33_554_432, totalBytes: 3,
            partSha256: String(repeating: "d", count: 64), asset: try tempFile(Data([1, 2, 3]))))
        try await writer.save(part)
        var damaged = CloudRecordCodec.encode(CloudBlobPartHeader(
            hash: String(repeating: "e", count: 64), part: 0, parts: 1, partBytes: 33_554_432, totalBytes: 3,
            partSha256: String(repeating: "f", count: 64), asset: try tempFile(Data([4, 5, 6]))))
        damaged.fields["v"] = .int(99)
        try await writer.save(damaged)
        await l.b.gateway.setFetchesBlobZone(true)    // parts in the fetched zone (a peer that misplaces them): still skipped by the receiver
        try await l.b.fetch()
        let report = try await l.b.reconciler.applyPending()
        #expect(report.applied.map(\.entityId) == [note.id])
        #expect(try l.b.note(note.id)?.text == "# Mixed\nbody\n")
        #expect(try l.b.rowCount("ck_blob_part") == 0 && l.b.rowCount("ck_quarantine") == 0 && l.b.rowCount("ck_remote") == 0)
        #expect(try l.b.pinnedFiles().isEmpty)
        #expect(try l.b.store.engineState() != nil)
    }

    // MARK: the fence

    @Test func fenceBlocksApplyingOtherVersionsOfAQuarantinedEntity() async throws {
        let l = try await lab(); defer { l.world.cleanup() }
        let note = try l.a.noteStore.create(text: "# Fenced\nv1\n")
        try await l.a.sync()
        try await l.b.fetch()
        _ = try await l.b.reconciler.applyPending()                       // b holds version 1
        try l.a.edit(note.id, "# Fenced\nv2\n")
        try await l.a.sync()
        let two = try #require(await l.world.account.record(named: "e.note.\(note.id)"))
        var unsupported = Rec.entity(note.id, 9, inc: try #require(try l.b.store.pair(for: l.b.ref(note.id))?.inc))
        unsupported.fields["v"] = .int(99)
        #expect(try l.b.sink.intake(unsupported, delivery: .incremental) == .quarantined)
        #expect(try l.b.sink.intake(two, delivery: .incremental) == .stored, "an older valid version is stored, not applied")
        let report = try await l.b.reconciler.applyPending()
        #expect(report.fenced.map(\.entityId) == [note.id])
        #expect(try l.b.note(note.id)?.text == "# Fenced\nv1\n")
        #expect(try l.b.store.pair(for: l.b.ref(note.id))?.ver == 1)
        // And no save is prepared for it either: local edits only raise the dirty generation.
        try l.b.edit(note.id, "# Fenced\nv1 local\n")
        let publish = try await l.b.publish()
        #expect(publish.submitted == 0 && publish.saved == 0)
        #expect(try l.b.dirtyGeneration(note.id) != nil)
    }

    @Test func ignoreItIsExplicitAndDeletesPinnedFiles() async throws {
        let l = try await lab(); defer { l.world.cleanup() }
        let note = try l.a.noteStore.create(text: bigText)
        try await l.a.sync()
        await l.world.account.injectUnsupportedVersion(record: "e.note.\(note.id)")
        try await l.b.fetch()
        #expect(try l.b.pinnedFiles().count == 1)
        #expect(try l.b.store.isFenced(entityType: "note", entityId: note.id))
        // Nothing lifts the fence by itself.
        _ = try l.quarantine().retryAll()
        #expect(try l.b.store.isFenced(entityType: "note", entityId: note.id))
        try l.quarantine().ignore(recordName: "e.note.\(note.id)")
        #expect(!(try l.b.store.isFenced(entityType: "note", entityId: note.id)))
        #expect(try l.b.pinnedFiles().isEmpty)
        let summary = try l.quarantine().summary()
        #expect(summary.ignored == 1 && summary.needsAppUpdate == 0)
        // The same record delivered again does not re-fence the item the person chose to ignore.
        await l.b.gateway.expireTokenNextFetch()
        try await l.b.fetch()
        #expect(!(try l.b.store.isFenced(entityType: "note", entityId: note.id)))
    }
}
