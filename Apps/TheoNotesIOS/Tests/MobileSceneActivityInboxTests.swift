// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import UIKit
@testable import BaerchenIOS

@Suite(.serialized) @MainActor struct MobileSceneActivityInboxTests {
    private func activity() throws -> NSUserActivity {
        MobileNoteSceneActivation.activity(for: try MobileNoteSceneAddress(libraryID: String(repeating: "a", count: 64), noteID: UUID().uuidString))
    }
    @Test func coldDeliveryWaitsForMatchingSceneAndWarmReplayIsDeduplicated() throws {
        let inbox = MobileSceneActivityInbox()
        let activity = try activity()
        let expected = try MobileNoteSceneActivation.address(from: activity)
        #expect(inbox.receiveCold([activity], sceneSessionID: "scene-A"))
        #expect(inbox.take(sceneSessionID: "scene-B") == nil)
        #expect(inbox.take(sceneSessionID: "scene-A") == expected)
        #expect(!inbox.receive(activity, sceneSessionID: "scene-A"))
        #expect(inbox.take(sceneSessionID: "scene-A") == nil)
        #expect(inbox.receive(activity, sceneSessionID: "scene-B"))
        #expect(inbox.take(sceneSessionID: "scene-B") == expected)
    }
    @Test func notificationsContainOnlyDestinationSessionAndLatestLocalIntentWins() throws {
        let center = NotificationCenter()
        let inbox = MobileSceneActivityInbox(center: center)
        let first = try activity(), second = try activity()
        // NotificationCenter delivery is synchronous on this main-actor invocation.
        let observed = NotificationReceipt()
        let token = center.addObserver(forName: MobileSceneActivityInbox.notification, object: nil, queue: nil) { note in
            observed.record(session: note.object as? String, hasUserInfo: note.userInfo != nil)
        }
        defer { center.removeObserver(token) }
        #expect(inbox.receive(first, sceneSessionID: "scene-A"))
        #expect(inbox.receive(second, sceneSessionID: "scene-A"))
        #expect(observed.sessions == ["scene-A", "scene-A"] && !observed.hasUserInfo)
        #expect(inbox.take(sceneSessionID: "scene-A") == (try MobileNoteSceneActivation.address(from: second)))
    }
    @Test func malformedAmbiguousAndOverCapacityDeliveriesFailClosed() throws {
        let inbox = MobileSceneActivityInbox(maximumSessions: 1, maximumDeliveriesPerSession: 1)
        let first = try activity(), second = try activity()
        #expect(!inbox.receiveCold([first, second], sceneSessionID: "scene-A"))
        #expect(!inbox.receive(NSUserActivity(activityType: "foreign"), sceneSessionID: "scene-A"))
        #expect(inbox.receive(first, sceneSessionID: "scene-A"))
        #expect(!inbox.receive(second, sceneSessionID: "scene-A"))
        #expect(!inbox.receive(second, sceneSessionID: "scene-B"))
        inbox.disconnect(sceneSessionID: "scene-A")
        #expect(inbox.take(sceneSessionID: "scene-A") == nil)
        #expect(inbox.receive(second, sceneSessionID: "scene-B"))
    }
    @Test func sceneDelegateExposesObjectiveCContinuationAndDisconnectCallbacks() {
        let delegate = MobileQuickActionSceneDelegate()
        #expect(delegate.responds(to: NSSelectorFromString("scene:continueUserActivity:")))
        #expect(delegate.responds(to: NSSelectorFromString("sceneDidDisconnect:")))
    }
}

private final class NotificationReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    private var info = false
    func record(session: String?, hasUserInfo: Bool) {
        lock.lock(); defer { lock.unlock() }
        if let session { values.append(session) }; info = info || hasUserInfo
    }
    var sessions: [String] { lock.lock(); defer { lock.unlock() }; return values }
    var hasUserInfo: Bool { lock.lock(); defer { lock.unlock() }; return info }
}
