// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

extension CloudRecord {
    var ver: Int64? { if case .int(let v)? = fields["ver"] { return v }; return nil }
    var sid: String? { if case .string(let s)? = fields["sid"] { return s }; return nil }
    var inc: String? { if case .string(let s)? = fields["inc"] { return s }; return nil }
    var sids: [String] { if case .strings(let s)? = fields["sids"] { return s }; return [] }
    var incs: [String] { if case .strings(let s)? = fields["incs"] { return s }; return [] }
    var blobs: [String] { if case .strings(let s)? = fields["blobs"] { return s }; return [] }
    var cipher: Data? { if case .bytes(let d)? = fields["cipher"] { return d }; return nil }
    var cipherAsset: URL? { if case .asset(let u)? = fields["cipherAsset"] { return u }; return nil }
}

/// Journal, generations, record shape (CK-R4, CK-R17, CK-R3).
@Suite struct CloudPublisherTests {
    static func text(_ sealer: CloudPayloadSealer, _ record: CloudRecord, id: String) throws -> String? {
        let sealed = try record.cipher ?? Data(contentsOf: try #require(record.cipherAsset))
        switch try sealer.open(sealed, type: .note, entityID: id) {
        case .deleted: return nil
        case .live(let body): return try SyncPayloadCodec.decode(SyncNotePayload.self, from: body).text
        }
    }

    // MARK: first publish and later saves

    @Test func aFirstPublishCreatesAnIncarnationAndVersionOneWithoutSystemFields() async throws {
        let world = try await PublisherWorld.make(1); defer { world.cleanup() }
        let a = world.devices[0]
        let note = try a.noteStore.create(text: "# One\nbody\n")
        let report = try await a.publish()
        #expect(report.prepared == 1 && report.submitted == 1 && report.saved == 1)
        let record = try #require(await world.account.record(named: "e.note.\(note.id)"))
        #expect(record.ver == 1 && record.sid != nil && record.sids == [record.sid!])
        #expect(!(record.inc ?? "").isEmpty && record.incs.isEmpty)
        let log = await a.gateway.sendLog
        #expect(log.count == 1 && log[0].hadSystemFields == false)
        let pair = try #require(try a.store.pair(for: a.ref(note.id)))
        #expect(pair.ver == 1 && pair.inc == record.inc && pair.sids == record.sids)
        #expect(try a.dirtyCount() == 0 && a.store.allInflight().isEmpty)
        #expect(try Self.text(a.sealer, record, id: note.id) == "# One\nbody\n")
    }

    @Test func laterSavesKeepTheIncarnationAndUseBaseVersionPlusOneAndExtendTheChain() async throws {
        let world = try await PublisherWorld.make(1); defer { world.cleanup() }
        let a = world.devices[0]
        let note = try a.noteStore.create(text: "# One\n")
        try await a.publish()
        let first = try #require(await world.account.record(named: "e.note.\(note.id)"))
        try a.edit(note.id, "# One\nmore\n")
        try await a.publish()
        let second = try #require(await world.account.record(named: "e.note.\(note.id)"))
        #expect(second.ver == 2 && second.inc == first.inc)
        #expect(second.sids == [second.sid!, first.sid!])
        let log = await a.gateway.sendLog
        #expect(log.map(\.hadSystemFields) == [false, true])
    }

    @Test func theAttemptChainIsTruncatedToEight() async throws {
        let world = try await PublisherWorld.make(1); defer { world.cleanup() }
        let a = world.devices[0]
        let note = try a.noteStore.create(text: "# Chain\n")
        try await a.publish()
        for n in 1...10 { try a.edit(note.id, "# Chain\nedit \(n)\n"); try await a.publish() }
        let record = try #require(await world.account.record(named: "e.note.\(note.id)"))
        #expect(record.ver == 11 && record.sids.count == 8 && record.sids[0] == record.sid)
        #expect(Set(record.sids).count == 8)
    }

    // MARK: journal and generations

    @Test func editsDuringFlightRaiseGenerationAndKeepDirty() async throws {
        let world = try await PublisherWorld.make(1); defer { world.cleanup() }
        let a = world.devices[0]
        await a.gateway.setAutoSend(false)
        let note = try a.noteStore.create(text: "# Flight\n")
        try await a.publish()                                     // prepared, sent to the gateway's pending list, not sent
        let inflight = try #require(try a.store.inflight(for: a.ref(note.id)))
        #expect(inflight.state == .sending)
        try a.edit(note.id, "# Flight\nwhile in flight\n")
        let raised = try #require(try a.dirtyGeneration(note.id))
        #expect(raised > inflight.generation)
        try await a.gateway.sendPending()
        try a.publisher.consumeResults()
        #expect(try a.dirtyGeneration(note.id) == raised)          // the success covered the old generation only
        #expect(try a.store.pair(for: a.ref(note.id))?.ver == 1)
        await a.gateway.setAutoSend(true)
        try await a.publish()                                     // the next snapshot is built on the pair just stored
        let record = try #require(await world.account.record(named: "e.note.\(note.id)"))
        #expect(record.ver == 2)
        #expect(try Self.text(a.sealer, record, id: note.id) == "# Flight\nwhile in flight\n")
        #expect(try a.dirtyCount() == 0)
    }

    @Test func successNeverClearsANewerDirtyGeneration() async throws {
        let world = try await PublisherWorld.make(1); defer { world.cleanup() }
        let a = world.devices[0]
        await a.gateway.setAutoSend(false)
        let note = try a.noteStore.create(text: "# G\n")
        try await a.publish()
        for n in 1...3 { try a.edit(note.id, "# G\nedit \(n)\n") }
        let newer = try #require(try a.dirtyGeneration(note.id))
        try await a.gateway.sendPending()
        let report = try a.publisher.consumeResults()
        #expect(report.saved == 1)
        #expect(try a.dirtyGeneration(note.id) == newer)
        #expect(try a.store.allInflight().isEmpty)
    }

    @Test func theInflightSnapshotIsImmutableWhileTheNoteIsEdited() async throws {
        let world = try await PublisherWorld.make(1); defer { world.cleanup() }
        let a = world.devices[0]
        let note = try a.noteStore.create(text: "# Frozen\nfirst\n")
        let made = try await a.publisher.prepare()
        #expect(made.count == 1)
        let before = try #require(try a.store.inflight(for: a.ref(note.id)))
        try a.edit(note.id, "# Frozen\nsecond\n")
        try a.edit(note.id, "# Frozen\nthird\n")
        let after = try #require(try a.store.inflight(for: a.ref(note.id)))
        #expect(after == before)                                  // byte for byte, generation included
        #expect(try await a.publisher.prepare().isEmpty)          // no second snapshot while one is in flight
        _ = try await a.publisher.submit()
        let record = try #require(await world.account.record(named: "e.note.\(note.id)"))
        #expect(try Self.text(a.sealer, record, id: note.id) == "# Frozen\nfirst\n")
        try a.publisher.consumeResults()
        #expect(try a.dirtyGeneration(note.id) != nil)            // the later edits are still owed
    }

    @Test func aTombstoneIsASealedRecordWithTheSameShape() async throws {
        let world = try await PublisherWorld.make(1); defer { world.cleanup() }
        let a = world.devices[0]
        let note = try a.noteStore.create(text: "# Gone\nsecret words\n")
        try await a.publish()
        let live = try #require(await world.account.record(named: "e.note.\(note.id)"))
        try a.noteStore.deletePermanently([note.id])
        try await a.publish()
        let gone = try #require(await world.account.record(named: "e.note.\(note.id)"))
        #expect(Set(gone.fields.keys) == Set(live.fields.keys))   // nothing marks it as a deletion
        #expect(gone.ver == 2 && gone.inc == live.inc)
        let sealed = try #require(gone.cipher)
        guard case .deleted = try a.sealer.open(sealed, type: .note, entityID: note.id) else { Issue.record("not a sealed deletion"); return }
        #expect(abs(gone.cipher!.count - live.cipher!.count) < 4_096)
    }

    @Test func aSealedPayloadOver200KiBUsesAnAssetOnTheSameRecord() async throws {
        let world = try await PublisherWorld.make(1); defer { world.cleanup() }
        let a = world.devices[0]
        var generator = SystemRandomNumberGenerator()
        let big = "# Big\n" + (0..<4_000).map { _ in String((0..<80).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789 ".randomElement(using: &generator)! }) + "\n" }.joined()
        #expect(big.utf8.count > 200 * 1024)
        let note = try a.noteStore.create(text: big)
        try await a.publish()
        let record = try #require(await world.account.record(named: "e.note.\(note.id)"))
        #expect(record.cipher == nil && record.cipherAsset != nil)
        #expect(record.name == "e.note.\(note.id)")
        #expect(try Self.text(a.sealer, record, id: note.id) == big)
        #expect(try a.dirtyCount() == 0)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: a.paths.root.appendingPathComponent("CloudSendStaging").path)) ?? []
        #expect(leftovers.isEmpty)                                // the staging copy is removed once the save is recorded
    }

    @Test func aNoteIsSealedForItsOwnEntityOnly() async throws {
        let world = try await PublisherWorld.make(1); defer { world.cleanup() }
        let a = world.devices[0]
        let one = try a.noteStore.create(text: "# One\n")
        let two = try a.noteStore.create(text: "# Two\n")
        try await a.publish()
        let record = try #require(await world.account.record(named: "e.note.\(one.id)"))
        #expect(throws: (any Error).self) { try a.sealer.open(record.cipher!, type: .note, entityID: two.id) }
        #expect(throws: (any Error).self) { try a.sealer.open(record.cipher!, type: .tagPreference, entityID: one.id) }
    }

    // MARK: blobs first (Task 7 seam)

    @Test func blobsAreUploadedBeforeTheEntitySubmitsAndAFailureSendsNothing() async throws {
        let world = try await PublisherWorld.make(1); defer { world.cleanup() }
        let a = world.devices[0]
        let note = try a.noteStore.create(text: "# Scan\n![Receipt](receipt.png)\n")
        let bytes = Data((0..<20_000).map { UInt8($0 % 251) })
        _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: bytes, filename: "receipt.png", to: note.id)
        let account = world.account
        let seenAtBlobTime = LockedBox<[Bool]>([])
        a.blobs.onCall = { _ in
            let names = await account.recordNames
            seenAtBlobTime.update { $0.append(names.contains { $0.hasPrefix("e.attachment.") }) }
        }
        a.blobs.failNext()
        let first = try await a.publish()
        #expect(first.blocked.contains { $0.entityType == "attachment" })
        #expect(await account.recordNames.allSatisfy { !$0.hasPrefix("e.attachment.") })      // nothing sent for it
        #expect(try a.store.allInflight().contains { $0.entity.entityType == "attachment" && $0.state == .prepared })
        let second = try await a.publish()
        #expect(second.saved >= 1)
        let attachment = try #require(await account.recordNames.first { $0.hasPrefix("e.attachment.") })
        let record = try #require(await account.record(named: attachment))
        #expect(record.blobs.count == 1)
        #expect(a.blobs.calls.last == record.blobs)
        #expect(seenAtBlobTime.value.allSatisfy { $0 == false })                          // blobs first, record second
    }

    @Test func entitiesGoOutInTheCloudflareOrderAttachmentsBeforeNotes() async throws {
        let world = try await PublisherWorld.make(1); defer { world.cleanup() }
        let a = world.devices[0]
        let note = try a.noteStore.create(text: "# Scan\n![Receipt](receipt.png)\n")
        _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: Data((0..<2_000).map { UInt8($0 % 251) }), filename: "receipt.png", to: note.id)
        try await a.publish()
        let order = await a.gateway.sendLog.map(\.recordName)
        let attachmentIndex = try #require(order.firstIndex { $0.hasPrefix("e.attachment.") })
        let noteIndex = try #require(order.firstIndex { $0.hasPrefix("e.note.") })
        #expect(attachmentIndex < noteIndex)
    }

    // MARK: key readiness (Task 8 gate, injected)

    @Test func noSaveBeforeKeyCreationComplete() async throws {
        let world = try await PublisherWorld.make(1); defer { world.cleanup() }
        let a = world.devices[0]
        let note = try a.noteStore.create(text: "# Keys\n")
        a.keysReady.update { $0 = false }
        let generation = try #require(try a.dirtyGeneration(note.id))
        for _ in 0..<3 {
            await #expect(throws: CloudPublisherError.keysNotReady) { try await a.publish() }
        }
        #expect(try a.store.allInflight().isEmpty)                                // nothing prepared
        #expect(await a.gateway.sendLog.isEmpty)
        #expect(await a.gateway.pendingAttemptIds.isEmpty)                         // nothing submitted
        #expect(await world.account.recordNames.isEmpty)                           // no Entity or BlobPart in the cloud
        #expect(try a.dirtyGeneration(note.id) == generation)                      // dirty state kept
        // A snapshot prepared before the gate closed is not sent either, and stays prepared.
        a.keysReady.update { $0 = true }
        #expect(try await a.publisher.prepare().count == 1)
        a.keysReady.update { $0 = false }
        await #expect(throws: CloudPublisherError.keysNotReady) { try await a.publisher.submit() }
        #expect(try a.store.inflight(for: a.ref(note.id))?.state == .prepared)
        #expect(await a.gateway.sendLog.isEmpty)
        // Once key creation is complete everything goes out as if nothing had happened.
        a.keysReady.update { $0 = true }
        let report = try await a.publish()
        #expect(report.saved == 1)
        #expect(await world.account.record(named: "e.note.\(note.id)") != nil)
        #expect(try a.dirtyCount() == 0)
    }

    // MARK: gate

    @Test func nothingIsPreparedBeforeSyncIsEnabledOrWhileTheAccountIsFenced() async throws {
        let account = FakeCloudKitAccount()
        let a = try PublisherDevice("gate", account: account, enabled: false); defer { a.cleanup() }
        try await a.prepareGateway()
        let note = try a.noteStore.create(text: "# Gate\n")
        let disabled = try await a.publisher.prepare()
        #expect(disabled.isEmpty)
        try a.setEnabled(true)
        try a.store.setAccountFenced(true)
        let fenced = try await a.publisher.prepare()
        #expect(fenced.isEmpty)
        try a.store.setAccountFenced(false)
        let open = try await a.publisher.prepare()
        #expect(open.count == 1)
        _ = note
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func update(_ change: (inout T) -> Void) { lock.lock(); change(&stored); lock.unlock() }
}
