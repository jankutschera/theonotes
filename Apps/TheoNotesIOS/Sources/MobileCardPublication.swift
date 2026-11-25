// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import TheoNotesCore

/// App-only builder. Widgets read the shared wire DTO and never open the library.
@MainActor enum MobileCardPublication {
    nonisolated static func libraryID(for paths: AppPaths) -> String {
        SyncWire.hash(Data(paths.root.standardizedFileURL.resolvingSymlinksInPath().path.utf8))
    }

    nonisolated static let maximumConfiguredNotes = 200
    nonisolated static let maximumConfiguredTags = 100

    static func make(library: MobileLibrary, now: Date = .now, calendar: Calendar = .current,
                     configuredNoteIDs: Set<String> = [], configuredTagIDs: Set<String> = []) throws -> WidgetSnapshot {
        guard !library.isClosed, !library.isClosing else { throw WidgetSnapshot.Invalid.publication }
        return try make(store: library.store, database: library.database, paths: library.paths,
            appLockEnabled: library.appLockEnabled, now: now, calendar: calendar,
            configuredNoteIDs: configuredNoteIDs, configuredTagIDs: configuredTagIDs)
    }

    /// Immutable inputs only: detached callers must retain the database until this read completes.
    nonisolated static func make(store: NoteStore, database: AppDatabase, paths: AppPaths,
                     appLockEnabled: Bool, now: Date = .now, calendar: Calendar = .current,
                     configuredNoteIDs: Set<String> = [], configuredTagIDs: Set<String> = []) throws -> WidgetSnapshot {
        let configuredTags = Set(configuredTagIDs.map(CanonicalKey.make))
        guard configuredNoteIDs.count <= maximumConfiguredNotes, configuredTags.count <= maximumConfiguredTags,
              (configuredNoteIDs.union(configuredTags)).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") }) else {
            throw WidgetSnapshot.Invalid.publication
        }
        let id = libraryID(for: paths)
        if appLockEnabled { return .locked(libraryID: id, now: now) }
        let nextUp = try CardPublication.make(card: FocusCard(store: store),
            appLockEnabled: appLockEnabled, now: now, calendar: calendar)
        let snapshot = try database.pool.read { db in
            func cards(_ scope: SidebarScope, limit: Int, ids: Set<String>? = nil) throws -> [WidgetSnapshot.NoteCard] {
                if let ids, ids.isEmpty { return [] }
                let query = SearchCompiler.compile(.not(.special(.locked)), scope: scope,
                    sort: .modifiedDescending, now: now, calendar: calendar)
                var arguments = query.arguments
                let selected = ids?.sorted()
                let restriction = selected.map { " AND q.id IN (" + Array(repeating: "?", count: $0.count).joined(separator: ",") + ")" } ?? ""
                if let selected { for id in selected { arguments += [id] } }
                arguments += [limit]
                let rows = try Row.fetchAll(db, sql: """
                    SELECT q.id, substr(q.title,1,256) AS title, substr(q.subtitle,1,512) AS subtitle
                    FROM (\(query.sql)) q JOIN note n ON n.id=q.id
                    WHERE n.deletedAt IS NULL AND n.location='notes' AND NOT n.isLocked\(restriction)
                    ORDER BY q.isPinned DESC,q.modifiedAt DESC,q.id LIMIT ?
                    """, arguments: arguments)
                return rows.map(card)
            }
            // Recent use is a note-activity proxy (opening/modifying a readable tagged note),
            // not a persisted history of selecting a tag. Inbox is supplied first by the entity query.
            let tagIDs = try String.fetchAll(db, sql: """
                SELECT t.pathKey FROM tag t JOIN note_tag nt ON nt.tagId=t.id
                JOIN note n ON n.id=nt.noteId LEFT JOIN note_ui_state u ON u.noteId=n.id
                WHERE length(CAST(t.pathKey AS BLOB)) <= 256 AND n.location='notes'
                  AND n.deletedAt IS NULL AND NOT n.isLocked
                GROUP BY t.id,t.pathKey,t.isPinned
                ORDER BY t.isPinned DESC,MAX(MAX(n.modifiedAt,COALESCE(u.lastOpenedAt,n.modifiedAt))) DESC,t.pathKey
                LIMIT 100
                """)
            func lists(_ ids: [String]) throws -> [WidgetSnapshot.TagList] {
                try ids.compactMap { tag in
                    let notes = try cards(.tag(tag), limit: 20)
                    return notes.isEmpty ? nil : .init(id: tag, notes: notes)
                }
            }
            let tags = try lists(tagIDs)
            let selectedTags = try lists(configuredTags.sorted())
            let selectedPins = try cards(.pinned, limit: maximumConfiguredNotes, ids: configuredNoteIDs)
            let last = try Row.fetchOne(db, sql: """
                SELECT n.id,substr(n.title,1,256) AS title,substr(n.subtitle,1,512) AS subtitle
                FROM note n JOIN note_ui_state u ON u.noteId=n.id
                WHERE n.location='notes' AND n.deletedAt IS NULL AND NOT n.isLocked AND u.lastOpenedAt IS NOT NULL
                ORDER BY u.lastOpenedAt DESC,n.id LIMIT 1
                """)
            let timeline = try nextUp.entries.filter { $0.date <= now.addingTimeInterval(WidgetSnapshot.lifetime) }.map { entry -> WidgetSnapshot.NextUpEntry in
                guard entry.state == .candidate, let noteID = entry.noteId else {
                    return .init(date: entry.date, state: entry.state == .locked ? .locked : .empty)
                }
                guard let row = try Row.fetchOne(db, sql: "SELECT isLocked,location,deletedAt FROM note WHERE id=?", arguments: [noteID]),
                      row["deletedAt"] as Date? == nil, row["location"] as String == "notes" else {
                    return .init(date: entry.date, state: .empty)
                }
                if row["isLocked"] as Bool { return .init(date: entry.date, state: .locked) }
                return .init(date: entry.date, state: .candidate, noteId: noteID, kind: entry.kind,
                             title: bounded(entry.title ?? "", bytes: 256), line: entry.line.map { bounded($0, bytes: 512) })
            }
            return WidgetSnapshot(libraryID: id, generatedAt: now, redacted: false, nextUp: timeline,
                pinned: try cards(.pinned, limit: 200),
                inbox: try cards(.inbox, limit: 20), tags: tags, lastOpened: last.map(card),
                configuredPins: selectedPins, configuredTags: selectedTags)
        }
        try snapshot.validate(now: now)
        guard try snapshot.encoded().count <= WidgetSnapshot.maximumBytes else { throw WidgetSnapshot.Invalid.publication }
        return snapshot
    }

    nonisolated private static func card(_ row: Row) -> WidgetSnapshot.NoteCard {
        .init(id: row["id"], title: bounded(row["title"], bytes: 256), firstLine: bounded(row["subtitle"], bytes: 512))
    }

    nonisolated private static func bounded(_ text: String, bytes limit: Int) -> String {
        var result = String.UnicodeScalarView(), count = 0
        for scalar in text.unicodeScalars where scalar.value != 0 {
            let size = String(scalar).utf8.count
            guard count + size <= limit else { break }
            result.append(scalar); count += size
        }
        return String(result)
    }
}
