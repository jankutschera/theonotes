// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

// Shared by CloudKitBlobTransferTests and CloudAttachmentTests: a device with a real `CloudKitBlobTransfer` on the fake cloud,
// blob files built on disk (never held in memory), and a gateway wrapper that counts and interferes.

let blobMiB = 1_048_576

enum BlobFixtures {
    /// Writes `size` pseudo-random bytes (deterministic in `seed`) one MiB at a time and returns their SHA-256.
    @discardableResult
    static func write(size: Int, seed: UInt8, to url: URL) throws -> String {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        var block = Data(count: blobMiB)
        var state = UInt64(seed) &* 0x9E37_79B9_7F4A_7C15 &+ 1
        block.withUnsafeMutableBytes { raw in
            let words = raw.bindMemory(to: UInt64.self)
            for index in words.indices {
                state &+= 0x9E37_79B9_7F4A_7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                words[index] = z ^ (z >> 31)
            }
        }
        var hasher = SHA256()
        var written = 0
        var counter: UInt64 = 0
        while written < size {
            let count = min(block.count, size - written)
            block.withUnsafeMutableBytes { $0.storeBytes(of: counter, as: UInt64.self) }
            let chunk = block.prefix(count)
            try handle.write(contentsOf: chunk)
            hasher.update(data: chunk)
            written += count; counter += 1
        }
        return CloudBlobCache.hex(hasher.finalize())
    }

    static func digest(_ url: URL) throws -> (hash: String, size: Int64) { try CloudBlobCache.digest(of: url, check: {}) }
}

/// Forwards to the fake device, counts deletes (v1 never deletes a blob part) and lets a test act right after an asset fetch.
final class InstrumentedGateway: CloudKitGateway, @unchecked Sendable {
    let inner: FakeCloudKitDevice
    private let lock = NSLock()
    private var _deletes: [[String]] = []
    private var _zoneDeletes = 0
    private var _fetches: [(names: [String], withAssets: Bool)] = []
    private var _log: [String] = []
    var afterAssetFetch: (@Sendable ([String]) async -> Void)?
    /// Runs right before a save reaches the fake (a concurrent writer can act here) and right after it was handed over.
    var beforeSubmit: (@Sendable ([CloudSave]) async -> Void)?
    var afterSubmit: (@Sendable ([CloudSave]) -> Void)?

    init(_ inner: FakeCloudKitDevice) { self.inner = inner }

    var deleteCalls: [[String]] { lock.withLock { _deletes } }
    var zoneDeletes: Int { lock.withLock { _zoneDeletes } }
    var log: [String] { lock.withLock { _log } }
    var assetFetches: [[String]] { lock.withLock { _fetches.filter(\.withAssets).map(\.names) } }
    var metadataFetches: [[String]] { lock.withLock { _fetches.filter { !$0.withAssets }.map(\.names) } }

    func prepare() async throws -> CloudAccountState { try await inner.prepare() }
    func accountState() async -> CloudAccountState { await inner.accountState() }
    func submit(_ saves: [CloudSave]) async throws {
        lock.withLock { _log.append("submit " + saves.map(\.record.name).joined(separator: ",")) }
        if let hook = beforeSubmit { await hook(saves) }
        do { try await inner.submit(saves) } catch { lock.withLock { _log.append("submit threw \(error)") }; throw error }
        afterSubmit?(saves)
    }
    func fetchChanges(into sink: any CloudChangeSink) async throws { try await inner.fetchChanges(into: sink) }
    func fetch(_ names: [String], keys: [String]?) async throws -> [String: CloudRecord] {
        lock.withLock { _fetches.append((names, keys == nil || keys?.contains("asset") == true)) }
        lock.withLock { _log.append("fetch \(keys == nil ? "assets" : "meta") \(names.first ?? "")") }
        let result: [String: CloudRecord]
        do { result = try await inner.fetch(names, keys: keys) } catch { lock.withLock { _log.append("fetch threw \(error)") }; throw error }
        if keys == nil || keys?.contains("asset") == true, let hook = afterAssetFetch { await hook(names) }
        return result
    }
    func delete(_ names: [String]) async throws { lock.withLock { _deletes.append(names) }; try await inner.delete(names) }
    func deleteZone() async throws { lock.withLock { _zoneDeletes += 1 }; try await inner.deleteZone() }
    func deleteZone(expecting userHash: String) async throws { lock.withLock { _zoneDeletes += 1 }; try await inner.deleteZone(expecting: userHash) }
    nonisolated var events: AsyncStream<CloudGatewayEvent> { inner.events }
}

/// One device with a blob transfer. `blobs` are local source files registered in `sync_blob_state` the way the attachment
/// preparer registers its ciphertext.
struct BlobRig {
    let device: PublisherDevice
    let gateway: InstrumentedGateway
    let fence: CloudGenerationFence
    let transfer: CloudKitBlobTransfer
    let diagnostics: CloudBlobDiagnostics
    let keysReady: LockedBox<Bool>
    let clock: LockedBox<Date>

    init(_ device: PublisherDevice, partBytes: Int = blobMiB, crash: CrashPoint = .never, freeBytes: (@Sendable () -> Int64)? = nil,
         timing: CloudBlobTiming = CloudBlobTiming(pollInterval: 0.005, outcomeTimeout: 4, cloudLookupInterval: 0.2),
         start: Date = Date(timeIntervalSince1970: 1_793_188_800)) {
        self.device = device
        gateway = InstrumentedGateway(device.gateway)
        fence = CloudGenerationFence(store: device.store)
        diagnostics = CloudBlobDiagnostics()
        keysReady = LockedBox(true)
        clock = LockedBox(start)
        let ready = keysReady, now = clock
        transfer = CloudKitBlobTransfer(
            database: device.db, paths: device.paths, gateway: gateway, store: device.store, fence: fence,
            keyReadiness: { if !ready.value { throw CloudPublisherError.keysNotReady } },
            partBytes: partBytes, timing: timing, crash: crash, clock: { now.value }, freeBytes: freeBytes, diagnostics: diagnostics)
    }

    /// A transfer on the same library and fake device, as after a restart (new diagnostics).
    func restarted(partBytes: Int = blobMiB, crash: CrashPoint = .never, freeBytes: (@Sendable () -> Int64)? = nil) -> BlobRig {
        BlobRig(device, partBytes: partBytes, crash: crash, freeBytes: freeBytes, start: clock.value)
    }

    @discardableResult
    func addSource(size: Int, seed: UInt8 = 1) throws -> (hash: String, file: URL) {
        let directory = device.paths.root.appendingPathComponent("SyncBlobs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = UUID().uuidString + ".bch"
        let file = directory.appendingPathComponent(name)
        let hash = try BlobFixtures.write(size: size, seed: seed, to: file)
        try device.db.pool.write { db in
            try db.execute(sql: "INSERT INTO sync_blob_state(hash,localPath,byteSize) VALUES(?,?,?)", arguments: [hash, "SyncBlobs/" + name, size])
        }
        return (hash, file)
    }

    /// A row that claims a source of this size without a file behind it (for the refusals that must happen before any work).
    func addPhantomSource(size: Int) throws -> String {
        let hash = CloudBlobCache.hex(SHA256.hash(data: Data("phantom-\(size)".utf8)))
        try device.db.pool.write { db in
            try db.execute(sql: "INSERT INTO sync_blob_state(hash,localPath,byteSize) VALUES(?,?,?)", arguments: [hash, "SyncBlobs/\(UUID().uuidString).bch", size])
        }
        return hash
    }

    func partNames(_ hash: String, size: Int, partBytes: Int = blobMiB) -> [String] {
        let plan = CloudBlobPlan(totalBytes: size, partBytes: partBytes)
        return (0..<plan.parts).map { plan.name(hash: hash, part: $0) }
    }

    func scratchNames() -> [String] { CloudBlobCache(paths: device.paths).scratchNames() }
    func pinnedNames() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: CloudBlobCache(paths: device.paths).downloads.path)) ?? []
    }
    func partRows(_ hash: String) throws -> [CloudBlobPartRow] { try CloudBlobPartStore(database: device.db).rows(hash: hash) }
}

/// Saves hand-made `BlobPart` records through a device, the way another (faulty or newer) client could have left them.
enum CraftedParts {
    /// Splits `source` like the transfer would and saves each part under `hashName` (which may be a lie).
    static func save(on device: PublisherDevice, hashName: String, source: URL, size: Int, partBytes: Int, only: Set<Int>? = nil,
                     shaOverride: String? = nil) async throws {
        let plan = CloudBlobPlan(totalBytes: size, partBytes: partBytes)
        let cache = CloudBlobCache(paths: device.paths)
        try cache.prepareDirectories()
        let shas = try CloudBlobCache.partHashes(of: source, plan: plan, check: {})
        for index in 0..<plan.parts where only?.contains(index) ?? true {
            let slice = cache.newScratch("crafted")
            try CloudBlobCache.writeSlice(of: source, range: plan.range(of: index), to: slice, check: {})
            let header = CloudBlobPartHeader(hash: hashName, part: index, parts: plan.parts, partBytes: plan.partBytes, totalBytes: size,
                                             partSha256: shaOverride ?? shas[index], asset: slice)
            try await device.gateway.submit([CloudSave(attemptId: UUIDv7.make(), accountGeneration: try device.store.generation(),
                                                       record: CloudRecordCodec.encode(header))])
        }
    }
}

func blobEventually(timeout: TimeInterval = 5, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}

/// Entities go on to the test sink; `BlobPart` records are not entities and are fetched by name by the transfer, so a fetch
/// that delivers them (the fake does, G0 item 3) must not store them. Task 6's sink has to do the same.
final class BlobSkippingSink: CloudChangeSink, @unchecked Sendable {
    private let inner: CloudFeedSink
    init(_ inner: CloudFeedSink) { self.inner = inner }
    func commit(changed: [CloudRecord], deletedNames: [String]) throws {
        try inner.commit(changed: changed.filter { $0.type != .blobPart }, deletedNames: deletedNames.filter { !$0.hasPrefix("b.") })
    }
    func saveEngineState(_ state: Data) throws { try inner.saveEngineState(state) }
    func beginFullRefetch() throws { try inner.beginFullRefetch() }
    func endFullRefetch() throws { try inner.endFullRefetch() }
}

extension PublisherDevice {
    /// A fetch that hands over entities only (BlobPart assets are not delivered eagerly: the lazy case of G0 item 3).
    func fetchEntities() async throws {
        await gateway.setDeliversBlobPartAssets(false)
        try await gateway.fetchChanges(into: BlobSkippingSink(sink))
    }
}
