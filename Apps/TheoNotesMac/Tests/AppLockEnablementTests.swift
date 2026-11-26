// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Testing
@testable import TheoNotes

/// Turning App Lock on or off in Settings reaches the reminders at once, with the real
/// `AppLock` and `AppEnvironment`. Only the system prompt and the notification center are fakes.
@MainActor
@Suite struct AppLockEnablementTests {
    @Test func setEnabledTrueRedactsWithoutEngaging() async throws {
        let env = try ReminderEnv()
        try env.lineReminder()
        await env.reminders.reconcile()
        let oldId = try #require(env.center.pending.keys.first)
        env.center.deliver(oldId)
        #expect(!env.environment.appLock.isEnabled && !env.environment.appLock.isLocked)

        env.authenticator.script(.success)
        #expect(await env.environment.appLock.setEnabled(true) == .enabled)

        #expect(env.center.removedDeliveredNow.contains(oldId), "the delivered text goes synchronously, before the replan")
        // Nothing here asks for a reconcile: the enabled-change hook itself must replan.
        await env.waitUntil { env.center.pendingRequests.map(\.title) == ["Theo Notes"] }
        #expect(env.center.delivered.isEmpty)
        let requests = env.center.pendingRequests
        #expect(requests.map(\.title) == ["Theo Notes"])
        #expect(requests.map { $0.body ?? "" } == ["Reminder"])
        #expect(requests.first?.identifier != oldId)
        #expect(!env.environment.appLock.isLocked, "enabling does not engage the lock")
    }

    @Test func setEnabledFalseReplansWithText() async throws {
        let first = try ReminderEnv()
        try first.lineReminder()
        let env = try first.relaunch(appLockEnabled: true)
        await env.reminders.reconcile()
        #expect(env.center.pendingRequests.map(\.title) == ["Theo Notes"])
        #expect(env.environment.appLock.isLocked)

        env.authenticator.script(.success)
        #expect(await env.environment.appLock.setEnabled(false) == .disabled)
        await env.waitUntil { env.center.pendingRequests.map(\.title) == ["Title"] }

        let requests = env.center.pendingRequests
        #expect(requests.map(\.title) == ["Title"])
        #expect(requests.map { $0.body ?? "" } == ["buy milk"])
    }

    @Test func enabledChangeHandlerFiresOnceForEachRealChange() async throws {
        let fixture = try AppLockFixture(enabled: false)
        defer { fixture.destroy() }
        let lock = fixture.makeLock()
        var seen: [Bool] = []
        let token = lock.addEnabledChangeHandler { seen.append($0) }

        fixture.authenticator.script(.cancelled)
        #expect(await lock.setEnabled(true) == .cancelled)
        fixture.authenticator.script(.failed)
        #expect(await lock.setEnabled(true) == .failed)
        #expect(seen.isEmpty, "a prompt that did not pass changes nothing")

        fixture.authenticator.script(.success)
        #expect(await lock.setEnabled(true) == .enabled)
        #expect(await lock.setEnabled(true) == .enabled)
        #expect(seen == [true], "turning on what is on fires nothing")
        #expect(await lock.setEnabled(false) == .disabled)
        #expect(seen == [true, false])

        lock.removeEnabledChangeHandler(token)
        #expect(await lock.setEnabled(true) == .enabled)
        #expect(seen == [true, false])
    }

    @Test func theHandlerSeesTheNewStateAndTheStoredSetting() async throws {
        let fixture = try AppLockFixture(enabled: false)
        defer { fixture.destroy() }
        let lock = fixture.makeLock()
        var observed: [(Bool, Bool, Bool)] = []
        lock.addEnabledChangeHandler { [settings = fixture.settings] enabled in
            observed.append((enabled, lock.isEnabled, settings.appLockEnabled))
        }
        fixture.authenticator.script(.success)
        _ = await lock.setEnabled(true)
        #expect(observed.count == 1 && observed[0] == (true, true, true))
    }
}
