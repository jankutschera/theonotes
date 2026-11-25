// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing

extension Tag {
    /// Timing gates (ruling R29): the 10k-note gates run only in the serial perf pass of
    /// `scripts/test-all.sh` (`BAERCHEN_PERF=1 swift test --no-parallel --filter '/testPerf'`).
    @Tag static var perf: Self
}

enum PerfGate {
    static let isEnabled = ProcessInfo.processInfo.environment["BAERCHEN_PERF"] == "1"

    static let onlyInPerfPass: ConditionTrait = .enabled(
        if: isEnabled, "timing gate: runs in the serial perf pass (BAERCHEN_PERF=1, scripts/test-all.sh)")
}
