// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation

// One sync cycle (Task 10, CK-R4, CK-R5, CK-R15): resolve what an earlier run left unknown -> fetch -> apply -> prepare ->
// blobs -> submit -> consume results -> apply the echoes, round after round until nothing moves. Every gateway call and every
// download runs through `CloudGenerationFence.run`, so an account change cancels and drains it and a late completion of the
// old account writes nothing (the stores check the generation themselves).
//
// A cycle with `uploads: false` is the download-first half of the first run: it fetches and applies, and never prepares,
// blobs or submits. The key bundle record, when another device replaced it, is noticed by the sink and refreshed after the fetch.

/// The key bundle did not verify: data work is held and the state says why (CK-R135).
struct CloudKeyHold: Error, Equatable { let state: CloudSyncState }

public struct CloudCycleReport: Sendable, Equatable {
    public var rounds = 0
    public var fetches = 0
    public var applied = 0
    public var saved = 0
    public var merged = 0
    /// Fetched versions that wait for the note password.
    public var waitingForUnlock = 0
    public var waitingForDependency = 0
    /// The round limit was reached while there was still work.
    public var moreWork = false
    /// Uploads are held because iCloud has no room (CK-R15); the coordinator reports `quotaFull` instead of "up to date".
    public var quotaHeld = false
    public init() {}
}

/// Set from the sink (which runs inside the gateway's fetch) when a `KeyBundle` record arrives.
final class CloudChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func raise() { lock.withLock { raised = true } }
    /// Stays raised until the new bundle was verified (`clear`): a failed or interrupted verification is repeated by the next cycle.
    var isRaised: Bool { lock.withLock { raised } }
    func clear() { lock.withLock { raised = false } }
}

struct CloudSyncSession: Sendable {
    static let maximumRounds = 64

    let library: any CloudSyncLibrary
    let store: CloudSyncStore
    let gateway: any CloudKitGateway
    let fence: CloudGenerationFence
    let keys: AccountKeys
    let pinner: CloudAssetPinner
    let transfer: CloudKitBlobTransfer
    let publisher: CloudPublisher
    let changed: CloudChangeFlag
    let appBuild: String?
    let step: @Sendable (String) async throws -> Void
    let crash: CrashPoint
    /// Verifies the key bundle again (online, through the key layer's pins) and throws `CloudKeyHold` when it does not hold up.
    let verifyKeys: @Sendable () async throws -> Void
    /// The shipped versions of each starter note (STARTER-R2); a test swaps in the single-version list of a 1.0.x build.
    var starterVersions: [String: [Data]] = CloudStarterBase.shippedPayloads

    var accountID: String { keys.accountID }

    func makeSink(generation: Int64? = nil) -> CloudFeedSink {
        let flag = changed
        var provider: (@Sendable () throws -> Int64)?
        if let generation { provider = { @Sendable () throws -> Int64 in generation } }
        return CloudFeedSink(store: store, pinner: pinner, crash: crash, generation: provider, onKeyBundle: { _ in flag.raise() }, onUnreadableKeyBundle: { flag.raise() })
    }

    func makeReconciler(generation: Int64, access: LockedNoteAccess?, password: String?) -> CloudReconciler {
        let sealer = CloudPayloadSealer(accountID: accountID, vaultKey: keys.vaultKey)
        return CloudReconciler(database: library.database, paths: library.paths, store: store, accountID: accountID, vaultKey: keys.vaultKey,
                               pinner: pinner, blobs: transfer, coordinator: library.commitCoordinator, crash: crash,
                               generation: { generation }, noteAccess: { access }, notePassword: { password },
                               firstContactVersions: CloudStarterBase.sealedVersions(sealer: sealer, payloads: starterVersions),
                               locallyDeletedStarters: (try? store.deletedStarters()) ?? [])
    }

    func run(uploads: Bool, access: LockedNoteAccess?, notePassword: String?) async throws -> CloudCycleReport {
        var report = CloudCycleReport()
        try await step("cycle.begin")
        for _ in 0..<Self.maximumRounds {
            report.rounds += 1
            var progressed = false
            if uploads {
                let consumed = try publisher.consumeResults()
                if consumed.saved > 0 { report.saved += consumed.saved; progressed = true }
                // An answer that arrived since the last cycle (the live engine answers later) is consumed here and counts too.
                if consumed.quotaHeld > 0 { report.quotaHeld = true }
                // An earlier run's unknown outcome: the fence-level resolution claims what is provably ours; the publisher's
                // own table (CK-R4) decides the rest inside `publishCycle`.
                _ = try await fence.resolveUnknownOutcomes(using: gateway)
            }
            try await fetch()
            report.fetches += 1
            // A key bundle that changed in the cloud is verified before anything else is done with this cycle's data: no apply, no
            // publish. A failure holds the work; the flag stays up, so the next cycle verifies again before it does anything.
            if changed.isRaised { try await verifyKeys() }
            let sink = makeSink()
            _ = try CloudQuarantine(store: store, pinner: pinner, sink: sink).retryAll(appBuild: appBuild)
            try await step("cycle.afterFetch")
            let applied = try await apply(access: access, password: notePassword)
            report.applied += applied.applied.count
            report.waitingForUnlock = applied.waitingForUnlock.count
            report.waitingForDependency = applied.waitingForDependency.count
            if !applied.applied.isEmpty { progressed = true }
            try await step("cycle.afterApply")
            if uploads {
                try await step("cycle.beforeUpload")
                let published = try await publish()
                try await step("cycle.afterUpload")
                report.saved += published.saved
                report.merged += published.needsMerge.count
                if published.quotaHeld > 0 { report.quotaHeld = true }       // across all rounds, never overwritten
                if published.saved > 0 || !published.needsMerge.isEmpty || published.advanced.count > 0 { progressed = true }
            }
            if report.quotaHeld { return report }      // no room in iCloud: another round would only be refused again
            if !progressed { return report }
        }
        report.moreWork = true
        return report
    }

    private func fetch() async throws {
        try await fence.run { generation in
            try await gateway.fetchChanges(into: makeSink(generation: generation))
        }
    }

    private func apply(access: LockedNoteAccess?, password: String?) async throws -> CloudApplyReport {
        try await fence.run { generation in
            try await makeReconciler(generation: generation, access: access, password: password).applyPending()
        }
    }

    private func publish() async throws -> CloudPublishReport {
        try await fence.run { _ in try await publisher.publishCycle() }
    }
}
