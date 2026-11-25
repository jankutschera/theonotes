// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CloudKit
import Foundation
#if os(macOS)
import Security
#endif

/// `CloudKitGateway` on `CKSyncEngine` (CK-R15, CK-R160 to CK-R169). The only implementation that talks to the real service; the rest of
/// the sync core knows only the protocol (and `FakeCloudKitDevice` in tests).
///
/// How it differs from a plain "engine wrapper" (each point is a ruling in `docs/decisions.md`):
/// - Two record zones (CK-R152/R160): `Entity` and `KeyBundle` in the main zone, `BlobPart` in `<zone>Blobs`. The engine never fetches the
///   blob zone; parts are read by name (`fetch`), with `desiredKeys` excluding `asset` when only metadata is needed.
/// - The engine runs with `automaticallySync = false` (CK-R161): every send and fetch is one a caller asked for. Records reach a sink
///   only inside `fetchChanges(into:)`.
/// - The durable truth of what still has to be sent is the caller's `ck_inflight`. The gateway keeps an in-memory queue, empties the
///   engine's own pending list when an engine is created and reports every outcome to `CloudGatewayStore.recordSendResult` the moment
///   the engine reports it (CK-R162). A result that could not be stored stays queued and `submit` throws, so the caller's rows become
///   `unknown` and are resolved by the restart path (CK-R169).
/// - Every queued save and every engine event is bound to the engine epoch it belongs to; an event from another epoch can never
///   complete, or change the cache of, a newer attempt (CK-R169). Account changes fence the gateway until `prepare()` (CK-R163).
///   `deleteZone(expecting:)` binds the deletion to the expected account by naming that account as the zone owner (CK-R164).
public actor LiveCloudKitGateway: CloudKitGateway {
    public nonisolated let events: AsyncStream<CloudGatewayEvent>
    private let continuation: AsyncStream<CloudGatewayEvent>.Continuation

    /// Created on first use: CloudKit traps in a process without the iCloud entitlement, so building the gateway must not touch it.
    private let containerIdentifier: String
    private var cachedContainer: CKContainer?
    private var container: CKContainer {
        if let cachedContainer { return cachedContainer }
        let created = CKContainer(identifier: containerIdentifier)
        cachedContainer = created
        return created
    }
    private var database: CKDatabase { container.privateCloudDatabase }

    private let zones: CloudZones
    private let store: any CloudGatewayStore
    private let pinDirectory: URL
    private let maxBatchItems: Int
    private let automaticallySync: Bool
    private let hooks: LiveGatewayHooks?
    private static let maxBatchBytes = 1_048_576
    private static let maxBatchAssetBytes = 128 * 1_048_576
    private static let lateLimit = 1000

    /// The id of the private-database subscription `prepare()` makes sure exists (CK-R169).
    public static let pushSubscriptionID: CKSubscription.ID = "TheoNotesDatabase"

    // engine
    private var engine: (any SyncEngineHandle)?
    /// Every new engine, every fence and every zone deletion starts a new epoch. Events carry the epoch of the engine they came from.
    private var epoch = 0
    /// Counts account-level resets (fence, zone deletion). A result of an `await` that started in another generation is discarded.
    private var generation = 0
    private var engineStale = false
    private var fenced = false
    private var persistedState: Data?
    private var volatileState: Data?
    private var lastKnownAccount: CloudAccountState?
    private var rateLimitedUntil: Date?
    private var effectiveBatchItems: Int

    // operations
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var activeFetch: ActiveFetch?
    private var zoneCapture: ZoneCapture?

    // sending
    private struct BaseEntry { let tag: String; let archive: Data }
    /// CloudKit's own archive per record id and change tag (CK-R165). The core sees only the change tag; this is where the real
    /// archive of that version is kept for the next save. A miss (after a restart, or a version never seen here) is repaired by one
    /// fetch by name before the save. Bounded: the oldest entries are dropped first.
    private var baseCache: [CKRecord.ID: BaseEntry] = [:]
    private var baseCacheOrder: [CKRecord.ID] = []
    private static let baseCacheLimit = 4000
    private var queue: [CKRecord.ID: [Entry]] = [:]
    /// Saves that were on the wire of an engine that has since been retired (account change, rebuilt engine, lost response). Their
    /// late result is still recorded for their own attempt (CK-R45), but they never touch the queue, the engine or the cache.
    private struct LateKey: Hashable { let epoch: Int; let id: CKRecord.ID; let sid: String }
    private var late: [LateKey: Entry] = [:]
    private var lateOrder: [LateKey] = []

    // diagnostics (read by the live contract run and the unit tests)
    private(set) var sinklessDeliveries = 0
    private(set) var skippedRecords = 0
    private(set) var subscriptionError: String?
    private var trace: (@Sendable (String) -> Void)?
    /// A line per engine event and per thrown engine error, for the live contract run only (the text can contain record contents).
    func setTrace(_ trace: (@Sendable (String) -> Void)?) { self.trace = trace }

    private struct ActiveFetch {
        let sink: any CloudChangeSink
        let full: Bool
        var failure: Error?
        var held: Data?
        var tokenExpired = false
        var zoneGone = false
        /// The first error `didFetchRecordZoneChanges` reported that is not one of the two above: the fetch is incomplete (CK-R169).
        var zoneError: Error?
    }

    private struct ZoneCapture {
        var saved: [String] = []
        var failed: [CKError] = []
    }

    private struct Entry {
        let token = UUID()
        let save: CloudSave
        /// The record's own `sid` field (the publisher sets it to the attempt id; other callers may use any value). nil for records without
        /// one (BlobPart, KeyBundle).
        var sid: String? {
            if case .string(let value)? = save.record.fields["sid"] { return value } else { return nil }
        }
        let record: CKRecord
        let approximateSize: Int
        let assetBytes: Int
        /// The epoch of the engine this save was handed to; nil while it waits.
        var handedEpoch: Int?
        /// The outcome, once known and until the store has taken it. The entry stays queued until then (CK-R169).
        var pendingOutcome: CloudSaveOutcome?
        var handed: Bool { handedEpoch != nil }
    }

    /// - Parameters:
    ///   - engineState: the serialization the sink saved last (`CloudChangeSink.saveEngineState`); nil for a new device.
    ///   - pinDirectory: a durable folder (the no-backup folder in the app). Assets of a `serverRecordChanged` record are copied here
    ///     before the result is recorded, because the staging area can be emptied by the system (CK-R60).
    ///   - batchItemLimit: at most this many records per request (CK-R15: 100). The live contract run lowers or raises it.
    public init(configuration: CloudKitConfiguration, store: any CloudGatewayStore, engineState: Data?, pinDirectory: URL,
                batchItemLimit: Int = 100) {
        self.init(configuration: configuration, store: store, engineState: engineState, pinDirectory: pinDirectory,
                  batchItemLimit: batchItemLimit, automaticallySync: false, hooks: nil)
    }

    /// `automaticallySync: true` (the engine fetches and sends on its own schedule and on push) is NOT supported: the live run with it
    /// failed three cases (CK-R161: a fetch without a sink consumed records the engine then never offered again). It exists so that
    /// the run can be repeated when Apple's behaviour changes. `hooks` replace the engine, the account lookup and the subscription for tests.
    init(configuration: CloudKitConfiguration, store: any CloudGatewayStore, engineState: Data?, pinDirectory: URL,
         batchItemLimit: Int, automaticallySync: Bool, hooks: LiveGatewayHooks?) {
        self.automaticallySync = automaticallySync
        self.hooks = hooks
        containerIdentifier = configuration.containerIdentifier
        zones = CloudZones(configuration: configuration)
        self.store = store
        self.pinDirectory = pinDirectory
        maxBatchItems = max(1, batchItemLimit)
        effectiveBatchItems = max(1, batchItemLimit)
        persistedState = engineState
        (events, continuation) = AsyncStream.makeStream()
    }

    /// CloudKit raises an exception (not an error) in a process without the iCloud entitlement. On macOS the entitlement can be read
    /// from the code signature; iOS has no such API (a build without it fails at signing), so it answers true there.
    public static func processHasCloudKitEntitlement() -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil)
        if let services = value as? [String] { return services.contains("CloudKit") || services.contains("*") }
        return false
        #else
        return true
        #endif
    }

    // MARK: - CloudKitGateway

    public func accountState() async -> CloudAccountState {
        if let provider = hooks?.accountState { return await provider() }
        do {
            switch try await container.accountStatus() {
            case .available:
                let user = try await container.userRecordID()
                return .available(userHash: CloudRecordMapping.userHash(recordName: user.recordName))
            case .noAccount: return .noAccount
            case .restricted: return .restricted
            case .temporarilyUnavailable: return .temporarilyUnavailable
            case .couldNotDetermine: return .couldNotDetermine
            @unknown default: return .couldNotDetermine
            }
        } catch {
            return .couldNotDetermine
        }
    }

    public func prepare() async throws -> CloudAccountState {
        fenced = false
        let state = await accountState()
        lastKnownAccount = state
        guard case .available = state else { return state }
        flushOutcomes()
        await acquire()
        defer { release() }
        // CK-R169: push needs a database subscription; a failure here never blocks syncing (the schedulers fetch anyway) and is
        // tried again at the next `prepare()`.
        do { try await (hooks?.ensureSubscription ?? { try await self.ensureSubscription() })(); subscriptionError = nil }
        catch { subscriptionError = "\(error)"; trace?("ensureSubscription failed: \(error)") }
        let engine = ensureEngine()
        if case .unknown = try store.zoneState() {
            try await createZones(engine)
            try store.setZoneState(.created)
        }
        return state
    }

    public func submit(_ saves: [CloudSave]) async throws {
        if saves.isEmpty { return }
        flushOutcomes()
        if fenced {
            for save in saves { try recordNow(save, .fenced) }
            return
        }
        if let until = rateLimitedUntil, until > Date() {
            for save in saves { try recordNow(save, .offline) }
            return
        }
        await acquire()
        defer { release() }
        if fenced {
            for save in saves { try recordNow(save, .fenced) }
            return
        }
        let attemptIds = Set(saves.map(\.attemptId))
        let engine = ensureEngine()
        let startedIn = generation
        let resolved = await resolveBases(saves, generation: startedIn)
        if fenced || startedIn != generation {         // (an account change while the bases were fetched)
            for save in saves { try recordNow(save, .fenced) }
            return
        }
        var ids: [CKRecord.ID] = []
        var storeRefused = false
        for (save, base) in zip(saves, resolved) {
            let refused: CloudSaveOutcome?
            switch base {
            case .outcome(let outcome): refused = outcome
            case .base(let baseRecord):
                do {
                    let record = try CloudRecordMapping.makeCKRecord(from: save.record, base: baseRecord, zones: zones)
                    queue[record.recordID, default: []].append(Entry(save: save, record: record, approximateSize: save.record.approximateSize,
                                                                     assetBytes: CloudRecordMapping.assetBytes(of: save.record)))
                    ids.append(record.recordID)
                    refused = nil
                } catch let error as CloudRecordMappingError {
                    refused = .failed(code: Self.code(of: error))
                } catch {
                    refused = .failed(code: "mapping")
                }
            }
            if let refused, (try? recordNow(save, refused)) == nil { storeRefused = true }
        }
        if !ids.isEmpty {
            engine.addPendingSaves(ids.filter { queue[$0]?.first?.handed == false })       // (a set: a record named twice is added once)
            await drain(engine, ids: ids)
        }
        flushOutcomes()
        // CK-R169: a result the store would not take stays queued. The caller must not wait for it: it marks these rows unknown (a
        // `submit` that throws does exactly that, CK-R71) and the restart path resolves them.
        if storeRefused || unstoredOutcomeExists(for: attemptIds) { throw CloudSyncError.failed(code: "outcomeNotStored") }
    }

    public func fetchChanges(into sink: any CloudChangeSink) async throws {
        try requireUsable()
        if let until = rateLimitedUntil, until > Date() { throw CloudSyncError.offline }
        await acquire()
        defer { release() }
        var attempt = 0
        while true {
            attempt += 1
            try requireUsable()
            let engine = ensureEngine()
            let full = persistedState == nil
            if full, await zoneVanished() { return }
            activeFetch = ActiveFetch(sink: sink, full: full)
            if full {
                do { try sink.beginFullRefetch() } catch { activeFetch = nil; throw error }
            }
            var thrown: Error?
            do { try await engine.fetchChanges() } catch { thrown = error }
            let fetch = activeFetch
            activeFetch = nil
            // Whatever goes wrong from here on, the engine may be ahead of what is durable: it is discarded, and the next call builds
            // one from the last state a sink saved (CK-R169).
            if let failure = fetch?.failure { engineStale = true; throw failure }
            let expired = fetch?.tokenExpired == true || thrown.map(CloudKitErrorMapping.isChangeTokenExpired) == true
            if expired {
                // CK-R15: the token is gone; start over from nothing inside a new full-refetch bracket.
                persistedState = nil; engineStale = true
                if attempt < 3 { continue }
                throw CloudSyncError.failed(code: "changeTokenExpired")
            }
            if let thrown { engineStale = true; noteRateLimit(thrown); throw CloudKitErrorMapping.syncError(for: thrown) }
            if let zoneError = fetch?.zoneError {
                // A zone that could not be fetched is an incomplete picture: the bracket stays open, nothing is marked missing and no
                // state advances (CK-R169).
                engineStale = true; noteRateLimit(zoneError); throw CloudKitErrorMapping.syncError(for: zoneError)
            }
            if fetch?.zoneGone == true { engineStale = true; return }       // the zone vanished: nothing ends or is saved
            do {
                if full { try sink.endFullRefetch() }
                if let state = fetch?.held ?? (full ? volatileState : nil), state != persistedState {
                    try sink.saveEngineState(state)
                    persistedState = state
                }
            } catch {
                engineStale = true
                throw error
            }
            return
        }
    }

    public func fetch(_ names: [String], keys: [String]?) async throws -> [String: CloudRecord] {
        try requireUsable()
        if let until = rateLimitedUntil, until > Date() { throw CloudSyncError.offline }
        let startedIn = generation
        var result: [String: CloudRecord] = [:]
        var index = 0
        while index < names.count {
            let chunk = Array(names[index..<min(index + 100, names.count)])
            index += chunk.count
            let fetched: [CKRecord.ID: Result<CKRecord, Error>]
            do { fetched = try await database.records(for: chunk.map(zones.recordID(name:)), desiredKeys: keys) }
            catch { noteRateLimit(error); throw CloudKitErrorMapping.syncError(for: error) }
            guard startedIn == generation, !fenced else { throw CloudSyncError.fenced }         // another account's answer is not ours
            for (id, outcome) in fetched {
                switch outcome {
                case .success(let record):
                    if keys == nil { remember(record) }
                    if let mapped = CloudRecordMapping.makeCloudRecord(from: record) { result[id.recordName] = mapped } else { skippedRecords += 1 }
                case .failure(let error):
                    if CloudKitErrorMapping.ckError(error)?.code == .unknownItem { continue }
                    noteRateLimit(error)
                    throw CloudKitErrorMapping.syncError(for: error)
                }
            }
        }
        return result
    }

    public func delete(_ names: [String]) async throws {
        try requireUsable()
        var index = 0
        while index < names.count {
            let chunk = Array(names[index..<min(index + 100, names.count)])
            index += chunk.count
            let outcome: (saveResults: [CKRecord.ID: Result<CKRecord, Error>], deleteResults: [CKRecord.ID: Result<Void, Error>])
            do { outcome = try await database.modifyRecords(saving: [], deleting: chunk.map(zones.recordID(name:)), atomically: false) }
            catch { noteRateLimit(error); throw CloudKitErrorMapping.syncError(for: error) }
            for (_, result) in outcome.deleteResults {
                if case .failure(let error) = result, CloudKitErrorMapping.ckError(error)?.code != .unknownItem {
                    throw CloudKitErrorMapping.syncError(for: error)
                }
            }
        }
    }

    public func deleteZone() async throws {
        try requireUsable()
        let user = try await currentUser()
        try await deleteZones(ownedBy: user)
    }

    /// CK-R164. CloudKit has no "run this operation only for user X". What it has: a private-database zone id carries its owner. The
    /// zone ids sent here name the expected user as owner (`ownerName` = that user's record name, not the "current user" placeholder),
    /// so an operation that reaches the server while another account is signed in addresses zones that account does not own. The check
    /// of the expected user happens immediately before. If the signed-in user cannot be determined the call throws without deleting.
    public func deleteZone(expecting userHash: String) async throws {
        try requireUsable()
        let user = try await currentUser()
        guard CloudRecordMapping.userHash(recordName: user.recordName) == userHash else { throw CloudSyncError.fenced }
        try await deleteZones(ownedBy: user)
    }

    /// The gateway's own `CKSyncEngine.cancelOperations()` (CK-R92 step 2): the fence takes it as its `cancelOperations` closure.
    public func cancelOperations() async {
        await engine?.cancelOperations()
    }

    // MARK: - push (iOS)

    /// For `application(_:didReceiveRemoteNotification:)` (Task 16): a notification about the private database becomes `.remoteChange`
    /// (the coordinator then runs its cycle). Returns whether it was one. The subscription that makes CloudKit send it is ensured by
    /// `prepare()` (CK-R169); the apps never rely on push alone (iOS also fetches at launch, in the foreground and on a background
    /// refresh; the Mac on its timer).
    @discardableResult
    public nonisolated func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let note = CKNotification(fromRemoteNotificationDictionary: userInfo), note.notificationType == .database,
              (note as? CKDatabaseNotification)?.databaseScope == .private else { return false }
        continuation.yield(.remoteChange)
        return true
    }

    /// CK-R169. A database subscription exists once per database (the live run: saving a second one answers success and lists nothing
    /// new), so ANY database subscription is enough, the engine's `CKSyncEngineDatabaseSubscription-Private` as well as ours. If there
    /// is none, ours is saved with a fixed id (a save of an id that exists replaces it, so this is idempotent).
    func ensureSubscription() async throws {
        let existing = try await database.allSubscriptions()
        if existing.contains(where: { $0 is CKDatabaseSubscription }) { return }
        let subscription = CKDatabaseSubscription(subscriptionID: Self.pushSubscriptionID)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        let outcome = try await database.modifySubscriptions(saving: [subscription], deleting: [])
        if case .failure(let error)? = outcome.saveResults[Self.pushSubscriptionID] { throw error }
    }

    // MARK: - used by the delegate

    func fetchOptions(_ context: CKSyncEngine.FetchChangesContext) -> CKSyncEngine.FetchChangesOptions {
        var options = context.options
        // CK-R152: the blob zone is never fetched by the engine. CK-R161: the main zone only while a caller's sink is waiting for it.
        // Named zones, not "everything but the blob zone": the live run showed that `allExcluding` also fetches every other zone in the
        // private database (the leftover zones of earlier runs came through), and those records would reach the sink.
        options.scope = activeFetch != nil ? .zoneIDs([zones.main]) : .zoneIDs([])
        return options
    }

    struct BatchSelection: Sendable {
        var records: [CKRecord]
        /// Pending changes nothing backs any more.
        var drop: [CKRecord.ID]
    }

    /// The saves to hand to the engine now, in the engine's own order. Each one is marked as handed to THIS epoch.
    func selectBatch(pending: [CKRecord.ID], epoch: Int) -> BatchSelection? {
        guard !fenced, epoch == self.epoch else { return nil }
        var selection = BatchSelection(records: [], drop: [])
        var bytes = 0, assetBytes = 0
        for id in pending {
            guard let entry = queue[id]?.first, entry.pendingOutcome == nil, !entry.handed else {
                selection.drop.append(id)           // nothing waits behind it, or it is already out
                continue
            }
            if !selection.records.isEmpty {
                if selection.records.count >= effectiveBatchItems { break }
                if bytes + entry.approximateSize > Self.maxBatchBytes || assetBytes + entry.assetBytes > Self.maxBatchAssetBytes { continue }
            }
            selection.records.append(entry.record)
            bytes += entry.approximateSize; assetBytes += entry.assetBytes
            queue[id]?[0].handedEpoch = epoch
        }
        return selection
    }

    func handle(_ event: CKSyncEngine.Event, epoch: Int) async {
        if let trace { trace("event(epoch \(epoch)/\(self.epoch)) \(String(String(describing: event).prefix(300)))") }
        switch event {
        case .stateUpdate(let update):
            if let data = try? JSONEncoder().encode(update.stateSerialization) { processState(data, epoch: epoch) }
        case .accountChange(let change):
            let state: CloudAccountState
            switch change.changeType {
            case .signIn(let user): state = .available(userHash: CloudRecordMapping.userHash(recordName: user.recordName))
            case .signOut: state = .noAccount
            case .switchAccounts(_, let user): state = .available(userHash: CloudRecordMapping.userHash(recordName: user.recordName))
            @unknown default: state = .couldNotDetermine
            }
            processAccountChange(state, epoch: epoch)
        case .fetchedDatabaseChanges(let changes):
            processZoneDeletions(changes.deletions.filter { zones.isOurs($0.zoneID) }.map { CloudKitErrorMapping.removal(for: $0.reason) }, epoch: epoch)
        case .fetchedRecordZoneChanges(let changes):
            processFetched(modifications: changes.modifications.map(\.record), deletions: changes.deletions.map { $0.recordID.recordName }, epoch: epoch)
        case .sentDatabaseChanges(let sent):
            zoneCapture?.saved += sent.savedZones.map { $0.zoneID.zoneName }
            zoneCapture?.failed += sent.failedZoneSaves.map(\.error)
        case .sentRecordZoneChanges(let sent):
            await processSent(saved: sent.savedRecords, failed: sent.failedRecordSaves.map { ($0.record, $0.error) }, epoch: epoch)
        case .willFetchChanges:
            // A fetch nobody asked for (push, timer): nothing is delivered (scope above); the caller is told to run its cycle.
            if epoch == self.epoch, activeFetch == nil { emit(.remoteChange) }
        case .didFetchRecordZoneChanges(let done): processZoneFetched(error: done.error, epoch: epoch)
        case .willFetchRecordZoneChanges, .didFetchChanges, .willSendChanges, .didSendChanges: break
        @unknown default: break
        }
    }

    // MARK: - event processing (plain values, so the unit tests can drive it without CloudKit)

    /// During a fetch the state is only buffered, whatever kind of fetch it is: it is saved after the whole fetch completed and every
    /// commit it follows has been made (CK-R15), and dropped if the fetch did not complete (CK-R169, round 2). Outside a fetch it is kept
    /// in memory only.
    func processState(_ data: Data, epoch: Int) {
        guard epoch == self.epoch else { return }
        guard activeFetch != nil else { volatileState = data; return }
        activeFetch?.held = data
    }

    func processFetched(modifications: [CKRecord], deletions: [String], epoch: Int) {
        guard epoch == self.epoch else { return }
        guard let fetch = activeFetch else {
            // Not expected (the scope is empty without a sink). Whatever the engine did with its token is not trusted: start over from
            // the last state a sink saved, and let the caller's next cycle fetch again.
            sinklessDeliveries += modifications.count + deletions.count
            engineStale = true
            emit(.remoteChange)
            return
        }
        guard fetch.failure == nil else { return }
        var changed: [CloudRecord] = []
        for record in modifications {
            remember(record)
            if let mapped = CloudRecordMapping.makeCloudRecord(from: record) { changed.append(mapped) } else { skippedRecords += 1 }
        }
        guard !changed.isEmpty || !deletions.isEmpty else { return }
        do { try fetch.sink.commit(changed: changed, deletedNames: deletions) } catch { activeFetch?.failure = error }
    }

    func processZoneDeletions(_ reasons: [ZoneRemoval], epoch: Int) {
        guard epoch == self.epoch else { return }
        for reason in reasons { noteZoneRemoved(reason) }
    }

    func processZoneFetched(error: CKError?, epoch: Int) {
        guard epoch == self.epoch, let error else { return }
        if CloudKitErrorMapping.isChangeTokenExpired(error) { activeFetch?.tokenExpired = true; return }
        if let removal = CloudKitErrorMapping.zoneRemoval(for: error) {
            activeFetch?.zoneGone = true
            noteZoneRemoved(removal)
            return
        }
        if activeFetch?.zoneError == nil { activeFetch?.zoneError = error }
    }

    func processAccountChange(_ state: CloudAccountState, epoch: Int) {
        guard epoch == self.epoch else { return }
        // A new engine reports `signIn` for the account it starts with; `prepare()` already saw that account.
        if state == lastKnownAccount { return }
        lastKnownAccount = state
        fenceNow()
        emit(.accountChanged(state))
    }

    private enum Claim {
        case current(UUID)
        case late(LateKey)
        case none
    }

    /// Which queued save an event from engine `epoch` is about. Name + epoch + attempt id must all match. The attempt id is the record's
    /// `sid` (the publisher sets it to the attempt id; Entity records carry it; BlobPart and KeyBundle do not, which is why an engine that lost a response is never used for that
    /// record again, see `retire`). Whatever else is at the head of the same record id's queue is a different attempt and is never
    /// completed by this event (CK-R169).
    private func claim(_ id: CKRecord.ID, epoch: Int, sid: String?) -> Claim {
        if epoch == self.epoch, let head = queue[id]?.first, head.handedEpoch == epoch, head.sid == sid {
            return .current(head.token)
        }
        let key = LateKey(epoch: epoch, id: id, sid: sid ?? "")
        return late[key] != nil ? .late(key) : .none
    }

    private static func sid(of record: CKRecord) -> String? { record["sid"] as? String }

    func processSent(saved: [CKRecord], failed: [(record: CKRecord, error: CKError)], epoch: Int) async {
        for record in saved {
            let id = record.recordID
            let outcome: CloudSaveOutcome
            if let tag = record.recordChangeTag {
                outcome = .saved(systemFields: CloudRecordMapping.SystemFields.make(tag: tag, name: id.recordName))
            } else {
                outcome = .failed(code: "savedWithoutChangeTag")
            }
            switch claim(id, epoch: epoch, sid: Self.sid(of: record)) {
            case .current(let token):
                remember(record)
                settle(id, token: token, outcome)
            case .late(let key):
                settleLate(key, outcome)             // recorded for its own attempt; no cache, no queue, no engine
            case .none:
                break
            }
        }
        var requeue: [CKRecord.ID] = []
        var shrink = false
        for failure in failed {
            let id = failure.record.recordID
            let error = failure.error
            switch claim(id, epoch: epoch, sid: Self.sid(of: failure.record)) {
            case .none:
                continue
            case .late(let key):
                // The engine this belonged to is gone; the caller resolves the attempt as unknown unless a plain outcome says enough.
                let outcome = CloudKitErrorMapping.outcome(for: error) { _ in throw CloudSyncError.failed(code: "assetNotAvailable") }
                settleLate(key, outcome)
            case .current(let token):
                noteRateLimit(error)
                if error.code == .limitExceeded, effectiveBatchItems > 1 {
                    // CK-R46: halve and send again; only a single record that is too large surfaces as the outcome.
                    shrink = true
                    queue[id]?[0].handedEpoch = nil
                    requeue.append(id)
                    continue
                }
                if error.code == .userDeletedZone { noteZoneRemoved(.userDeletedZone) }
                var server: CKRecord?
                if error.code == .serverRecordChanged {
                    let startedIn = generation
                    server = await completeServerRecord(error.serverRecord)
                    // The await may have outlived the engine, the account or the attempt: then this event no longer owns anything.
                    guard startedIn == generation, case .current(let again) = claim(id, epoch: epoch, sid: Self.sid(of: failure.record)), again == token else { continue }
                    if let server { remember(server) }
                }
                let outcome = CloudKitErrorMapping.outcome(for: error) { _ in
                    guard let server else { throw CloudSyncError.failed(code: "assetNotAvailable") }
                    return try self.pinned(CloudRecordMapping.makeCloudRecord(from: server))
                }
                engine?.removePendingSaves([id])      // the engine would retry it; the caller owns retries (CK-R162)
                settle(id, token: token, outcome)
            }
        }
        if epoch == self.epoch {
            if shrink { effectiveBatchItems = max(1, effectiveBatchItems / 2) }
            else if failed.isEmpty { effectiveBatchItems = min(maxBatchItems, effectiveBatchItems * 2) }
            if !requeue.isEmpty { engine?.addPendingSaves(requeue) }
        }
        flushOutcomes()
    }

    // MARK: - bases of saves

    private enum Resolved { case base(CKRecord?), outcome(CloudSaveOutcome) }

    private func recordID(of record: CloudRecord) -> CKRecord.ID {
        CKRecord.ID(recordName: record.name, zoneID: zones.zoneID(for: record.type))
    }

    func remember(_ record: CKRecord) {
        guard let tag = record.recordChangeTag else { return }
        if baseCache[record.recordID] == nil {
            baseCacheOrder.append(record.recordID)
            if baseCacheOrder.count > Self.baseCacheLimit { baseCache[baseCacheOrder.removeFirst()] = nil }
        }
        baseCache[record.recordID] = BaseEntry(tag: tag, archive: CloudRecordMapping.archive(of: record))
    }

    func cachedTag(for id: CKRecord.ID) -> String? { baseCache[id]?.tag }

    /// The CloudKit record each save continues. A create has none. A save that names a version we hold the archive of uses it; any
    /// other is repaired by reading the record's current version by name: the same change tag gives the base, a different one means the
    /// save is stale (`serverRecordChanged` with the current record), a missing record is `unknownItem`. Nothing read after an account
    /// change is used or remembered.
    private func resolveBases(_ saves: [CloudSave], generation startedIn: Int) async -> [Resolved] {
        var result = [Resolved?](repeating: nil, count: saves.count)
        var misses: [Int] = []
        for (index, save) in saves.enumerated() {
            guard let data = save.record.systemFields else { result[index] = .base(nil); continue }
            guard let version = CloudRecordMapping.SystemFields.parse(data), version.name == save.record.name else {
                result[index] = .outcome(.failed(code: "systemFieldsUnreadable")); continue
            }
            let id = recordID(of: save.record)
            if let cached = baseCache[id], cached.tag == version.tag, let record = try? CloudRecordMapping.record(fromArchive: cached.archive) {
                result[index] = .base(record)
            } else {
                misses.append(index)
            }
        }
        guard !misses.isEmpty else { return result.compactMap { $0 } }
        let ids = Array(Set(misses.map { recordID(of: saves[$0].record) }))
        var current: [CKRecord.ID: Result<CKRecord, Error>] = [:]
        do {
            var offset = 0
            while offset < ids.count {
                let chunk = Array(ids[offset..<min(offset + 100, ids.count)])
                offset += chunk.count
                current.merge(try await database.records(for: chunk, desiredKeys: ["v"])) { $1 }
            }
        } catch {
            noteRateLimit(error)
            let outcome = Self.outcome(for: CloudKitErrorMapping.syncError(for: error))
            for index in misses { result[index] = .outcome(outcome) }
            return result.compactMap { $0 }
        }
        if startedIn != generation { return saves.map { _ in .outcome(.fenced) } }
        var stale: [Int] = []
        for index in misses {
            let save = saves[index]
            let id = recordID(of: save.record)
            guard let fetched = current[id] else { result[index] = .outcome(.unknownItem); continue }
            switch fetched {
            case .success(let record):
                if let version = save.record.systemFields.flatMap(CloudRecordMapping.SystemFields.parse), record.recordChangeTag == version.tag {
                    result[index] = .base(record)
                } else {
                    stale.append(index)
                }
            case .failure(let error):
                if let ck = CloudKitErrorMapping.ckError(error) {
                    result[index] = .outcome(CloudKitErrorMapping.outcome(for: ck) { _ in throw CloudSyncError.failed(code: "conflictAssetUnavailable") })
                } else {
                    result[index] = .outcome(.offline)
                }
            }
        }
        if !stale.isEmpty {
            let staleIDs = Array(Set(stale.map { recordID(of: saves[$0].record) }))
            let full = (try? await database.records(for: staleIDs)) ?? [:]
            if startedIn != generation { return saves.map { _ in .outcome(.fenced) } }
            for index in stale {
                if case .success(let record)? = full[recordID(of: saves[index].record)], let server = pinnedOrNil(record) {
                    remember(record)
                    result[index] = .outcome(.serverRecordChanged(server: server))
                } else {
                    result[index] = .outcome(.failed(code: "conflictAssetUnavailable"))
                }
            }
        }
        return result.compactMap { $0 }
    }

    private func pinnedOrNil(_ record: CKRecord) -> CloudRecord? { try? pinned(CloudRecordMapping.makeCloudRecord(from: record)) }

    /// The server record of a `serverRecordChanged` error comes without the files of its asset fields; the whole record is read again
    /// when it has any, so that the conflict can be merged and its payload pinned (CK-R60). The caller remembers the result, and only
    /// after checking that this answer still belongs to the attempt that asked.
    private func completeServerRecord(_ record: CKRecord?) async -> CKRecord? {
        guard let record else { return nil }
        let missingAsset = record.allKeys().contains { (record[$0] as? CKAsset).map { $0.fileURL == nil } ?? false }
        if missingAsset { return try? await database.records(for: [record.recordID])[record.recordID]?.get() }
        return record
    }

    // MARK: - sending

    private func drain(_ engine: any SyncEngineHandle, ids: [CKRecord.ID]) async {
        let startedEpoch = epoch
        for _ in 0..<16 {
            guard epoch == startedEpoch else { return }       // the engine was replaced under us: its saves are in `late` now
            guard ids.contains(where: { queue[$0] != nil }) else { return }
            do { try await engine.sendChanges() } catch {
                guard epoch == startedEpoch else { return }
                noteRateLimit(error)
                let mapped = CloudKitErrorMapping.syncError(for: error)
                if mapped == .limitExceeded, effectiveBatchItems > 1 {
                    effectiveBatchItems = max(1, effectiveBatchItems / 2)
                    for id in ids where queue[id] != nil {
                        queue[id]?[0].handedEpoch = nil
                        engine.addPendingSaves([id])
                    }
                    continue
                }
                failQueued(ids, with: Self.outcome(for: mapped), removeFrom: engine)
                return
            }
            guard epoch == startedEpoch else { return }
            let pending = Set(engine.pendingSaveIDs)
            for id in ids {
                guard let head = queue[id]?.first, !pending.contains(id), head.pendingOutcome == nil else { continue }
                // Sent (or tried) and no outcome learned: the response is lost, the caller resolves it as unknown (CK-R4, CK-R77).
                // The save stays reachable as a late result of this epoch, but leaves the queue.
                if head.handed { retire(id) }
                else { await failDormant(id) }
            }
            if !ids.contains(where: { pending.contains($0) && queue[$0] != nil }) { return }
        }
        // The engine kept the changes pending and never asked for them (no account, no network): it is dormant.
        for id in ids where queue[id] != nil { await failDormant(id) }
    }

    private func failDormant(_ id: CKRecord.ID) async {
        let state = await accountState()
        let outcome: CloudSaveOutcome
        switch state {
        case .noAccount, .restricted: outcome = .unauthenticated
        default: outcome = .offline
        }
        engine?.removePendingSaves([id])
        settleAll(id, outcome)
    }

    private func failQueued(_ ids: [CKRecord.ID], with outcome: CloudSaveOutcome, removeFrom engine: any SyncEngineHandle) {
        engine.removePendingSaves(ids)
        for id in ids { settleAll(id, outcome) }
    }

    private static func outcome(for error: CloudSyncError) -> CloudSaveOutcome {
        switch error {
        case .offline: return .offline
        case .unauthenticated: return .unauthenticated
        case .quotaExceeded: return .quotaExceeded
        case .limitExceeded: return .limitExceeded
        case .zoneNotFound: return .zoneNotFound
        case .fenced: return .fenced
        case .failed(let code): return .failed(code: code)
        }
    }

    private static func code(of error: CloudRecordMappingError) -> String {
        switch error {
        case .fieldNotAllowed(let type, let field): return "fieldNotAllowed:\(type).\(field)"
        case .systemFieldsUnreadable: return "systemFieldsUnreadable"
        case .systemFieldsMismatch(let what): return "systemFieldsMismatch:\(what)"
        case .assetFileMissing(let field): return "assetFileNotFound:\(field)"
        }
    }

    // MARK: - outcomes (CK-R169: an entry leaves the queue only after its result is stored)

    /// A result for a save that is not queued (refused before it was queued): stored now, or the error reaches the caller.
    private func recordNow(_ save: CloudSave, _ outcome: CloudSaveOutcome) throws {
        do { try store.recordSendResult(attemptId: save.attemptId, accountGeneration: save.accountGeneration, outcome: outcome) }
        catch where Self.isRevoked(error) { return }
        catch { throw CloudSyncError.failed(code: "outcomeNotStored") }
    }

    /// The store refuses a result because the durable fence is up or the save belongs to another generation (CK-R99, CK-R171): the
    /// session that sent it was stopped or switched, so the result is moot. It is dropped, not kept for a store that will never take it.
    private static func isRevoked(_ error: Error) -> Bool {
        switch error as? CloudSyncStoreError {
        case .accountFenced?, .staleAccountGeneration?: return true
        default: return false
        }
    }

    /// Gives the queued save `token` its outcome and tries to store it. If the store refuses, the entry stays at the head, holding the
    /// outcome, and the next `flushOutcomes()` tries again.
    private func settle(_ id: CKRecord.ID, token: UUID, _ outcome: CloudSaveOutcome, readd: Bool = true) {
        guard queue[id]?.first?.token == token else { return }
        if queue[id]?[0].pendingOutcome == nil { queue[id]?[0].pendingOutcome = outcome }
        storeHead(id, readd: readd)
    }

    /// Settles every queued save of this record with the same outcome (as far as the store takes them).
    private func settleAll(_ id: CKRecord.ID, _ outcome: CloudSaveOutcome) {
        while let head = queue[id]?.first {
            settle(id, token: head.token, outcome, readd: false)
            if queue[id]?.first?.token == head.token { break }          // the store refused: it stays
        }
    }

    private func storeHead(_ id: CKRecord.ID, readd: Bool) {
        guard let head = queue[id]?.first, let outcome = head.pendingOutcome else { return }
        do { try store.recordSendResult(attemptId: head.save.attemptId, accountGeneration: head.save.accountGeneration, outcome: outcome) }
        catch where Self.isRevoked(error) { /* moot: leaves the queue like a stored result */ }
        catch { return }
        var entries = queue[id] ?? []
        entries.removeFirst()
        queue[id] = entries.isEmpty ? nil : entries
        if readd, !entries.isEmpty, !fenced { engine?.addPendingSaves([id]) }
    }

    private func settleLate(_ key: LateKey, _ outcome: CloudSaveOutcome) {
        guard var entry = late[key] else { return }
        if entry.pendingOutcome == nil { entry.pendingOutcome = outcome }
        late[key] = entry
        storeLate(key)
    }

    private func storeLate(_ key: LateKey) {
        guard let entry = late[key], let outcome = entry.pendingOutcome else { return }
        do { try store.recordSendResult(attemptId: entry.save.attemptId, accountGeneration: entry.save.accountGeneration, outcome: outcome) }
        catch where Self.isRevoked(error) { /* moot: dropped */ }
        catch { return }
        late[key] = nil
        lateOrder.removeAll { $0 == key }
    }

    /// Offers every held outcome to the store again.
    func flushOutcomes() {
        for id in Array(queue.keys) { storeHead(id, readd: true) }
        for key in Array(late.keys) { storeLate(key) }
    }

    private func unstoredOutcomeExists(for attemptIds: Set<String>) -> Bool {
        queue.values.contains { $0.contains { $0.pendingOutcome != nil && attemptIds.contains($0.save.attemptId) } }
            || late.values.contains { $0.pendingOutcome != nil && attemptIds.contains($0.save.attemptId) }
    }

    /// The head of this record's queue was on the wire of its engine and nothing came back: it stays reachable as a late result.
    private func retire(_ id: CKRecord.ID) {
        guard var entries = queue[id], !entries.isEmpty, let epoch = entries[0].handedEpoch else { return }
        let entry = entries.removeFirst()
        queue[id] = entries.isEmpty ? nil : entries
        addLate(entry, epoch: epoch, id: id)
        // The answer may still come, and a record without an attempt id cannot be told from the next save's answer: this engine is
        // not used again, the next call builds a new one (new epoch), and what waits behind this save goes there.
        engineStale = true
        if !entries.isEmpty, !fenced { engine?.addPendingSaves([id]) }
    }

    private func addLate(_ entry: Entry, epoch: Int, id: CKRecord.ID) {
        let key = LateKey(epoch: epoch, id: id, sid: entry.sid ?? "")
        late[key] = entry
        lateOrder.append(key)
        while lateOrder.count > Self.lateLimit { late[lateOrder.removeFirst()] = nil }
    }

    /// Before the epoch changes: every save that was handed to the old engine moves to `late`, where only an event from that very
    /// engine can reach it.
    private func retireHandedEntries() {
        for id in Array(queue.keys) {
            guard var entries = queue[id] else { continue }
            var keep: [Entry] = []
            for entry in entries {
                if let handedEpoch = entry.handedEpoch, entry.pendingOutcome == nil { addLate(entry, epoch: handedEpoch, id: id) }
                else { keep.append(entry) }
            }
            entries = keep
            queue[id] = entries.isEmpty ? nil : entries
        }
    }

    /// Copies each asset into the durable pin folder and checks the size; the staging copy may already be gone (CK-R60).
    private func pinned(_ record: CloudRecord?) throws -> CloudRecord {
        guard var copy = record else { throw CloudSyncError.failed(code: "unmappableRecord") }
        try FileManager.default.createDirectory(at: pinDirectory, withIntermediateDirectories: true)
        for (key, value) in record?.fields ?? [:] {
            guard case .asset(let url) = value else { continue }
            let target = pinDirectory.appendingPathComponent("\(UUID().uuidString)-\(key)")
            do { try FileManager.default.copyItem(at: url, to: target) } catch { throw CloudSyncError.failed(code: "assetNotAvailable") }
            let before = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
            let after = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) ?? -2
            guard before == after else { try? FileManager.default.removeItem(at: target); throw CloudSyncError.failed(code: "assetNotAvailable") }
            copy.fields[key] = .asset(target)
        }
        return copy
    }

    // MARK: - engine lifecycle

    private func requireUsable() throws {
        if fenced { throw CloudSyncError.fenced }
    }

    /// An engine for the saved state, with an empty pending list: what is still to be sent is `ck_inflight` (the caller's), and a
    /// save that was only in the old engine's list has no record to build from here (CK-R15, CK-R162). Replacing an engine starts a
    /// new epoch: what was on the old one's wire can only be answered by the old one, as a late result.
    private func ensureEngine() -> any SyncEngineHandle {
        if let engine, !engineStale { return engine }
        if let old = engine { Task { await old.cancelOperations() } }
        retireHandedEntries()
        epoch += 1
        engineStale = false
        let created: any SyncEngineHandle
        if let make = hooks?.makeEngine {
            created = make(persistedState, epoch)
        } else {
            created = LiveSyncEngine(database: database, state: persistedState, epoch: epoch, gateway: self, automaticallySync: automaticallySync)
        }
        created.clearPending()
        created.addPendingSaves(queue.compactMap { id, entries in entries.first.map { $0.handed ? nil : id } ?? nil })
        engine = created
        return created
    }

    /// CK-R163 steps (1) to (5) on the gateway's side: no more batches, outstanding operations cancelled, the engine and its state
    /// dropped, saves that never left stay reported as `fenced`; saves already on the wire can only be answered as late results.
    private func fenceNow() {
        fenced = true
        retireHandedEntries()
        epoch += 1
        generation += 1
        let old = engine
        engine = nil
        engineStale = false
        persistedState = nil
        volatileState = nil
        baseCache = [:]; baseCacheOrder = []
        for id in Array(queue.keys) { settleAll(id, .fenced) }
        if let old { Task { await old.cancelOperations() } }
    }

    private func createZones(_ engine: any SyncEngineHandle) async throws {
        zoneCapture = ZoneCapture()
        engine.addPendingZoneSaves(zones.all)
        do { try await engine.sendChanges() } catch {
            zoneCapture = nil
            trace?("createZones sendChanges threw \(error)")
            engine.removePendingZoneSaves(zones.all)
            throw CloudKitErrorMapping.syncError(for: error)
        }
        for _ in 0..<300 where (zoneCapture?.saved.count ?? 0) < zones.all.count && (zoneCapture?.failed.isEmpty ?? true) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let capture = zoneCapture ?? ZoneCapture()
        zoneCapture = nil
        trace?("createZones saved=\(capture.saved) failed=\(capture.failed)")
        if let failed = capture.failed.first {
            engine.removePendingZoneSaves(zones.all)
            throw CloudKitErrorMapping.syncError(for: failed)
        }
        guard Set(zones.all.map(\.zoneName)).isSubset(of: Set(capture.saved)) else {
            engine.removePendingZoneSaves(zones.all)
            throw CloudSyncError.offline
        }
    }

    private func noteZoneRemoved(_ reason: ZoneRemoval) {
        guard case .created? = try? store.zoneState() else { return }
        try? store.setZoneState(.removed(reason))
        emit(.zoneRemoved(reason))
    }

    /// A device that starts without engine state asks the service whether the zones are still there; a zone that went away while this
    /// device was not looking is reported as removed instead of being fetched as an empty picture (the fake does the same).
    private func zoneVanished() async -> Bool {
        guard case .created? = try? store.zoneState() else { return false }
        let missing: Bool
        do {
            let result = try await database.recordZones(for: zones.all)
            missing = result.contains { _, outcome in
                if case .failure(let error) = outcome { return CloudKitErrorMapping.zoneRemoval(for: error) != nil } else { return false }
            }
        } catch {
            guard let ck = CloudKitErrorMapping.ckError(error), ck.code == .partialFailure,
                  let inner = CloudKitErrorMapping.significantPartialError(ck) else { return false }
            missing = CloudKitErrorMapping.zoneRemoval(for: inner) != nil
        }
        if missing { noteZoneRemoved(.deleted) }
        return missing
    }

    private func currentUser() async throws -> CKRecord.ID {
        do { return try await container.userRecordID() } catch { throw CloudKitErrorMapping.syncError(for: error) }
    }

    private func deleteZones(ownedBy user: CKRecord.ID) async throws {
        await acquire()
        defer { release() }
        let owned = zones.all.map { CKRecordZone.ID(zoneName: $0.zoneName, ownerName: user.recordName) }
        let outcome: (saveResults: [CKRecordZone.ID: Result<CKRecordZone, Error>], deleteResults: [CKRecordZone.ID: Result<Void, Error>])
        do { outcome = try await database.modifyRecordZones(saving: [], deleting: owned) }
        catch { noteRateLimit(error); throw CloudKitErrorMapping.syncError(for: error) }
        for (_, result) in outcome.deleteResults {
            if case .failure(let error) = result, CloudKitErrorMapping.ckError(error)?.code != .zoneNotFound {
                throw CloudKitErrorMapping.syncError(for: error)
            }
        }
        // The copy is gone: the engine's state refers to zones that no longer exist, and what was queued can no longer be sent.
        try store.setZoneState(.removed(.deleted))
        if let old = engine { Task { await old.cancelOperations() } }
        retireHandedEntries()
        engine = nil; engineStale = false; epoch += 1; generation += 1; persistedState = nil; volatileState = nil
        baseCache = [:]; baseCacheOrder = []
        for id in Array(queue.keys) { settleAll(id, .zoneNotFound) }
    }

    // MARK: - serialization of engine-driving operations

    private func acquire() async {
        if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    private func noteRateLimit(_ error: Error) {
        if let seconds = CloudKitErrorMapping.retryAfter(error), seconds > 0 { rateLimitedUntil = Date().addingTimeInterval(seconds) }
        else if let ck = CloudKitErrorMapping.ckError(error), ck.code == .partialFailure, let inner = CloudKitErrorMapping.significantPartialError(ck),
                let seconds = CloudKitErrorMapping.retryAfter(inner), seconds > 0 { rateLimitedUntil = Date().addingTimeInterval(seconds) }
    }

    private func emit(_ event: CloudGatewayEvent) { continuation.yield(event) }

    // MARK: - hooks for the live contract run and the unit tests

    /// One engine fetch with no caller sink: must deliver nothing and only announce `.remoteChange` (CK-R161). Returns how many records
    /// reached the gateway without a sink (0 when the scope gating works).
    func fetchWithoutSink() async throws -> Int {
        await acquire()
        defer { release() }
        let engine = ensureEngine()
        sinklessDeliveries = 0
        try await engine.fetchChanges()
        return sinklessDeliveries
    }

    func queuedSaveCount() -> Int { queue.values.reduce(0) { $0 + $1.count } }
    func lateSaveCount() -> Int { late.count }
    func currentEpoch() -> Int { epoch }
    func isFenced() -> Bool { fenced }
    func rateLimitHold() -> Date? { rateLimitedUntil }
}
