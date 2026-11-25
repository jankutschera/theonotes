// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// Focus state for the backup tests (C9): a note with a capture source, an open time, two
/// reminders, hides and snapshots, and a locked note with a reminder and sealed snapshots.
enum FocusBackupSupport {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let password = "backup-focus-password"

    struct Seeded {
        let plain: Note
        let secret: Note
        let anchoredPing: Ping
        let wholePing: Ping
        let secretPing: Ping
        let plainSnapshots: [String]
        let secretSnapshots: [String]
        let access: LockedNoteAccess
    }

    static func hash(of line: Int, in note: Note) -> String {
        LineAnchor.at(line: line, in: note.text)!.hash
    }

    static func millis(_ seconds: Double) -> Date { NoteStore.roundedToMillis(t0.addingTimeInterval(seconds)) }

    /// `plain` and `secret` are notes of `store`; `secret` is locked at the end.
    static func seed(store: NoteStore, plain: Note, secret: Note, password: String = password) throws -> Seeded {
        try store.db.pool.write { db in
            try db.execute(sql: "UPDATE note SET captureSource='voice' WHERE id=?", arguments: [plain.id])
            try db.execute(sql: "UPDATE note SET captureSource='command' WHERE id=?", arguments: [secret.id])
        }
        try store.recordOpened(noteId: plain.id, now: millis(10))
        let anchor = try #require(LineAnchor.at(line: 2, in: plain.text))
        let anchored = try store.setPing(noteId: plain.id, anchor: anchor, fireAt: millis(3600), now: millis(0))
        let whole = try store.setPing(noteId: plain.id, anchor: nil, fireAt: millis(7200), now: millis(0))
        let secretPing = try store.setPing(noteId: secret.id, anchor: nil, fireAt: millis(100), now: millis(0))
        let plainTexts = ["\(plain.text)\nplain snapshot one", "\(plain.text)\nplain snapshot two"]
        for (index, text) in plainTexts.enumerated() {
            _ = try #require(try store.takeSnapshot(noteId: plain.id, text: text, now: millis(60 * Double(index + 1))))
        }
        let secretTexts = ["\(secret.text)\nsecret snapshot one", "\(secret.text)\nsecret snapshot two"]
        for (index, text) in secretTexts.enumerated() {
            _ = try #require(try store.takeSnapshot(noteId: secret.id, text: text, now: millis(60 * Double(index + 1))))
        }
        try store.db.pool.write { db in
            try db.execute(sql: "UPDATE note_ping SET firedAt=? WHERE id=?", arguments: [millis(7300), whole.id])
            let hidden = millis(86_400)
            for key in ["note:\(plain.id)", "todo:\(plain.id):2:\(hash(of: 2, in: plain))", "ping:\(anchored.id)"] {
                try db.execute(sql: "INSERT INTO focus_hide(candidateKey,noteId,hiddenUntil) VALUES(?,?,?)", arguments: [key, plain.id, hidden])
            }
            try db.execute(sql: "INSERT INTO focus_hide(candidateKey,noteId,hiddenUntil) VALUES('pool',NULL,?)", arguments: [millis(172_800)])
        }
        let access = try NotePrivacy(store: store).setPassword(password)
        try access.lock(noteId: secret.id)
        return Seeded(plain: plain, secret: try #require(try store.note(id: secret.id)), anchoredPing: anchored, wholePing: whole,
                      secretPing: secretPing, plainSnapshots: plainTexts, secretSnapshots: secretTexts, access: access)
    }

    private static func dv(_ row: Row, _ column: String) -> String { (row[column] as DatabaseValue).description }

    /// Every focus row of a library as comparable lines (sealed snapshots by their bytes).
    static func dump(_ db: AppDatabase) throws -> [String] {
        try db.pool.read { db in
            var lines: [String] = []
            for row in try Row.fetchAll(db, sql: "SELECT id, captureSource FROM note ORDER BY id") {
                lines.append("capture \(row["id"] as String) \(row["captureSource"] as String? ?? "-")")
            }
            for row in try Row.fetchAll(db, sql: "SELECT noteId, lastOpenedAt FROM note_ui_state ORDER BY noteId") {
                lines.append("opened \(row["noteId"] as String) \(dv(row, "lastOpenedAt"))")
            }
            for row in try Row.fetchAll(db, sql: "SELECT * FROM note_ping ORDER BY id") {
                lines.append("ping \(row["id"] as String) \(row["noteId"] as String) \(row["anchorLine"] as Int? ?? 0) \(row["anchorHash"] as String? ?? "-") "
                    + "\(dv(row, "fireAt")) \(dv(row, "firedAt")) \(dv(row, "createdAt"))")
            }
            for row in try Row.fetchAll(db, sql: "SELECT * FROM focus_hide ORDER BY candidateKey") {
                lines.append("hide \(row["candidateKey"] as String) \(row["noteId"] as String? ?? "-") \(dv(row, "hiddenUntil"))")
            }
            for row in try Row.fetchAll(db, sql: "SELECT * FROM note_snapshot ORDER BY id") {
                lines.append("snapshot \(row["id"] as String) \(row["noteId"] as String) \(dv(row, "takenAt")) "
                    + "\(row["text"] as String? ?? "-") \((row["sealedText"] as Data?)?.base64EncodedString() ?? "-")")
            }
            return lines
        }
    }

    /// The archive's extracted record of a note, as JSON.
    static func record(_ tree: URL, _ noteId: String) throws -> [String: Any] {
        let data = try Data(contentsOf: tree.appendingPathComponent(noteId + ".textbundle/record.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func extract(_ archive: URL, into parent: URL) throws -> URL {
        let tree = parent.appendingPathComponent("extract-\(UUID())")
        try PortableZIP.extract(archive, to: tree)
        return tree
    }
}
