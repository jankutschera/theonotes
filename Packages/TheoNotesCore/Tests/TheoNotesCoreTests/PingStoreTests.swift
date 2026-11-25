// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct PingStoreTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func at(_ hours: Double) -> Date { now.addingTimeInterval(hours * 3600) }

    let tmp: TempPaths
    init() throws { tmp = try TempPaths() }

    private func store() throws -> NoteStore {
        NoteStore(db: try .inMemory(), notifier: nil, paths: tmp.paths)
    }

    private func anchor(_ line: Int, in text: String) throws -> LineAnchor {
        try #require(LineAnchor.at(line: line, in: text))
    }

    @Test func settingTheSameLineTwiceMovesTheTime() throws {
        let store = try store()
        let note = try store.create(text: "# T\nline two\nline three")
        let anchor = try anchor(2, in: note.text)
        let first = try store.setPing(noteId: note.id, anchor: anchor, fireAt: Self.at(1), now: Self.now)
        let second = try store.setPing(noteId: note.id, anchor: anchor, fireAt: Self.at(5), now: Self.at(0.5))
        #expect(second.id == first.id)
        #expect(second.fireAt == Self.at(5))
        #expect(second.anchor == anchor)
        #expect(try store.pings() == [second])
        #expect(try store.ping(id: first.id) == second)
    }

    @Test func movingAFiredReminderRearmsIt() throws {
        let store = try store()
        let note = try store.create(text: "# T")
        let ping = try store.setPing(noteId: note.id, anchor: nil, fireAt: Self.at(1), now: Self.now)
        try store.markPingFired(id: ping.id, at: Self.at(2))
        #expect(try store.ping(id: ping.id)?.firedAt == Self.at(2))
        let moved = try store.setPing(noteId: note.id, anchor: nil, fireAt: Self.at(9), now: Self.at(3))
        #expect(moved.id == ping.id)
        #expect(moved.firedAt == nil)
    }

    @Test func lineAndWholeNoteAreSeparateTargets() throws {
        let store = try store()
        let note = try store.create(text: "# T\nline two")
        let line = try store.setPing(noteId: note.id, anchor: try anchor(2, in: note.text), fireAt: Self.at(1), now: Self.now)
        let whole = try store.setPing(noteId: note.id, anchor: nil, fireAt: Self.at(2), now: Self.now)
        #expect(line.id != whole.id)
        #expect(try store.pings().map(\.id) == [line.id, whole.id])
        // A second line is a third target.
        let other = try store.setPing(noteId: note.id, anchor: try anchor(1, in: note.text), fireAt: Self.at(3), now: Self.now)
        #expect(Set(try store.pings().map(\.id)) == [line.id, whole.id, other.id])
    }

    @Test func settingAPingOnAnUnknownNoteThrows() throws {
        let store = try store()
        #expect(throws: StoreError.noteNotFound(id: "missing")) {
            try store.setPing(noteId: "missing", anchor: nil, fireAt: Self.at(1), now: Self.now)
        }
    }

    @Test func aMalformedAnchorIsRefused() throws {
        let store = try store()
        let note = try store.create(text: "# T")
        #expect(throws: PingError.invalidAnchor) {
            try store.setPing(noteId: note.id, anchor: LineAnchor(line: 0, hash: "abcd1234"), fireAt: Self.at(1), now: Self.now)
        }
        #expect(throws: PingError.invalidAnchor) {
            try store.setPing(noteId: note.id, anchor: LineAnchor(line: 1, hash: "ABCD"), fireAt: Self.at(1), now: Self.now)
        }
        #expect(try store.pings().isEmpty)
    }

    @Test func snoozeCreatesOneReplacementNotTwo() throws {
        let store = try store()
        let note = try store.create(text: "# T\nline two")
        let anchor = try anchor(2, in: note.text)
        let original = try store.setPing(noteId: note.id, anchor: anchor, fireAt: Self.at(1), now: Self.now)
        try store.markPingFired(id: original.id, at: Self.at(1))
        let snoozed = try store.snoozePing(id: original.id, until: Self.at(2), now: Self.at(1.1))
        #expect(snoozed.id != original.id)
        #expect(snoozed.noteId == note.id)
        #expect(snoozed.anchor == anchor)
        #expect(snoozed.fireAt == Self.at(2))
        #expect(snoozed.firedAt == nil)
        #expect(try store.pings() == [snoozed])
        #expect(try store.ping(id: original.id) == nil)
    }

    @Test func snoozingAMissingPingThrows() throws {
        let store = try store()
        #expect(throws: PingError.pingNotFound(id: "gone")) {
            try store.snoozePing(id: "gone", until: Self.at(2), now: Self.now)
        }
    }

    @Test func handleDeletesTheRow() throws {
        let store = try store()
        let note = try store.create(text: "# T")
        let ping = try store.setPing(noteId: note.id, anchor: nil, fireAt: Self.at(1), now: Self.now)
        let kept = try store.setPing(noteId: note.id, anchor: try anchor(1, in: note.text), fireAt: Self.at(1), now: Self.now)
        try store.handlePing(id: ping.id)
        #expect(try store.pings() == [kept])
        // Handling twice, or an unknown id, is not an error: the notification and the card can race.
        try store.handlePing(id: ping.id)
        try store.handlePing(id: "never-existed")
    }

    @Test func markPingsFiredSetsFiredAtOnlyForDueRows() throws {
        let store = try store()
        let note = try store.create(text: "# T\nline two\nline three")
        let due = try store.setPing(noteId: note.id, anchor: nil, fireAt: Self.at(1), now: Self.now)
        let exact = try store.setPing(noteId: note.id, anchor: try anchor(2, in: note.text), fireAt: Self.at(2), now: Self.now)
        let later = try store.setPing(noteId: note.id, anchor: try anchor(3, in: note.text), fireAt: Self.at(3), now: Self.now)

        let marked = try store.markPingsFired(dueBy: Self.at(2))

        #expect(marked == [due.id, exact.id])
        #expect(try store.ping(id: due.id)?.firedAt == Self.at(2))
        #expect(try store.ping(id: exact.id)?.firedAt == Self.at(2))
        #expect(try store.ping(id: later.id)?.firedAt == nil)
        // Already fired rows keep their first firedAt and are not reported again.
        #expect(try store.markPingsFired(dueBy: Self.at(10)) == [later.id])
        #expect(try store.ping(id: due.id)?.firedAt == Self.at(2))
    }

    @Test func aReminderMovedBetweenChoosingAndMarkingIsNotMarked() throws {
        let store = try store()
        let note = try store.create(text: "# T\nline two")
        let moving = try store.setPing(noteId: note.id, anchor: nil, fireAt: Self.at(1), now: Self.now)
        let steady = try store.setPing(noteId: note.id, anchor: try anchor(2, in: note.text), fireAt: Self.at(1), now: Self.now)

        // A concurrent setPing lands after the due rows were chosen and before they are marked.
        let marked = try store.markPingsFired(dueBy: Self.at(2)) { db in
            try db.execute(sql: "UPDATE note_ping SET fireAt = ?, firedAt = NULL WHERE id = ?", arguments: [Self.at(9), moving.id])
        }

        #expect(marked == [steady.id])
        let after = try #require(try store.ping(id: moving.id))
        #expect(after.firedAt == nil)
        #expect(after.fireAt == Self.at(9))
        #expect(try store.ping(id: steady.id)?.firedAt == Self.at(2))
    }

    @Test func markPingFiredKeepsTheFirstTime() throws {
        let store = try store()
        let note = try store.create(text: "# T")
        let ping = try store.setPing(noteId: note.id, anchor: nil, fireAt: Self.at(1), now: Self.now)
        try store.markPingFired(id: ping.id, at: Self.at(1))
        try store.markPingFired(id: ping.id, at: Self.at(4))
        #expect(try store.ping(id: ping.id)?.firedAt == Self.at(1))
        try store.markPingFired(id: "never-existed", at: Self.at(4))
    }

    @Test func lockedNoteRefusesALineReminderAndMovesItsOneWholeNoteReminder() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Plan\nsecret line")
        let whole = try library.store.setPing(noteId: note.id, anchor: nil, fireAt: Self.at(1), now: Self.now)
        let access = try library.access(); defer { access.revoke() }
        try access.lock(noteId: note.id)

        let line = LineAnchor(line: 2, hash: "abcd1234")
        #expect(throws: StoreError.noteLocked(id: note.id)) {
            try library.store.setPing(noteId: note.id, anchor: line, fireAt: Self.at(5), now: Self.now)
        }
        #expect(try library.store.pings() == [whole])

        let moved = try library.store.setPing(noteId: note.id, anchor: nil, fireAt: Self.at(7), now: Self.at(2))
        #expect(moved.id == whole.id)
        #expect(moved.fireAt == Self.at(7))
        #expect(try library.store.pings() == [moved])
    }

    @Test func lockedNoteWithoutAReminderGetsOneWholeNoteReminder() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Plan")
        let access = try library.access(); defer { access.revoke() }
        try access.lock(noteId: note.id)
        let ping = try library.store.setPing(noteId: note.id, anchor: nil, fireAt: Self.at(1), now: Self.now)
        #expect(ping.anchor == nil)
        #expect(try library.store.pings() == [ping])
    }

    @Test func pingsNeverTouchTheNote() throws {
        let store = try store()
        let note = try store.create(text: "# T\nline two", now: Self.now)
        let before = try #require(try store.note(id: note.id))
        let dirtyBefore = try store.db.pool.read { try Int.fetchOne($0, sql: "SELECT COALESCE(SUM(generation), 0) FROM sync_dirty") }
        let line = try store.setPing(noteId: note.id, anchor: try anchor(2, in: note.text), fireAt: Self.at(1), now: Self.at(9))
        let whole = try store.setPing(noteId: note.id, anchor: nil, fireAt: Self.at(1), now: Self.at(9))
        _ = try store.markPingsFired(dueBy: Self.at(3))
        let snoozed = try store.snoozePing(id: line.id, until: Self.at(4), now: Self.at(9))
        try store.handlePing(id: whole.id)
        try store.handlePing(id: snoozed.id)
        #expect(try store.note(id: note.id) == before)
        let dirtyAfter = try store.db.pool.read { try Int.fetchOne($0, sql: "SELECT COALESCE(SUM(generation), 0) FROM sync_dirty") }
        #expect(dirtyAfter == dirtyBefore)
    }

    @Test func aDeletedNoteTakesItsReminders() throws {
        let store = try store()
        let note = try store.create(text: "# T")
        _ = try store.setPing(noteId: note.id, anchor: nil, fireAt: Self.at(1), now: Self.now)
        try store.deletePermanently([note.id])
        #expect(try store.pings().isEmpty)
    }
}
