// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

/// Where a wiki link points (spec §3.5, ruling R16). The single place that decides it — link
/// navigation (`NoteStore.wikiLinkTargetId`), backlinks (`resolvedLinkTargetId`) and the
/// title-change rewrite all use this rule:
///
/// - The target title matches a note's `titleKey` (`TitleKey`: whitespace runs collapsed and
///   trimmed, NFC + Unicode case folding, so case-insensitive; diacritics count). A title with
///   runs ("Big    Title") is the target of `[[Big Title]]` and `[[Big    Title]]` alike. An empty
///   target (`[[/Heading]]`) is the source note.
/// - Candidates are notes in Notes or Archive (the Trash is excluded) that are not deleted.
/// - Several candidates (duplicate titles): the most recently modified wins; equal `modifiedAt`
///   → the larger id (UUIDv7, so the newer note).
/// - A heading resolves to the first heading of the target note with the same `headingKey`
///   (the same `TitleKey`).
public enum WikiLinkResolver {
    /// The note a link resolves to, and the heading within it (its ordinal in `heading`, nil when
    /// the link names none or the note has no such heading).
    public struct Target: Equatable, Sendable {
        public var noteId: String
        public var headingOrdinal: Int?

        public init(noteId: String, headingOrdinal: Int? = nil) {
            self.noteId = noteId
            self.headingOrdinal = headingOrdinal
        }
    }

    /// Notes a link can resolve to (titled, not in the Trash, not deleted).
    static let liveNotes = "titleKey != '' AND location != 'trash' AND deletedAt IS NULL"
    /// Among duplicates the first in this order wins.
    static let order = "modifiedAt DESC, id DESC"
    /// The candidate filter of the rule (binds the title key).
    private static let candidates = "titleKey = ? AND \(liveNotes)"

    /// The note links to `titleKey` resolve to, if any.
    public static func resolve(titleKey: String, in db: Database) throws -> String? {
        try String.fetchOne(db, sql: """
            SELECT id FROM note WHERE \(candidates) ORDER BY \(order) LIMIT 1
            """, arguments: [titleKey])
    }

    /// `link` as written in note `sourceNoteId`. Nil when no note has the title.
    public static func resolve(_ link: WikiLinkRef, from sourceNoteId: String, in db: Database) throws -> Target? {
        let noteId = link.target.isEmpty
            ? sourceNoteId
            : try resolve(titleKey: TitleKey.make(link.target), in: db)
        guard let noteId else { return nil }
        return Target(noteId: noteId, headingOrdinal: try link.heading.flatMap { try headingOrdinal($0, inNote: noteId, in: db) })
    }

    /// What decides whether a link's heading names a note's heading: `TitleKey` (whitespace runs
    /// collapsed and trimmed, the wiki-link parser's rule, then `CanonicalKey`). The one heading
    /// matcher for navigation and the title/heading rewrite.
    public static func headingKey(_ heading: String) -> String {
        TitleKey.make(heading)
    }

    /// The ordinal of the first heading of `noteId` whose `headingKey` equals `heading`'s.
    public static func headingOrdinal(_ heading: String, inNote noteId: String, in db: Database) throws -> Int? {
        let key = headingKey(heading)
        return try Row.fetchAll(db, sql: "SELECT ordinal, text FROM heading WHERE noteId = ? ORDER BY ordinal", arguments: [noteId])
            .first { headingKey($0[1] as String) == key }
            .map { $0[0] }
    }

    /// Whether links to `titleKey` resolved to `note` when it still had that title and was last
    /// modified at `modifiedAt` (the note's own current row is left out; the others are as now).
    static func resolved(
        titleKey: String, to note: Note, modifiedAt: Date, in db: Database
    ) throws -> Bool {
        guard !titleKey.isEmpty, note.location != .trash, note.deletedAt == nil else { return false }
        let newer = try Bool.fetchOne(db, sql: """
            SELECT EXISTS (SELECT 1 FROM note WHERE \(candidates) AND id != ?
                AND (modifiedAt > ? OR (modifiedAt = ? AND id > ?)))
            """, arguments: [titleKey, note.id, modifiedAt, modifiedAt, note.id]) ?? false
        return !newer
    }
}

extension NoteStore {
    /// `link` as written in note `sourceNoteId` (see `WikiLinkResolver`); resolves only, nil when
    /// no note has the title (a click creates it: `resolveOrCreateWikiLink`).
    public func resolveWikiLink(_ link: WikiLinkRef, from sourceNoteId: String) throws -> WikiLinkResolver.Target? {
        try db.pool.read { try WikiLinkResolver.resolve(link, from: sourceNoteId, in: $0) }
    }
}
