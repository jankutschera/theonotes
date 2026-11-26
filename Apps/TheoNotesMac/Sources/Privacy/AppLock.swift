// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import CoreGraphics
import Foundation
import LocalAuthentication
import Observation

/// What an identity check answered.
enum AppAuthResult: Equatable, Sendable {
    case success
    /// The person dismissed the prompt.
    case cancelled
    /// The check ran and did not pass.
    case failed
    /// The Mac cannot check anyone right now (no login password set, no way to ask).
    case unavailable
}

/// Asks the Mac whether the person at the keyboard is its owner. Touch ID first, the Mac login
/// password as the fallback (`LAPolicy.deviceOwnerAuthentication`). Tests use a fake.
protocol AppAuthenticator: Sendable {
    /// Whether `authenticate` can run at all. Never prompts.
    func canAuthenticate() -> Bool
    func authenticate(reason: String) async -> AppAuthResult
    /// Cancels the prompt that is up, if any: the sheet goes away and its `authenticate` returns
    /// `.cancelled`. Called when the lock engages again while a prompt is waiting.
    func invalidatePending()
}

/// `LAContext` is retained while its prompt is up so `invalidatePending()` can end it.
final class LocalAuthenticator: AppAuthenticator, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: LAContext?

    func canAuthenticate() -> Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func invalidatePending() {
        let context = lock.withLock { () -> LAContext? in
            defer { pending = nil }
            return pending
        }
        context?.invalidate()
    }

    func authenticate(reason: String) async -> AppAuthResult {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return .unavailable }
        lock.withLock { pending = context }
        defer { lock.withLock { if pending === context { pending = nil } } }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) ? .success : .failed
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .appCancel, .systemCancel: return .cancelled
            case .passcodeNotSet, .notInteractive: return .unavailable
            default: return .failed
            }
        } catch {
            return .failed
        }
    }
}

/// What the automation surfaces say while App Lock is engaged. No library content, no note
/// id and no count is in it.
enum AppLockedRefusal {
    static let message = "Theo Notes is locked. Unlock it, then try again."
    /// `x-error` code 6, "failed" (the x-callback code space has no code of its own for this).
    static let xCallbackCode = 6
}

/// The app-wide lock: while it is engaged no window shows library content and no
/// automation surface answers with any. It guards the screen, not the data: notes stay in the
/// library as they are, and the Note Password and `NoteVault` are separate. The Mac password
/// that opens it is never stored or seen here; `AppAuthenticator` only reports the outcome.
///
/// It engages at launch when it is on, when the app has been out of the front for the chosen
/// delay, when no input reached the Mac for that long while the app is in front, and at once on
/// sleep, screen lock and screensaver.
@MainActor
@Observable
final class AppLock {
    enum EnableOutcome: Equatable {
        case enabled, disabled
        /// The person dismissed the prompt; nothing changed.
        case cancelled
        /// The Mac cannot check its owner, so the lock is not turned on (it could not be opened).
        case unavailable
        /// The prompt ran and did not pass; nothing changed.
        case failed
    }

    struct HandlerToken: Hashable, Sendable { fileprivate let id: Int }

    private(set) var isEnabled: Bool
    private(set) var isLocked: Bool
    /// A prompt is up (to unlock, or to turn the lock on or off).
    private(set) var isAuthenticating = false
    /// Why the last attempt did not open the app; nil after a cancel, which is no error.
    private(set) var notice: String?
    private(set) var delay: Int
    /// Bumped every time the lock engages, or the Mac locks while it is on. Work that started before
    /// is stale: a prompt that answers late, a copy, an export.
    private(set) var generation = 0

    @ObservationIgnored private let settings: TheoNotesCore.Settings
    @ObservationIgnored private let authenticator: any AppAuthenticator
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let idleSeconds: @Sendable () -> TimeInterval
    @ObservationIgnored private let isAppActive: @MainActor () -> Bool
    @ObservationIgnored private var lifecycleObservation: (any VaultLifecycleObservation)?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var didLock: [(token: HandlerToken, handler: @MainActor () -> Void)] = []
    @ObservationIgnored private var willLock: [(token: HandlerToken, handler: @MainActor () -> Void)] = []
    @ObservationIgnored private var didUnlock: [(token: HandlerToken, handler: @MainActor () -> Void)] = []
    @ObservationIgnored private var enabledChange: [(token: HandlerToken, handler: @MainActor (Bool) -> Void)] = []
    @ObservationIgnored private var nextHandlerId = 0
    /// The lock screen asks for the system prompt once per lock (and once per return to the app).
    @ObservationIgnored private var autoPrompted = false

    /// `idleSeconds` is the time since the last keyboard or mouse input anywhere on the Mac;
    /// `isAppActive` says whether the app is in front (the lock screen prompts only then).
    init(
        settings: TheoNotesCore.Settings, authenticator: any AppAuthenticator,
        lifecycle: (any VaultLifecycleSource)? = nil, clock: any Clock<Duration> = ContinuousClock(),
        idleSeconds: @escaping @Sendable () -> TimeInterval = AppLock.systemIdleSeconds,
        isAppActive: @escaping @MainActor () -> Bool = { NSApp?.isActive ?? false }
    ) {
        self.settings = settings
        self.authenticator = authenticator
        self.clock = clock
        self.idleSeconds = idleSeconds
        self.isAppActive = isAppActive
        let enabled = settings.appLockEnabled
        isEnabled = enabled
        isLocked = enabled
        delay = settings.appLockDelay
        lifecycleObservation = lifecycle?.observe { [weak self] event in self?.handle(event) }
    }

    /// Seconds since the last keyboard or mouse input on the Mac, from the session's event source.
    nonisolated static func systemIdleSeconds() -> TimeInterval {
        let anyInput = CGEventType(rawValue: ~0) ?? .null
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    // MARK: Engaging and opening

    /// Engages the lock, if it is on. The handlers run once per engagement, before the screen
    /// changes hands: the environment saves open edits and takes the note key away.
    func lock() {
        guard isEnabled else { return }
        invalidateInFlight()
        guard !isLocked else { return }
        cancelTimer()
        autoPrompted = false
        notice = nil
        // Window titles, Dock images, panels and sheets are scrubbed before the state is published.
        for entry in willLock { entry.handler() }
        isLocked = true
        for entry in didLock { entry.handler() }
    }

    /// Ends the prompt that is up and makes every earlier job stale. A success that arrives after
    /// this call opens nothing.
    private func invalidateInFlight() {
        guard isEnabled else { return }
        generation &+= 1
        authenticator.invalidatePending()
    }

    /// Whether work that started at `generation` may still produce output: the lock has not engaged
    /// since and is not engaged now.
    func isCurrent(_ generation: Int) -> Bool { !isLocked && self.generation == generation }

    /// Runs right before the lock engages (`isLocked` is still false), in registration order.
    @discardableResult
    func addWillLockHandler(_ handler: @escaping @MainActor () -> Void) -> HandlerToken {
        nextHandlerId += 1
        let token = HandlerToken(id: nextHandlerId)
        willLock.append((token, handler))
        return token
    }

    /// Runs after the app was unlocked.
    @discardableResult
    func addDidUnlockHandler(_ handler: @escaping @MainActor () -> Void) -> HandlerToken {
        nextHandlerId += 1
        let token = HandlerToken(id: nextHandlerId)
        didUnlock.append((token, handler))
        return token
    }

    /// Runs after every engagement of the lock, in registration order.
    @discardableResult
    func addDidLockHandler(_ handler: @escaping @MainActor () -> Void) -> HandlerToken {
        nextHandlerId += 1
        let token = HandlerToken(id: nextHandlerId)
        didLock.append((token, handler))
        return token
    }

    func removeDidLockHandler(_ token: HandlerToken) { didLock.removeAll { $0.token == token } }

    /// Runs when Settings turned App Lock on or off, right after the setting is written and
    /// the state is updated, in registration order. A prompt that was cancelled or failed runs
    /// nothing. Turning it on does not engage it: `isLocked` is unchanged by this call.
    @discardableResult
    func addEnabledChangeHandler(_ handler: @escaping @MainActor (Bool) -> Void) -> HandlerToken {
        nextHandlerId += 1
        let token = HandlerToken(id: nextHandlerId)
        enabledChange.append((token, handler))
        return token
    }

    func removeEnabledChangeHandler(_ token: HandlerToken) { enabledChange.removeAll { $0.token == token } }

    /// Asks the Mac to confirm the owner and opens the app on a pass. False for anything else; a
    /// request while a prompt is up does nothing.
    @discardableResult
    func unlock() async -> Bool {
        guard isLocked, !isAuthenticating else { return false }
        let result = await authenticate(reason: "Unlock Theo Notes")
        switch result {
        case .success:
            notice = nil
            isLocked = false
            startIdleWatch()
            for entry in didUnlock { entry.handler() }
            return true
        case .cancelled:
            notice = nil
        case .failed:
            notice = "That did not work. Try again with Touch ID or your Mac password."
        case .unavailable:
            notice = "This Mac cannot confirm who you are right now. Set a login password in System Settings, then try again."
        }
        return false
    }

    /// What the lock screen calls when it appears: one prompt per lock, and only while the app is in
    /// front (a window of a background app must not pop a system prompt).
    func requestAutomaticUnlock() async {
        guard isLocked, !autoPrompted, !isAuthenticating, isAppActive() else { return }
        autoPrompted = true
        await unlock()
    }

    // MARK: Settings

    /// Turns the lock on or off. Both ask the Mac to confirm the owner first: on, so a lock that
    /// cannot be opened is never switched on; off, so a passer-by cannot remove it. When the Mac
    /// cannot ask at all, turning it off is allowed (turning it on is not).
    @discardableResult
    func setEnabled(_ enable: Bool) async -> EnableOutcome {
        guard !isAuthenticating else { return isEnabled ? .enabled : .disabled }
        if enable == isEnabled { return enable ? .enabled : .disabled }
        if enable {
            guard authenticator.canAuthenticate() else { return .unavailable }
            switch await authenticate(reason: "Turn on App Lock") {
            case .success: break
            case .cancelled: return .cancelled
            case .failed: return .failed
            case .unavailable: return .unavailable
            }
        } else if authenticator.canAuthenticate() {
            switch await authenticate(reason: "Turn off App Lock") {
            case .success, .unavailable: break
            case .cancelled: return .cancelled
            case .failed: return .failed
            }
        }
        settings.appLockEnabled = enable
        isEnabled = enable
        if enable {
            startIdleWatch()
        } else {
            cancelTimer()
            isLocked = false
        }
        for entry in enabledChange { entry.handler(enable) }
        return enable ? .enabled : .disabled
    }

    /// One of `Settings.appLockDelayOptions`; anything else is ignored. A running countdown keeps its
    /// old length; the new one applies from the next time the app leaves the front.
    func setDelay(_ seconds: Int) {
        guard TheoNotesCore.Settings.appLockDelayOptions.contains(seconds) else { return }
        settings.appLockDelay = seconds
        delay = seconds
        if isEnabled, !isLocked, isAppActive() { startIdleWatch() }
    }

    // MARK: Lifecycle

    private func handle(_ event: VaultLifecycleEvent) {
        switch event {
        case .deviceLocked:
            // `lock()` also ends a prompt that is still up when the app is already locked.
            lock()
        case .appResigned:
            guard isEnabled, !isLocked, !isAuthenticating else { return }
            guard delay > 0 else { return lock() }
            startTimer { [weak self] in
                guard let self else { return }
                do { try await self.clock.sleep(for: .seconds(self.delay)) } catch { return }
                guard !Task.isCancelled else { return }
                self.lock()
            }
        case .appBecameActive:
            cancelTimer()
            if isLocked {
                autoPrompted = false
                Task { [weak self] in await self?.requestAutomaticUnlock() }
            } else {
                startIdleWatch()
            }
        }
    }

    /// While the app is in front: locks once the whole Mac has seen no input for `delay`. It looks at
    /// the real idle time when it wakes, so typing in between only moves the next check.
    private func startIdleWatch() {
        guard isEnabled, !isLocked, delay > 0 else { return cancelTimer() }
        startTimer { [weak self] in
            while let self, !Task.isCancelled {
                let wait = Double(self.delay) - self.idleSeconds()
                if wait <= 0 { return self.lock() }
                do { try await self.clock.sleep(for: .seconds(wait)) } catch { return }
            }
        }
    }

    private func startTimer(_ body: @escaping @MainActor () async -> Void) {
        cancelTimer()
        timer = Task { await body() }
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }

    /// A result that arrives after the lock engaged (or the Mac locked) again is dropped: it counts as
    /// cancelled, whatever the prompt said.
    private func authenticate(reason: String) async -> AppAuthResult {
        isAuthenticating = true
        defer { isAuthenticating = false }
        let started = generation
        let result = await authenticator.authenticate(reason: reason)
        return started == generation ? result : .cancelled
    }
}
