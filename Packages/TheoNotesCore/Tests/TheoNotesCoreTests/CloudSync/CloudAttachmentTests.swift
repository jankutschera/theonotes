// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

extension PublisherDevice {
    /// The publisher of this device uses the real blob transfer instead of the recording double.
    func publishThrough(_ rig: BlobRig) {
        publisher = CloudPublisher(database: db, paths: paths, store: store, gateway: rig.gateway, accountID: accountID, vaultKey: key,
                                   blobs: rig.transfer, intake: intake, keyReadiness: Self.gate(keysReady))
    }

    func attachmentID(of noteID: String) throws -> String {
        try #require(try db.pool.read { try String.fetchOne($0, sql: "SELECT id FROM attachment WHERE noteId=? ORDER BY createdAt LIMIT 1", arguments: [noteID]) })
    }

    func attachmentPayload(_ id: String, in account: FakeCloudKitAccount) async throws -> (payload: SyncAttachmentPayload?, record: CloudRecord) {
        let record = try #require(await account.record(named: "e.attachment.\(id)"))
        let opened = try sealer.open(try #require(record.cipher), type: .attachment, entityID: id)
        guard case .live(let body) = opened else { return (nil, record) }
        return (try SyncPayloadCodec.decode(SyncAttachmentPayload.self, from: body), record)
    }
}

private func sampleBytes(_ count: Int, marker: String = "") -> Data {
    var data = Data((0..<count).map { UInt8(($0 &* 31 &+ ($0 >> 8)) % 251) })
    data.replaceSubrange(0..<marker.utf8.count, with: Data(marker.utf8))
    return data
}

extension PublisherDevice {
    /// The real receiver, with attachment ciphertext coming from this rig's `CloudKitBlobTransfer.download(hash:)` (a verified local
    /// file; a part that is missing makes the note and the attachment wait for it).
    func receiver(_ rig: BlobRig) -> CloudReconciler {
        CloudReconciler(database: db, paths: paths, store: store, accountID: accountID, vaultKey: key, pinner: CloudAssetPinner(directory: paths.cloudPinned),
                        blobs: rig.transfer, crash: crash, noteAccess: { nil })
    }

    func attachmentRemotes() throws -> [CloudRemoteVersion] { try store.allRemote().filter { $0.entity.entityType == "attachment" } }

    func installed(noteID: String, filename: String) -> URL {
        paths.attachments.appendingPathComponent(noteID, isDirectory: true).appendingPathComponent(filename)
    }

    func installedFiles() -> [String] {
        let enumerator = FileManager.default.enumerator(at: paths.attachments, includingPropertiesForKeys: [.isRegularFileKey])
        var found: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { found.append(url.lastPathComponent) }
        }
        return found.sorted()
    }
}

@Suite(.serialized) struct CloudAttachmentTests {
    // MARK: publishing

    @Test func anAttachmentEntityWaitsForItsBlobsAndTheBlobsGoFirst() async throws {
        try await withBlobWorld(1) { world in
            let a = world.devices[0]
            let rig = BlobRig(a)
            a.publishThrough(rig)
            let note = try a.noteStore.create(text: "# Scan\n![Receipt](receipt.png)\n")
            _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: sampleBytes(3 * blobMiB + 5), filename: "receipt.png", to: note.id)

            // the cloud is unreachable at the first look. The note names the same blob as its attachment (its recovery pins), so
            // it waits for it too: nothing is sent for either, their snapshots stay prepared
            await a.gateway.failNext(.offline)
            await a.gateway.failNext(.offline)
            let first = try await a.publish()
            #expect(first.blocked.contains { $0.entityType == "attachment" } && first.blocked.contains { $0.entityType == "note" })
            #expect(await world.account.recordNames.allSatisfy { !$0.hasPrefix("e.") })
            #expect(try a.store.allInflight().contains { $0.entity.entityType == "attachment" && $0.state == .prepared })

            // quota runs out between two parts: parts stay, the entity still waits
            await world.account.setQuota(bytes: 2 * blobMiB + blobMiB / 2)
            let second = try await a.publish()
            #expect(second.blocked.contains { $0.entityType == "attachment" })
            #expect(await world.account.recordNames.filter { $0.hasPrefix("b.") }.count == 2)
            #expect(await world.account.recordNames.allSatisfy { !$0.hasPrefix("e.") })

            await world.account.setQuota(bytes: nil)
            let third = try await a.publish()
            #expect(third.saved >= 1)
            let id = try a.attachmentID(of: note.id)
            let (payload, record) = try await a.attachmentPayload(id, in: world.account)
            let live = try #require(payload)
            #expect(record.blobs == [live.blobHash])
            let partPrefix = "b.\(live.blobHash)."
            let allNames = await world.account.recordNames
            var parts: [String] = []
            for name in allNames where name.hasPrefix(partPrefix) { parts.append(name) }
            #expect(parts.count == 4)                                                    // 3 MiB + overhead in 1 MiB parts
            let order = await a.gateway.sendLog.map(\.recordName)
            let lastPart = try #require(order.lastIndex { $0.hasPrefix("b.") })
            let entity = try #require(order.firstIndex { $0.hasPrefix("e.") })
            #expect(lastPart < entity)                                                   // every part before any entity that names it
        }
    }

    @Test func aLockedNotesAttachmentKeepsItsOpaqueNameAndItsInnerCiphertext() async throws {
        try await withBlobWorld(2) { world in
            let a = world.devices[0], b = world.devices[1]
            let rigA = BlobRig(a), rigB = BlobRig(b)
            a.publishThrough(rigA)
            let marker = "TOP-SECRET-PHOTO-BYTES"
            let note = try a.noteStore.create(text: "# Private\n![Photo](photo.png)\n")
            _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: sampleBytes(2 * blobMiB, marker: marker), filename: "photo.png", to: note.id)
            let access = try NotePrivacy(store: a.noteStore).setPassword("correct horse")
            try access.lock(noteId: note.id)
            try await a.publish()

            let id = try a.attachmentID(of: note.id)
            let (payload, record) = try await a.attachmentPayload(id, in: world.account)
            let live = try #require(payload)
            #expect(live.isLocked && live.filename == id + ".bch")                      // the opaque name, never photo.png
            #expect(live.uti == nil && live.width == nil && live.height == nil && live.ocrText == nil)
            let wire = String(decoding: try #require(record.cipher), as: UTF8.self)
            #expect(!wire.contains("photo.png"))

            // what sits in the cloud is the outer encryption of the file as it is on disk: the inner (note-key) ciphertext
            let innerFile = a.paths.attachments.appendingPathComponent(note.id).appendingPathComponent(id + ".bch")
            let inner = try Data(contentsOf: innerFile)
            #expect(inner.range(of: Data(marker.utf8)) == nil)                           // the file on disk is already ciphertext
            let downloaded = try await rigB.transfer.download(hash: live.blobHash)
            #expect(try Data(contentsOf: downloaded).range(of: Data(marker.utf8)) == nil)
            let plain = b.paths.root.appendingPathComponent("outer-plain")
            try ChunkedCipher.decrypt(input: downloaded, output: plain, keyEncryptionKey: b.key,
                                      context: try SyncWire.cipherContext(accountID: b.accountID, type: .attachment, entityID: id))
            #expect(try Data(contentsOf: plain) == inner)                               // inner ciphertext carried unchanged
            for name in await world.account.recordNames where name.hasPrefix("b.") {
                let part = try #require(await world.account.record(named: name))
                guard case .asset(let url)? = part.fields["asset"] else { Issue.record("no asset"); continue }
                #expect(try Data(contentsOf: url).range(of: Data(marker.utf8)) == nil)
            }
        }
    }

    // MARK: receiver scenarios (the real applier; the blob comes from CloudKitBlobTransfer.download(hash:))

    @Test func receiverAnAttachmentThatArrivesBeforeItsNoteWaitsAndThenInstallsByteIdentical() async throws {
        try await withBlobWorld(2) { world in
            let a = world.devices[0], b = world.devices[1]
            let rigA = BlobRig(a), rigB = BlobRig(b)
            a.publishThrough(rigA)
            let bytes = sampleBytes(3 * blobMiB + 17)
            let note = try a.noteStore.create(text: "# Scan\n![Receipt](receipt.png)\n")
            _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: bytes, filename: "receipt.png", to: note.id)
            try await a.publish()
            let attachmentID = try a.attachmentID(of: note.id)

            try await b.fetchEntities()
            let noteRecord = try #require(await world.account.record(named: "e.note.\(note.id)"))
            let held = try #require(try b.store.remote(recordName: "e.note.\(note.id)"))
            _ = try b.store.deleteRemote(held, accountGeneration: try b.store.generation())   // the note has not arrived yet
            let receiver = b.receiver(rigB)
            let first = try await receiver.applyPending()
            #expect(first.waitingForDependency.map(\.entityType) == ["attachment"])      // no note to attach it to
            #expect(b.installedFiles().isEmpty && rigB.gateway.assetFetches.isEmpty)      // nothing downloaded, nothing partial
            #expect(!first.applied.contains { $0.entityType == "attachment" && $0.entityId == attachmentID })
            #expect(try b.store.remote(recordName: "e.attachment.\(attachmentID)") != nil) // not acknowledged early
            #expect(try b.noteStore.allNotes().isEmpty) // no speculative recovery for a first delivery

            _ = try b.sink.intake(noteRecord, delivery: .incremental)
            let second = try await receiver.applyPending()
            #expect(second.applied.contains { $0.entityType == "note" })
            #expect(try Data(contentsOf: b.installed(noteID: note.id, filename: "receipt.png")) == bytes)
            #expect(rigB.scratchNames().isEmpty)
            #expect(try b.rowCount("ck_remote") == 0)
        }
    }

    @Test func receiverAnAttachmentWithMissingBlobPartsIsNeverAppliedPartiallyAndAppliesOnceTheyArrive() async throws {
        try await withBlobWorld(2) { world in
            let a = world.devices[0], b = world.devices[1]
            let rigA = BlobRig(a), rigB = BlobRig(b)
            a.publishThrough(rigA)
            let bytes = sampleBytes(3 * blobMiB + 17)
            let note = try a.noteStore.create(text: "# Scan\n![Receipt](receipt.png)\n")
            _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: bytes, filename: "receipt.png", to: note.id)
            try await a.publish()
            let id = try a.attachmentID(of: note.id)
            let live = try #require(try await a.attachmentPayload(id, in: world.account).payload)
            let lost = "b.\(live.blobHash).1.2"
            await world.account.removeRecord(lost)                                      // the iCloud copy lost a part

            try await b.fetchEntities()
            let receiver = b.receiver(rigB)
            let first = try await receiver.applyPending()
            #expect(try b.note(note.id) == nil, "the note waits for its file")
            #expect(first.waitingForDependency.contains { $0.entityType == "note" || $0.entityType == "attachment" })
            #expect(b.installedFiles().isEmpty && rigB.gateway.assetFetches.isEmpty && rigB.pinnedNames().isEmpty)

            rigA.clock.update { $0 = $0.addingTimeInterval(25 * 3600) }                  // the sender re-checks and heals the hole
            try await rigA.transfer.ensureUploaded([live.blobHash])
            _ = try await receiver.applyPending()
            #expect(try Data(contentsOf: b.installed(noteID: note.id, filename: "receipt.png")) == bytes)
            #expect(try b.rowCount("ck_remote") == 0)
        }
    }

    @Test func receiverALockedNotesAttachmentInstallsItsInnerCiphertextUnderTheOpaqueName() async throws {
        try await withBlobWorld(2) { world in
            let a = world.devices[0], b = world.devices[1]
            let rigA = BlobRig(a), rigB = BlobRig(b)
            a.publishThrough(rigA)
            let note = try a.noteStore.create(text: "# Private\n![Photo](photo.png)\n")
            _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: sampleBytes(2 * blobMiB, marker: "SECRET-BYTES"), filename: "photo.png", to: note.id)
            let access = try NotePrivacy(store: a.noteStore).setPassword("correct horse")
            try access.lock(noteId: note.id)
            try await a.publish()
            let id = try a.attachmentID(of: note.id)

            try await b.fetchEntities()
            _ = try await b.receiver(rigB).applyPending()                                // no password needed for a first contact
            let inner = try Data(contentsOf: a.paths.attachments.appendingPathComponent(note.id).appendingPathComponent(id + ".bch"))
            #expect(try Data(contentsOf: b.installed(noteID: note.id, filename: id + ".bch")) == inner)
            #expect(b.installedFiles() == [id + ".bch"])
            #expect(try b.note(note.id)?.isLocked == true)
        }
    }

    // MARK: tombstones

    @Test func anAttachmentTombstoneNamesNoBlobDeletesNoPartAndTheReceiverRemovesTheFileWithoutDownloading() async throws {
        try await withBlobWorld(2) { world in
            let a = world.devices[0], b = world.devices[1]
            let rigA = BlobRig(a), rigB = BlobRig(b)
            a.publishThrough(rigA)
            let bytes = sampleBytes(2 * blobMiB + 1)
            let note = try a.noteStore.create(text: "# Scan\n![Receipt](receipt.png)\n")
            _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: bytes, filename: "receipt.png", to: note.id)
            try await a.publish()
            let id = try a.attachmentID(of: note.id)
            let live = try #require(try await a.attachmentPayload(id, in: world.account).payload)
            let partsBefore = await world.account.recordNames.filter { $0.hasPrefix("b.") }
            let uploadedBefore = rigA.diagnostics.uploadedParts.count

            // B installs the live attachment
            try await b.fetchEntities()
            let receiver = b.receiver(rigB)
            _ = try await receiver.applyPending()
            #expect(try Data(contentsOf: b.installed(noteID: note.id, filename: "receipt.png")) == bytes)
            let liveVersion = try #require(try b.store.pair(for: b.ref(id, type: "attachment"))?.ver)
            let fetchesBefore = rigB.gateway.assetFetches.count

            // A removes it: the note no longer references it and the grace period has passed
            try a.edit(note.id, "# Scan\nNo picture any more.\n")
            let removed = a.noteStore.removeUnreferencedAttachments(noteId: note.id, now: .now.addingTimeInterval(NoteStore.attachmentGracePeriod + 60))
            #expect(removed == ["receipt.png"])
            try await a.publish()

            let (payload, record) = try await a.attachmentPayload(id, in: world.account)
            #expect(payload == nil)                                                      // a tombstone
            #expect(record.blobs.isEmpty)                                                // names no blob
            #expect(await world.account.recordNames.filter { $0.hasPrefix("b.") } == partsBefore)   // parts stay (CK-R8)
            #expect(rigA.diagnostics.uploadedParts.count == uploadedBefore)             // no blob work for a tombstone
            #expect(rigA.gateway.deleteCalls.isEmpty && rigA.gateway.zoneDeletes == 0)

            try await b.fetchEntities()
            let tombstone = try #require(try b.attachmentRemotes().first)
            #expect(tombstone.ver > liveVersion)
            _ = try await receiver.applyPending()
            #expect(try b.int("SELECT COUNT(*) FROM attachment WHERE id=? AND deletedAt IS NOT NULL", [id]) == 1, "the receiver marks the attachment removed")
            #expect(rigB.gateway.assetFetches.count == fetchesBefore)                    // nothing downloaded for a tombstone
            _ = live
        }
    }
}
