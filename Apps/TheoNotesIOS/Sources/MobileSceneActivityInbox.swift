// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import UIKit

/// Cold connection options can arrive before SwiftUI mounts the destination root.
/// Keep each delivery private to its actual OS scene session; no global navigation,
/// extra-window request or activity contents are broadcast to other windows.
@MainActor final class MobileSceneActivityInbox {
    static let shared = MobileSceneActivityInbox()
    static let notification = Notification.Name("MobileSceneActivityInbox.received")
    private struct Entry {
        var pending: MobileNoteSceneAddress?
        var seen: Set<UUID> = []
    }
    private var entries: [String: Entry] = [:]
    private let center: NotificationCenter
    private let maximumSessions: Int
    private let maximumDeliveriesPerSession: Int
    init(center: NotificationCenter = .default, maximumSessions: Int = 64, maximumDeliveriesPerSession: Int = 64) {
        self.center = center
        self.maximumSessions = max(1, maximumSessions)
        self.maximumDeliveriesPerSession = max(1, maximumDeliveriesPerSession)
    }
    @discardableResult func receiveCold(_ activities: Set<NSUserActivity>, sceneSessionID: String) -> Bool {
        let relevant = activities.filter { $0.activityType == MobileNoteSceneActivation.activityType }
        // Connection options have no meaningful order. Never pick an arbitrary target.
        guard relevant.count == 1, let activity = relevant.first else { return false }
        return receive(activity, sceneSessionID: sceneSessionID)
    }
    @discardableResult func receive(_ activity: NSUserActivity, sceneSessionID: String) -> Bool {
        guard !sceneSessionID.isEmpty, sceneSessionID.utf8.count <= 256,
              let address = try? MobileNoteSceneActivation.address(from: activity) else { return false }
        guard entries[sceneSessionID] != nil || entries.count < maximumSessions else { return false }
        var entry = entries[sceneSessionID] ?? Entry()
        guard !entry.seen.contains(address.windowID), entry.seen.count < maximumDeliveriesPerSession else { return false }
        entry.seen.insert(address.windowID)
        entry.pending = address // The latest explicit intent wins within THIS scene only.
        entries[sceneSessionID] = entry
        center.post(name: Self.notification, object: sceneSessionID)
        return true
    }
    func take(sceneSessionID: String) -> MobileNoteSceneAddress? {
        guard var entry = entries[sceneSessionID] else { return nil }
        let pending = entry.pending
        entry.pending = nil
        entries[sceneSessionID] = entry
        return pending
    }
    /// Called only by the actual UIKit scene disconnection callback, never a sheet
    /// disappearance or a shared-library view replacement.
    func disconnect(sceneSessionID: String) { entries.removeValue(forKey: sceneSessionID) }
}

extension MobileQuickActionSceneDelegate {
    @objc func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        MobileSceneActivityInbox.shared.receive(userActivity, sceneSessionID: scene.session.persistentIdentifier)
    }
    @objc func sceneDidDisconnect(_ scene: UIScene) {
        MobileSceneActivityInbox.shared.disconnect(sceneSessionID: scene.session.persistentIdentifier)
    }
}
