// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

/// Writes everything derived from a note's text into the database. Callers run it inside the
/// same write transaction that stores the text, so the derived rows never lag behind.
public enum NoteIndexer {
    /// Updates `note.title/titleKey/subtitle` and replaces the note's `note_tag` (direct tags plus
    /// materialized ancestors), `wiki_link`, `heading` and `note_stats` rows. Per-tag pins for tags
    /// the note no longer carries are dropped, then orphan tags are deleted. Then syncs the note's
    /// `attachment` rows and finally writes its `note_search_content` row (FTS indexes follow via
    /// triggers).
    @discardableResult
    public static func index(noteId: String, text: String, in db: Database) throws -> NoteMetadata {
        let meta = NoteParser.metadata(for: text)
        let isLocked = try Bool.fetchOne(db, sql: "SELECT isLocked FROM note WHERE id = ?", arguments: [noteId]) ?? false
        if isLocked {
            // Index rebuilding must preserve the visible title and tags while never deriving
            // plaintext headings, previews, links or statistics from an authorized session.
            try db.execute(sql: "UPDATE note SET subtitle = '' WHERE id = ?", arguments: [noteId])
            try db.execute(sql: "DELETE FROM heading WHERE noteId = ?", arguments: [noteId])
            try db.execute(sql: "DELETE FROM wiki_link WHERE sourceNoteId = ?", arguments: [noteId])
            try db.execute(sql: "DELETE FROM note_stats WHERE noteId = ?", arguments: [noteId])
        } else {
            try writeDerivedRows(meta, noteId: noteId, in: db)
            // Here and not in `writeDerivedRows`: migration v2b runs that before the column exists (v19 backfills itself).
            // A locked note keeps the type it had, like its tag rows.
            try db.execute(sql: "UPDATE note SET noteType = ? WHERE id = ?",
                           arguments: [NoteType.of(directTags: meta.tags)?.rawValue, noteId])
        }
        try writeAttachments(meta, noteId: noteId, isLocked: isLocked, in: db)
        try writeSearchContent(meta, text: text, noteId: noteId, isLocked: isLocked, in: db)
        return meta
    }

    /// Only the tables that exist as of migration `v2b`, which calls this before
    /// `note_search_content` exists (migration `v4` backfills search content on its own).
    static func indexWithoutSearch(noteId: String, text: String, in db: Database) throws {
        try writeDerivedRows(NoteParser.metadata(for: text), noteId: noteId, in: db)
    }

    private static func writeDerivedRows(_ meta: NoteMetadata, noteId: String, in db: Database) throws {
        try db.execute(
            sql: "UPDATE note SET title = ?, titleKey = ?, subtitle = ? WHERE id = ?",
            arguments: [meta.title, TitleKey.make(meta.title), meta.subtitle, noteId]
        )
        guard db.changesCount > 0 else { throw StoreError.noteNotFound(id: noteId) }

        try writeTags(meta.tags, noteId: noteId, in: db)
        try writeLinks(meta.wikiLinks, noteId: noteId, in: db)
        try writeHeadings(meta.headings, noteId: noteId, in: db)
        try writeStats(meta, noteId: noteId, in: db)
        try db.execute(
            sql: """
                DELETE FROM note_pin WHERE noteId = ?
                    AND tagId NOT IN (SELECT tagId FROM note_tag WHERE noteId = ?)
                """,
            arguments: [noteId, noteId]
        )
        try removeOrphanTags(in: db)
    }

    /// One row per unlocked note (a locked note's text is `''` and it must not be findable, so its
    /// row is deleted). Columns hold `SearchText.fold` of the title, the raw text (Bear searches the
    /// Markdown source, markup and link URLs included), the attachment names and the recognized
    /// text of the note's attachments (`writeAttachments` ran first). An upsert keeps
    /// the row's `rowid` — the FTS key — stable and fires the UPDATE trigger; `INSERT OR REPLACE` would delete without firing the DELETE trigger. Rows
    /// whose content is unchanged are not rewritten.
    private static func writeSearchContent(
        _ meta: NoteMetadata, text: String, noteId: String, isLocked: Bool, in db: Database
    ) throws {
        if isLocked {
            try db.execute(sql: "DELETE FROM note_search_content WHERE noteId = ?", arguments: [noteId])
            return
        }
        let ocr = try ocrSearchText(noteId: noteId, filenames: meta.attachments.map(\.filename), in: db)
        try db.execute(
            sql: """
                INSERT INTO note_search_content (noteId, title, body, attachmentNames, ocrText) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(noteId) DO UPDATE SET
                    title = excluded.title, body = excluded.body, attachmentNames = excluded.attachmentNames,
                    ocrText = excluded.ocrText
                WHERE title IS NOT excluded.title OR body IS NOT excluded.body
                    OR attachmentNames IS NOT excluded.attachmentNames OR ocrText IS NOT excluded.ocrText
                """,
            arguments: [
                noteId, SearchText.fold(meta.title), SearchText.fold(text),
                SearchText.fold(meta.attachments.map(\.filename).joined(separator: " ")), ocr,
            ]
        )
    }

    /// Keeps the note's `attachment` rows in step with the links in its text. Rows are keyed by
    /// `AttachmentFiles.fileSystemKey` (case and normalization insensitive). A missing row is
    /// inserted as `pending` (UUIDv7 `id`); a row whose link left the text becomes a tombstone
    /// (`deletedAt`), and a re-link revives it with the same `id` and its OCR text (the
    /// app-only R23 cleanup purges tombstones once the file is gone). A locked note is never
    /// OCR'd: its text is `''` while locked, so rows cannot be derived; every row becomes `locked`
    /// and loses its plaintext facts (hash, size, dates, type, dimensions, recognized text). Back on
    /// an unlocked note only the `locked` rows return to `pending`; a `skipped` row stays.
    private static func writeAttachments(_ meta: NoteMetadata, noteId: String, isLocked: Bool, in db: Database) throws {
        let now = Date()
        if isLocked {
            try db.execute(
                sql: """
                    UPDATE attachment SET ocrState = 'locked', ocrText = NULL, ocrAt = NULL, ocrVersion = NULL,
                        sha256 = NULL, byteSize = NULL, fileModifiedAt = NULL, uti = NULL, width = NULL, height = NULL,
                        updatedAt = ?
                    WHERE noteId = ? AND (ocrState != 'locked' OR ocrText IS NOT NULL OR ocrAt IS NOT NULL
                        OR ocrVersion IS NOT NULL OR sha256 IS NOT NULL OR byteSize IS NOT NULL
                        OR fileModifiedAt IS NOT NULL OR uti IS NOT NULL OR width IS NOT NULL OR height IS NOT NULL)
                    """,
                arguments: [now, noteId]
            )
            return
        }
        var wanted: [(key: String, filename: String)] = []
        var seen = Set<String>()
        for ref in meta.attachments {
            let key = AttachmentFiles.fileSystemKey(ref.filename)
            if seen.insert(key).inserted { wanted.append((key, ref.filename)) }
        }
        var existing: [String: (filename: String, deleted: Bool)] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT filenameKey, filename, deletedAt FROM attachment WHERE noteId = ?",
                                    arguments: [noteId]) {
            existing[row["filenameKey"]] = (row["filename"], (row["deletedAt"] as Date?) != nil)
        }
        for key in existing.keys where !seen.contains(key) && existing[key]!.deleted == false {
            try db.execute(
                sql: "UPDATE attachment SET deletedAt = ?, updatedAt = ? WHERE noteId = ? AND filenameKey = ?",
                arguments: [now, now, noteId, key]
            )
        }
        for (key, filename) in wanted {
            if let row = existing[key] {
                guard row.deleted || row.filename != filename else { continue }
                try db.execute(
                    sql: "UPDATE attachment SET deletedAt = NULL, filename = ?, updatedAt = ? WHERE noteId = ? AND filenameKey = ?",
                    arguments: [filename, now, noteId, key]
                )
            } else {
                try db.execute(
                    sql: """
                        INSERT INTO attachment (id, noteId, filename, filenameKey, createdAt, updatedAt)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [UUIDv7.make(now: now), noteId, filename, key, now, now]
                )
            }
        }
        try db.execute(
            sql: "UPDATE attachment SET ocrState = 'pending', updatedAt = ? WHERE noteId = ? AND ocrState = 'locked'",
            arguments: [now, noteId]
        )
    }

    /// `SearchText.fold` of the recognized text of the given attachments (live `done` rows only),
    /// in the given (text) order, joined by `\n`.
    static func ocrSearchText(noteId: String, filenames: [String], in db: Database) throws -> String {
        let rows = try Row.fetchAll(db, sql: """
            SELECT filenameKey, ocrText FROM attachment
            WHERE noteId = ? AND ocrState = 'done' AND ocrText IS NOT NULL AND deletedAt IS NULL
            """, arguments: [noteId])
        var byKey: [String: String] = [:]
        for row in rows { byKey[row["filenameKey"]] = row["ocrText"] }
        var seen = Set<String>()
        return filenames.map(AttachmentFiles.fileSystemKey).filter { seen.insert($0).inserted }
            .compactMap { byKey[$0].map(SearchText.fold) }
            .joined(separator: "\n")
    }

    /// Rewrites only `note_search_content.ocrText` after OCR results changed the attachment rows.
    /// A note without a search content row (locked) is left alone.
    static func refreshOCRSearchText(noteId: String, text: String, in db: Database) throws {
        let filenames = NoteParser.metadata(for: text).attachments.map(\.filename)
        let ocr = try ocrSearchText(noteId: noteId, filenames: filenames, in: db)
        try db.execute(
            sql: "UPDATE note_search_content SET ocrText = ? WHERE noteId = ? AND ocrText IS NOT ?",
            arguments: [ocr, noteId, ocr]
        )
    }

    /// Deletes tags no note carries, that are not pinned and that no per-tag pin references.
    static func removeOrphanTags(in db: Database) throws {
        try db.execute(sql: """
            DELETE FROM tag WHERE isPinned = 0
                AND NOT EXISTS (SELECT 1 FROM note_tag WHERE note_tag.tagId = tag.id)
                AND NOT EXISTS (SELECT 1 FROM note_pin WHERE note_pin.tagId = tag.id)
            """)
    }

    /// Tag rows and the note type of a locked note, whose tags come from its sealed payload and not from `index`.
    static func writeLockedTags(_ tags: [String], noteId: String, in db: Database) throws {
        try writeTags(tags, noteId: noteId, in: db)
        try db.execute(sql: "UPDATE note SET noteType = ? WHERE id = ?",
                       arguments: [NoteType.of(directTags: tags)?.rawValue, noteId])
    }

    /// `a/b` direct → `a` (isDirect 0) + `a/b` (isDirect 1). A new tag row takes the first-seen
    /// spelling as `displayPath`; an existing row keeps its spelling.
    static func writeTags(_ tags: [String], noteId: String, in db: Database) throws {
        var order: [String] = []
        var entries: [String: (display: String, isDirect: Bool)] = [:]
        for tag in tags {
            let paths = TagScanner.ancestorPaths(of: tag)
            for (i, path) in paths.enumerated() {
                let key = CanonicalKey.make(path)
                let isDirect = i == paths.count - 1
                if let existing = entries[key] {
                    entries[key] = (existing.display, existing.isDirect || isDirect)
                } else {
                    order.append(key)
                    entries[key] = (path, isDirect)
                }
            }
        }

        try db.execute(sql: "DELETE FROM note_tag WHERE noteId = ?", arguments: [noteId])
        for key in order {
            let entry = entries[key]!
            try db.execute(
                sql: "INSERT INTO tag (id, pathKey, displayPath) VALUES (?, ?, ?) ON CONFLICT(pathKey) DO NOTHING",
                arguments: [UUIDv7.make(), key, entry.display]
            )
            let tagId = try String.fetchOne(db, sql: "SELECT id FROM tag WHERE pathKey = ?", arguments: [key])!
            try db.execute(
                sql: "INSERT INTO note_tag (noteId, tagId, isDirect) VALUES (?, ?, ?)",
                arguments: [noteId, tagId, entry.isDirect]
            )
        }
    }

    private static func writeLinks(_ links: [WikiLinkRef], noteId: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM wiki_link WHERE sourceNoteId = ?", arguments: [noteId])
        for (ordinal, link) in links.enumerated() {
            try db.execute(
                sql: """
                    INSERT INTO wiki_link (sourceNoteId, ordinal, targetKey, targetTitle, targetHeading, alias)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [noteId, ordinal, TitleKey.make(link.target), link.target, link.heading, link.alias]
            )
        }
    }

    private static func writeHeadings(_ headings: [HeadingRef], noteId: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM heading WHERE noteId = ?", arguments: [noteId])
        for (ordinal, heading) in headings.enumerated() {
            try db.execute(
                sql: "INSERT INTO heading (noteId, ordinal, level, text, line) VALUES (?, ?, ?, ?, ?)",
                arguments: [noteId, ordinal, heading.level, heading.text, heading.line]
            )
        }
    }

    /// `hasCode` = a fenced code block (the `@code` search operator).
    /// `attachmentNames` = attachment filenames joined by `\n` (for search).
    private static func writeStats(_ meta: NoteMetadata, noteId: String, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT OR REPLACE INTO note_stats
                    (noteId, openTodos, doneTodos, hasCode, hasImages, hasFiles, isEmpty, attachmentNames, firstImage)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                noteId, meta.openTodos, meta.doneTodos, meta.hasCode,
                meta.attachments.contains { $0.isImage }, meta.attachments.contains { !$0.isImage },
                meta.isEmpty, meta.attachments.map(\.filename).joined(separator: "\n"),
                meta.attachments.first { $0.isImage }?.filename,
            ]
        )
    }
}
