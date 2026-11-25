// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

/// One notification the apps should have scheduled. The identifier is not part of it: it comes
/// from the ledger (`NotificationLedger.reconcile`).
public struct PlannedNotification: Equatable, Sendable {
    public let pingId: String
    public let noteId: String
    public let title: String
    public let body: String?
    public let fireAt: Date
    /// The 1-based line a tap opens, when the anchored line still exists.
    public let line: Int?
    /// 8 hex characters over title, body and time (`PingPlanner.contentHash`): tells whether what
    /// is scheduled still matches the plan.
    public let contentHash: String

    public init(pingId: String, noteId: String, title: String, body: String?, fireAt: Date, line: Int?, contentHash: String) {
        self.pingId = pingId
        self.noteId = noteId
        self.title = title
        self.body = body
        self.fireAt = fireAt
        self.line = line
        self.contentHash = contentHash
    }
}

/// Which notifications should exist right now (FOC-R10). The apps' schedulers only apply this
/// plan; they decide nothing about content.
public enum PingPlanner {
    /// With App Lock enabled every notification reads like this and names no note.
    public static let genericTitle = "Theo Notes"
    public static let genericBody = "Reminder"
    static let untitled = "Untitled"

    /// One entry per reminder that is unfired, not yet due, and on a note in Notes, earliest first.
    /// - Line reminder: the note title and the anchored line (`FocusClock.displayLine`); when the
    ///   line is gone the title alone.
    /// - Whole-note reminder, and any reminder on a locked note: the title alone.
    /// - `appLockEnabled`: the generic text, for every note.
    /// Reminders on notes in Archive or Trash are left out and return when the note is restored.
    public static func plan(store: NoteStore, appLockEnabled: Bool, now: Date) throws -> [PlannedNotification] {
        let cutoff = NoteStore.roundedToMillis(now)
        let rows = try store.db.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT p.id, p.noteId, p.anchorLine, p.anchorHash, p.fireAt, n.title,
                       CASE WHEN p.anchorLine IS NULL OR n.isLocked THEN NULL ELSE n.text END AS text
                FROM note_ping p JOIN note n ON n.id = p.noteId
                WHERE p.firedAt IS NULL AND p.fireAt > ? AND n.location = 'notes' AND n.deletedAt IS NULL
                ORDER BY p.fireAt, p.id
                """, arguments: [cutoff])
        }
        return rows.map { row in
            let fireAt: Date = row["fireAt"]
            var title: String = row["title"]
            var body: String?
            var line: Int?
            if appLockEnabled {
                title = genericTitle
                body = genericBody
            } else {
                if title.isEmpty { title = untitled }
                let anchorLine: Int? = row["anchorLine"]
                let anchorHash: String? = row["anchorHash"]
                let text: String? = row["text"]
                if let anchorLine, let anchorHash, let text,
                   let resolved = LineAnchor(line: anchorLine, hash: anchorHash).resolve(in: text) {
                    line = resolved
                    let shown = LineAnchor.lineText(resolved, in: text).map(FocusClock.displayLine) ?? ""
                    body = shown.isEmpty ? nil : shown
                }
            }
            return PlannedNotification(
                pingId: row["id"], noteId: row["noteId"], title: title, body: body, fireAt: fireAt, line: line,
                contentHash: contentHash(title: title, body: body, fireAt: fireAt))
        }
    }

    /// `FNV8(title + "\n" + (body ?? "") + "\n" + fireAt-ms)`.
    static func contentHash(title: String, body: String?, fireAt: Date) -> String {
        let ms = Int64((fireAt.timeIntervalSince1970 * 1000).rounded())
        return LineAnchor.hash(title + "\n" + (body ?? "") + "\n" + String(ms))
    }
}

public enum LedgerError: Error, Equatable {
    case identifierKindMismatch(identifier: String)
}

public struct LedgerEntry: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case reminder, timer
    }

    public let identifier: String
    public let kind: Kind
    public let pingId: String?
    public let noteId: String?
    public let contentHash: String?

    public init(identifier: String, kind: Kind, pingId: String?, noteId: String?, contentHash: String?) {
        self.identifier = identifier
        self.kind = kind
        self.pingId = pingId
        self.noteId = noteId
        self.contentHash = contentHash
    }
}

/// The device-local record of every notification identifier the app has scheduled (FOC-R17).
/// Identifiers are `reminder:<pingId>:<uuid>` or `timer:<uuid>`; they never contain note text.
/// A row is written before the notification is added, so a crash in between leaves a known id,
/// and it stays until the notification is confirmed gone (`confirmGone`) or forgotten.
public struct NotificationLedger: Sendable {
    public static let categoryIdentifier = "reminder"
    public static let snoozeHourAction = "reminder.snooze.hour"
    public static let snoozeNineAction = "reminder.snooze.nine"

    /// Reminder lifecycle (cold-launch removal, reconcile) touches only rows of kind `reminder`
    /// whose identifier is also in the `reminder:` namespace; a malformed row is left alone.
    /// `substr` rather than `LIKE`, which ignores case.
    private static let inReminderNamespace = "substr(identifier, 1, 9) = 'reminder:'"

    let store: NoteStore

    public init(store: NoteStore) {
        self.store = store
    }

    public func entries() throws -> [LedgerEntry] {
        try store.db.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT identifier, kind, pingId, noteId, contentHash FROM notification_ledger ORDER BY recordedAt, identifier
                """).compactMap(Self.entry(from:))
        }
    }

    /// Records (or updates) one row. Call it before `UNUserNotificationCenter.add`.
    /// Throws `LedgerError.identifierKindMismatch` unless a reminder's identifier starts with
    /// `reminder:` and a timer's with `timer:`.
    public func record(_ entry: LedgerEntry, now: Date) throws {
        guard entry.identifier.hasPrefix(entry.kind.rawValue + ":") else {
            throw LedgerError.identifierKindMismatch(identifier: entry.identifier)
        }
        try store.db.pool.write { db in try Self.upsert(entry, now: now, in: db) }
    }

    public func forget(_ identifiers: [String]) throws {
        guard !identifiers.isEmpty else { return }
        try store.db.pool.write { db in
            for identifier in identifiers {
                try db.execute(sql: "DELETE FROM notification_ledger WHERE identifier = ?", arguments: [identifier])
            }
        }
    }

    /// What a cold launch removes by id before anything else runs: every `reminder:` identifier
    /// whose note is locked or gone, and every `reminder:` identifier when App Lock is enabled.
    /// Timers are never listed. Pure SQL; it does not talk to the notification center.
    public func coldLaunchRemovals(appLockEnabled: Bool) throws -> [String] {
        try store.db.pool.read { db in
            if appLockEnabled {
                return try String.fetchAll(db, sql: """
                    SELECT identifier FROM notification_ledger WHERE kind = 'reminder' AND \(Self.inReminderNamespace) ORDER BY recordedAt, identifier
                    """)
            }
            return try String.fetchAll(db, sql: """
                SELECT l.identifier FROM notification_ledger l LEFT JOIN note n ON n.id = l.noteId
                WHERE l.kind = 'reminder' AND \(Self.inReminderNamespace) AND (n.id IS NULL OR n.isLocked OR n.deletedAt IS NOT NULL)
                ORDER BY l.recordedAt, l.identifier
                """)
        }
    }

    /// Matches the plan against the ledger and returns what the scheduler must add and remove.
    /// - A planned notification whose (pingId, contentHash) matches a ledger row keeps that row's
    ///   identifier and is not added again.
    /// - Any other gets a new `reminder:<pingId>:<uuid>`, recorded here, in the same transaction,
    ///   before it is returned.
    /// - Every `reminder:` row no plan entry kept is in `remove`; timers never are. Removed rows
    ///   stay in the ledger until `confirmGone` or `forget`.
    /// - A note that is locked is never trusted as unchanged and its row has no hash (FOC-R17), so
    ///   its notification is rebuilt, title only, on every reconcile.
    public func reconcile(
        planned: [PlannedNotification], now: Date = .now
    ) throws -> (add: [(identifier: String, notification: PlannedNotification)], remove: [String]) {
        try store.db.pool.write { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT identifier, pingId, contentHash FROM notification_ledger
                WHERE kind = 'reminder' AND \(Self.inReminderNamespace) ORDER BY recordedAt, identifier
                """)
            var kept = Set<String>()
            var add: [(identifier: String, notification: PlannedNotification)] = []
            for item in planned {
                let locked = try Bool.fetchOne(db, sql: "SELECT isLocked FROM note WHERE id = ?", arguments: [item.noteId]) ?? true
                if !locked, let match = rows.first(where: {
                    let id: String = $0["identifier"]
                    let pingId: String? = $0["pingId"]
                    let hash: String? = $0["contentHash"]
                    return !kept.contains(id) && pingId == item.pingId && hash == item.contentHash
                }) {
                    kept.insert(match["identifier"] as String)
                    continue
                }
                let identifier = "reminder:\(item.pingId):\(UUIDv7.make(now: now))"
                try Self.upsert(
                    LedgerEntry(identifier: identifier, kind: .reminder, pingId: item.pingId, noteId: item.noteId,
                                contentHash: locked ? nil : item.contentHash),
                    now: now, in: db)
                kept.insert(identifier)
                add.append((identifier, item))
            }
            let remove = rows.map { $0["identifier"] as String }.filter { !kept.contains($0) }
            return (add, remove)
        }
    }

    /// The second line, after the cold-launch removal: the `reminder:` identifiers present in the
    /// notification center (pending or delivered) that no ledger row knows. Returns nothing when
    /// the ledger cannot be read, so a failed read never removes a reminder the user still wants.
    public func sweepUnknown(pending: Set<String>, delivered: Set<String>) -> [String] {
        let known: Set<String>
        do {
            known = try store.db.pool.read { db in
                Set(try String.fetchAll(db, sql: "SELECT identifier FROM notification_ledger"))
            }
        } catch {
            storeLogger.error("notification ledger unreadable during sweep")
            return []
        }
        return pending.union(delivered).filter { $0.hasPrefix("reminder:") && !known.contains($0) }.sorted()
    }

    /// The readback after removals: forgets the ledger rows whose identifier is in neither set.
    /// Call it only once pending adds have completed, or a just-recorded row looks absent.
    public func confirmGone(pending: Set<String>, delivered: Set<String>) throws {
        let present = pending.union(delivered)
        try store.db.pool.write { db in
            for identifier in try String.fetchAll(db, sql: "SELECT identifier FROM notification_ledger") where !present.contains(identifier) {
                try db.execute(sql: "DELETE FROM notification_ledger WHERE identifier = ?", arguments: [identifier])
            }
        }
    }

    private static func upsert(_ entry: LedgerEntry, now: Date, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO notification_ledger(identifier, kind, pingId, noteId, contentHash, recordedAt)
            VALUES(?, ?, ?, ?, ?, ?)
            ON CONFLICT(identifier) DO UPDATE SET
              kind = excluded.kind, pingId = excluded.pingId, noteId = excluded.noteId,
              contentHash = excluded.contentHash, recordedAt = excluded.recordedAt
            """, arguments: [entry.identifier, entry.kind.rawValue, entry.pingId, entry.noteId, entry.contentHash,
                             NoteStore.roundedToMillis(now)])
    }

    private static func entry(from row: Row) -> LedgerEntry? {
        guard let kind = LedgerEntry.Kind(rawValue: row["kind"]) else { return nil }
        return LedgerEntry(identifier: row["identifier"], kind: kind, pingId: row["pingId"], noteId: row["noteId"], contentHash: row["contentHash"])
    }
}
