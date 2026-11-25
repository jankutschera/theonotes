// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore

/// Which part of a note a reminder from the editor's right-click menu is about.
enum ReminderScope {
    case line, note
}

extension AppModel {
    /// Note ▸ Remind Me…: in a main window the note its editor shows (else the selected one), in a note
    /// window its note. With the editor focused the sheet offers the caret's line as well.
    func remindMe(main: MainWindowState?, noteWindow: NoteWindowState?, editorFocused: Bool) {
        guard !isLocked else { return }
        if let main {
            let noteId = main.editor.session?.noteId ?? main.model.selectedNoteIDs.first
            guard let noteId else { return }
            present(noteId: noteId, caret: editorFocused ? main.editor.status.selection?.head : nil, over: main.window)
        } else if let noteWindow {
            present(noteId: noteWindow.noteId, caret: editorFocused ? noteWindow.editor.status.selection?.head : nil,
                    over: noteWindow.hostWindow)
        }
    }

    /// The editor's right-click menu: "Remind Me…".
    func remind(editor: EditorBridgeController, scope: ReminderScope) {
        guard !isLocked, let noteId = editor.session?.noteId else { return }
        let caret = scope == .line ? editor.status.selection?.head : nil
        present(noteId: noteId, caret: caret, over: editor.webView.window)
    }

    private func present(noteId: String, caret: Int?, over parent: NSWindow?) {
        // What was typed is saved first, so the line's hash is the stored line's.
        environment.flushAll()
        guard let target = ReminderTarget.resolve(note: (try? environment.store.note(id: noteId)) ?? nil, caret: caret) else {
            beep()
            return
        }
        let preview: String? = {
            guard case .line(_, let anchor) = target, let note = (try? environment.store.note(id: noteId)) ?? nil else { return nil }
            return LineAnchor.lineText(anchor.line, in: note.text).map(FocusClock.displayLine)
        }()
        ReminderPresenter.present(target: target, linePreview: preview, over: parent) { [weak self] choice in
            Task { await self?.setReminder(choice, over: parent) }
        }
    }

    /// Saves the reminder and schedules it; says so once when notifications are off for the app.
    @discardableResult
    func setReminder(_ choice: ReminderChoice, over parent: NSWindow? = nil) async -> MacNotificationScheduler.Outcome? {
        do {
            let outcome = try await environment.reminders.setReminder(
                noteId: choice.target.noteId, anchor: choice.target.anchor, fireAt: choice.fireAt)
            if outcome == .notificationsOff { ReminderPresenter.notifyNotificationsOff(over: parent) }
            return outcome
        } catch {
            appLogger.error("could not set a reminder: \(error)")
            beep()
            return nil
        }
    }

    /// Wires a tapped notification to the window code. Called once by the app delegate.
    func connectReminderTaps() {
        environment.reminders.openNote = { [weak self] noteId, caret in
            guard let self else { return false }
            let selection = caret.map { SelectionRange(anchor: $0, head: $0) }
            return openNote(OpenNoteRequest(noteId: noteId, selection: selection))
        }
    }
}
