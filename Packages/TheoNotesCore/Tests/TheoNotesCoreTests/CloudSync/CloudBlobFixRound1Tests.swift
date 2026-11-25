// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// Fix round 1 (Codex review of Task 7): C1, C2, I1 to I5.
@Suite(.serialized) struct CloudBlobFixRound1Tests {
    /// A publisher cycle runs right after a save reached the cloud and before the transfer read its result: the moment the
    /// orphan sweep used to eat BlobPart results (CK-R114).
    static func sweepAfterEverySave(_ rig: BlobRig, _ device: PublisherDevice) {
        rig.gateway.afterSubmit = { _ in _ = try? device.publisher.consumeResults() }
    }

    // MARK: C1

    @Test func anExistingCorruptPinIsReplacedByTheVerifiedAssembly() async throws {
        try await withBlobWorld(2) { world in
            let a = BlobRig(world.devices[0]), b = BlobRig(world.devices[1])
            let (hash, _) = try a.addSource(size: 3 * blobMiB, seed: 50)
            try await a.transfer.ensureUploaded([hash])
            let cache = CloudBlobCache(paths: world.devices[1].paths)
            try cache.prepareDirectories()
            let pin = cache.downloads.appendingPathComponent(hash)
            try Data("junk that is not the blob".utf8).write(to: pin)
            let local = try await b.transfer.download(hash: hash)
            #expect(local == pin)
            #expect(try BlobFixtures.digest(local).hash == hash)                        // the verified bytes won, not the junk
            #expect((try? FileManager.default.contentsOfDirectory(atPath: cache.downloads.path)) == [hash])
            #expect(b.scratchNames().isEmpty)
        }
    }

    // MARK: C2

    @Test func twoSeparatelyBuiltTransfersDownloadingTheSameHashWriteOneAssembly() async throws {
        try await withBlobWorld(2) { world in
            let a = BlobRig(world.devices[0])
            let (hash, _) = try a.addSource(size: 3 * blobMiB, seed: 51)
            try await a.transfer.ensureUploaded([hash])
            let b1 = BlobRig(world.devices[1]), b2 = b1.restarted()
            b1.gateway.afterAssetFetch = { _ in try? await Task.sleep(nanoseconds: 80_000_000) }   // keep the two overlapping
            async let first = b1.transfer.download(hash: hash)
            async let second = b2.transfer.download(hash: hash)
            let urls = try await [first, second]
            #expect(urls[0] == urls[1])
            #expect(try BlobFixtures.digest(urls[0]).hash == hash)
            #expect(b1.gateway.assetFetches.count + b2.gateway.assetFetches.count == 3)  // one download between them
            #expect(b1.scratchNames().isEmpty)
        }
    }

    // MARK: I1

    @Test func blobPartResultsSurviveThePublishersOrphanSweepButOldOnesAreDropped() async throws {
        try await withBlobWorld(1) { world in
            let device = world.devices[0]
            let now = Date(timeIntervalSince1970: 1_793_188_800)
            let store = CloudSyncStore(database: device.db, clock: { now })
            let generation = try store.generation()
            try store.recordSendResult(attemptId: CloudSyncStore.blobAttemptPrefix + "mine", accountGeneration: generation, outcome: .quotaExceeded)
            try store.recordSendResult(attemptId: "someone-elses-orphan", accountGeneration: generation, outcome: .quotaExceeded)
            try store.deleteOrphanSendResults()
            #expect(try store.sendResult(attemptId: CloudSyncStore.blobAttemptPrefix + "mine") != nil)
            #expect(try store.sendResult(attemptId: "someone-elses-orphan") == nil)
            let later = CloudSyncStore(database: device.db, clock: { now.addingTimeInterval(25 * 3600) })
            try later.deleteOrphanSendResults()                                         // a transfer that died is cleaned up after a day
            #expect(try store.sendResult(attemptId: CloudSyncStore.blobAttemptPrefix + "mine") == nil)
        }
    }

    @Test func aQuotaResultIsReportedAsQuotaWhileThePublisherKeepsSweeping() async throws {
        try await withBlobWorld(1) { world in
            let device = world.devices[0]
            let a = BlobRig(device, timing: CloudBlobTiming(pollInterval: 0.02, outcomeTimeout: 4, cloudLookupInterval: 60))
            let (hash, _) = try a.addSource(size: 2 * blobMiB, seed: 52)
            await world.account.setQuota(bytes: blobMiB / 2)
            Self.sweepAfterEverySave(a, device)
            await #expect(throws: CloudSyncError.quotaExceeded) { try await a.transfer.ensureUploaded([hash]) }
        }
    }

    @Test func aConflictResultIsHandledWhileThePublisherKeepsSweeping() async throws {
        try await withBlobWorld(2) { world in
            let device = world.devices[0], crafter = world.devices[1]
            let a = BlobRig(device, timing: CloudBlobTiming(pollInterval: 0.02, outcomeTimeout: 4, cloudLookupInterval: 60))
            let (hash, file) = try a.addSource(size: 2 * blobMiB, seed: 53)
            let raced = LockedBox(false)
            a.gateway.beforeSubmit = { saves in
                guard saves[0].record.name == "b.\(hash).1.0", !raced.value else { return }
                raced.update { $0 = true }
                try? await CraftedParts.save(on: crafter, hashName: hash, source: file, size: 2 * blobMiB, partBytes: blobMiB,
                                             only: [0], shaOverride: String(repeating: "ab", count: 32))
            }
            Self.sweepAfterEverySave(a, device)
            try await a.transfer.ensureUploaded([hash])
            #expect(a.diagnostics.corruptRemoteParts == ["b.\(hash).1.0"])
            #expect(await world.account.versionCount(of: "b.\(hash).1.0") == 1)         // the foreign part was not overwritten
            #expect(try a.partRows(hash).allSatisfy { $0.partBytes == 2 * blobMiB && $0.state == .verified })
        }
    }

    // MARK: I2

    @Test func keyReadinessGoingFalseBetweenPartsStopsTheNextSave() async throws {
        try await withBlobWorld(1) { world in
            let a = BlobRig(world.devices[0])
            let (hash, _) = try a.addSource(size: 3 * blobMiB, seed: 54)
            let names = a.partNames(hash, size: 3 * blobMiB)
            let ready = a.keysReady
            a.gateway.afterSubmit = { saves in if saves[0].record.name == names[0] { ready.update { $0 = false } } }
            await #expect(throws: CloudPublisherError.keysNotReady) { try await a.transfer.ensureUploaded([hash]) }
            #expect(await world.account.versionCount(of: names[0]) == 1)
            #expect(await world.account.versionCount(of: names[1]) == 0)                // the next part was not saved
            #expect(a.scratchNames().isEmpty)
        }
    }

    @Test func aDurableAccountFenceBetweenPartsStopsTheNextSave() async throws {
        try await withBlobWorld(1) { world in
            let device = world.devices[0]
            let a = BlobRig(device)
            let (hash, _) = try a.addSource(size: 3 * blobMiB, seed: 55)
            let names = a.partNames(hash, size: 3 * blobMiB)
            let store = device.store
            a.gateway.afterSubmit = { saves in if saves[0].record.name == names[0] { try? store.setAccountFenced(true) } }
            await #expect(throws: (any Error).self) { try await a.transfer.ensureUploaded([hash]) }
            #expect(await world.account.versionCount(of: names[1]) == 0)
        }
    }

    // MARK: I3

    @Test func aCachedFileOverTheCapIsRefusedBeforeItIsHashedOrReturned() async throws {
        try await withBlobWorld(1) { world in
            let device = world.devices[0]
            let b = BlobRig(device)
            let directory = device.paths.root.appendingPathComponent("SyncBlobs", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = UUID().uuidString + ".bch"
            let size = SyncWire.maximumBlobBytes + 1
            FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: nil)
            let handle = try FileHandle(forWritingTo: directory.appendingPathComponent(name))
            try handle.truncate(atOffset: UInt64(size)); try handle.close()             // sparse: no bytes are written
            let hash = String(repeating: "9", count: 64)
            try await device.db.pool.write { db in
                try db.execute(sql: "INSERT INTO sync_blob_state(hash,localPath,byteSize) VALUES(?,?,?)", arguments: [hash, "SyncBlobs/" + name, size])
            }
            await #expect(throws: CloudBlobError.sizeOutOfRange(Int64(size))) { try await b.transfer.download(hash: hash) }
            #expect(b.gateway.metadataFetches.isEmpty)
        }
    }

    // MARK: I4

    @Test func anErrorMidDownloadLeavesNoAssemblyBehind() async throws {
        try await withBlobWorld(2) { world in
            let a = BlobRig(world.devices[0]), b = BlobRig(world.devices[1])
            let (hash, _) = try a.addSource(size: 4 * blobMiB, seed: 56)
            let names = a.partNames(hash, size: 4 * blobMiB)
            try await a.transfer.ensureUploaded([hash])
            let account = world.account
            let seen = LockedBox(0)
            b.gateway.afterAssetFetch = { _ in
                let n = seen.value + 1
                seen.update { $0 = n }
                if n == 2 { await account.removeRecord(names[2]) }                      // part 2 disappears while part 1 is being read
            }
            await #expect(throws: CloudBlobError.missingParts(hash: hash, parts: [2])) { try await b.transfer.download(hash: hash) }
            #expect(b.scratchNames().isEmpty)
        }
    }

    @Test func aCancelledDownloadLeavesNoAssemblyBehind() async throws {
        try await withBlobWorld(2) { world in
            let a = BlobRig(world.devices[0]), b = BlobRig(world.devices[1])
            let (hash, _) = try a.addSource(size: 4 * blobMiB, seed: 57)
            try await a.transfer.ensureUploaded([hash])
            let transfer = b.transfer
            let task = LockedBox<Task<URL, any Error>?>(nil)
            let seen = LockedBox(0)
            b.gateway.afterAssetFetch = { _ in
                let n = seen.value + 1
                seen.update { $0 = n }
                if n == 2 { task.value?.cancel() }                                      // part 0 is already in the assembly
            }
            let running = Task { try await transfer.download(hash: hash) }
            task.update { $0 = running }
            await #expect(throws: CancellationError.self) { try await running.value }
            #expect(b.scratchNames().isEmpty)
        }
    }

    // MARK: I5

    @Test func aConcurrentCreateOfTheSamePartNameGetsServerRecordChangedAndAMismatchIsNeverOverwritten() async throws {
        try await withBlobWorld(2) { world in
            let a = BlobRig(world.devices[0]), crafter = world.devices[1]
            let (hash, file) = try a.addSource(size: 2 * blobMiB, seed: 58)
            let raced = LockedBox(false)
            a.gateway.beforeSubmit = { saves in
                guard saves[0].record.name == "b.\(hash).1.1", !raced.value else { return }
                raced.update { $0 = true }
                try? await CraftedParts.save(on: crafter, hashName: hash, source: file, size: 2 * blobMiB, partBytes: blobMiB,
                                             only: [1], shaOverride: String(repeating: "cd", count: 32))
            }
            try await a.transfer.ensureUploaded([hash])
            #expect(a.diagnostics.corruptRemoteParts == ["b.\(hash).1.1"])
            #expect(await world.account.versionCount(of: "b.\(hash).1.1") == 1)         // create-only: nothing was overwritten
            #expect(a.diagnostics.uploadedParts.contains("b.\(hash).2.0"))              // stored under the next split name instead
            let b = BlobRig(world.devices[1])
            let local = try await b.transfer.download(hash: hash)
            #expect(try BlobFixtures.digest(local).hash == hash)
        }
    }

    @Test func aConcurrentCreateOfTheIdenticalPartIsAcceptedAfterReadingItsMetadata() async throws {
        try await withBlobWorld(2) { world in
            let a = BlobRig(world.devices[0]), other = world.devices[1]
            let (hash, file) = try a.addSource(size: 2 * blobMiB, seed: 59)
            let raced = LockedBox(false)
            a.gateway.beforeSubmit = { saves in
                guard saves[0].record.name == "b.\(hash).1.0", !raced.value else { return }
                raced.update { $0 = true }
                try? await CraftedParts.save(on: other, hashName: hash, source: file, size: 2 * blobMiB, partBytes: blobMiB, only: [0])
            }
            try await a.transfer.ensureUploaded([hash])
            #expect(a.diagnostics.corruptRemoteParts.isEmpty)
            #expect(await world.account.versionCount(of: "b.\(hash).1.0") == 1)
            #expect(try a.partRows(hash).count == 2 && a.partRows(hash).allSatisfy { $0.state == .verified && $0.partBytes == blobMiB })
            #expect(a.gateway.metadataFetches.count >= 3)                               // the conflict was settled by reading the metadata
        }
    }
}
