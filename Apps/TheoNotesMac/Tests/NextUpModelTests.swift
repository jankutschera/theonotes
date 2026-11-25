// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import GRDB
import Testing
@testable import TheoNotes

/// Focus layer C15: the Next Up card of a main window and its two-minute timer (spec A3, FOC-R280 …
/// FOC-R289). The notification center is the fake of `MacNotificationSchedulerTests`: no test posts
/// a real notification.
@MainActor
@Suite struct NextUpModelTests {
    @MainActor
    final class Fixture {
        let env: ReminderEnv
        let ticks = ManualScheduler()
        let model: NextUpModel
        var appIsActive = false
        var opened: [(noteId: String, caret: Int?)] = []
        var openSucceeds = true
        /// Whether this fixture's window is the key window (the panel may open itself in it).
        var windowIsKey = true

        init(env: ReminderEnv? = nil) throws {
            let env = try env ?? ReminderEnv()
            self.env = env
            let clock = env.clock
            model = NextUpModel(environment: env.environment, scheduler: env.reminders, clock: ticks, now: { clock.now })
            model.isAppActive = { [unowned self] in appIsActive }
            model.canPresentOnTimerEnd = { [unowned self] in windowIsKey }
            model.openNote = { [unowned self] noteId, caret in
                opened.append((noteId, caret))
                return openSucceeds
            }
        }

        var store: NoteStore { env.store }

        func text(_ id: String) throws -> String { try #require(try store.note(id: id)).text }

        /// A due reminder on `noteId`, whole note.
        @discardableResult
        func dueReminder(on noteId: String, anchor: LineAnchor? = nil) throws -> Ping {
            try store.setPing(noteId: noteId, anchor: anchor, fireAt: env.clock.now.addingTimeInterval(-60), now: env.clock.now)
        }
    }

    private func undoManager() -> UndoManager {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }

    /// Every table but the notification ledger, as sorted row descriptions.
    private func libraryDigest(_ env: ReminderEnv) throws -> [String] {
        try env.environment.database.pool.read { db in
            let tables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                  AND name != 'notification_ledger' ORDER BY name
                """)
            return tables.flatMap { table in
                ((try? Row.fetchAll(db, sql: "SELECT * FROM \"\(table)\"")) ?? []).map { "\(table): \($0)" }.sorted()
            }
        }
    }

    // MARK: The card

    @Test func showsTheTodoThenTheCaptureThenEmpty() throws {
        let f = try Fixture()
        f.model.refresh()
        #expect(f.model.candidate == nil)

        let capture = try f.store.create(text: "Idea for later", captureSource: .shortcut)
        let todo = try f.store.create(text: "Groceries\n- [ ] milk")
        f.model.refresh()
        guard case .todo(let shown)? = f.model.candidate else {
            Issue.record("expected the to-do first, got \(String(describing: f.model.candidate))")
            return
        }
        #expect(shown.noteId == todo.id && shown.lineText == "milk")

        f.model.later()
        guard case .capture(let next)? = f.model.candidate else {
            Issue.record("expected the capture second, got \(String(describing: f.model.candidate))")
            return
        }
        #expect(next.noteId == capture.id)

        f.model.later()
        #expect(f.model.candidate == nil)
    }

    @Test func laterAndNotTodayNeverWriteTheNote() throws {
        let f = try Fixture()
        let note = try f.store.create(text: "Groceries\n- [ ] milk\n- [ ] eggs")
        let before = try #require(try f.store.note(id: note.id))
        f.model.refresh()
        f.model.later()
        #expect(f.model.candidate != nil, "the second to-do follows")
        f.model.notToday()
        #expect(f.model.candidate == nil)
        let after = try #require(try f.store.note(id: note.id))
        #expect(after.text == before.text && after.revision == before.revision && after.modifiedAt == before.modifiedAt)
    }

    // MARK: Done

    @Test func doneIsOneUndoStep() throws {
        let f = try Fixture()
        let original = "Groceries\n- [ ] milk\n- [x] eggs"
        let note = try f.store.create(text: original)
        let session = try f.env.environment.session(for: note.id)
        _ = session.addTextListener { _, _ in }
        let undo = undoManager()
        f.model.undoManager = undo
        f.model.refresh()
        #expect(f.model.canDone)

        #expect(f.model.done())
        let done = "Groceries\n- [x] milk\n- [x] eggs"
        #expect(try f.text(note.id) == done)
        #expect(session.text == done, "the open note takes the change at once")
        #expect(undo.undoActionName == "Done")
        #expect(f.model.candidate == nil, "nothing open is left")

        undo.undo()
        #expect(try f.text(note.id) == original)
        #expect(session.text == original)
        #expect(!undo.canUndo, "one step, not two")
        #expect(undo.canRedo)

        undo.redo()
        #expect(try f.text(note.id) == done)
        #expect(undo.canUndo)
    }

    @Test func doneIsUnavailableForReadOnlyAndForReminders() throws {
        let f = try Fixture()
        let locked = try f.store.create(text: "Frozen\n- [ ] untouchable")
        try f.store.setReadOnly(locked.id, readOnly: true)
        let before = try #require(try f.store.note(id: locked.id))
        f.model.refresh()
        guard case .todo(let shown)? = f.model.candidate else {
            Issue.record("expected the read-only to-do")
            return
        }
        #expect(shown.isReadOnly && !f.model.canDone)
        #expect(!f.model.done())
        let after = try #require(try f.store.note(id: locked.id))
        #expect(after.text == before.text && after.revision == before.revision)

        // A due reminder comes first, and it never offers Done, even on a note with an open to-do.
        let plain = try f.store.create(text: "Errands\n- [ ] post")
        let ping = try f.dueReminder(on: plain.id, anchor: LineAnchor.at(line: 2, in: "Errands\n- [ ] post"))
        f.model.refresh()
        guard case .reminder(let reminder)? = f.model.candidate else {
            Issue.record("expected the reminder")
            return
        }
        #expect(reminder.pingId == ping.id && !f.model.canDone)
        #expect(!f.model.done())
        #expect(try f.text(plain.id) == "Errands\n- [ ] post")
    }

    @Test func doneRefusesTextThatIsNotSavedYet() throws {
        let f = try Fixture()
        let note = try f.store.create(text: "Groceries\n- [ ] milk")
        let session = try f.env.environment.session(for: note.id)
        _ = session.addTextListener { _, _ in }
        f.model.refresh()
        #expect(f.model.canDone)
        // An edit the editor acknowledged, and a library that cannot take it: the text is unsaved.
        let change = ChangeSet(sections: [.retain(20), .replace(deleteLength: 0, insert: "!")])
        let expected = session.revision + 1
        #expect(session.apply(txId: UUID().uuidString, baseRevision: session.revision, changeSet: change, origin: nil)
            == .acked(revision: expected))
        try f.env.environment.database.pool.close()
        #expect(f.env.environment.unsavedNoteIds.contains(note.id))

        #expect(!f.model.done())
        #expect(f.model.notice == NextUpModel.unsavedNotice, "refused because of the unsaved text, not because the write failed")
        #expect(session.text == "Groceries\n- [ ] milk!", "the open text is untouched")
    }

    // MARK: Open

    @Test func openScrollsToTheCheckbox() throws {
        let f = try Fixture()
        let text = "Plan\nintro\n\n- [ ] call Sam"
        let note = try f.store.create(text: text)
        f.model.refresh()
        f.model.isPresented = true

        #expect(f.model.open())
        #expect(f.opened.count == 1)
        #expect(f.opened.first?.noteId == note.id)
        #expect(f.opened.first?.caret == ("Plan\nintro\n\n" as NSString).length, "the caret sits at the start of the to-do line")
        #expect(!f.model.isPresented)
        #expect(try f.store.lastOpenedAt(noteId: note.id) != nil, "an open of a note already shown counts too")
    }

    @Test func openingAReminderDeletesIt() throws {
        let f = try Fixture()
        let text = "Taxes\nsend the form"
        let note = try f.store.create(text: text)
        let ping = try f.dueReminder(on: note.id, anchor: LineAnchor.at(line: 2, in: text))
        f.model.refresh()

        #expect(f.model.open())
        #expect(f.opened.first?.noteId == note.id)
        #expect(f.opened.first?.caret == ("Taxes\n" as NSString).length)
        #expect(try f.store.ping(id: ping.id) == nil)
    }

    @Test func aNoteThatCannotBeShownKeepsItsReminder() throws {
        let f = try Fixture()
        let note = try f.store.create(text: "Taxes")
        let ping = try f.dueReminder(on: note.id)
        f.openSucceeds = false
        f.model.refresh()

        #expect(!f.model.open())
        #expect(try f.store.ping(id: ping.id) != nil)
        #expect(try f.store.lastOpenedAt(noteId: note.id) == nil)
        #expect(f.model.candidate != nil)
    }

    // MARK: A note locked while its card is up

    @Test func aTodoLockedElsewhereLeavesTheCardAtOnce() async throws {
        let f = try Fixture()
        let note = try f.store.create(text: "Groceries\n- [ ] secret milk")
        f.model.refresh()
        guard case .todo(let shown)? = f.model.candidate else {
            Issue.record("expected the to-do")
            return
        }
        #expect(shown.lineText == "secret milk")

        try await f.env.lockNote(note.id)  // another window, or sync, locks it
        await f.env.waitUntil { f.model.candidate == nil }
        #expect(f.model.candidate == nil, "a locked note supplies no text to the card")
    }

    @Test func aLineReminderLockedElsewhereShowsOnlyTheTitle() async throws {
        let f = try Fixture()
        let text = "Taxes\nsecret line"
        let note = try f.store.create(text: text)
        try f.dueReminder(on: note.id, anchor: LineAnchor.at(line: 2, in: text))
        f.model.refresh()
        guard case .reminder(let shown)? = f.model.candidate else {
            Issue.record("expected the reminder")
            return
        }
        #expect(shown.lineText == "secret line")

        try await f.env.lockNote(note.id)
        await f.env.waitUntil {
            if case .reminder(let r)? = f.model.candidate { return r.lineText == nil } else { return true }
        }
        if case .reminder(let r)? = f.model.candidate {
            #expect(r.lineText == nil && r.caretOffset == nil && r.isLocked, "title only")
        }
    }

    // MARK: Timer

    @Test func timerSchedulesOneNotificationAndDismissRemovesIt() async throws {
        let f = try Fixture()
        let start = f.env.clock.now
        await f.model.startTimer()

        #expect(f.model.timerState == .running(endsAt: start.addingTimeInterval(120)))
        #expect(f.model.timerRemaining == 120)
        let request = try #require(f.env.center.pendingRequests.first)
        #expect(f.env.center.pendingRequests.count == 1)
        #expect(request.identifier.hasPrefix("timer:"))
        #expect(request.title == "Time's up" && request.body == nil)
        #expect(request.fireAt == start.addingTimeInterval(120))
        #expect(try f.env.ledger.entries().map(\.identifier) == [request.identifier])

        await f.model.startTimer()
        #expect(f.env.center.pendingRequests.count == 1, "a running timer is not started twice")

        f.model.dismissTimer()
        #expect(f.model.timerState == .idle && f.model.timerRemaining == nil)
        #expect(f.env.center.pending.isEmpty)
        #expect(f.env.center.removedPendingNow.contains(request.identifier))
        #expect(try f.env.ledger.entries().isEmpty)
        f.ticks.advance(by: .seconds(300))
        #expect(f.model.timerState == .idle, "a dismissed timer never ends")
    }

    @Test func timerWritesNothingToTheLibrary() async throws {
        let f = try Fixture()
        let note = try f.store.create(text: "Groceries\n- [ ] milk")
        try f.dueReminder(on: note.id)
        f.model.refresh()
        let before = try libraryDigest(f.env)

        await f.model.startTimer()
        #expect(try f.env.ledger.entries().allSatisfy { $0.identifier.hasPrefix("timer:") && $0.kind == .timer })
        f.ticks.advance(by: .seconds(120))
        #expect(f.model.timerState == .finished)
        f.model.dismissTimer()

        #expect(try libraryDigest(f.env) == before)
        #expect(try f.env.ledger.entries().isEmpty)
    }

    @Test func timerEndingWhileTheAppIsActiveShowsInThePanelNotAsABanner() async throws {
        let f = try Fixture()
        f.appIsActive = true
        await f.model.startTimer()
        let id = try #require(f.env.center.pending.keys.first)
        #expect(f.env.reminders.willPresent(requestIdentifier: id) == false, "the panel shows this timer's end, not the system")

        f.ticks.advance(by: .seconds(119))
        #expect(f.model.timerState != .finished && !f.model.isPresented)
        f.ticks.advance(by: .seconds(1))

        #expect(f.model.timerState == .finished)
        #expect(f.model.isPresented, "the panel opens on the end")
        #expect(f.env.center.pending[id] == nil, "no notification is left to banner")
        #expect(f.env.center.delivered.isEmpty)
        #expect(try f.env.ledger.entries().isEmpty)
    }

    /// K5 P-N8 (FOC-R392): the toolbar symbol never changes under an open popover.
    @Test func theToolbarSymbolWaitsForThePopoverToClose() async throws {
        let f = try Fixture()
        f.appIsActive = true
        f.model.present()
        await f.model.startTimer()
        #expect(f.model.timerState != .idle)
        #expect(f.model.toolbarTimerState == .idle, "the popover is up: the button keeps its symbol")

        f.ticks.advance(by: .seconds(120))
        #expect(f.model.timerState == .finished && f.model.isPresented)
        #expect(f.model.toolbarTimerState == .idle)

        f.model.isPresented = false
        #expect(f.model.toolbarTimerState == .finished, "closed: the button shows the bell")

        f.model.dismissTimer()
        #expect(f.model.toolbarTimerState == .idle)
    }

    @Test func theToolbarSymbolFollowsTheTimerAtOnceWhileThePopoverIsClosed() async throws {
        let f = try Fixture()
        f.appIsActive = false
        await f.model.startTimer()
        guard case .running = f.model.toolbarTimerState else {
            Issue.record("expected the running symbol, got \(f.model.toolbarTimerState)")
            return
        }
        f.ticks.advance(by: .seconds(120))
        #expect(f.model.toolbarTimerState == .finished)
    }

    @Test func timerEndingInTheBackgroundLeavesTheNotificationToTheSystem() async throws {
        let f = try Fixture()
        f.appIsActive = false
        await f.model.startTimer()
        let id = try #require(f.env.center.pending.keys.first)

        f.ticks.advance(by: .seconds(120))
        #expect(f.model.timerState == .finished)
        #expect(f.env.center.pending[id] != nil, "the system rings it")
        #expect(!f.model.isPresented)

        f.env.center.deliver(id)
        f.model.dismissTimer()
        #expect(f.env.center.delivered.isEmpty, "dismissing clears the banner too")
        #expect(f.model.timerState == .idle)
    }

    @Test func timerEndingInAWindowThatCannotShowItKeepsTheNotification() async throws {
        // Two windows of one app: the user works in A, the timer was started in B.
        let a = try Fixture()
        let b = try Fixture(env: a.env)
        a.appIsActive = true
        b.appIsActive = true
        a.windowIsKey = true
        b.windowIsKey = false
        await b.model.startTimer()
        let id = try #require(b.env.center.pending.keys.first)
        #expect(b.env.reminders.willPresent(requestIdentifier: id), "no eligible panel yet: the system may show it")

        b.ticks.advance(by: .seconds(120))
        #expect(b.model.timerState == .finished)
        #expect(!b.model.isPresented, "its window is not the key window")
        #expect(b.env.center.pending[id] != nil, "the notification is the only signal left")
        #expect(b.env.reminders.willPresent(requestIdentifier: id), "and it banners in front")
    }

    @Test func timerWithoutPermissionStillCounts() async throws {
        let f = try Fixture()
        f.env.center.authorized = false
        await f.model.startTimer()
        #expect(f.model.timerRemaining == 120)
        #expect(f.env.center.pending.isEmpty)
        #expect(try f.env.ledger.entries().isEmpty)
        f.ticks.advance(by: .seconds(120))
        #expect(f.model.timerState == .finished)
    }

    // MARK: Empty card and App Lock

    @Test func emptyCardOffersVoiceCapture() throws {
        let f = try Fixture()
        var asked = 0
        f.model.refresh()
        #expect(f.model.candidate == nil)
        #expect(!f.model.offersVoiceCapture, "no voice capture is wired yet")

        f.model.startVoiceCapture = { asked += 1 }
        #expect(f.model.offersVoiceCapture)
        f.model.isPresented = true
        f.model.captureVoice()
        #expect(asked == 1)
        #expect(!f.model.isPresented)

        _ = try f.store.create(text: "Groceries\n- [ ] milk")
        f.model.refresh()
        #expect(!f.model.offersVoiceCapture, "only an empty card offers it")
    }

    @Test func appLockedShowsNothing() async throws {
        let first = try ReminderEnv()
        let note = try first.store.create(text: "Groceries\n- [ ] milk")
        try first.store.setPing(noteId: note.id, anchor: nil, fireAt: first.clock.now.addingTimeInterval(-60), now: first.clock.now)

        // Launched with App Lock on: engaged from the start.
        let launched = try Fixture(env: try first.relaunch(appLockEnabled: true))
        #expect(launched.env.environment.appLock.isLocked)
        launched.model.refresh()
        #expect(launched.model.candidate == nil)
        #expect(launched.model.isLocked && !launched.model.canDone && !launched.model.offersVoiceCapture)
        launched.model.present()
        #expect(!launched.model.isPresented)
        #expect(!launched.model.open() && launched.opened.isEmpty)

        // Engaged while the card is up: it goes away at once.
        let open = try Fixture(env: try launched.env.relaunch(appLockEnabled: false))
        open.model.refresh()
        open.model.present()
        #expect(open.model.candidate != nil && open.model.isPresented)
        open.env.authenticator.script(.success)
        #expect(await open.env.environment.appLock.setEnabled(true) == .enabled)
        open.env.environment.appLock.lock()
        #expect(open.env.environment.appLock.isLocked)
        #expect(open.model.candidate == nil)
        #expect(!open.model.isPresented)
        open.model.refresh()
        #expect(open.model.candidate == nil)
    }

    @Test func theMenuItemIsOffWithoutAnAppAndWhileLocked() throws {
        #expect(NextUpMenu.title == "Next Up")
        #expect(NextUpMenu.isDisabled(app: nil, hasMainWindow: true))
        let env = try ReminderEnv()
        let defaults = UserDefaults(suiteName: "TheoNotesNextUp-\(UUID().uuidString)")!
        let app = AppModel(environment: env.environment, defaults: defaults)
        #expect(!NextUpMenu.isDisabled(app: app, hasMainWindow: true))
        #expect(NextUpMenu.isDisabled(app: app, hasMainWindow: false))
        let locked = try env.relaunch(appLockEnabled: true)
        let lockedApp = AppModel(environment: locked.environment, defaults: defaults)
        #expect(NextUpMenu.isDisabled(app: lockedApp, hasMainWindow: true))
    }
}
