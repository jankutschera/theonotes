// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB

// Local side of the CloudKit blob transfer (Task 7): the split plan, the durable part state (`ck_blob_part`), the scratch area and
// the verify-and-pin helper. `SyncBlobTransfer` (Cloudflare) is not touched; this file reuses only `SyncBlobLocation` and
// `SyncAttachmentPreparer.hashFile` from the existing sync code.

/// How one blob ciphertext is cut into `BlobPart` records. At most 8 parts; a part's size is a multiple of 1 MiB because the
/// record name carries it in MiB (`b.<hash>.<MiB>.<part>`).
struct CloudBlobPlan: Equatable, Sendable {
    static let alternativeSplits = 3

    let totalBytes: Int
    let partBytes: Int

    var parts: Int { (totalBytes + partBytes - 1) / partBytes }

    func range(of part: Int) -> (offset: Int, length: Int) {
        let offset = part * partBytes
        return (offset, min(partBytes, totalBytes - offset))
    }

    func name(hash: String, part: Int) -> String { CloudRecordCodec.blobPartRecordName(hash: hash, partBytes: partBytes, part: part) }

    /// The split sizes a blob may be stored under, in order of preference: the configured size, then three larger ones a MiB apart.
    /// A part that exists under a name with wrong metadata is never overwritten in v1; the next split is a different name.
    static func candidates(totalBytes: Int, partBytes: Int) -> [CloudBlobPlan] {
        (0...alternativeSplits).map { CloudBlobPlan(totalBytes: totalBytes, partBytes: partBytes + $0 * CloudRecordCodec.partUnitBytes) }
            .filter { $0.parts <= CloudRecordCodec.maxBlobParts }
    }
}

/// One row of `ck_blob_part`: what this device knows about a part in the cloud. `uploaded`: our save of it was acknowledged,
/// not yet confirmed by a metadata read. `verified`: the cloud showed exactly this metadata at `verifiedAt` (trusted for 24 h, CK-R8).
struct CloudBlobPartRow: Equatable, Sendable {
    enum State: String, Sendable { case uploaded, verified }
    var hash: String
    var part: Int
    var parts: Int
    var partBytes: Int
    var totalBytes: Int
    var partSha256: String
    var state: State
    var verifiedAt: Date?
}

/// Every write re-checks the account generation inside its own transaction (CK-R98): a transfer that outlives an account change
/// writes nothing.
struct CloudBlobPartStore: Sendable {
    let database: AppDatabase

    func rows(hash: String) throws -> [CloudBlobPartRow] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM ck_blob_part WHERE hash=? ORDER BY part", arguments: [hash]).map(Self.row)
        }
    }

    /// Writes one part. Rows of this hash that belong to another split are removed first (the key is `(hash, part)`).
    func upsert(_ row: CloudBlobPartRow, generation: Int64) throws {
        try database.pool.write { db in
            try CloudSyncStore.requireOpen(db, generation)
            try Self.upsert(row, in: db)
        }
    }

    /// Replaces every row of `hash` with `rows` in one transaction.
    func replace(hash: String, with rows: [CloudBlobPartRow], generation: Int64) throws {
        try database.pool.write { db in
            try CloudSyncStore.requireOpen(db, generation)
            try db.execute(sql: "DELETE FROM ck_blob_part WHERE hash=?", arguments: [hash])
            for row in rows { try Self.upsert(row, in: db) }
        }
    }

    func drop(hash: String, generation: Int64) throws {
        try database.pool.write { db in
            try CloudSyncStore.requireOpen(db, generation)
            try db.execute(sql: "DELETE FROM ck_blob_part WHERE hash=?", arguments: [hash])
        }
    }

    private static func upsert(_ row: CloudBlobPartRow, in db: Database) throws {
        try db.execute(sql: "DELETE FROM ck_blob_part WHERE hash=? AND partBytes<>?", arguments: [row.hash, row.partBytes])
        try db.execute(sql: """
            INSERT OR REPLACE INTO ck_blob_part(hash,part,parts,partBytes,totalBytes,partSha256,state,verifiedAt) VALUES(?,?,?,?,?,?,?,?)
            """, arguments: [row.hash, row.part, row.parts, row.partBytes, row.totalBytes, row.partSha256, row.state.rawValue, row.verifiedAt])
    }

    private static func row(_ row: Row) -> CloudBlobPartRow {
        CloudBlobPartRow(hash: row["hash"], part: row["part"], parts: row["parts"], partBytes: row["partBytes"], totalBytes: row["totalBytes"],
                         partSha256: row["partSha256"], state: CloudBlobPartRow.State(rawValue: row["state"]) ?? .uploaded,
                         verifiedAt: row["verifiedAt"])
    }
}

/// The scratch area and the pinned cache of one library. Scratch lives in the no-backup folder `CloudBlobs`; verified blobs are
/// pinned where the existing materializer already looks (`SyncDownloads/<hash>`), so the receiver needs no new path logic.
struct CloudBlobCache: Sendable {
    /// The buffer every copy loop uses; memory stays bounded by it, not by the blob.
    static let bufferBytes = 1_048_576
    static let staleAfter: TimeInterval = 24 * 3600

    let paths: AppPaths

    var scratch: URL { paths.root.appendingPathComponent("CloudBlobs", isDirectory: true) }
    var downloads: URL { paths.root.appendingPathComponent("SyncDownloads", isDirectory: true) }

    func prepareDirectories() throws {
        for var directory in [scratch, downloads] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
        }
    }

    /// A scratch file with a random name.
    func newScratch(_ kind: String) -> URL { scratch.appendingPathComponent("\(kind)-\(UUID().uuidString)") }

    /// The one scratch file that is deliberately not random: the partially assembled download of one blob under one split, so an
    /// interrupted download resumes. Swept like every scratch file when older than a day.
    func assembly(hash: String, partBytes: Int) -> URL {
        scratch.appendingPathComponent("dl-\(hash).\(partBytes / CloudRecordCodec.partUnitBytes).asm")
    }

    /// Removes scratch files not touched for a day (a crashed process leaves them). Returns how many went.
    @discardableResult
    func sweep(now: Date = Date(), olderThan age: TimeInterval = CloudBlobCache.staleAfter) -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: scratch.path) else { return 0 }
        var removed = 0
        for name in names {
            let url = scratch.appendingPathComponent(name)
            guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  now.timeIntervalSince(modified) > age else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    func scratchNames() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? [] }

    func freeBytes() -> Int64 {
        let probe = FileManager.default.fileExists(atPath: scratch.path) ? scratch : paths.root
        return (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? Int64.max
    }

    // MARK: the pinned cache

    /// A local copy of this ciphertext that verifies against its hash: the library's own source (`sync_blob_state`, the file an
    /// attachment was encrypted into, or a copy pinned by an earlier download) or `SyncDownloads/<hash>`. Identical ciphertext is
    /// stored once, whatever notes reference it.
    func existing(hash: String, database: AppDatabase) -> URL? {
        let known = try? database.pool.read { db in
            try Row.fetchOne(db, sql: "SELECT localPath, byteSize FROM sync_blob_state WHERE hash=? AND localPath IS NOT NULL", arguments: [hash])
        }
        // The cap comes before any hashing or returning of a local file.
        let range = 1...Int64(SyncWire.maximumBlobBytes)
        if let known, let path: String = known["localPath"], range.contains(known["byteSize"] as Int64),
           let found = try? SyncBlobLocation.verified(path, paths: paths, hash: hash, size: known["byteSize"]) { return found.url }
        let pinned = downloads.appendingPathComponent(hash)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: pinned.path)[.size]) as? Int64, range.contains(size),
              let found = try? SyncBlobLocation.verified("SyncDownloads/" + hash, paths: paths, hash: hash, size: size) else { return nil }
        return found.url
    }

    /// Moves a fully verified assembly into the cache and returns the pinned location. An existing pin is kept only if it
    /// verifies itself (size and SHA-256); a corrupt or foreign file there is replaced by an atomic rename of ours over it,
    /// then the directory is synced (CK-R117).
    func pin(_ verified: URL, hash: String, size: Int64) throws -> URL {
        try SyncWire.validateHash(hash)
        try prepareDirectories()
        let target = downloads.appendingPathComponent(hash)
        if FileManager.default.fileExists(atPath: target.path),
           let present = try? Self.digest(of: target, check: {}), present.hash == hash, present.size == size {
            try? FileManager.default.removeItem(at: verified)
            return target
        }
        let source = try FileHandle(forUpdating: verified)
        try source.synchronize(); try source.close()
        guard Darwin.rename(verified.path, target.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let directory = Darwin.open(downloads.path, O_RDONLY | O_DIRECTORY)
        if directory >= 0 { _ = Darwin.fsync(directory); Darwin.close(directory) }
        return target
    }

    // MARK: streaming

    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    /// SHA-256 of every part of `file` under `plan`, one buffer at a time.
    static func partHashes(of file: URL, plan: CloudBlobPlan, check: () throws -> Void) throws -> [String] {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var result: [String] = []
        for part in 0..<plan.parts {
            var hasher = SHA256()
            var remaining = plan.range(of: part).length
            while remaining > 0 {
                try check()
                let chunk = try autoreleasepool { try handle.read(upToCount: min(bufferBytes, remaining)) } ?? Data()
                guard !chunk.isEmpty else { throw CloudBlobError.sourceUnavailable }
                hasher.update(data: chunk); remaining -= chunk.count
            }
            result.append(hex(hasher.finalize()))
        }
        return result
    }

    /// Copies one part of `source` into a new scratch file at `target`; returns its SHA-256.
    static func writeSlice(of source: URL, range: (offset: Int, length: Int), to target: URL, check: () throws -> Void) throws -> String {
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else { throw CloudBlobError.sourceUnavailable }
        let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
        let output = try FileHandle(forWritingTo: target); defer { try? output.close() }
        try input.seek(toOffset: UInt64(range.offset))
        var hasher = SHA256()
        var remaining = range.length
        while remaining > 0 {
            try check()
            try autoreleasepool {
                guard let chunk = try input.read(upToCount: min(bufferBytes, remaining)), !chunk.isEmpty else { throw CloudBlobError.sourceUnavailable }
                hasher.update(data: chunk); try output.write(contentsOf: chunk); remaining -= chunk.count
            }
        }
        return hex(hasher.finalize())
    }

    /// Appends `part` to `assembly` (one buffer at a time) if it is `expectedBytes` long and hashes to `expectedSha`. On any
    /// problem the assembly is cut back to where it was, so it never holds half a part or a wrong one.
    static func append(_ part: URL, to assembly: URL, expectedBytes: Int, expectedSha: String, check: () throws -> Void) throws {
        if !FileManager.default.fileExists(atPath: assembly.path) { FileManager.default.createFile(atPath: assembly.path, contents: nil) }
        let input = try FileHandle(forReadingFrom: part); defer { try? input.close() }
        let output = try FileHandle(forWritingTo: assembly); defer { try? output.close() }
        let start = try output.seekToEnd()
        var hasher = SHA256()
        var written = 0
        do {
            while true {
                try check()
                let more: Bool = try autoreleasepool {
                    guard let chunk = try input.read(upToCount: bufferBytes), !chunk.isEmpty else { return false }
                    hasher.update(data: chunk); try output.write(contentsOf: chunk); written += chunk.count
                    return true
                }
                if !more { break }
            }
        } catch { try? output.truncate(atOffset: start); throw error }
        guard written == expectedBytes, hex(hasher.finalize()) == expectedSha else {
            try? output.truncate(atOffset: start)
            throw CloudBlobError.partDidNotVerify
        }
    }

    /// SHA-256 and size of a whole file, one buffer at a time.
    static func digest(of file: URL, check: () throws -> Void) throws -> (hash: String, size: Int64) {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hasher = SHA256(); var size: Int64 = 0
        while true {
            try check()
            let more: Bool = try autoreleasepool {
                guard let chunk = try handle.read(upToCount: bufferBytes), !chunk.isEmpty else { return false }
                hasher.update(data: chunk); size += Int64(chunk.count)
                return true
            }
            if !more { break }
        }
        return (hex(hasher.finalize()), size)
    }
}
