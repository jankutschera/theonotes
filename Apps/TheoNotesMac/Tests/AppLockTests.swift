// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import SwiftUI
import Testing
@testable import TheoNotes

/// M9M task 6: App Lock. Libraries are temporary folders under /tmp, the authenticator is a fake
/// (no Touch ID prompt, no real Keychain) and time is moved by hand.
final class FakeAppAuthenticator: AppAuthenticator, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [AppAuthResult] = []
    private var calls = 0
    private var reasons: [String] = []
    private var held: [CheckedContinuation<Void, Never>] = []
    private var holding = false
    private var availableFlag = true
    var available: Bool {
        get { lock.withLock { availableFlag } }
        set { lock.withLock { availableFlag = newValue } }
    }

    /// What the next authentications answer; the last entry repeats.
    func script(_ results: AppAuthResult...) { lock.withLock { self.results = results } }
    var callCount: Int { lock.withLock { calls } }
    var askedReasons: [String] { lock.withLock { reasons } }
    func holdPrompts() { lock.withLock { holding = true } }
    func releasePrompts() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            holding = false
            let copy = held
            held = []
            return copy
        }
        for continuation in waiting { continuation.resume() }
    }

    func canAuthenticate() -> Bool { available }

    private var invalidationCount = 0
    /// How often a prompt that was up was ended from outside.
    var invalidations: Int { lock.withLock { invalidationCount } }
    func invalidatePending() { lock.withLock { invalidationCount += 1 } }

    func authenticate(reason: String) async -> AppAuthResult {
        let shouldHold = lock.withLock { () -> Bool in
            calls += 1
            reasons.append(reason)
            return holding
        }
        if shouldHold {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { () -> Bool in
                    if holding { held.append(continuation); return false }
                    return true
                }
                if resumeNow { continuation.resume() }
            }
        }
        return lock.withLock { results.count > 1 ? results.removeFirst() : (results.first ?? .success) }
    }
}

/// A temporary library, a fake authenticator, a manual lifecycle source, a manual clock and a
/// settable system idle time: everything `AppLock` reads from the outside.
@MainActor
struct AppLockFixture {
    let library: VaultLibrary
    let authenticator = FakeAppAuthenticator()
    let lifecycle = ManualLifecycleSource()
    let clock = ManualVaultClock()
    let idle = IdleBox()
    var settings: TheoNotesCore.Settings { library.settings }

    final class IdleBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 0
        var seconds: TimeInterval {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    /// `enabled` and `delay` are stored before the lock is made, as they are at a launch.
    init(enabled: Bool, delay: Int? = nil) throws {
        library = try VaultLibrary()
        settings.appLockEnabled = enabled
        if let delay { settings.appLockDelay = delay }
    }

    /// `active: false` is an app that is not in front: its lock screen asks for no prompt by itself.
    func makeLock(active: Bool = true) -> AppLock {
        let idle = idle
        return AppLock(
            settings: settings, authenticator: authenticator, lifecycle: lifecycle, clock: clock,
            idleSeconds: { idle.seconds }, isAppActive: { active })
    }

    func destroy() { library.destroy() }
}

@MainActor
@Suite struct AppLockTests {
    // MARK: launch

    @Test func isLockedAtLaunchOnlyWhenEnabled() throws {
        let off = try AppLockFixture(enabled: false)
        defer { off.destroy() }
        #expect(!off.makeLock().isLocked)
        let on = try AppLockFixture(enabled: true)
        defer { on.destroy() }
        let lock = on.makeLock()
        #expect(lock.isLocked && lock.isEnabled)
        #expect(on.authenticator.callCount == 0, "nothing prompts until the lock screen asks")
    }

    @Test func lockedAtLaunchHidesContentUntilAuthenticated() async throws {
        let fixture = try AppLockFixture(enabled: true)
        defer { fixture.destroy() }
        let lock = fixture.makeLock(active: false)
        let probe = GateProbe(secret: "SECRET-NOTE-TITLE-zqx")
        let host = NSHostingView(rootView: AppLockGate(lock: lock) { probe.content() })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()

        // Locked: the content closure never ran, so no note title or text was even made.
        #expect(probe.built == 0)
        #expect(fixture.authenticator.callCount == 0, "nothing prompts before the user (or the screen) asks")

        fixture.authenticator.script(.success)
        #expect(await lock.unlock())
        for _ in 0..<50 where probe.built == 0 {
            await Task.yield()
            host.layoutSubtreeIfNeeded()
        }
        #expect(probe.built > 0, "the content is built once the Mac has confirmed its owner")
    }

    @Test func theGateKeepsTheContentOutAgainWhenTheLockEngagesAgain() async throws {
        let fixture = try AppLockFixture(enabled: true)
        defer { fixture.destroy() }
        let lock = fixture.makeLock(active: false)
        _ = await lock.unlock()
        let probe = GateProbe(secret: "SECRET-zqx")
        let host = NSHostingView(rootView: AppLockGate(lock: lock) { probe.content() })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let builtWhileOpen = probe.built
        #expect(builtWhileOpen > 0)

        lock.lock()
        for _ in 0..<5 { await Task.yield(); host.layoutSubtreeIfNeeded() }
        let afterLock = probe.built
        for _ in 0..<5 { await Task.yield(); host.layoutSubtreeIfNeeded() }
        #expect(probe.built == afterLock, "no new content is built while locked")
        #expect(lock.isLocked)
    }

    // MARK: unlocking

    @Test func unlockUsesTheAuthenticatorAndASuccessOpensTheApp() async throws {
        let fixture = try AppLockFixture(enabled: true)
        defer { fixture.destroy() }
        let lock = fixture.makeLock()
        fixture.authenticator.script(.success)
        #expect(await lock.unlock())
        #expect(!lock.isLocked && lock.notice == nil && !lock.isAuthenticating)
        #expect(fixture.authenticator.callCount == 1)
        #expect(fixture.authenticator.askedReasons.first?.isEmpty == false)
    }

    @Test func cancelledAndFailedAttemptsStayLockedWithTheRightNotice() async throws {
        let fixture = try AppLockFixture(enabled: true)
        defer { fixture.destroy() }
        let lock = fixture.makeLock()
        fixture.authenticator.script(.cancelled, .failed, .unavailable, .success)
        #expect(await lock.unlock() == false)
        #expect(lock.isLocked && lock.notice == nil, "cancelling is not an error")
        #expect(await lock.unlock() == false)
        #expect(lock.isLocked && lock.notice != nil)
        let failed = lock.notice
        #expect(await lock.unlock() == false)
        #expect(lock.isLocked && lock.notice != nil && lock.notice != failed, "no identity check is available: a different notice")
        #expect(await lock.unlock())
        #expect(!lock.isLocked && lock.notice == nil)
    }

    @Test func concurrentUnlockRequestsShareOnePrompt() async throws {
        let fixture = try AppLockFixture(enabled: true)
        defer { fixture.destroy() }
        let lock = fixture.makeLock()
        fixture.authenticator.holdPrompts()
        async let first = lock.unlock()
        for _ in 0..<200 where !lock.isAuthenticating { await Task.yield() }
        #expect(lock.isAuthenticating)
        #expect(await lock.unlock() == false, "a second request while the prompt is up does nothing")
        fixture.authenticator.releasePrompts()
        #expect(await first)
        #expect(fixture.authenticator.callCount == 1)
    }

    @Test func theLockScreenPromptsOnceUntilTheAppIsLockedAgain() async throws {
        let fixture = try AppLockFixture(enabled: true)
        defer { fixture.destroy() }
        let lock = fixture.makeLock()
        fixture.authenticator.script(.cancelled)
        await lock.requestAutomaticUnlock()
        await lock.requestAutomaticUnlock()
        #expect(fixture.authenticator.callCount == 1, "a cancelled prompt is not repeated by every window that appears")
        fixture.lifecycle.send(.appBecameActive)
        for _ in 0..<200 where fixture.authenticator.callCount < 2 { await Task.yield() }
        #expect(fixture.authenticator.callCount == 2, "coming back to the app asks again")
    }

    // MARK: relock

    @Test func leavingTheAppLocksAfterTheDelay() async throws {
        let fixture = try AppLockFixture(enabled: true, delay: 60)
        defer { fixture.destroy() }
        let lock = fixture.makeLock()
        _ = await lock.unlock()
        #expect(!lock.isLocked)

        fixture.lifecycle.send(.appResigned)
        await fixture.clock.waitForSleeper()
        fixture.clock.advance(by: .seconds(59))
        await Task.yield()
        #expect(!lock.isLocked)
        fixture.clock.advance(by: .seconds(1))
        for _ in 0..<200 where !lock.isLocked { await Task.yield() }
        #expect(lock.isLocked)
    }

    @Test func comingBackBeforeTheDelayKeepsTheAppOpen() async throws {
        let fixture = try AppLockFixture(enabled: true, delay: 60)
        defer { fixture.destroy() }
        let lock = fixture.makeLock()
        _ = await lock.unlock()
        fixture.lifecycle.send(.appResigned)
        await fixture.clock.waitForSleeper()
        fixture.lifecycle.send(.appBecameActive)
        fixture.clock.advance(by: .seconds(3600))
        await Task.yield()
        #expect(!lock.isLocked)
    }

    @Test func aDelayOfZeroLocksAsSoonAsTheAppLeavesTheFront() async throws {
        let fixture = try AppLockFixture(enabled: true, delay: 0)
        defer { fixture.destroy() }
        let lock = fixture.makeLock()
        _ = await lock.unlock()
        fixture.lifecycle.send(.appResigned)
        #expect(lock.isLocked)
    }

    @Test func sleepAndScreenLockLockAtOnceWhateverTheDelay() async throws {
        let fixture = try AppLockFixture(enabled: true, delay: 3600)
        defer { fixture.destroy() }
        let lock = fixture.makeLock()
        _ = await lock.unlock()
        fixture.lifecycle.send(.deviceLocked)
        #expect(lock.isLocked)
    }

    @Test func noInputWhileInFrontLocksAfterTheDelay() async throws {
        let fixture = try AppLockFixture(enabled: true, delay: 60)
        defer { fixture.destroy() }
        let lock = fixture.makeLock()
        _ = await lock.unlock()
        fixture.idle.seconds = 10
        fixture.lifecycle.send(.appBecameActive)
        await fixture.clock.waitForSleeper()

        // The user typed again meanwhile: the watch looks at the real idle time and waits on.
        fixture.idle.seconds = 5
        fixture.clock.advance(by: .seconds(50))
        await Task.yield()
        #expect(!lock.isLocked)

        fixture.idle.seconds = 60
        await fixture.clock.waitForSleeper()
        fixture.clock.advance(by: .seconds(55))
        for _ in 0..<200 where !lock.isLocked { await Task.yield() }
        #expect(lock.isLocked)
    }

    @Test func aDisabledLockNeverLocks() async throws {
        let fixture = try AppLockFixture(enabled: false)
        defer { fixture.destroy() }
        let lock = fixture.makeLock()
        lock.lock()
        fixture.lifecycle.send(.deviceLocked)
        fixture.lifecycle.send(.appResigned)
        #expect(!lock.isLocked)
    }

    @Test func aPromptOfOurOwnIsNotInactivity() async throws {
        let fixture = try AppLockFixture(enabled: false, delay: 0)
        defer { fixture.destroy() }
        let lock = fixture.makeLock()
        fixture.authenticator.holdPrompts()
        async let outcome = lock.setEnabled(true)
        for _ in 0..<200 where !lock.isAuthenticating { await Task.yield() }
        // The system prompt takes the front: the app resigns while it is up. Delay 0 must not lock a lock being set up.
        fixture.lifecycle.send(.appResigned)
        fixture.authenticator.releasePrompts()
        #expect(await outcome == .enabled)
        #expect(!lock.isLocked)
    }

    // MARK: turning it on and off

    @Test func turningItOnAsksTheMacToConfirmAndStoresTheChoice() async throws {
        let fixture = try AppLockFixture(enabled: false)
        defer { fixture.destroy() }
        let lock = fixture.makeLock()
        fixture.authenticator.script(.success)
        #expect(await lock.setEnabled(true) == .enabled)
        #expect(lock.isEnabled && !lock.isLocked, "turning it on does not lock the window you are in")
        #expect(fixture.settings.appLockEnabled)
        #expect(fixture.authenticator.callCount == 1)
    }

    @Test func turningItOnIsRefusedWhenTheMacCannotConfirmWhoYouAre() async throws {
        let fixture = try AppLockFixture(enabled: false)
        defer { fixture.destroy() }
        let lock = fixture.makeLock()
        fixture.authenticator.available = false
        #expect(await lock.setEnabled(true) == .unavailable)
        #expect(!lock.isEnabled && !fixture.settings.appLockEnabled, "never lock someone out of their own notes")
        #expect(fixture.authenticator.callCount == 0)

        fixture.authenticator.available = true
        fixture.authenticator.script(.cancelled)
        #expect(await lock.setEnabled(true) == .cancelled)
        #expect(!lock.isEnabled && !fixture.settings.appLockEnabled)
    }

    @Test func turningItOffAlsoAsksAndACancelKeepsItOn() async throws {
        let fixture = try AppLockFixture(enabled: true)
        defer { fixture.destroy() }
        let lock = fixture.makeLock()
        fixture.authenticator.script(.success)
        _ = await lock.unlock()

        fixture.authenticator.script(.cancelled)
        #expect(await lock.setEnabled(false) == .cancelled)
        #expect(lock.isEnabled && fixture.settings.appLockEnabled)

        fixture.authenticator.script(.success)
        #expect(await lock.setEnabled(false) == .disabled)
        #expect(!lock.isEnabled && !fixture.settings.appLockEnabled && !lock.isLocked)
    }

    @Test func theDelayIsStoredAndAppliesToTheNextCountdown() async throws {
        let fixture = try AppLockFixture(enabled: true, delay: 300)
        defer { fixture.destroy() }
        let lock = fixture.makeLock()
        _ = await lock.unlock()
        #expect(lock.delay == 300)
        lock.setDelay(60)
        #expect(lock.delay == 60 && fixture.settings.appLockDelay == 60)
        lock.setDelay(7)
        #expect(lock.delay == 60, "only the offered choices")
        fixture.lifecycle.send(.appResigned)
        await fixture.clock.waitForSleeper()
        fixture.clock.advance(by: .seconds(60))
        for _ in 0..<200 where !lock.isLocked { await Task.yield() }
        #expect(lock.isLocked)
    }

    // MARK: what locking does

    @Test func lockingRunsTheHandlersOnceAndUnlockingDoesNotRunThemAgain() async throws {
        let fixture = try AppLockFixture(enabled: true)
        defer { fixture.destroy() }
        let lock = fixture.makeLock()
        var count = 0
        lock.addDidLockHandler { count += 1 }
        _ = await lock.unlock()
        lock.lock()
        lock.lock()
        #expect(count == 1)
        _ = await lock.unlock()
        #expect(count == 1)
    }

    @Test func lockingRelocksTheNoteVaultAndTheEnvironmentWiresItUp() async throws {
        let root = URL(fileURLWithPath: "/tmp/theo-applock-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authenticator = FakeAppAuthenticator()
        let lifecycle = ManualLifecycleSource()
        let environment = try AppEnvironment(
            paths: AppPaths(root: root), vaultCache: FakeVaultKeyCache(), vaultLifecycle: nil,
            appAuthenticator: authenticator, appLockLifecycle: lifecycle, appIdleSeconds: { 0 })
        try await environment.vault.createPassword("correct horse")
        #expect(environment.vault.isUnlocked)
        #expect(await environment.appLock.setEnabled(true) == .enabled)
        #expect(environment.vault.isUnlocked, "turning App Lock on leaves the notes as they were")

        environment.appLock.lock()
        #expect(environment.appLock.isLocked)
        #expect(!environment.vault.isUnlocked, "App Lock takes the note key away too")

        authenticator.script(.success)
        #expect(await environment.appLock.unlock())
        #expect(!environment.vault.isUnlocked, "the Mac password is not the Note Password")
    }

    @Test func aFreshEnvironmentIsNotLocked() throws {
        let root = URL(fileURLWithPath: "/tmp/theo-applock-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = try AppEnvironment(paths: AppPaths(root: root), vaultCache: FakeVaultKeyCache(), vaultLifecycle: nil)
        #expect(!environment.appLock.isLocked && !environment.appLock.isEnabled)
    }
}

/// Counts how often the gated content was built.
@MainActor
final class GateProbe {
    let secret: String
    private(set) var built = 0
    init(secret: String) { self.secret = secret }

    @ViewBuilder func content() -> some View {
        let _ = { built += 1 }()
        Text(secret).accessibilityLabel(secret)
    }
}

/// Every accessibility label, title and value in a window's tree, as an assistive technology would
/// walk it (the same walk `AccessibilityAudit` uses).
@MainActor
enum AccessibilityWalker {
    static func labels(in window: NSWindow) -> [String] {
        var found: [String] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ element: Any, depth: Int) {
            guard depth < 60, found.count < 20_000, let node = element as? NSObject,
                  seen.insert(ObjectIdentifier(node)).inserted,
                  node.responds(to: #selector(NSAccessibilityProtocol.accessibilityChildren)) else { return }
            for key in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                if let text = node.value(forKey: key) as? String, !text.isEmpty { found.append(text) }
            }
            for child in (node.value(forKey: "accessibilityChildren") as? [Any]) ?? [] { visit(child, depth: depth + 1) }
        }
        for child in window.accessibilityChildren() ?? [] { visit(child, depth: 0) }
        return found
    }
}
