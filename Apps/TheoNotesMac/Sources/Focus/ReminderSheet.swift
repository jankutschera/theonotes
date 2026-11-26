// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Observation
import SwiftUI

/// What a reminder is about: one line of a note, or the whole note.
enum ReminderTarget: Equatable {
    case line(noteId: String, anchor: LineAnchor)
    case note(noteId: String)

    var noteId: String {
        switch self {
        case .line(let noteId, _), .note(let noteId): return noteId
        }
    }

    var anchor: LineAnchor? {
        if case .line(_, let anchor) = self { return anchor }
        return nil
    }

    /// The target for a caret: its line, or the whole note when the note is locked (a locked note takes
    /// no line reminder), the caret is unknown, or the line is empty. Nil when there is no such note.
    static func resolve(note: Note?, caret: Int?) -> ReminderTarget? {
        guard let note else { return nil }
        guard !note.isLocked, let caret, let anchor = LineAnchor.at(utf16Offset: caret, in: note.text),
              let text = LineAnchor.lineText(anchor.line, in: note.text), !FocusClock.displayLine(text).isEmpty
        else { return .note(noteId: note.id) }
        return .line(noteId: note.id, anchor: anchor)
    }
}

/// What the sheet hands back when the person sets the reminder.
struct ReminderChoice: Equatable {
    let target: ReminderTarget
    let fireAt: Date
}

/// The sheet's state: which target, and when.
@MainActor
@Observable
final class ReminderSheetModel {
    static let title = "Remind Me"
    static let confirmTitle = "Remind Me"
    static let inFiveMinutesTitle = "In 5 Minutes"
    static let inOneHourTitle = "In 1 Hour"

    /// The 09:00 button: "Today 09:00" while 09:00 is still ahead, otherwise "Tomorrow 09:00", the time
    /// in the person's locale format. `PingTime.defaultFireDate` decides which 09:00 it sets.
    static func nineTitle(now: Date, locale: Locale = .current, calendar: Calendar = .current) -> String {
        let day = nineDay(now: now, calendar: calendar)
        return (day == .today ? "Today" : "Tomorrow") + " " + MacNotificationCategory.nineOClock(locale: locale, calendar: calendar)
    }

    enum NineDay: Equatable { case today, tomorrow }

    /// Which day the 09:00 button sets, from the very date `nextNine()` sets (`PingTime.defaultFireDate`).
    static func nineDay(now: Date, calendar: Calendar) -> NineDay {
        let fire = PingTime.defaultFireDate(now: now, calendar: calendar)
        return calendar.isDate(fire, inSameDayAs: now) ? .today : .tomorrow
    }
    static let lineChoice = "This line"
    static let noteChoice = "The whole note"

    let noteId: String
    /// The line the caret was on; nil when only the whole note can be chosen.
    let lineAnchor: LineAnchor?
    /// The line as the reminder will show it, when there is one.
    let linePreview: String?
    var wholeNote: Bool
    var fireAt: Date

    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let locale: Locale

    init(
        target: ReminderTarget, linePreview: String? = nil, now: @escaping () -> Date = { .now },
        calendar: Calendar = .current, locale: Locale = .current
    ) {
        noteId = target.noteId
        lineAnchor = target.anchor
        self.linePreview = linePreview
        wholeNote = target.anchor == nil
        fireAt = PingTime.defaultFireDate(now: now(), calendar: calendar)
        self.now = now
        self.calendar = calendar
        self.locale = locale
    }

    var offersLine: Bool { lineAnchor != nil }

    var target: ReminderTarget {
        if let lineAnchor, !wholeNote { return .line(noteId: noteId, anchor: lineAnchor) }
        return .note(noteId: noteId)
    }

    var choice: ReminderChoice { ReminderChoice(target: target, fireAt: fireAt) }

    /// A time that has passed cannot be set.
    var canSet: Bool { fireAt > now() }

    /// The 09:00 button's label for the clock now.
    var nineTitle: String { Self.nineTitle(now: now(), locale: locale, calendar: calendar) }
    var nineDay: NineDay { Self.nineDay(now: now(), calendar: calendar) }

    func inFiveMinutes() { fireAt = PingTime.inFiveMinutes(now: now()) }
    func inOneHour() { fireAt = PingTime.inOneHour(now: now()) }
    func nextNine() { fireAt = PingTime.defaultFireDate(now: now(), calendar: calendar) }
}

/// The 09:00 button. A sheet can stay open across 09:00, so the label is re-read from the clock every
/// second: it never says "Today" for a click that now sets tomorrow.
struct ReminderNineButton: View {
    static let refreshSeconds: TimeInterval = 1
    let model: ReminderSheetModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.refreshSeconds)) { _ in
            Button(model.nineTitle) { model.nextNine() }
        }
    }
}

/// Note ▸ Remind Me…: pick the line or the note and a time.
struct ReminderSheet: View {
    @State private var model: ReminderSheetModel
    let onDone: (ReminderChoice?) -> Void

    init(target: ReminderTarget, linePreview: String? = nil, onDone: @escaping (ReminderChoice?) -> Void) {
        _model = State(initialValue: ReminderSheetModel(target: target, linePreview: linePreview))
        self.onDone = onDone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(ReminderSheetModel.title).font(.headline)
            if model.offersLine {
                Picker("About", selection: $model.wholeNote) {
                    Text(ReminderSheetModel.lineChoice).tag(false)
                    Text(ReminderSheetModel.noteChoice).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if !model.wholeNote, let preview = model.linePreview {
                    Text(preview).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            DatePicker("When", selection: $model.fireAt, displayedComponents: [.date, .hourAndMinute])
            HStack {
                Button(ReminderSheetModel.inFiveMinutesTitle) { model.inFiveMinutes() }
                Button(ReminderSheetModel.inOneHourTitle) { model.inOneHour() }
                ReminderNineButton(model: model)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onDone(nil) }.keyboardShortcut(.cancelAction)
                Button(ReminderSheetModel.confirmTitle) { onDone(model.choice) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSet)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

/// Shows the sheet over a window (or alone when none is up) and ends it on either answer.
@MainActor
enum ReminderPresenter {
    static func present(
        target: ReminderTarget, linePreview: String?, over parent: NSWindow?, onChoice: @escaping @MainActor (ReminderChoice) -> Void
    ) {
        var panel: NSWindow?
        let view = ReminderSheet(target: target, linePreview: linePreview) { choice in
            if let panel {
                if let parent, parent.sheets.contains(panel) { parent.endSheet(panel) } else { panel.close() }
            }
            panel = nil
            if let choice { onChoice(choice) }
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled]
        window.title = ReminderSheetModel.title
        panel = window
        if let parent {
            parent.beginSheet(window)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Said once after a reminder was saved while notifications are off for the app.
    static func notifyNotificationsOff(over parent: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Notifications are off"
        alert.informativeText = "The reminder is saved. Allow notifications for Theo Notes in System Settings to be told when it is due."
        alert.addButton(withTitle: "OK")
        if let parent { alert.beginSheetModal(for: parent) } else { alert.runModal() }
    }
}
