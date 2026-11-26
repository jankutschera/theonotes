// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

public struct CloudQuarantineSummary: Sendable, Equatable {
    /// Records written by a newer format or payload version: "Some items wait for an app update".
    public var needsAppUpdate = 0
    /// Records that are damaged or do not belong to their name: "N items in iCloud could not be read".
    public var unreadable = 0
    /// Items the person chose to ignore (their fence is lifted, their files are gone).
    public var ignored = 0
    public init() {}
}

public struct CloudQuarantineRetryReport: Sendable, Equatable {
    public var released: [String] = []
    public var stillQuarantined: [String] = []
    public init() {}
}

/// The person-facing side of the quarantine: retry, the two status counts, and the explicit "Ignore this item".
/// Nothing is ever deleted in the cloud, and a quarantine row is removed only when its version is understood and stored, a newer
/// valid version replaced it (the sink does that), or the person ignores it.
public struct CloudQuarantine: Sendable {
    private let store: CloudSyncStore
    private let pinner: CloudAssetPinner
    private let sink: CloudFeedSink

    public init(store: CloudSyncStore, pinner: CloudAssetPinner, sink: CloudFeedSink) {
        self.store = store; self.pinner = pinner; self.sink = sink
    }

    /// Retried at launch, after an app-build change and each cycle, always from the pinned copies. A record that the format
    /// rejected (`version:`, shape, name) is decoded again every time; one that opened badly (`payload:`) is only worth another
    /// try when the app build changed, so those wait for `appBuild` to differ from the last build that tried them.
    @discardableResult
    public func retryAll(appBuild: String? = nil) throws -> CloudQuarantineRetryReport {
        var report = CloudQuarantineRetryReport()
        let lastBuild = try store.lastAppBuild()
        let buildChanged = appBuild != nil && appBuild != lastBuild
        for row in try store.quarantineRows() where !row.ignoredByUser {
            if row.reason.hasPrefix("payload:"), !buildChanged { report.stillQuarantined.append(row.recordName); continue }
            if try sink.retryQuarantined(row, pinned: row.pinnedAssets) { report.released.append(row.recordName) }
            else { report.stillQuarantined.append(row.recordName) }
        }
        if let appBuild, buildChanged { try store.setLastAppBuild(appBuild) }
        return report
    }

    /// "Ignore this item": explicit, recorded, the fence lifts, the pinned files are deleted.
    public func ignore(recordName: String) throws {
        pinner.remove(try store.ignoreQuarantine(recordName: recordName))
    }

    public func summary() throws -> CloudQuarantineSummary {
        var summary = CloudQuarantineSummary()
        for row in try store.quarantineRows() {
            if row.ignoredByUser { summary.ignored += 1 }
            else if row.reason.hasPrefix("version:") || row.reason == "payload:unsupported" { summary.needsAppUpdate += 1 }
            else { summary.unreadable += 1 }
        }
        return summary
    }
}

extension CloudSyncStore {
    func lastAppBuild() throws -> String? {
        try database.pool.read { try String.fetchOne($0, sql: "SELECT lastAppBuild FROM ck_state WHERE id=1") }
    }
    func setLastAppBuild(_ build: String) throws {
        try database.pool.write { try $0.execute(sql: "UPDATE ck_state SET lastAppBuild=? WHERE id=1", arguments: [build]) }
    }
}
