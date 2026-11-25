// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import TheoNotesCore

/// Manually advanced clock for deterministic debounce tests.
final class TestClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Swift.Duration

        func advanced(by duration: Swift.Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Swift.Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private typealias Sleeper = (deadline: Instant, continuation: CheckedContinuation<Void, any Error>)

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [UUID: Sleeper] = [:]

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Swift.Duration { .zero }

    var sleeperCount: Int { lock.withLock { sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if deadline <= current {
                    lock.unlock()
                    continuation.resume()
                } else {
                    sleepers[id] = (deadline, continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            let sleeper = lock.withLock { sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Swift.Duration) {
        let ready: [Sleeper] = lock.withLock {
            current = current.advanced(by: duration)
            let due = sleepers.filter { $0.value.deadline <= current }
            for key in due.keys { sleepers.removeValue(forKey: key) }
            return Array(due.values)
        }
        for sleeper in ready { sleeper.continuation.resume() }
    }
}
