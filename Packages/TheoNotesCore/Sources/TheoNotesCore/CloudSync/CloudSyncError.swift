// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// Errors a gateway throws from its async operations (per-record save problems are `CloudSaveOutcome` values instead).
public enum CloudSyncError: Error, Equatable, Sendable {
    case offline, unauthenticated, quotaExceeded, limitExceeded, zoneNotFound
    /// The gateway is fenced after an account change; `prepare()` lifts it once the caller's policy allows.
    case fenced
    case failed(code: String)
}
