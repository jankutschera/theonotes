// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Testing
@testable import TheoNotes

/// Note ▸ Remind Me…: what the sheet offers and where it starts.
@MainActor
@Suite struct ReminderSheetTests {
    private func note(text: String, locked: Bool = false) -> Note {
        Note(id: "n1", text: text, title: "Title", titleKey: "title", createdAt: .now, modifiedAt: .now, isLocked: locked)
    }

    private let berlin: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    @Test func lineTargetUsesTheCaretLineAnchor() throws {
        let text = "Title\nbuy milk\nsecond"
        let caret = try #require(LineAnchor.utf16Offset(ofLine: 2, in: text)) + 3
        let target = try #require(ReminderTarget.resolve(note: note(text: text), caret: caret))
        #expect(target == .line(noteId: "n1", anchor: try #require(LineAnchor.at(line: 2, in: text))))

        let model = ReminderSheetModel(target: target, linePreview: "buy milk")
        #expect(model.offersLine && !model.wholeNote)
        #expect(model.choice.target == target)
        model.wholeNote = true
        #expect(model.choice.target == .note(noteId: "n1"))
    }

    @Test func aBlankLineOrNoCaretOffersTheWholeNote() throws {
        let text = "Title\n\nsecond"
        #expect(ReminderTarget.resolve(note: note(text: text), caret: 6) == .note(noteId: "n1"))
        #expect(ReminderTarget.resolve(note: note(text: text), caret: nil) == .note(noteId: "n1"))
        #expect(ReminderTarget.resolve(note: nil, caret: 2) == nil)
    }

    @Test func lockedNoteOffersOnlyTheWholeNote() throws {
        let target = try #require(ReminderTarget.resolve(note: note(text: "Title\nbuy milk", locked: true), caret: 8))
        #expect(target == .note(noteId: "n1"))
        let model = ReminderSheetModel(target: target)
        #expect(!model.offersLine)
        #expect(model.choice.target == .note(noteId: "n1"))
    }

    @Test func defaultTimeIsNextNine() throws {
        func date(_ hour: Int, day: Int = 27) -> Date {
            berlin.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: 30))!
        }
        let target = ReminderTarget.note(noteId: "n1")
        let evening = ReminderSheetModel(target: target, now: { date(18) }, calendar: berlin)
        #expect(evening.fireAt == berlin.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 9)))
        let early = ReminderSheetModel(target: target, now: { date(7) }, calendar: berlin)
        #expect(early.fireAt == berlin.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 9)))
        #expect(early.canSet)
        early.fireAt = date(6)
        #expect(!early.canSet, "a time that has passed cannot be set")
        early.inOneHour()
        #expect(early.fireAt == date(8))
        early.inFiveMinutes()
        #expect(early.fireAt == date(7).addingTimeInterval(300))
    }
}
