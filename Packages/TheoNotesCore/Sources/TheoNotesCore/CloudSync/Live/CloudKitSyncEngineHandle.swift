// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CloudKit
import Foundation

/// The part of `CKSyncEngine` the gateway uses, as a protocol, so that the gateway's event handling can be tested without a container
/// (CloudKit traps in a process without the iCloud entitlement). `LiveSyncEngine` is the only production conformer.
protocol SyncEngineHandle: AnyObject, Sendable {
    func fetchChanges() async throws
    func sendChanges() async throws
    func cancelOperations() async
    var pendingSaveIDs: [CKRecord.ID] { get }
    func addPendingSaves(_ ids: [CKRecord.ID])
    func removePendingSaves(_ ids: [CKRecord.ID])
    func addPendingZoneSaves(_ ids: [CKRecordZone.ID])
    func removePendingZoneSaves(_ ids: [CKRecordZone.ID])
    /// Empties both pending lists (the engine's own list is a cache of ours, CK-R15).
    func clearPending()
}

/// A `CKSyncEngine` together with its delegate. The engine does not retain its delegate (a delegate that only the configuration refers
/// to is gone before the first event and the engine then neither sends nor fetches), so this object does.
final class LiveSyncEngine: SyncEngineHandle, @unchecked Sendable {
    private let engine: CKSyncEngine
    private let delegate: CloudKitEngineDelegate

    init(database: CKDatabase, state: Data?, epoch: Int, gateway: LiveCloudKitGateway, automaticallySync: Bool) {
        delegate = CloudKitEngineDelegate(epoch: epoch)
        delegate.attach(gateway)
        let serialization = state.flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        var configuration = CKSyncEngine.Configuration(database: database, stateSerialization: serialization, delegate: delegate)
        configuration.automaticallySync = automaticallySync
        engine = CKSyncEngine(configuration)
    }

    func fetchChanges() async throws { try await engine.fetchChanges() }
    func sendChanges() async throws { try await engine.sendChanges() }
    func cancelOperations() async { await engine.cancelOperations() }

    var pendingSaveIDs: [CKRecord.ID] {
        engine.state.pendingRecordZoneChanges.compactMap { change in
            if case .saveRecord(let id) = change { return id } else { return nil }
        }
    }

    func addPendingSaves(_ ids: [CKRecord.ID]) { engine.state.add(pendingRecordZoneChanges: ids.map { .saveRecord($0) }) }
    func removePendingSaves(_ ids: [CKRecord.ID]) { engine.state.remove(pendingRecordZoneChanges: ids.map { .saveRecord($0) }) }
    func addPendingZoneSaves(_ ids: [CKRecordZone.ID]) { engine.state.add(pendingDatabaseChanges: ids.map { .saveZone(CKRecordZone(zoneID: $0)) }) }
    func removePendingZoneSaves(_ ids: [CKRecordZone.ID]) { engine.state.remove(pendingDatabaseChanges: ids.map { .saveZone(CKRecordZone(zoneID: $0)) }) }

    func clearPending() {
        engine.state.remove(pendingRecordZoneChanges: engine.state.pendingRecordZoneChanges)
        engine.state.remove(pendingDatabaseChanges: engine.state.pendingDatabaseChanges)
    }
}

/// What a test (or the gateway's default) puts in place of the real environment. Production code passes none.
struct LiveGatewayHooks: Sendable {
    var makeEngine: (@Sendable (_ state: Data?, _ epoch: Int) -> any SyncEngineHandle)?
    var accountState: (@Sendable () async -> CloudAccountState)?
    var ensureSubscription: (@Sendable () async throws -> Void)?

    init(makeEngine: (@Sendable (Data?, Int) -> any SyncEngineHandle)? = nil, accountState: (@Sendable () async -> CloudAccountState)? = nil,
         ensureSubscription: (@Sendable () async throws -> Void)? = nil) {
        self.makeEngine = makeEngine; self.accountState = accountState; self.ensureSubscription = ensureSubscription
    }
}
