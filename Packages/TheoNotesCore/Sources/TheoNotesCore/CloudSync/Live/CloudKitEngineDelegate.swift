// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CloudKit
import Foundation

/// `CKSyncEngineDelegate` for one engine instance. It holds no logic: every callback is forwarded into the gateway actor
/// (delegate events are handled inside the gateway actor), tagged with the epoch of the engine it came from so that a
/// discarded engine (after an account change or a failed fetch) cannot move the saved state or complete a newer attempt.
final class CloudKitEngineDelegate: CKSyncEngineDelegate, @unchecked Sendable {
    let epoch: Int
    private let lock = NSLock()
    private weak var gateway: LiveCloudKitGateway?

    init(epoch: Int) { self.epoch = epoch }

    func attach(_ gateway: LiveCloudKitGateway) { lock.withLock { self.gateway = gateway } }
    private var target: LiveCloudKitGateway? { lock.withLock { gateway } }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await target?.handle(event, epoch: epoch)
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.compactMap { change -> CKRecord.ID? in
            guard context.options.scope.contains(change), case .saveRecord(let id) = change else { return nil }
            return id
        }
        guard let selection = await target?.selectBatch(pending: pending, epoch: epoch) else { return nil }
        if !selection.drop.isEmpty { syncEngine.state.remove(pendingRecordZoneChanges: selection.drop.map { .saveRecord($0) }) }
        guard !selection.records.isEmpty else { return nil }
        return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: selection.records, recordIDsToDelete: [], atomicByZone: false)
    }

    func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        guard let target else { return context.options }
        return await target.fetchOptions(context)
    }
}
