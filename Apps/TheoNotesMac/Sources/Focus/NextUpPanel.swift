// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import SwiftUI

/// Note ▸ Next Up: the title, and when the command is off.
enum NextUpMenu {
    static let title = "Next Up"

    /// Off without an app, while App Lock is engaged, and with no main window to hang the panel from.
    @MainActor
    static func isDisabled(app: AppModel?, hasMainWindow: Bool) -> Bool {
        guard let app, !app.isLocked else { return true }
        return !hasMainWindow
    }
}

extension AppModel {
    /// Note ▸ Next Up: the panel of `main` (else the frontmost main window, else a new one), brought forward.
    func showNextUp(preferring main: MainWindowState?) {
        guard !isLocked else { return }
        let show: (MainWindowState) -> Void = { state in
            state.window?.makeKeyAndOrderFront(nil)
            state.nextUp.present()
        }
        if let main { show(main) } else { withMainWindow(show) }
    }
}

/// The toolbar button; the panel hangs from it.
struct NextUpToolbarButton: View {
    @ObservedObject var model: NextUpModel
    @Environment(\.undoManager) private var undoManager

    private var symbol: String {
        switch model.toolbarTimerState {
        case .idle: "arrow.forward.circle"
        case .running: "timer"
        case .finished: "bell.fill"
        }
    }

    var body: some View {
        Button(NextUpMenu.title, systemImage: symbol) { model.toggle() }
            .help("Next Up")
            .disabled(model.isLocked)
            .popover(isPresented: $model.isPresented, arrowEdge: .bottom) {
                NextUpPanel(model: model)
            }
            .onAppear { model.undoManager = undoManager }
            .onChange(of: undoManager) { model.undoManager = $1 }
    }
}

/// The card: one thing, its actions, and the two-minute timer. It shows nothing while App Lock is engaged.
struct NextUpPanel: View {
    @ObservedObject var model: NextUpModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.isLocked {
                card
                Divider()
                timer
                if let notice = model.notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }

    // MARK: The card

    @ViewBuilder private var card: some View {
        switch model.candidate {
        case .reminder(let reminder)?:
            CandidateText(kind: "Reminder", symbol: "bell", title: reminder.title, line: reminder.lineText)
            actions
        case .todo(let todo)?:
            CandidateText(kind: "To-do", symbol: "circle", title: todo.title, line: todo.lineText)
            actions
        case .capture(let capture)?:
            CandidateText(kind: "Captured", symbol: "tray.and.arrow.down", title: capture.title, line: nil)
            actions
        case nil:
            Text("Nothing is waiting.")
                .foregroundStyle(.secondary)
            if model.offersVoiceCapture {
                Button("Capture Voice Note", systemImage: "mic") { model.captureVoice() }
            }
        }
    }

    private var actions: some View {
        HStack {
            Button("Open") { model.open() }
                .keyboardShortcut(.defaultAction)
            Button("Later") { model.later() }
            if model.canDone {
                Button("Done") { model.done() }
            }
            Spacer(minLength: 0)
            Button("Not Today") { model.notToday() }
        }
    }

    // MARK: The timer

    @ViewBuilder private var timer: some View {
        switch model.timerState {
        case .idle:
            Button("2-Minute Timer", systemImage: "timer") { Task { await model.startTimer() } }
        case .running:
            HStack {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = Int((model.timerRemaining(at: context.date) ?? 0).rounded(.up))
                    Label(Self.clock(seconds), systemImage: "timer")
                        .monospacedDigit()
                        .accessibilityLabel("Timer, \(seconds / 60) minutes \(seconds % 60) seconds left")
                }
                Spacer(minLength: 0)
                Button("Dismiss") { model.dismissTimer() }
            }
        case .finished:
            HStack {
                Label(NextUpModel.timerNotificationTitle, systemImage: "bell.fill")
                Spacer(minLength: 0)
                Button("Dismiss") { model.dismissTimer() }
            }
        }
    }

    static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// What the card is about: a small kind label, the note's title and, for a to-do or reminder, its line.
private struct CandidateText: View {
    let kind: String
    let symbol: String
    let title: String
    let line: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(kind, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .lineLimit(2)
            if let line {
                Text(line)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
