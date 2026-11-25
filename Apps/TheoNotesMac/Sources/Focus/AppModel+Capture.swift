// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import CryptoKit
import SwiftUI

/// Capture Thought (global shortcut and menu bar item, not the File menu): the title, and when the command is off.
enum CaptureThoughtMenu {
    static let title = "Capture Thought"

    /// Off without an app, and while App Lock is engaged (nothing reaches the library behind it).
    @MainActor
    static func isDisabled(app: AppModel?) -> Bool {
        guard let app else { return true }
        return app.isLocked
    }
}

extension AppModel {
    /// File ▸ Capture Thought: makes an empty note (`captureSource` command) and opens it in a new
    /// note window with the caret at its start. That window's own load is not an open (FOC-R3), and
    /// closing it with nothing typed moves the note to the Trash (`captureWindowClosed`). Returns the
    /// note's id, or nil when nothing was made: App Lock is engaged, the note could not be stored, or
    /// the window could not be requested (the empty note is cancelled again).
    @discardableResult
    func captureThought() -> String? {
        guard !isLocked else { return nil }
        let note: Note
        do {
            note = try environment.store.create(text: "", captureSource: .command)
        } catch {
            appLogger.error("could not capture a thought: \(error)")
            beep()
            return nil
        }
        environment.suppressOpenRecord(noteId: note.id)
        environment.registerCaptureWindow(noteId: note.id)
        guard openNoteInNewWindow(id: note.id, caret: 0) else {
            environment.abandonCapture(noteId: note.id)
            environment.cancelCapture(noteId: note.id)
            beep()
            return nil
        }
        return note.id
    }

    /// The window of `noteId` closed; `finish` lets go of its editor (commits the note, detaches).
    ///
    /// For the window Capture Thought opened this is the one door to cancelling the capture, and it
    /// goes through the editor first (FOC-R343): the editor is frozen and drained, so text typed
    /// just before the close has reached the session, and only then is "untouched" decided. An
    /// untouched capture goes to the Trash; anything else, and any doubt (the editor cannot
    /// confirm in time, App Lock engaged, the app quitting, another window showing the note), keeps
    /// it (FOC-R252, FOC-R344 … FOC-R346). `finish` runs once the answer is in. Any other window
    /// closes at once.
    func captureWindowClosed(noteId: String, editor: EditorBridgeController, finish: @escaping @MainActor () -> Void) {
        guard environment.takeCaptureWindow(noteId: noteId) else { return finish() }
        let key = UUID()
        captureCloses[key] = Task { @MainActor [self] in
            let untouched = await captureIsUntouched(noteId: noteId, editor: editor)
            finish()
            captureCloses[key] = nil
            onCaptureWindowClosed?(noteId)
            // Closing saved every open session. One that still holds text the store lacks (its save
            // failed) means the note is not empty: keep it.
            guard untouched, !isLocked, !isQuitting, !environment.unsavedNoteIds.contains(noteId) else { return }
            environment.cancelCapture(noteId: noteId)
        }
    }

    /// Completes when every capture close that is waiting for its editor has been decided.
    func settleCaptureCloses() async {
        while let task = captureCloses.values.first { await task.value }
    }

    /// True only when the editor, frozen and drained, says that the capture's document was never
    /// edited and holds exactly the session's text.
    private func captureIsUntouched(noteId: String, editor: EditorBridgeController) async -> Bool {
        guard !isLocked, !isQuitting, !environment.anotherEditorShows(noteId: noteId, besides: editor),
              let session = editor.session, session.noteId == noteId else { return false }
        guard let frozen = await editor.freezeForClose(noteId: noteId) else { return false }
        // The answer is about the document of that session: still the one shown, nothing else
        // happened to the app or the note meanwhile.
        guard editor.session === session, !isLocked, !isQuitting,
              !environment.anotherEditorShows(noteId: noteId, besides: editor) else { return false }
        let expected = SHA256.hash(data: Data(session.text.utf8)).map { String(format: "%02x", $0) }.joined()
        return !frozen.editedSinceLoad && frozen.sha256 == expected
    }
}
