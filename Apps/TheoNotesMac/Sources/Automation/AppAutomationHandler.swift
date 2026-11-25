// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesAutomation
import TheoNotesCore
import Foundation

/// Answers the requests that arrive on the automation socket (`AppSocketServer`): open a note, report
/// the selection. Runs on the main actor, since it touches windows and editors. Never logs note text.
@MainActor
final class AppAutomationHandler {
    private let app: AppModel

    init(app: AppModel) { self.app = app }

    func handle(_ request: AppSocketRequest) -> AppSocketResponse {
        // The server cancels the task of a request it has already answered with a timeout; such a
        // request must not act when the main actor finally gets to it (ruling M5-R207).
        if Task.isCancelled, request.method != "ping" {
            return failure(request.id, AutomationError(code: .appUnavailable, message: AppSocketClient.timeoutMessage))
        }
        // App Lock (M9M-R63): `ping` only says the app runs. Everything else that could name or return a
        // note is refused, whatever the method.
        if request.method != "ping", app.isLocked {
            return failure(request.id, AutomationError(code: .appLocked, message: AppLockedRefusal.message))
        }
        switch request.method {
        case "ping":
            return AppSocketResponse(id: request.id, result: SelectionResult())
        case "open":
            guard let params = request.params else {
                return failure(request.id, AutomationError(code: .usage, message: "open needs a note"))
            }
            do throws(AutomationError) {
                return AppSocketResponse(id: request.id, result: try open(params))
            } catch {
                return failure(request.id, error)
            }
        case "getSelection":
            return AppSocketResponse(id: request.id, result: getSelection())
        default:
            return failure(request.id, AutomationError(code: .usage, message: "Unknown request: \(request.method)"))
        }
    }

    private func failure(_ id: Int, _ error: AutomationError) -> AppSocketResponse {
        AppSocketResponse(id: id, error: AppSocketError(code: error.code, message: error.message))
    }

    // MARK: - open

    /// Checks the note, the heading and the selection, then shows the note (`AppModel.openNote`). The
    /// reusable open path: the x-callback `open-note` calls it with the same parameters.
    @discardableResult
    func open(_ params: OpenParams, find: String? = nil, showWindow: Bool = true) throws(AutomationError) -> SelectionResult {
        let environment = app.environment
        // What was typed a moment ago is in the store, so the heading index and the text are current.
        environment.flushAll()
        let note = try loadNote(params.noteId)
        var selection: SelectionRange?
        if params.selectionText != nil || params.selectionOffset != nil {
            if note.isLocked {
                throw AutomationError(code: .noteLocked, message: "Note is locked: \(note.id)")
            }
            let text = environment.existingSession(for: note.id)?.text ?? note.text
            selection = try Self.selection(
                in: text, matching: params.selectionText, offset: params.selectionOffset, length: params.selectionLength)
        }
        // A heading the note does not have is not an error: the note opens at the top (`open-note` contract).
        let headingIndex = params.header.flatMap { try? environment.store.headingIndex(noteId: note.id, heading: $0) }
        if Task.isCancelled {
            throw AutomationError(code: .appUnavailable, message: AppSocketClient.timeoutMessage)
        }
        let shown = app.openNote(
            OpenNoteRequest(
                noteId: note.id, headingIndex: headingIndex, edit: params.edit, newWindow: params.newWindow,
                float: params.float, selection: selection, find: find, showWindow: showWindow))
        guard shown else { throw AutomationError(code: .busy, message: "Theo Notes is still starting; try again") }
        return SelectionResult(noteId: note.id)
    }

    private func loadNote(_ id: String) throws(AutomationError) -> Note {
        do {
            if let note = try app.environment.store.note(id: id) { return note }
        } catch {
            throw AutomationError(code: .internal, message: "The library could not be read")
        }
        throw AutomationError(code: .noteNotFound, message: "Note not found: \(id)")
    }

    /// The UTF-16 range of the selection `app open` asks for. `matching` must occur exactly once
    /// (case-sensitive, byte for byte; occurrences may overlap, so "aa" in "aaa" is two). `offset` and
    /// `length` are UTF-8 bytes that must not split a scalar or leave the note.
    static func selection(
        in text: String, matching selectionText: String?, offset: Int?, length: Int?
    ) throws(AutomationError) -> SelectionRange? {
        let outside = AutomationError(code: .usage, message: "Selection is outside the note")
        if let selectionText {
            let bytes = Array(text.utf8)
            let needle = Array(selectionText.utf8)
            var starts: [Int] = []
            if !needle.isEmpty, bytes.count >= needle.count {
                for index in 0...(bytes.count - needle.count) where bytes[index] == needle[0] {
                    if bytes[index..<index + needle.count].elementsEqual(needle) { starts.append(index) }
                }
            }
            guard let first = starts.first else {
                throw AutomationError(code: .notFound, message: "Selection text not found")
            }
            guard starts.count == 1 else {
                throw AutomationError(code: .ambiguous, message: "Selection text matches \(starts.count) times")
            }
            do {
                return SelectionRange(
                    anchor: try TextOffsets.utf16Offset(fromUTF8: first, in: text),
                    head: try TextOffsets.utf16Offset(fromUTF8: first + needle.count, in: text))
            } catch {
                throw outside
            }
        }
        guard let offset else { return nil }
        let (end, overflow) = offset.addingReportingOverflow(length ?? 0)
        guard offset >= 0, (length ?? 0) >= 0, !overflow else { throw outside }
        do {
            return SelectionRange(
                anchor: try TextOffsets.utf16Offset(fromUTF8: offset, in: text),
                head: try TextOffsets.utf16Offset(fromUTF8: end, in: text))
        } catch {
            throw outside
        }
    }

    // MARK: - getSelection

    /// The note in the key window's editor and its selection in UTF-8 bytes. No open note: nothing. A
    /// locked note: its id only. A selection the editor has not reported, or one that no longer fits
    /// the text, or text that could not be stored: the id only. Typing not yet committed is flushed
    /// first, so the offsets and the text the caller then reads from the store are one text (final
    /// review M2).
    func getSelection() -> SelectionResult {
        app.environment.flushAll()
        guard let editor = app.keyEditor(), let session = editor.session, !session.noteId.isEmpty,
              let note = (try? app.environment.store.note(id: session.noteId)) ?? nil
        else { return SelectionResult() }
        let result = SelectionResult(noteId: note.id)
        // Words a voice capture holds out of the store (FOC-R395) would shift the offsets: the
        // selection is only reported on the stored text (FOC-R401).
        guard !note.isLocked, let range = editor.status.selection,
              TextNormalization.identical(session.text, session.committedText) else { return result }
        let text = session.text
        let (from, to) = (min(range.anchor, range.head), max(range.anchor, range.head))
        guard let start = try? TextOffsets.utf8Offset(fromUTF16: from, in: text),
              let end = try? TextOffsets.utf8Offset(fromUTF16: to, in: text)
        else { return result }
        let utf16 = text.utf16
        let low = utf16.index(utf16.startIndex, offsetBy: from)
        let high = utf16.index(low, offsetBy: to - from)
        return SelectionResult(
            noteId: note.id, selectionOffset: start, selectionLength: end - start,
            selectionText: String(text[low..<high]))
    }
}
