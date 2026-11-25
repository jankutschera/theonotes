// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB

/// A note coming from another app, with the source's dates and flags.
public struct ImportedNoteDraft: Equatable, Sendable {
    public var text: String
    public var createdAt: Date
    public var modifiedAt: Date
    /// `trashedAt` / `archivedAt` are set to `modifiedAt` for trash / archive.
    public var location: NoteLocation
    public var isPinnedGlobal: Bool
    /// Tag paths (with or without `#`) the note is pinned in. Pins for tags the text does not
    /// carry (directly or as an ancestor) are skipped; see `NoteStore.pinnableTags`.
    public var tagPins: [String]
    public var isReadOnly: Bool
    public var attachments: [ImportedAttachment]

    public init(
        text: String, createdAt: Date, modifiedAt: Date, location: NoteLocation = .notes,
        isPinnedGlobal: Bool = false, tagPins: [String] = [], isReadOnly: Bool = false,
        attachments: [ImportedAttachment] = []
    ) {
        self.text = text
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.location = location
        self.isPinnedGlobal = isPinnedGlobal
        self.tagPins = tagPins
        self.isReadOnly = isReadOnly
        self.attachments = attachments
    }
}

/// The flags an import carries besides text and dates. Stored per ref as last seen in the
/// source, so each field can be merged on its own: the source wins only for fields it changed.
public struct SourceMetadata: Codable, Equatable, Sendable {
    public var location: NoteLocation
    public var isPinnedGlobal: Bool
    /// Tag paths of per-tag pins.
    public var tagPins: [String]
    public var isReadOnly: Bool

    public init(location: NoteLocation, isPinnedGlobal: Bool, tagPins: [String], isReadOnly: Bool) {
        self.location = location
        self.isPinnedGlobal = isPinnedGlobal
        self.tagPins = tagPins
        self.isReadOnly = isReadOnly
    }

    /// Per field: `source` when it differs from `lastSeen` (or nothing was seen), else `local`.
    /// Tag pins compare as sets of canonical tag keys.
    public static func merge(source: SourceMetadata, lastSeen: SourceMetadata?, local: SourceMetadata) -> SourceMetadata {
        guard let lastSeen else { return source }
        func pinKeys(_ m: SourceMetadata) -> Set<String> { Set(m.tagPins.map(NoteStore.pinKey)) }
        return SourceMetadata(
            location: source.location != lastSeen.location ? source.location : local.location,
            isPinnedGlobal: source.isPinnedGlobal != lastSeen.isPinnedGlobal ? source.isPinnedGlobal : local.isPinnedGlobal,
            tagPins: pinKeys(source) != pinKeys(lastSeen) ? source.tagPins : local.tagPins,
            isReadOnly: source.isReadOnly != lastSeen.isReadOnly ? source.isReadOnly : local.isReadOnly)
    }
}

/// A row of `external_ref`: which local note a source note (e.g. a Bear id) was imported into.
public struct ExternalRef: Equatable, Sendable {
    public var source: String
    public var externalId: String
    /// `nil` once the note was deleted permanently in Theo Notes (tombstone: never re-imported).
    public var noteId: String?
    public var lastSeenModified: Date?
    /// Hash of the whole source record at the last pull.
    public var lastSeenHash: String?
    /// `NoteStore.textHash` of the source's text at the last pull.
    public var lastSeenTextHash: String?
    /// The source's flags at the last pull.
    public var lastSeenMeta: SourceMetadata?
    /// The note's revision after the last write from the source.
    public var importedRevision: Int?
    /// `NoteStore.textHash` of the text last written into the note (for a conflict copy: the
    /// marked text). The note's current text hashing differently means a local edit.
    public var importedTextHash: String?

    public init(
        source: String, externalId: String, noteId: String?, lastSeenModified: Date?, lastSeenHash: String?,
        lastSeenTextHash: String?, lastSeenMeta: SourceMetadata?, importedRevision: Int?, importedTextHash: String?
    ) {
        self.source = source
        self.externalId = externalId
        self.noteId = noteId
        self.lastSeenModified = lastSeenModified
        self.lastSeenHash = lastSeenHash
        self.lastSeenTextHash = lastSeenTextHash
        self.lastSeenMeta = lastSeenMeta
        self.importedRevision = importedRevision
        self.importedTextHash = importedTextHash
    }
}

/// What was seen in the source, written to `external_ref` in the same transaction as the note.
/// The ref is pointed at the written note (inserted or moved there); `importedRevision` is the
/// note's revision after the write; `importedTextHash` is updated when the text was written.
public struct ExternalRefWrite: Equatable, Sendable {
    public var source: String
    public var externalId: String
    public var lastSeenModified: Date
    public var lastSeenHash: String
    public var lastSeenTextHash: String
    public var lastSeenMeta: SourceMetadata

    public init(
        source: String, externalId: String, lastSeenModified: Date, lastSeenHash: String,
        lastSeenTextHash: String, lastSeenMeta: SourceMetadata
    ) {
        self.source = source
        self.externalId = externalId
        self.lastSeenModified = lastSeenModified
        self.lastSeenHash = lastSeenHash
        self.lastSeenTextHash = lastSeenTextHash
        self.lastSeenMeta = lastSeenMeta
    }
}

extension NoteStore {
    // MARK: - Import

    /// Inserts a note with the draft's dates and flags in one transaction: note row, index, pins,
    /// optional external ref (inserted, or moved here from another note: conflict copies).
    /// Attachments follow the staging rule (`AttachmentFiles`): staged and fsynced before the
    /// transaction, moved into `Attachments/<id>/` after the commit, removed if it fails.
    @discardableResult
    public func importNote(_ draft: ImportedNoteDraft, externalRef: ExternalRefWrite? = nil) throws -> Note {
        let id = UUIDv7.make(now: draft.createdAt)
        let note = try AttachmentFiles(paths: paths, database: db).write(draft.attachments, noteId: id, replacing: false) { db -> Note in
            let text = TextNormalization.normalizeLineEndings(draft.text)
            let modified = Self.roundedToMillis(draft.modifiedAt)
            try Note(
                id: id, text: text, title: "", titleKey: "",
                createdAt: Self.roundedToMillis(draft.createdAt), modifiedAt: modified,
                location: draft.location,
                trashedAt: draft.location == .trash ? modified : nil,
                archivedAt: draft.location == .archive ? modified : nil,
                isPinnedGlobal: draft.isPinnedGlobal, isReadOnly: draft.isReadOnly
            ).insert(db)
            try NoteIndexer.index(noteId: id, text: text, in: db)
            try Self.writeTagPins(draft.tagPins, text: text, noteId: id, in: db)
            let note = try Note.fetchOne(db, key: id)!
            if let externalRef { try Self.writeExternalRef(externalRef, note: note, textWritten: true, in: db) }
            return note
        }
        notifier?.post()
        return note
    }

    /// Replaces an imported note's text, `modifiedAt`, location, flags and pins with the draft
    /// (same id, `createdAt` kept) if its revision is still `expectedRevision`, and writes the
    /// draft's attachments (same-name files are overwritten).
    ///
    /// Files the draft no longer lists are kept: an open session with unsaved edits, or the
    /// conflict copy it makes (`createConflictCopy`), may still link them. The app's cleanup
    /// (eviction, launch sweep; ruling R23) removes them once nothing references them.
    @discardableResult
    public func replaceImported(
        noteID: String, draft: ImportedNoteDraft, expectedRevision: Int, externalRef: ExternalRefWrite? = nil
    ) throws -> Note {
        let note = try AttachmentFiles(paths: paths, database: db).write(draft.attachments, noteId: noteID, replacing: false) { db in
            try Self.writeImported(noteID: noteID, draft: draft, text: TextNormalization.normalizeLineEndings(draft.text),
                                   expectedRevision: expectedRevision, externalRef: externalRef, in: db)
        }
        notifier?.post()
        return note
    }

    /// Like `replaceImported` but keeps the note's text and attachments: applies the draft's
    /// `modifiedAt`, location, flags and pins (pins checked against the kept text). For source
    /// changes that did not touch the text.
    @discardableResult
    public func applyImportedMetadata(
        noteID: String, draft: ImportedNoteDraft, expectedRevision: Int, externalRef: ExternalRefWrite? = nil
    ) throws -> Note {
        let note = try db.pool.write { db in
            try Self.writeImported(noteID: noteID, draft: draft, text: nil, expectedRevision: expectedRevision,
                                   externalRef: externalRef, in: db)
        }
        notifier?.post()
        return note
    }

    /// Refs of one source, keyed by external id.
    public func externalRefs(source: String) throws -> [String: ExternalRef] {
        try db.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT externalId, noteId, lastSeenModified, lastSeenHash, lastSeenTextHash, lastSeenMeta,
                        importedRevision, importedTextHash
                    FROM external_ref WHERE source = ?
                    """,
                arguments: [source])
            var refs: [String: ExternalRef] = [:]
            for row in rows {
                let ref = ExternalRef(
                    source: source, externalId: row[0], noteId: row[1], lastSeenModified: row[2],
                    lastSeenHash: row[3], lastSeenTextHash: row[4],
                    lastSeenMeta: (row[5] as String?).flatMap { try? JSONDecoder().decode(SourceMetadata.self, from: Data($0.utf8)) },
                    importedRevision: row[6], importedTextHash: row[7])
                refs[ref.externalId] = ref
            }
            return refs
        }
    }

    /// The note's per-tag pins (tag display paths).
    public func tagPins(noteId: String) throws -> [String] {
        try db.pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT tag.displayPath FROM note_pin JOIN tag ON tag.id = note_pin.tagId
                WHERE note_pin.noteId = ? ORDER BY tag.pathKey
                """, arguments: [noteId])
        }
    }

    /// SHA-256 (hex) of the line-ending-normalized text's UTF-8 bytes.
    public static func textHash(_ text: String) -> String {
        SHA256.hash(data: Data(TextNormalization.normalizeLineEndings(text).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Splits pin paths into those the text carries (directly or as an ancestor of one of its
    /// tags) and the rest. Pins keep their input spelling.
    public static func pinnableTags(_ tagPins: [String], text: String) -> (pinnable: [String], skipped: [String]) {
        var carried = Set<String>()
        for tag in NoteParser.metadata(for: text).tags {
            for path in TagScanner.ancestorPaths(of: tag) { carried.insert(CanonicalKey.make(path)) }
        }
        var pinnable: [String] = [], skipped: [String] = []
        for pin in tagPins {
            if carried.contains(pinKey(pin)) { pinnable.append(pin) } else { skipped.append(pin) }
        }
        return (pinnable, skipped)
    }

    static func pinKey(_ pin: String) -> String {
        var name = Substring(pin)
        if name.hasPrefix("#") { name = name.dropFirst() }
        if name.hasSuffix("#") { name = name.dropLast() }
        return CanonicalKey.make(TagScanner.normalize(Array(name.unicodeScalars)[...]))
    }

    /// `text == nil` keeps the stored text (metadata-only update). A locked note is refused
    /// (`noteLocked`): its text lives in the encrypted payload, so neither an imported text nor
    /// pins checked against the empty plaintext column may be written over it.
    private static func writeImported(
        noteID: String, draft: ImportedNoteDraft, text: String?, expectedRevision: Int,
        externalRef: ExternalRefWrite?, in db: Database
    ) throws -> Note {
        try NotePrivacy.requireNoPendingTransition(noteID, in: db)
        guard try !require(noteID, in: db).isLocked else { throw StoreError.noteLocked(id: noteID) }
        let modified = roundedToMillis(draft.modifiedAt)
        try db.execute(
            sql: """
                UPDATE note SET text = COALESCE(?, text), modifiedAt = ?, location = ?, trashedAt = ?,
                    archivedAt = ?, isPinnedGlobal = ?, isReadOnly = ?, revision = revision + 1
                WHERE id = ? AND revision = ?
                """,
            arguments: [
                text, modified, draft.location,
                draft.location == .trash ? modified : nil, draft.location == .archive ? modified : nil,
                draft.isPinnedGlobal, draft.isReadOnly, noteID, expectedRevision,
            ]
        )
        guard db.changesCount > 0 else {
            guard let current = try Int.fetchOne(
                db, sql: "SELECT revision FROM note WHERE id = ?", arguments: [noteID]
            ) else { throw StoreError.noteNotFound(id: noteID) }
            throw StoreError.revisionConflict(current: current)
        }
        if let text { try NoteIndexer.index(noteId: noteID, text: text, in: db) }
        let stored = try Note.fetchOne(db, key: noteID)!
        try db.execute(sql: "DELETE FROM note_pin WHERE noteId = ?", arguments: [noteID])
        try writeTagPins(draft.tagPins, text: stored.text, noteId: noteID, in: db)
        try NoteIndexer.removeOrphanTags(in: db)
        if let externalRef { try writeExternalRef(externalRef, note: stored, textWritten: text != nil, in: db) }
        return stored
    }

    private static func writeTagPins(_ tagPins: [String], text: String, noteId: String, in db: Database) throws {
        for pin in pinnableTags(tagPins, text: text).pinnable {
            guard let tagId = try String.fetchOne(
                db, sql: "SELECT id FROM tag WHERE pathKey = ?", arguments: [pinKey(pin)]
            ) else { continue }
            try db.execute(
                sql: "INSERT OR IGNORE INTO note_pin (noteId, tagId) VALUES (?, ?)", arguments: [noteId, tagId])
        }
    }

    private static func metaJSON(_ meta: SourceMetadata) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(meta), as: UTF8.self)
    }

    /// Upserts the ref onto `note`. `importedTextHash` is replaced only when the text was written.
    /// A tombstone (`noteId IS NULL`: deleted permanently, e.g. while a pull ran) is never
    /// revived: throws `externalRefTombstoned`, which rolls back the whole write.
    private static func writeExternalRef(_ ref: ExternalRefWrite, note: Note, textWritten: Bool, in db: Database) throws {
        let tombstoned = try Bool.fetchOne(
            db, sql: "SELECT noteId IS NULL FROM external_ref WHERE source = ? AND externalId = ?",
            arguments: [ref.source, ref.externalId])
        if tombstoned == true { throw StoreError.externalRefTombstoned(source: ref.source, externalId: ref.externalId) }
        try db.execute(
            sql: """
                INSERT INTO external_ref (source, externalId, noteId, lastSeenModified, lastSeenHash,
                    lastSeenTextHash, lastSeenMeta, importedRevision, importedTextHash)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(source, externalId) DO UPDATE SET noteId = excluded.noteId,
                    lastSeenModified = excluded.lastSeenModified, lastSeenHash = excluded.lastSeenHash,
                    lastSeenTextHash = excluded.lastSeenTextHash, lastSeenMeta = excluded.lastSeenMeta,
                    importedRevision = excluded.importedRevision,
                    importedTextHash = \(textWritten ? "excluded.importedTextHash" : "external_ref.importedTextHash")
                """,
            arguments: [
                ref.source, ref.externalId, note.id, roundedToMillis(ref.lastSeenModified), ref.lastSeenHash,
                ref.lastSeenTextHash, metaJSON(ref.lastSeenMeta), note.revision, textWritten ? textHash(note.text) : nil,
            ])
    }
}
