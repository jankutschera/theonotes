// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct PingPlannerTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func at(_ hours: Double) -> Date { now.addingTimeInterval(hours * 3600) }

    let tmp: TempPaths
    init() throws { tmp = try TempPaths() }

    private func store() throws -> NoteStore {
        NoteStore(db: try .inMemory(), notifier: nil, paths: tmp.paths)
    }

    private func plan(_ store: NoteStore, appLock: Bool = false, now: Date = PingPlannerTests.now) throws -> [PlannedNotification] {
        try PingPlanner.plan(store: store, appLockEnabled: appLock, now: now)
    }

    @Test func lineReminderShowsTitleAndLine() throws {
        let store = try store()
        let note = try store.create(text: "# Plan\n- [ ] **call** the dentist  \nrest")
        let anchor = try #require(LineAnchor.at(line: 2, in: note.text))
        let ping = try store.setPing(noteId: note.id, anchor: anchor, fireAt: Self.at(2), now: Self.now)

        let planned = try plan(store)

        #expect(planned.count == 1)
        let item = try #require(planned.first)
        #expect(item.pingId == ping.id)
        #expect(item.noteId == note.id)
        #expect(item.title == "Plan")
        #expect(item.body == "**call** the dentist")
        #expect(item.line == 2)
        #expect(item.fireAt == Self.at(2))
    }

    @Test func theAnchoredLineFollowsLinesInsertedAbove() throws {
        let store = try store()
        let note = try store.create(text: "# Plan\ncall the dentist")
        let anchor = try #require(LineAnchor.at(line: 2, in: note.text))
        _ = try store.setPing(noteId: note.id, anchor: anchor, fireAt: Self.at(2), now: Self.now)
        _ = try store.updateText(id: note.id, text: "# Plan\nnew one\nnew two\ncall the dentist", expectedRevision: note.revision)

        let item = try #require(try plan(store).first)

        #expect(item.body == "call the dentist")
        #expect(item.line == 4)
    }

    @Test func wholeNoteReminderHasNoBody() throws {
        let store = try store()
        let note = try store.create(text: "# Plan\nsome body text")
        _ = try store.setPing(noteId: note.id, anchor: nil, fireAt: Self.at(2), now: Self.now)

        let item = try #require(try plan(store).first)

        #expect(item.title == "Plan")
        #expect(item.body == nil)
        #expect(item.line == nil)
    }

    /// K5 P-R1: "Untitled" / "oneThe text." was the plan working as written. The note's first line was
    /// blank (so no title) and its second line really read `oneThe text.`; title and line stay in
    /// separate fields and are never joined.
    @Test func aBlankFirstLineGivesUntitledAndTheLineIsTheBodyAsWritten() throws {
        let store = try store()
        let text = "\noneThe text.\n[Voice Note.m4a](Voice%20Note.m4a)<!-- {\"embed\":\"true\"} -->\n two"
        let note = try store.create(text: text)
        let anchor = try #require(LineAnchor.at(line: 2, in: note.text))
        _ = try store.setPing(noteId: note.id, anchor: anchor, fireAt: Self.at(2), now: Self.now)

        let item = try #require(try plan(store).first)

        #expect(item.title == "Untitled")
        #expect(item.body == "oneThe text.")
        #expect(item.line == 2)
    }

    @Test func theTitleAndTheLineAreSeparateFields() throws {
        let store = try store()
        let note = try store.create(text: "Plan\none")
        let anchor = try #require(LineAnchor.at(line: 2, in: note.text))
        _ = try store.setPing(noteId: note.id, anchor: anchor, fireAt: Self.at(2), now: Self.now)

        let item = try #require(try plan(store).first)

        #expect(item.title == "Plan")
        #expect(item.body == "one")
    }

    @Test func aNoteWithoutATitleIsCalledUntitled() throws {
        let store = try store()
        let note = try store.create(text: "")
        _ = try store.setPing(noteId: note.id, anchor: nil, fireAt: Self.at(2), now: Self.now)
        #expect(try plan(store).first?.title == "Untitled")
    }

    @Test func deletedLineFallsBackToTheTitle() throws {
        let store = try store()
        let note = try store.create(text: "# Plan\ncall the dentist\nlast")
        let anchor = try #require(LineAnchor.at(line: 2, in: note.text))
        let ping = try store.setPing(noteId: note.id, anchor: anchor, fireAt: Self.at(2), now: Self.now)
        _ = try store.updateText(id: note.id, text: "# Plan\nlast", expectedRevision: note.revision)

        let planned = try plan(store)

        #expect(planned.count == 1)
        let item = try #require(planned.first)
        #expect(item.pingId == ping.id)
        #expect(item.title == "Plan")
        #expect(item.body == nil)
        #expect(item.line == nil)
    }

    @Test func anAnchoredLineThatDisplaysAsNothingHasNoBodyButKeepsItsLine() throws {
        let store = try store()
        let note = try store.create(text: "# Plan\n- [ ]\nlast")
        let anchor = try #require(LineAnchor.at(line: 2, in: note.text))
        _ = try store.setPing(noteId: note.id, anchor: anchor, fireAt: Self.at(2), now: Self.now)
        let item = try #require(try plan(store).first)
        #expect(item.body == nil)
        #expect(item.line == 2)
    }

    @Test func lockedNoteShowsTitleOnly() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Plan\nsecret canary line")
        let anchor = try #require(LineAnchor.at(line: 2, in: note.text))
        _ = try library.store.setPing(noteId: note.id, anchor: anchor, fireAt: Self.at(2), now: Self.now)
        let access = try library.access(); defer { access.revoke() }
        try access.lock(noteId: note.id)

        let planned = try plan(library.store)

        #expect(planned.count == 1)
        let item = try #require(planned.first)
        #expect(item.title == "Plan")
        #expect(item.body == nil)
        #expect(item.line == nil)
        #expect(!String(describing: item).contains("canary"))
    }

    @Test func appLockShowsNoNoteText() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let open = try library.store.create(text: "# Open canary title\ncanary body line")
        let locked = try library.store.create(text: "# Locked canary title")
        _ = try library.store.setPing(noteId: open.id, anchor: try #require(LineAnchor.at(line: 2, in: open.text)), fireAt: Self.at(2), now: Self.now)
        _ = try library.store.setPing(noteId: locked.id, anchor: nil, fireAt: Self.at(3), now: Self.now)
        let access = try library.access(); defer { access.revoke() }
        try access.lock(noteId: locked.id)

        let planned = try plan(library.store, appLock: true)

        #expect(planned.count == 2)
        for item in planned {
            #expect(item.title == PingPlanner.genericTitle)
            #expect(item.body == PingPlanner.genericBody)
            #expect(item.line == nil)
            #expect(!String(describing: item).contains("canary"))
        }
        // They still point at their reminders, so the scheduler can map a tap back.
        #expect(Set(planned.map(\.noteId)) == [open.id, locked.id])
    }

    @Test func archivedOrTrashedNotesAreNotPlannedAndComeBackOnRestore() throws {
        let store = try store()
        let note = try store.create(text: "# Plan")
        let other = try store.create(text: "# Other")
        _ = try store.setPing(noteId: note.id, anchor: nil, fireAt: Self.at(5), now: Self.now)
        _ = try store.setPing(noteId: other.id, anchor: nil, fireAt: Self.at(6), now: Self.now)

        try store.archive([note.id])
        #expect(try plan(store).map(\.noteId) == [other.id])
        try store.restore([note.id])
        #expect(try plan(store).map(\.noteId) == [note.id, other.id])

        try store.trash([note.id])
        #expect(try plan(store).map(\.noteId) == [other.id])
        try store.restore([note.id])
        #expect(try plan(store).map(\.noteId) == [note.id, other.id])
        // The rows were never touched while the note was away.
        #expect(try store.pings().count == 2)
    }

    @Test func firedAndPastRemindersAreNotPlanned() throws {
        let store = try store()
        let note = try store.create(text: "# Plan\na\nb\nc")
        _ = try store.setPing(noteId: note.id, anchor: nil, fireAt: Self.at(-1), now: Self.now)
        let fired = try store.setPing(noteId: note.id, anchor: try #require(LineAnchor.at(line: 2, in: note.text)), fireAt: Self.at(1), now: Self.now)
        try store.markPingFired(id: fired.id, at: Self.at(1))
        _ = try store.setPing(noteId: note.id, anchor: try #require(LineAnchor.at(line: 3, in: note.text)), fireAt: Self.now, now: Self.now)
        let future = try store.setPing(noteId: note.id, anchor: try #require(LineAnchor.at(line: 4, in: note.text)), fireAt: Self.at(1), now: Self.now)

        #expect(try plan(store).map(\.pingId) == [future.id])
    }

    @Test func plansAreOrderedByTimeThenId() throws {
        let store = try store()
        let a = try store.create(text: "# A")
        let b = try store.create(text: "# B")
        _ = try store.setPing(noteId: a.id, anchor: nil, fireAt: Self.at(9), now: Self.now)
        _ = try store.setPing(noteId: b.id, anchor: nil, fireAt: Self.at(2), now: Self.now)
        #expect(try plan(store).map(\.title) == ["B", "A"])
    }

    @Test func contentHashFollowsTheDocumentedRule() throws {
        let store = try store()
        let note = try store.create(text: "# Plan\ncall the dentist")
        let ping = try store.setPing(noteId: note.id, anchor: try #require(LineAnchor.at(line: 2, in: note.text)), fireAt: Self.at(2), now: Self.now)
        let whole = try store.setPing(noteId: note.id, anchor: nil, fireAt: Self.at(3), now: Self.now)
        let planned = try plan(store)
        let ms = Int64((Self.at(2).timeIntervalSince1970 * 1000).rounded())
        let msWhole = Int64((Self.at(3).timeIntervalSince1970 * 1000).rounded())
        let byPing = Dictionary(uniqueKeysWithValues: planned.map { ($0.pingId, $0) })
        #expect(byPing[ping.id]?.contentHash == LineAnchor.hash("Plan\ncall the dentist\n\(ms)"))
        #expect(byPing[whole.id]?.contentHash == LineAnchor.hash("Plan\n\n\(msWhole)"))
        #expect(LineAnchor.isValidHash(try #require(byPing[ping.id]).contentHash))
    }

    @Test func aChangedTitleBodyOrTimeChangesTheHash() throws {
        let store = try store()
        let note = try store.create(text: "# Plan\ncall the dentist")
        let ping = try store.setPing(noteId: note.id, anchor: try #require(LineAnchor.at(line: 2, in: note.text)), fireAt: Self.at(2), now: Self.now)
        let first = try #require(try plan(store).first).contentHash
        _ = try store.setPing(noteId: note.id, anchor: ping.anchor, fireAt: Self.at(3), now: Self.now)
        let moved = try #require(try plan(store).first).contentHash
        #expect(moved != first)
        let renamed = try store.updateText(id: note.id, text: "# Plans\ncall the dentist", expectedRevision: note.revision)
        let retitled = try #require(try plan(store).first).contentHash
        #expect(retitled != moved)
        _ = try store.updateText(id: note.id, text: "# Plans\ncall the dentist now", expectedRevision: renamed.revision)
        // The line text changed, so the anchor no longer resolves: the body is gone and the hash differs again.
        #expect(try #require(try plan(store).first).contentHash != retitled)
    }
}
