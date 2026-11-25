// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import os

let storeLogger = Logger(subsystem: "com.truebrewbirdie.baerchen", category: "store")

public enum StoreError: Error, Equatable {
    case revisionConflict(current: Int)
    case noteNotFound(id: String)
    /// The note is locked, so its text is not readable (e.g. as a template).
    case noteLocked(id: String)
    case tagNotFound(path: String)
    /// Pinning within a tag the note does not carry (directly or as an ancestor).
    case noteNotTagged(id: String, tagPath: String)
    /// The path cannot be written as a tag (empty after normalization, or would not parse back).
    case invalidTag(path: String)
    /// Only root tags can be pinned in the sidebar (Bear: nested tags can't be pinned).
    case tagNotRoot(path: String)
    /// Renaming a tag into its own subtree (`work` → `work/sub`).
    case tagIntoOwnSubtree(path: String, target: String)
    /// A tag rename, nest or merge onto one of the reserved type tags (`idea`, `log`, `ref`).
    case reservedTagName(String)
    /// The source note's Theo Notes note was deleted permanently (tombstone): an import may not
    /// point the ref at a note again. Raised inside the write, so nothing was written.
    case externalRefTombstoned(source: String, externalId: String)
}

/// When a `NoteStore.WriteGuard` runs inside a write transaction.
public enum WriteStage: Sendable {
    /// After the transaction opened and before the change: a check of the state the change starts from.
    case begin
    /// After the change and before the commit: a check of the state the change leaves.
    case beforeCommit
}

/// All writes go through one write transaction each, re-index the note text they change
/// (`NoteIndexer`) in that transaction, and post the change notification after the commit.
/// Batch operations fail as a whole (`StoreError.noteNotFound`) if any id is unknown.
public final class NoteStore: Sendable {
    let db: AppDatabase
    let notifier: ChangeNotifier?
    /// Where `Attachments/<noteId>/` and `Journal/<noteId>.*` live (removed on permanent delete).
    let paths: AppPaths
    /// Notes whose attachment files the cleanup leaves alone (open in an editor session).
    public let retention: AttachmentRetention
    /// Called inside every write transaction of this store (`WriteStage`); a throw rolls the whole
    /// transaction back and reaches the caller as it was thrown.
    public typealias WriteGuard = @Sendable (Database, WriteStage) throws -> Void
    private let writeGuard: WriteGuard?

    public init(db: AppDatabase, notifier: ChangeNotifier?, paths: AppPaths) {
        self.db = db
        self.notifier = notifier
        self.paths = paths
        self.retention = AttachmentRetention()
        self.writeGuard = nil
    }

    private init(copying other: NoteStore, writeGuard: WriteGuard?) {
        self.db = other.db
        self.notifier = other.notifier
        self.paths = other.paths
        self.retention = other.retention
        self.writeGuard = writeGuard
    }

    /// This store with `writeGuard` checking each of its write transactions: how a caller that must
    /// not leave a state behind (the MCP server's tag scope) enforces it atomically instead of
    /// writing first and undoing afterwards. Guarding a store that is already guarded adds the new
    /// check after the old one (both run, the old one first); it never replaces it.
    ///
    /// Only writes that go through the store's own write transaction are guarded: the text, tag,
    /// location, pin, tag-management and create methods. The import methods (`importNote`,
    /// `replaceImported`, `applyImportedMetadata`) and the UI-state and attachment-cleanup writes
    /// open their own transactions and are not guarded; the MCP server cannot reach them.
    public func guarded(by writeGuard: @escaping WriteGuard) -> NoteStore {
        guard let inner = self.writeGuard else { return NoteStore(copying: self, writeGuard: writeGuard) }
        return NoteStore(
            copying: self,
            writeGuard: { db, stage in
                try inner(db, stage)
                try writeGuard(db, stage)
            })
    }

    // MARK: - Reads

    public func note(id: String) throws -> Note? {
        try db.pool.read { try Note.fetchOne($0, key: id) }
    }

    /// Only the revision column: the cheap check whether an open session is behind the store.
    public func revision(id: String) throws -> Int? {
        try db.pool.read { try Int.fetchOne($0, sql: "SELECT revision FROM note WHERE id = ?", arguments: [id]) }
    }

    public func allNotes(location: NoteLocation = .notes) throws -> [Note] {
        try db.pool.read { try Self.request(location).fetchAll($0) }
    }

    public func notesObservation(
        location: NoteLocation
    ) -> ValueObservation<ValueReducers.Fetch<[Note]>> {
        ValueObservation.tracking { try Self.request(location).fetchAll($0) }
    }

    private static func request(_ location: NoteLocation) -> QueryInterfaceRequest<Note> {
        Note.filter(Column("location") == location.rawValue).order(Column("modifiedAt").desc)
    }

    // MARK: - Text

    /// Line endings are normalised to "\n" (see `TextNormalization.normalizeLineEndings`).
    /// `captureSource` names the gesture that makes a captured note. It is written once, here, and
    /// never changed (FOC-R2).
    public func create(text: String, now: Date = .now, captureSource: CaptureSource? = nil) throws -> Note {
        try write { db in try Self.insert(text: text, now: now, captureSource: captureSource, in: db) }
    }

    /// Never removes attachment files (ruling R23: the cleanup runs only in the app process).
    /// With `preservingModifiedDate` the revision still bumps and the text is still indexed, but
    /// `modifiedAt` stays as it was (CLI/MCP `--no-update-modified`).
    public func updateText(
        id: String, text: String, expectedRevision: Int, now: Date = .now, preservingModifiedDate: Bool = false
    ) throws -> Note {
        try write { db in
            try Self.writeText(
                id: id, text: text, expectedRevision: expectedRevision, now: now,
                preservingModifiedDate: preservingModifiedDate, in: db)
        }
    }

    /// A new note with the same text (new id, timestamps `now`, not pinned, in Notes) and a copy
    /// of its attachment files (`copyingAttachments`).
    public func duplicate(id: String, now: Date = .now) throws -> Note {
        try copyingAttachments(of: id, now: now) { newId, db in
            let source = try Self.require(id, in: db)
            guard !source.isLocked else { throw StoreError.noteLocked(id: id) }
            return try Self.insert(id: newId, text: source.text, now: now, in: db)
        }
    }

    /// Copies selected Markdown into a fresh note, keeping the source and its import identity intact.
    /// All source attachment files are staged with the new note; protection requires LockedNoteAccess.
    public func createFromSelection(of noteId: String, text: String, now: Date = .now) throws -> Note {
        try copyingAttachments(of: noteId, now: now) { newId, db in
            guard try !Self.require(noteId, in: db).isLocked else { throw StoreError.noteLocked(id: noteId) }
            return try Self.insert(id: newId, text: text, now: now, in: db)
        }
    }

    /// The copy an open session makes when the store's text conflicts with its unsaved edits:
    /// a new note with `text` (the store's version) that keeps the original's creation date,
    /// global and tag pins, and location (M2 ruling R20), plus a copy of its attachment files
    /// (`copyingAttachments`).
    ///
    /// Which note keeps an `external_ref`: when `text` is exactly what the source (Bear, Apple
    /// Notes) last wrote into the note (`importedTextHash`), the ref moves to the copy in the same
    /// transaction. The copy then mirrors the source and later pulls update it in place, while the
    /// original, holding the local edits, becomes a plain Theo Notes note. Same rule as the
    /// importers' own conflict copies (R4). Otherwise (e.g. a CLI write) the ref stays.
    /// Persist just the browser text. No attachment staging or import identity is involved.
    public func canRecoverMissingJournalPlain() throws -> Bool {
        try db.pool.read { db in
            try SyncDeletedRecoveryPolicy.hasNoVaultOrPendingVault(in: db, cloud: false)
                && SyncDeletedRecoveryPolicy.hasNoVaultOrPendingVault(in: db, cloud: true)
                && Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM privacy_transition)") == false
        }
    }

    public func preserveBrowserRecovery(noteId: String, text: String, baseRevision: Int, now: Date) throws -> BrowserRecoveryResult {
        try preserveBrowserRecovery(noteId: noteId, text: text, baseRevision: baseRevision, now: now, journalContext: nil)
    }
    func preserveBrowserRecovery(noteId: String, text: String, baseRevision: Int, now: Date, journalContext: JournalRecoveryContext?) throws -> BrowserRecoveryResult {
        let text = TextNormalization.normalizeLineEndings(text)
        let result = try write { db in
            if let original = try Note.fetchOne(db, key: noteId) {
                guard !original.isLocked else { throw CocoaError(.fileWriteNoPermission) }
            } else {
                // A missing row no longer proves that the previous content was plain. Check
                // both sync transports and privacy staging in this same writer transaction.
                guard try SyncDeletedRecoveryPolicy.hasNoVaultOrPendingVault(in: db, cloud: false),
                      try SyncDeletedRecoveryPolicy.hasNoVaultOrPendingVault(in: db, cloud: true),
                      try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM privacy_transition)") == false else {
                    throw CocoaError(.fileWriteNoPermission)
                }
            }
            var generation = try journalContext.map { try JournalRecoveryGeneration.next($0, in: db) } ?? 0
            while true {
                let identity = generation == 0 ? noteId : noteId + "\0orphan-generation:\(generation)"
                let id = BrowserRecoveryID.make(noteId: identity, text: text, baseRevision: baseRevision)
                if let existing = try Note.fetchOne(db, key: id) {
                    let recorded = try journalContext.map { try JournalRecoveryGeneration.matches($0, generation: generation, id: id, in: db) } ?? false
                    guard !existing.isLocked, existing.deletedAt == nil,
                          recorded || (existing.location == .notes && TextNormalization.identical(existing.text, text)) else {
                        // Q4: a copy the user edited, trashed, archived or locked keeps this id; journal
                        // recovery moves to the next generation in this same transaction (ruling 4).
                        guard journalContext != nil, generation < Int.max else { throw CocoaError(.fileWriteFileExists) }
                        generation += 1; continue
                    }
                    if let journalContext { try JournalRecoveryGeneration.save(journalContext, generation: generation, id: id, in: db) }
                    return (existing, false)
                }
                let created = try Self.insert(id: id, text: text, now: now, in: db)
                if let journalContext { try JournalRecoveryGeneration.save(journalContext, generation: generation, id: id, in: db) }
                return (created, true)
            }
        }
        // The writer has committed before this readback; native may ACK only after this returns.
        guard let committed = try note(id: result.0.id), !committed.isLocked, committed.deletedAt == nil,
              (journalContext != nil || (committed.location == .notes && TextNormalization.identical(committed.text, text))) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return BrowserRecoveryResult(note: committed, created: result.1)
    }

    public func createConflictCopy(of noteId: String, text: String, now: Date = .now) throws -> Note {
        try copyingAttachments(of: noteId, now: now) { newId, db in
            guard try !Self.require(noteId, in: db).isLocked else { throw StoreError.noteLocked(id: noteId) }
            var copy = try Self.insert(id: newId, text: text, now: now, in: db)
            if let original = try Note.fetchOne(db, key: noteId) {
                try db.execute(
                    sql: """
                        UPDATE note SET createdAt = ?, location = ?, trashedAt = ?, archivedAt = ?, isPinnedGlobal = ?
                        WHERE id = ?
                        """,
                    arguments: [original.createdAt, original.location, original.trashedAt, original.archivedAt,
                                original.isPinnedGlobal, newId])
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO note_pin (noteId, tagId)
                        SELECT ?, tagId FROM note_pin
                        WHERE noteId = ? AND tagId IN (SELECT tagId FROM note_tag WHERE noteId = ?)
                        """,
                    arguments: [newId, noteId, newId])
                copy = try Self.require(newId, in: db)
            }
            try db.execute(
                sql: "UPDATE external_ref SET noteId = ?, importedRevision = ? WHERE noteId = ? AND importedTextHash = ?",
                arguments: [copy.id, copy.revision, noteId, Self.textHash(copy.text)])
            return copy
        }
    }

    /// Inserts a note made from `source` (`insert(newId, db)`) and copies `Attachments/<source>/`
    /// with the staging rule: the files are cloned into a batch before the transaction, the
    /// transaction records it, and they are renamed into place after the commit. A file whose copy
    /// fails is recorded with its source, so `install` and the launch recovery copy it again
    /// (M2 ruling R20); the copy's other links work meanwhile.
    func copyingAttachments(of source: String, now: Date, insert: (String, Database) throws -> Note) throws -> Note {
        let newId = UUIDv7.make(now: now)
        let files = AttachmentFiles(paths: paths, database: db)
        let staged = files.stageCopy(from: source, to: newId)
        let copy: Note
        do {
            copy = try write { db in
                if let staged { try AttachmentFiles.record(staged, in: db) }
                return try insert(newId, db)
            }
        } catch {
            if let staged { files.discard(staged) }
            throw error
        }
        if let staged { files.install(staged) }
        return copy
    }

    /// Appends `\n#tag` (`.bottom`) or inserts a `#tag` line directly after the title line (`.top`;
    /// the title line is the first body line, below YAML front matter: ruling M5-R95).
    /// Multi-word and number-only tags use the closed form `#a b#`.
    /// Notes that already carry the tag directly (any spelling) are left untouched.
    public func addTag(
        _ path: String, to ids: [String], position: TagPosition, now: Date = .now,
        preservingModifiedDate: Bool = false
    ) throws {
        try addTags([path], to: ids, position: position, now: now, preservingModifiedDate: preservingModifiedDate)
    }

    /// `addTag` for several tags in one write transaction: all of them land or none does.
    public func addTags(
        _ paths: [String], to ids: [String], position: TagPosition, now: Date = .now,
        preservingModifiedDate: Bool = false
    ) throws {
        let tokens = try paths.map { try Self.tagToken($0) }
        try write { db in
            for id in Self.unique(ids) {
                for (name, token) in tokens {
                    // Read again per tag: the previous insertion changed the text and the revision.
                    let note = try Self.require(id, in: db)
                    let key = CanonicalKey.make(name)
                    let tags = NoteParser.metadata(for: note.text).tags
                    guard !tags.contains(where: { CanonicalKey.make($0) == key }) else { continue }
                    let text = position == .bottom
                        ? note.text + "\n" + token
                        : Self.insertingTagLineAfterTitle(token, into: note.text)
                    _ = try Self.writeText(
                        id: note.id, text: text, expectedRevision: note.revision, now: now,
                        preservingModifiedDate: preservingModifiedDate, in: db)
                }
            }
        }
    }

    /// Removes every occurrence of the tag (exact path, any spelling) with one adjacent space, and
    /// a line the removal left blank. Nested tags (`#a/b` when removing `a`) are kept.
    public func removeTag(
        _ path: String, from ids: [String], now: Date = .now, preservingModifiedDate: Bool = false
    ) throws {
        try removeTags([path], from: ids, now: now, preservingModifiedDate: preservingModifiedDate)
    }

    /// `removeTag` for several tags in one write transaction: all of them go or none does.
    public func removeTags(
        _ paths: [String], from ids: [String], now: Date = .now, preservingModifiedDate: Bool = false
    ) throws {
        let keys = paths.map { CanonicalKey.make(TagScanner.normalize(Array($0.unicodeScalars)[...])) }
        try write { db in
            for id in Self.unique(ids) {
                for key in keys {
                    let note = try Self.require(id, in: db)
                    guard let text = Self.removingTag(key, from: note.text) else { continue }
                    _ = try Self.writeText(
                        id: note.id, text: text, expectedRevision: note.revision, now: now,
                        preservingModifiedDate: preservingModifiedDate, in: db)
                }
            }
        }
    }

    // MARK: - Location and pins (revision bumps, `modifiedAt` unchanged)

    public func trash(_ ids: [String], now: Date = .now) throws {
        try update(ids, sql: "location = 'trash', trashedAt = ?", [Self.roundedToMillis(now)])
    }

    public func archive(_ ids: [String], now: Date = .now) throws {
        try update(ids, sql: "location = 'archive', archivedAt = ?, trashedAt = NULL", [Self.roundedToMillis(now)])
    }

    /// Back to Notes, from Trash or Archive.
    public func restore(_ ids: [String]) throws {
        try update(ids, sql: "location = 'notes', trashedAt = NULL, archivedAt = NULL", [])
    }

    /// `inTag == nil` pins globally (`isPinnedGlobal`); otherwise within that tag (`note_pin`),
    /// which the note must carry directly or as an ancestor of one of its tags.
    public func setPinned(_ ids: [String], pinned: Bool, inTag tagPath: String? = nil) throws {
        try setPins(ids, pinned: pinned, inTags: tagPath.map { [$0] } ?? [], global: tagPath == nil)
    }

    /// `setPinned` for several contexts in one write transaction: each tag in `tagPaths`, then
    /// globally when `global`. Any failure rolls all of them back.
    public func setPins(_ ids: [String], pinned: Bool, inTags tagPaths: [String], global: Bool) throws {
        try write { db in
            for tagPath in tagPaths { try Self.setPinned(ids, pinned: pinned, inTag: tagPath, in: db) }
            if global { try Self.updateRows(ids, sql: "isPinnedGlobal = ?", [pinned], in: db) }
        }
    }

    private static func setPinned(_ ids: [String], pinned: Bool, inTag tagPath: String, in db: Database) throws {
        let key = CanonicalKey.make(TagScanner.normalize(Array(tagPath.unicodeScalars)[...]))
        guard let tagId = try String.fetchOne(db, sql: "SELECT id FROM tag WHERE pathKey = ?", arguments: [key])
        else { throw StoreError.tagNotFound(path: tagPath) }
        for note in try require(ids, in: db) {
            if pinned {
                let tagged = try Bool.fetchOne(
                    db, sql: "SELECT EXISTS (SELECT 1 FROM note_tag WHERE noteId = ? AND tagId = ?)",
                    arguments: [note.id, tagId]
                ) ?? false
                guard tagged else { throw StoreError.noteNotTagged(id: note.id, tagPath: tagPath) }
                try db.execute(sql: "INSERT OR IGNORE INTO note_pin (noteId, tagId) VALUES (?, ?)",
                               arguments: [note.id, tagId])
            } else {
                try db.execute(sql: "DELETE FROM note_pin WHERE noteId = ? AND tagId = ?",
                               arguments: [note.id, tagId])
            }
            try db.execute(sql: "UPDATE note SET revision = revision + 1 WHERE id = ?", arguments: [note.id])
        }
        try NoteIndexer.removeOrphanTags(in: db)
    }

    // MARK: - Deletion (the app closes open sessions for these ids first)

    public func deletePermanently(_ ids: [String]) throws {
        let ids = try write { db -> [String] in
            let notes = try Self.require(ids, in: db)
            try Self.delete(notes.map(\.id), in: db)
            return notes.map(\.id)
        }
        removeFiles(of: ids)
    }

    /// Permanently deletes every note in the trash; returns how many.
    public func emptyTrash() throws -> Int {
        let ids = try write { db -> [String] in
            let ids = try String.fetchAll(db, sql: "SELECT id FROM note WHERE location = 'trash'")
            try Self.delete(ids, in: db)
            return ids
        }
        removeFiles(of: ids)
        return ids.count
    }

    /// Empty Trash for the notes the caller listed: deletes those of `ids` still in the trash
    /// (checked inside the transaction), so a note trashed after the list was read, e.g. by a
    /// pull, is left alone. Returns the deleted ids.
    public func emptyTrash(ids: [String]) throws -> [String] {
        let deleted = try write { db -> [String] in
            let deleted = try Self.unique(ids).filter {
                try Bool.fetchOne(db, sql: "SELECT location = 'trash' FROM note WHERE id = ?", arguments: [$0]) == true
            }
            try Self.delete(deleted, in: db)
            return deleted
        }
        removeFiles(of: deleted)
        return deleted
    }

    /// When the note no longer exists, cleans up what is left of it, e.g. a journal a late edit
    /// recreated after a permanent delete: `Journal/<id>.jsonl` and `.base` are moved aside as
    /// `*.unreplayed` for manual recovery (never deleted: they may hold the only copy of typed
    /// text), `Attachments/<id>/` and `Thumbnails/<id>/` are removed. Returns whether the note
    /// was gone.
    public func removeFilesIfDeleted(noteId: String) throws -> Bool {
        guard try note(id: noteId) == nil else { return false }
        try EditJournal.moveAside(noteId: noteId, in: paths.journal)
        removeDirectories(of: [noteId])
        return true
    }

    // MARK: - Attachment cleanup

    /// Files modified more recently are never removed: a file is placed before its link is
    /// inserted (drop, paste, ⇧⌘V), and an insert may still be on its way.
    public static let attachmentGracePeriod: TimeInterval = 10 * 60

    /// Removes the files in `Attachments/<noteId>/` that the note's committed text no longer
    /// references (`AttachmentReferences`), except `keeping`. Ruling R23: only the app calls it,
    /// when it evicts a session (its in-process `retention` is then authoritative) and in the
    /// launch sweep; store writes (CLI, MCP, imports) never delete files. Nothing is removed while
    /// the files may still be linked: the note is open in an editor session of this process
    /// (`retention`; unsaved edits or undo history may link them again), it has a non-empty
    /// journal (unsaved acked edits of a session elsewhere, or a journal kept for manual
    /// recovery), a batch for it is staged, a pending copy still reads from it (`copy-source`), a
    /// copied or cut link still holds the file (`retention.holds`, R30),
    /// it is locked (text unreadable), or it does not exist (the delete path removes the
    /// directory). Files modified within `attachmentGracePeriod` of `now` stay. Returns the
    /// removed names.
    @discardableResult
    public func removeUnreferencedAttachments(noteId: String, keeping: [String] = [], now: Date = .now) -> [String] {
        do {
            return try db.pool.write { writer in
                try NotePrivacy.requireNoPendingTransition(noteId, in: writer)
                let fm = FileManager.default
                let dir = attachmentDirectory(noteId)
                let files = AttachmentFiles(paths: paths, database: db)
                guard !retention.contains(noteId), !hasJournal(noteId),
                      !files.hasStagedFiles(for: noteId), !files.isCopySource(noteId),
                      let note = try Note.fetchOne(writer, key: noteId), !note.isLocked else { return [] }
                // A missing or empty directory has no file left to remove, but its tombstones go: the
                // files they kept OCR text for are gone.
                let existing = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
                guard !existing.isEmpty else {
                    try purgeAttachmentTombstones(noteId: noteId, keepingFiles: [], in: writer)
                    return []
                }
                let references = AttachmentReferences(text: note.text)
                let keep = Set(keeping.map(AttachmentFiles.fileSystemKey))
                let cutoff = now.addingTimeInterval(-Self.attachmentGracePeriod)
                var removed: [String] = []
                for name in existing.sorted() where !name.hasPrefix(".") && !keep.contains(AttachmentFiles.fileSystemKey(name)) {
                    guard !references.references(name), !retention.holds(name, of: noteId, now: now) else { continue }
                    let url = dir.appendingPathComponent(name)
                    guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                          modified < cutoff else { continue }
                    do {
                        try fm.removeItem(at: url)
                        removed.append(name)
                    } catch {
                        storeLogger.error("note \(noteId, privacy: .public): unreferenced attachment not removed: \(error)")
                    }
                }
                if !removed.isEmpty {
                    storeLogger.notice("note \(noteId, privacy: .public): \(removed.count) unreferenced attachment(s) removed")
                }
                try purgeAttachmentTombstones(noteId: noteId, keepingFiles: Set(existing.filter { !removed.contains($0) }.map(AttachmentFiles.fileSystemKey)), in: writer)
                return removed
            }
        } catch NotePrivacyError.cleanupPending {
            return []
        } catch {
            storeLogger.error("unreferenced attachment cleanup failed")
            return []
        }
    }

    /// Prune tombstones under the same writer as the file sweep and privacy check.
    private func purgeAttachmentTombstones(noteId: String, keepingFiles: Set<String>, in db: Database) throws {
        let keys = try String.fetchAll(
            db, sql: "SELECT filenameKey FROM attachment WHERE noteId = ? AND deletedAt IS NOT NULL",
            arguments: [noteId])
        for key in keys where !keepingFiles.contains(key) {
            try db.execute(sql: "DELETE FROM attachment WHERE noteId = ? AND filenameKey = ?", arguments: [noteId, key])
        }
    }

    /// `removeUnreferencedAttachments` for every note directory (the launch sweep); returns how
    /// many files were removed.
    @discardableResult
    public func removeUnreferencedAttachments() -> Int {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: paths.attachments.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
        // Notes with tombstones but no directory at all (a file that never arrived): the same
        // per-note cleanup purges the tombstones, under the same guards.
        let withTombstones = (try? db.pool.read {
            try String.fetchAll($0, sql: "SELECT DISTINCT noteId FROM attachment WHERE deletedAt IS NOT NULL")
        }) ?? []
        for id in Set(withTombstones).subtracting(names) { removeUnreferencedAttachments(noteId: id) }
        return names.reduce(0) { $0 + removeUnreferencedAttachments(noteId: $1).count }
    }

    /// A non-empty `<id>.jsonl`, or one moved aside for manual recovery (`<id>.jsonl.unreplayed*`).
    private func hasJournal(_ noteId: String) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.journal.path)) ?? []
        return names.contains { name in
            guard name == "\(noteId).jsonl" || name.hasPrefix("\(noteId).jsonl.unreplayed") else { return false }
            let url = paths.journal.appendingPathComponent(name)
            return ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
        }
    }

    // MARK: - Internals

    func write<T>(_ body: (Database) throws -> T) throws -> T {
        let writeGuard = writeGuard
        let result = try db.pool.write { db in
            try writeGuard?(db, .begin)
            let value = try body(db)
            try writeGuard?(db, .beforeCommit)
            return value
        }
        notifier?.post()
        return result
    }

    /// `SET <sql>, revision = revision + 1` for every id; any unknown id rolls back the batch.
    private func update(_ ids: [String], sql: String, _ arguments: [(any DatabaseValueConvertible)?]) throws {
        try write { db in try Self.updateRows(ids, sql: sql, arguments, in: db) }
    }

    private static func updateRows(
        _ ids: [String], sql: String, _ arguments: [(any DatabaseValueConvertible)?], in db: Database
    ) throws {
        for id in unique(ids) {
            try db.execute(
                sql: "UPDATE note SET \(sql), revision = revision + 1 WHERE id = ?",
                arguments: StatementArguments(arguments + [id])
            )
            guard db.changesCount > 0 else { throw StoreError.noteNotFound(id: id) }
        }
    }

    static func insert(
        id: String? = nil, text: String, now: Date, captureSource: CaptureSource? = nil, in db: Database
    ) throws -> Note {
        let text = TextNormalization.normalizeLineEndings(text)
        let stamp = roundedToMillis(now)
        let note = Note(
            id: id ?? UUIDv7.make(now: now), text: text, title: "", titleKey: "",
            createdAt: stamp, modifiedAt: stamp
        )
        try note.insert(db)
        // `Note` has no such field: the source is device-local state (FOC-R2, FOC-R4).
        if let captureSource {
            try db.execute(sql: "UPDATE note SET captureSource = ? WHERE id = ?", arguments: [captureSource, note.id])
        }
        try NoteIndexer.index(noteId: note.id, text: text, in: db)
        return try Note.fetchOne(db, key: note.id)!
    }

    /// The one text-write path (editor commits, tag edits): optimistic concurrency, new revision,
    /// `modifiedAt = now` (unless `preservingModifiedDate`), re-index.
    static func writeText(
        id: String, text: String, expectedRevision: Int, now: Date, preservingModifiedDate: Bool = false,
        in db: Database
    ) throws -> Note {
        try NotePrivacy.requireNoPendingTransition(id, in: db)
        guard try !Self.require(id, in: db).isLocked else { throw StoreError.noteLocked(id: id) }
        let text = TextNormalization.normalizeLineEndings(text)
        try db.execute(
            sql: """
                UPDATE note SET text = ?, modifiedAt = CASE WHEN ? THEN modifiedAt ELSE ? END,
                    revision = revision + 1 WHERE id = ? AND revision = ?
                """,
            arguments: [text, preservingModifiedDate, roundedToMillis(now), id, expectedRevision]
        )
        guard db.changesCount > 0 else {
            guard let current = try Int.fetchOne(
                db, sql: "SELECT revision FROM note WHERE id = ?", arguments: [id]
            ) else { throw StoreError.noteNotFound(id: id) }
            throw StoreError.revisionConflict(current: current)
        }
        try NoteIndexer.index(noteId: id, text: text, in: db)
        return try Note.fetchOne(db, key: id)!
    }

    static func require(_ id: String, in db: Database) throws -> Note {
        guard let note = try Note.fetchOne(db, key: id) else { throw StoreError.noteNotFound(id: id) }
        return note
    }

    private static func require(_ ids: [String], in db: Database) throws -> [Note] {
        try unique(ids).map { try require($0, in: db) }
    }

    static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// Also used by `CloudSyncStore.enableUploads` for the starter notes a first sync must not publish (STARTER-R4).
    static func delete(_ ids: [String], in db: Database) throws {
        for id in ids {
            try NotePrivacy.requireNoPendingTransition(id, in: db)
            try db.execute(sql: "DELETE FROM note WHERE id = ?", arguments: [id])
        }
        try NoteIndexer.removeOrphanTags(in: db)
    }

    private func attachmentDirectory(_ noteId: String) -> URL {
        paths.attachments.appendingPathComponent(noteId, isDirectory: true)
    }

    /// After the commit: `Attachments/<id>/`, `Thumbnails/<id>/` and every `Journal/<id>.*` file
    /// (`.jsonl`, `.base`, `*.unreplayed*`). Failures are logged; the notes are already gone.
    private func removeFiles(of ids: [String]) {
        let journals = (try? FileManager.default.contentsOfDirectory(atPath: paths.journal.path)) ?? []
        for id in ids {
            remove(journals.filter { $0.hasPrefix(id + ".") }.map { paths.journal.appendingPathComponent($0) }, of: id)
        }
        removeDirectories(of: ids)
    }

    private func removeDirectories(of ids: [String]) {
        for id in ids {
            remove([attachmentDirectory(id), paths.thumbnails.appendingPathComponent(id, isDirectory: true)], of: id)
        }
    }

    private func remove(_ targets: [URL], of id: String) {
        let fm = FileManager.default
        for url in targets where fm.fileExists(atPath: url.path) {
            do {
                try fm.removeItem(at: url)
            } catch {
                storeLogger.error("note \(id, privacy: .public): could not remove \(url.lastPathComponent, privacy: .private): \(error)")
            }
        }
    }

    // MARK: - Tag text rewriting

    /// Normalized tag name and how it is written: `#name`, or `#name#` when an open tag would not
    /// parse back to the same name (spaces, number-only, punctuation).
    public static func tagToken(_ path: String) throws -> (name: String, token: String) {
        let name = TagScanner.normalize(Array(path.unicodeScalars)[...])
        guard !name.isEmpty else { throw StoreError.invalidTag(path: path) }
        for token in ["#" + name, "#" + name + "#"] where TagScanner.tags(inLine: token) == [name] {
            return (name, token)
        }
        throw StoreError.invalidTag(path: path)
    }

    /// The one new-note tag rule (spec §4.3, ruling R31) for ⌘N, templates and wiki links: the
    /// tokens a note made in a window gets beyond the tags its text carries (`carried`). Each of
    /// `extraTags` (the selected tag, the tags a search requires) it lacks, then, in `workspace`,
    /// the workspace's tag unless the note then carries a tag inside it. Throws `invalidTag`.
    public static func newNoteTagTokens(
        carrying carried: [String], extraTags: [String], workspace: Workspace?
    ) throws -> [String] {
        var carried = carried
        var tokens: [String] = []
        for path in extraTags {
            let (name, token) = try tagToken(path)
            let key = CanonicalKey.make(name)
            guard !carried.contains(where: { CanonicalKey.make($0) == key }) else { continue }
            carried.append(name)
            tokens.append(token)
        }
        if let workspace, !carried.contains(where: workspace.includes(tagPath:)) {
            tokens.append(try tagToken(workspace.path).token)
        }
        return tokens
    }

    /// `text` with `line` (tag tokens separated by spaces) placed where `addTag` would put a tag:
    /// on a line of its own at the end (`.bottom`) or directly after the title line (`.top`).
    public static func addingTagLine(_ line: String, to text: String, position: TagPosition) -> String {
        position == .bottom ? text + "\n" + line : insertingTagLineAfterTitle(line, into: text)
    }

    /// Inserts `line` on its own line directly after the note's title line: the first body line,
    /// after YAML front matter (a leading BOM stays with that line). Bear reads the first body line
    /// as the title, so a tag line above it would become the title (ruling M5-R95). A text without
    /// a title line (empty, or front matter only) gets the line at its end.
    static func insertingTagLineAfterTitle(_ line: String, into text: String) -> String {
        // Line indices come from NoteParser's scalar `\n` split; a Character split treats "\r\n"
        // as one Character, so stored CR text (external writers) must be normalised first.
        let text = TextNormalization.normalizeLineEndings(text)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let bodyStart = NoteParser.frontMatterEnd(NoteParser.splitLines(text)) ?? 0
        lines.insert(line, at: min(bodyStart + 1, lines.count))
        return lines.joined(separator: "\n")
    }

    /// The UTF-16 offset where `insertingTagLineAfterTitle` inserts its line break: the end of the
    /// title line (`text` has `\n` line endings).
    static func titleLineEnd(of text: String) -> Int {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard !lines.isEmpty else { return 0 }
        let bodyStart = NoteParser.frontMatterEnd(NoteParser.splitLines(text)) ?? 0
        let last = min(bodyStart, lines.count - 1)
        return lines.prefix(last + 1).reduce(0) { $0 + $1.utf16.count } + last
    }

    /// `nil` when the text has no occurrence of the tag.
    static func removingTag(_ key: String, from text: String) -> String? {
        removingTags(from: text) { CanonicalKey.make($0) == key }
    }

    /// Removes every tag occurrence whose name satisfies `matches` (plus one adjoining space; a
    /// line left blank is dropped). `nil` when nothing matched.
    static func removingTags(from text: String, matching matches: (String) -> Bool) -> String? {
        let text = TextNormalization.normalizeLineEndings(text)
        let occurrences = NoteParser.tagOccurrences(in: text).filter { matches($0.name) }
        guard !occurrences.isEmpty else { return nil }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { Array($0.unicodeScalars) }
        var blankLines: [Int] = []
        for (lineIndex, group) in Dictionary(grouping: occurrences, by: \.line) {
            var line = lines[lineIndex]
            let offset = lineIndex == 0 && line.first == "\u{FEFF}" ? 1 : 0
            for occurrence in group.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
                var lower = occurrence.range.lowerBound + offset, upper = occurrence.range.upperBound + offset
                if lower > offset, Chars.isSpace(line[lower - 1]) {
                    lower -= 1
                } else if upper < line.count, Chars.isSpace(line[upper]) {
                    upper += 1
                }
                line.removeSubrange(lower..<upper)
            }
            if isBlankOrBareListMarker(line.dropFirst(offset)) { blankLines.append(lineIndex) }
            lines[lineIndex] = line
        }
        for index in blankLines.sorted(by: >) { lines.remove(at: index) }
        return lines.map { String(String.UnicodeScalarView($0)) }.joined(separator: "\n")
    }

    /// Whitespace only, or only a list marker the removal left behind: `- `, `* `, `+ `, `1. `,
    /// `1) `, optionally followed by a task box (`[ ]`, `[x]`).
    static func isBlankOrBareListMarker(_ line: ArraySlice<Unicode.Scalar>) -> Bool {
        var rest = line.drop(while: Chars.isSpace)
        guard let first = rest.first else { return true }
        if first == "-" || first == "*" || first == "+" {
            rest = rest.dropFirst()
        } else if Chars.isDigit(first) {
            rest = rest.drop(while: Chars.isDigit)
            guard let close = rest.first, close == "." || close == ")" else { return false }
            rest = rest.dropFirst()
        } else {
            return false
        }
        guard rest.isEmpty || Chars.isSpace(rest.first!) else { return false }
        rest = rest.drop(while: Chars.isSpace)
        if rest.count >= 3, rest.first == "[", rest[rest.startIndex + 2] == "]",
           [" ", "x", "X"].contains(rest[rest.startIndex + 1]) {
            rest = rest.dropFirst(3)
        }
        return rest.allSatisfy(Chars.isSpace)
    }

    /// The store keeps millisecond dates (GRDB writes `…SS.SSS`). Rounding to the nearest
    /// millisecond is idempotent on decoded values, which can come back as `k/1000 − ε`: a stored
    /// date written back unchanged stays the same date.
    static func roundedToMillis(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }
}
