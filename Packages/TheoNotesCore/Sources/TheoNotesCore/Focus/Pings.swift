// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

/// A one-time reminder on a note: on the whole note (`anchor == nil`) or on one line of it
/// (FOC-R10). Device-local: it is not part of the note, the sync payload or any export.
public struct Ping: Equatable, Sendable {
    public let id: String
    public let noteId: String
    public let anchor: LineAnchor?
    public let fireAt: Date
    /// Set when the reminder was delivered, or seen past due at launch or activation. A fired
    /// reminder is a due card candidate until it is handled (`handlePing`) or snoozed.
    public let firedAt: Date?

    public init(id: String, noteId: String, anchor: LineAnchor?, fireAt: Date, firedAt: Date?) {
        self.id = id
        self.noteId = noteId
        self.anchor = anchor
        self.fireAt = fireAt
        self.firedAt = firedAt
    }
}

public enum PingError: Error, Equatable {
    /// The anchor line is below 1 or its hash is not 8 lowercase hex characters.
    case invalidAnchor
    case pingNotFound(id: String)
}

/// The times a reminder is offered at.
public enum PingTime {
    /// 09:00 today when `now` is before 09:00, otherwise 09:00 tomorrow, in `calendar`'s zone.
    public static func defaultFireDate(now: Date, calendar: Calendar) -> Date {
        FocusClock.nextNineAM(after: now, calendar: calendar)
    }

    public static func inOneHour(now: Date) -> Date {
        now.addingTimeInterval(3600)
    }

    public static func inFiveMinutes(now: Date) -> Date {
        now.addingTimeInterval(300)
    }
}

extension NoteStore {
    /// The order a locked note's single reminder is chosen in: the whole-note row first, then the
    /// same order `FocusPurge` keeps one by.
    private static let lockedChoiceOrder = "anchorLine IS NOT NULL, firedAt IS NOT NULL, fireAt, id"

    /// Sets the reminder for (`noteId`, `anchor`) to `fireAt`. A second call for the same target
    /// moves that reminder (same id, armed again) instead of adding one. A locked note takes no
    /// line reminder (`StoreError.noteLocked`): it keeps one title-only reminder, which this moves.
    /// Writes no note row, so the note's revision, date and sync state stay as they were.
    @discardableResult
    public func setPing(noteId: String, anchor: LineAnchor?, fireAt: Date, now: Date = .now) throws -> Ping {
        if let anchor, anchor.line < 1 || !LineAnchor.isValidHash(anchor.hash) { throw PingError.invalidAnchor }
        let fire = Self.roundedToMillis(fireAt)
        return try write { db in
            guard let isLocked = try Bool.fetchOne(db, sql: "SELECT isLocked FROM note WHERE id = ?", arguments: [noteId]) else {
                throw StoreError.noteNotFound(id: noteId)
            }
            let existing: String?
            if isLocked {
                if anchor != nil { throw StoreError.noteLocked(id: noteId) }
                existing = try String.fetchOne(db, sql: """
                    SELECT id FROM note_ping WHERE noteId = ? ORDER BY \(Self.lockedChoiceOrder) LIMIT 1
                    """, arguments: [noteId])
            } else {
                existing = try String.fetchOne(db, sql: """
                    SELECT id FROM note_ping
                    WHERE noteId = ? AND COALESCE(anchorLine, 0) = ? AND COALESCE(anchorHash, '') = ?
                    """, arguments: [noteId, anchor?.line ?? 0, anchor?.hash ?? ""])
            }
            if let existing {
                try db.execute(sql: "UPDATE note_ping SET fireAt = ?, firedAt = NULL WHERE id = ?", arguments: [fire, existing])
                return try Self.requirePing(existing, in: db)
            }
            let id = UUIDv7.make(now: now)
            try db.execute(sql: """
                INSERT INTO note_ping(id, noteId, anchorLine, anchorHash, fireAt, firedAt, createdAt)
                VALUES(?, ?, ?, ?, ?, NULL, ?)
                """, arguments: [id, noteId, anchor?.line, anchor?.hash, fire, Self.roundedToMillis(now)])
            return try Self.requirePing(id, in: db)
        }
    }

    /// Every reminder, earliest first.
    public func pings() throws -> [Ping] {
        try db.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM note_ping ORDER BY fireAt, id").map(Self.ping(from:))
        }
    }

    public func ping(id: String) throws -> Ping? {
        try db.pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM note_ping WHERE id = ?", arguments: [id]).map(Self.ping(from:))
        }
    }

    /// Marks every unfired reminder with `fireAt <= dueBy` as fired at `dueBy` and returns their
    /// ids, earliest first. What launch and activation call to catch up on reminders that came
    /// due while the app was not running.
    public func markPingsFired(dueBy: Date) throws -> [String] {
        try markPingsFired(dueBy: dueBy, afterSelect: nil)
    }

    /// Choosing and marking happen in one write transaction. `afterSelect` is a test seam that runs
    /// between the two steps; the update re-checks that each row is still unfired and due.
    func markPingsFired(dueBy: Date, afterSelect: ((Database) throws -> Void)?) throws -> [String] {
        let cutoff = Self.roundedToMillis(dueBy)
        let anyDue = try db.pool.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM note_ping WHERE firedAt IS NULL AND fireAt <= ?)", arguments: [cutoff]) ?? false
        }
        guard anyDue else { return [] }
        return try write { db in
            let due = try String.fetchAll(db, sql: """
                SELECT id FROM note_ping WHERE firedAt IS NULL AND fireAt <= ? ORDER BY fireAt, id
                """, arguments: [cutoff])
            try afterSelect?(db)
            var marked: [String] = []
            for id in due {
                // The row must still be due: a reminder moved after it was chosen is not marked.
                try db.execute(sql: "UPDATE note_ping SET firedAt = ? WHERE id = ? AND firedAt IS NULL AND fireAt <= ?",
                               arguments: [cutoff, id, cutoff])
                if db.changesCount > 0 { marked.append(id) }
            }
            return marked
        }
    }

    /// Marks one reminder fired at `at`. The first time wins; an unknown id is ignored (the
    /// reminder may have been handled already).
    public func markPingFired(id: String, at: Date) throws {
        try write { db in
            try db.execute(sql: "UPDATE note_ping SET firedAt = COALESCE(firedAt, ?) WHERE id = ?", arguments: [Self.roundedToMillis(at), id])
        }
    }

    /// The reminder was dealt with (notification tapped or dismissed, card Open or Done): its row
    /// is deleted. An unknown id is ignored, so the notification and the card can race.
    public func handlePing(id: String) throws {
        try write { db in try db.execute(sql: "DELETE FROM note_ping WHERE id = ?", arguments: [id]) }
    }

    /// Replaces the reminder with exactly one new, unfired reminder on the same target at
    /// `until`, in one transaction. The old id is gone, so its notification is retired by the
    /// next reconcile.
    public func snoozePing(id: String, until: Date, now: Date = .now) throws -> Ping {
        try write { db in
            let old = try Self.requirePing(id, in: db)
            try db.execute(sql: "DELETE FROM note_ping WHERE id = ?", arguments: [id])
            let replacement = UUIDv7.make(now: now)
            try db.execute(sql: """
                INSERT INTO note_ping(id, noteId, anchorLine, anchorHash, fireAt, firedAt, createdAt)
                VALUES(?, ?, ?, ?, ?, NULL, ?)
                """, arguments: [replacement, old.noteId, old.anchor?.line, old.anchor?.hash,
                                 Self.roundedToMillis(until), Self.roundedToMillis(now)])
            return try Self.requirePing(replacement, in: db)
        }
    }

    private static func requirePing(_ id: String, in db: Database) throws -> Ping {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM note_ping WHERE id = ?", arguments: [id]) else {
            throw PingError.pingNotFound(id: id)
        }
        return ping(from: row)
    }

    private static func ping(from row: Row) -> Ping {
        let line: Int? = row["anchorLine"]
        let hash: String? = row["anchorHash"]
        let anchor = (line != nil && hash != nil) ? LineAnchor(line: line!, hash: hash!) : nil
        return Ping(id: row["id"], noteId: row["noteId"], anchor: anchor, fireAt: row["fireAt"], firedAt: row["firedAt"])
    }
}
