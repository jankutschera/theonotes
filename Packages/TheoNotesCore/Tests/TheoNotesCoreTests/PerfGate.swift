// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing

extension Tag {
    /// Timing gates (ruling R29). They flake when the whole suite runs in parallel, so the normal
    /// `swift test` skips the 10k-note gates and runs the cheap ones with loose sanity bounds;
    /// `scripts/test-all.sh` runs every `.perf` test again, strictly and serially
    /// (`BAERCHEN_PERF=1 swift test --no-parallel --filter '/testPerf'`).
    @Tag static var perf: Self
}

enum PerfGate {
    /// The serial perf pass of `scripts/test-all.sh`.
    static let isEnabled = ProcessInfo.processInfo.environment["BAERCHEN_PERF"] == "1"

    /// For the 10k-note gates: they run only in the perf pass.
    static let onlyInPerfPass: ConditionTrait = .enabled(
        if: isEnabled, "timing gate: runs in the serial perf pass (BAERCHEN_PERF=1, scripts/test-all.sh)")

    /// `strict` in the perf pass, `sanity` (a bound that only catches a gross regression) otherwise.
    static func bound<T: Sendable>(_ strict: T, sanity: T) -> T {
        isEnabled ? strict : sanity
    }
}
