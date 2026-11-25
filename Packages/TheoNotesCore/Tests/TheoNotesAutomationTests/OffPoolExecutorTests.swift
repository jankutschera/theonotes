// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Synchronization
import Testing
@testable import TheoNotesAutomation

@Suite struct OffPoolExecutorTests {
    /// Twice as many synchronous waits as the machine has cores, each on a pool thread, each for a
    /// task on `OffPoolExecutor`: every task must run although the pool is blocked. (With a concurrent
    /// GCD queue the jobs were enqueued but got no thread, and the CLI's blocking bridges deadlocked
    /// the test process.) Bounded: a task that does not run within 3 s counts as a failure.
    @Test func itsTasksRunWhileEveryCooperativeThreadIsBlocked() async {
        let width = ProcessInfo.processInfo.activeProcessorCount * 2
        let outcomes = Mutex<[Bool]>([])
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<width {
                group.addTask {
                    let done = DispatchSemaphore(value: 0)
                    let ranOffThePool = Mutex(false)
                    Task.detached(executorPreference: OffPoolExecutor.shared) {
                        ranOffThePool.withLock { $0 = OffPoolExecutor.isCurrent }
                        await Task.yield()
                        done.signal()
                    }
                    let signaled = waitBlocking(done, seconds: 3)
                    outcomes.withLock { $0.append(signaled && ranOffThePool.withLock { $0 }) }
                }
            }
        }
        #expect(outcomes.withLock { $0 } == Array(repeating: true, count: width))
    }
}

/// Blocks the calling thread, as a synchronous test on the pool does.
private func waitBlocking(_ semaphore: DispatchSemaphore, seconds: Double) -> Bool {
    semaphore.wait(timeout: .now() + seconds) == .success
}
