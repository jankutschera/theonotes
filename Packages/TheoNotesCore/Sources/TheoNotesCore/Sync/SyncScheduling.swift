// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

public struct SyncPendingWork: Equatable, Sendable {
    public let count: Int
    public let generation: Int64
}

extension SyncQueue {
    /// Dirty generations change even when a later edit leaves the number of queued notes
    /// unchanged. Observe commits, never editor keystrokes or derived search/OCR rows.
    @MainActor public func observePending(onError: @escaping @MainActor (Error) -> Void,
                                         onChange: @escaping @MainActor (SyncPendingWork) -> Void) -> ObservationToken {
        let cancellable = ValueObservation.tracking { db in
            SyncPendingWork(count: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_dirty") ?? 0,
                generation: try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(generation),0) FROM sync_dirty") ?? 0)
        }.start(in: database.pool, scheduling: .immediate, onError: onError, onChange: onChange)
        return ObservationToken { cancellable.cancel() }
    }
}

public struct SyncRetrySchedule: Sendable {
    public private(set) var failures = 0
    public init() {}
    public mutating func reset() { failures = 0 }
    public mutating func failed(retryAfter: TimeInterval? = nil, jitter: Double = Double.random(in: 0.8...1.2)) -> TimeInterval {
        failures = min(failures + 1, 9)
        let delay = min(300, pow(2, Double(failures))) * min(1.2, max(0.8, jitter.isFinite ? jitter : 1))
        let server = retryAfter.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0
        return max(delay, server)
    }
}
