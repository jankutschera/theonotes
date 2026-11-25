// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// Problems the receiver and the attachment code report that are not gateway errors (CK-R5). `unsupportedRecordVersion` is a
/// record written by a newer build; `corruptAttachment` and `quarantined` are items that stay held back.
public enum CloudPolicyError: Error, Equatable, Sendable {
    case unsupportedRecordVersion
    case corruptAttachment
    case quarantined(count: Int)
}

/// What a failure means, before any timing is applied.
public enum CloudErrorClass: Sendable, Equatable {
    case quotaFull
    case offline
    /// The call was refused for lack of a signed-in account; `account` (when known) tells why.
    case unauthenticated
    case signedOut
    case restricted
    /// The synced copy vanished (CK-R15): reported, never retried, never re-created.
    case zoneRemoved(ZoneRemoval)
    case needsAppUpdate
    case itemsUnreadable(count: Int)
    /// The gateway is fenced after an account change; only the account policy lifts it.
    case fenced
    case failed(kind: String)
}

/// How a classified failure is handled.
public struct CloudErrorDecision: Sendable, Equatable {
    public enum Retry: Sendable, Equatable {
        /// Nothing retries by itself; something else (an account event, the person, an app update) changes the situation.
        case none
        case after(TimeInterval)
        /// Quota: when the app comes to the foreground and otherwise every `interval` seconds.
        case onForegroundOrEvery(TimeInterval)
    }

    public var state: CloudSyncState
    public var retry: Retry
    /// Uploads (saves) must not be sent while this holds.
    public var uploadsBlocked: Bool
    /// Fetching must not run while this holds.
    public var receivingBlocked: Bool
}

/// Classifies gateway failures and applies the backoff schedule. Reuses `SyncRetrySchedule` (it grows from about 2 s to the
/// 300 s cap and carries jitter), so an offline device never spins. One value per sync loop; `succeeded()` resets the backoff.
public struct CloudErrorPolicy: Sendable {
    public static let quotaRetryInterval: TimeInterval = 6 * 3600

    private var schedule = SyncRetrySchedule()
    private let now: @Sendable () -> Date
    private let jitter: @Sendable () -> Double

    public init(now: @escaping @Sendable () -> Date = { Date() },
                jitter: @escaping @Sendable () -> Double = { Double.random(in: 0.8...1.2) }) {
        self.now = now; self.jitter = jitter
    }

    public var consecutiveFailures: Int { schedule.failures }
    public mutating func succeeded() { schedule.reset() }

    // MARK: classification (pure)

    /// `account` is what the device reports now, if known: an `unauthenticated` failure under a restricted account is
    /// `.restricted`, under no account `.signedOut`, otherwise a transient `.unauthenticated`.
    public static func classify(_ error: Error, account: CloudAccountState? = nil) -> CloudErrorClass {
        switch error {
        case let error as CloudSyncError:
            switch error {
            case .offline: return .offline
            case .unauthenticated:
                switch account {
                case .restricted?: return .restricted
                case .noAccount?: return .signedOut
                default: return .unauthenticated
                }
            case .quotaExceeded: return .quotaFull
            case .zoneNotFound: return .zoneRemoved(.deleted)
            case .fenced: return .fenced
            case .limitExceeded: return .failed(kind: "limitExceeded")
            case .failed(let code): return .failed(kind: code)
            }
        case let error as CloudPolicyError:
            switch error {
            case .unsupportedRecordVersion: return .needsAppUpdate
            case .corruptAttachment: return .itemsUnreadable(count: 1)
            case .quarantined(let count): return .itemsUnreadable(count: max(1, count))
            }
        case let rejection as CloudRecordRejection:
            guard case .unsupported(let reason) = rejection else { return .itemsUnreadable(count: 1) }
            if case .version = reason { return .needsAppUpdate }
            return .itemsUnreadable(count: 1)
        case let error as URLError:
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return .offline
            default: return .failed(kind: "network")
            }
        default:
            return .failed(kind: String(describing: type(of: error)))
        }
    }

    /// A send outcome that is a failure; nil for `saved`, `serverRecordChanged` and `unknownItem` (the publisher's own cases).
    public static func classify(_ outcome: CloudSaveOutcome, account: CloudAccountState? = nil) -> CloudErrorClass? {
        switch outcome {
        case .saved, .serverRecordChanged, .unknownItem: return nil
        case .quotaExceeded: return classify(CloudSyncError.quotaExceeded, account: account)
        case .limitExceeded: return classify(CloudSyncError.limitExceeded, account: account)
        case .zoneNotFound: return classify(CloudSyncError.zoneNotFound, account: account)
        case .unauthenticated: return classify(CloudSyncError.unauthenticated, account: account)
        case .offline: return classify(CloudSyncError.offline, account: account)
        case .fenced: return classify(CloudSyncError.fenced, account: account)
        case .failed(let code): return .failed(kind: code)
        }
    }

    /// A zone removal the gateway reported as an event (not an error): same handling as a failure that says so.
    public static func classify(_ event: CloudGatewayEvent) -> CloudErrorClass? {
        if case .zoneRemoved(let reason) = event { return .zoneRemoved(reason) }
        return nil
    }

    // MARK: decision (applies the schedule)

    public mutating func decide(_ error: Error, account: CloudAccountState? = nil) -> CloudErrorDecision {
        decide(Self.classify(error, account: account))
    }

    public mutating func decide(_ outcome: CloudSaveOutcome, account: CloudAccountState? = nil) -> CloudErrorDecision? {
        Self.classify(outcome, account: account).map { decide($0) }
    }

    public mutating func decide(_ kind: CloudErrorClass) -> CloudErrorDecision {
        switch kind {
        case .quotaFull:
            // Uploads wait; receiving continues. Not a backoff failure: the situation changes when space frees up.
            return CloudErrorDecision(state: .quotaFull, retry: .onForegroundOrEvery(Self.quotaRetryInterval),
                                      uploadsBlocked: true, receivingBlocked: false)
        case .offline:
            let delay = backoff()
            return CloudErrorDecision(state: .offline(retryAt: now().addingTimeInterval(delay)), retry: .after(delay),
                                      uploadsBlocked: false, receivingBlocked: false)
        case .unauthenticated:
            let delay = backoff()
            return CloudErrorDecision(state: .waitingForICloud, retry: .after(delay), uploadsBlocked: false, receivingBlocked: false)
        case .signedOut:
            return CloudErrorDecision(state: .signedOutOfICloud, retry: .none, uploadsBlocked: true, receivingBlocked: true)
        case .restricted:
            return CloudErrorDecision(state: .restricted, retry: .none, uploadsBlocked: true, receivingBlocked: true)
        case .zoneRemoved(let reason):
            return CloudErrorDecision(state: .zoneRemoved(reason: reason), retry: .none, uploadsBlocked: true, receivingBlocked: true)
        case .needsAppUpdate:
            return CloudErrorDecision(state: .needsAppUpdate, retry: .none, uploadsBlocked: false, receivingBlocked: false)
        case .itemsUnreadable(let count):
            return CloudErrorDecision(state: .itemsUnreadable(count: count), retry: .none, uploadsBlocked: false, receivingBlocked: false)
        case .fenced:
            return CloudErrorDecision(state: .paused, retry: .none, uploadsBlocked: true, receivingBlocked: true)
        case .failed(let kind):
            let delay = backoff()
            return CloudErrorDecision(state: .failed(kind: kind), retry: .after(delay), uploadsBlocked: false, receivingBlocked: false)
        }
    }

    private mutating func backoff() -> TimeInterval { schedule.failed(jitter: jitter()) }
}
