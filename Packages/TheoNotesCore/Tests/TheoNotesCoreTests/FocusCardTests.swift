// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct FocusCardTests {
    static let now = FocusFixtureLibrary.now
    static let calendar = FocusFixtureLibrary.utc

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private func todo(_ candidate: FocusCandidate?) throws -> TodoCandidate {
        guard case .todo(let todo)? = candidate else { throw Failure("expected a to-do, got \(String(describing: candidate))") }
        return todo
    }

    private func reminder(_ candidate: FocusCandidate?) throws -> ReminderCandidate {
        guard case .reminder(let reminder)? = candidate else { throw Failure("expected a reminder, got \(String(describing: candidate))") }
        return reminder
    }

    private func next(_ f: FocusFixtureLibrary, at date: Date = FocusCardTests.now) throws -> FocusCandidate? {
        try f.card.next(now: date, calendar: Self.calendar)
    }

    // MARK: Spec section 9

    @Test func cardSequenceFromTheSpec() throws {
        let f = try FocusFixtureLibrary(); defer { f.cleanup() }
        let notesBefore = try f.allNotes()

        // The older open to-do outranks the newer capture.
        let call = try todo(try next(f))
        #expect(call.noteId == f.oldTodo.id)
        #expect(call.title == "Old todo")
        #expect(call.lineText == "Call Anna")
        #expect(call.anchor == LineAnchor.at(line: 2, in: f.oldTodo.text))
        #expect(call.caretOffset == "# Old todo\n".utf16.count)
        #expect(!call.isReadOnly)

        // Later: the next card is the capture, not the locked Secret that is older still.
        try f.card.later(.todo(call), now: Self.now, calendar: Self.calendar)
        #expect(try next(f) == .capture(NoteCandidate(noteId: f.captured.id, title: "Captured")))

        // Not Today: the empty card until the next local midnight.
        try f.card.notToday(now: Self.now, calendar: Self.calendar)
        #expect(try next(f) == nil)
        let midnight = FocusClock.nextLocalMidnight(after: Self.now, calendar: Self.calendar)
        #expect(try next(f, at: midnight.addingTimeInterval(-1)) == nil)
        #expect(try f.hideCount() == 2)

        // Midnight ends both hides and deletes the expired rows.
        #expect(try todo(try next(f, at: midnight)).noteId == f.oldTodo.id)
        #expect(try f.hideCount() == 0)

        // The notes are byte-identical across all three actions (I4).
        #expect(try f.allNotes() == notesBefore)
    }

    @Test func doneTogglesOneCheckboxAndUndoPutsItBack() throws {
        let f = try FocusFixtureLibrary(); defer { f.cleanup() }
        let chores = try f.store.create(text: "# Chores\n- [ ] Call Anna\n- [ ] Call Bob\n- [x] Pay rent", now: Self.now)
        try f.store.trash([f.oldTodo.id])
        let candidate = try todo(try next(f))
        #expect(candidate.noteId == chores.id)
        #expect(candidate.lineText == "Call Anna")

        let toggle = try f.card.done(candidate, now: Self.now.addingTimeInterval(60))

        #expect(toggle.before == chores.text)
        #expect(toggle.after == "# Chores\n- [x] Call Anna\n- [ ] Call Bob\n- [x] Pay rent")
        let afterDone = try #require(try f.store.note(id: chores.id))
        #expect(afterDone.text == toggle.after)
        #expect(afterDone.location == .notes)
        #expect(afterDone.revision == chores.revision + 1)
        // The next card is the other open to-do of the same note.
        #expect(try todo(try next(f)).lineText == "Call Bob")

        #expect(try f.card.undo(toggle, now: Self.now.addingTimeInterval(120)))
        #expect(try f.store.note(id: chores.id)?.text == chores.text)
        #expect(try todo(try next(f)).lineText == "Call Anna")
        // One undo step: the same toggle cannot be undone twice.
        #expect(try f.card.undo(toggle) == false)
    }

    @Test func undoAfterAFurtherEditDoesNothing() throws {
        let f = try FocusFixtureLibrary(); defer { f.cleanup() }
        let toggle = try f.card.done(try todo(try next(f)), now: Self.now)
        let doneNote = try #require(try f.store.note(id: f.oldTodo.id))
        let edited = try f.store.updateText(
            id: doneNote.id, text: doneNote.text + "\nmore", expectedRevision: doneNote.revision, now: Self.now)

        #expect(try f.card.undo(toggle) == false)
        #expect(try f.store.note(id: f.oldTodo.id) == edited)
        #expect(edited.text == "# Old todo\n- [x] Call Anna\nmore")
    }

    @Test func dueReminderOutranksTheTodo() throws {
        let f = try FocusFixtureLibrary(); defer { f.cleanup() }
        let ping = try f.store.setPing(noteId: f.plain.id, anchor: nil, fireAt: Self.now.addingTimeInterval(-60), now: Self.now)

        let card = try reminder(try next(f))
        #expect(card.pingId == ping.id)
        #expect(card.noteId == f.plain.id)
        #expect(card.title == "Plain")
        #expect(card.lineText == nil)
        #expect(card.caretOffset == nil)
        #expect(!card.isLocked)

        // Opening handles it: the row is gone and the to-do is next.
        try f.card.opened(.reminder(card), now: Self.now)
        #expect(try f.store.ping(id: ping.id) == nil)
        #expect(try todo(try next(f)).noteId == f.oldTodo.id)
        #expect(try f.store.lastOpenedAt(noteId: f.plain.id) == Self.now)
    }

    @Test func aReminderThatIsNotDueYetDoesNotShow() throws {
        let f = try FocusFixtureLibrary(); defer { f.cleanup() }
        _ = try f.store.setPing(noteId: f.plain.id, anchor: nil, fireAt: Self.now.addingTimeInterval(60), now: Self.now)
        #expect(try todo(try next(f)).noteId == f.oldTodo.id)
        #expect(try reminder(try next(f, at: Self.now.addingTimeInterval(60))).title == "Plain")
    }

    @Test func theEarliestDueReminderWinsAndALineReminderShowsItsLine() throws {
        let f = try FocusFixtureLibrary(); defer { f.cleanup() }
        let anchor = try #require(LineAnchor.at(line: 2, in: f.oldTodo.text))
        _ = try f.store.setPing(noteId: f.plain.id, anchor: nil, fireAt: FocusFixtureLibrary.at(hours: -1), now: Self.now)
        let earlier = try f.store.setPing(noteId: f.oldTodo.id, anchor: anchor, fireAt: FocusFixtureLibrary.at(hours: -3), now: Self.now)

        let card = try reminder(try next(f))

        #expect(card.pingId == earlier.id)
        #expect(card.lineText == "Call Anna")
        #expect(card.caretOffset == "# Old todo\n".utf16.count)

        // Later hides that one reminder only; the other one is next. Not Today hides both.
        try f.card.later(.reminder(card), now: Self.now, calendar: Self.calendar)
        #expect(try reminder(try next(f)).title == "Plain")
        try f.card.notToday(now: Self.now, calendar: Self.calendar)
        #expect(try next(f) == nil)
    }

    // MARK: Anchors and hides

    @Test func laterSurvivesLinesInsertedAbove() throws {
        let f = try FocusFixtureLibrary(); defer { f.cleanup() }
        try f.card.later(try #require(try next(f)), now: Self.now, calendar: Self.calendar)

        let note = try #require(try f.store.note(id: f.oldTodo.id))
        _ = try f.store.updateText(
            id: note.id, text: "intro one\nintro two\nintro three\n" + note.text, expectedRevision: note.revision, now: Self.now)

        // The to-do moved from line 2 to line 5 and is still hidden.
        #expect(try next(f) == .capture(NoteCandidate(noteId: f.captured.id, title: "Captured")))

        // A different line is a different candidate: editing the hidden to-do brings it back.
        let moved = try #require(try f.store.note(id: f.oldTodo.id))
        _ = try f.store.updateText(
            id: moved.id, text: moved.text.replacingOccurrences(of: "Call Anna", with: "Call Anna today"),
            expectedRevision: moved.revision, now: Self.now)
        let back = try todo(try next(f))
        #expect(back.lineText == "Call Anna today")
        #expect(back.anchor.line == 5)
    }

    @Test func aHiddenTodoLetsTheNextTodoOfTheSameNoteShow() throws {
        let f = try FocusFixtureLibrary(); defer { f.cleanup() }
        let two = try f.store.create(text: "# Two\n- [ ] first\n- [ ] second", now: FocusFixtureLibrary.ago(days: 30))
        try f.store.trash([f.oldTodo.id])
        let first = try todo(try next(f))
        #expect(first.noteId == two.id && first.lineText == "first")

        try f.card.later(.todo(first), now: Self.now, calendar: Self.calendar)

        #expect(try todo(try next(f)).lineText == "second")
    }

    @Test func laterAndNotTodayWriteNoNoteAndOnlyFocusHideRows() throws {
        let f = try FocusFixtureLibrary(); defer { f.cleanup() }
        let before = try f.allNotes()
        let candidate = try #require(try next(f))
        try f.card.later(candidate, now: Self.now, calendar: Self.calendar)
        try f.card.later(candidate, now: Self.now, calendar: Self.calendar)
        try f.card.notToday(now: Self.now, calendar: Self.calendar)
        #expect(try f.allNotes() == before)
        // Hiding twice keeps one row per key, and a hide ends at the next local midnight.
        #expect(try f.hideCount() == 2)
        let until = try f.library.db.pool.read {
            try Date.fetchOne($0, sql: "SELECT hiddenUntil FROM focus_hide WHERE candidateKey = 'pool'")
        }
        #expect(until == FocusClock.nextLocalMidnight(after: Self.now, calendar: Self.calendar))
    }

    // MARK: Pool membership

    @Test func templatesFencesArchiveTrashAndLockedAreNotCandidates() throws {
        let f = try FocusFixtureLibrary(); defer { f.cleanup() }
        let store = f.store
        let old = FocusFixtureLibrary.ago(days: 9)
        // Remove the fixture's own candidates, keeping the locked Secret.
        try store.trash([f.oldTodo.id, f.captured.id])
        #expect(try next(f) == nil)

        _ = try store.create(text: "# Template\n#template\n- [ ] template todo", now: old)
        _ = try store.create(text: "# Fence\n```\n- [ ] inside a fence\n```\nand `- [ ] inline` words", now: old)
        let archivedTodo = try store.create(text: "# Archived\n- [ ] archived todo", now: old)
        let trashedTodo = try store.create(text: "# Trashed\n- [ ] trashed todo", now: old)
        let archivedCapture = try store.create(text: "# Archived capture", now: old, captureSource: .share)
        let trashedCapture = try store.create(text: "# Trashed capture", now: old, captureSource: .voice)
        let lockedCapture = try store.create(text: "# Locked capture\n- [ ] locked todo", now: old, captureSource: .mcp)
        let archivedPing = try store.create(text: "# Archived ping", now: old)
        try store.archive([archivedTodo.id, archivedCapture.id, archivedPing.id])
        try store.trash([trashedTodo.id, trashedCapture.id])
        try f.access.lock(noteId: lockedCapture.id)
        _ = try store.setPing(noteId: archivedPing.id, anchor: nil, fireAt: FocusFixtureLibrary.at(hours: -5), now: Self.now)
        _ = try store.setPing(noteId: trashedTodo.id, anchor: nil, fireAt: FocusFixtureLibrary.at(hours: -5), now: Self.now)

        #expect(try next(f) == nil)

        // A box inside a fence never counts, even in a note that also has a real one.
        let mixed = try store.create(text: "# Mixed\n```\n- [ ] inside a fence\n```\n- [ ] after the fence", now: old.addingTimeInterval(-60))
        let real = try todo(try next(f))
        #expect(real.noteId == mixed.id)
        #expect(real.lineText == "after the fence")
        #expect(real.anchor.line == 5)
        try store.trash([mixed.id])

        // The same shapes in Notes are candidates, so none of the above is vacuous.
        let live = try store.create(text: "# Live\n- [ ] live todo", now: old)
        #expect(try todo(try next(f)).noteId == live.id)
        try store.restore([archivedPing.id])
        #expect(try reminder(try next(f)).noteId == archivedPing.id)
    }

    @Test func readOnlyTodoOffersNoDone() throws {
        let f = try FocusFixtureLibrary(); defer { f.cleanup() }
        try f.store.setReadOnly(f.oldTodo.id, readOnly: true)
        let candidate = try todo(try next(f))
        #expect(candidate.noteId == f.oldTodo.id)
        #expect(candidate.isReadOnly)
        let before = try f.store.note(id: f.oldTodo.id)

        #expect(throws: FocusCardError.readOnly(noteId: f.oldTodo.id)) { try f.card.done(candidate, now: Self.now) }

        #expect(try f.store.note(id: f.oldTodo.id) == before)
    }

    @Test func doneRefusesATodoThatIsGone() throws {
        let f = try FocusFixtureLibrary(); defer { f.cleanup() }
        let candidate = try todo(try next(f))
        let note = try #require(try f.store.note(id: f.oldTodo.id))
        _ = try f.store.updateText(id: note.id, text: "# Old todo\nnothing here", expectedRevision: note.revision, now: Self.now)

        #expect(throws: FocusCardError.todoGone(noteId: note.id)) { try f.card.done(candidate, now: Self.now) }
        #expect(try f.store.note(id: note.id)?.text == "# Old todo\nnothing here")
    }

    @Test func neverOpenedNotesRankByModifiedAt() throws {
        let f = try FocusFixtureLibrary(); defer { f.cleanup() }
        try f.store.trash([f.oldTodo.id])
        let newer = try f.store.create(text: "# Newer\n- [ ] newer todo", now: FocusFixtureLibrary.ago(days: 3))
        let older = try f.store.create(text: "# Older\n- [ ] older todo", now: FocusFixtureLibrary.ago(days: 4))
        #expect(try todo(try next(f)).noteId == older.id)

        // A note opened before the other one was last modified ranks ahead of it ...
        try f.store.recordOpened(noteId: newer.id, now: FocusFixtureLibrary.ago(days: 8))
        #expect(try todo(try next(f)).noteId == newer.id)
        // ... and opening it again sends it to the back.
        try f.store.recordOpened(noteId: newer.id, now: FocusFixtureLibrary.ago(days: 1))
        #expect(try todo(try next(f)).noteId == older.id)
    }

    @Test func openingTheCaptureMovesItOutOfThePool() throws {
        let f = try FocusFixtureLibrary(); defer { f.cleanup() }
        try f.card.later(try #require(try next(f)), now: Self.now, calendar: Self.calendar)
        let candidate = try #require(try next(f))
        #expect(candidate == .capture(NoteCandidate(noteId: f.captured.id, title: "Captured")))
        let before = try f.allNotes()

        try f.card.opened(candidate, now: Self.now)

        #expect(try next(f) == nil)
        #expect(try f.store.lastOpenedAt(noteId: f.captured.id) == Self.now)
        #expect(try f.allNotes() == before)
    }

    @Test func theOldestUnopenedCaptureShowsFirst() throws {
        let f = try FocusFixtureLibrary(); defer { f.cleanup() }
        try f.store.trash([f.oldTodo.id])
        let older = try f.store.create(text: "# Older capture", now: FocusFixtureLibrary.ago(days: 6), captureSource: .voice)
        let olderCandidate = FocusCandidate.capture(NoteCandidate(noteId: older.id, title: "Older capture"))
        #expect(try next(f) == olderCandidate)
        try f.card.later(olderCandidate, now: Self.now, calendar: Self.calendar)
        #expect(try next(f) == .capture(NoteCandidate(noteId: f.captured.id, title: "Captured")))
    }

    // MARK: Locked notes

    @Test func lockedNoteNeverSuppliesBodyText() throws {
        let f = try FocusFixtureLibrary(secretReminderAt: FocusFixtureLibrary.at(hours: -2)); defer { f.cleanup() }
        // Only locked material is left: the Secret capture (never opened, older than Captured),
        // its reminder, and no to-do anywhere.
        try f.store.trash([f.oldTodo.id, f.captured.id])

        let candidate = try reminder(try next(f))

        #expect(candidate.noteId == f.secret.id)
        #expect(candidate.isLocked)
        #expect(candidate.title == "Secret")
        #expect(candidate.lineText == nil)
        #expect(candidate.caretOffset == nil)
        #expect(!String(describing: candidate).contains("move the money"))

        // Handled, the locked capture and its to-do are still not offered.
        try f.card.opened(.reminder(candidate), now: Self.now)
        #expect(try next(f) == nil)
        #expect(try f.store.lastOpenedAt(noteId: f.secret.id) == nil)
    }
}
