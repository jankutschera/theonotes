// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct CardPublicationTests {
    static let now = FocusFixtureLibrary.now
    static let calendar = FocusFixtureLibrary.utc
    static let midnight = FocusClock.nextLocalMidnight(after: now, calendar: calendar)

    private func make(_ f: FocusFixtureLibrary, appLock: Bool = false) throws -> CardPublication {
        try CardPublication.make(card: f.card, appLockEnabled: appLock, now: Self.now, calendar: Self.calendar)
    }

    private func json(_ publication: CardPublication) throws -> String {
        String(decoding: try publication.encoded(), as: UTF8.self)
    }

    @Test func timelineHasNowMidnightAndUpcomingReminders() throws {
        let f = try FocusFixtureLibrary(); defer { f.cleanup() }
        // Later hides the to-do now; the hide ends at midnight.
        try f.card.later(try #require(try f.card.next(now: Self.now, calendar: Self.calendar)), now: Self.now, calendar: Self.calendar)
        let inRange = try f.store.setPing(noteId: f.plain.id, anchor: nil, fireAt: FocusFixtureLibrary.at(hours: 20), now: Self.now)
        // Not listed: beyond 24 hours, already fired, and on an archived note.
        _ = try f.store.setPing(noteId: f.captured.id, anchor: nil, fireAt: FocusFixtureLibrary.at(hours: 30), now: Self.now)
        let fired = try f.store.setPing(noteId: f.oldTodo.id, anchor: nil, fireAt: FocusFixtureLibrary.at(hours: 22), now: Self.now)
        try f.store.markPingFired(id: fired.id, at: Self.now)
        let archived = try f.store.create(text: "# Archived", now: Self.now)
        try f.store.archive([archived.id])
        _ = try f.store.setPing(noteId: archived.id, anchor: nil, fireAt: FocusFixtureLibrary.at(hours: 5), now: Self.now)

        let publication = try make(f)

        #expect(publication.version == 1)
        #expect(publication.entries == [
            .init(date: Self.now, state: .candidate, noteId: f.captured.id, kind: "capture", title: "Captured"),
            .init(date: Self.midnight, state: .candidate, noteId: f.oldTodo.id, kind: "todo", title: "Old todo", line: "Call Anna"),
            .init(date: inRange.fireAt, state: .candidate, noteId: f.plain.id, kind: "reminder", title: "Plain"),
        ])
        #expect(Self.midnight == FocusFixtureLibrary.at(hours: 16))
    }

    @Test func publishingPurgesExpiredHidesLikeACardRead() throws {
        let f = try FocusFixtureLibrary(); defer { f.cleanup() }
        try f.card.later(try #require(try f.card.next(now: Self.now, calendar: Self.calendar)), now: Self.now, calendar: Self.calendar)
        try f.card.notToday(now: Self.now, calendar: Self.calendar)
        #expect(try f.hideCount() == 2)

        // Only the publication runs, after midnight: the hides are expired.
        let after = Self.midnight.addingTimeInterval(60)
        let publication = try CardPublication.make(card: f.card, appLockEnabled: false, now: after, calendar: Self.calendar)

        #expect(try f.hideCount() == 0)
        #expect(publication.entries.first == .init(
            date: after, state: .candidate, noteId: f.oldTodo.id, kind: "todo", title: "Old todo", line: "Call Anna"))
    }

    @Test func anEmptyCardIsAnEmptyEntry() throws {
        let f = try FocusFixtureLibrary(); defer { f.cleanup() }
        try f.card.notToday(now: Self.now, calendar: Self.calendar)

        let publication = try make(f)

        #expect(publication.entries == [
            .init(date: Self.now, state: .empty),
            .init(date: Self.midnight, state: .candidate, noteId: f.oldTodo.id, kind: "todo", title: "Old todo", line: "Call Anna"),
        ])
    }

    @Test func entriesAreCappedAtTenAndKeepMidnight() throws {
        let f = try FocusFixtureLibrary(); defer { f.cleanup() }
        let lines = (1...12).map { "line \($0)" }
        let busy = try f.store.create(text: lines.joined(separator: "\n"), now: Self.now)
        for (index, _) in lines.enumerated() {
            let anchor = try #require(LineAnchor.at(line: index + 1, in: busy.text))
            _ = try f.store.setPing(noteId: busy.id, anchor: anchor, fireAt: FocusFixtureLibrary.at(hours: Double(index + 1)), now: Self.now)
        }

        let publication = try make(f)

        #expect(publication.entries.count == CardPublication.entryLimit)
        #expect(publication.entries.map(\.date) == publication.entries.map(\.date).sorted())
        #expect(publication.entries.first?.date == Self.now)
        #expect(publication.entries.contains { $0.date == Self.midnight })
        // The reminders show their line, and the ones after the cap are left out.
        #expect(publication.entries.contains { $0.kind == "reminder" && $0.line == "line 1" })
        #expect(!publication.entries.contains { $0.line == "line 10" })
    }

    @Test func appLockEnabledAndLockedNotesAreRedacted() throws {
        let f = try FocusFixtureLibrary(secretReminderAt: FocusFixtureLibrary.at(hours: -2)); defer { f.cleanup() }

        // App Lock enabled: one locked entry, nothing of any note, whatever the card holds.
        let appLocked = try make(f, appLock: true)
        #expect(appLocked == .locked(now: Self.now))
        let appLockedJSON = try json(appLocked)
        for secret in ["Old todo", "Call Anna", "Captured", "Secret", "Plain", f.oldTodo.id, f.captured.id, f.secret.id] {
            #expect(!appLockedJSON.contains(secret))
        }

        // App Lock off, only the locked note's reminder is due: its entry is locked and empty of
        // strings, unlike the in-app card, which shows the title.
        try f.store.trash([f.oldTodo.id, f.captured.id])
        let publication = try make(f)
        #expect(publication.entries.first == .init(date: Self.now, state: .locked))
        let text = try json(publication)
        for secret in ["Secret", "move the money", f.secret.id] {
            #expect(!text.contains(secret))
        }
        #expect(try FocusCard(store: f.store).next(now: Self.now, calendar: Self.calendar) != nil)
    }

    @Test func lockedPublicationCarriesNoStrings() throws {
        let publication = CardPublication.locked(now: Self.now)

        #expect(publication.entries.count == 1)
        let entry = try #require(publication.entries.first)
        #expect(entry.state == .locked)
        #expect(entry.noteId == nil && entry.kind == nil && entry.title == nil && entry.line == nil)
        #expect(try json(publication) == #"{"entries":[{"date":1800000000000,"state":"locked"}],"version":1}"#)
        #expect(CardPublication.relativePath == "Card/next-up.json")
    }

    @Test func encodingIsStable() throws {
        let publication = CardPublication(entries: [
            .init(date: Date(timeIntervalSince1970: 1_800_000_000.0004), state: .candidate, noteId: "n1", kind: "todo",
                  title: "Call/Text \"Anna\"", line: "Ünï 😀"),
            .init(date: Date(timeIntervalSince1970: 1_800_000_060), state: .empty),
        ])
        let expected = #"{"entries":[{"date":1800000000000,"kind":"todo","line":"Ünï 😀","noteId":"n1","state":"candidate","title":"Call/Text \"Anna\""},"#
            + #"{"date":1800000060000,"state":"empty"}],"version":1}"#

        #expect(try json(publication) == expected)
        #expect(try publication.encoded() == publication.encoded())
        #expect(try CardPublication.decode(Data(expected.utf8)) == publication)
        #expect(try CardPublication.decode(publication.encoded()) == publication)
    }
}
