// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

/// A workspace (spec §3.5, inventory §2.1): a tag that narrows a window to the notes carrying it
/// or one of its descendants. `LibraryQueries` (lists, counts, tag tree, snapshot) and
/// `SearchCompiler` take one and apply `predicate` to every statement; Quick Open adopts the same
/// predicate. Two workspaces are equal when their tags are (canonical key), whatever the spelling.
public struct Workspace: Hashable, Sendable {
    /// The tag path as chosen (the spelling the switcher shows).
    public let path: String
    /// The tag's canonical key (`tag.pathKey`).
    public let key: String

    public init(path: String) {
        self.path = path
        key = CanonicalKey.make(TagScanner.normalize(Array(path.unicodeScalars)[...]))
    }

    public static func == (a: Workspace, b: Workspace) -> Bool { a.key == b.key }
    public func hash(into hasher: inout Hasher) { hasher.combine(key) }

    /// A SQL boolean over the note alias `note`: it carries the tag or a descendant (`note_tag`
    /// materializes ancestors, so one row per note says so). Bind `arguments` where `sql` appears.
    public func predicate(note alias: String = "n") -> (sql: String, arguments: [(any DatabaseValueConvertible)?]) {
        ("""
            EXISTS (SELECT 1 FROM note_tag ws_nt WHERE ws_nt.noteId = \(alias).id
                AND ws_nt.tagId = (SELECT id FROM tag WHERE pathKey = ?))
            """, [key])
    }

    /// The tag `tagPath` is the workspace's tag or one of its descendants.
    public func includes(tagPath: String) -> Bool {
        let other = Workspace(path: tagPath).key
        return other == key || other.hasPrefix(key + "/")
    }

    /// The note (any location) carries the tag or a descendant.
    public func contains(noteId: String, db: Database) throws -> Bool {
        let (sql, arguments) = predicate()
        return try Bool.fetchOne(db, sql: "SELECT \(sql) FROM note n WHERE n.id = ?", arguments: StatementArguments(arguments + [noteId])) ?? false
    }

    /// The tag still exists in the library (it disappears with the last note carrying it, unless pinned).
    public func exists(db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM tag WHERE pathKey = ?)", arguments: [key]) ?? false
    }

    // MARK: - Recents (`workspace` table, migration v6)

    /// How many recently used workspaces are kept.
    public static let recentLimit = 5

    /// Recently used workspaces whose tag still exists, most recent first, in the spelling used.
    public static func recent(db: Database) throws -> [Workspace] {
        try String.fetchAll(db, sql: """
            SELECT w.displayPath FROM workspace w
            WHERE EXISTS (SELECT 1 FROM tag t WHERE t.pathKey = w.pathKey)
            ORDER BY w.lastUsedAt DESC, w.pathKey
            LIMIT ?
            """, arguments: [recentLimit]).map(Workspace.init(path:))
    }

    /// Pinned root tags (the switcher's "Pinned" section), in sidebar order.
    public static func pinned(db: Database) throws -> [Workspace] {
        try String.fetchAll(db, sql: "SELECT displayPath FROM tag WHERE isPinned AND instr(pathKey, '/') = 0")
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map(Workspace.init(path:))
    }

    /// Records a use (entering the workspace). A row is kept while fewer than `recentLimit`
    /// workspaces whose tag exists are more recent: the newest live ones fill the list, and a row
    /// whose tag is gone neither takes a live one's place nor is dropped while it could still
    /// come back with its tag (an undone Delete Tag).
    static func recordUse(_ workspace: Workspace, now: Date, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO workspace (pathKey, displayPath, lastUsedAt) VALUES (?, ?, ?)
            ON CONFLICT(pathKey) DO UPDATE SET displayPath = excluded.displayPath, lastUsedAt = excluded.lastUsedAt
            """, arguments: [workspace.key, workspace.path, now])
        try db.execute(sql: """
            DELETE FROM workspace WHERE (
                SELECT COUNT(*) FROM workspace w
                WHERE EXISTS (SELECT 1 FROM tag t WHERE t.pathKey = w.pathKey)
                  AND (w.lastUsedAt > workspace.lastUsedAt
                       OR (w.lastUsedAt = workspace.lastUsedAt AND w.pathKey < workspace.pathKey))
            ) >= ?
            """, arguments: [recentLimit])
    }

    /// A recent-workspace row (tag renames move them; undo puts them back).
    struct RecentRow: Equatable, Sendable {
        var key: String
        var displayPath: String
        var lastUsedAt: Date
    }

    /// The rows of workspaces in the tag subtrees `roots` (each root and its descendants).
    static func recentRows(inSubtrees roots: [String], db: Database) throws -> [RecentRow] {
        try Row.fetchAll(db, sql: "SELECT pathKey, displayPath, lastUsedAt FROM workspace ORDER BY pathKey")
            .map { RecentRow(key: $0[0], displayPath: $0[1], lastUsedAt: $0[2]) }
            .filter { row in roots.contains { NoteStore.isInSubtree(row.key, of: $0) } }
    }

    /// Writes `row` (onto an existing row of the same tag: the later use wins the time).
    static func upsert(_ row: RecentRow, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO workspace (pathKey, displayPath, lastUsedAt) VALUES (?, ?, ?)
            ON CONFLICT(pathKey) DO UPDATE SET displayPath = excluded.displayPath,
                lastUsedAt = MAX(lastUsedAt, excluded.lastUsedAt)
            """, arguments: [row.key, row.displayPath, row.lastUsedAt])
    }
}

/// What the workspace switcher offers (spec §4.2): pinned root tags and recent workspaces.
public struct WorkspaceChoices: Equatable, Sendable {
    public var pinned: [Workspace] = []
    public var recent: [Workspace] = []

    public init(pinned: [Workspace] = [], recent: [Workspace] = []) {
        self.pinned = pinned; self.recent = recent
    }
}

extension NoteStore {
    /// Entering `workspace`: it becomes the most recent one.
    public func recordWorkspaceUse(_ workspace: Workspace, now: Date = .now) throws {
        try write { try Workspace.recordUse(workspace, now: now, db: $0) }
    }
}
