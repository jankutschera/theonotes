// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

@Suite struct FocusClockTests {
    static var berlin: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        Self.berlin.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func parts(_ date: Date) -> [Int] {
        let c = Self.berlin.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return [c.year!, c.month!, c.day!, c.hour!, c.minute!]
    }

    @Test func nextMidnightOnSpringForwardAndFallBackDays() {
        // Spring forward: 2026-03-29 has 23 hours. Fall back: 2026-10-25 has 25 hours.
        let days: [(m: Int, d: Int, hours: Double)] = [(3, 29, 23), (10, 25, 25)]
        for day in days {
            let midnight = date(2026, day.m, day.d, 0)
            for (h, min) in [(23, 59), (0, 30)] {
                let now = date(2026, day.m, day.d, h, min)
                let next = FocusClock.nextLocalMidnight(after: now, calendar: Self.berlin)
                #expect(parts(next) == [2026, day.m, day.d + 1, 0, 0], "\(day.m)-\(day.d) \(h):\(min)")
                #expect(next > now)
            }
            let next = FocusClock.nextLocalMidnight(after: date(2026, day.m, day.d, 0, 30), calendar: Self.berlin)
            #expect(next.timeIntervalSince(midnight) == day.hours * 3600)
        }
        // Exactly midnight belongs to the new day, so the next midnight is a day later.
        let atMidnight = date(2026, 10, 26, 0)
        #expect(parts(FocusClock.nextLocalMidnight(after: atMidnight, calendar: Self.berlin)) == [2026, 10, 27, 0, 0])
    }

    @Test func nextNineIsTodayBeforeNine() {
        for (h, min) in [(0, 0), (8, 59)] {
            let next = FocusClock.nextNineAM(after: date(2026, 10, 27, h, min), calendar: Self.berlin)
            #expect(parts(next) == [2026, 10, 27, 9, 0], "\(h):\(min)")
        }
    }

    @Test func nextNineIsTomorrowFromNine() {
        for (h, min) in [(9, 0), (9, 1), (23, 59)] {
            let next = FocusClock.nextNineAM(after: date(2026, 10, 27, h, min), calendar: Self.berlin)
            #expect(parts(next) == [2026, 10, 28, 9, 0], "\(h):\(min)")
        }
        // Across a DST change the wall clock still reads 09:00.
        let fall = FocusClock.nextNineAM(after: date(2026, 10, 24, 10), calendar: Self.berlin)
        #expect(parts(fall) == [2026, 10, 25, 9, 0])
        let spring = FocusClock.nextNineAM(after: date(2026, 3, 28, 10), calendar: Self.berlin)
        #expect(parts(spring) == [2026, 3, 29, 9, 0])
    }

    @Test func displayLineStripsMarkers() {
        #expect(FocusClock.displayLine("  - [ ] **Call** Anna") == "**Call** Anna")
        #expect(FocusClock.displayLine("## Plan") == "Plan")
        #expect(FocusClock.displayLine("* [x] done") == "done")
        #expect(FocusClock.displayLine("+ plain") == "plain")
        #expect(FocusClock.displayLine("12. step") == "step")
        #expect(FocusClock.displayLine("3) step") == "step")
        #expect(FocusClock.displayLine("\t- item") == "item")
        #expect(FocusClock.displayLine("no marker") == "no marker")
        #expect(FocusClock.displayLine("#tag stays") == "#tag stays")
        #expect(FocusClock.displayLine("-") == "")
        #expect(FocusClock.displayLine("") == "")
        let long = String(repeating: "a", count: 300)
        #expect(FocusClock.displayLine(long).count == 200)
        #expect(FocusClock.displayLine("- [ ] " + long).count == 200)
    }

    @Test func displayLineTruncatesOnAGraphemeBoundary() {
        let family = "👨‍👩‍👧"
        let text = String(repeating: "a", count: 199) + family + "tail"
        let shown = FocusClock.displayLine(text)
        #expect(shown.count == 200)
        #expect(shown.hasSuffix(family))
    }
}
