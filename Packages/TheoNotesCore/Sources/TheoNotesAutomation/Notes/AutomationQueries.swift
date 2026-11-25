// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import GRDB

/// `--location`.
enum LocationFilter: String {
    case notes, trash, archive, all

    static func parse(_ raw: String?) throws(AutomationError) -> LocationFilter {
        guard let raw else { return .notes }
        guard let filter = LocationFilter(rawValue: raw) else {
            throw AutomationError(code: .usage, message: "Invalid location: \(raw)")
        }
        return filter
    }

    var noteLocation: NoteLocation? { NoteLocation(rawValue: rawValue) }
}

/// The two queries behind `list` and `search`: which notes, in which order, and how many in all.
///
/// Each comes as `…Notes` (the note rows, read once) and as a plain form that returns ids (and match
/// counts). `countTotal: false` skips the `COUNT(*)` for callers that never print the total; the
/// total is then only the number of rows returned. `limit: 0` reads no rows at all, so `--count`
/// costs one `COUNT(*)`.
enum AutomationQueries {
    /// Notes in `location`, narrowed to `tag` (the tag and its descendants) when given. `limit` nil
    /// returns every note; 0 returns none (only the total).
    static func listNotes(
        location: LocationFilter, tag: String?, sort: SortSpec, limit: Int?, offset: Int, scope: NoteScope,
        countTotal: Bool = true, db: Database
    ) throws -> (notes: [Note], total: Int) {
        var conditions = ["n.deletedAt IS NULL"]
        var arguments: [(any DatabaseValueConvertible)?] = []
        locationCondition(location, into: &conditions, arguments: &arguments)
        if let key = tagKey(tag) {
            conditions.append(
                "n.id IN (SELECT nt.noteId FROM note_tag nt JOIN tag t ON t.id = nt.tagId WHERE t.pathKey = ?)")
            arguments.append(key)
        }
        let inScope = scope.predicate(note: "n")
        conditions.append("(\(inScope.sql))")
        arguments += inScope.arguments
        let whereClause = conditions.joined(separator: " AND ")
        var notes: [Note] = []
        if limit != 0 {
            notes = try Note.fetchAll(
                db,
                sql: "SELECT n.* FROM note n WHERE \(whereClause) ORDER BY \(sort.orderBy()) LIMIT ? OFFSET ?",
                arguments: StatementArguments(arguments + [limit ?? -1, max(offset, 0)]))
        }
        guard countTotal || limit == 0 else { return (notes, notes.count) }
        let total = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM note n WHERE \(whereClause)", arguments: StatementArguments(arguments)) ?? 0
        return (notes, total)
    }

    static func list(
        location: LocationFilter, tag: String?, sort: SortSpec, limit: Int?, offset: Int, scope: NoteScope,
        countTotal: Bool = true, db: Database
    ) throws -> (ids: [String], total: Int) {
        let found = try listNotes(
            location: location, tag: tag, sort: sort, limit: limit, offset: offset, scope: scope,
            countTotal: countTotal, db: db)
        return (found.notes.map(\.id), found.total)
    }

    /// Notes matching the Bear search `query`, each with its match count. Which notes match is
    /// decided by `SearchCompiler.filter`, the predicate the app's own search uses (`@title`,
    /// `@ocr` and the date and todo filters included).
    static func searchNotes(
        _ query: String, location: LocationFilter, sort: SortSpec, limit: Int?, offset: Int, scope: NoteScope,
        now: Date, calendar: Calendar, locale: Locale = .current, countTotal: Bool = true, db: Database
    ) throws -> (hits: [(note: Note, matches: Int)], total: Int) {
        let expression = SearchParser.parse(query, locale: locale)
        let filter = SearchCompiler.filter(expression, now: now, calendar: calendar)
        var conditions = ["n.deletedAt IS NULL"]
        var arguments: [(any DatabaseValueConvertible)?] = []
        locationCondition(location, into: &conditions, arguments: &arguments)
        let inScope = scope.predicate(note: "n")
        conditions.append("(\(inScope.sql))")
        arguments += inScope.arguments
        conditions.append("(\(filter.predicate))")
        arguments += filter.arguments
        let whereClause = conditions.joined(separator: " AND ")
        var hits: [(note: Note, matches: Int)] = []
        if limit != 0 {
            let needles = SearchMatchCounter.needles(expression)
            let cursor = try Note.fetchCursor(
                db,
                sql: """
                    SELECT n.* FROM note n \(filter.joins) WHERE \(whereClause)
                    ORDER BY \(sort.orderBy()) LIMIT ? OFFSET ?
                    """,
                arguments: StatementArguments(arguments + [limit ?? -1, max(offset, 0)]))
            while let note = try cursor.next() {
                hits.append((note, SearchMatchCounter.count(needles, in: note.text)))
            }
        }
        guard countTotal || limit == 0 else { return (hits, hits.count) }
        let total = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM note n \(filter.joins) WHERE \(whereClause)",
            arguments: StatementArguments(arguments)) ?? 0
        return (hits, total)
    }

    static func search(
        _ query: String, location: LocationFilter, sort: SortSpec, limit: Int?, offset: Int, scope: NoteScope,
        now: Date, calendar: Calendar, locale: Locale = .current, countTotal: Bool = true, db: Database
    ) throws -> (hits: [(id: String, matches: Int)], total: Int) {
        let found = try searchNotes(
            query, location: location, sort: sort, limit: limit, offset: offset, scope: scope, now: now,
            calendar: calendar, locale: locale, countTotal: countTotal, db: db)
        return (found.hits.map { ($0.note.id, $0.matches) }, found.total)
    }

    private static func locationCondition(
        _ location: LocationFilter, into conditions: inout [String], arguments: inout [(any DatabaseValueConvertible)?]
    ) {
        guard let noteLocation = location.noteLocation else { return }
        conditions.append("n.location = ?")
        arguments.append(noteLocation.rawValue)
    }

    /// The `pathKey` of `--tag`: surrounding `#` and whitespace stripped. nil when nothing is left.
    private static func tagKey(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let noise = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "#"))
        let stripped = raw.trimmingCharacters(in: noise)
        guard !stripped.isEmpty else { return nil }
        return CanonicalKey.make((try? NoteStore.tagToken(stripped).name) ?? stripped)
    }
}
