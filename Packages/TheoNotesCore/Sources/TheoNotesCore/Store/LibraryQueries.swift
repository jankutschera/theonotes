// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

public enum SidebarScope: Hashable, Sendable {
    case notes, inbox, pinned, untagged, todo, today, locked, archive, trash
    case type(NoteType)
    case tag(String)
}

public struct NoteListItem: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var modifiedAt: Date
    public var createdAt: Date
    /// Pinned in the queried scope: per-tag pin in a tag scope, global pin elsewhere.
    public var isPinned: Bool
    public var isLocked: Bool
    public var isReadOnly: Bool
    public var hasAttachments: Bool
    public var firstImageFilename: String?
    /// How the note was captured (`CaptureSource`); nil for an ordinary note.
    public var captureSource: CaptureSource?
    /// The note's type (`NoteType`), nil for an untyped note.
    public var noteType: NoteType?

    public init(
        id: String, title: String, subtitle: String, modifiedAt: Date, createdAt: Date, isPinned: Bool,
        isLocked: Bool, isReadOnly: Bool, hasAttachments: Bool, firstImageFilename: String?,
        captureSource: CaptureSource? = nil, noteType: NoteType? = nil
    ) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.modifiedAt = modifiedAt
        self.createdAt = createdAt; self.isPinned = isPinned; self.isLocked = isLocked
        self.isReadOnly = isReadOnly; self.hasAttachments = hasAttachments
        self.firstImageFilename = firstImageFilename; self.captureSource = captureSource
        self.noteType = noteType
    }
}

/// `LibraryQueries.search` result: matching notes and the strings to highlight in them.
public struct SearchResult: Equatable, Sendable {
    public var items: [NoteListItem]
    public var terms: [String]

    public init(items: [NoteListItem], terms: [String]) {
        self.items = items; self.terms = terms
    }
}

public struct TagNode: Identifiable, Equatable, Sendable {
    /// The tag's `pathKey`.
    public var id: String
    public var path: String
    /// Last component of `path`.
    public var name: String
    public var noteCount: Int
    public var isPinned: Bool
    public var iconName: String?
    public var children: [TagNode]
}

public struct SidebarCounts: Equatable, Sendable {
    public var notes = 0, pinned = 0, untagged = 0, todo = 0, today = 0
    public var locked = 0, archive = 0, trash = 0
    public var inbox = 0, ideas = 0, logs = 0, references = 0

    public init(
        notes: Int = 0, pinned: Int = 0, untagged: Int = 0, todo: Int = 0, today: Int = 0,
        locked: Int = 0, archive: Int = 0, trash: Int = 0,
        inbox: Int = 0, ideas: Int = 0, logs: Int = 0, references: Int = 0
    ) {
        self.notes = notes; self.pinned = pinned; self.untagged = untagged; self.todo = todo
        self.today = today; self.locked = locked; self.archive = archive; self.trash = trash
        self.inbox = inbox; self.ideas = ideas; self.logs = logs; self.references = references
    }
}

/// Everything the sidebar and the note list show for one scope, read in one transaction.
public struct LibrarySnapshot: Equatable, Sendable {
    public var items: [NoteListItem] = []
    public var tagTree: [TagNode] = []
    public var counts = SidebarCounts()
    /// The `noteSort` setting the items are ordered by.
    public var sort: NoteSort = SettingKey<NoteSort>.noteSort.defaultValue
    /// The workspace switcher's pinned and recent workspaces (never narrowed by the workspace).
    public var workspaceChoices = WorkspaceChoices()
    /// False when the snapshot's workspace names a tag that no longer exists.
    public var workspaceExists = true

    public init() {}
}

/// Read-only queries behind the sidebar and the note list. Each is one SQL statement (the tag
/// tree: one statement plus in-memory assembly), regardless of library size. With a `workspace`
/// every one covers only the notes carrying its tag or a descendant (`Workspace.predicate`).
public enum LibraryQueries {
    public static func notes(
        in scope: SidebarScope, sort: NoteSort, workspace: Workspace? = nil, now: Date, calendar: Calendar, db: Database
    ) throws -> [NoteListItem] {
        let clause = scopeClause(scope, workspace: workspace, now: now, calendar: calendar)
        let sql = """
            SELECT n.id, n.title, n.subtitle, n.modifiedAt, n.createdAt, n.isLocked, n.isReadOnly,
                   COALESCE(s.hasImages OR s.hasFiles, 0) AS hasAttachments, s.firstImage,
                   (\(clause.pinnedExpr)) AS isPinned, n.captureSource, n.noteType
            FROM note n LEFT JOIN note_stats s ON s.noteId = n.id
            WHERE \(clause.filter)
            ORDER BY isPinned DESC, \(orderBy(sort)), n.id
            """
        return try listItems(db, sql: sql, arguments: StatementArguments(clause.pinnedArguments + clause.filterArguments))
    }

    /// One note's list row outside any scope (pinned = its global pin); nil when it is gone or in the Trash.
    public static func item(id: String, db: Database) throws -> NoteListItem? {
        let sql = """
            SELECT n.id, n.title, n.subtitle, n.modifiedAt, n.createdAt, n.isLocked, n.isReadOnly,
                   COALESCE(s.hasImages OR s.hasFiles, 0) AS hasAttachments, s.firstImage,
                   n.isPinnedGlobal, n.captureSource, n.noteType
            FROM note n LEFT JOIN note_stats s ON s.noteId = n.id
            WHERE n.id = ? AND n.deletedAt IS NULL AND n.location != 'trash'
            """
        return try listItems(db, sql: sql, arguments: [id]).first
    }

    /// Notes in `scope` matching Bear search `query` (see `SearchParser`, `SearchCompiler`),
    /// ordered like the note list (pinned first, then `sort`). `terms`: what to highlight.
    /// The UI pages results (ruling R8): `limit` rows from `offset` (ignored without `limit`).
    public static func search(
        _ query: String, in scope: SidebarScope, sort: NoteSort, workspace: Workspace? = nil, now: Date,
        calendar: Calendar, locale: Locale = .current, limit: Int? = nil, offset: Int = 0, db: Database
    ) throws -> SearchResult {
        let expr = SearchParser.parse(query, locale: locale)
        let (sql, arguments) = SearchCompiler.compile(expr, scope: scope, sort: sort, workspace: workspace, now: now,
                                                  calendar: calendar, limit: limit, offset: offset)
        return SearchResult(items: try listItems(db, sql: sql, arguments: arguments), terms: SearchCompiler.highlightTerms(expr))
    }

    /// The list filter and pinned expression of a sidebar scope (`n` = note), the filter narrowed
    /// to `workspace`. The pinned expression comes first in the statement, so its arguments are
    /// bound first.
    static func scopeClause(_ scope: SidebarScope, workspace: Workspace? = nil, now: Date, calendar: Calendar) -> (
        pinnedExpr: String, pinnedArguments: [(any DatabaseValueConvertible)?],
        filter: String, filterArguments: [(any DatabaseValueConvertible)?]
    ) {
        let clause = baseScopeClause(scope, now: now, calendar: calendar)
        guard let workspace else { return clause }
        let inWorkspace = workspace.predicate()
        return (clause.pinnedExpr, clause.pinnedArguments,
                "(\(clause.filter)) AND \(inWorkspace.sql)", clause.filterArguments + inWorkspace.arguments)
    }

    /// No note_tag row other than a direct reserved type tag (`n` = note).
    static let untaggedExpr = """
        NOT EXISTS (SELECT 1 FROM note_tag t JOIN tag g ON g.id = t.tagId
            WHERE t.noteId = n.id AND NOT (t.isDirect AND g.pathKey IN ('idea', 'log', 'ref')))
        """

    /// `scopeClause` without a workspace. Todo and Today leave templates out (spec §4.10).
    private static func baseScopeClause(_ scope: SidebarScope, now: Date, calendar: Calendar) -> (
        pinnedExpr: String, pinnedArguments: [(any DatabaseValueConvertible)?],
        filter: String, filterArguments: [(any DatabaseValueConvertible)?]
    ) {
        switch scope {
        case .notes:
            return ("n.isPinnedGlobal", [], "n.location = 'notes'", [])
        case .pinned:
            return ("1", [], """
                n.location = 'notes' AND (n.isPinnedGlobal
                    OR EXISTS (SELECT 1 FROM note_pin p WHERE p.noteId = n.id))
                """, [])
        case .inbox:
            let template = Templates.predicate()
            return ("n.isPinnedGlobal", [],
                    "n.location = 'notes' AND n.noteType IS NULL AND NOT n.isLocked AND NOT \(template.sql)",
                    template.arguments)
        case .type(let type):
            let template = Templates.predicate()
            return ("n.isPinnedGlobal", [],
                    "n.location = 'notes' AND n.noteType = ? AND NOT \(template.sql)",
                    [type.rawValue] + template.arguments)
        case .untagged:
            return ("n.isPinnedGlobal", [], "n.location = 'notes' AND \(untaggedExpr)", [])
        case .todo:
            let template = Templates.predicate()
            return ("n.isPinnedGlobal", [], "n.location = 'notes' AND COALESCE(s.openTodos, 0) > 0 AND NOT \(template.sql)",
                    template.arguments)
        case .today:
            let (start, end) = dayBounds(now: now, calendar: calendar)
            let template = Templates.predicate()
            return ("n.isPinnedGlobal", [],
                    "n.location = 'notes' AND n.modifiedAt >= ? AND n.modifiedAt < ? AND NOT \(template.sql)",
                    [start, end] + template.arguments)
        case .locked:
            return ("n.isPinnedGlobal", [], "n.location = 'notes' AND n.isLocked", [])
        case .archive:
            return ("n.isPinnedGlobal", [], "n.location = 'archive'", [])
        case .trash:
            return ("n.isPinnedGlobal", [], "n.location = 'trash'", [])
        case .tag(let path):
            let key = tagKey(path)
            return ("""
                EXISTS (SELECT 1 FROM note_pin p WHERE p.noteId = n.id
                    AND p.tagId = (SELECT id FROM tag WHERE pathKey = ?))
                """, [key], """
                n.location = 'notes' AND EXISTS (SELECT 1 FROM note_tag t WHERE t.noteId = n.id
                    AND t.tagId = (SELECT id FROM tag WHERE pathKey = ?))
                """, [key])
        }
    }

    /// Positional decoding of the list columns: by-name lookups dominate the cost at 10k rows in
    /// debug builds.
    private static func listItems(_ db: Database, sql: String, arguments: StatementArguments) throws -> [NoteListItem] {
        var items: [NoteListItem] = []
        let cursor = try Row.fetchCursor(db, sql: sql, arguments: arguments)
        while let row = try cursor.next() {
            items.append(NoteListItem(
                id: row[0], title: row[1], subtitle: row[2], modifiedAt: row[3], createdAt: row[4],
                isPinned: row[9], isLocked: row[5], isReadOnly: row[6],
                hasAttachments: row[7], firstImageFilename: row[8], captureSource: row[10],
                noteType: (row[11] as String?).flatMap(NoteType.init(rawValue:))
            ))
        }
        return items
    }

    /// Tags with at least one note in Notes (descendants included), or pinned. Missing ancestors
    /// of a shown tag are synthesized; labels come from each node's own row. In a `workspace`:
    /// only tags of its notes in Notes, counting those notes (pinned tags get no exception).
    public static func tagTree(workspace: Workspace? = nil, db: Database) throws -> [TagNode] {
        let inWorkspace = workspace?.predicate()
        let rows = try Row.fetchAll(db, sql: """
            SELECT t.pathKey, t.displayPath, t.iconName, t.isPinned, COUNT(n.id) AS noteCount
            FROM tag t
            LEFT JOIN note_tag nt ON nt.tagId = t.id
            LEFT JOIN note n ON n.id = nt.noteId AND n.location = 'notes'\(inWorkspace.map { " AND " + $0.sql } ?? "")
            GROUP BY t.id
            """, arguments: StatementArguments(inWorkspace?.arguments ?? []))
        struct Entry {
            var path: String; var count: Int; var isPinned: Bool; var icon: String?
            var visible: Bool; var synthesized = false
        }
        var entries: [String: Entry] = [:]
        for row in rows {
            let count: Int = row["noteCount"]
            let pinned: Bool = row["isPinned"]
            entries[row["pathKey"]] = Entry(
                path: row["displayPath"], count: count, isPinned: pinned, icon: row["iconName"],
                visible: (count > 0 || (pinned && workspace == nil)) && !NoteType.isReservedWorkspace(path: row["pathKey"])
            )
        }

        // Synthesize missing ancestors of visible tags; a hidden existing ancestor is revealed.
        for (key, entry) in entries where entry.visible {
            let keyParts = key.split(separator: "/", omittingEmptySubsequences: false)
            let pathParts = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            guard keyParts.count == pathParts.count else { continue }
            for depth in 1..<max(keyParts.count, 1) {
                let ancestorKey = keyParts[..<depth].joined(separator: "/")
                if entries[ancestorKey] == nil {
                    entries[ancestorKey] = Entry(
                        path: pathParts[..<depth].joined(separator: "/"), count: 0,
                        isPinned: false, icon: nil, visible: true, synthesized: true
                    )
                } else if !entries[ancestorKey]!.visible {
                    entries[ancestorKey]!.visible = true
                }
            }
        }

        var childKeys: [String: [String]] = [:]
        var rootKeys: [String] = []
        for key in entries.keys where entries[key]!.visible {
            if let slash = key.lastIndex(of: "/"), entries[String(key[..<slash])] != nil {
                childKeys[String(key[..<slash]), default: []].append(key)
            } else {
                rootKeys.append(key)
            }
        }

        func build(_ key: String) -> TagNode {
            let entry = entries[key]!
            let children = (childKeys[key] ?? []).map(build)
            let count = entry.synthesized ? children.reduce(0) { $0 + $1.noteCount } : entry.count
            return TagNode(
                id: key, path: entry.path,
                name: String(entry.path.split(separator: "/", omittingEmptySubsequences: false).last ?? ""),
                noteCount: count, isPinned: entry.isPinned, iconName: entry.icon,
                children: sorted(children)
            )
        }
        return sorted(rootKeys.map(build))
    }

    public static func counts(workspace: Workspace? = nil, now: Date, calendar: Calendar, db: Database) throws -> SidebarCounts {
        let (start, end) = dayBounds(now: now, calendar: calendar)
        let inWorkspace = workspace?.predicate()
        let template = Templates.predicate()
        let row = try Row.fetchOne(db, sql: """
            SELECT
                COALESCE(SUM(n.location = 'notes'), 0) AS notes,
                COALESCE(SUM(n.location = 'notes' AND (n.isPinnedGlobal
                    OR EXISTS (SELECT 1 FROM note_pin p WHERE p.noteId = n.id))), 0) AS pinned,
                COALESCE(SUM(n.location = 'notes' AND \(untaggedExpr)), 0) AS untagged,
                COALESCE(SUM(n.location = 'notes' AND COALESCE(s.openTodos, 0) > 0 AND NOT \(template.sql)), 0) AS todo,
                COALESCE(SUM(n.location = 'notes' AND n.modifiedAt >= ? AND n.modifiedAt < ? AND NOT \(template.sql)), 0) AS today,
                COALESCE(SUM(n.location = 'notes' AND n.isLocked), 0) AS locked,
                COALESCE(SUM(n.location = 'archive'), 0) AS archive,
                COALESCE(SUM(n.location = 'trash'), 0) AS trash,
                COALESCE(SUM(n.location = 'notes' AND n.noteType IS NULL AND NOT n.isLocked AND NOT \(template.sql)), 0) AS inbox,
                COALESCE(SUM(n.location = 'notes' AND n.noteType = 'idea' AND NOT \(template.sql)), 0) AS ideas,
                COALESCE(SUM(n.location = 'notes' AND n.noteType = 'log' AND NOT \(template.sql)), 0) AS logs,
                COALESCE(SUM(n.location = 'notes' AND n.noteType = 'reference' AND NOT \(template.sql)), 0) AS refs
            FROM note n LEFT JOIN note_stats s ON s.noteId = n.id
            \(inWorkspace.map { "WHERE " + $0.sql } ?? "")
            """, arguments: StatementArguments(
                template.arguments + [start, end] + template.arguments + template.arguments + template.arguments
                + template.arguments + template.arguments + (inWorkspace?.arguments ?? [])))!
        return SidebarCounts(
            notes: row["notes"], pinned: row["pinned"], untagged: row["untagged"], todo: row["todo"],
            today: row["today"], locked: row["locked"], archive: row["archive"], trash: row["trash"],
            inbox: row["inbox"], ideas: row["ideas"], logs: row["logs"], references: row["refs"]
        )
    }

    /// The list for `scope` (ordered by the `noteSort` setting), the tag tree and the counts, all
    /// within `workspace`, plus the workspace switcher's choices.
    public static func snapshot(
        scope: SidebarScope, workspace: Workspace? = nil, now: Date, calendar: Calendar, db: Database
    ) throws -> LibrarySnapshot {
        var snapshot = LibrarySnapshot()
        snapshot.sort = try Settings.value(.noteSort, in: db)
        snapshot.items = try notes(in: scope, sort: snapshot.sort, workspace: workspace, now: now, calendar: calendar, db: db)
        snapshot.tagTree = try tagTree(workspace: workspace, db: db)
        snapshot.counts = try counts(workspace: workspace, now: now, calendar: calendar, db: db)
        snapshot.workspaceChoices = WorkspaceChoices(pinned: try Workspace.pinned(db: db), recent: try Workspace.recent(db: db))
        snapshot.workspaceExists = try workspace?.exists(db: db) ?? true
        return snapshot
    }

    /// One GRDB `ValueObservation` over `snapshot` (it tracks every table the queries read:
    /// note, note_stats, note_tag, note_pin, tag, setting, workspace). The current value is delivered before
    /// this returns, later ones after each change committed through `database` (this process
    /// only; other processes' writes arrive via `ChangeNotifier`).
    @MainActor
    public static func observeSnapshot(
        scope: SidebarScope,
        workspace: Workspace? = nil,
        database: AppDatabase,
        calendar: Calendar,
        now: @escaping @Sendable () -> Date,
        onError: @escaping @MainActor (Error) -> Void,
        onChange: @escaping @MainActor (LibrarySnapshot) -> Void
    ) -> ObservationToken {
        let cancellable = ValueObservation
            .tracking { db in try snapshot(scope: scope, workspace: workspace, now: now(), calendar: calendar, db: db) }
            .removeDuplicates()
            .start(in: database.pool, scheduling: .immediate, onError: onError, onChange: onChange)
        return ObservationToken { cancellable.cancel() }
    }

    // MARK: - Helpers

    private static func sorted(_ nodes: [TagNode]) -> [TagNode] {
        nodes.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    private static func dayBounds(now: Date, calendar: Calendar) -> (Date, Date) {
        let start = calendar.startOfDay(for: now)
        return (start, calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400))
    }

    private static func tagKey(_ path: String) -> String {
        CanonicalKey.make(TagScanner.normalize(Array(path.unicodeScalars)[...]))
    }

    static func orderBy(_ sort: NoteSort) -> String {
        switch sort {
        case .modifiedDescending: "n.modifiedAt DESC"
        case .modifiedAscending: "n.modifiedAt ASC"
        case .createdDescending: "n.createdAt DESC"
        case .createdAscending: "n.createdAt ASC"
        case .titleAscending: "n.titleKey ASC, n.modifiedAt DESC"
        case .titleDescending: "n.titleKey DESC, n.modifiedAt DESC"
        }
    }
}
