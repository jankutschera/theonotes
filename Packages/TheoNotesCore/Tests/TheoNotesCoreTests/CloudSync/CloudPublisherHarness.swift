// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

// A device for the publisher tests: a real library (temporary folder), the real `CloudSyncStore`, a `FakeCloudKitDevice`
// on a shared `FakeCloudKitAccount`, the real `CloudPublisher`. The receiver (Task 6) does not exist yet, so a notes-only
// stand-in (`applyNotes`) merges fetched versions the way the plan describes the applier: three-way merge against the
// base pair's ancestor (or the exact ancestor of an ambiguous outcome), written through the reused note writer, the
// pair moved in the same transaction by `recordApplied`, a snapshot of ours dropped in that same transaction.

/// Test double of the Task 7 seam: records the order of events against the cloud.
final class RecordingBlobs: CloudBlobUploading, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    private var _failures = 0
    /// Called with the hashes before they are "uploaded"; tests use it to observe what the cloud has at that moment.
    var onCall: (@Sendable ([String]) async -> Void)?
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return _calls }
    func failNext(_ times: Int = 1) { lock.withLock { _failures += times } }
    func ensureUploaded(_ hashes: [String]) async throws {
        let fail = lock.withLock { () -> Bool in
            _calls.append(hashes)
            let fail = _failures > 0
            if fail { _failures -= 1 }
            return fail
        }
        await onCall?(hashes)
        if fail { throw CloudSyncError.offline }
    }
}

struct NoBlobTransport: SyncBlobTransport {
    func ensureUploaded(_ hashes: [String]) async throws {}
    func download(hash: String) async throws -> URL { throw SyncProtocolError.invalidPayload }
}

final class PublisherDevice: @unchecked Sendable {
    let name: String
    let paths: AppPaths
    let db: AppDatabase
    let store: CloudSyncStore
    let accountID = "ck-publisher-account"
    let key: SymmetricKey
    let disk = FakeDeviceDisk()
    let crash: CrashPoint
    let gateway: FakeCloudKitDevice
    let blobs = RecordingBlobs()
    let sink: CloudFeedSink
    var intake: CloudFeedSink { sink }
    /// The unlocked access and password the receiver may use (set by tests that exercise protected notes).
    let access = LockedBox<LockedNoteAccess?>(nil)
    let password = LockedBox<String?>(nil)
    var reconciler: CloudReconciler {
        let access = access, password = password
        return CloudReconciler(database: db, paths: paths, store: store, accountID: accountID, vaultKey: key, pinner: CloudAssetPinner(directory: paths.cloudPinned),
                               crash: crash, noteAccess: { access.value }, notePassword: { password.value })
    }
    let sealer: CloudPayloadSealer
    var publisher: CloudPublisher
    /// The key-readiness gate the publisher is given; tests close it with `keysReady.update { $0 = false }`.
    let keysReady = LockedBox<Bool>(true)
    var noteStore: NoteStore { NoteStore(db: db, notifier: nil, paths: paths) }
    private var clockValue = Date(timeIntervalSince1970: 1_793_188_800)

    init(_ name: String, account: FakeCloudKitAccount?, key: SymmetricKey = SymmetricKey(data: Data(repeating: 7, count: 32)),
         crash: CrashPoint = CrashPoint(), enabled: Bool = true) throws {
        self.name = name; self.key = key; self.crash = crash
        paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("ck-publisher-\(name)-\(UUID())"))
        try paths.createDirectories()
        db = try AppDatabase(path: paths.database)
        store = CloudSyncStore(database: db)
        _ = try store.bind(accountId: accountID, containerId: "iCloud.test", zoneName: "TheoNotes", cloudUserHash: "user")
        if enabled { try db.pool.write { try $0.execute(sql: "UPDATE sync_control SET enabled=1 WHERE id=1") } }
        gateway = FakeCloudKitDevice(account: account, store: store, disk: disk, crash: crash)
        sink = CloudFeedSink(store: store, pinner: CloudAssetPinner(directory: paths.cloudPinned), crash: crash)
        sealer = CloudPayloadSealer(accountID: accountID, vaultKey: key)
        publisher = CloudPublisher(database: db, paths: paths, store: store, gateway: gateway, accountID: accountID, vaultKey: key,
                                   blobs: blobs, intake: sink, keyReadiness: Self.gate(keysReady), crash: crash)
    }

    static func gate(_ ready: LockedBox<Bool>) -> @Sendable () throws -> Void {
        return { if !ready.value { throw CloudPublisherError.keysNotReady } }
    }

    func cleanup() { try? db.pool.close(); try? FileManager.default.removeItem(at: paths.root) }

    /// Creates the zone (the coordinator's `prepare()` step).
    func prepareGateway() async throws { _ = try await gateway.prepare() }

    /// A new process: same library, same fake-device disk, fresh publisher.
    func restart(crash: CrashPoint = .never) {
        publisher = CloudPublisher(database: db, paths: paths, store: store, gateway: gateway, accountID: accountID, vaultKey: key,
                                   blobs: blobs, intake: intake, keyReadiness: Self.gate(keysReady), crash: crash)
    }

    // MARK: reading the library

    func notes() throws -> [Note] { try db.pool.read { try Note.fetchAll($0, sql: "SELECT * FROM note ORDER BY id") } }
    func note(_ id: String) throws -> Note? { try db.pool.read { try Note.fetchOne($0, key: id) } }
    func dirtyGeneration(_ id: String, type: String = "note") throws -> Int64? {
        try db.pool.read { try Int64.fetchOne($0, sql: "SELECT generation FROM sync_dirty WHERE entityType=? AND localId=?", arguments: [type, id]) }
    }
    func rowCount(_ table: String) throws -> Int { try db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)")! } }
    func dirtyCount() throws -> Int { try db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_dirty")! } }
    func ref(_ id: String, type: String = "note") -> CloudEntityRef { CloudEntityRef(entityType: type, entityId: id) }

    /// Edits through the product's own path; the capture triggers raise the dirty generation.
    @discardableResult
    func edit(_ id: String, _ text: String) throws -> Note {
        let current = try #require(try note(id))
        return try noteStore.updateText(id: id, text: text, expectedRevision: current.revision)
    }

    func setEnabled(_ on: Bool) throws {
        try db.pool.write { try $0.execute(sql: "UPDATE sync_control SET enabled=? WHERE id=1", arguments: [on]) }
    }

    // MARK: cycles

    @discardableResult
    func publish() async throws -> CloudPublishReport {
        let report = try await publisher.publishCycle()
        ModelCounters.shared.add(report)
        return report
    }

    func fetch() async throws { try await gateway.fetchChanges(into: sink) }

    /// A full device round: fetch, merge what arrived, publish; repeated until nothing moves (bounded).
    func sync(rounds: Int = 6) async throws {
        for _ in 0..<rounds {
            try await fetch()
            let applied = try await applyNotes()
            let report = try await publish()
            if applied == 0, report.prepared == 0, report.submitted == 0, report.saved == 0, report.needsMerge.isEmpty { break }
        }
    }

    // MARK: the receiver

    /// The real receiver (Task 6): applies every fetched version waiting in `ck_remote`. Returns how many were applied.
    @discardableResult
    func applyNotes() async throws -> Int { try await reconciler.applyPending().applied.count }
}

/// A person with N devices on one iCloud account.
struct PublisherWorld {
    let account: FakeCloudKitAccount
    let devices: [PublisherDevice]
    static func make(_ count: Int, crash: CrashPoint? = nil) async throws -> PublisherWorld {
        let account = FakeCloudKitAccount()
        let devices = try (0..<count).map { try PublisherDevice("d\($0)", account: account, crash: crash ?? CrashPoint()) }
        for device in devices { try await device.prepareGateway() }
        return PublisherWorld(account: account, devices: devices)
    }
    func cleanup() { devices.forEach { $0.cleanup() } }
}

/// How often the model test's schedules reached the interesting paths (so a green run cannot hide a model that never gets there).
final class ModelCounters: @unchecked Sendable {
    static let shared = ModelCounters()
    private let lock = NSLock()
    private var values: [String: Int] = [:]
    func add(_ report: CloudPublishReport) {
        lock.withLock {
            values["saved", default: 0] += report.saved
            values["merge", default: 0] += report.needsMerge.count
            values["requeued", default: 0] += report.requeued
            values["paused", default: 0] += report.paused.count
            values["staleResult", default: 0] += report.discardedStaleResults
        }
    }
    func bump(_ key: String) { lock.withLock { values[key, default: 0] += 1 } }
    func value(_ key: String) -> Int { lock.withLock { values[key] ?? 0 } }
}
