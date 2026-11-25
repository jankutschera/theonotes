// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// Receives what a fetch delivers. The gateway calls `commit` per batch, then `saveEngineState` for the state that follows
/// that batch: the persisted state is never ahead of the persisted data (CK-R5). During a full refetch the gateway holds the
/// state back until `endFullRefetch` returned.
public protocol CloudChangeSink: Sendable {
    /// Validates, quarantines and stores the batch; durable before returning. Throwing aborts the fetch and saves no state.
    func commit(changed: [CloudRecord], deletedNames: [String]) throws
    /// Only after the commits it follows.
    func saveEngineState(_ state: Data) throws
    func beginFullRefetch() throws
    func endFullRefetch() throws
}

/// What the gateway persists itself, so that a restart loses nothing: the zone lifecycle (`ck_state.zoneState`) and every
/// send outcome the moment it is known (`ck_send_result`), whether or not anyone is waiting. `CloudSyncStore` (Task 3) conforms.
public protocol CloudGatewayStore: Sendable {
    func zoneState() throws -> CloudZoneState
    func setZoneState(_ state: CloudZoneState) throws
    func recordSendResult(attemptId: String, accountGeneration: Int64, outcome: CloudSaveOutcome) throws
}

/// The only seam between the sync engine and CloudKit. `import CloudKit` exists only under `CloudSync/Live/`.
public protocol CloudKitGateway: Sendable {
    /// Creates the zone ONLY when `zoneState == .unknown`; also lifts the fence after an account change (the caller's policy decided).
    func prepare() async throws -> CloudAccountState
    func accountState() async -> CloudAccountState
    /// Durable intent; outcomes arrive in `ck_send_result` (`CloudGatewayStore.recordSendResult`), not as a return value.
    func submit(_ saves: [CloudSave]) async throws
    func fetchChanges(into sink: any CloudChangeSink) async throws
    /// Missing names are absent from the result. `keys` is the field subset (nil: all fields and assets).
    func fetch(_ names: [String], keys: [String]?) async throws -> [String: CloudRecord]
    /// Restricted by Global Constraints: only "Delete my iCloud copy" and tests may call this.
    func delete(_ names: [String]) async throws
    func deleteZone() async throws
    /// Deletes the zone of the account the device is signed in to NOW, but only if that account is `userHash`; otherwise nothing is
    /// deleted and the call throws `CloudSyncError.fenced`. There is no default implementation on purpose: the live gateway (Task 14)
    /// MUST check and delete without a gap in between, and a conformer that cannot do that safely must throw instead of deleting
    /// (fail closed). Only "Delete my iCloud copy" calls it (Task 15, C1).
    func deleteZone(expecting userHash: String) async throws
    nonisolated var events: AsyncStream<CloudGatewayEvent> { get }
}
