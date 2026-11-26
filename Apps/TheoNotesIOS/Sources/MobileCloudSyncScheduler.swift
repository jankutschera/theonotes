// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import UIKit

/// When the iCloud sync runs a cycle on the iPhone and iPad. Push is never the only trigger (Gate G0 A4 measured a
/// silent push at 15 s, but the system may delay or drop one): the app comes to the front, a local edit has settled
/// (`SyncQueue.observePending`, debounced), a 5-minute timer while the app runs, a retry the coordinator asks for, and, outside this
/// class, the launch fetch (`MobileCloudSyncController.start`), the silent push and the `BGAppRefreshTask` under the existing identifier.
/// Changes that arrive from iCloud are the gateway's events; the coordinator listens to them itself, so the scheduler does not repeat that.
/// It only exists while the person's switch is on: an off library has no observer, no timer and no notification handler.
@MainActor final class MobileCloudSyncScheduler {
    struct Timing: Sendable {
        /// Quiet time after the last local edit before a cycle starts.
        var debounce: TimeInterval = 1.5
        /// The timer that catches whatever no event announced.
        var interval: TimeInterval = 300
        /// The shortest wait before a retry after a failure.
        var retryFloor: TimeInterval = 5
        /// Used when the last cycle ended with "the person has to act": a slow look, not a loop.
        var needsPersonInterval: TimeInterval = 300
        init(debounce: TimeInterval = 1.5, interval: TimeInterval = 300, retryFloor: TimeInterval = 5, needsPersonInterval: TimeInterval = 300) {
            self.debounce = debounce; self.interval = interval; self.retryFloor = retryFloor; self.needsPersonInterval = needsPersonInterval
        }
    }

    enum Reason: Equatable, Sendable { case foreground, localChange, timer, retry }

    enum Outcome: Equatable, Sendable {
        /// The cycle ran; nothing is waiting.
        case done
        /// Something else is busy right now; try again shortly.
        case later
        /// A person has to do something first (a password, recovery words, a choice).
        case needsPerson
        case retry(after: TimeInterval)
        /// The sync is gone (switched off): stop scheduling.
        case stop
    }

    private let database: AppDatabase
    private let timing: Timing
    private let run: @MainActor (Reason) async -> Outcome
    private let didEnterBackground: @MainActor () -> Void
    private var observation: ObservationToken?
    private var lifecycle: [NSObjectProtocol] = []
    private var wake: Task<Void, Never>?
    private var running = false
    private var stopped = false
    private var started = false
    private var lastPending: SyncPendingWork?
    /// What the scheduled wake-up will run, for a test.
    private(set) var nextReason: Reason?
    private(set) var cyclesRun = 0

    init(database: AppDatabase, timing: Timing, didEnterBackground: @escaping @MainActor () -> Void = {},
         run: @escaping @MainActor (Reason) async -> Outcome) {
        self.database = database; self.timing = timing; self.run = run; self.didEnterBackground = didEnterBackground
    }

    isolated deinit {
        wake?.cancel(); observation?.cancel()
        lifecycle.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func start() {
        guard !started, !stopped else { return }
        started = true
        observation = SyncQueue(database: database).observePending(onError: { _ in }, onChange: { [weak self] work in
            guard let self else { return }
            // A cycle's own clean-up lowers the numbers; only a change that leaves work behind asks for a cycle.
            let previous = self.lastPending
            self.lastPending = work
            guard work.count > 0, work != previous else { return }
            self.request(.localChange, after: self.timing.debounce, debounce: true)
        })
        lifecycle.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.request(.foreground, after: 0) }
        })
        lifecycle.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didEnterBackground() }
        })
        request(.timer, after: timing.interval)
    }

    func stop() {
        stopped = true
        wake?.cancel(); wake = nil; nextReason = nil
        observation?.cancel(); observation = nil
        lifecycle.forEach { NotificationCenter.default.removeObserver($0) }
        lifecycle = []
    }

    /// Asks for a cycle `seconds` from now. A sooner request replaces a later one; a debounced request replaces any (the quiet time
    /// restarts at every edit).
    func request(_ reason: Reason, after seconds: TimeInterval, debounce: Bool = false) {
        guard !stopped else { return }
        let delay = max(0, seconds)
        if !debounce, wake != nil, let due = dueDate, due <= Date().addingTimeInterval(delay) { return }
        wake?.cancel()
        dueDate = Date().addingTimeInterval(delay)
        nextReason = reason
        wake = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.fire(reason)
        }
    }

    private var dueDate: Date?

    private func fire(_ reason: Reason) async {
        guard !stopped else { return }
        wake = nil; dueDate = nil; nextReason = nil
        guard !running else { request(reason, after: 1); return }
        running = true
        let outcome = await run(reason)
        running = false
        cyclesRun += 1
        guard !stopped else { return }
        switch outcome {
        case .done: request(.timer, after: timing.interval)
        case .later: request(reason, after: 2)
        case .needsPerson: request(.timer, after: timing.needsPersonInterval)
        case .retry(let seconds): request(.retry, after: max(seconds, timing.retryFloor))
        case .stop: stop()
        }
    }
}
