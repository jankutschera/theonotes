// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// Spec section 9, one test per bullet (C18). Each test restates the user-visible promise on its own,
/// through the public surface of the layer, so it keeps guarding the promise if a unit test next to
/// the code is rewritten. The fixture is `FocusFixtureLibrary` or a temporary library; no production
/// library is touched.
@Suite struct FocusAcceptanceTests {
    static let now = FocusFixtureLibrary.now
    static let calendar = FocusFixtureLibrary.utc

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private func next(_ f: FocusFixtureLibrary, at date: Date = FocusAcceptanceTests.now) throws -> FocusCandidate? {
        try f.card.next(now: date, calendar: Self.calendar)
    }

    private func todo(_ candidate: FocusCandidate?) throws -> TodoCandidate {
        guard case .todo(let todo)? = candidate else { throw Failure("expected a to-do, got \(String(describing: candidate))") }
        return todo
    }

    private func reminder(_ candidate: FocusCandidate?) throws -> ReminderCandidate {
        guard case .reminder(let reminder)? = candidate else { throw Failure("expected a reminder, got \(String(describing: candidate))") }
        return reminder
    }

    private func utf8Texts(_ notes: [Note]) -> [String: [UInt8]] {
        Dictionary(uniqueKeysWithValues: notes.map { ($0.id, Array($0.text.utf8)) })
    }

    // MARK: Bullet 1: Share, Save

    @Test func shareSaveCreatesTheNoteFromThePayload() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let inboxDir = library.paths.root.appendingPathComponent("group/CaptureInbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        let inbox = CaptureInbox(directory: inboxDir)
        let attachments = AttachmentStore(paths: library.paths, database: library.db)
        let bystander = try library.store.create(text: "# Bystander\nleave me", now: Self.now)

        // The extension's Save with nothing typed: the request carries the shared words and nothing else.
        let payload = "Oat milk, tea\u{2014}and a stamp\nsecond line  "
        let request = CaptureRequest(itemId: UUIDv7.make(), mode: .save, text: payload)
        try inbox.enqueue(request, files: [])
        let done = try inbox.drain(into: library.store, attachments: attachments, now: Self.now)

        #expect(done == [request.itemId])
        let note = try #require(try library.store.note(id: request.itemId))
        #expect(Array(note.text.utf8) == Array(payload.utf8))
        #expect(note.title == "Oat milk, tea\u{2014}and a stamp")
        #expect(note.location == .notes)
        #expect(try library.store.captureSource(noteId: note.id) == .share)
        // Exactly one new note, and the other note is untouched.
        let all = try library.db.pool.read { try Note.fetchAll($0) }
        #expect(all.count == 2)
        #expect(try library.store.note(id: bystander.id) == bystander)
        // The item is consumed: a second drain finds nothing and adds nothing.
        #expect(try inbox.drain(into: library.store, attachments: attachments, now: Self.now) == [])
        #expect(try library.db.pool.read { try Note.fetchCount($0) } == 2)
    }

    // MARK: Bullet 3: card order, Later, Not Today

    @Test func cardOrderLaterAndNotTodayLeaveTextsIdentical() throws {
        let f = try FocusFixtureLibrary(); defer { f.cleanup() }
        let before = try f.allNotes()
        let textsBefore = utf8Texts(before)

        // The open to-do comes before the capture nobody opened; the locked note never shows.
        let first = try todo(try next(f))
        #expect(first.noteId == f.oldTodo.id)
        #expect(first.lineText == "Call Anna")

        // Later, then the capture.
        try f.card.later(.todo(first), now: Self.now, calendar: Self.calendar)
        #expect(try next(f) == .capture(NoteCandidate(noteId: f.captured.id, title: "Captured")))

        // Not Today, then nothing until the next local midnight; then the to-do returns.
        try f.card.notToday(now: Self.now, calendar: Self.calendar)
        #expect(try next(f) == nil)
        let midnight = FocusClock.nextLocalMidnight(after: Self.now, calendar: Self.calendar)
        #expect(try next(f, at: midnight.addingTimeInterval(-1)) == nil)
        #expect(try todo(try next(f, at: midnight)).noteId == f.oldTodo.id)

        // Not one byte of any note changed: texts, revisions and times (the notes are never written).
        let after = try f.allNotes()
        #expect(after == before)
        #expect(utf8Texts(after) == textsBefore)
    }

    // MARK: Bullet 4: Done and one undo

    @Test func doneTogglesOneCheckboxAndOneUndoRestoresIt() throws {
        let f = try FocusFixtureLibrary(); defer { f.cleanup() }
        let original = "# Chores\n- [ ] Call Anna\n- [ ] Call Bob\n- [x] Pay rent"
        let chores = try f.store.create(text: original, now: Self.now)
        try f.store.trash([f.oldTodo.id])
        let candidate = try todo(try next(f))
        #expect(candidate.noteId == chores.id && candidate.lineText == "Call Anna")

        let toggle = try f.card.done(candidate, now: Self.now.addingTimeInterval(60))

        let done = try #require(try f.store.note(id: chores.id))
        #expect(done.text == "# Chores\n- [x] Call Anna\n- [ ] Call Bob\n- [x] Pay rent")
        // One checkbox changed, and only that one: one character differs.
        let differing = zip(original.utf16, done.text.utf16).filter { $0 != $1 }.count
        #expect(differing == 1 && original.utf16.count == done.text.utf16.count)
        #expect(done.text.components(separatedBy: "[x]").count - 1 == 2)

        // One undo puts the exact text back; a second does nothing.
        #expect(try f.card.undo(toggle, now: Self.now.addingTimeInterval(120)))
        let restored = try #require(try f.store.note(id: chores.id))
        #expect(Array(restored.text.utf8) == Array(original.utf8))
        #expect(try f.card.undo(toggle, now: Self.now.addingTimeInterval(180)) == false)
        #expect(try f.store.note(id: chores.id)?.text == original)
    }

    // MARK: Bullet 5: reminders

    @Test func dueReminderOutranksTodoAndIsGoneAfterHandling() throws {
        let f = try FocusFixtureLibrary(); defer { f.cleanup() }
        let dueAt = Self.now.addingTimeInterval(60)
        let ping = try f.store.setPing(noteId: f.plain.id, anchor: nil, fireAt: dueAt, now: Self.now)

        // Before it is due: planned as a notification, and the card still offers the to-do.
        #expect(try PingPlanner.plan(store: f.store, appLockEnabled: false, now: Self.now).map(\.pingId) == [ping.id])
        #expect(try todo(try next(f)).noteId == f.oldTodo.id)

        // It fires: no longer planned, and now it comes before the to-do.
        #expect(try f.store.markPingsFired(dueBy: dueAt) == [ping.id])
        #expect(try PingPlanner.plan(store: f.store, appLockEnabled: false, now: dueAt).isEmpty)
        // Not even a clock set back plans it again: a fired reminder rings once.
        #expect(try PingPlanner.plan(store: f.store, appLockEnabled: false, now: Self.now).isEmpty)
        let card = try reminder(try next(f, at: dueAt))
        #expect(card.pingId == ping.id && card.noteId == f.plain.id)

        // Handled (opened from the notification or the card): the row is gone and the to-do is next.
        try f.card.opened(.reminder(card), now: dueAt)
        #expect(try f.store.ping(id: ping.id) == nil)
        #expect(try f.store.pings().isEmpty)
        #expect(try todo(try next(f, at: dueAt)).noteId == f.oldTodo.id)
    }

    @Test func snoozeLeavesExactlyOneRow() throws {
        let f = try FocusFixtureLibrary(); defer { f.cleanup() }
        let anchor = try #require(LineAnchor.at(line: 2, in: f.oldTodo.text))
        let ping = try f.store.setPing(noteId: f.oldTodo.id, anchor: anchor, fireAt: Self.now, now: Self.now)
        _ = try f.store.markPingsFired(dueBy: Self.now)

        let snoozed = try f.store.snoozePing(id: ping.id, until: PingTime.inOneHour(now: Self.now), now: Self.now)

        let rows = try f.store.pings()
        #expect(rows.count == 1 && rows.first?.id == snoozed.id)
        #expect(snoozed.id != ping.id)
        #expect(try f.store.ping(id: ping.id) == nil)
        #expect(snoozed.noteId == f.oldTodo.id && snoozed.anchor == anchor)
        #expect(snoozed.fireAt == NoteStore.roundedToMillis(Self.now.addingTimeInterval(3600)) && snoozed.firedAt == nil)
        // One notification is planned for it, and none for the old id.
        let plan = try PingPlanner.plan(store: f.store, appLockEnabled: false, now: Self.now)
        #expect(plan.map(\.pingId) == [snoozed.id])

        // Snoozing again still leaves one.
        let again = try f.store.snoozePing(id: snoozed.id, until: PingTime.inOneHour(now: Self.now).addingTimeInterval(3600), now: Self.now)
        #expect(try f.store.pings().map(\.id) == [again.id])
    }

    // MARK: Bullet 6: locked notes

    @Test func lockedNoteSuppliesNoBodyToCardPublicationOrPlan() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let access = try library.access()
        let store = library.store
        let ledger = NotificationLedger(store: store)
        let canary = "move the money"
        let secret = try store.create(text: "# Secret\n- [ ] \(canary)", now: Self.now.addingTimeInterval(-86_400))
        let fireAt = Self.now.addingTimeInterval(3600)
        let anchor = try #require(LineAnchor.at(line: 2, in: secret.text))
        let ping = try store.setPing(noteId: secret.id, anchor: anchor, fireAt: fireAt, now: Self.now)
        let second = try store.setPing(noteId: secret.id, anchor: nil, fireAt: fireAt.addingTimeInterval(3600), now: Self.now)
        // The to-do was put off with Later before the note was locked.
        let card = FocusCard(store: store)
        try card.later(try #require(try card.next(now: Self.now, calendar: Self.calendar)), now: Self.now, calendar: Self.calendar)
        func hides() throws -> Int {
            try library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM focus_hide WHERE noteId = ?", arguments: [secret.id]) ?? -1 }
        }
        #expect(try hides() == 1)

        // While the note is open, the notification carries the line (so this test can see a leak).
        let openPlan = try PingPlanner.plan(store: store, appLockEnabled: false, now: Self.now)
        #expect(openPlan.first?.body == canary)
        let scheduled = try ledger.reconcile(planned: openPlan, now: Self.now)
        let deliveredId = try #require(scheduled.add.first).identifier

        try access.lock(noteId: secret.id)

        // Locking keeps one reminder, title only (the earliest), forgets what the notification said,
        // and drops the hide.
        let kept = try store.pings().filter { $0.noteId == secret.id }
        #expect(kept.map(\.id) == [ping.id] && kept.first?.anchor == nil)
        #expect(try store.ping(id: second.id) == nil)
        #expect(try ledger.entries().filter { $0.noteId == secret.id }.allSatisfy { $0.contentHash == nil })
        #expect(try hides() == 0)

        // The notification already on the device is scrubbed, by id, without reading it.
        #expect(try ledger.coldLaunchRemovals(appLockEnabled: false).contains(deliveredId))

        // The plan is the title alone: no line, no body, no line number.
        let plan = try PingPlanner.plan(store: store, appLockEnabled: false, now: Self.now)
        let planned = try #require(plan.first)
        #expect(plan.count == 1 && planned.pingId == ping.id)
        #expect(planned.title == "Secret" && planned.body == nil && planned.line == nil)
        let rebuilt = try ledger.reconcile(planned: plan, now: Self.now)
        #expect(rebuilt.remove.contains(deliveredId))
        #expect(rebuilt.add.allSatisfy { $0.notification.body == nil })

        // The card: a due reminder of a locked note shows the title and flags it, with no line or caret.
        let due = fireAt.addingTimeInterval(1)
        let candidate = try reminder(try card.next(now: due, calendar: Self.calendar))
        #expect(candidate.isLocked && candidate.lineText == nil && candidate.caretOffset == nil && candidate.title == "Secret")

        // The to-do of a locked note is never a candidate.
        #expect(try card.candidate(at: Self.now) == nil)

        // The widget publication: the entries carry no body, the bytes contain no word of the line.
        let publication = try CardPublication.make(card: card, appLockEnabled: false, now: due, calendar: Self.calendar)
        for entry in publication.entries {
            #expect(entry.line == nil)
            #expect(entry.state != .candidate || entry.noteId != secret.id)
        }
        let json = String(decoding: try publication.encoded(), as: UTF8.self)
        #expect(!json.contains(canary) && !json.contains("money"))
        let everything = plan.map { "\($0.title)|\($0.body ?? "")" }.joined() + json
            + (try ledger.entries().map { "\($0.identifier)|\($0.contentHash ?? "")" }.joined())
        #expect(!everything.contains(canary))
    }

    @Test func appLockEnabledNamesNoNoteInPlanOrPublication() throws {
        let f = try FocusFixtureLibrary(); defer { f.cleanup() }
        let anchor = try #require(LineAnchor.at(line: 2, in: f.oldTodo.text))
        _ = try f.store.setPing(noteId: f.oldTodo.id, anchor: anchor, fireAt: FocusFixtureLibrary.at(hours: 2), now: Self.now)

        let plan = try PingPlanner.plan(store: f.store, appLockEnabled: true, now: Self.now)
        let publication = try CardPublication.make(card: f.card, appLockEnabled: true, now: Self.now, calendar: Self.calendar)

        #expect(plan.map(\.title) == ["Theo Notes"] && plan.map(\.body) == ["Reminder"] && plan.map(\.line) == [nil])
        #expect(publication.entries.map(\.state) == [.locked])
        let json = String(decoding: try publication.encoded(), as: UTF8.self)
        for word in ["Old todo", "Call Anna", "Captured", "Plain", f.oldTodo.id] {
            #expect(!json.contains(word) && !plan.contains { $0.title.contains(word) || ($0.body ?? "").contains(word) }, Comment(rawValue: word))
        }
    }

    // MARK: Bullet 8: Restore as Copy

    @Test func restoreAsCopyLeavesTheSourceUnchanged() throws {
        let f = try FocusFixtureLibrary(); defer { f.cleanup() }
        let source = try f.store.create(text: "# Draft\nfirst version", now: Self.now)
        let snapshot = try #require(try f.store.takeSnapshot(noteId: source.id, text: source.text, now: Self.now))
        let edited = try f.store.updateText(
            id: source.id, text: "# Draft\nsecond version", expectedRevision: source.revision, now: Self.now.addingTimeInterval(60))
        let snapshotsBefore = try f.store.snapshots(noteId: source.id)
        let notesBefore = try f.library.db.pool.read { try Note.fetchCount($0) }

        let copy = try f.store.restoreSnapshotAsCopy(id: snapshot.id, now: Self.now.addingTimeInterval(120))

        // A second note holds the old words; the source is the same row it was.
        #expect(copy.id != source.id && copy.text == "# Draft\nfirst version" && copy.location == .notes)
        #expect(try f.library.db.pool.read { try Note.fetchCount($0) } == notesBefore + 1)
        #expect(try f.store.note(id: source.id) == edited)
        #expect(edited.text == "# Draft\nsecond version")
        // The source keeps its history untouched, and the copy starts without a captured mark.
        #expect(try f.store.snapshots(noteId: source.id) == snapshotsBefore)
        #expect(try f.store.captureSource(noteId: copy.id) == nil)
    }

    // MARK: Bullet 9: export (Markdown, TextBundle, plain text; HTML and PDF are in FocusExportMacTests)

    @Test func exportCarriesNoFocusState() throws {
        let f = try FocusFixtureLibrary(); defer { f.cleanup() }
        let note = try f.store.create(text: "# Export me\n- [ ] ship it\nplain words", now: Self.now, captureSource: .voice)
        let anchor = try #require(LineAnchor.at(line: 2, in: note.text))
        let ping = try f.store.setPing(noteId: note.id, anchor: anchor, fireAt: FocusFixtureLibrary.at(hours: 5), now: Self.now)
        try f.store.recordOpened(noteId: note.id, now: Self.now)
        try f.card.later(.todo(TodoCandidate(noteId: note.id, title: "Export me", anchor: anchor, lineText: "ship it", caretOffset: 11, isReadOnly: false)),
                         now: Self.now, calendar: Self.calendar)
        let snapshotCanary = "history-canary-7c1f"
        _ = try f.store.takeSnapshot(noteId: note.id, text: "# Export me\n\(snapshotCanary)", now: Self.now)
        #expect(try f.hideCount() >= 1)

        let destination = f.library.paths.root.appendingPathComponent("export", isDirectory: true)
        let plan = ExportPlan.selection(try f.store.exportCandidates(ids: [note.id]))
        let exporter = NoteExporter(store: f.store, paths: f.library.paths)
        for format in FileExportFormat.allCases {
            for item in plan.items {
                _ = try exporter.write(item, format: format, under: destination.appendingPathComponent(format.rawValue), options: ExportOptions())
            }
        }

        var files: [String: Data] = [:]
        let walker = try #require(FileManager.default.enumerator(at: destination, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in walker where (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            files[url.lastPathComponent] = try Data(contentsOf: url)
        }
        #expect(files.keys.contains { $0.hasSuffix(".md") } && files.keys.contains { $0.hasSuffix(".txt") } && files["info.json"] != nil)
        // The Markdown file is the note's text and nothing else.
        let markdown = try #require(files.first { $0.key.hasSuffix(".md") }?.value)
        #expect(Array(markdown) == Array(note.text.utf8))
        let fireMillis = String(Int64(ping.fireAt.timeIntervalSince1970 * 1000))
        let fireSeconds = String(Int64(ping.fireAt.timeIntervalSince1970))
        for (name, data) in files {
            let text = String(decoding: data, as: UTF8.self)
            for canary in [snapshotCanary, ping.id, anchor.hash, fireMillis, fireSeconds, "captureSource", "lastOpenedAt", "hiddenUntil", "fireAt", "voice"] {
                #expect(!text.contains(canary), "\(canary) in \(name)")
            }
        }
    }
}
