// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

/// A reminder that is due. On a locked note it carries the title only: no line,
/// no caret position.
public struct ReminderCandidate: Equatable, Sendable {
    public let pingId: String
    public let noteId: String
    public let title: String
    /// The anchored line as a card shows it (`FocusClock.displayLine`); nil for a whole-note
    /// reminder, a locked note, or a line that is gone.
    public let lineText: String?
    /// UTF-16 offset of the start of the anchored line, for "Open" to scroll to.
    public let caretOffset: Int?
    public let isLocked: Bool

    public init(pingId: String, noteId: String, title: String, lineText: String?, caretOffset: Int?, isLocked: Bool) {
        self.pingId = pingId
        self.noteId = noteId
        self.title = title
        self.lineText = lineText
        self.caretOffset = caretOffset
        self.isLocked = isLocked
    }
}

/// The first open to-do of the note that was opened longest ago.
public struct TodoCandidate: Equatable, Sendable {
    public let noteId: String
    public let title: String
    /// Where the to-do is now; it follows the line when lines are added or removed above it.
    public let anchor: LineAnchor
    /// The line as a card shows it (`FocusClock.displayLine`).
    public let lineText: String
    /// UTF-16 offset of the start of the line.
    public let caretOffset: Int
    /// The note is read-only: the card offers no Done.
    public let isReadOnly: Bool

    public init(noteId: String, title: String, anchor: LineAnchor, lineText: String, caretOffset: Int, isReadOnly: Bool) {
        self.noteId = noteId
        self.title = title
        self.anchor = anchor
        self.lineText = lineText
        self.caretOffset = caretOffset
        self.isReadOnly = isReadOnly
    }
}

/// The oldest captured note nobody has opened since.
public struct NoteCandidate: Equatable, Sendable {
    public let noteId: String
    public let title: String

    public init(noteId: String, title: String) {
        self.noteId = noteId
        self.title = title
    }
}

public enum FocusCandidate: Equatable, Sendable {
    case reminder(ReminderCandidate)
    case todo(TodoCandidate)
    case capture(NoteCandidate)

    /// The `focus_hide.candidateKey` Later writes for it.
    public var key: String {
        switch self {
        case .reminder(let r): "ping:\(r.pingId)"
        case .todo(let t): "todo:\(t.noteId):\(t.anchor.line):\(t.anchor.hash)"
        case .capture(let c): "note:\(c.noteId)"
        }
    }

    public var noteId: String {
        switch self {
        case .reminder(let r): r.noteId
        case .todo(let t): t.noteId
        case .capture(let c): c.noteId
        }
    }
}

/// What Done changed: the note's text before and after, so one `undo` can put it back.
public struct TodoToggle: Equatable, Sendable {
    public let noteId: String
    public let before: String
    public let after: String

    public init(noteId: String, before: String, after: String) {
        self.noteId = noteId
        self.before = before
        self.after = after
    }
}

public enum FocusCardError: Error, Equatable {
    /// The note is read-only, so Done is not offered.
    case readOnly(noteId: String)
    /// The to-do is gone: its line was removed or edited, or the box is already checked.
    case todoGone(noteId: String)
    /// The note is not in Notes any more (Archive, Trash).
    case notInNotes(noteId: String)
}

/// The Next Up card (spec A3): one candidate at a time, picked from the pool in a
/// fixed order. Later and Not Today only write `focus_hide` rows, never the note (I4); a card read
/// deletes the expired ones. Locked notes never supply body text.
public struct FocusCard: Sendable {
    let store: NoteStore

    static let poolKey = "pool"
    static let untitled = "Untitled"

    public init(store: NoteStore) {
        self.store = store
    }

    // MARK: Reading

    /// The candidate to show at `now`, or nil when nothing is waiting (or the pool is hidden).
    /// Expired hides are deleted first.
    public func next(now: Date, calendar: Calendar = .current) throws -> FocusCandidate? {
        try purgeExpiredHides(at: now)
        return try candidate(at: now)
    }

    /// Deletes the hides that ended at or before `date` (every card read does). Reads
    /// first, so a read with nothing to delete takes no write lock.
    func purgeExpiredHides(at date: Date) throws {
        let cutoff = NoteStore.roundedToMillis(date)
        let anyExpired = try store.db.pool.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM focus_hide WHERE hiddenUntil <= ?)", arguments: [cutoff]) ?? false
        }
        guard anyExpired else { return }
        try store.db.pool.write { db in
            try db.execute(sql: "DELETE FROM focus_hide WHERE hiddenUntil <= ?", arguments: [cutoff])
        }
    }

    /// The candidate as it would be at `date`, from one read snapshot and without deleting
    /// anything: a hide counts only while `hiddenUntil > date`. `CardPublication` evaluates the
    /// timeline of later moments through it.
    func candidate(at date: Date) throws -> FocusCandidate? {
        let cutoff = NoteStore.roundedToMillis(date)
        return try store.db.pool.read { db in
            let hidden = Set(try String.fetchAll(
                db, sql: "SELECT candidateKey FROM focus_hide WHERE hiddenUntil > ?", arguments: [cutoff]))
            if hidden.contains(Self.poolKey) { return nil }
            if let reminder = try Self.dueReminder(at: cutoff, hidden: hidden, in: db) { return .reminder(reminder) }
            if let todo = try Self.firstTodo(hidden: hidden, in: db) { return .todo(todo) }
            if let capture = try Self.oldestCapture(hidden: hidden, in: db) { return .capture(capture) }
            return nil
        }
    }

    private static func dueReminder(at cutoff: Date, hidden: Set<String>, in db: Database) throws -> ReminderCandidate? {
        let rows = try Row.fetchCursor(db, sql: """
            SELECT p.id, p.noteId, p.anchorLine, p.anchorHash, n.title, n.isLocked,
                   CASE WHEN p.anchorLine IS NULL OR n.isLocked THEN NULL ELSE n.text END AS text
            FROM note_ping p JOIN note n ON n.id = p.noteId
            WHERE p.fireAt <= ? AND n.location = 'notes' AND n.deletedAt IS NULL
            ORDER BY p.fireAt, p.id
            """, arguments: [cutoff])
        while let row = try rows.next() {
            let id: String = row["id"]
            if hidden.contains("ping:\(id)") { continue }
            let title: String = row["title"]
            let isLocked: Bool = row["isLocked"]
            var lineText: String?
            var caretOffset: Int?
            let anchorLine: Int? = row["anchorLine"]
            let anchorHash: String? = row["anchorHash"]
            let text: String? = row["text"]
            if !isLocked, let anchorLine, let anchorHash, let text,
               let line = LineAnchor(line: anchorLine, hash: anchorHash).resolve(in: text) {
                let shown = LineAnchor.lineText(line, in: text).map(FocusClock.displayLine) ?? ""
                lineText = shown.isEmpty ? nil : shown
                caretOffset = LineAnchor.utf16Offset(ofLine: line, in: text)
            }
            return ReminderCandidate(
                pingId: id, noteId: row["noteId"], title: title.isEmpty ? untitled : title,
                lineText: lineText, caretOffset: caretOffset, isLocked: isLocked)
        }
        return nil
    }

    /// Notes with an open to-do, least recently opened first (`lastOpenedAt`, else `modifiedAt`).
    /// The first note that still has a to-do that is not hidden supplies it.
    private static func firstTodo(hidden: Set<String>, in db: Database) throws -> TodoCandidate? {
        let hiddenTodos = Self.hiddenTodoAnchors(hidden)
        let template = Templates.predicate()
        let notes = try Row.fetchCursor(db, sql: """
            SELECT n.id, n.title, n.isReadOnly
            FROM note n
            JOIN note_stats s ON s.noteId = n.id
            LEFT JOIN note_ui_state u ON u.noteId = n.id
            WHERE n.location = 'notes' AND NOT n.isLocked AND n.deletedAt IS NULL AND s.openTodos > 0
              AND NOT \(template.sql)
            ORDER BY COALESCE(u.lastOpenedAt, n.modifiedAt), n.id
            """, arguments: StatementArguments(template.arguments))
        while let row = try notes.next() {
            let id: String = row["id"]
            guard let text = try String.fetchOne(db, sql: "SELECT text FROM note WHERE id = ?", arguments: [id]) else { continue }
            let hiddenLines = Set((hiddenTodos[id] ?? []).compactMap { $0.resolve(in: text) })
            guard let todo = TodoLines.all(in: text).first(where: { !$0.isDone && !hiddenLines.contains($0.line) }),
                  let anchor = LineAnchor.at(line: todo.line, in: text),
                  let caret = LineAnchor.utf16Offset(ofLine: todo.line, in: text)
            else { continue }
            let title: String = row["title"]
            return TodoCandidate(
                noteId: id, title: title.isEmpty ? untitled : title, anchor: anchor,
                lineText: FocusClock.displayLine(todo.text), caretOffset: caret, isReadOnly: row["isReadOnly"])
        }
        return nil
    }

    private static func oldestCapture(hidden: Set<String>, in db: Database) throws -> NoteCandidate? {
        let rows = try Row.fetchCursor(db, sql: """
            SELECT n.id, n.title
            FROM note n LEFT JOIN note_ui_state u ON u.noteId = n.id
            WHERE n.captureSource IS NOT NULL AND u.lastOpenedAt IS NULL
              AND NOT n.isLocked AND n.location = 'notes' AND n.deletedAt IS NULL
            ORDER BY n.createdAt, n.id
            """)
        while let row = try rows.next() {
            let id: String = row["id"]
            if hidden.contains("note:\(id)") { continue }
            let title: String = row["title"]
            return NoteCandidate(noteId: id, title: title.isEmpty ? untitled : title)
        }
        return nil
    }

    /// `todo:<noteId>:<line>:<hash>` keys, grouped by note. The note id is everything before the
    /// last two colon-separated parts.
    private static func hiddenTodoAnchors(_ keys: Set<String>) -> [String: [LineAnchor]] {
        var result: [String: [LineAnchor]] = [:]
        for key in keys where key.hasPrefix("todo:") {
            let parts = key.dropFirst("todo:".count).split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count >= 3, let line = Int(parts[parts.count - 2]) else { continue }
            let hash = String(parts[parts.count - 1])
            let noteId = parts[0..<(parts.count - 2)].joined(separator: ":")
            result[noteId, default: []].append(LineAnchor(line: line, hash: hash))
        }
        return result
    }

    // MARK: Actions

    /// Later: hides `candidate` until the next local midnight. Writes no note.
    public func later(_ candidate: FocusCandidate, now: Date, calendar: Calendar = .current) throws {
        try hide(key: candidate.key, noteId: candidate.noteId, now: now, calendar: calendar)
    }

    /// Not Today: hides the whole pool until the next local midnight. Writes no note.
    public func notToday(now: Date, calendar: Calendar = .current) throws {
        try hide(key: Self.poolKey, noteId: nil, now: now, calendar: calendar)
    }

    private func hide(key: String, noteId: String?, now: Date, calendar: Calendar) throws {
        let until = NoteStore.roundedToMillis(FocusClock.nextLocalMidnight(after: now, calendar: calendar))
        try store.db.pool.write { db in
            // A note that is gone cannot own a row (foreign key); the hide then belongs to no note.
            let owner = try noteId.flatMap { id in
                try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM note WHERE id = ?)", arguments: [id]) == true ? id : nil
            }
            try db.execute(sql: """
                INSERT INTO focus_hide(candidateKey, noteId, hiddenUntil) VALUES(?, ?, ?)
                ON CONFLICT(candidateKey) DO UPDATE SET noteId = excluded.noteId, hiddenUntil = excluded.hiddenUntil
                """, arguments: [key, owner, until])
        }
    }

    /// Done: checks (or unchecks, if it is already checked) nothing but the one box of `todo`,
    /// through the normal text write (revision, `modifiedAt`, index). Throws `readOnly` for a
    /// read-only note and `todoGone` when the anchored line is no longer an open to-do.
    @discardableResult
    public func done(_ todo: TodoCandidate, now: Date = .now) throws -> TodoToggle {
        try store.write { db in
            let note = try NoteStore.require(todo.noteId, in: db)
            if note.isLocked { throw StoreError.noteLocked(id: note.id) }
            if note.deletedAt != nil || note.location != .notes { throw FocusCardError.notInNotes(noteId: note.id) }
            if note.isReadOnly { throw FocusCardError.readOnly(noteId: note.id) }
            guard let line = todo.anchor.resolve(in: note.text),
                  TodoLines.all(in: note.text).contains(where: { $0.line == line && !$0.isDone }),
                  let toggled = TodoLines.toggled(note.text, line: line)
            else { throw FocusCardError.todoGone(noteId: note.id) }
            _ = try NoteStore.writeText(
                id: note.id, text: toggled, expectedRevision: note.revision, now: now, in: db)
            return TodoToggle(noteId: note.id, before: note.text, after: toggled)
        }
    }

    /// Puts `toggle.before` back, but only while the note still reads exactly `toggle.after`: a
    /// further edit, a lock, a move out of Notes or a read-only flag makes it do nothing.
    @discardableResult
    public func undo(_ toggle: TodoToggle, now: Date = .now) throws -> Bool {
        try store.write { db in
            guard let note = try Note.fetchOne(db, key: toggle.noteId),
                  note.deletedAt == nil, note.location == .notes, !note.isLocked, !note.isReadOnly,
                  note.text == toggle.after
            else { return false }
            _ = try NoteStore.writeText(
                id: note.id, text: toggle.before, expectedRevision: note.revision, now: now, in: db)
            return true
        }
    }

    /// The user opened the candidate's note from the card. Records `lastOpenedAt` (which takes a
    /// capture out of the pool and sends a to-do's note to the back of the line) and, for a
    /// reminder, deletes it: opening handles it. A locked note stores no `lastOpenedAt`.
    public func opened(_ candidate: FocusCandidate, now: Date = .now) throws {
        if case .reminder(let reminder) = candidate { try store.handlePing(id: reminder.pingId) }
        try store.recordOpened(noteId: candidate.noteId, now: now)
    }
}
