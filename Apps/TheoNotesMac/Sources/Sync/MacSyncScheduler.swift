// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Network

@MainActor final class MacSyncScheduler {
    enum Outcome: Equatable { case success(pending: Bool), deferred, needsUser, failed(retryAfter: TimeInterval?) }
    private weak var controller: MacSyncController?
    private var observation: ObservationToken?
    private var monitor: NWPathMonitor?
    private var wake: Task<Void, Never>?
    private var running: Task<Void, Never>?
    private var retry = SyncRetrySchedule()
    private var deadline: Date?
    private var retryNotBefore: Date?
    private var serverNotBefore: Date?
    private var active = false
    private var online = true
    private var stopped = false
    private var lifecycle: [(NotificationCenter, NSObjectProtocol)] = []

    init(controller: MacSyncController, library: AppEnvironment) {
        self.controller = controller
        observation = SyncQueue(database: library.database).observePending(onError: { [weak controller] error in
            controller?.errorMessage = error.localizedDescription
        }, onChange: { [weak self] work in
            if work.count > 0 { self?.request(after: 1, debounce: true) }
        })
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                let restored = !self.online && available
                self.online = available
                if restored { self.retry.reset(); self.retryNotBefore = self.serverNotBefore; self.request(after: 0) }
            }
        }
        self.monitor = monitor
        monitor.start(queue: DispatchQueue(label: "com.truebrewbirdie.baerchen.sync-connectivity"))
        setActive(true)
        let secrets = NotificationCenter.default.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { [weak controller] _ in
            MainActor.assumeIsolated { controller?.setSensitivePresentation(false) }
        }
        lifecycle.append((NotificationCenter.default, secrets))
        for (center, name, resumes) in [
            (NotificationCenter.default, NSApplication.didBecomeActiveNotification, true),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification, false),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification, true)
        ] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self, weak controller] _ in
                MainActor.assumeIsolated {
                    if name == NSApplication.didBecomeActiveNotification { controller?.setSensitivePresentation(true) }
                    self?.setActive(resumes)
                }
            }
            lifecycle.append((center, token))
        }
    }

    func setActive(_ value: Bool) {
        guard !stopped else { return }
        active = value
        if value { request(after: 0) }
        else {
            wake?.cancel(); wake = nil; deadline = nil
        }
    }

    func request(after seconds: TimeInterval = 0, debounce: Bool = false) {
        guard !stopped, active, controller?.paused != true else { return }
        let seconds = max(seconds, retryNotBefore?.timeIntervalSinceNow ?? 0)
        let next = Date.now.addingTimeInterval(max(0, seconds))
        if !debounce, let deadline, deadline <= next { return }
        wake?.cancel(); deadline = next
        wake = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, seconds))) } catch { return }
            guard let self, !self.stopped else { return }
            self.wake = nil; self.deadline = nil
            self.startRun()
        }
    }

    private func startRun() {
        guard active, !stopped, let controller, !controller.paused else { return }
        guard online else { request(after: 30); return }
        guard running == nil, !controller.busy else { request(after: 2); return }
        running = Task { [weak self, weak controller] in
            guard let self, let controller else { return }
            let outcome = await controller.refreshAutomatically()
            self.running = nil
            guard !self.stopped else { return }
            let delay: TimeInterval
            switch outcome {
            case .success(let pending): self.retry.reset(); self.retryNotBefore = nil; self.serverNotBefore = nil; delay = pending ? 3 : 60
            case .deferred: delay = 2
            case .needsUser: delay = 300
            case .failed(let retryAfter):
                delay = self.retry.failed(retryAfter: retryAfter)
                self.retryNotBefore = .now.addingTimeInterval(delay)
                if let retryAfter, retryAfter.isFinite, retryAfter > 0 { self.serverNotBefore = .now.addingTimeInterval(retryAfter) }
                self.wake?.cancel(); self.wake = nil; self.deadline = nil
            }
            self.request(after: delay)
        }
    }

    func cancelScheduledWork() {
        stopped = true; active = false
        wake?.cancel(); wake = nil; deadline = nil
        observation?.cancel(); observation = nil
        monitor?.cancel(); monitor = nil
        lifecycle.forEach { $0.0.removeObserver($0.1) }; lifecycle = []
    }

    isolated deinit {
        wake?.cancel(); running?.cancel(); observation?.cancel(); monitor?.cancel()
        lifecycle.forEach { $0.0.removeObserver($0.1) }
    }

    func stop() async {
        cancelScheduledWork()
        running?.cancel()
        await controller?.cancelAutomaticRun()
        await running?.value; running = nil
    }
}
