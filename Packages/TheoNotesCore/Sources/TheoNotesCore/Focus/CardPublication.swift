// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

/// What the widget and the lock-screen card read (`Card/next-up.json`, FOC-R13): a timeline of
/// what the Next Up card will show and when, so the system can switch it without waking the app.
///
/// Entries, oldest first and at most 10: now, the next local midnight (when Later and Not Today
/// end), and the first 8 unfired reminders within 24 hours. It carries no score, count or history (I3).
///
/// Privacy (FOC-R160): while App Lock is enabled the publication is a single `.locked` entry with
/// no strings. A reminder on a locked note is a `.locked` entry too: the file lives outside the
/// unlocked app, so unlike the in-app card it does not even show that note's title.
public struct CardPublication: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case candidate, empty, locked
    }

    public struct Entry: Codable, Equatable, Sendable {
        /// When this entry starts to apply (millisecond precision).
        public let date: Date
        public let state: State
        public let noteId: String?
        /// `reminder`, `todo` or `capture`; only on a `.candidate`.
        public let kind: String?
        public let title: String?
        /// The reminder's or to-do's line as a card shows it.
        public let line: String?

        public init(date: Date, state: State, noteId: String? = nil, kind: String? = nil, title: String? = nil, line: String? = nil) {
            self.date = NoteStore.roundedToMillis(date)
            self.state = state
            self.noteId = noteId
            self.kind = kind
            self.title = title
            self.line = line
        }
    }

    public static let relativePath = "Card/next-up.json"
    /// Entries per publication.
    public static let entryLimit = 10
    /// How far ahead reminders are listed.
    static let horizon: TimeInterval = 24 * 3600

    public var version = 1
    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    /// One `.locked` entry and no strings. What the app writes synchronously at library
    /// initialization while App Lock is enabled, before any window or widget can read the old file.
    public static func locked(now: Date) -> CardPublication {
        CardPublication(entries: [Entry(date: now, state: .locked)])
    }

    /// The timeline from `now`. `appLockEnabled` is the Settings value, not the engaged state.
    public static func make(card: FocusCard, appLockEnabled: Bool, now: Date, calendar: Calendar) throws -> CardPublication {
        if appLockEnabled { return locked(now: now) }
        try card.purgeExpiredHides(at: now)
        let start = NoteStore.roundedToMillis(now)
        let reminders = try card.store.db.pool.read { db in
            try Date.fetchAll(db, sql: """
                SELECT p.fireAt FROM note_ping p JOIN note n ON n.id = p.noteId
                WHERE p.firedAt IS NULL AND p.fireAt > ? AND p.fireAt <= ?
                  AND n.location = 'notes' AND n.deletedAt IS NULL
                ORDER BY p.fireAt, p.id LIMIT ?
                """, arguments: [start, start.addingTimeInterval(horizon), entryLimit - 2])
        }
        var dates = [start, NoteStore.roundedToMillis(FocusClock.nextLocalMidnight(after: now, calendar: calendar))]
        dates.append(contentsOf: reminders.map(NoteStore.roundedToMillis))
        // At most 2 + (entryLimit - 2) dates, so the timeline never exceeds `entryLimit`.
        var seen = Set<Date>()
        let ordered = dates.filter { seen.insert($0).inserted }.sorted()
        return CardPublication(entries: try ordered.map { date in
            entry(for: try card.candidate(at: date), at: date)
        })
    }

    private static func entry(for candidate: FocusCandidate?, at date: Date) -> Entry {
        switch candidate {
        case nil:
            return Entry(date: date, state: .empty)
        case .reminder(let r)?:
            if r.isLocked { return Entry(date: date, state: .locked) }
            return Entry(date: date, state: .candidate, noteId: r.noteId, kind: "reminder", title: r.title, line: r.lineText)
        case .todo(let t)?:
            return Entry(date: date, state: .candidate, noteId: t.noteId, kind: "todo", title: t.title, line: t.lineText)
        case .capture(let c)?:
            return Entry(date: date, state: .candidate, noteId: c.noteId, kind: "capture", title: c.title)
        }
    }

    // MARK: Encoding

    /// Sorted keys, dates as integer milliseconds: the same publication is always the same bytes,
    /// so the app can skip a write that would change nothing.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> CardPublication {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(CardPublication.self, from: data)
    }
}
