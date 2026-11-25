// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// Runs `body` against a world of fake devices and removes everything the fake cloud wrote to disk (it keeps every blob part as a
/// file in its own temporary folder; the biggest tests would otherwise leave a gigabyte behind).
func withBlobWorld(_ count: Int, _ body: (PublisherWorld) async throws -> Void) async throws {
    let world = try await PublisherWorld.make(count)
    func tidy() async {
        var folders: Set<URL> = []
        for name in await world.account.recordNames {
            guard let record = await world.account.record(named: name) else { continue }
            for case .asset(let url) in record.fields.values { folders.insert(url.deletingLastPathComponent()) }
        }
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        for device in world.devices {
            try? FileManager.default.removeItem(at: device.gateway.stagingDirectory)
            try? FileManager.default.removeItem(at: device.disk.pinDirectory)
        }
        world.cleanup()
    }
    do { try await body(world) } catch { await tidy(); throw error }
    await tidy()
}

@Suite(.serialized) struct CloudKitBlobTransferTests {
    // MARK: round trips and the cap

    @Test func aHundredMiBBlobInFourPartsRoundTripsByteIdentical() async throws {
        try await withBlobWorld(2) { world in
            let a = BlobRig(world.devices[0], partBytes: 33_554_432), b = BlobRig(world.devices[1], partBytes: 33_554_432)
            let size = 100 * blobMiB
            let (hash, _) = try a.addSource(size: size)
            try await a.transfer.ensureUploaded([hash])
            #expect(a.diagnostics.uploadedParts == (0..<4).map { "b.\(hash).32.\($0)" })
            let local = try await b.transfer.download(hash: hash)
            let measured = try BlobFixtures.digest(local)
            #expect(measured.hash == hash && measured.size == Int64(size))
            #expect(local.path.hasSuffix("SyncDownloads/" + hash))
            #expect(b.scratchNames().isEmpty)
            #expect(try a.partRows(hash).count == 4 && a.partRows(hash).allSatisfy { $0.state == .verified && $0.verifiedAt != nil })
        }
    }

    @Test func theLargestBlobTakesEightPartsAndOneByteMoreIsRefusedBeforeAnyWork() async throws {
        try await withBlobWorld(2) { world in
            let a = BlobRig(world.devices[0], partBytes: 33_554_432), b = BlobRig(world.devices[1], partBytes: 33_554_432)
            let cap = SyncWire.maximumBlobBytes
            #expect(cap == 263_192_576)
            let (hash, _) = try a.addSource(size: cap)
            try await a.transfer.ensureUploaded([hash])
            #expect(a.diagnostics.uploadedParts.count == 8)
            let local = try await b.transfer.download(hash: hash)
            let measured = try BlobFixtures.digest(local)
            #expect(measured.hash == hash && measured.size == Int64(cap))
            try? FileManager.default.removeItem(at: local)

            let tooBig = try a.addPhantomSource(size: cap + 1)
            let empty = try a.addPhantomSource(size: 0)
            let before = (a.gateway.metadataFetches.count, await world.devices[0].gateway.sendLog.count)
            await #expect(throws: CloudBlobError.sizeOutOfRange(Int64(cap + 1))) { try await a.transfer.ensureUploaded([tooBig]) }
            await #expect(throws: CloudBlobError.sizeOutOfRange(0)) { try await a.transfer.ensureUploaded([empty]) }
            #expect(a.gateway.metadataFetches.count == before.0)                        // not one cloud call
            #expect(await world.devices[0].gateway.sendLog.count == before.1)
        }
    }

    @Test func aPartSizeThatNeedsMoreThanEightPartsIsRefused() async throws {
        try await withBlobWorld(1) { world in
            let a = BlobRig(world.devices[0], partBytes: blobMiB)
            let hash = try a.addPhantomSource(size: 9 * blobMiB)
            await #expect(throws: CloudBlobError.tooManyParts(9)) { try await a.transfer.ensureUploaded([hash]) }
        }
    }

    // MARK: resuming and trusting what is in the cloud

    @Test func aCrashBetweenPartsResumesWithoutSendingVerifiedPartsAgain() async throws {
        try await withBlobWorld(1) { world in
            let crash = CrashPoint()
            crash.arm("blob.afterPartSaved", afterHits: 1)
            let a1 = BlobRig(world.devices[0], crash: crash)
            let (hash, _) = try a1.addSource(size: 4 * blobMiB)
            let names = a1.partNames(hash, size: 4 * blobMiB)
            await #expect(throws: CrashInjected.self) { try await a1.transfer.ensureUploaded([hash]) }
            let kept = try a1.partRows(hash)
            #expect(kept.count == 2 && kept.allSatisfy { $0.state == .uploaded })       // local part state survived the crash
            #expect(a1.scratchNames().isEmpty)                                         // the slice of the crashed part is gone
            let a2 = a1.restarted()
            try await a2.transfer.ensureUploaded([hash])
            #expect(a2.diagnostics.uploadedParts == Array(names.suffix(2)))
            for name in names { #expect(await world.account.versionCount(of: name) == 1) }
            #expect(try a2.partRows(hash).allSatisfy { $0.state == .verified })
        }
    }

    @Test func aFreshDeviceFindsTheExistingPartsAndUploadsNothing() async throws {
        try await withBlobWorld(2) { world in
            let a = BlobRig(world.devices[0]), b = BlobRig(world.devices[1])
            let (hash, _) = try a.addSource(size: 3 * blobMiB, seed: 9)
            try await a.transfer.ensureUploaded([hash])
            try b.addSource(size: 3 * blobMiB, seed: 9)
            let sent = await world.devices[1].gateway.sendLog.count
            try await b.transfer.ensureUploaded([hash])
            #expect(b.diagnostics.uploadedParts.isEmpty)
            #expect(await world.devices[1].gateway.sendLog.count == sent)
            #expect(try b.partRows(hash).count == 3 && b.partRows(hash).allSatisfy { $0.state == .verified })
        }
    }

    @Test func aStalePartialSetWithWrongPartDigestsIsNotTrustedAndNeverOverwritten() async throws {
        try await withBlobWorld(3) { world in
            let a = BlobRig(world.devices[0]), crafter = world.devices[2]
            let (hash, file) = try a.addSource(size: 4 * blobMiB, seed: 3)
            // another client left part 0 under our name with a digest that is not this blob's
            try await CraftedParts.save(on: crafter, hashName: hash, source: file, size: 4 * blobMiB, partBytes: blobMiB,
                                        only: [0], shaOverride: String(repeating: "ab", count: 32))
            let stale = "b.\(hash).1.0"
            #expect(await world.account.versionCount(of: stale) == 1)
            try await a.transfer.ensureUploaded([hash])
            #expect(a.diagnostics.corruptRemoteParts == [stale])
            #expect(await world.account.versionCount(of: stale) == 1)                   // not overwritten
            #expect(a.diagnostics.uploadedParts == (0..<2).map { "b.\(hash).2.\($0)" })  // stored under another split-size name (2 MiB parts)
            #expect(try a.partRows(hash).allSatisfy { $0.partBytes == 2 * blobMiB && $0.state == .verified })
            // a reader picks the complete split, not the stale one
            let b = BlobRig(world.devices[1])
            let local = try await b.transfer.download(hash: hash)
            #expect(try BlobFixtures.digest(local).hash == hash)
        }
    }

    @Test func whenEverySplitNameHoldsForeignPartsTheUploadReportsCorruptRemotePart() async throws {
        try await withBlobWorld(2) { world in
            let a = BlobRig(world.devices[0]), crafter = world.devices[1]
            let (hash, file) = try a.addSource(size: 2 * blobMiB, seed: 4)
            for mib in 1...4 {
                try await CraftedParts.save(on: crafter, hashName: hash, source: file, size: 2 * blobMiB, partBytes: mib * blobMiB,
                                            only: [0], shaOverride: String(repeating: "cd", count: 32))
            }
            await #expect(throws: CloudBlobError.corruptRemotePart(hash: hash, part: 0)) { try await a.transfer.ensureUploaded([hash]) }
            #expect(a.diagnostics.corruptRemoteParts.count == 4 && a.diagnostics.uploadedParts.isEmpty)
            #expect(a.scratchNames().isEmpty)
        }
    }

    @Test func aVerifiedMarkOlderThanADayIsCheckedAgainAndALostPartIsUploadedFromTheLocalSource() async throws {
        try await withBlobWorld(1) { world in
            let a = BlobRig(world.devices[0])
            let (hash, _) = try a.addSource(size: 3 * blobMiB, seed: 5)
            let names = a.partNames(hash, size: 3 * blobMiB)
            try await a.transfer.ensureUploaded([hash])
            await world.account.removeRecord(names[1])                                  // gone behind the app's back
            let lookups = a.gateway.metadataFetches.count
            a.clock.update { $0 = $0.addingTimeInterval(23 * 3600) }
            try await a.transfer.ensureUploaded([hash])                                 // still trusted: not even a look
            #expect(a.gateway.metadataFetches.count == lookups)
            #expect(await world.account.record(named: names[1]) == nil)
            a.clock.update { $0 = $0.addingTimeInterval(2 * 3600) }                    // now 25 h
            try await a.transfer.ensureUploaded([hash])
            #expect(a.gateway.metadataFetches.count > lookups)
            #expect(await world.account.record(named: names[1]) != nil)
            #expect(a.diagnostics.uploadedParts.suffix(1) == [names[1]])               // only the lost part went again
            let rows = try a.partRows(hash)
            #expect(rows.count == 3 && rows.allSatisfy { $0.state == .verified && $0.verifiedAt == a.clock.value })
        }
    }

    @Test func aMissingPartAfterAnEarlierOneIsNeverCalledVerified() async throws {
        try await withBlobWorld(2) { world in
            let a = BlobRig(world.devices[0]), b = BlobRig(world.devices[1])
            let (hash, _) = try a.addSource(size: 3 * blobMiB, seed: 6)
            let names = a.partNames(hash, size: 3 * blobMiB)
            try await a.transfer.ensureUploaded([hash])
            await world.account.removeRecord(names[1])
            // a device that looks sees the hole and never marks the whole as verified
            try b.addSource(size: 3 * blobMiB, seed: 6)
            await world.account.removeRecord(names[2])
            try await b.transfer.ensureUploaded([hash])
            #expect(b.diagnostics.uploadedParts == [names[1], names[2]])
            #expect(try b.partRows(hash).allSatisfy { $0.state == .verified })
        }
    }

    @Test func identicalCiphertextIsStoredOnceAndNeverSentAgain() async throws {
        try await withBlobWorld(1) { world in
            let a = BlobRig(world.devices[0])
            let (hash, _) = try a.addSource(size: 3 * blobMiB, seed: 7)
            async let first: Void = a.transfer.ensureUploaded([hash, hash])
            async let second: Void = a.transfer.ensureUploaded([hash])
            _ = try await (first, second)
            try await a.transfer.ensureUploaded([hash])
            #expect(a.diagnostics.uploadedParts.count == 3)
            for name in a.partNames(hash, size: 3 * blobMiB) { #expect(await world.account.versionCount(of: name) == 1) }
        }
    }

    @Test func atMostTwoBlobsAreInFlightAtOnce() async throws {
        try await withBlobWorld(1) { world in
            let device = world.devices[0]
            let a = BlobRig(device)
            await device.gateway.setAutoSend(false)
            let hashes = try (1...3).map { try a.addSource(size: 2 * blobMiB, seed: UInt8($0 + 20)).hash }
            let tasks = hashes.map { hash in Task { try await a.transfer.ensureUploaded([hash]) } }
            #expect(await blobEventually { device.disk.pending.count == 2 })
            try await Task.sleep(nanoseconds: 150_000_000)
            #expect(device.disk.pending.count == 2)                                     // the third waits for a slot
            await device.gateway.setAutoSend(true)
            try await device.gateway.sendPending()
            for task in tasks { try await task.value }
            for hash in hashes { #expect(try a.partRows(hash).count == 2) }
        }
    }

    // MARK: failures of the cloud

    @Test func quotaExceededMidBlobKeepsTheStateAndLaterCompletes() async throws {
        try await withBlobWorld(1) { world in
            let a = BlobRig(world.devices[0])
            let (hash, _) = try a.addSource(size: 4 * blobMiB, seed: 8)
            let names = a.partNames(hash, size: 4 * blobMiB)
            await world.account.setQuota(bytes: 2 * blobMiB + blobMiB / 2)
            await #expect(throws: CloudSyncError.quotaExceeded) { try await a.transfer.ensureUploaded([hash]) }
            let kept = try a.partRows(hash)
            #expect(kept.map(\.part) == [0, 1] && kept.allSatisfy { $0.state == .uploaded })
            #expect(a.scratchNames().isEmpty)
            await world.account.setQuota(bytes: nil)
            try await a.transfer.ensureUploaded([hash])
            for name in names { #expect(await world.account.versionCount(of: name) == 1) }
            #expect(try a.partRows(hash).count == 4 && a.partRows(hash).allSatisfy { $0.state == .verified })
        }
    }

    @Test func noPartIsSavedBeforeKeyCreationIsComplete() async throws {
        try await withBlobWorld(1) { world in
            let a = BlobRig(world.devices[0])
            let (hash, _) = try a.addSource(size: 2 * blobMiB, seed: 10)
            a.keysReady.update { $0 = false }
            await #expect(throws: CloudPublisherError.keysNotReady) { try await a.transfer.ensureUploaded([hash]) }
            #expect(await world.devices[0].gateway.sendLog.isEmpty && a.gateway.metadataFetches.isEmpty)
            #expect(await world.account.recordNames.isEmpty)
            a.keysReady.update { $0 = true }
            try await a.transfer.ensureUploaded([hash])
            #expect(await world.account.recordNames.count == 2)
        }
    }

    // MARK: scratch files and the account fence

    @Test func scratchSlicesAreRemovedOnSuccessFailureAndCancel() async throws {
        try await withBlobWorld(1) { world in
            let device = world.devices[0]
            let a = BlobRig(device)
            let (okHash, _) = try a.addSource(size: 2 * blobMiB, seed: 11)
            try await a.transfer.ensureUploaded([okHash])
            #expect(a.scratchNames().isEmpty)                                           // success

            let (failHash, _) = try a.addSource(size: 2 * blobMiB, seed: 12)
            await world.account.setQuota(bytes: 2 * blobMiB + 1000)
            await #expect(throws: CloudSyncError.quotaExceeded) { try await a.transfer.ensureUploaded([failHash]) }
            #expect(a.scratchNames().isEmpty)                                           // failure
            await world.account.setQuota(bytes: nil)

            let (stuckHash, _) = try a.addSource(size: 2 * blobMiB, seed: 13)
            await device.gateway.setAutoSend(false)
            let task = Task { try await a.transfer.ensureUploaded([stuckHash]) }
            #expect(await blobEventually { !a.scratchNames().isEmpty && device.disk.pending.count == 1 })
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(a.scratchNames().isEmpty)                                           // cancel
            await device.gateway.setAutoSend(true)
        }
    }

    @Test func anAccountChangeCancelsATransferDrainsItAndRefusesItsWrites() async throws {
        try await withBlobWorld(1) { world in
            let device = world.devices[0]
            let a = BlobRig(device)
            let (hash, _) = try a.addSource(size: 2 * blobMiB, seed: 14)
            let generation = try device.store.generation()
            await device.gateway.setAutoSend(false)
            let task = Task { try await a.transfer.ensureUploaded([hash]) }
            #expect(await blobEventually { !a.scratchNames().isEmpty })
            try await a.fence.accountChanged()
            // The change cancels the task and closes the fence; whichever the transfer sees first stops it.
            do {
                try await task.value
                Issue.record("the transfer must stop when the account changes")
            } catch is CancellationError {
            } catch CloudSyncError.fenced {
            } catch {
                Issue.record("unexpected error \(error)")
            }
            #expect(a.scratchNames().isEmpty)
            await #expect(throws: CloudSyncError.fenced) { try await a.transfer.ensureUploaded([hash]) }
            await #expect(throws: CloudSyncStoreError.self) {
                try CloudBlobPartStore(database: device.db).upsert(
                    CloudBlobPartRow(hash: hash, part: 0, parts: 2, partBytes: blobMiB, totalBytes: 2 * blobMiB,
                                     partSha256: String(repeating: "0", count: 64), state: .uploaded, verifiedAt: nil), generation: generation)
            }
            #expect(try a.partRows(hash).isEmpty)
        }
    }

    @Test func staleScratchFilesAreSweptAndFreshOnesKept() async throws {
        try await withBlobWorld(1) { world in
            let a = BlobRig(world.devices[0])
            let cache = CloudBlobCache(paths: world.devices[0].paths)
            try cache.prepareDirectories()
            let now = Date()
            for (name, age) in [("slice-old", 2 * 86_400.0), ("dl-\(String(repeating: "a", count: 64)).1.asm", 3 * 86_400.0), ("slice-new", 60.0)] {
                let url = cache.scratch.appendingPathComponent(name)
                try Data("x".utf8).write(to: url)
                try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
            }
            #expect(a.transfer.sweepScratch(now: now) == 2)
            #expect(cache.scratchNames() == ["slice-new"])
        }
    }

    // MARK: downloads

    @Test func aMissingMiddlePartReportsMissingAndFetchesNoAsset() async throws {
        try await withBlobWorld(2) { world in
            let a = BlobRig(world.devices[0]), b = BlobRig(world.devices[1])
            let (hash, _) = try a.addSource(size: 4 * blobMiB, seed: 15)
            try await a.transfer.ensureUploaded([hash])
            await world.account.removeRecord(a.partNames(hash, size: 4 * blobMiB)[2])
            await #expect(throws: CloudBlobError.missingParts(hash: hash, parts: [2])) { try await b.transfer.download(hash: hash) }
            #expect(b.gateway.assetFetches.isEmpty)                                     // metadata first: nothing large moved
            await #expect(throws: CloudBlobError.notInCloud(hash: String(repeating: "e", count: 64))) {
                try await b.transfer.download(hash: String(repeating: "e", count: 64))
            }
        }
    }

    @Test func aFlippedByteFailsThePartDigestAndNothingIsPinned() async throws {
        try await withBlobWorld(2) { world in
            let a = BlobRig(world.devices[0]), b = BlobRig(world.devices[1])
            let (hash, _) = try a.addSource(size: 3 * blobMiB, seed: 16)
            try await a.transfer.ensureUploaded([hash])
            await world.account.corrupt(record: a.partNames(hash, size: 3 * blobMiB)[1], field: "asset")
            await #expect(throws: CloudPolicyError.corruptAttachment) { try await b.transfer.download(hash: hash) }
            #expect(b.pinnedNames().isEmpty && b.scratchNames().isEmpty)               // never partial, no leftovers
            #expect(b.gateway.assetFetches.count == 4)                                  // stops at the bad part (part 1), twice: the retry from the cloud
        }
    }

    @Test func rightPartsButAWrongFinalHashIsRefused() async throws {
        try await withBlobWorld(2) { world in
            let crafter = world.devices[0], b = BlobRig(world.devices[1])
            let source = crafter.paths.root.appendingPathComponent("lie.bin")
            try BlobFixtures.write(size: 3 * blobMiB, seed: 17, to: source)
            let lie = String(repeating: "f", count: 64)
            try await CraftedParts.save(on: crafter, hashName: lie, source: source, size: 3 * blobMiB, partBytes: blobMiB)
            await #expect(throws: CloudPolicyError.corruptAttachment) { try await b.transfer.download(hash: lie) }
            #expect(b.pinnedNames().isEmpty && b.scratchNames().isEmpty)
        }
    }

    @Test func aTotalBeyondTheCapIsRefusedBeforeAnAssetMoves() async throws {
        try await withBlobWorld(2) { world in
            let crafter = world.devices[0], b = BlobRig(world.devices[1], partBytes: 33_554_432)
            let source = crafter.paths.root.appendingPathComponent("small.bin")
            try BlobFixtures.write(size: 1000, seed: 18, to: source)
            let hash = String(repeating: "1", count: 64)
            let header = CloudBlobPartHeader(hash: hash, part: 0, parts: 8, partBytes: 33_554_432, totalBytes: SyncWire.maximumBlobBytes + 1,
                                             partSha256: String(repeating: "2", count: 64), asset: source)
            try await crafter.gateway.submit([CloudSave(attemptId: UUIDv7.make(), accountGeneration: 0, record: CloudRecordCodec.encode(header))])
            await #expect(throws: CloudPolicyError.corruptAttachment) { try await b.transfer.download(hash: hash) }
            #expect(b.gateway.assetFetches.isEmpty)
        }
    }

    @Test func aStagedFileTheSystemRemovedBetweenFetchAndReadIsSurvived() async throws {
        try await withBlobWorld(2) { world in
            let a = BlobRig(world.devices[0]), b = BlobRig(world.devices[1])
            let (hash, _) = try a.addSource(size: 3 * blobMiB, seed: 19)
            let names = a.partNames(hash, size: 3 * blobMiB)
            try await a.transfer.ensureUploaded([hash])
            let fetches = LockedBox(0)
            let device = world.devices[1]
            b.gateway.afterAssetFetch = { _ in
                // the system clears the staging area right after the second fetch (part 1), before the part is read
                let n = fetches.value + 1
                fetches.update { $0 = n }
                if n == 2 { await device.gateway.evictStagedAssets() }
            }
            let local = try await b.transfer.download(hash: hash)
            #expect(try BlobFixtures.digest(local).hash == hash)
            // only the vanished part was fetched again; the finished part 0 was kept, no restart from scratch
            #expect(b.diagnostics.downloadedParts == [names[0], names[1], names[1], names[2]])
        }
    }

    @Test func aStagedFileThatKeepsVanishingFailsWithoutLeavingAnything() async throws {
        try await withBlobWorld(2) { world in
            let a = BlobRig(world.devices[0]), b = BlobRig(world.devices[1])
            let (hash, _) = try a.addSource(size: 2 * blobMiB, seed: 22)
            try await a.transfer.ensureUploaded([hash])
            let device = world.devices[1]
            b.gateway.afterAssetFetch = { _ in await device.gateway.evictStagedAssets() }
            await #expect(throws: CloudSyncError.failed(code: "assetNotAvailable")) { try await b.transfer.download(hash: hash) }
            #expect(b.pinnedNames().isEmpty)
        }
    }

    @Test func anInterruptedDownloadResumesWithTheMissingPartsOnly() async throws {
        try await withBlobWorld(2) { world in
            let a = BlobRig(world.devices[0])
            let (hash, _) = try a.addSource(size: 4 * blobMiB, seed: 23)
            let names = a.partNames(hash, size: 4 * blobMiB)
            try await a.transfer.ensureUploaded([hash])
            let crash = CrashPoint()
            crash.arm("blob.afterDownloadedPart", afterHits: 1)
            let b1 = BlobRig(world.devices[1], crash: crash)
            await #expect(throws: CrashInjected.self) { try await b1.transfer.download(hash: hash) }
            #expect(b1.scratchNames() == ["dl-\(hash).1.asm"])                          // two verified parts kept
            let b2 = b1.restarted()
            let local = try await b2.transfer.download(hash: hash)
            #expect(b2.diagnostics.downloadedParts == Array(names.suffix(2)))
            #expect(try BlobFixtures.digest(local).hash == hash)
            #expect(b2.scratchNames().isEmpty)
        }
    }

    @Test func aDownloadedBlobIsPinnedOnceAndFoundWithoutTheCloud() async throws {
        try await withBlobWorld(2) { world in
            let a = BlobRig(world.devices[0]), b = BlobRig(world.devices[1])
            let (hash, _) = try a.addSource(size: 2 * blobMiB, seed: 24)
            try await a.transfer.ensureUploaded([hash])
            async let one = b.transfer.download(hash: hash)
            async let two = b.transfer.download(hash: hash)
            let urls = try await [one, two]
            #expect(urls[0] == urls[1])
            let fetches = b.gateway.assetFetches.count
            #expect(fetches == 2)                                                       // concurrent callers shared one download
            _ = try await b.transfer.download(hash: hash)
            #expect(b.gateway.assetFetches.count == fetches)                            // cached
            // the sender already holds the ciphertext: no cloud call at all
            let own = try await a.transfer.download(hash: hash)
            #expect(try BlobFixtures.digest(own).hash == hash && a.gateway.assetFetches.isEmpty)
        }
    }

    @Test func aDownloadWithTooLittleFreeSpaceIsRefusedBeforeItStarts() async throws {
        try await withBlobWorld(2) { world in
            let a = BlobRig(world.devices[0])
            let (hash, _) = try a.addSource(size: 3 * blobMiB, seed: 25)
            try await a.transfer.ensureUploaded([hash])
            let tight = BlobRig(world.devices[1], freeBytes: { Int64(5 * blobMiB) })    // needs 2 x 3 MiB
            await #expect(throws: CloudBlobError.insufficientDiskSpace(needed: Int64(6 * blobMiB), available: Int64(5 * blobMiB))) {
                try await tight.transfer.download(hash: hash)
            }
            #expect(tight.gateway.assetFetches.isEmpty && tight.scratchNames().isEmpty)
            let roomy = BlobRig(world.devices[1], freeBytes: { Int64(6 * blobMiB) })
            _ = try await roomy.transfer.download(hash: hash)
        }
    }

    // MARK: v1 never deletes

    @Test func v1NeverDeletesBlobParts() async throws {
        try await withBlobWorld(2) { world in
            let a = BlobRig(world.devices[0]), b = BlobRig(world.devices[1])
            let (hash, _) = try a.addSource(size: 3 * blobMiB, seed: 26)
            let names = a.partNames(hash, size: 3 * blobMiB)
            // every path that touches parts: upload, download, re-check after a day, corruption, missing part, cancel, failure
            try await a.transfer.ensureUploaded([hash])
            _ = try await b.transfer.download(hash: hash)
            a.clock.update { $0 = $0.addingTimeInterval(2 * 86_400) }
            try await a.transfer.ensureUploaded([hash])
            await world.account.corrupt(record: names[0], field: "partSha256")
            a.clock.update { $0 = $0.addingTimeInterval(2 * 86_400) }
            try await a.transfer.ensureUploaded([hash])
            await a.transfer.shutdown()
            for rig in [a, b] {
                #expect(rig.gateway.deleteCalls.isEmpty && rig.gateway.zoneDeletes == 0)
                #expect(await rig.device.gateway.deleteLog.isEmpty)
            }
            #expect(Set(await world.account.recordNames).isSuperset(of: Set(names)))
        }
    }

    // MARK: memory (perf pass only, not part of the normal run)

    @Test(.tags(.perf), PerfGate.onlyInPerfPass)
    func testPerfPeakMemoryGrowthStaysUnder64MBForTheLargestBlob() async throws {
        try await withBlobWorld(2) { world in
            let a = BlobRig(world.devices[0], partBytes: 33_554_432), b = BlobRig(world.devices[1], partBytes: 33_554_432)
            let (hash, _) = try a.addSource(size: SyncWire.maximumBlobBytes, seed: 40)
            let sampler = FootprintSampler()
            try await a.transfer.ensureUploaded([hash])
            let local = try await b.transfer.download(hash: hash)
            let growth = sampler.stop()
            #expect(try BlobFixtures.digest(local).hash == hash)
            #expect(growth < 64 * 1_048_576, "peak footprint grew by \(growth / 1_048_576) MiB")
        }
    }
}

/// Samples the process's physical footprint while a transfer runs and reports the highest growth over the starting value.
final class FootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Int64 = 0
    private var running = true
    private let base: Int64
    private var thread: Thread?

    init() {
        base = Self.footprint()
        peak = base
        let thread = Thread { [self] in
            while lock.withLock({ running }) {
                let now = Self.footprint()
                lock.withLock { peak = max(peak, now) }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        thread.start()
        self.thread = thread
    }

    func stop() -> Int64 {
        lock.withLock { running = false }
        return lock.withLock { peak } - base
    }

    static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }
}
