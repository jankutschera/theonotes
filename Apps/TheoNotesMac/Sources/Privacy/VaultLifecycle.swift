// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import Foundation

/// What the vault reacts to. Sleep, screen lock, screensaver and a switched-away login session
/// are all `.deviceLocked`: they relock at once. Resigning is the only event with a delay.
enum VaultLifecycleEvent: Sendable, Equatable {
    case appResigned
    case appBecameActive
    case deviceLocked
}

/// Keeps the observation alive; releasing it stops the events.
protocol VaultLifecycleObservation: AnyObject {}

@MainActor
protocol VaultLifecycleSource {
    func observe(_ handler: @escaping @MainActor (VaultLifecycleEvent) -> Void) -> any VaultLifecycleObservation
}

/// The three notification centers are injectable so a test posts the real names to its own.
/// `com.apple.screenIsLocked` and `com.apple.screensaver.didstart` are the distributed names the
/// system posts for the lock screen and the screensaver; they are not in Apple's reference docs
///, so the other events cover sleep and a switched-away session independently.
@MainActor
final class SystemVaultLifecycleSource: VaultLifecycleSource {
    static let screenLockedName = Notification.Name("com.apple.screenIsLocked")
    static let screensaverStartedName = Notification.Name("com.apple.screensaver.didstart")

    private final class Observation: VaultLifecycleObservation, @unchecked Sendable {
        private var tokens: [(NotificationCenter, any NSObjectProtocol)] = []
        func add(_ center: NotificationCenter, _ token: any NSObjectProtocol) { tokens.append((center, token)) }
        deinit { for (center, token) in tokens { center.removeObserver(token) } }
    }

    private let center: NotificationCenter
    private let workspace: NotificationCenter
    private let distributed: NotificationCenter

    init(center: NotificationCenter = .default,
         workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
         distributed: NotificationCenter = DistributedNotificationCenter.default()) {
        self.center = center
        self.workspace = workspace
        self.distributed = distributed
    }

    func observe(_ handler: @escaping @MainActor (VaultLifecycleEvent) -> Void) -> any VaultLifecycleObservation {
        let observation = Observation()
        func listen(_ center: NotificationCenter, _ name: Notification.Name, _ event: VaultLifecycleEvent) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler(event) }
            }
            observation.add(center, token)
        }
        listen(center, NSApplication.didResignActiveNotification, .appResigned)
        listen(center, NSApplication.didBecomeActiveNotification, .appBecameActive)
        listen(workspace, NSWorkspace.screensDidSleepNotification, .deviceLocked)
        listen(workspace, NSWorkspace.willSleepNotification, .deviceLocked)
        listen(workspace, NSWorkspace.sessionDidResignActiveNotification, .deviceLocked)
        listen(distributed, Self.screenLockedName, .deviceLocked)
        listen(distributed, Self.screensaverStartedName, .deviceLocked)
        return observation
    }
}
