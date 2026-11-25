// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Testing
@testable import TheoNotesCore

struct SyncRetryScheduleTests {
    @Test func retriesBackOffRespectServerDelayAndResetAfterConnectivityReturns() {
        var schedule = SyncRetrySchedule()
        #expect(schedule.failed(jitter: 1) == 2)
        #expect(schedule.failed(jitter: 1) == 4)
        #expect(schedule.failed(retryAfter: 90, jitter: 1) == 90)
        for _ in 0..<30 { _ = schedule.failed(jitter: 1) }
        #expect(schedule.failed(jitter: 1) == 300)
        #expect(schedule.failed(retryAfter: .infinity, jitter: .nan) == 300)
        schedule.reset()
        #expect(schedule.failures == 0)
        #expect(schedule.failed(jitter: 1) == 2)
    }
}
