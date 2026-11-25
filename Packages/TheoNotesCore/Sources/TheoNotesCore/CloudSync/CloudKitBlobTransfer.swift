// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB

// Verified, resumable blob transfer as CloudKit `BlobPart` records (Task 7, CK-R8, CK-R110 to CK-R114).
//
//   upload   local ciphertext (verified against its hash) -> metadata read of the parts that exist -> missing parts, one at a time,
//            each from a scratch slice -> metadata read again -> `ck_blob_part` rows `verified`
//   download metadata of every part first -> each asset moved out of the system staging area at once, size and SHA-256 checked,
//            appended through a 1 MiB buffer -> size and SHA-256 of the whole blob -> pinned in `SyncDownloads/<hash>`
//
// Nothing here deletes a record (v1 never deletes blob parts, CK-R8) and nothing writes outside the library's no-backup scratch
// folder except the pinned result. The publisher awaits `ensureUploaded` before it submits an Entity that names a blob; the
// receiver calls `download(hash:)` before it applies an attachment.

public enum CloudBlobError: Error, Equatable, Sendable {
    /// The blob is empty or larger than `SyncWire.maximumBlobBytes`. Refused before any work.
    case sizeOutOfRange(Int64)
    /// The configured part size would need more than 8 parts for this blob.
    case tooManyParts(Int)
    /// The local ciphertext is missing, changed or does not match its hash.
    case sourceUnavailable
    /// The cloud has some, not all, parts of this blob (or none of the splits is complete): wait for the rest.
    case missingParts(hash: String, parts: [Int])
    /// The cloud has nothing for this blob.
    case notInCloud(hash: String)
    /// A part exists under our name with other metadata and no alternative split name is left.
    case corruptRemotePart(hash: String, part: Int)
    case insufficientDiskSpace(needed: Int64, available: Int64)
    /// A part or the whole blob did not match its size or SHA-256. Internal to the one retry; surfaces as
    /// `CloudPolicyError.corruptAttachment` after it.
    case partDidNotVerify
}

/// Test and diagnostics hook: what the transfer has seen and done.
public final class CloudBlobDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var corrupt: [String] = []
    private var uploaded: [String] = []
    private var downloaded: [String] = []
    public init() {}
    fileprivate func corruptPart(_ name: String) { lock.withLock { if !corrupt.contains(name) { corrupt.append(name) } } }
    fileprivate func uploadedPart(_ name: String) { lock.withLock { uploaded.append(name) } }
    fileprivate func downloadedPart(_ name: String) { lock.withLock { downloaded.append(name) } }
    /// Record names found in the cloud with metadata that is not ours (never overwritten).
    public var corruptRemoteParts: [String] { lock.withLock { corrupt } }
    /// Record names this device saved, in order.
    public var uploadedParts: [String] { lock.withLock { uploaded } }
    /// Record names this device fetched an asset for, in order.
    public var downloadedParts: [String] { lock.withLock { downloaded } }
}

public struct CloudBlobTiming: Sendable {
    /// How often the store is read for the outcome of a part save.
    public var pollInterval: TimeInterval
    /// How long one part save may stay unanswered before the upload gives up for now (the next run asks the cloud).
    public var outcomeTimeout: TimeInterval
    /// How often an unanswered save is looked up in the cloud by name. A last resort only: results are kept by the orphan
    /// sweep (CK-R114), so an unanswered save normally means the gateway has not sent it yet.
    public var cloudLookupInterval: TimeInterval
    public init(pollInterval: TimeInterval = 0.25, outcomeTimeout: TimeInterval = 600, cloudLookupInterval: TimeInterval = 60) {
        self.pollInterval = pollInterval; self.outcomeTimeout = outcomeTimeout; self.cloudLookupInterval = cloudLookupInterval
    }
}

/// Cancelled by the caller; checked at every buffer boundary.
final class CloudBlobCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func cancel() { lock.withLock { flag = true } }
    func check() throws {
        if Task.isCancelled || lock.withLock({ flag }) { throw CancellationError() }
    }
}

public actor CloudKitBlobTransfer: CloudBlobUploading, SyncBlobTransport {
    private struct Running<Value: Sendable> { let id: UUID; let task: Task<Value, any Error> }

    private let worker: Worker
    private var uploading: [String: Running<Void>] = [:]
    private var downloading: [String: Running<URL>] = [:]
    private var freeSlots = 2
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var swept = false
    private var closed = false

    /// - Parameters:
    ///   - fence: every transfer runs through `fence.run` so an account change cancels and drains it (CK-R15, CK-R92).
    ///   - keyReadiness: called before any `BlobPart` is saved; it throws while key creation is incomplete (Task 8,
    ///     `CloudKeyCreation.requireComplete`). Downloads do not need it.
    ///   - freeBytes: free space on the volume of the library, for the pre-flight (default: the system's answer).
    public init(database: AppDatabase, paths: AppPaths, gateway: any CloudKitGateway, store: CloudSyncStore,
                fence: CloudGenerationFence, keyReadiness: @escaping @Sendable () throws -> Void,
                partBytes: Int = 33_554_432, timing: CloudBlobTiming = CloudBlobTiming(), crash: CrashPoint = .never,
                clock: @escaping @Sendable () -> Date = { Date() }, freeBytes: (@Sendable () -> Int64)? = nil,
                diagnostics: CloudBlobDiagnostics = CloudBlobDiagnostics()) {
        let cache = CloudBlobCache(paths: paths)
        let unit = CloudRecordCodec.partUnitBytes
        let partBytes = max(unit, partBytes / unit * unit)
        worker = Worker(database: database, paths: paths, gateway: gateway, store: store, fence: fence, keyReadiness: keyReadiness,
                        partBytes: partBytes, timing: timing, crash: crash, clock: clock, freeBytes: freeBytes ?? { cache.freeBytes() },
                        cache: cache, parts: CloudBlobPartStore(database: database), diagnostics: diagnostics)
    }

    public nonisolated var diagnostics: CloudBlobDiagnostics { worker.diagnostics }

    /// Cancels every transfer and waits for it. Scratch files of cancelled transfers are removed by the transfers themselves.
    public func shutdown() async {
        closed = true
        let uploads = Array(uploading.values), downloads = Array(downloading.values)
        uploads.forEach { $0.task.cancel() }; downloads.forEach { $0.task.cancel() }
        for entry in uploads { _ = try? await entry.task.value }
        for entry in downloads { _ = try? await entry.task.value }
    }

    /// Removes scratch files older than a day (a crashed process leaves them). Call at launch; also runs once before the first transfer.
    @discardableResult
    public nonisolated func sweepScratch(now: Date = Date(), olderThan age: TimeInterval = 24 * 3600) -> Int {
        worker.cache.sweep(now: now, olderThan: age)
    }

    // MARK: upload

    /// Makes every blob named by `hashes` present and verified in the cloud. At most two blobs are in flight; one task per hash.
    public func ensureUploaded(_ hashes: [String]) async throws {
        guard !closed else { throw CancellationError() }
        let unique = Set(hashes).sorted()
        for hash in unique { try SyncWire.validateHash(hash) }
        try prepareOnce()
        let runs = unique.map { uploadRun(for: $0) }
        var failure: (any Error)?
        await withTaskCancellationHandler {
            for run in runs {
                do { try await run.task.value } catch { failure = failure ?? error }
            }
        } onCancel: { runs.forEach { $0.task.cancel() } }
        for (hash, run) in zip(unique, runs) where uploading[hash]?.id == run.id { uploading[hash] = nil }
        if let failure { throw failure }
        try Task.checkCancellation()
    }

    private func uploadRun(for hash: String) -> Running<Void> {
        if let running = uploading[hash] { return running }
        let worker = self.worker
        let task = Task<Void, any Error> {
            await self.acquire()
            let cancel = CloudBlobCancel()
            do {
                try await withTaskCancellationHandler {
                    try await worker.fence.run { generation in try await worker.upload(hash: hash, generation: generation, cancel: cancel) }
                } onCancel: { cancel.cancel() }
            } catch { self.release(); throw error }
            self.release()
        }
        let running = Running(id: UUID(), task: task)
        uploading[hash] = running
        return running
    }

    private func acquire() async {
        if freeSlots > 0 { freeSlots -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { freeSlots += 1 } else { waiters.removeFirst().resume() }
    }

    // MARK: download

    /// The verified ciphertext of `hash` on local disk. Metadata first (all parts present and consistent), then each asset; the
    /// first mismatch drops the scratch state and tries once more from the cloud, the second ends in `corruptAttachment`.
    public func download(hash: String) async throws -> URL {
        guard !closed else { throw CancellationError() }
        try SyncWire.validateHash(hash)
        try prepareOnce()
        let running: Running<URL>
        if let current = downloading[hash] { running = current } else {
            let worker = self.worker
            let task = Task<URL, any Error> {
                let cancel = CloudBlobCancel()
                return try await withTaskCancellationHandler {
                    try await worker.fence.run { generation in try await worker.downloadWithRetry(hash: hash, generation: generation, cancel: cancel) }
                } onCancel: { cancel.cancel() }
            }
            running = Running(id: UUID(), task: task)
            downloading[hash] = running
        }
        defer { if downloading[hash]?.id == running.id { downloading[hash] = nil } }
        return try await withTaskCancellationHandler {
            let url = try await running.task.value
            try Task.checkCancellation()
            return url
        } onCancel: { running.task.cancel() }
    }

    private func prepareOnce() throws {
        try worker.cache.prepareDirectories()
        if !swept { swept = true; worker.cache.sweep() }
    }
}

// MARK: - the work, off the actor

extension CloudKitBlobTransfer {
    /// Everything a transfer needs, immutable; the heavy loops run on it so the actor stays free.
    fileprivate struct Worker: Sendable {
        let database: AppDatabase
        let paths: AppPaths
        let gateway: any CloudKitGateway
        let store: CloudSyncStore
        let fence: CloudGenerationFence
        let keyReadiness: @Sendable () throws -> Void
        let partBytes: Int
        let timing: CloudBlobTiming
        let crash: CrashPoint
        let clock: @Sendable () -> Date
        let freeBytes: @Sendable () -> Int64
        let cache: CloudBlobCache
        let parts: CloudBlobPartStore
        let diagnostics: CloudBlobDiagnostics

        static let metadataKeys = ["v", "hash", "part", "parts", "partBytes", "totalBytes", "partSha256"]

        // MARK: upload

        func upload(hash: String, generation: Int64, cancel: CloudBlobCancel) async throws {
            try keyReadiness()
            let (path, size) = try source(of: hash)
            guard size > 0, size <= Int64(SyncWire.maximumBlobBytes) else { throw CloudBlobError.sizeOutOfRange(size) }
            let base = CloudBlobPlan(totalBytes: Int(size), partBytes: partBytes)
            guard base.parts <= CloudRecordCodec.maxBlobParts else { throw CloudBlobError.tooManyParts(base.parts) }
            let candidates = CloudBlobPlan.candidates(totalBytes: Int(size), partBytes: partBytes)
            try cancel.check()
            if try trusted(hash: hash, size: Int(size)) { return }
            let file: URL
            do { file = try SyncBlobLocation.verified(path, paths: paths, hash: hash, size: size).url }
            catch is CancellationError { throw CancellationError() }
            catch { throw CloudBlobError.sourceUnavailable }
            var lastCorrupt = 0
            for plan in candidates {
                let shas = try CloudBlobCache.partHashes(of: file, plan: plan, check: cancel.check)
                do {
                    try await settle(hash: hash, file: file, plan: plan, shas: shas, generation: generation, cancel: cancel)
                    return
                } catch CloudBlobError.corruptRemotePart(_, let part) {
                    lastCorrupt = part
                    diagnostics.corruptPart(plan.name(hash: hash, part: part))
                }
            }
            throw CloudBlobError.corruptRemotePart(hash: hash, part: lastCorrupt)
        }

        private func source(of hash: String) throws -> (path: String, size: Int64) {
            let row = try database.pool.read { db in
                try Row.fetchOne(db, sql: "SELECT localPath, byteSize FROM sync_blob_state WHERE hash=?", arguments: [hash])
            }
            guard let row else { throw CloudBlobError.sourceUnavailable }
            let size: Int64 = row["byteSize"]
            guard size > 0, size <= Int64(SyncWire.maximumBlobBytes) else { throw CloudBlobError.sizeOutOfRange(size) }
            guard let path: String = row["localPath"] else { throw CloudBlobError.sourceUnavailable }
            return (path, size)
        }

        /// A complete set of `verified` rows younger than 24 h (CK-R8). Anything else is checked against the cloud.
        private func trusted(hash: String, size: Int) throws -> Bool {
            let rows = try parts.rows(hash: hash)
            guard let first = rows.first else { return false }
            let plan = CloudBlobPlan(totalBytes: size, partBytes: first.partBytes)
            guard plan.partBytes % CloudRecordCodec.partUnitBytes == 0, plan.parts <= CloudRecordCodec.maxBlobParts, rows.count == plan.parts else { return false }
            let now = clock()
            for (index, row) in rows.enumerated() {
                guard row.part == index, row.parts == plan.parts, row.partBytes == plan.partBytes, row.totalBytes == size,
                      row.state == .verified, let at = row.verifiedAt, now.timeIntervalSince(at) <= CloudBlobCache.staleAfter else { return false }
            }
            return true
        }

        /// Brings one split to "all parts present and ours": reads what the cloud has, saves what is missing one part at a
        /// time, reads again. Throws `corruptRemotePart` when a part of this name exists with other metadata.
        private func settle(hash: String, file: URL, plan: CloudBlobPlan, shas: [String], generation: Int64, cancel: CloudBlobCancel) async throws {
            let names = (0..<plan.parts).map { plan.name(hash: hash, part: $0) }
            let existing = try await metadata(names)
            var missing: [Int] = []
            var present: [Int] = []
            for index in 0..<plan.parts {
                guard let record = existing[names[index]] else { missing.append(index); continue }
                guard matches(record, hash: hash, plan: plan, part: index, sha: shas[index]) else {
                    throw CloudBlobError.corruptRemotePart(hash: hash, part: index)
                }
                present.append(index)
            }
            let now = clock()
            try parts.replace(hash: hash, with: present.map { row(hash, plan, $0, shas[$0], .verified, now) }, generation: generation)
            for index in missing {
                try cancel.check()
                try await uploadPart(hash: hash, file: file, plan: plan, index: index, sha: shas[index], generation: generation, cancel: cancel)
            }
            guard !missing.isEmpty else { return }
            // Confirm against the cloud before anything is called verified.
            let after = try await metadata(names)
            for index in 0..<plan.parts {
                guard let record = after[names[index]] else { throw CloudSyncError.failed(code: "blobPartNotConfirmed") }
                guard matches(record, hash: hash, plan: plan, part: index, sha: shas[index]) else {
                    throw CloudBlobError.corruptRemotePart(hash: hash, part: index)
                }
            }
            let confirmed = clock()
            try parts.replace(hash: hash, with: (0..<plan.parts).map { row(hash, plan, $0, shas[$0], .verified, confirmed) }, generation: generation)
        }

        private func row(_ hash: String, _ plan: CloudBlobPlan, _ index: Int, _ sha: String, _ state: CloudBlobPartRow.State, _ at: Date?) -> CloudBlobPartRow {
            CloudBlobPartRow(hash: hash, part: index, parts: plan.parts, partBytes: plan.partBytes, totalBytes: plan.totalBytes,
                             partSha256: sha, state: state, verifiedAt: state == .verified ? at : nil)
        }

        private func uploadPart(hash: String, file: URL, plan: CloudBlobPlan, index: Int, sha: String, generation: Int64, cancel: CloudBlobCancel) async throws {
            try crash.hit("blob.beforePart")
            try fence.requireCurrent(generation)
            let slice = cache.newScratch("slice")
            defer { try? FileManager.default.removeItem(at: slice) }
            let need = Int64(plan.partBytes) * 2
            let available = freeBytes()
            guard available >= need else { throw CloudBlobError.insufficientDiskSpace(needed: need, available: available) }
            let written = try CloudBlobCache.writeSlice(of: file, range: plan.range(of: index), to: slice, check: cancel.check)
            guard written == sha else { throw CloudBlobError.sourceUnavailable }       // the source changed under us
            let header = CloudBlobPartHeader(hash: hash, part: index, parts: plan.parts, partBytes: plan.partBytes,
                                             totalBytes: plan.totalBytes, partSha256: sha, asset: slice)
            let record = CloudRecordCodec.encode(header)
            _ = try CloudRecordCodec.decode(record)
            let attemptId = CloudSyncStore.blobAttemptPrefix + UUIDv7.make()
            // Readiness and the account fence are checked again right before the save leaves (CK-R14, CK-R92).
            try keyReadiness()
            try fence.requireCurrent(generation)
            if try store.isAccountFenced() { throw CloudSyncError.fenced }
            try await gateway.submit([CloudSave(attemptId: attemptId, accountGeneration: generation, record: record)])
            diagnostics.uploadedPart(record.name)
            try await awaitOutcome(attemptId: attemptId, hash: hash, plan: plan, index: index, sha: sha, generation: generation, cancel: cancel)
            try parts.upsert(row(hash, plan, index, sha, .uploaded, nil), generation: generation)
            try crash.hit("blob.afterPartSaved")
        }

        /// Reads the outcome of one part save from the store (the gateway writes it the moment it is known). A part whose result
        /// row never shows up is looked up in the cloud by name now and then: if it is there and ours, it landed.
        private func awaitOutcome(attemptId: String, hash: String, plan: CloudBlobPlan, index: Int, sha: String, generation: Int64, cancel: CloudBlobCancel) async throws {
            let name = plan.name(hash: hash, part: index)
            let deadline = Date().addingTimeInterval(timing.outcomeTimeout)
            var nextLookup = Date().addingTimeInterval(timing.cloudLookupInterval)
            while true {
                try cancel.check()
                if let result = try store.sendResult(attemptId: attemptId) {
                    try fence.requireCurrent(generation)
                    try store.deleteSendResult(attemptId: attemptId)
                    guard result.accountGeneration == generation else { throw CloudSyncError.fenced }
                    switch result.outcome {
                    case .saved: return
                    case .serverRecordChanged:
                        // The name exists: the save is create-only (no system fields), so nothing was overwritten (CK-R116).
                        // Read what is there; the same part written by another device is fine, anything else is foreign.
                        if let found = try await metadata([name])[name], matches(found, hash: hash, plan: plan, part: index, sha: sha) { return }
                        throw CloudBlobError.corruptRemotePart(hash: hash, part: index)
                    case .quotaExceeded: throw CloudSyncError.quotaExceeded
                    case .limitExceeded: throw CloudSyncError.limitExceeded
                    case .zoneNotFound: throw CloudSyncError.zoneNotFound
                    case .unauthenticated: throw CloudSyncError.unauthenticated
                    case .fenced: throw CloudSyncError.fenced
                    case .offline: throw CloudSyncError.offline
                    case .unknownItem: throw CloudSyncError.failed(code: "unknownItem")
                    case .failed(let code): throw CloudSyncError.failed(code: code)
                    }
                }
                if Date() >= nextLookup {
                    nextLookup = Date().addingTimeInterval(timing.cloudLookupInterval)
                    if let found = try? await metadata([name])[name], matches(found, hash: hash, plan: plan, part: index, sha: sha) { return }
                }
                guard Date() < deadline else { throw CloudSyncError.offline }
                try await Task.sleep(nanoseconds: UInt64(max(0.001, timing.pollInterval) * 1_000_000_000))
            }
        }

        // MARK: metadata

        /// Metadata only: the `asset` field is not requested, so nothing is staged and nothing large moves.
        func metadata(_ names: [String]) async throws -> [String: CloudRecord] {
            try await gateway.fetch(names, keys: Self.metadataKeys)
        }

        /// The header of a record read without its asset; nil if the record is not a valid `BlobPart` under its own name.
        func header(_ record: CloudRecord) -> CloudBlobPartHeader? {
            var full = record
            if full.fields["asset"] == nil { full.fields["asset"] = .asset(URL(fileURLWithPath: "/dev/null")) }
            guard case .blobPart(let header)? = try? CloudRecordCodec.decode(full) else { return nil }
            return header
        }

        func matches(_ record: CloudRecord, hash: String, plan: CloudBlobPlan, part: Int, sha: String) -> Bool {
            guard let found = header(record) else { return false }
            return found.hash == hash && found.part == part && found.parts == plan.parts && found.partBytes == plan.partBytes
                && found.totalBytes == plan.totalBytes && found.partSha256 == sha
        }

        // MARK: download

        /// One download of a hash at a time in the whole process and library, whichever transfer instance asks (CK-R117): the
        /// deterministic assembly file and the pin are only touched under this lock, and a caller that waited finds the pin.
        func downloadWithRetry(hash: String, generation: Int64, cancel: CloudBlobCancel) async throws -> URL {
            let namespace = "cloud-blob-download|\(paths.root.standardizedFileURL.path)|\(hash)"
            return try await CloudKeySerial.shared(namespace: namespace).run { try await self.downloadLocked(hash: hash, generation: generation, cancel: cancel) }
        }

        private func downloadLocked(hash: String, generation: Int64, cancel: CloudBlobCancel) async throws -> URL {
            if let size = try cachedRowSize(of: hash), size <= 0 || size > Int64(SyncWire.maximumBlobBytes) { throw CloudBlobError.sizeOutOfRange(size) }
            // A local copy that verifies (our own source, or an earlier pin) needs no cloud call.
            if let local = cache.existing(hash: hash, database: database) { return local }
            do {
                for attempt in 0..<2 {
                    do { return try await download(hash: hash, generation: generation, cancel: cancel) }
                    catch CloudBlobError.partDidNotVerify {
                        // Drop what we hold of it (assembly, part state) and ask the cloud again, once.
                        removeAssemblies(hash: hash)
                        try parts.drop(hash: hash, generation: generation)
                        if attempt == 1 { break }
                    }
                }
                throw CloudPolicyError.corruptAttachment
            } catch let crash as CrashInjected {
                throw crash                  // a crash runs no cleanup; the assembly stays for the next launch (age policy: a day)
            } catch {
                removeAssemblies(hash: hash)    // an error or a cancel leaves nothing behind (CK-R118)
                throw error
            }
        }

        private func cachedRowSize(of hash: String) throws -> Int64? {
            try database.pool.read { db in
                try Int64.fetchOne(db, sql: "SELECT byteSize FROM sync_blob_state WHERE hash=? AND localPath IS NOT NULL", arguments: [hash])
            }
        }

        private func removeAssemblies(hash: String) {
            for split in 0...CloudBlobPlan.alternativeSplits {
                try? FileManager.default.removeItem(at: cache.assembly(hash: hash, partBytes: partBytes + split * CloudRecordCodec.partUnitBytes))
            }
        }

        private struct Layout { let plan: CloudBlobPlan; let shas: [String] }

        /// Tries every complete, consistent split in order; one whose parts do not verify is dropped and the next is tried (a
        /// foreign part under the first split's name must not hide a good set under the next).
        private func download(hash: String, generation: Int64, cancel: CloudBlobCancel) async throws -> URL {
            try cancel.check()
            for layout in try await locate(hash: hash) {
                do { return try await assemble(hash: hash, layout: layout, generation: generation, cancel: cancel) }
                catch CloudBlobError.partDidNotVerify {
                    try? FileManager.default.removeItem(at: cache.assembly(hash: hash, partBytes: layout.plan.partBytes))
                }
            }
            throw CloudBlobError.partDidNotVerify
        }

        private func assemble(hash: String, layout: Layout, generation: Int64, cancel: CloudBlobCancel) async throws -> URL {
            let plan = layout.plan
            let assembly = cache.assembly(hash: hash, partBytes: plan.partBytes)
            var done = 0
            if let size = (try? FileManager.default.attributesOfItem(atPath: assembly.path)[.size]) as? Int {
                if size > plan.totalBytes { try? FileManager.default.removeItem(at: assembly) } else {
                    done = size / plan.partBytes
                    if done * plan.partBytes != size, let handle = try? FileHandle(forWritingTo: assembly) {
                        try? handle.truncate(atOffset: UInt64(done * plan.partBytes)); try? handle.close()
                    }
                }
            }
            let remaining = Int64(plan.totalBytes - done * plan.partBytes)
            let available = freeBytes()
            guard available >= remaining * 2 else { throw CloudBlobError.insufficientDiskSpace(needed: remaining * 2, available: available) }
            for index in done..<plan.parts {
                try cancel.check()
                try fence.requireCurrent(generation)
                try await fetchPart(hash: hash, layout: layout, index: index, into: assembly, cancel: cancel)
                try crash.hit("blob.afterDownloadedPart")
            }
            let measured = try CloudBlobCache.digest(of: assembly, check: cancel.check)
            guard measured.size == Int64(plan.totalBytes), measured.hash == hash else {
                try? FileManager.default.removeItem(at: assembly)
                throw CloudBlobError.partDidNotVerify
            }
            try cancel.check()
            return try cache.pin(assembly, hash: hash, size: measured.size)
        }

        /// Metadata of every part of each split this build would have used, before any asset moves. Every complete and
        /// consistent split, in order of preference.
        private func locate(hash: String) async throws -> [Layout] {
            let splits = (0...CloudBlobPlan.alternativeSplits).map { partBytes + $0 * CloudRecordCodec.partUnitBytes }
            let firsts = try await metadata(splits.map { CloudRecordCodec.blobPartRecordName(hash: hash, partBytes: $0, part: 0) })
            var corrupt = false
            var incomplete: [Int]?
            var found: [Layout] = []
            for split in splits {
                guard let first = firsts[CloudRecordCodec.blobPartRecordName(hash: hash, partBytes: split, part: 0)] else { continue }
                guard let head = header(first), head.hash == hash, head.part == 0, head.partBytes == split,
                      head.totalBytes <= SyncWire.maximumBlobBytes else { corrupt = true; continue }
                let plan = CloudBlobPlan(totalBytes: head.totalBytes, partBytes: split)
                guard plan.parts == head.parts else { corrupt = true; continue }
                let names = (1..<max(1, plan.parts)).map { plan.name(hash: hash, part: $0) }
                let rest = names.isEmpty ? [:] : try await metadata(names)
                var shas = [head.partSha256]
                var missing: [Int] = []
                var inconsistent = false
                for index in 1..<max(1, plan.parts) {
                    guard let record = rest[plan.name(hash: hash, part: index)] else { missing.append(index); shas.append(""); continue }
                    guard let part = header(record), part.hash == hash, part.part == index, part.parts == plan.parts,
                          part.partBytes == split, part.totalBytes == head.totalBytes else { inconsistent = true; break }
                    shas.append(part.partSha256)
                }
                if inconsistent { corrupt = true; continue }
                if !missing.isEmpty { incomplete = missing; continue }
                found.append(Layout(plan: plan, shas: shas))
            }
            if !found.isEmpty { return found }
            if let incomplete { throw CloudBlobError.missingParts(hash: hash, parts: incomplete) }
            if corrupt { throw CloudBlobError.partDidNotVerify }
            throw CloudBlobError.notInCloud(hash: hash)
        }

        private func fetchPart(hash: String, layout: Layout, index: Int, into assembly: URL, cancel: CloudBlobCancel) async throws {
            let plan = layout.plan
            let name = plan.name(hash: hash, part: index)
            var attempts = 0
            var local: URL
            while true {
                let got = try await gateway.fetch([name], keys: nil)
                diagnostics.downloadedPart(name)
                guard let record = got[name] else { throw CloudBlobError.missingParts(hash: hash, parts: [index]) }
                guard let found = header(record), found.hash == hash, found.part == index, found.parts == plan.parts,
                      found.partBytes == plan.partBytes, found.totalBytes == plan.totalBytes, found.partSha256 == layout.shas[index]
                else { throw CloudBlobError.partDidNotVerify }
                // Out of the system's staging area at once: the system may clear it at any time.
                let target = cache.newScratch("part")
                do { try FileManager.default.moveItem(at: found.asset, to: target); local = target; break }
                catch {
                    attempts += 1
                    if attempts > 1 { throw CloudSyncError.failed(code: "assetNotAvailable") }
                }
            }
            defer { try? FileManager.default.removeItem(at: local) }
            let expected = plan.range(of: index).length
            guard (try? FileManager.default.attributesOfItem(atPath: local.path)[.size]) as? Int == expected else { throw CloudBlobError.partDidNotVerify }
            try CloudBlobCache.append(local, to: assembly, expectedBytes: expected, expectedSha: layout.shas[index], check: cancel.check)
        }
    }
}
