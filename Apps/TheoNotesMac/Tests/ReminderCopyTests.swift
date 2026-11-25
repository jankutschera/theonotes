// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Testing
@testable import TheoNotes

/// The copy the brief fixes: "Remind Me", "In 5 Minutes", "In 1 Hour", the 09:00 button (time in the locale's format).
@MainActor
@Suite struct ReminderCopyTests {
    private func gregorian(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    @Test func snoozeActionsReadInOneHourAndAtNineInTheLocalesFormat() {
        let us = MacNotificationCategory.reminder(locale: Locale(identifier: "en_US"), calendar: gregorian("America/New_York"))
        // macOS writes a narrow no-break space before AM; compare with a plain one.
        #expect(us.actions.map { $0.title.replacingOccurrences(of: "\u{202F}", with: " ") } == ["In 1 Hour", "At 9:00 AM"])
        let de = MacNotificationCategory.reminder(locale: Locale(identifier: "de_DE"), calendar: gregorian("Europe/Berlin"))
        #expect(de.actions.map(\.title) == ["In 1 Hour", "At 09:00"])
        #expect(us.actions.map(\.identifier) == ["reminder.snooze.hour", "reminder.snooze.nine"])
    }

    @Test func sheetButtonsAreNamedLikeTheBrief() {
        #expect(ReminderSheetModel.title == "Remind Me")
        #expect(ReminderSheetModel.confirmTitle == "Remind Me")
        #expect(ReminderSheetModel.inFiveMinutesTitle == "In 5 Minutes")
        #expect(ReminderSheetModel.inOneHourTitle == "In 1 Hour")
    }

    /// FOC-R365: the quick button for 09:00 says which day it means, in the locale's time format.
    @Test func theNineButtonNamesTheDay() {
        func berlinTime(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            gregorian("Europe/Berlin").date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
        }
        func title(_ now: Date, _ identifier: String = "de_DE") -> String {
            ReminderSheetModel.nineTitle(now: now, locale: Locale(identifier: identifier), calendar: gregorian("Europe/Berlin"))
                .replacingOccurrences(of: "\u{202F}", with: " ")
        }
        #expect(title(berlinTime(27, 0, 5)) == "Today 09:00")
        #expect(title(berlinTime(27, 8, 59)) == "Today 09:00")
        #expect(title(berlinTime(27, 9)) == "Tomorrow 09:00", "at 09:00 sharp the next 09:00 is tomorrow's")
        #expect(title(berlinTime(27, 18)) == "Tomorrow 09:00")
        #expect(title(berlinTime(27, 23, 59)) == "Tomorrow 09:00")
        #expect(title(berlinTime(27, 7), "en_US") == "Today 9:00 AM")
        #expect(title(berlinTime(27, 18), "en_US") == "Tomorrow 9:00 AM")
    }

    @Test func theModelsNineButtonFollowsItsClock() {
        var clock = gregorian("Europe/Berlin").date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 7))!
        let model = ReminderSheetModel(
            target: .note(noteId: "n1"), now: { clock }, calendar: gregorian("Europe/Berlin"), locale: Locale(identifier: "de_DE"))
        #expect(model.nineTitle == "Today 09:00")
        clock = gregorian("Europe/Berlin").date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 20))!
        #expect(model.nineTitle == "Tomorrow 09:00")
    }

    /// FOC-R369: an open sheet crosses 09:00. The label and the click are computed from the same target
    /// date, so they never name different days, and the view re-reads the clock while it is open.
    @Test func theLabelAndTheClickAgreeAcrossNine() {
        let calendar = gregorian("Europe/Berlin")
        func at(_ hour: Int, _ minute: Int, _ second: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: hour, minute: minute, second: second))!
        }
        var clock = at(8, 59, 59)
        let model = ReminderSheetModel(
            target: .note(noteId: "n1"), now: { clock }, calendar: calendar, locale: Locale(identifier: "de_DE"))
        #expect(model.nineTitle == "Today 09:00")
        model.nextNine()
        #expect(calendar.isDate(model.fireAt, inSameDayAs: clock), "the label said Today: the click sets today")

        clock = at(9, 0, 0)
        #expect(model.nineTitle == "Tomorrow 09:00")
        model.nextNine()
        #expect(!calendar.isDate(model.fireAt, inSameDayAs: clock), "the label says Tomorrow: the click sets tomorrow")
        #expect(model.nineDay == .tomorrow)
    }

    @Test func theSheetRefreshesTheNineButtonOnATimer() throws {
        #expect(ReminderNineButton.refreshSeconds <= 1)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sheet = try String(contentsOf: root.appendingPathComponent("Sources/Focus/ReminderSheet.swift"), encoding: .utf8)
        #expect(sheet.contains("TimelineView(.periodic(from: .now, by: Self.refreshSeconds))"))
        #expect(sheet.contains("ReminderNineButton(model: model)"))
    }

    /// FOC-R366: "In 5 Minutes" lives in the sheet only; the banner keeps its two snooze actions
    /// (a pair shared with the iPhone through `NotificationLedger`), and its "At 9:00" still means the next 9:00.
    @Test func theBannerKeepsItsTwoActions() {
        let category = MacNotificationCategory.reminder(locale: Locale(identifier: "de_DE"), calendar: gregorian("Europe/Berlin"))
        #expect(category.actions.map(\.identifier) == ["reminder.snooze.hour", "reminder.snooze.nine"])
        #expect(category.actions.map(\.title) == ["In 1 Hour", "At 09:00"])
    }

    @Test func menuTitlesAreTheBriefs() {
        #expect(RemindMeMenu.title == "Remind Me…")
        #expect(EditorContextMenu.remindTitle == "Remind Me…")
    }
}
