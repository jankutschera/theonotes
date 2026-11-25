// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

@Suite struct PingTimeTests {
    private func parts(_ date: Date) -> [Int] {
        let c = FocusClockTests.berlin.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return [c.year!, c.month!, c.day!, c.hour!, c.minute!]
    }

    private func berlin(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        FocusClockTests.berlin.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    @Test func defaultIsTodayBeforeNineAndTomorrowFromNine() {
        let calendar = FocusClockTests.berlin
        // 2026-10-25 is the 25-hour fall-back day in Berlin, 2026-03-29 the 23-hour spring-forward day.
        for (m, d) in [(10, 24), (10, 25), (3, 29)] {
            let early = PingTime.defaultFireDate(now: berlin(2026, m, d, 8, 59), calendar: calendar)
            #expect(parts(early) == [2026, m, d, 9, 0], "\(m)-\(d) 08:59")
            let atNine = PingTime.defaultFireDate(now: berlin(2026, m, d, 9, 0), calendar: calendar)
            #expect(parts(atNine) == [2026, m, d + 1, 9, 0], "\(m)-\(d) 09:00")
            let late = PingTime.defaultFireDate(now: berlin(2026, m, d, 23, 59), calendar: calendar)
            #expect(parts(late) == [2026, m, d + 1, 9, 0], "\(m)-\(d) 23:59")
        }
    }

    @Test func inOneHourIsExactlyThirtySixHundredSeconds() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(PingTime.inOneHour(now: now).timeIntervalSince(now) == 3600)
    }

    /// FOC-R365: the Remind Me sheet's "In 5 Minutes".
    @Test func inFiveMinutesIsExactlyThreeHundredSeconds() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(PingTime.inFiveMinutes(now: now).timeIntervalSince(now) == 300)
    }
}
