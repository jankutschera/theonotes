// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

// Devices for the coordinator tests (Task 10): a real library in a temporary folder, the real `CloudSyncStore`, a `FakeCloudKitDevice`
// on a shared `FakeCloudKitAccount`, an in-memory iCloud Keychain shared by every device of the person, and the REAL coordinator.
// Nothing here is a stand-in for the code under test.

/// Forwards to the fake device and remembers what was saved, in order; a test can also make it hold or fail a call.
final class CoordGateway: CloudKitGateway, @unchecked Sendable {
    let inner: FakeCloudKitDevice
    private let lock = NSLock()
    private var _saves: [CloudSave] = []
    private var _calls: [String] = []
    private var _deletes: [[String]] = []
    nonisolated let events: AsyncStream<CloudGatewayEvent>
    init(_ inner: FakeCloudKitDevice) { self.inner = inner; events = inner.events }

    var saves: [CloudSave] { lock.withLock { _saves } }
    var savedNames: [String] { saves.map(\.record.name) }
    var calls: [String] { lock.withLock { _calls } }
    var callCount: Int { lock.withLock { _calls.count } }
    var deletes: [[String]] { lock.withLock { _deletes } }
    private func note(_ name: String) { lock.withLock { _calls.append(name) } }

    func prepare() async throws -> CloudAccountState { note("prepare"); return try await inner.prepare() }
    func accountState() async -> CloudAccountState { await inner.accountState() }
    func submit(_ batch: [CloudSave]) async throws {
        lock.withLock { _calls.append("submit"); _saves += batch }
        try await inner.submit(batch)
    }
    func fetchChanges(into sink: any CloudChangeSink) async throws { note("fetchChanges"); try await inner.fetchChanges(into: sink) }
    func fetch(_ names: [String], keys: [String]?) async throws -> [String: CloudRecord] {
        note("fetch:" + (keys?.joined(separator: ",") ?? "all")); return try await inner.fetch(names, keys: keys)
    }
    func delete(_ names: [String]) async throws { lock.withLock { _calls.append("delete"); _deletes.append(names) }; try await inner.delete(names) }
    func deleteZone() async throws { note("deleteZone"); try await inner.deleteZone() }
    func deleteZone(expecting userHash: String) async throws { note("deleteZone"); try await inner.deleteZone(expecting: userHash) }
}

/// A named hold: the coordinator calls `await hold.pass(name)` at its steps; a test decides what happens there.
final class CoordHooks: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [String: @Sendable () async -> Void] = [:]
    private var seen: [String] = []
    var steps: [String] { lock.withLock { seen } }
    private var every: (@Sendable (String) async -> Void)?
    func on(_ name: String, _ action: @escaping @Sendable () async -> Void) { lock.withLock { actions[name] = action } }
    /// Runs at every step, before the action named for it.
    func onEveryStep(_ action: @escaping @Sendable (String) async -> Void) { lock.withLock { every = action } }
    func clear() { lock.withLock { actions = [:]; every = nil } }
    func pass(_ name: String) async {
        let (action, all) = lock.withLock { () -> ((@Sendable () async -> Void)?, (@Sendable (String) async -> Void)?) in seen.append(name); return (actions[name], every) }
        await all?(name)
        await action?()
    }
}

let coordConfiguration = CloudKitConfiguration(containerIdentifier: "iCloud.test.theonotes")

final class CoordDevice: CloudSyncLibrary, @unchecked Sendable {
    let name: String
    let paths: AppPaths
    let database: AppDatabase
    var db: AppDatabase { database }
    let store: CloudSyncStore
    let seedStore: InMemoryCloudKeySeedStore
    let fake: FakeCloudKitDevice
    let gateway: CoordGateway
    let disk = FakeDeviceDisk()
    /// Armed boundaries of the fake cloud connection itself (`afterSend`).
    let fakeCrash = CrashPoint()
    let hooks = CoordHooks()
    var syncPolicy: SyncLaunchPolicy = .enabled
    /// The host's editor coordination; nil (no editors) unless a test installs one.
    let commits = LockedBox<(any SyncCommitCoordinator)?>(nil)
    var commitCoordinator: (any SyncCommitCoordinator)? { commits.value }
    private let lock = NSLock()
    private var _backups = 0
    private var _passwordChecks = 0
    var realBackups = false
    let needsJournalKey = LockedBox(false)
    let realJournalRecovery = LockedBox(false)
    let offerSealedMoveAside = LockedBox(false)
    let journalAccess = LockedBox<LockedNoteAccess?>(nil)
    let journalRetirement = LockedBox<MissingJournalRecovery.Retirement?>(nil)
    let journalRecoveries = LockedBox(0)
    var noteStore: NoteStore { NoteStore(db: database, notifier: nil, paths: paths) }
    var backups: Int { lock.withLock { _backups } }
    var passwordChecks: Int { lock.withLock { _passwordChecks } }
    private(set) var coordinators: [CloudSyncCoordinator] = []
    var blobSettings = CloudBlobSettings(partBytes: blobMiB, timing: CloudBlobTiming(pollInterval: 0.005, outcomeTimeout: 4, cloudLookupInterval: 0.2))
    let clockValue = LockedBox<Date>(Date(timeIntervalSince1970: 1_793_300_000))

    init(_ name: String, cloud: FakeCloudKitAccount?, keychain: InMemoryCloudKeychain, root: URL? = nil) throws {
        self.name = name
        paths = AppPaths(root: root ?? FileManager.default.temporaryDirectory.appendingPathComponent("ck-coord-\(name)-\(UUID())"))
        try paths.createDirectories()
        database = try AppDatabase(path: paths.database)
        store = CloudSyncStore(database: database)
        seedStore = InMemoryCloudKeySeedStore(keychain: keychain)
        fake = FakeCloudKitDevice(account: cloud, store: store, disk: disk, crash: fakeCrash)
        gateway = CoordGateway(fake)
    }

    func cleanup() { journalAccess.value?.revoke(); try? database.pool.close(); try? FileManager.default.removeItem(at: paths.root) }

    // MARK: CloudSyncLibrary

    func journalRecoveryState() async -> CloudJournalRecoveryState {
        if realJournalRecovery.value {
            guard let report = try? await MainActor.run(body: {
                try JournalRecoveryCoordinator.recover(store: noteStore, access: journalAccess.value, liveSessionIDs: [], dirtyLiveSessionIDs: [], allowSealedMoveAside: offerSealedMoveAside.value)
            }) else { return .blocked }
            if report.keyState == .waitingForSyncKey { return .waitingForKey }
            return report.keyState != nil || report.hasUncommittedRecovery ? .blocked : .ready
        }
        return needsJournalKey.value ? .waitingForKey : .ready
    }
    func withJournalKeyInstall(_ install: @Sendable () async throws -> Bool) async throws -> Bool { try await install() }
    func offerJournalMoveAsideForUnavailableKey() async throws { offerSealedMoveAside.update { $0 = true } }
    func recoverJournalsAfterKey(password: String) async throws {
        let access = try NotePrivacy(store: noteStore).unlock(password: password)
        if realJournalRecovery.value {
            let report = try await MainActor.run {
                try JournalRecoveryCoordinator.recover(store: noteStore, access: access, liveSessionIDs: [], dirtyLiveSessionIDs: [])
            }
            journalRetirement.update { $0 = report.singles.first?.retirement }
            journalAccess.update { $0 = access }
        } else {
            access.revoke()
        }
        journalRecoveries.update { $0 += 1 }
        needsJournalKey.update { $0 = false }
    }

    func makeBackup() async throws -> String {
        lock.withLock { _backups += 1 }
        if realBackups {
            let backup = LibraryBackup(database: database, paths: paths)
            _ = try backup.createRolling()
            return try #require(try backup.localBackups().first).id
        }
        return "test-backup-\(backups)"
    }
    func verifyNotePassword(_ password: String) async throws {
        lock.withLock { _passwordChecks += 1 }
        let privacy = NotePrivacy(store: noteStore)
        try privacy.unlock(password: password).revoke()
    }

    // MARK: the coordinator

    @discardableResult
    func makeCoordinator(crash: CrashPoint = .never, gateway: (any CloudKitGateway)? = nil, configuration: CloudKitConfiguration? = coordConfiguration,
                         drainTimeout: TimeInterval = 10, appBuild: String? = nil) -> CloudSyncCoordinator {
        let hooks = self.hooks, clock = clockValue
        let coordinator = CloudSyncCoordinator(
            library: self, gateway: gateway ?? self.gateway, seeds: seedStore, configuration: configuration, blobs: blobSettings,
            clock: { clock.value }, crash: crash, checkpoint: { await hooks.pass($0) }, appBuild: appBuild, drainTimeout: drainTimeout)
        coordinators.append(coordinator)
        return coordinator
    }

    var coordinator: CloudSyncCoordinator { coordinators.last ?? makeCoordinator() }

    /// The account keys of this device as the key layer rebuilds them (seed + bundle), for tests that call the store directly.
    func liveKeys() async throws -> AccountKeys {
        let join = CloudKeyJoin(seeds: seedStore, probe: seedStore, bundles: CloudKeyBundleStore(gateway: gateway, results: store), state: store)
        return try #require(try await join.evaluate().keys)
    }

    /// The person's switch: the first run; the first device chooses to skip the recovery key (acknowledged).
    @discardableResult
    func enable(notePassword: String? = nil, recovery: RecoveryChoice? = nil, using coordinator: CloudSyncCoordinator? = nil) async throws -> CloudSyncState {
        let c = coordinator ?? self.coordinator
        return try await c.enable(recovery: try recovery ?? RecoveryChoice.skip(acknowledged: true), notePassword: notePassword)
    }

    // MARK: reading the library

    func notes() throws -> [Note] { try database.pool.read { try Note.fetchAll($0, sql: "SELECT * FROM note ORDER BY id") } }
    func note(_ id: String) throws -> Note? { try database.pool.read { try Note.fetchOne($0, key: id) } }
    func count(_ table: String) throws -> Int { try database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)")! } }
    func string(_ sql: String) throws -> String? { try database.pool.read { try String.fetchOne($0, sql: sql) } }
    func sql(_ statement: String) throws { try database.pool.write { try $0.execute(sql: statement) } }
    func dirty() throws -> [(type: String, id: String, generation: Int64)] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT entityType, localId, generation FROM sync_dirty ORDER BY entityType, localId")
                .map { ($0["entityType"], $0["localId"], $0["generation"]) }
        }
    }
    func dirtyGeneration(_ id: String, type: String = "note") throws -> Int64? {
        try database.pool.read { try Int64.fetchOne($0, sql: "SELECT generation FROM sync_dirty WHERE entityType=? AND localId=?", arguments: [type, id]) }
    }
    func edit(_ id: String, _ text: String) throws {
        let current = try #require(try note(id))
        _ = try noteStore.updateText(id: id, text: text, expectedRevision: current.revision)
    }
    func trash(_ id: String) throws { try noteStore.trash([id]) }
    func hardDelete(_ id: String) throws { try noteStore.deletePermanently([id]) }

    /// Every note with its place and a hash of its text, sorted: what "the same library" means in these tests.
    func fingerprint() throws -> [String] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, location, text FROM note ORDER BY id").map { row in
                let text: String = row["text"]
                let digest = SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
                return "\(row["id"] as String)|\(row["location"] as String)|\(digest)"
            }
        }
    }

    /// Titles of notes in Notes and Archive (a conflict copy shares its title with the original).
    func visibleTitles() throws -> [String] {
        try database.pool.read { try String.fetchAll($0, sql: "SELECT title FROM note WHERE location IN ('notes','archive') ORDER BY title") }
    }

    func conflictCopies() throws -> Int { try count("sync_conflict") }
}

/// A person with several devices on one iCloud account and one iCloud Keychain.
struct CoordWorld {
    let cloud: FakeCloudKitAccount
    let keychain: InMemoryCloudKeychain
    let devices: [CoordDevice]

    static func make(_ count: Int, user: String = "fake-user") throws -> CoordWorld {
        let cloud = FakeCloudKitAccount(user: user), keychain = InMemoryCloudKeychain()
        return CoordWorld(cloud: cloud, keychain: keychain, devices: try (0..<count).map { try CoordDevice("d\($0)", cloud: cloud, keychain: keychain) })
    }
    func cleanup() { devices.forEach { $0.cleanup() } }

    /// Syncs every device in turn until all libraries are equal and nothing is left to send (bounded). Returns the rounds used.
    @discardableResult
    func converge(_ list: [CoordDevice]? = nil, rounds: Int = 10) async throws -> Int {
        let list = list ?? devices
        var previous: [[String]] = []
        for round in 1...rounds {
            for device in list { _ = try await device.coordinator.syncNow() }
            let now = try list.map { try $0.fingerprint() }
            let settled = now == previous && Set(now.map { $0.joined() }).count == 1
            if settled, try list.allSatisfy({ try $0.count("ck_inflight") == 0 && $0.count("ck_remote") == 0 }) { return round }
            previous = now
        }
        return rounds
    }
}

func withCoordWorld(_ count: Int, _ body: (CoordWorld) async throws -> Void) async throws {
    let world = try CoordWorld.make(count)
    defer { world.cleanup() }
    try await body(world)
}

/// Waits (polling the actor) until `condition` holds or the time is up.
func eventually(timeout: TimeInterval = 5, _ condition: @Sendable () async throws -> Bool) async throws -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try await condition() { return true }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    return try await condition()
}


/// Runs several devices' work one step at a time in an order the test chooses: a device runs until its next step, then the
/// schedule names who goes next. Stands in for "the fake schedules both first-runs at every await point" at the coordinator's
/// own step boundaries (each is a point where another device may act: after keys, after bind, after the download, ...).
actor Baton {
    private let order: [Int]
    private var cursor = 0
    private var holder: Int
    private var parked: [Int: CheckedContinuation<Void, Never>] = [:]
    private var finished: Set<Int> = []
    private let count: Int

    init(order: [Int], count: Int) { self.order = order; self.count = count; holder = order.first ?? 0; cursor = min(1, order.count) }

    /// Waits until it is this device's turn (called once, before its work starts).
    func acquire(_ device: Int) async {
        if holder == device { return }
        await withCheckedContinuation { parked[device] = $0 }
    }

    /// The device reached a step: hand the baton to whoever the schedule names next and wait until it comes back.
    func yield(_ device: Int) async {
        let next = pick(after: device)
        guard next != device else { return }
        hand(to: next)
        await withCheckedContinuation { parked[device] = $0 }
    }

    func finish(_ device: Int) {
        finished.insert(device)
        guard finished.count < count else { return }
        hand(to: pick(after: device))
    }

    private func pick(after device: Int) -> Int {
        let alive = (0..<count).filter { !finished.contains($0) }
        if cursor < order.count {
            let wanted = order[cursor]; cursor += 1
            if alive.contains(wanted) { return wanted }
        }
        // the schedule is used up: round robin over the devices that are still working
        return alive.first(where: { $0 != device }) ?? device
    }

    private func hand(to device: Int) {
        holder = device
        if let waiting = parked[device] { parked[device] = nil; waiting.resume() }
    }
}

/// A gateway whose network operations fail with `offline` while `isOffline` (the account state still answers, as the system does).
final class FlakyGateway: CloudKitGateway, @unchecked Sendable {
    let inner: CoordGateway
    private let flag = LockedBox<Bool>(false)
    nonisolated let events: AsyncStream<CloudGatewayEvent>
    init(_ inner: CoordGateway) { self.inner = inner; events = inner.events }
    var isOffline: Bool { get { flag.value } set { flag.update { $0 = newValue } } }
    private func check() throws { if flag.value { throw CloudSyncError.offline } }
    func prepare() async throws -> CloudAccountState { try check(); return try await inner.prepare() }
    func accountState() async -> CloudAccountState { await inner.accountState() }
    func submit(_ saves: [CloudSave]) async throws { try check(); try await inner.submit(saves) }
    func fetchChanges(into sink: any CloudChangeSink) async throws { try check(); try await inner.fetchChanges(into: sink) }
    func fetch(_ names: [String], keys: [String]?) async throws -> [String: CloudRecord] { try check(); return try await inner.fetch(names, keys: keys) }
    func delete(_ names: [String]) async throws { try check(); try await inner.delete(names) }
    func deleteZone() async throws { try check(); try await inner.deleteZone() }
    func deleteZone(expecting userHash: String) async throws { try check(); try await inner.deleteZone(expecting: userHash) }
}

/// A one-shot gate a test closes before a step and opens later.
actor Latch {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if open { return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
}

/// Searches every field and every asset of every record in the fake cloud for the given texts, as UTF-8, UTF-16 and base64.
func plaintextHits(in account: FakeCloudKitAccount, canaries: [String]) async throws -> [String] {
    var hits: [String] = []
    for name in await account.recordNames {
        guard let record = await account.record(named: name) else { continue }
        var blobs: [Data] = []
        for (_, value) in record.fields {
            switch value {
            case .bytes(let data): blobs.append(data)
            case .string(let text): blobs.append(Data(text.utf8))
            case .strings(let list): blobs += list.map { Data($0.utf8) }
            case .asset(let url): blobs.append(try Data(contentsOf: url))
            case .int: break
            }
        }
        blobs.append(Data(name.utf8))
        for canary in canaries {
            let utf16 = Data(canary.utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] })
            let needles = [Data(canary.utf8), utf16, Data(Data(canary.utf8).base64EncodedString().utf8)]
            if blobs.contains(where: { blob in needles.contains { blob.range(of: $0) != nil } }) { hits.append("\(canary) in \(name)") }
        }
    }
    return hits
}
