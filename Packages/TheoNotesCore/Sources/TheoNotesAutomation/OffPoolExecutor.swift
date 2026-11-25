// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// Async work that must not wait for a thread of the shared cooperative pool. Each job runs on a
/// serial GCD queue of its own: GCD gives serial queues overcommit threads, which it starts even
/// when the cooperative threads are all blocked. (A concurrent queue would not do: it targets the
/// same constrained default-QoS pool, and with every cooperative thread blocked it got no thread.)
///
/// Two kinds of work need it. A fetch's limits (`HTTPSFetcher` total, idle and lookup timeouts) are
/// wall-clock timers; work on the pool can wait behind any backlog of synchronous jobs in the same
/// process (the start of a parallel test run queues hundreds), and that wait used to count against
/// the limits, so every fetch "timed out" together. And the CLI's blocking bridges (`CLIBlocking`,
/// `mcp-server`) wait on the calling thread for async work: when the caller is itself a pool thread
/// (every synchronous test is one) and the work needs the pool, enough such waits at once deadlock
/// the process.
final class OffPoolExecutor: TaskExecutor, @unchecked Sendable {
    static let shared = OffPoolExecutor()

    private static let key = DispatchSpecificKey<Bool>()

    private init() {}

    /// True on a thread that runs one of this executor's jobs.
    static var isCurrent: Bool { DispatchQueue.getSpecific(key: key) == true }

    /// Where a fetch's timers fire (deadline, idle wait, lookup timeout): a serial queue, so GCD
    /// serves it with an overcommit thread like the jobs above. On the constrained global queue a
    /// timer could fire late while the work it bounds ran, or early relative to work stuck there.
    static let timers = DispatchQueue(label: "com.truebrewbirdie.baerchen.off-pool.timers")

    /// A serial queue of its own for one fetch's `URLSession` delegate callbacks (overcommit, as above).
    static func delegateQueue() -> OperationQueue {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.underlyingQueue = DispatchQueue(label: "com.truebrewbirdie.baerchen.off-pool.delegate")
        return queue
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        let queue = DispatchQueue(label: "com.truebrewbirdie.baerchen.off-pool")
        queue.setSpecific(key: Self.key, value: true)
        queue.async { job.runSynchronously(on: executor) }
    }
}
