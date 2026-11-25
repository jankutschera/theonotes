// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// Rehearsal 1 of the identity flip (stage-2 plan B6, REN2-R52): the one check that needs library code and cannot be
/// done with `sqlite3`. `scripts/rehearse-identity-flip.sh` runs it inside a throw-away build with the flipped
/// bundle root, against an OLD `.baerchen-backup` from a COPY of the library, and restores it into a second temporary
/// library. It prints no note text, titles or tag names: only counts go to the JSON file named by
/// `THEONOTES_REHEARSAL_OUT`. Without the two variables the test is skipped, so a normal test run never reads a
/// library or a backup it was not given.
@Suite struct FlipRehearsalChecks {
    private static let environment = ProcessInfo.processInfo.environment
    private static let archive = environment["THEONOTES_REHEARSAL_BACKUP"]
    private static let output = environment["THEONOTES_REHEARSAL_OUT"]

    @Test(.enabled(if: archive != nil && output != nil, "set by scripts/rehearse-identity-flip.sh"))
    func test_old_backup_restores_into_a_second_library() throws {
        let archive = URL(fileURLWithPath: try #require(Self.archive))
        let out = URL(fileURLWithPath: try #require(Self.output))
        #expect(archive.pathExtension == LegacyNames.backupExtension, "the rehearsal restores an OLD-type archive")
        let second = try LibraryBackupTests.Library()
        defer { second.cleanup() }

        let summary = try second.backup.inspect(archive)
        let result = try second.backup.restore(archive, mode: .merge)
        let counts = try second.db.pool.read { db in
            (notes: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note") ?? -1,
             locked: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note WHERE isLocked = 1") ?? -1,
             tags: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag") ?? -1,
             attachments: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM attachment WHERE deletedAt IS NULL") ?? -1,
             envelope: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM crypto_envelope") ?? -1,
             quick: try String.fetchOne(db, sql: "PRAGMA quick_check") ?? "?")
        }
        #expect(result.restored == summary.noteCount)
        #expect(result.keptExisting == 0)
        #expect(counts.notes == summary.noteCount)
        #expect(counts.locked == summary.lockedNoteCount)
        #expect(counts.quick == "ok")
        if summary.lockedNoteCount > 0 { #expect(counts.envelope == 1, "the vault envelope came along with the locked notes") }

        let report: [String: Any] = [
            "archiveNotes": summary.noteCount, "archiveLocked": summary.lockedNoteCount,
            "archiveAttachments": summary.attachmentCount, "restored": result.restored,
            "notes": counts.notes, "locked": counts.locked, "tags": counts.tags,
            "attachments": counts.attachments, "envelopeRows": counts.envelope, "quickCheck": counts.quick,
            "notesEqual": counts.notes == summary.noteCount, "lockedEqual": counts.locked == summary.lockedNoteCount,
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: out)
    }
}
