// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// The fixture library of spec section 9 for the Next Up card: a known open to-do, a capture
/// nobody opened, a locked note that had a to-do, and a note without any.
///
/// | Note       | Text                                   | State                                    |
/// |------------|----------------------------------------|------------------------------------------|
/// | Old todo   | `# Old todo` / `- [ ] Call Anna`       | created and opened 10 days ago           |
/// | Captured   | `# Captured` / `shared words`          | `.share`, never opened, 2 days old       |
/// | Secret     | `# Secret` / `- [ ] move the money`    | `.command`, 20 days old, then locked     |
/// | Plain      | `# Plain` / `just words`               | created 5 days ago, no to-do, no capture |
///
/// Everything is relative to `now` (2027-01-15 08:00 UTC). Libraries live under the temp folder.
struct FocusFixtureLibrary {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func ago(days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
    static func at(hours: Double) -> Date { now.addingTimeInterval(hours * 3600) }

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    let library: PrivacyTestLibrary
    let access: LockedNoteAccess
    let oldTodo: Note
    let captured: Note
    let secret: Note
    let plain: Note

    var store: NoteStore { library.store }
    var card: FocusCard { FocusCard(store: library.store) }

    /// `secretReminderAt` puts a reminder on line 2 of Secret before it is locked, so the lock
    /// collapses it to the title.
    init(secretReminderAt: Date? = nil) throws {
        library = try PrivacyTestLibrary()
        access = try library.access()
        let store = library.store
        oldTodo = try store.create(text: "# Old todo\n- [ ] Call Anna", now: Self.ago(days: 10))
        try store.recordOpened(noteId: oldTodo.id, now: Self.ago(days: 10))
        captured = try store.create(text: "# Captured\nshared words", now: Self.ago(days: 2), captureSource: .share)
        let secret = try store.create(
            text: "# Secret\n- [ ] move the money", now: Self.ago(days: 20), captureSource: .command)
        if let secretReminderAt {
            let anchor = try #require(LineAnchor.at(line: 2, in: secret.text))
            try store.setPing(noteId: secret.id, anchor: anchor, fireAt: secretReminderAt, now: Self.ago(days: 20))
        }
        try access.lock(noteId: secret.id)
        self.secret = try #require(try store.note(id: secret.id))
        plain = try store.create(text: "# Plain\njust words", now: Self.ago(days: 5))
    }

    func cleanup() {
        access.revoke()
        library.cleanup()
    }

    /// Every note row, to prove an action wrote none of them (I4).
    func allNotes() throws -> [Note] {
        try library.db.pool.read { try Note.order(Column("id")).fetchAll($0) }
    }

    func hideCount() throws -> Int {
        try library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM focus_hide") ?? 0 }
    }
}
