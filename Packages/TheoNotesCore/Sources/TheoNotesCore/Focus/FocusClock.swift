// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// Local-time rules of the focus layer, with the calendar passed in so tests can pin a time zone.
public enum FocusClock {
    /// Longest line shown on a card or in a notification body.
    static let displayLimit = 200

    /// The first local midnight strictly after `date` (when a hide ends, FOC-R8). On a daylight
    /// saving day that is 23 or 25 hours long it is still the start of the next calendar day.
    public static func nextLocalMidnight(after date: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: date)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: start) else {
            return start.addingTimeInterval(24 * 3600)
        }
        return calendar.startOfDay(for: tomorrow)
    }

    /// The default reminder time (FOC-R10): 09:00 today when `date` is before 09:00, otherwise
    /// 09:00 tomorrow.
    public static func nextNineAM(after date: Date, calendar: Calendar) -> Date {
        func nine(on day: Date) -> Date? {
            calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day, matchingPolicy: .nextTime)
        }
        if let today = nine(on: date), today > date { return today }
        let midnight = nextLocalMidnight(after: date, calendar: calendar)
        return nine(on: midnight) ?? midnight.addingTimeInterval(9 * 3600)
    }

    /// A line of a note as a card or notification shows it: without leading blanks, a list marker
    /// (`-` `*` `+` `1.` `1)`), a to-do box or heading `#`s, without trailing blanks, and cut to 200
    /// characters on a grapheme boundary. Other Markdown (emphasis, links) is left as typed.
    public static func displayLine(_ raw: String) -> String {
        let s = Array(raw.unicodeScalars)
        var end = LineShape.trimmedEnd(s)
        var p = 0
        while p < end && Chars.isBlank(s[p]) { p += 1 }
        if let afterBullet = LineShape.bulletEnd(s, from: p, to: end) {
            p = afterBullet
            if let box = LineShape.todoBox(s, at: p, to: end) { p = box.end }
        } else if let afterNumber = LineShape.orderedMarkerEnd(s, from: p, to: end) {
            p = afterNumber
        }
        if let heading = LineShape.atxHeading(s, from: p, to: end) {
            p = heading.content.lowerBound
            end = heading.content.upperBound
        }
        guard p < end else { return "" }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: s[p..<end])
        return String(String(view).prefix(displayLimit))
    }
}
