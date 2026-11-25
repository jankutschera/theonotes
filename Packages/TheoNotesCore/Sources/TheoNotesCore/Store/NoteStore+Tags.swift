// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

/// What a tag rename or delete changed, and what undoing it needs.
public struct TagRewriteResult: Equatable, Sendable {
    /// Notes whose text was rewritten, in id order.
    public var changedNoteIds: [String] = []
    /// Locked notes carrying the tag; their text is not readable, so they were left alone.
    public var skippedLocked: [String] = []
    /// Read-only notes carrying the tag, left alone like locked ones (R10).
    public var skippedReadOnly: [String] = []
    /// Notes whose type could not be written: the tag would not count (e.g. inside an unclosed code fence).
    public var skippedNotApplied: [String] = []
    /// Whether any note text or tag row (spelling, icon, pin) changed; false means no undo step.
    public var didChange = false
    /// Text of each changed note before the rewrite.
    public var previousTexts: [String: String] = [:]
    /// Text the rewrite gave each changed note (undo only restores notes still at it).
    public var rewrittenTexts: [String: String] = [:]

    struct TagRowState: Equatable, Sendable {
        var key: String
        var displayPath: String
        var iconName: String?
        var isPinned: Bool
        /// Whether any note carried the tag (ancestors included) at capture time.
        var hadNotes = false

        /// What the sidebar shows of the row (`hadNotes` is bookkeeping, not state).
        var metadata: [String?] { [key, displayPath, iconName, isPinned ? "1" : "0"] }
    }

    struct NotePinState: Equatable, Sendable {
        var noteId: String
        var tagKey: String
    }

    /// The tag subtrees the operation touched (the old path; for a rename also the new one).
    var subtreeKeys: [String] = []
    /// Tag rows (spelling, icon, pin) and per-tag note pins in those subtrees before the operation.
    var previousTagRows: [TagRowState] = []
    var previousNotePins: [NotePinState] = []
    /// Recent-workspace rows in those subtrees before the operation (a rename moves them).
    var previousWorkspaceRows: [Workspace.RecentRow] = []
}

/// Tag management (inventory §2.3): rename, delete, pin, icon. Each operation is one write
/// transaction; note texts go through `writeText` (revision bump, `modifiedAt`, re-index).
/// Tags in code, math, comments and front matter are not tags and are never touched.
extension NoteStore {
    /// Rewrites `#old` and every `#old/…` descendant to `new` in all unlocked notes (any location),
    /// re-rendering each token in the form the new name needs (`#name` or `#name#`). Renaming onto
    /// an existing tag merges the two. Icons and pins move to the new paths (the target's own icon
    /// wins; a pin only survives on a root tag); per-tag note pins follow their notes.
    @discardableResult
    public func renameTag(
        _ oldPath: String, to newPath: String, now: Date = .now, preservingModifiedDate: Bool = false
    ) throws -> TagRewriteResult {
        let old = TagScanner.normalize(Array(oldPath.unicodeScalars)[...])
        let oldKey = CanonicalKey.make(old)
        let new = try Self.tagToken(newPath).name
        let newKey = CanonicalKey.make(new)
        guard !NoteType.isReservedWorkspace(path: new) else { throw StoreError.reservedTagName(newPath) }
        // `work` → `work/sub` would move the root below itself and lose its own row.
        guard !Self.isRenameIntoOwnSubtree(old, to: new) else {
            throw StoreError.tagIntoOwnSubtree(path: oldPath, target: newPath)
        }
        let depth = Self.components(old).count
        let rename = { (name: String) in Self.renamed(name, oldKey: oldKey, depth: depth, to: new) }
        return try write { db in
            let rows = try Self.tagRowStates(in: db)
            let oldRows = rows.filter { Self.isInSubtree($0.key, of: oldKey) }
            guard !old.isEmpty, !oldRows.isEmpty else { throw StoreError.tagNotFound(path: oldPath) }
            guard old != new else { return TagRewriteResult() }

            var result = try Self.prepareResult(subtrees: [oldKey, newKey], rows: rows, in: db)
            let carrying = try Self.notesCarrying(oldKey, in: db)
            let notes = carrying.notes
            result.skippedLocked = carrying.locked
            result.skippedReadOnly = carrying.readOnly
            let skipped = !carrying.locked.isEmpty || !carrying.readOnly.isEmpty
            for note in notes {
                guard let text = try Self.replacingTags(in: note.text, with: rename) else { continue }
                try Self.record(
                    note, rewrittenTo: text, now: now, preservingModifiedDate: preservingModifiedDate, into: &result, in: db)
            }

            for row in oldRows {
                guard let mapped = rename(row.displayPath) else { continue }
                let mappedKey = CanonicalKey.make(mapped)
                let keepsPin = row.isPinned && !mapped.contains("/")
                let exists = try Bool.fetchOne(
                    db, sql: "SELECT EXISTS (SELECT 1 FROM tag WHERE pathKey = ?)", arguments: [mappedKey]
                ) ?? false
                if exists || row.iconName != nil || keepsPin {
                    try db.execute(
                        sql: """
                            INSERT INTO tag (id, pathKey, displayPath) VALUES (?, ?, ?)
                            ON CONFLICT(pathKey) DO UPDATE SET displayPath = excluded.displayPath
                            """,
                        arguments: [UUIDv7.make(), mappedKey, mapped]
                    )
                    try db.execute(
                        sql: "UPDATE tag SET iconName = COALESCE(iconName, ?), isPinned = isPinned OR ? WHERE pathKey = ?",
                        arguments: [row.iconName, keepsPin, mappedKey]
                    )
                }
                // Skipped notes still carry the old tag: it keeps its icon and pin.
                if mappedKey != row.key && !skipped {
                    try db.execute(sql: "UPDATE tag SET iconName = NULL, isPinned = 0 WHERE pathKey = ?", arguments: [row.key])
                }
            }

            // Recent workspaces follow the rename (onto an existing one: merged, the later use
            // first); while skipped notes keep the old tag, its workspace stays recent too.
            for row in result.previousWorkspaceRows where Self.isInSubtree(row.key, of: oldKey) {
                guard let mapped = rename(row.displayPath) else { continue }
                let mappedKey = CanonicalKey.make(mapped)
                try Workspace.upsert(.init(key: mappedKey, displayPath: mapped, lastUsedAt: row.lastUsedAt), db: db)
                if mappedKey != row.key && !skipped {
                    try db.execute(sql: "DELETE FROM workspace WHERE pathKey = ?", arguments: [row.key])
                }
            }

            let changed = Set(result.changedNoteIds)
            let displayByKey = Dictionary(rows.map { ($0.key, $0.displayPath) }, uniquingKeysWith: { a, _ in a })
            for pin in result.previousNotePins where changed.contains(pin.noteId) && Self.isInSubtree(pin.tagKey, of: oldKey) {
                guard let mapped = displayByKey[pin.tagKey].flatMap(rename) else { continue }
                try Self.insertNotePin(noteId: pin.noteId, tagKey: CanonicalKey.make(mapped), in: db)
            }
            try NoteIndexer.removeOrphanTags(in: db)
            try Self.finish(&result, in: db)
            return result
        }
    }

    /// Gives each note exactly the type tag for `type` (none for `nil`), one write transaction.
    /// Locked and read-only notes are left alone and listed as skipped, like in `renameTag`, and so
    /// is a note where the tag would not take effect (`skippedNotApplied`); undo with
    /// `undoTagRewrite`. Sorting notes keeps their modified date.
    @discardableResult
    public func setType(
        _ type: NoteType?, noteIds: [String], now: Date = .now, preservingModifiedDate: Bool = true
    ) throws -> TagRewriteResult {
        try write { db in
            var result = TagRewriteResult()
            for id in Self.unique(noteIds) {
                let note = try Self.require(id, in: db)
                if note.isLocked { result.skippedLocked.append(id); continue }
                if note.isReadOnly { result.skippedReadOnly.append(id); continue }
                guard let text = NoteTypeText.settingIfEffective(type, in: note.text) else {
                    result.skippedNotApplied.append(id)
                    continue
                }
                guard text != note.text else { continue }
                try Self.record(
                    note, rewrittenTo: text, now: now, preservingModifiedDate: preservingModifiedDate, into: &result, in: db)
            }
            result.didChange = !result.changedNoteIds.isEmpty
            return result
        }
    }

    /// Removes `#tag` and every descendant from all unlocked notes (a line left empty is dropped);
    /// the notes themselves stay. The tag's icon and pin go too unless locked notes still carry it.
    @discardableResult
    public func deleteTag(
        _ path: String, now: Date = .now, preservingModifiedDate: Bool = false
    ) throws -> TagRewriteResult {
        let key = CanonicalKey.make(TagScanner.normalize(Array(path.unicodeScalars)[...]))
        return try write { db in
            let rows = try Self.tagRowStates(in: db)
            let subtree = rows.filter { Self.isInSubtree($0.key, of: key) }
            guard !key.isEmpty, !subtree.isEmpty else { throw StoreError.tagNotFound(path: path) }

            var result = try Self.prepareResult(subtrees: [key], rows: rows, in: db)
            let (notes, locked, readOnly) = try Self.notesCarrying(key, in: db)
            result.skippedLocked = locked
            result.skippedReadOnly = readOnly
            for note in notes {
                guard let text = Self.removingTags(from: note.text, matching: {
                    Self.isInSubtree(CanonicalKey.make($0), of: key)
                }) else { continue }
                try Self.record(
                    note, rewrittenTo: text, now: now, preservingModifiedDate: preservingModifiedDate, into: &result, in: db)
            }
            if locked.isEmpty && readOnly.isEmpty {
                for row in subtree {
                    try db.execute(sql: "UPDATE tag SET iconName = NULL, isPinned = 0 WHERE pathKey = ?", arguments: [row.key])
                }
            }
            try NoteIndexer.removeOrphanTags(in: db)
            try Self.finish(&result, in: db)
            return result
        }
    }

    /// Restores the texts of a rename or delete (only notes still at the rewritten text; others
    /// were edited since and are left alone) and the affected tags' spelling, icons and pins.
    /// Returns the restored note ids.
    @discardableResult
    public func undoTagRewrite(_ result: TagRewriteResult, now: Date = .now) throws -> [String] {
        try write { db in
            let restored = try Self.replaceTexts(
                result.changedNoteIds, expecting: result.rewrittenTexts, with: result.previousTexts, now: now, in: db
            )

            // Pins and icons go back where the notes are: a row the operation created keeps them
            // while notes still carry it (notes edited since were not restored), and a captured
            // pin returns only to a tag that has notes again or never had any.
            let captured = Dictionary(result.previousTagRows.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            let inSubtrees = { (key: String) in result.subtreeKeys.contains { Self.isInSubtree(key, of: $0) } }
            for row in try Self.tagRowStates(in: db) where inSubtrees(row.key) && captured[row.key] == nil && !row.hadNotes {
                try db.execute(sql: "UPDATE tag SET iconName = NULL, isPinned = 0 WHERE pathKey = ?", arguments: [row.key])
            }
            let hasNotes = Set(try Self.tagRowStates(in: db).filter(\.hadNotes).map(\.key))
            for var row in result.previousTagRows {
                row.isPinned = row.isPinned && (hasNotes.contains(row.key) || !row.hadNotes)
                try db.execute(
                    sql: """
                        INSERT INTO tag (id, pathKey, displayPath, iconName, isPinned) VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(pathKey) DO UPDATE SET displayPath = excluded.displayPath,
                            iconName = excluded.iconName, isPinned = excluded.isPinned
                        """,
                    arguments: [UUIDv7.make(), row.key, row.displayPath, row.iconName, row.isPinned]
                )
            }

            let restoredSet = Set(restored)
            for id in restored {
                for tagKey in try Self.notePinKeys(noteId: id, in: db) where inSubtrees(tagKey) {
                    try db.execute(
                        sql: "DELETE FROM note_pin WHERE noteId = ? AND tagId = (SELECT id FROM tag WHERE pathKey = ?)",
                        arguments: [id, tagKey]
                    )
                }
            }
            for pin in result.previousNotePins where restoredSet.contains(pin.noteId) {
                try Self.insertNotePin(noteId: pin.noteId, tagKey: pin.tagKey, in: db)
            }
            // Recent workspaces in the touched subtrees go back to what they were.
            for row in try Workspace.recentRows(inSubtrees: result.subtreeKeys, db: db) {
                try db.execute(sql: "DELETE FROM workspace WHERE pathKey = ?", arguments: [row.key])
            }
            for row in result.previousWorkspaceRows { try Workspace.upsert(row, db: db) }
            try NoteIndexer.removeOrphanTags(in: db)
            return restored
        }
    }

    /// `nil` or `""` resets the tag to its default TagCon (`TagIcons.defaultSymbol(forTagPath:)`).
    public func setTagIcon(_ path: String, symbol: String?) throws {
        let key = CanonicalKey.make(TagScanner.normalize(Array(path.unicodeScalars)[...]))
        let symbol = symbol?.isEmpty == false ? symbol : nil
        try write { db in
            try db.execute(sql: "UPDATE tag SET iconName = ? WHERE pathKey = ?", arguments: [symbol, key])
            guard db.changesCount > 0 else { throw StoreError.tagNotFound(path: path) }
        }
    }

    /// Pinned tags sit at the top of the sidebar and stay listed without notes. Root tags only.
    public func setTagPinned(_ path: String, pinned: Bool) throws {
        let name = TagScanner.normalize(Array(path.unicodeScalars)[...])
        guard !name.contains("/") else { throw StoreError.tagNotRoot(path: path) }
        try write { db in
            try db.execute(sql: "UPDATE tag SET isPinned = ? WHERE pathKey = ?", arguments: [pinned, CanonicalKey.make(name)])
            guard db.changesCount > 0 else { throw StoreError.tagNotFound(path: path) }
            if !pinned { try NoteIndexer.removeOrphanTags(in: db) }
        }
    }

    /// Notes in Notes or Archive carrying the tag or a descendant that a rename or delete would
    /// rewrite (locked and read-only ones are skipped) — the count the confirmations show.
    public func noteCount(forTag path: String) throws -> Int {
        let key = CanonicalKey.make(TagScanner.normalize(Array(path.unicodeScalars)[...]))
        return try db.pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(DISTINCT n.id) FROM note n
                JOIN note_tag nt ON nt.noteId = n.id JOIN tag t ON t.id = nt.tagId
                WHERE t.pathKey = ? AND n.location != 'trash' AND NOT n.isLocked AND NOT n.isReadOnly
                """, arguments: [key]) ?? 0
        }
    }

    /// `work` → `work/sub` (any spelling): a tag cannot move below itself.
    public static func isRenameIntoOwnSubtree(_ old: String, to new: String) -> Bool {
        let normalize = { (s: String) in CanonicalKey.make(TagScanner.normalize(Array(s.unicodeScalars)[...])) }
        let oldKey = normalize(old), newKey = normalize(new)
        return !oldKey.isEmpty && newKey != oldKey && isInSubtree(newKey, of: oldKey)
    }

    /// Where `path` ends up when `old` is renamed to `new`: `new` for `old` itself, `new/rest` for
    /// a descendant, `nil` for any other tag.
    public static func renamedTagPath(_ path: String, from old: String, to new: String) -> String? {
        let normalize = { (s: String) in TagScanner.normalize(Array(s.unicodeScalars)[...]) }
        let old = normalize(old)
        return renamed(normalize(path), oldKey: CanonicalKey.make(old), depth: components(old).count, to: normalize(new))
    }

    // MARK: - Internals

    static func isInSubtree(_ key: String, of root: String) -> Bool {
        key == root || key.hasPrefix(root + "/")
    }

    private static func components(_ name: String) -> [Substring] {
        name.split(separator: "/", omittingEmptySubsequences: true)
    }

    /// `old/rest` (any spelling of `old`) → `new/rest` with `rest` as written; `nil` outside `old`.
    static func renamed(_ name: String, oldKey: String, depth: Int, to new: String) -> String? {
        let parts = components(name)
        guard depth > 0, parts.count >= depth,
              CanonicalKey.make(parts[..<depth].joined(separator: "/")) == oldKey else { return nil }
        return ([new] + parts[depth...].map(String.init)).joined(separator: "/")
    }

    /// Replaces every tag occurrence `rename` maps to a new name with that name's token. The result
    /// must parse back to the expected tags; if open tokens would not (a following character joins
    /// the tag), every replaced token is written closed. `nil` when nothing matched.
    static func replacingTags(in text: String, with rename: (String) -> String?) throws -> String? {
        let text = TextNormalization.normalizeLineEndings(text)
        let occurrences = NoteParser.tagOccurrences(in: text)
        guard occurrences.contains(where: { rename($0.name) != nil }) else { return nil }
        let expected = occurrences.map { rename($0.name) ?? $0.name }
        for closed in [false, true] {
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { Array($0.unicodeScalars) }
            for (lineIndex, group) in Dictionary(grouping: occurrences, by: \.line) {
                let offset = lineIndex == 0 && lines[0].first == "\u{FEFF}" ? 1 : 0
                for occurrence in group.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
                    guard let name = rename(occurrence.name) else { continue }
                    let token = closed ? "#" + name + "#" : try tagToken(name).token
                    lines[lineIndex].replaceSubrange(
                        occurrence.range.lowerBound + offset..<occurrence.range.upperBound + offset,
                        with: token.unicodeScalars
                    )
                }
            }
            let result = lines.map { String(String.UnicodeScalarView($0)) }.joined(separator: "\n")
            if NoteParser.tagOccurrences(in: result).map(\.name) == expected { return result }
        }
        throw StoreError.invalidTag(path: expected.first { !occurrences.map(\.name).contains($0) } ?? "")
    }

    /// Sets `didChange`: a rewritten note, or a tag row in the touched subtrees that differs.
    private static func finish(_ result: inout TagRewriteResult, in db: Database) throws {
        let subtrees = result.subtreeKeys
        let now = try tagRowStates(in: db).filter { row in subtrees.contains { isInSubtree(row.key, of: $0) } }
        result.didChange = !result.changedNoteIds.isEmpty
            || now.map(\.metadata) != result.previousTagRows.map(\.metadata)
    }

    private static func record(
        _ note: Note, rewrittenTo text: String, now: Date, preservingModifiedDate: Bool,
        into result: inout TagRewriteResult, in db: Database
    ) throws {
        let written = try writeText(
            id: note.id, text: text, expectedRevision: note.revision, now: now,
            preservingModifiedDate: preservingModifiedDate, in: db)
        result.changedNoteIds.append(note.id)
        result.previousTexts[note.id] = note.text
        result.rewrittenTexts[note.id] = written.text
    }

    private static func prepareResult(
        subtrees: [String], rows: [TagRewriteResult.TagRowState], in db: Database
    ) throws -> TagRewriteResult {
        var result = TagRewriteResult()
        result.subtreeKeys = subtrees
        let inSubtrees = { (key: String) in subtrees.contains { isInSubtree(key, of: $0) } }
        result.previousTagRows = rows.filter { inSubtrees($0.key) }
        result.previousWorkspaceRows = try Workspace.recentRows(inSubtrees: subtrees, db: db)
        result.previousNotePins = try Row.fetchAll(db, sql: """
            SELECT p.noteId, t.pathKey FROM note_pin p JOIN tag t ON t.id = p.tagId ORDER BY p.noteId, t.pathKey
            """)
            .map { TagRewriteResult.NotePinState(noteId: $0[0], tagKey: $0[1]) }
            .filter { inSubtrees($0.tagKey) }
        return result
    }

    static func tagRowStates(in db: Database) throws -> [TagRewriteResult.TagRowState] {
        try Row.fetchAll(db, sql: """
            SELECT pathKey, displayPath, iconName, isPinned,
                   EXISTS (SELECT 1 FROM note_tag nt WHERE nt.tagId = tag.id) AS hadNotes
            FROM tag ORDER BY pathKey
            """).map {
            TagRewriteResult.TagRowState(
                key: $0[0], displayPath: $0[1], iconName: $0[2], isPinned: $0[3], hadNotes: $0[4]
            )
        }
    }

    /// Notes carrying the tag or a descendant (ancestors are materialized in `note_tag`, so the
    /// root's rows cover the subtree): the ones to rewrite, and the skipped locked and read-only ids.
    private static func notesCarrying(
        _ key: String, in db: Database
    ) throws -> (notes: [Note], locked: [String], readOnly: [String]) {
        let notes = try Note.fetchAll(db, sql: """
            SELECT n.* FROM note n
            WHERE EXISTS (SELECT 1 FROM note_tag nt JOIN tag t ON t.id = nt.tagId
                          WHERE nt.noteId = n.id AND t.pathKey = ?)
            ORDER BY n.id
            """, arguments: [key])
        return (
            notes.filter { !$0.isLocked && !$0.isReadOnly },
            notes.filter(\.isLocked).map(\.id),
            notes.filter { $0.isReadOnly && !$0.isLocked }.map(\.id)
        )
    }

    private static func notePinKeys(noteId: String, in db: Database) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT t.pathKey FROM note_pin p JOIN tag t ON t.id = p.tagId WHERE p.noteId = ?
            """, arguments: [noteId])
    }

    /// Pins the note within the tag if it carries it.
    private static func insertNotePin(noteId: String, tagKey: String, in db: Database) throws {
        try db.execute(sql: """
            INSERT OR IGNORE INTO note_pin (noteId, tagId)
            SELECT nt.noteId, nt.tagId FROM note_tag nt JOIN tag t ON t.id = nt.tagId
            WHERE nt.noteId = ? AND t.pathKey = ?
            """, arguments: [noteId, tagKey])
    }
}
