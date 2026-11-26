// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
@testable import TheoNotesCore

// An in-memory CloudKit for everything before the Apple account exists (the fake is the test strategy, and nothing it
// teaches is frozen before Gate G0). Each behaviour below is tagged
//   [doc]  modelled on documentation (URL in docs/superpowers/specs/2026-10-28-cloudkit-record-v1.md, "Fake fidelity"), or
//   [G0]   an ASSUMPTION that Gate G0 / the live contract run must confirm or correct.
// Mapping to the live gateway: `FakeCloudKitAccount` is the cloud of one iCloud user; `FakeCloudKitDevice` is one device's
// gateway (`CKSyncEngine` plus our delegate) with its own engine state and durable pending list.

// MARK: - support for tests

/// The durable parts of a device that survive a restart: the pending list and the pin directory (the gateway's own durable
/// folder, in the app the no-backup folder). (The change token is the sink's saved engine state; the zone lifecycle and the
/// send results are in the `CloudGatewayStore`.)
final class FakeDeviceDisk: @unchecked Sendable {
    private let lock = NSLock()
    private var saves: [CloudSave] = []
    let pinDirectory: URL

    init() {
        pinDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("fake-ck-pinned-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: pinDirectory, withIntermediateDirectories: true)
    }

    var pending: [CloudSave] {
        get { lock.lock(); defer { lock.unlock() }; return saves }
        set { lock.lock(); defer { lock.unlock() }; saves = newValue }
    }

    /// Removes the first pending save with this attempt id (a result for it is now durable).
    func removeFirst(attemptId: String) {
        lock.lock(); defer { lock.unlock() }
        if let index = saves.firstIndex(where: { $0.attemptId == attemptId }) { saves.remove(at: index) }
    }
}

struct CloudSendResult: Equatable, Sendable {
    let attemptId: String
    let accountGeneration: Int64
    let outcome: CloudSaveOutcome
}

/// Stands in for `ck_state.zoneState` and `ck_send_result` (Task 3 implements the SQLite version of `CloudGatewayStore`).
final class InMemoryCloudGatewayStore: CloudGatewayStore, @unchecked Sendable {
    private let lock = NSLock()
    private var zone: CloudZoneState = .unknown
    private var results: [String: CloudSendResult] = [:]

    func zoneState() throws -> CloudZoneState { lock.lock(); defer { lock.unlock() }; return zone }
    func setZoneState(_ state: CloudZoneState) throws { lock.lock(); defer { lock.unlock() }; zone = state }
    /// The n-th next `recordSendResult` call (counted from now) throws.
    func failRecord(onCall n: Int) { lock.lock(); defer { lock.unlock() }; failAt = recordCalls + n }
    private var recordCalls = 0
    private var failAt: Int?

    func recordSendResult(attemptId: String, accountGeneration: Int64, outcome: CloudSaveOutcome) throws {
        lock.lock(); defer { lock.unlock() }
        recordCalls += 1
        if failAt == recordCalls { failAt = nil; throw SinkFailure(what: "recordSendResult") }
        results[attemptId] = CloudSendResult(attemptId: attemptId, accountGeneration: accountGeneration, outcome: outcome)
    }

    func result(for attemptId: String) -> CloudSendResult? { lock.lock(); defer { lock.unlock() }; return results[attemptId] }
    func outcome(for attemptId: String) -> CloudSaveOutcome? { result(for: attemptId)?.outcome }
    var attemptIds: [String] { lock.lock(); defer { lock.unlock() }; return Array(results.keys) }

    func waitForOutcomes(_ ids: [String], timeout: TimeInterval) async throws -> [CloudSaveOutcome] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let found = ids.compactMap { outcome(for: $0) }
            if found.count == ids.count { return found }
            if Date() > deadline { throw CloudSyncError.failed(code: "timeout waiting for \(ids.count - found.count) outcome(s)") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

struct SinkFailure: Error, Equatable { let what: String }

final class RecordingSink: CloudChangeSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _allChanged: [CloudRecord] = []
    private var _deleted: [String] = []
    private var _commitSizes: [Int] = []
    private var _log: [String] = []
    private var _lastState: Data?
    private var _fullRefetches = 0
    private var commitCalls = 0, stateCalls = 0
    private var failCommitAt: Int?, failStateAt: Int?

    var allChanged: [CloudRecord] { lock.lock(); defer { lock.unlock() }; return _allChanged }
    var changedNames: [String] { allChanged.map(\.name) }
    var deletedNames: [String] { lock.lock(); defer { lock.unlock() }; return _deleted }
    var commitSizes: [Int] { lock.lock(); defer { lock.unlock() }; return _commitSizes }
    var log: [String] { lock.lock(); defer { lock.unlock() }; return _log }
    var lastState: Data? { lock.lock(); defer { lock.unlock() }; return _lastState }
    var fullRefetches: Int { lock.lock(); defer { lock.unlock() }; return _fullRefetches }
    func changed(named name: String) -> CloudRecord? { allChanged.last { $0.name == name } }

    /// The n-th next commit / state save (counted from now) throws.
    func failCommit(onCall n: Int) { lock.lock(); defer { lock.unlock() }; failCommitAt = commitCalls + n }
    func failStateSave(onCall n: Int) { lock.lock(); defer { lock.unlock() }; failStateAt = stateCalls + n }

    func commit(changed: [CloudRecord], deletedNames: [String]) throws {
        lock.lock(); defer { lock.unlock() }
        commitCalls += 1
        if failCommitAt == commitCalls { failCommitAt = nil; throw SinkFailure(what: "commit") }
        _allChanged += changed; _deleted += deletedNames
        _commitSizes.append(changed.count + deletedNames.count)
        _log.append("commit")
    }

    func saveEngineState(_ state: Data) throws {
        lock.lock(); defer { lock.unlock() }
        stateCalls += 1
        if failStateAt == stateCalls { failStateAt = nil; throw SinkFailure(what: "state") }
        _lastState = state
        _log.append("state")
    }

    func beginFullRefetch() throws { lock.lock(); defer { lock.unlock() }; _fullRefetches += 1; _log.append("begin") }
    func endFullRefetch() throws { lock.lock(); defer { lock.unlock() }; _log.append("end") }
}

// MARK: - the cloud of one iCloud user

enum FakeFault: Sendable, Equatable { case offline, unauthenticated, quotaExceeded }

actor FakeCloudKitAccount {
    struct Version {
        var record: CloudRecord        // without system fields; asset fields point at server-side files
        var tag: String
        var index: Int
        var bytes: Int
    }

    nonisolated let userRecordName: String
    nonisolated let userHash: String
    nonisolated let id = UUID()
    let maxAssetBytes: Int
    private let root: URL

    private(set) var zonePresent = false
    private(set) var lastRemoval: ZoneRemoval?
    private var epoch = 0
    private var history: [String: [Version]] = [:]
    private var tombstones: [String: Int] = [:]
    private var journalIndex = 0
    private var quotaBytes: Int?
    private var limitItems = 400, limitBytes = 2_000_000
    private var offered: Set<Data> = []
    private var autoPush = false
    private var listeners: [UUID: FakeCloudKitDevice] = [:]

    init(user: String = "fake-user", maxAssetBytes: Int = SyncWire.maximumBlobBytes) {
        userRecordName = user
        userHash = SHA256.hash(data: Data(user.utf8)).map { String(format: "%02x", $0) }.joined()
        self.maxAssetBytes = maxAssetBytes
        root = FileManager.default.temporaryDirectory.appendingPathComponent("fake-ck-cloud-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // inspection

    var recordNames: [String] { history.keys.sorted() }
    var usedBytes: Int { history.values.reduce(0) { $0 + ($1.last?.bytes ?? 0) } }
    var currentEpoch: Int { epoch }
    var currentIndex: Int { journalIndex }
    func versionCount(of name: String) -> Int { history[name]?.count ?? 0 }
    func record(named name: String) -> CloudRecord? { history[name]?.last.map(serverView) }
    func exceedsLimits(count: Int, bytes: Int) -> Bool { count > limitItems || bytes > limitBytes }
    func isOffered(_ systemFields: Data?) -> Bool { systemFields.map { offered.contains($0) } ?? false }

    // configuration and server-side faults

    func createZone() { zonePresent = true; epoch += 1; journalIndex = 0 }
    func setQuota(bytes: Int?) { quotaBytes = bytes }
    func setLimits(items: Int, bytes: Int) { limitItems = items; limitBytes = bytes }
    func setAutoPush(_ on: Bool) { autoPush = on }
    func register(_ device: FakeCloudKitDevice, id: UUID) { listeners[id] = device }
    func unregister(id: UUID) { listeners[id] = nil }

    /// [doc] The zone and everything in it are gone; devices learn on their next fetch or save (`zoneNotFound`).
    func removeZone(reason: ZoneRemoval = .deleted) {
        zonePresent = false; lastRemoval = reason
        history = [:]; tombstones = [:]
    }

    /// A record deleted behind the app's back (CloudKit Console); other devices see its name in `deletedNames`.
    func removeRecord(_ name: String) { deleteRecords([name]) }

    func deleteRecords(_ names: [String]) {
        for name in names where history[name] != nil {
            history[name] = nil
            journalIndex += 1
            tombstones[name] = journalIndex
        }
    }

    /// Another client changed one field of the stored record (new tag).
    func corrupt(record name: String, field: String) {
        guard var version = history[name]?.last else { return }
        switch version.record.fields[field] {
        case .bytes(var data)?: if data.isEmpty { data.append(0xFF) } else { data[0] ^= 0xFF }; version.record.fields[field] = .bytes(data)
        case .string(let s)?: version.record.fields[field] = .string(s + "x")
        case .int(let i)?: version.record.fields[field] = .int(i &+ 1)
        case .strings(let list)?: version.record.fields[field] = .strings(list + ["x"])
        case .asset(let url)?:
            var data = (try? Data(contentsOf: url)) ?? Data()
            if data.isEmpty { data.append(0xFF) } else { data[0] ^= 0xFF }
            let copy = root.appendingPathComponent(UUID().uuidString)
            try? data.write(to: copy)
            version.record.fields[field] = .asset(copy)
        case nil: return
        }
        append(version.record)
    }

    /// A newer app wrote this record with a format version this build does not know.
    func injectUnsupportedVersion(record name: String) {
        guard var version = history[name]?.last else { return }
        version.record.fields["v"] = .int(99)
        append(version.record)
    }

    /// The stale-parent trap: hand out the server's current system fields so a careless caller can retry with them. The tag
    /// is accepted if used (the cloud cannot know the sender's ancestor is older); the sending device logs `usedOfferedTag`.
    func offerFreshTag(for name: String) -> Data? {
        guard let version = history[name]?.last else { return nil }
        let fields = systemFields(name: name, tag: version.tag)
        offered.insert(fields)
        return fields
    }

    // the cloud's own operations

    private func systemFields(name: String, tag: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["fake": 1, "zone": "TheoNotes", "name": name, "tag": tag], options: [.sortedKeys])
    }

    private func parse(_ data: Data) -> (name: String, tag: String)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["fake"] as? Int == 1,
              let name = object["name"] as? String, let tag = object["tag"] as? String else { return nil }
        return (name, tag)
    }

    private func serverView(_ version: Version) -> CloudRecord {
        var record = version.record
        record.systemFields = systemFields(name: record.name, tag: version.tag)
        return record
    }

    private func assetBytes(_ record: CloudRecord) -> Int {
        record.fields.values.reduce(0) { total, value in
            guard case .asset(let url) = value else { return total }
            return total + ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
        }
    }

    @discardableResult
    private func append(_ record: CloudRecord) -> Version {
        journalIndex += 1
        tombstones[record.name] = nil
        let version = Version(record: record, tag: UUID().uuidString, index: journalIndex, bytes: record.approximateSize + assetBytes(record))
        history[record.name, default: []].append(version)
        return version
    }

    /// Server-side copy of every asset at save time: the local file may go away afterwards. [doc: CKAsset "CloudKit saves both the record and the asset"]
    private func copyAssets(_ record: CloudRecord) throws -> CloudRecord {
        var copy = record
        copy.systemFields = nil
        for (key, value) in record.fields {
            guard case .asset(let url) = value else { continue }
            if failAssetCopy { failAssetCopy = false; throw CloudSyncError.failed(code: "assetCopy") }
            let target = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: url, to: target)
            copy.fields[key] = .asset(target)
        }
        return copy
    }

    private func discardCopies(_ records: [CloudRecord]) {
        for record in records {
            for value in record.fields.values { if case .asset(let url) = value { try? FileManager.default.removeItem(at: url) } }
        }
    }

    nonisolated var rootPath: String { root.path }
    private var failAssetCopy = false
    /// The server fails to store the next asset it copies (disk or transfer problem).
    func failNextAssetCopy() { failAssetCopy = true }

    /// nil means the save would succeed. `pendingDelta` is the net byte growth of earlier saves of the same atomic transaction.
    private func evaluate(_ save: CloudSave, pendingDelta: Int) -> CloudSaveOutcome? {
        let record = save.record
        guard zonePresent else { return .zoneNotFound }
        if let fields = record.systemFields {
            guard let parsed = parse(fields), parsed.name == record.name else { return .failed(code: "invalidArguments") }
        }
        for value in record.fields.values {
            guard case .asset(let url) = value else { continue }
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int else { return .failed(code: "assetFileNotFound") }
            if size > maxAssetBytes { return .failed(code: "assetTooLarge") }   // [G0] the real limit and error code
        }
        let existing = history[record.name]?.last
        switch (existing, record.systemFields) {
        case (nil, .some): return .unknownItem                                    // [G0] absent record with a tag
        case (.some(let current), nil): return .serverRecordChanged(server: serverView(current))   // create on an existing name [G0]
        case (.some(let current), .some(let fields)):
            if parse(fields)?.tag != current.tag { return .serverRecordChanged(server: serverView(current)) }   // [doc] change-tag compare
        case (nil, nil): break
        }
        if let quota = quotaBytes {
            let newBytes = record.approximateSize + assetBytes(record)
            if usedBytes + pendingDelta - (existing?.bytes ?? 0) + newBytes > quota { return .quotaExceeded }   // [doc]
        }
        return nil
    }

    private func growth(of save: CloudSave) -> Int {
        save.record.approximateSize + assetBytes(save.record) - (history[save.record.name]?.last?.bytes ?? 0)
    }

    /// One CKModifyRecordsOperation worth of saves. `atomic` models a custom zone with isAtomic = true: one failure fails the rest
    /// with `batchRequestFailed`; the engine path (atomicByZone = false) is independent per record. [doc]
    func commit(_ saves: [CloudSave], atomic: Bool, from sender: UUID) async -> [CloudSaveOutcome] {
        var outcomes: [CloudSaveOutcome] = []
        var landed = false
        if atomic {
            // Stage and validate the whole transaction (cumulative quota, asset copies), then commit all or nothing.
            var verdicts: [CloudSaveOutcome?] = []
            var delta = 0
            for save in saves {
                let verdict = evaluate(save, pendingDelta: delta)
                verdicts.append(verdict)
                if verdict == nil { delta += growth(of: save) }
            }
            if verdicts.contains(where: { $0 != nil }) { return verdicts.map { $0 ?? .failed(code: "batchRequestFailed") } }
            var staged: [CloudRecord] = []
            for (position, save) in saves.enumerated() {
                do { staged.append(try copyAssets(save.record)) } catch {
                    discardCopies(staged)
                    return saves.indices.map { $0 == position ? .failed(code: "assetFileNotFound") : .failed(code: "batchRequestFailed") }
                }
            }
            for record in staged {
                let version = append(record)
                outcomes.append(.saved(systemFields: systemFields(name: record.name, tag: version.tag)))
            }
            landed = !saves.isEmpty
        } else {
            for save in saves {
                if let failure = evaluate(save, pendingDelta: 0) { outcomes.append(failure); continue }
                do {
                    let stored = try copyAssets(save.record)
                    let version = append(stored)
                    outcomes.append(.saved(systemFields: systemFields(name: stored.name, tag: version.tag)))
                    landed = true
                } catch {
                    outcomes.append(.failed(code: "assetFileNotFound"))
                }
            }
        }
        if landed && autoPush {
            for (id, device) in listeners where id != sender { await device.receiveRemotePush() }
        }
        return outcomes
    }

    struct Change { let index: Int; let record: CloudRecord?; let deletedName: String? }

    /// Everything after `token` in oldest-to-newest order, one entry per record (its latest version). `nil` is a full fetch: current records only.
    func changes(after token: Int?) -> [Change] {
        var list: [Change] = []
        for (_, versions) in history {
            guard let current = versions.last, current.index > (token ?? 0) else { continue }
            list.append(Change(index: current.index, record: serverView(current), deletedName: nil))
        }
        if token != nil {
            for (name, index) in tombstones where index > (token ?? 0) { list.append(Change(index: index, record: nil, deletedName: name)) }
        }
        return list.sorted { $0.index < $1.index }
    }

    func previousVersion(of name: String) -> CloudRecord? {
        guard let versions = history[name], versions.count >= 2 else { return nil }
        return serverView(versions[versions.count - 2])
    }
}

// MARK: - one device

actor FakeCloudKitDevice: CloudKitGateway {
    struct SendLogEntry: Equatable {
        let attemptId: String, recordName: String, accountGeneration: Int64
        let hadSystemFields: Bool, usedOfferedTag: Bool
    }

    private enum Operation { case prepare, send, fetch, other }

    nonisolated let events: AsyncStream<CloudGatewayEvent>
    private let continuation: AsyncStream<CloudGatewayEvent>.Continuation
    private let id = UUID()
    private let store: any CloudGatewayStore
    private let disk: FakeDeviceDisk
    private let crash: CrashPoint
    /// The system's staging area: files here can vanish at any time. Persisted results never hold a path inside it.
    nonisolated let stagingDirectory: URL
    private var staging: URL { stagingDirectory }
    private var sending = false

    private var account: FakeCloudKitAccount?
    private var lastAccountId: UUID?
    private var stateOverride: CloudAccountState?
    private var fenced = false
    private(set) var engineState: Data?

    // knobs
    private var autoSend = true
    private var fetchBatchSize = 100
    private var sendBatchItems = 100
    private var sendBatchBytes = 1_048_576
    private var atomicByZone = false
    private var deliversBlobPartAssets = true   // [G0 A3] CKSyncEngine hands over the assets of the records it fetches eagerly (measured: 252 MB)
    /// [G0 A3, ] `BlobPart` records live in a second zone that the engine is told not to fetch: `fetchChanges` never
    /// delivers them (nor their deletions); they are read by name with `fetch`. A test can switch the zone on to model a newer or
    /// misbehaving peer that puts parts into the fetched zone.
    private var fetchesBlobZone = false

    // armed faults
    private var faults: [FakeFault] = []
    private var loseNext: LostResponse?
    private var lateArmed = false
    private var expireToken = false
    private var redeliver = false
    private var reorder: Reorder?
    private var staleSpecs: [(name: String, afterBatches: Int)] = []
    private var delaySpecs: [(name: String, byBatches: Int)] = []
    private var evictBeforePin = false
    private var failStaging = false
    private var parked: [(save: CloudSave, account: FakeCloudKitAccount)] = []

    // logs
    private(set) var eventLog: [CloudGatewayEvent] = []
    private(set) var sendLog: [SendLogEntry] = []
    private(set) var deleteLog: [String] = []
    private(set) var operationLog: [String] = []
    private(set) var stagedFiles: [URL] = []

    enum LostResponse: Sendable { case offline, silence }
    enum Reorder { case permutation([Int]), seed(UInt64) }

    init(account: FakeCloudKitAccount?, store: any CloudGatewayStore, disk: FakeDeviceDisk = FakeDeviceDisk(), engineState: Data? = nil,
         crash: CrashPoint = .never) {
        self.account = account; self.store = store; self.disk = disk; self.engineState = engineState; self.crash = crash
        (events, continuation) = AsyncStream.makeStream()
        stagingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("fake-ck-staging-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        lastAccountId = account?.id
    }

    // MARK: knobs and fault injection

    func setAutoSend(_ on: Bool) { autoSend = on }
    func setFetchBatchSize(_ n: Int) { fetchBatchSize = max(1, n) }
    func setAtomicByZone(_ on: Bool) { atomicByZone = on }
    func setDeliversBlobPartAssets(_ on: Bool) { deliversBlobPartAssets = on }
    func setFetchesBlobZone(_ on: Bool) { fetchesBlobZone = on }
    func setAccountState(_ state: CloudAccountState) { stateOverride = state; emit(.accountChanged(state)) }
    var pendingAttemptIds: [String] { disk.pending.map(\.attemptId) }

    /// The next network operation fails: `offline` and `unauthenticated` hit any operation, `quotaExceeded` only a send.
    func failNext(_ fault: FakeFault) { faults.append(fault) }
    /// The next save commits on the server, but the device is told `offline` (or nothing at all with `.silence`).
    func loseNextResponseAfterCommit(report: LostResponse = .offline) { loseNext = report }
    /// The next send is still on the wire when the account is cancelled/switched; it commits to its original account on `deliverLateCompletions()`. [doc: cancelOperations]
    func completeLateAfterCancel() { lateArmed = true }
    func expireTokenNextFetch() { expireToken = true }
    func redeliverBatch() { redeliver = true }
    func reorderBatch(_ permutation: [Int]) { reorder = .permutation(permutation) }
    func reorderBatch(seed: UInt64) { reorder = .seed(seed) }
    /// The record's previous version is delivered again `afterBatches` batches after the batch that carries its current version
    /// (0: right behind it in the same batch). Dropped if the record has no previous version. [plan-doc: unordered delivery]
    func deliverStaleVersion(of name: String, afterBatches: Int = 0) { staleSpecs.append((name, afterBatches)) }
    /// The record's current version is held back and delivered `byBatches` batches late. The saved state never passes it.
    func delayDelivery(of name: String, byBatches: Int) { delaySpecs.append((name, byBatches)) }
    /// The system clears the staging area after a conflict record was staged and before the gateway pinned its assets.
    func evictStagedAssetsBeforePinning() { evictBeforePin = true }
    /// The next staging copy fails (disk full, source gone).
    func failNextStaging() { failStaging = true }
    func dropEngineState() { engineState = nil }

    func setQuota(bytes: Int?) async { await account?.setQuota(bytes: bytes) }
    func setLimits(items: Int, bytes: Int) async { await account?.setLimits(items: items, bytes: bytes) }
    func removeZone(reason: ZoneRemoval = .deleted) async { await account?.removeZone(reason: reason) }
    func removeRecord(_ name: String) async { await account?.removeRecord(name) }
    func corrupt(record: String, field: String) async { await account?.corrupt(record: record, field: field) }
    func injectUnsupportedVersion(record: String) async { await account?.injectUnsupportedVersion(record: record) }
    func offerFreshTag(for name: String) async -> Data? { await account?.offerFreshTag(for: name) }

    /// Deletes every staged asset file this device was handed, like the system clearing the staging area. [doc: CKAsset]
    func evictStagedAssets() {
        for url in stagedFiles { try? FileManager.default.removeItem(at: url) }
        stagedFiles = []
    }

    func pushRemoteChange() { emit(.remoteChange) }
    func receiveRemotePush() { emit(.remoteChange) }

    // MARK: account events

    func signOut() {
        fenced = true
        stateOverride = nil
        disk.pending = []
        let old = account
        account = nil
        if let old { let id = id; Task { await old.unregister(id: id) } }
        emit(.accountChanged(.noAccount))
    }

    func signIn(user: FakeCloudKitAccount) {
        if user.id != lastAccountId { resetForNewAccount() }
        account = user; lastAccountId = user.id; stateOverride = nil; fenced = true
        emit(.accountChanged(.available(userHash: user.userHash)))
    }

    func switchAccount(to user: FakeCloudKitAccount) {
        resetForNewAccount()
        account = user; lastAccountId = user.id; stateOverride = nil; fenced = true
        emit(.accountChanged(.available(userHash: user.userHash)))
    }

    func restrict() { stateOverride = .restricted; fenced = true; emit(.accountChanged(.restricted)) }

    /// [doc] "When the logged-in account changes, the sync engine resets its internal state, including unsaved changes" (CKSyncEngine accountChange).
    private func resetForNewAccount() {
        disk.pending = []
        engineState = nil
        try? store.setZoneState(.unknown)
    }

    // MARK: CloudKitGateway

    private func currentAccountState() -> CloudAccountState {
        if let stateOverride { return stateOverride }
        guard let account else { return .noAccount }
        return .available(userHash: account.userHash)
    }

    func accountState() async -> CloudAccountState { currentAccountState() }

    func prepare() async throws -> CloudAccountState {
        fenced = false
        if let fault = takeFault(for: .prepare) { throw error(for: fault) }
        let state = currentAccountState()
        guard case .available = state, let account else { return state }
        await account.register(self, id: id)
        let present = await account.zonePresent
        switch try store.zoneState() {
        case .unknown:
            if !present { await account.createZone() }
            try store.setZoneState(.created)
        case .created:
            if !present { try await noteZoneRemoved(account) }
        case .removed: break
        }
        return state
    }

    func submit(_ saves: [CloudSave]) async throws {
        disk.pending += saves
        if autoSend { try await sendPending() }
    }

    /// A save leaves the durable pending list only after its outcome is durable in the store (or the device is told nothing at all).
    /// A failure after the send, or while storing, leaves the rest pending; the resend of a landed save conflicts and is resolved by.
    func sendPending() async throws {
        if sending { return }
        sending = true
        defer { sending = false }
        while !disk.pending.isEmpty {
            let batch = peekBatch()
            let outcomes = await send(batch)
            try crash.hit("afterSend")
            for (save, outcome) in zip(batch, outcomes) {
                if let outcome {
                    // Like the live gateway: a result the durable fence or the generation refuses is moot and dropped.
                    do { try store.recordSendResult(attemptId: save.attemptId, accountGeneration: save.accountGeneration, outcome: outcome) }
                    catch CloudSyncStoreError.accountFenced {}
                    catch CloudSyncStoreError.staleAccountGeneration {}
                }
                disk.removeFirst(attemptId: save.attemptId)
            }
        }
    }

    func fetchChanges(into sink: any CloudChangeSink) async throws {
        if let fault = takeFault(for: .fetch) { throw error(for: fault) }
        try requireOnline()
        guard let account else { throw CloudSyncError.unauthenticated }
        guard await account.zonePresent else {
            if case .created = try store.zoneState() { try await noteZoneRemoved(account) }
            return
        }
        let epoch = await account.currentEpoch
        var token = decodeToken(engineState, account: account.id, epoch: epoch)
        if expireToken { expireToken = false; token = nil }       // [doc] changeTokenExpired: drop the token, refetch everything
        let full = token == nil
        let changes = await account.changes(after: token).filter { fetchesBlobZone || !Self.isBlobZoneChange($0) }
        let finalToken = await account.currentIndex
        let plan = await buildPlan(changes, account: account)
        defer { clearAdversary() }

        if full { try sink.beginFullRefetch() }
        var deferredState: Data?
        for (position, items) in plan.enumerated() {
            let stateAfter = encodeToken(tokenAfter(batch: position, plan: plan, finalToken: finalToken), account: account.id, epoch: epoch)
            try deliver(items, to: sink)
            if full { deferredState = stateAfter } else { try saveState(stateAfter, to: sink) }
            if redeliver && position == 0 { redeliver = false; try deliver(items, to: sink) }
        }
        if changes.isEmpty && full { deferredState = encodeToken(finalToken, account: account.id, epoch: epoch) }
        if full {
            try sink.endFullRefetch()
            if let deferredState { try saveState(deferredState, to: sink) }
        }
    }

    private static func isBlobZoneChange(_ change: FakeCloudKitAccount.Change) -> Bool {
        change.record?.type == .blobPart || change.deletedName?.hasPrefix("b.") == true
    }

    func fetch(_ names: [String], keys: [String]?) async throws -> [String: CloudRecord] {
        if let fault = takeFault(for: .other) { throw error(for: fault) }
        try requireOnline()
        guard let account else { throw CloudSyncError.unauthenticated }
        var result: [String: CloudRecord] = [:]
        for name in names {
            guard var record = await account.record(named: name) else { continue }
            if let keys { record.fields = record.fields.filter { keys.contains($0.key) } }
            result[name] = try stage(record)
        }
        return result
    }

    func delete(_ names: [String]) async throws {
        if let fault = takeFault(for: .other) { throw error(for: fault) }
        try requireOnline()
        guard let account else { throw CloudSyncError.unauthenticated }
        deleteLog += names
        await account.deleteRecords(names)
    }

    /// The atomic form the live gateway must offer (Task 15, C1): the zone of the account the device is signed in to NOW is deleted
    /// only if that account is `userHash`; otherwise nothing is deleted and the call is refused as `fenced`.
    func deleteZone(expecting userHash: String) async throws {
        guard let account, account.userHash == userHash, !fenced else { throw CloudSyncError.fenced }
        try await deleteZone()
    }

    func deleteZone() async throws {
        if let fault = takeFault(for: .other) { throw error(for: fault) }
        try requireOnline()
        guard let account else { throw CloudSyncError.unauthenticated }
        deleteLog.append("zone")
        await account.removeZone(reason: .deleted)
        try store.setZoneState(.removed(.deleted))
    }

    /// A saved-engine-state-free restart: parked wire operations that finish after the account changed.
    func deliverLateCompletions() async {
        let late = parked
        parked = []
        for entry in late {
            let outcomes = await commitSplit([entry.save], to: entry.account)
            for (save, outcome) in zip([entry.save], outcomes) {
                try? store.recordSendResult(attemptId: save.attemptId, accountGeneration: save.accountGeneration, outcome: outcome)
            }
        }
    }

    // MARK: internals

    private func emit(_ event: CloudGatewayEvent) {
        eventLog.append(event)
        continuation.yield(event)
    }

    private func noteZoneRemoved(_ account: FakeCloudKitAccount) async throws {
        let reason = await account.lastRemoval ?? .deleted
        try store.setZoneState(.removed(reason))
        emit(.zoneRemoved(reason))
    }

    private func requireOnline() throws {
        if fenced { throw CloudSyncError.fenced }
        switch currentAccountState() {
        case .available: break
        case .noAccount, .restricted: throw CloudSyncError.unauthenticated
        case .temporarilyUnavailable, .couldNotDetermine: throw CloudSyncError.offline
        }
    }

    private func takeFault(for operation: Operation) -> FakeFault? {
        guard let index = faults.firstIndex(where: { $0 != .quotaExceeded || operation == .send }) else { return nil }
        return faults.remove(at: index)
    }

    private func error(for fault: FakeFault) -> CloudSyncError {
        switch fault { case .offline: return .offline; case .unauthenticated: return .unauthenticated; case .quotaExceeded: return .quotaExceeded }
    }

    private func outcome(for fault: FakeFault) -> CloudSaveOutcome {
        switch fault { case .offline: return .offline; case .unauthenticated: return .unauthenticated; case .quotaExceeded: return .quotaExceeded }
    }

    private func peekBatch() -> [CloudSave] {
        var batch: [CloudSave] = []
        var bytes = 0
        for next in disk.pending {
            guard batch.count < sendBatchItems, batch.isEmpty || bytes + next.record.approximateSize <= sendBatchBytes else { break }
            batch.append(next); bytes += next.record.approximateSize
        }
        return batch
    }

    /// nil entries: the device never learns an outcome (silence, or still on the wire).
    private func send(_ batch: [CloudSave]) async -> [CloudSaveOutcome?] {
        if let fault = takeFault(for: .send) { operationLog.append("send:\(batch.count):\(fault)"); return batch.map { _ in outcome(for: fault) } }
        if fenced { return batch.map { _ in .fenced } }
        switch currentAccountState() {
        case .available: break
        case .noAccount, .restricted: return batch.map { _ in .unauthenticated }
        case .temporarilyUnavailable, .couldNotDetermine: return batch.map { _ in .offline }
        }
        guard let account else { return batch.map { _ in .unauthenticated } }
        for save in batch {
            sendLog.append(SendLogEntry(attemptId: save.attemptId, recordName: save.record.name, accountGeneration: save.accountGeneration,
                                        hadSystemFields: save.record.systemFields != nil,
                                        usedOfferedTag: await account.isOffered(save.record.systemFields)))
        }
        if lateArmed {
            lateArmed = false
            parked += batch.map { ($0, account) }
            return batch.map { _ in nil }
        }
        let outcomes = await commitSplit(batch, to: account)
        if let report = loseNext {
            loseNext = nil
            return outcomes.map { _ in report == .offline ? .offline : nil }
        }
        return outcomes
    }

    /// The live gateway's duty on `limitExceeded`: split the operation in half and retry both halves. [doc: CKError.limitExceeded]
    private func commitSplit(_ saves: [CloudSave], to account: FakeCloudKitAccount) async -> [CloudSaveOutcome] {
        let bytes = saves.reduce(0) { $0 + $1.record.approximateSize }
        if await account.exceedsLimits(count: saves.count, bytes: bytes) {
            operationLog.append("send:\(saves.count):limitExceeded")
            if saves.count == 1 { return [.limitExceeded] }
            let mid = saves.count / 2
            let left = await commitSplit(Array(saves[..<mid]), to: account)
            let right = await commitSplit(Array(saves[mid...]), to: account)
            return left + right
        }
        operationLog.append("send:\(saves.count):ok")
        let outcomes = await account.commit(saves, atomic: atomicByZone, from: id)
        return outcomes.map { outcome in
            guard case .serverRecordChanged(let server) = outcome else { return outcome }
            // [G0] assets in the conflict record. The result is persisted, so its assets are staged and then pinned into the
            // gateway's own durable folder before the result is recorded; if that fails the result says so.
            do { return .serverRecordChanged(server: try pin(try stage(server))) } catch { return .failed(code: "conflictAssetUnavailable") }
        }
    }

    /// Copies each staged asset into the pin directory and verifies the size; the staging copy may already be gone.
    private func pin(_ record: CloudRecord) throws -> CloudRecord {
        if evictBeforePin { evictBeforePin = false; evictStagedAssets() }
        var copy = record
        for (key, value) in record.fields {
            guard case .asset(let url) = value else { continue }
            let target = disk.pinDirectory.appendingPathComponent("\(UUID().uuidString)-\(key)")
            guard (try? FileManager.default.copyItem(at: url, to: target)) != nil else { throw CloudSyncError.failed(code: "assetNotAvailable") }
            let sizeBefore = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
            let sizeAfter = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) ?? -2
            guard sizeBefore == sizeAfter else { try? FileManager.default.removeItem(at: target); throw CloudSyncError.failed(code: "assetNotAvailable") }
            copy.fields[key] = .asset(target)
        }
        return copy
    }

    // fetch helpers

    private func encodeToken(_ index: Int, account: UUID, epoch: Int) -> Data {
        try! JSONSerialization.data(withJSONObject: ["a": account.uuidString, "e": epoch, "t": index], options: [.sortedKeys])
    }

    private func decodeToken(_ data: Data?, account: UUID, epoch: Int) -> Int? {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["a"] as? String == account.uuidString, object["e"] as? Int == epoch, let token = object["t"] as? Int else { return nil }
        return token
    }

    /// Armed adversary faults apply to one fetch only.
    private func clearAdversary() {
        reorder = nil; staleSpecs = []; delaySpecs = []; redeliver = false; expireToken = false
    }

    private func saveState(_ state: Data, to sink: any CloudChangeSink) throws {
        try sink.saveEngineState(state)
        engineState = state
    }

    private func deliver(_ items: [PlanItem], to sink: any CloudChangeSink) throws {
        let changed = try items.compactMap { $0.record }.map { try stageForFetch($0) }
        let deleted = items.compactMap { $0.name }
        try sink.commit(changed: changed, deletedNames: deleted)
    }

    private func stageForFetch(_ record: CloudRecord) throws -> CloudRecord {
        var copy = record
        if !deliversBlobPartAssets && record.type == .blobPart { copy.fields["asset"] = nil }
        return try stage(copy)
    }

    /// Copies each asset into this device's staging area; the files can later vanish (`evictStagedAssets`). [doc: CKAsset]
    /// A copy that fails fails the delivery: a server-side path is never handed out (it would never be evicted).
    private func stage(_ record: CloudRecord) throws -> CloudRecord {
        var copy = record
        for (key, value) in record.fields {
            guard case .asset(let url) = value else { continue }
            if failStaging { failStaging = false; throw CloudSyncError.failed(code: "assetNotAvailable") }
            let target = staging.appendingPathComponent("\(UUID().uuidString)-\(key)")
            guard (try? FileManager.default.copyItem(at: url, to: target)) != nil else { throw CloudSyncError.failed(code: "assetNotAvailable") }
            stagedFiles.append(target)
            copy.fields[key] = .asset(target)
        }
        return copy
    }

    struct PlanItem {
        var record: CloudRecord?
        var name: String?
        /// Journal position of the change; nil for a stale re-delivery.
        var index: Int?
        var recordName: String { record?.name ?? name ?? "" }
    }

    /// The delivery plan of one fetch: pages of the sorted delta, then the armed adversary applied across pages. [plan-doc: unordered delivery]
    private func buildPlan(_ changes: [FakeCloudKitAccount.Change], account: FakeCloudKitAccount) async -> [[PlanItem]] {
        var plan: [[PlanItem]] = stride(from: 0, to: changes.count, by: fetchBatchSize).map { start in
            changes[start..<min(start + fetchBatchSize, changes.count)].map { PlanItem(record: $0.record, name: $0.deletedName, index: $0.index) }
        }
        func position(of name: String) -> (batch: Int, item: Int)? {
            for (b, batch) in plan.enumerated() {
                if let i = batch.firstIndex(where: { $0.index != nil && $0.recordName == name }) { return (b, i) }
            }
            return nil
        }
        for spec in delaySpecs {
            guard let at = position(of: spec.name) else { continue }
            let item = plan[at.batch].remove(at: at.item)
            let target = at.batch + spec.byBatches
            while plan.count <= target { plan.append([]) }
            plan[target].append(item)
        }
        for spec in staleSpecs {
            guard let stale = await account.previousVersion(of: spec.name) else { continue }
            let anchor = position(of: spec.name)
            let target = (anchor?.batch ?? 0) + spec.afterBatches
            while plan.count <= target { plan.append([]) }
            let item = PlanItem(record: stale, name: nil, index: nil)
            if let anchor, anchor.batch == target { plan[target].insert(item, at: anchor.item + 1) } else { plan[target].append(item) }
        }
        if let first = plan.firstIndex(where: { $0.count >= 2 }) { plan[first] = applyReorder(plan[first]) }
        return plan.filter { !$0.isEmpty }
    }

    /// The state after batch `k` may not pass the oldest change still to be delivered.
    private func tokenAfter(batch k: Int, plan: [[PlanItem]], finalToken: Int) -> Int {
        let undelivered = plan[(k + 1)...].flatMap { $0 }.compactMap(\.index)
        guard let oldest = undelivered.min() else { return finalToken }
        return min(finalToken, oldest - 1)
    }

    private func applyReorder(_ items: [PlanItem]) -> [PlanItem] {
        guard let reorder, items.count >= 2 else { return items }
        self.reorder = nil
        switch reorder {
        case .permutation(let permutation):
            guard permutation.count == items.count, Set(permutation) == Set(0..<items.count) else { return items }
            return permutation.map { items[$0] }
        case .seed(let seed):
            var state = seed
            func next() -> UInt64 {   // SplitMix64
                state &+= 0x9E3779B97F4A7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
                z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
                return z ^ (z >> 31)
            }
            var shuffled = items
            for i in stride(from: shuffled.count - 1, to: 0, by: -1) { shuffled.swapAt(i, Int(next() % UInt64(i + 1))) }
            return shuffled
        }
    }
}
