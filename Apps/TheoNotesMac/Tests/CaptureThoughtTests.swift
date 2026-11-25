// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import SwiftUI
import Testing
@testable import TheoNotes

/// Focus layer C12: File ▸ Capture Thought, the captured mark in the note list, and `lastOpenedAt`
/// recorded when an editor shows a note (FOC-R2, FOC-R3, FOC-R120 … FOC-R122, FOC-R250 … FOC-R253).
@MainActor
@Suite struct CaptureThoughtTests {
    @MainActor
    final class Env {
        let root: URL
        let suiteName = "TheoNotesCapture-\(UUID().uuidString)"
        let defaults: UserDefaults
        let environment: AppEnvironment
        let app: AppModel
        var requests: [WindowRequest] = []

        init() throws {
            root = URL(fileURLWithPath: "/tmp/theo-capture-\(UUID().uuidString.prefix(8))", isDirectory: true)
            defaults = UserDefaults(suiteName: suiteName)!
            environment = try AppEnvironment(
                paths: AppPaths(root: root), appAuthenticator: FakeAppAuthenticator(), appLockLifecycle: nil,
                appIdleSeconds: { 0 })
            app = AppModel(environment: environment, defaults: defaults)
            app.openWindowRequest = { [unowned self] in self.requests.append($0) }
        }

        deinit {
            UserDefaults().removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        var store: NoteStore { environment.store }

        /// A ready editor with a fake page.
        func editor() -> (EditorBridgeController, FakeEditorPage) {
            let page = FakeEditorPage()
            let controller = EditorBridgeController(
                environment: environment, page: page, openExternally: { _ in }, checksumInterval: nil)
            _ = controller.handle(.ready(version: EditorBridge.version))
            return (controller, page)
        }

        /// What SwiftUI does for the note window the last request asked for.
        func openRequestedWindow() throws -> (window: NoteWindowState, editor: EditorBridgeController, page: FakeEditorPage) {
            guard case .note(let id) = requests.last else {
                Issue.record("expected a note window request, got \(requests)")
                throw CancellationError()
            }
            let (editor, page) = self.editor()
            return (app.makeNoteWindow(noteId: id, editor: editor), editor, page)
        }

        /// Waits for the freeze question a window close asked the page (W1). Fails the test if none came.
        func freezeQuestion(_ page: FakeEditorPage) async throws -> (requestId: String, noteId: String) {
            for _ in 0..<2000 where page.freezeRequests.isEmpty { await Task.yield() }
            return try #require(page.freezeRequests.last, "the close asked the editor nothing")
        }

        /// The page's answer to that question, as the editor would send it after draining.
        func answer(
            _ editor: EditorBridgeController, _ question: (requestId: String, noteId: String), ok: Bool = true,
            editedSinceLoad: Bool, text: String, reason: FreezeFailure = .timeout
        ) {
            _ = editor.handle(.frozenForClose(FrozenForClose(
                requestId: question.requestId, noteId: question.noteId, ok: ok, editedSinceLoad: editedSinceLoad,
                sha256: ok ? sha256Hex(text) : nil, reason: ok ? nil : reason)))
        }

        /// Plays an editor that answers "never edited, empty" to a question the close may ask. Gives
        /// the close the chance to ask; false if it did not (the tests that expect a note to be kept
        /// without asking use it so that asking anyway would trash the note and fail them).
        @discardableResult
        func answerIfAsked(_ opened: (window: NoteWindowState, editor: EditorBridgeController, page: FakeEditorPage)) async -> Bool {
            for _ in 0..<200 where opened.page.freezeRequests.isEmpty { await Task.yield() }
            guard let question = opened.page.freezeRequests.last else { return false }
            answer(opened.editor, question, editedSinceLoad: false, text: "")
            return true
        }

        /// Closes the window and plays the editor's answer, then waits for the decision.
        func close(
            _ opened: (window: NoteWindowState, editor: EditorBridgeController, page: FakeEditorPage),
            editedSinceLoad: Bool = false, text: String = ""
        ) async throws {
            opened.window.close()
            let question = try await freezeQuestion(opened.page)
            answer(opened.editor, question, editedSinceLoad: editedSinceLoad, text: text)
            await app.settleCaptureCloses()
        }
    }

    private func typed(_ noteId: String, _ text: String, base: Int = 0) -> EditorToHostMessage {
        .changes(
            noteId: noteId, txId: UUID().uuidString, baseRevision: base, revision: base + 1,
            changeSet: ChangeSet(sections: [.replace(deleteLength: 0, insert: text)]))
    }

    // MARK: - File ▸ Capture Thought

    @Test func captureThoughtOpensOneEmptyNoteWithSourceCommand() throws {
        let env = try Env()
        let id = try #require(env.app.captureThought())

        #expect(env.requests == [.note(id: id)])
        #expect(try env.store.allNotes().map(\.id) == [id])
        #expect(try env.store.note(id: id)?.text == "")
        #expect(try env.store.captureSource(noteId: id) == .command)

        let opened = try env.openRequestedWindow()
        #expect(opened.page.loadNotes.last == .loadNote(
            noteId: id, text: "", revision: 0, readOnly: false, selection: SelectionRange(anchor: 0, head: 0)))
    }

    @Test func closingItUntouchedMovesItToTheTrash() async throws {
        let env = try Env()
        let id = try #require(env.app.captureThought())
        let opened = try env.openRequestedWindow()

        opened.window.close()
        let question = try await env.freezeQuestion(opened.page)
        #expect(question.noteId == id)
        #expect(try env.store.note(id: id)?.location == .notes, "nothing is decided before the editor answers")
        env.answer(opened.editor, question, editedSinceLoad: false, text: "")
        await env.app.settleCaptureCloses()

        let note = try #require(try env.store.note(id: id))
        #expect(note.location == .trash)
        #expect(opened.editor.session == nil, "the editor let go of the note after the decision")
    }

    @Test func closingItAfterTypingKeepsIt() async throws {
        let env = try Env()
        let id = try #require(env.app.captureThought())
        let opened = try env.openRequestedWindow()
        #expect(opened.editor.handle(typed(id, "buy milk")) == .acked(revision: 1))

        try await env.close(opened, editedSinceLoad: true, text: "buy milk")

        let note = try #require(try env.store.note(id: id))
        #expect(note.location == .notes)
        #expect(note.text == "buy milk")
    }

    /// The bug of C12b: text typed just before the close is still on its way when the window closes.
    /// The close waits for the editor, the transaction arrives meanwhile, the note keeps the text.
    @Test func closingBeforeTheTypedTransactionArrivesKeepsTheNoteWithTheText() async throws {
        let env = try Env()
        let id = try #require(env.app.captureThought())
        let opened = try env.openRequestedWindow()

        opened.window.close() // the page has typed "buy milk"; its transaction is not at the host yet
        let question = try await env.freezeQuestion(opened.page)
        #expect(try env.store.note(id: id)?.location == .notes)
        #expect(opened.editor.handle(typed(id, "buy milk")) == .acked(revision: 1)) // arrives during the drain
        env.answer(opened.editor, question, editedSinceLoad: true, text: "buy milk")
        await env.app.settleCaptureCloses()

        let note = try #require(try env.store.note(id: id))
        #expect(note.location == .notes)
        #expect(note.text == "buy milk")
    }

    @Test func anEditorThatSaysUntouchedButHoldsOtherTextThanTheSessionKeepsIt() async throws {
        let env = try Env()
        let id = try #require(env.app.captureThought())
        let opened = try env.openRequestedWindow()
        #expect(opened.editor.handle(typed(id, "typed")) == .acked(revision: 1))

        // The editor's document ("") is not the session's ("typed"): something is not in sync.
        try await env.close(opened, editedSinceLoad: false, text: "")

        let note = try #require(try env.store.note(id: id))
        #expect(note.location == .notes)
        #expect(note.text == "typed")
    }

    /// The editor says "never edited" but its document is not the empty text the session holds:
    /// the two disagree, so nothing is decided from either.
    @Test func anEditorWhoseDocumentIsNotTheSessionsEmptyTextKeepsIt() async throws {
        let env = try Env()
        let id = try #require(env.app.captureThought())
        let opened = try env.openRequestedWindow()

        try await env.close(opened, editedSinceLoad: false, text: "text the host never received")

        #expect(try env.store.note(id: id)?.location == .notes)
    }

    @Test func aDocumentThatWasEditedAndEmptiedAgainIsKept() async throws {
        let env = try Env()
        let id = try #require(env.app.captureThought())
        let opened = try env.openRequestedWindow()

        // Typed and deleted again: empty, but "never edited" is the only rule that trashes.
        try await env.close(opened, editedSinceLoad: true, text: "")

        #expect(try env.store.note(id: id)?.location == .notes)
    }

    @Test func anEditorThatNeverAnswersKeepsIt() async throws {
        let env = try Env()
        let id = try #require(env.app.captureThought())
        let opened = try env.openRequestedWindow()
        opened.editor.freezeTimeout = .milliseconds(50)

        opened.window.close()
        await env.app.settleCaptureCloses()

        #expect(!opened.page.freezeRequests.isEmpty)
        #expect(try env.store.note(id: id)?.location == .notes)
        #expect(opened.editor.session == nil, "the window still let go of its editor")
    }

    @Test func anEditorThatCannotDrainKeepsIt() async throws {
        let env = try Env()
        let id = try #require(env.app.captureThought())
        let opened = try env.openRequestedWindow()

        opened.window.close()
        let question = try await env.freezeQuestion(opened.page)
        env.answer(opened.editor, question, ok: false, editedSinceLoad: false, text: "", reason: .timeout)
        await env.app.settleCaptureCloses()

        #expect(try env.store.note(id: id)?.location == .notes)
    }

    @Test func aWebViewThatWentAwayWhileTheCloseWaitsKeepsIt() async throws {
        let env = try Env()
        let id = try #require(env.app.captureThought())
        let opened = try env.openRequestedWindow()

        opened.window.close()
        let question = try await env.freezeQuestion(opened.page)
        opened.editor.simulateWebContentTermination()
        // A late answer from the old page changes nothing.
        env.answer(opened.editor, question, editedSinceLoad: false, text: "")
        await env.app.settleCaptureCloses()

        #expect(try env.store.note(id: id)?.location == .notes)
    }

    @Test func aPageThatNeverBootedKeepsIt() async throws {
        let env = try Env()
        let id = try #require(env.app.captureThought())
        let page = FakeEditorPage()
        let editor = EditorBridgeController(
            environment: env.environment, page: page, openExternally: { _ in }, checksumInterval: nil) // no `ready`
        let window = env.app.makeNoteWindow(noteId: id, editor: editor)

        window.close()
        await env.app.settleCaptureCloses()

        #expect(page.freezeRequests.isEmpty, "nothing to ask a page that is not there")
        #expect(try env.store.note(id: id)?.location == .notes)
    }

    @Test func aCaptureWhoseTextIsNotSavedYetIsKept() async throws {
        let env = try Env()
        let id = try #require(env.app.captureThought())
        env.environment.captureWindowOpened(noteId: id) // its window is open
        let (editor, page) = env.editor()
        try editor.open(noteId: id)
        #expect(editor.handle(typed(id, "still in the session")) == .acked(revision: 1))
        #expect(try env.store.note(id: id)?.text == "", "the typed text is not committed yet")

        // The window closes, but the save of that session does not happen (`finish` does nothing).
        // Even an editor that claims "untouched, same text" cannot make an unsaved note empty.
        env.app.captureWindowClosed(noteId: id, editor: editor, finish: {})
        let question = try await env.freezeQuestion(page)
        env.answer(editor, question, editedSinceLoad: false, text: "still in the session")
        await env.app.settleCaptureCloses()

        let note = try #require(try env.store.note(id: id))
        #expect(note.location == .notes)
    }

    @Test func closingItKeepsTextTypedInAnotherWindowOfTheSameNote() async throws {
        let env = try Env()
        let id = try #require(env.app.captureThought())
        let opened = try env.openRequestedWindow()
        let other = try env.store.create(text: "elsewhere").id
        // The capture window moved on to another note; a second editor types into the capture.
        opened.window.show(noteId: other)
        let (second, _) = env.editor()
        try second.open(noteId: id)
        #expect(second.handle(typed(id, "typed over there")) == .acked(revision: 1))
        #expect(try env.store.note(id: id)?.text == "", "the typed text is not committed yet")

        opened.window.close()
        await env.answerIfAsked(opened)
        await env.app.settleCaptureCloses()

        let note = try #require(try env.store.note(id: id))
        #expect(note.location == .notes)
        #expect(note.text == "typed over there")
        #expect(opened.page.freezeRequests.isEmpty, "this window no longer shows the capture: nothing to ask")
    }

    @Test func aSecondWindowShowingTheCaptureKeepsItEvenWhenNothingWasTyped() async throws {
        let env = try Env()
        let id = try #require(env.app.captureThought())
        let opened = try env.openRequestedWindow()
        let (second, _) = env.editor()
        try second.open(noteId: id) // e.g. the note selected in a main window

        opened.window.close()
        await env.answerIfAsked(opened)
        await env.app.settleCaptureCloses()

        #expect(try env.store.note(id: id)?.location == .notes)
        #expect(second.session?.noteId == id, "the other window is not disturbed")
    }

    @Test func switchingNotesInTheWindowBeforeClosingNeverCancelsTheCapture() async throws {
        let env = try Env()
        let id = try #require(env.app.captureThought())
        let opened = try env.openRequestedWindow()
        let other = try env.store.create(text: "elsewhere").id

        opened.window.show(noteId: other)
        opened.window.close()
        await env.answerIfAsked(opened)
        await env.app.settleCaptureCloses()

        #expect(try env.store.note(id: id)?.location == .notes)
        #expect(try env.store.note(id: other)?.location == .notes)
    }

    @Test func switchingNotesWhileTheCloseWaitsKeepsIt() async throws {
        let env = try Env()
        let id = try #require(env.app.captureThought())
        let opened = try env.openRequestedWindow()
        let other = try env.store.create(text: "elsewhere").id

        opened.window.close()
        let question = try await env.freezeQuestion(opened.page)
        try opened.editor.open(noteId: other) // the editor moves on while the question is open
        env.answer(opened.editor, question, editedSinceLoad: false, text: "")
        await env.app.settleCaptureCloses()

        #expect(try env.store.note(id: id)?.location == .notes)
    }

    @Test func aCaptureIsOnlyCancelledByItsOwnWindow() async throws {
        let env = try Env()
        let id = try #require(env.app.captureThought())
        let first = try env.openRequestedWindow()
        try await env.close(first)
        #expect(try env.store.note(id: id)?.location == .trash)

        // A later window on the same (restored) empty note is an ordinary window.
        try env.store.restore([id])
        let (editor, page) = env.editor()
        let again = env.app.makeNoteWindow(noteId: id, editor: editor)
        again.close()
        await env.answerIfAsked((again, editor, page))
        await env.app.settleCaptureCloses()
        #expect(try env.store.note(id: id)?.location == .notes)
        #expect(page.freezeRequests.isEmpty, "an ordinary window asks nothing")
    }

    @Test func nothingIsCreatedWhenTheWindowCannotBeRequested() throws {
        let env = try Env()
        env.app.openWindowRequest = nil
        for _ in 0..<AppModel.maxQueuedWindowRequests { env.app.requestWindow(.main) }
        #expect(env.app.captureThought() == nil)
        #expect(try env.store.allNotes().isEmpty, "the empty capture is cancelled at once")
    }

    // MARK: - lastOpenedAt

    @Test func itsOwnLoadIsNotAnOpen() throws {
        let env = try Env()
        let id = try #require(env.app.captureThought())
        _ = try env.openRequestedWindow()
        #expect(try env.store.lastOpenedAt(noteId: id) == nil)

        // The suppression covers that one load only: the user opening the note later is an open.
        let (editor, _) = env.editor()
        try editor.open(noteId: id)
        #expect(try env.store.lastOpenedAt(noteId: id) != nil)
    }

    @Test func openingANoteRecordsLastOpenedWithoutChangingRevision() throws {
        let env = try Env()
        let id = try env.store.create(text: "# Plan\n\n- [ ] one").id
        let before = try #require(try env.store.note(id: id))
        #expect(try env.store.lastOpenedAt(noteId: id) == nil)

        let (editor, _) = env.editor()
        try editor.open(noteId: id)

        let after = try #require(try env.store.note(id: id))
        #expect(try env.store.lastOpenedAt(noteId: id) != nil)
        #expect(after.revision == before.revision)
        #expect(after.modifiedAt == before.modifiedAt)
        #expect(after.text == before.text)
    }

    @Test func showingTheSameNoteAgainInTheSameEditorIsNotANewOpen() throws {
        let env = try Env()
        let id = try env.store.create(text: "same").id
        let (editor, _) = env.editor()
        try editor.open(noteId: id)
        let first = try #require(try env.store.lastOpenedAt(noteId: id))

        try editor.open(noteId: id)
        #expect(try env.store.lastOpenedAt(noteId: id) == first)
    }

    // MARK: - The captured mark

    @Test func noteRowShowsTheCapturedMarkOnlyForCaptures() throws {
        let env = try Env()
        let captured = try env.store.create(text: "from a gesture", captureSource: .command).id
        let ordinary = try env.store.create(text: "typed in the app").id
        let main = env.app.makeMainWindow(editor: env.editor().0)
        main.model.refresh()
        let items = Dictionary(uniqueKeysWithValues: main.model.items.map { ($0.id, $0) })

        #expect(NoteRow.showsCapturedMark(for: try #require(items[captured])))
        #expect(!NoteRow.showsCapturedMark(for: try #require(items[ordinary])))
        #expect(NoteRow.capturedSymbol == "tray.and.arrow.down")
        #expect(NoteRow.capturedLabel == "Captured")

        // The complete label VoiceOver reads for the row: the mark's own label, exactly.
        let now = Date()
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let modified = formatter.localizedString(for: now, relativeTo: now)
        let label = NoteListAccessibility.label(for: try #require(items[captured]), date: now, now: now)
        #expect(label == "from a gesture, Captured, modified \(modified)")
        let plain = NoteListAccessibility.label(for: try #require(items[ordinary]), date: now, now: now)
        #expect(plain == "typed in the app, modified \(modified)")
    }

    // MARK: - App Lock

    @Test func menuItemIsDisabledWhileAppLocked() async throws {
        let env = try Env()
        #expect(!CaptureThoughtMenu.isDisabled(app: env.app))
        #expect(CaptureThoughtMenu.isDisabled(app: nil))
        #expect(CaptureThoughtMenu.title == "Capture Thought")

        #expect(await env.environment.appLock.setEnabled(true) == .enabled)
        env.environment.appLock.lock()
        #expect(env.environment.appLock.isLocked)
        #expect(CaptureThoughtMenu.isDisabled(app: env.app))

        // The command itself refuses too (the automation and URL doors do not reach it, but a stale
        // menu validation must not create a note behind the lock screen).
        #expect(env.app.captureThought() == nil)
        #expect(try env.store.allNotes().isEmpty)
        #expect(env.requests.isEmpty)
    }

    /// The File menu of the test host's menu bar (the host has no `AppModel`, so the item is off there).
    /// A7: Capture Thought left the File menu; its global shortcut and the menu bar item stay.
    @Test func fileMenuHasNoCaptureThought() throws {
        let mainMenu = try #require(NSApp.mainMenu)
        let file = try #require(mainMenu.items.first { $0.title == "File" }?.submenu)
        #expect(!file.items.contains { $0.title == "Capture Thought" })
    }

    /// The File menu's button takes its state from App Lock. (A hosted SwiftUI window exposes no
    /// accessibility children here, see AccessibilityAuditTests; the live menu above covers the nil case.)
    @Test func menuButtonFollowsAppLock() async throws {
        let env = try Env()
        #expect(!CaptureThoughtMenu.isDisabled(app: env.app))
        #expect(CaptureThoughtMenu.isDisabled(app: nil))

        #expect(await env.environment.appLock.setEnabled(true) == .enabled)
        env.environment.appLock.lock()
        #expect(env.environment.appLock.isLocked)
        #expect(CaptureThoughtMenu.isDisabled(app: env.app))
    }

    @Test func lockingBetweenTheRequestAndTheWindowLeavesNoEmptyNote() async throws {
        let env = try Env()
        let id = try #require(env.app.captureThought())
        // The window never appeared: the lock came first and the request went stale.
        #expect(await env.environment.appLock.setEnabled(true) == .enabled)
        env.environment.appLock.lock()

        #expect(!env.environment.consumeOpenRecordSuppression(id))
        #expect(try env.store.allNotes().isEmpty, "the empty capture is not left in Notes")
        #expect(try env.store.note(id: id)?.location == .trash)
    }

    /// App Lock engaged when the window closes: nothing reaches the library behind it, so the note
    /// stays as it is (FOC-R345, amends FOC-R252's "closing cancels").
    /// Fix round 1: the lock-before-window path used to call the store directly. Every cancel of a
    /// capture in the app goes through `AppEnvironment.cancelCapture(noteId:)` (FOC-R350).
    @Test func everyCaptureCancelInTheAppGoesThroughOneEntryPoint() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var callers: [String] = []
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("store.cancelCapture(") { callers.append(file.lastPathComponent) }
        }
        #expect(callers == ["AppEnvironment.swift"], "capture cancels outside AppEnvironment.cancelCapture: \(callers)")
    }

    /// Lock before the window exists: nothing has an editor, the empty capture is cancelled by the
    /// one entry point, and the stale window is no capture window any more.
    @Test func lockingBeforeTheWindowExistsCancelsOnlyAnEmptyCapture() async throws {
        let env = try Env()
        let empty = try #require(env.app.captureThought())
        let typedInto = try #require(env.app.captureThought())
        // Someone typed into the second capture through another editor; the text is not committed yet.
        let (other, _) = env.editor()
        try other.open(noteId: typedInto)
        #expect(other.handle(typed(typedInto, "typed")) == .acked(revision: 1))
        #expect(try env.store.note(id: typedInto)?.text == "", "the typed text is not committed yet")

        #expect(await env.environment.appLock.setEnabled(true) == .enabled)
        env.environment.appLock.lock()

        #expect(try env.store.note(id: empty)?.location == .trash)
        let kept = try #require(try env.store.note(id: typedInto))
        #expect(kept.location == .notes)
        #expect(kept.text == "typed", "the typed text was saved before the cancel decided")
        // The stale window requests are gone: a window that opens late is an ordinary one.
        for id in [empty, typedInto] {
            env.environment.captureWindowOpened(noteId: id)
            #expect(!env.environment.takeCaptureWindow(noteId: id))
        }
    }

    @Test func closingWhileAppLockIsEngagedKeepsTheNote() async throws {
        let env = try Env()
        let id = try #require(env.app.captureThought())
        let opened = try env.openRequestedWindow()
        #expect(await env.environment.appLock.setEnabled(true) == .enabled)
        env.environment.appLock.lock()
        #expect(try env.store.note(id: id)?.location == .notes, "the window is open: it decides when it closes")

        opened.window.close()
        await env.answerIfAsked(opened)
        await env.app.settleCaptureCloses()

        #expect(try env.store.note(id: id)?.location == .notes)
        #expect(opened.editor.session == nil, "the window still let go of its editor")
    }

    @Test func appLockEngagingWhileTheCloseWaitsKeepsTheNote() async throws {
        let env = try Env()
        let id = try #require(env.app.captureThought())
        let opened = try env.openRequestedWindow()

        opened.window.close()
        let question = try await env.freezeQuestion(opened.page)
        #expect(await env.environment.appLock.setEnabled(true) == .enabled)
        env.environment.appLock.lock()
        env.answer(opened.editor, question, editedSinceLoad: false, text: "")
        await env.app.settleCaptureCloses()

        #expect(try env.store.note(id: id)?.location == .notes)
    }

    @Test func quittingWhileTheCloseWaitsKeepsTheNote() async throws {
        let env = try Env()
        let id = try #require(env.app.captureThought())
        let opened = try env.openRequestedWindow()

        opened.window.close()
        let question = try await env.freezeQuestion(opened.page)
        env.app.isQuitting = true // applicationShouldTerminate
        env.answer(opened.editor, question, editedSinceLoad: false, text: "")
        await env.app.settleCaptureCloses()

        #expect(try env.store.note(id: id)?.location == .notes)
    }
}
