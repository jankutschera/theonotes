// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

/// One attachment waiting for text recognition.
public struct OCRJob: Sendable, Hashable {
    public var noteId: String
    public var filename: String

    public init(noteId: String, filename: String) {
        self.noteId = noteId
        self.filename = filename
    }
}

/// What the recognizer found for a job.
public enum OCRResult: Sendable {
    /// Recognized text, with the file facts it was recognized from.
    case text(String, sha256: String, byteSize: Int, modifiedAt: Date)
    /// No text in the file (`sha256` when it was computed).
    case none(sha256: String?)
    /// The file could not be read or recognized (retried after `failedRetryInterval`, when the
    /// file changes, and when the recognizer version goes up).
    case failed
    /// Not recognized on purpose: too large (an unsupported type is `.none`).
    case skipped
    /// The file is not there (yet), e.g. still syncing; retried after `missingRetryInterval`.
    case missing
}

/// Size and modification date of a file when a job read it. A result is stored only for the file
/// these describe.
public struct OCRFileFacts: Sendable, Equatable {
    public var size: Int
    public var modifiedAt: Date

    public init(size: Int, modifiedAt: Date) {
        self.size = size
        self.modifiedAt = modifiedAt
    }

    /// Read with `attributesOfItem`: `URL.resourceValues` caches per URL object and would report
    /// the facts from before a replacement.
    public init?(url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              let modifiedAt = attributes[.modificationDate] as? Date else { return nil }
        self.init(size: size, modifiedAt: modifiedAt)
    }

    /// Same size and the same date to the millisecond (the database keeps milliseconds).
    public func matches(_ other: OCRFileFacts) -> Bool {
        size == other.size && abs(modifiedAt.timeIntervalSince(other.modifiedAt)) < 0.002
    }
}

enum OCRText {
    /// `text` cut to at most `limit` characters, at a word boundary when one is near (the cut only
    /// splits a word if the last max(32, limit / 10) characters hold no whitespace); trailing whitespace
    /// dropped.
    static func capped(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = text.prefix(limit)
        let next = text[text.index(text.startIndex, offsetBy: limit)]
        var cut = head
        if !next.isWhitespace, let space = head.lastIndex(where: \.isWhitespace),
           head.distance(from: space, to: head.endIndex) <= max(32, limit / 10) {
            cut = head[..<space]
        }
        return String(cut).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The OCR side of the `attachment` table (rows are created, tombstoned and revived by
/// `NoteIndexer`). Locked notes are never OCR'd: they have no pending jobs and `record` writes
/// nothing for them. All SQL is parameterized; nothing here logs note content.
public struct AttachmentTextStore: Sendable {
    /// The recognizer version stored with a result (`attachment.ocrVersion`); bump it when a
    /// better recognizer ships, so rows recognized by the old one can be re-queued.
    public static let recognizerVersion = 1

    /// Negative versions mark remote OCR imported under this local upgrade baseline, not a local recognition.
    static func adoptRemoteOCR(attachmentID: String, staged: AttachmentFiles.Staged, filename: String, in db: Database) throws {
        guard let entry = staged.entries.first(where: { $0.filename == filename }),
              let facts = OCRFileFacts(url: URL(fileURLWithPath: entry.path)) else { throw SyncQueueError.snapshotUnavailable }
        // Rename preserves staged mtime, so a failed upgrade can distinguish this file from changed bytes.
        try db.execute(sql: "UPDATE attachment SET ocrVersion=?,ocrAt=?,fileModifiedAt=? WHERE id=? AND byteSize=? AND ocrState='done' AND ocrText IS NOT NULL",
                       arguments: [-recognizerVersion, Date(), facts.modifiedAt, attachmentID, facts.size])
        guard db.changesCount == 1 else { throw SyncQueueError.snapshotUnavailable }
    }

    /// The most characters of recognized text kept per attachment (it goes into search, so it
    /// must not grow without bound).
    public static let maxTextLength = 200_000

    /// How long a `missing` row waits before `pendingJobs` offers it again. Missing rows are
    /// listed after every pending job, so a file that never arrives cannot starve the queue.
    public static let missingRetryInterval: TimeInterval = 10 * 60

    /// How long a `failed` row waits before `pendingJobs` offers it again, and how long a row whose
    /// re-run failed (it keeps its old text) waits. There is no retry counter (v7 is frozen), so
    /// the retries are bounded by this backoff.
    public static let failedRetryInterval: TimeInterval = 6 * 60 * 60

    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Jobs of live attachments of unlocked notes outside the trash, in this order: `pending` rows
    /// oldest first, then `done` and `none` rows recognized by an older recognizer
    /// (`ocrVersion` below `recognizerVersion`; their text stays searchable until the new result
    /// replaces it), then `failed` and `skipped` rows (on a version bump, or `failed` once
    /// `failedRetryInterval` has passed), then `missing` rows whose backoff
    /// (`missingRetryInterval` since `ocrAt`) has passed. A row that was re-run and failed again
    /// waits `failedRetryInterval` before it is offered again. That wait applies to the version-bump
    /// re-runs too: a `done`, `none`, `failed` or `skipped` row recognized less than
    /// `failedRetryInterval` ago waits it out after a recognizer bump, which spreads a re-OCR of the
    /// whole library over time instead of one storm (final review N2). Notes with a staged attachment
    /// batch (`staging_batch`) are skipped: replaced bytes are reset to pending before the new
    /// files are in place, so recognizing in that gap would record the old file's text.
    public func pendingJobs(limit: Int, now: Date = .now) throws -> [OCRJob] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT a.noteId, a.filename FROM attachment a JOIN note n ON n.id = a.noteId
                WHERE a.deletedAt IS NULL AND n.isLocked = 0 AND n.deletedAt IS NULL AND n.location != 'trash'
                    AND NOT EXISTS (SELECT 1 FROM staging_batch b WHERE b.noteId = a.noteId)
                    AND (a.ocrState = 'pending'
                        OR (a.ocrState IN ('done', 'none', 'failed', 'skipped')
                            AND (a.ocrVersion IS NULL OR abs(a.ocrVersion) < ?) AND (a.ocrAt IS NULL OR a.ocrAt <= ?))
                        OR (a.ocrState = 'failed' AND a.ocrAt <= ?)
                        OR (a.ocrState = 'missing' AND a.ocrAt <= ?))
                ORDER BY CASE a.ocrState WHEN 'pending' THEN 0 WHEN 'done' THEN 1 WHEN 'none' THEN 1
                    WHEN 'missing' THEN 3 ELSE 2 END, a.createdAt, a.rowid
                LIMIT ?
                """, arguments: [
                    Self.recognizerVersion, now.addingTimeInterval(-Self.failedRetryInterval),
                    now.addingTimeInterval(-Self.failedRetryInterval), now.addingTimeInterval(-Self.missingRetryInterval),
                    max(0, limit),
                ])
                .map { OCRJob(noteId: $0["noteId"], filename: $0["filename"]) }
        }
    }

    /// `failed` rows that wait out their backoff, with the file facts they failed on: the caller
    /// offers the ones whose file has changed since (a retry that needs no waiting). Only the
    /// `limit` rows that failed first are read: a changed file beyond that window is not offered
    /// early and waits at most `failedRetryInterval`, like any failed row (final review N1).
    public func failedJobsWithFacts(limit: Int, now: Date = .now) throws -> [(job: OCRJob, facts: OCRFileFacts)] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT a.noteId, a.filename, a.byteSize, a.fileModifiedAt FROM attachment a JOIN note n ON n.id = a.noteId
                WHERE a.deletedAt IS NULL AND n.isLocked = 0 AND n.deletedAt IS NULL AND n.location != 'trash'
                    AND NOT EXISTS (SELECT 1 FROM staging_batch b WHERE b.noteId = a.noteId)
                    AND a.ocrState = 'failed' AND a.ocrAt > ? AND a.byteSize IS NOT NULL AND a.fileModifiedAt IS NOT NULL
                ORDER BY a.ocrAt
                LIMIT ?
                """, arguments: [now.addingTimeInterval(-Self.failedRetryInterval), max(0, limit)])
                .map { (OCRJob(noteId: $0["noteId"], filename: $0["filename"]),
                        OCRFileFacts(size: $0["byteSize"], modifiedAt: $0["fileModifiedAt"])) }
        }
    }

    /// Whether an attachment batch of the note is committed but not installed yet.
    public func hasStagedBatch(noteId: String) throws -> Bool {
        try database.pool.read { try Self.hasStagedBatch(noteId: noteId, in: $0) }
    }

    private static func hasStagedBatch(noteId: String, in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db, sql: "SELECT EXISTS (SELECT 1 FROM staging_batch WHERE noteId = ?)", arguments: [noteId]) ?? false
    }

    /// Whether `job` may be recognized now: a live attachment of a note that is not locked, in
    /// the trash or deleted, and has no staged batch.
    public func isRunnable(_ job: OCRJob) throws -> Bool {
        try runnableToken(job) != nil
    }

    /// The attachment row's `updatedAt` when `job` may be recognized now (see `isRunnable`), else
    /// nil. Passed back to `record` as `expectingUpdatedAt`, so a result is dropped when the row
    /// changed (replaced bytes, unlink and re-link, lock) while the job ran.
    public func runnableToken(_ job: OCRJob) throws -> Date? {
        try database.pool.read { db in
            try Date.fetchOne(db, sql: """
                SELECT a.updatedAt FROM attachment a JOIN note n ON n.id = a.noteId
                WHERE a.noteId = ? AND a.filenameKey = ? AND a.deletedAt IS NULL AND n.isLocked = 0
                    AND n.deletedAt IS NULL AND n.location != 'trash'
                    AND NOT EXISTS (SELECT 1 FROM staging_batch b WHERE b.noteId = a.noteId)
                """, arguments: [job.noteId, AttachmentFiles.fileSystemKey(job.filename)])
        }
    }

    /// Live attachments of the note that wait for recognition, regardless of backoff: `pending`
    /// rows and `done`/`none` rows from an older recognizer, oldest first; none while the note is
    /// locked, trashed or staging. `failed`, `skipped` and `missing` rows are not included: they
    /// wait for the background pass (`pendingJobs(limit:)`) and its backoffs.
    public func pendingJobs(noteId: String) throws -> [OCRJob] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT a.noteId, a.filename FROM attachment a JOIN note n ON n.id = a.noteId
                WHERE a.noteId = ? AND a.deletedAt IS NULL AND n.isLocked = 0 AND n.deletedAt IS NULL
                    AND n.location != 'trash'
                    AND NOT EXISTS (SELECT 1 FROM staging_batch b WHERE b.noteId = a.noteId)
                    AND (a.ocrState = 'pending' OR (a.ocrState IN ('done', 'none') AND abs(a.ocrVersion) < ?))
                ORDER BY a.createdAt, a.rowid
                """, arguments: [noteId, Self.recognizerVersion])
                .map { OCRJob(noteId: $0["noteId"], filename: $0["filename"]) }
        }
    }

    /// Stores a result and refreshes the note's search content. Writes nothing when, inside the
    /// write transaction, the note has been locked, trashed or deleted, has a staged batch (the
    /// result may come from bytes about to be replaced), the attachment has left the note, or the
    /// row's `updatedAt` is no longer `expectingUpdatedAt` (when given). Recognized text is
    /// capped at `maxTextLength`.
    ///
    /// `facts` are the file's size and date when the job read it. They are stored with `failed`
    /// and `skipped` results. A `failed` result on a row that holds text for exactly that file, or a
    /// `missing` result on a row that holds text, keeps the text (a failed re-run must not blank search); only `ocrAt`
    /// moves, so the retry waits out `failedRetryInterval`.
    public func record(
        _ job: OCRJob, result: OCRResult, recognizerVersion: Int = recognizerVersion, facts: OCRFileFacts? = nil,
        expectingUpdatedAt: Date? = nil
    ) throws {
        try database.pool.write { db in
            guard let note = try Row.fetchOne(
                db, sql: "SELECT text, isLocked, deletedAt, location FROM note WHERE id = ?", arguments: [job.noteId]
            ), !(note["isLocked"] as Bool), (note["deletedAt"] as Date?) == nil, (note["location"] as String) != "trash",
               try !Self.hasStagedBatch(noteId: job.noteId, in: db) else { return }

            let key = AttachmentFiles.fileSystemKey(job.filename)
            guard let row = try Row.fetchOne(db, sql: """
                SELECT ocrState, ocrText, byteSize, fileModifiedAt, updatedAt FROM attachment
                WHERE noteId = ? AND filenameKey = ? AND deletedAt IS NULL
                """, arguments: [job.noteId, key]) else { return }
            if let expectingUpdatedAt, (row["updatedAt"] as Date) != expectingUpdatedAt { return }

            let now = Date()
            switch result {
            case let .text(text, sha256, byteSize, modifiedAt):
                try db.execute(sql: """
                    UPDATE attachment SET ocrState = 'done', ocrText = ?, ocrAt = ?, ocrVersion = ?, sha256 = ?,
                        byteSize = ?, fileModifiedAt = ?, updatedAt = ?
                    WHERE noteId = ? AND filenameKey = ? AND deletedAt IS NULL
                    """, arguments: [
                        OCRText.capped(text, to: Self.maxTextLength), now, recognizerVersion, sha256, byteSize, modifiedAt,
                        now, job.noteId, key,
                    ])
            case let .none(sha256):
                try db.execute(sql: """
                    UPDATE attachment SET ocrState = 'none', ocrText = NULL, ocrAt = ?, ocrVersion = ?,
                        sha256 = COALESCE(?, sha256), updatedAt = ?
                    WHERE noteId = ? AND filenameKey = ? AND deletedAt IS NULL
                    """, arguments: [now, recognizerVersion, sha256, now, job.noteId, key])
            case .failed, .missing:
                let hasText = (row["ocrState"] as String) == "done" && (row["ocrText"] as String?) != nil
                var sameFile = false
                if case .missing = result {
                    sameFile = true // no file to compare: it may only be late (syncing)
                } else if let facts {
                    if let size = row["byteSize"] as Int?, let modifiedAt = row["fileModifiedAt"] as Date? {
                        sameFile = facts.matches(OCRFileFacts(size: size, modifiedAt: modifiedAt))
                    }
                }
                if hasText, sameFile {
                    try db.execute(sql: """
                        UPDATE attachment SET ocrAt = ?, updatedAt = ? WHERE noteId = ? AND filenameKey = ? AND deletedAt IS NULL
                        """, arguments: [now, now, job.noteId, key])
                    return
                }
                if case .failed = result {
                    try Self.setState("failed", version: recognizerVersion, facts: facts, job: job, key: key, now: now, in: db)
                } else {
                    try Self.setState("missing", version: nil, facts: nil, job: job, key: key, now: now, in: db)
                }
            case .skipped:
                try Self.setState("skipped", version: recognizerVersion, facts: facts, job: job, key: key, now: now, in: db)
            }
            guard db.changesCount > 0 else { return }
            try NoteIndexer.refreshOCRSearchText(noteId: job.noteId, text: note["text"], in: db)
        }
    }

    private static func setState(
        _ state: String, version: Int?, facts: OCRFileFacts?, job: OCRJob, key: String, now: Date, in db: Database
    ) throws {
        try db.execute(sql: """
            UPDATE attachment SET ocrState = ?, ocrText = NULL, ocrAt = ?, ocrVersion = ?, byteSize = ?,
                fileModifiedAt = ?, updatedAt = ?
            WHERE noteId = ? AND filenameKey = ? AND deletedAt IS NULL
            """, arguments: [state, now, version, facts?.size, facts?.modifiedAt, now, job.noteId, key])
    }

    /// Recognized text of any already-recognized file with this content hash (a copied or
    /// re-imported attachment needs no second pass). Never from a locked or deleted note, nor
    /// from text whose local recognition or remote-import baseline predates `recognizerVersion`.
    public func reusableText(sha256: String) throws -> String? {
        try database.pool.read { db in
            try String.fetchOne(db, sql: """
                SELECT a.ocrText FROM attachment a JOIN note n ON n.id = a.noteId
                WHERE a.sha256 = ? AND a.ocrState = 'done' AND a.ocrText IS NOT NULL AND abs(a.ocrVersion) >= ?
                    AND n.isLocked = 0 AND n.deletedAt IS NULL
                ORDER BY a.ocrAt DESC
                LIMIT 1
                """, arguments: [sha256, Self.recognizerVersion])
        }
    }
}
