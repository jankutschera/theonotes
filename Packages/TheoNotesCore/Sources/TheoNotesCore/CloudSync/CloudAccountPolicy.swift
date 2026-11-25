// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

/// What to do about the iCloud account the device reports (CK-R10). Pure: the stored user hash and the reported account in,
/// a decision out. A different iCloud user never gets this library's notes silently (the decision is `.pause(.accountChanged)`).
public enum CloudAccountDecision: Sendable, Equatable {
    public enum PauseReason: Sendable, Equatable { case accountChanged, signedOut, restricted }
    /// The stored account is the signed-in one: lift the fence and carry on.
    case resume
    case pause(PauseReason)
    /// iCloud is temporarily unavailable or cannot be determined yet: nothing is lost, look again later.
    case waitForAccount
    /// The library has never been bound to an account and one is available.
    case firstBind
}

public enum CloudAccountPolicy {
    /// `stored` is `ck_state.cloudUserHash` (nil until the library is bound).
    public static func evaluate(stored: String?, current: CloudAccountState) -> CloudAccountDecision {
        switch current {
        case .available(let hash):
            guard let stored else { return .firstBind }
            return stored == hash ? .resume : .pause(.accountChanged)
        case .noAccount: return .pause(.signedOut)
        case .restricted: return .pause(.restricted)
        case .temporarilyUnavailable, .couldNotDetermine: return .waitForAccount
        }
    }

    /// The state the person sees for a decision; nil when the decision lets sync run.
    public static func state(for decision: CloudAccountDecision, stored: String?) -> CloudSyncState? {
        switch decision {
        case .resume, .firstBind: return nil
        case .pause(.accountChanged): return .accountChanged(previousHash: stored ?? "")
        case .pause(.signedOut): return .signedOutOfICloud
        case .pause(.restricted): return .restricted
        case .waitForAccount: return .waitingForICloud
        }
    }

    /// Re-derives the visible state from durable data at launch (CK-R15: the event stream is a notification only; a missed
    /// event changes nothing because everything it announced is already in `ck_state`). First match wins: not bound, account
    /// not usable, zone removed, fenced, unreadable items, missing items, else `.syncing` (the coordinator is about to sync).
    public static func launchState(store: CloudSyncStore, account: CloudAccountState) throws -> CloudSyncState {
        guard try store.backend() == .cloudkit else { return .off }
        let stored = try store.cloudUserHash()
        if let paused = state(for: evaluate(stored: stored, current: account), stored: stored) { return paused }
        if case .removed(let reason) = try store.zoneState() { return .zoneRemoved(reason: reason) }
        if try store.isAccountFenced() { return .paused }
        let held = try store.quarantineRows().filter { !$0.ignoredByUser }
        if held.contains(where: { $0.reason.hasPrefix("version:") }) { return .needsAppUpdate }
        if !held.isEmpty { return .itemsUnreadable(count: held.count) }
        let missing = try store.allMissing()
        if !missing.isEmpty { return .itemsMissingInCloud(count: missing.count) }
        return .syncing
    }
}

extension CloudSyncStore {
    /// `ck_state.cloudUserHash`: the iCloud user this library syncs with; nil before `bind`.
    public func cloudUserHash() throws -> String? {
        try database.pool.read { try String.fetchOne($0, sql: "SELECT cloudUserHash FROM ck_state WHERE id=1") }
    }

    /// "Upload again" (CK-R15): the only way out of `removed`. It sets the zone state to `unknown`, from which `prepare()`
    /// creates the zone again. Returns false (and changes nothing) in any other state.
    @discardableResult
    public func chooseUploadAgain() throws -> Bool {
        guard case .removed = try zoneState() else { return false }
        try setZoneState(.unknown)
        return true
    }
}
