// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

public struct SearchFilter {
    /// `LEFT JOIN`s that bring `note_stats s` and `note_search_content c` in beside `note n`.
    public var joins: String
    /// A SQL boolean over `n`, `s` and `c`, never NULL; its `?` placeholders take `arguments` in order.
    public var predicate: String
    public var arguments: [(any DatabaseValueConvertible)?]

    static let standardJoins = """
        LEFT JOIN note_stats s ON s.noteId = n.id
        LEFT JOIN note_search_content c ON c.noteId = n.id
        """

    public init(joins: String, predicate: String, arguments: [(any DatabaseValueConvertible)?]) {
        self.joins = joins
        self.predicate = predicate
        self.arguments = arguments
    }
}

/// `SearchExpr` → one parameterized SQL statement over `note n` (+ `note_stats s`,
/// `note_search_content c`). User text never enters the SQL string: every term is bound, and FTS5
/// MATCH arguments are built only from a fixed column filter plus the folded term as one quoted
/// FTS string (`"` doubled), so FTS syntax in a term (`*`, `-`, `:`, `NEAR`, `AND`, `(`) is literal.
///
/// Text matching (see `SearchExpr`): a substring uses `note_fts_trigram` from 3 characters on and
/// `instr` on the folded content below that (the trigram index cannot serve shorter strings);
/// a single-word phrase uses the word index `note_fts`.
///
/// Scope = the sidebar scope ∩ `workspace` (its predicate is part of the scope filter).
public enum SearchCompiler {
    public static func compile(
        _ expr: SearchExpr, scope: SidebarScope, sort: NoteSort, workspace: Workspace? = nil, now: Date,
        calendar: Calendar, limit: Int? = nil, offset: Int = 0
    ) -> (sql: String, arguments: StatementArguments) {
        let match = filter(expr, now: now, calendar: calendar)
        let scopeClause = LibraryQueries.scopeClause(scope, workspace: workspace, now: now, calendar: calendar)
        var arguments = scopeClause.pinnedArguments + scopeClause.filterArguments + match.arguments
        var sql = """
            SELECT n.id, n.title, n.subtitle, n.modifiedAt, n.createdAt, n.isLocked, n.isReadOnly,
                   COALESCE(s.hasImages OR s.hasFiles, 0) AS hasAttachments, s.firstImage,
                   (\(scopeClause.pinnedExpr)) AS isPinned, n.captureSource, n.noteType
            FROM note n
            \(match.joins)
            WHERE (\(scopeClause.filter)) AND \(match.predicate)
            ORDER BY isPinned DESC, \(LibraryQueries.orderBy(sort)), n.id
            """
        if let limit {
            sql += "\nLIMIT ? OFFSET ?"
            arguments.append(limit)
            arguments.append(max(offset, 0))
        }
        return (sql, StatementArguments(arguments))
    }

    /// The match predicate of `expr` over `note n`, `note_stats s` and `note_search_content c`
    /// (with the joins that bring `s` and `c` in). `compile` and the automation layer's `search`
    /// both build on it, so what matches is decided in one place, `@title` and `@ocr` included.
    public static func filter(_ expr: SearchExpr, now: Date, calendar: Calendar) -> SearchFilter {
        let columns: TextColumns = containsModifier(expr, .title) ? .title : containsModifier(expr, .ocr) ? .ocr : .all
        var context = Context(columns: columns, now: now, calendar: calendar)
        let predicate = context.predicate(removingModifiers(expr) ?? .and([]))
        return SearchFilter(joins: SearchFilter.standardJoins, predicate: predicate, arguments: context.arguments)
    }

    /// Strings to highlight in results: the positive terms and phrases as typed, and positive
    /// tags as `#name`.
    public static func highlightTerms(_ expr: SearchExpr) -> [String] {
        var terms: [String] = []
        func walk(_ e: SearchExpr) {
            switch e {
            case .term(let s), .phrase(let s): if !terms.contains(s) { terms.append(s) }
            case .tag(let name, _): if !terms.contains("#" + name) { terms.append("#" + name) }
            case .special, .not: break
            case .and(let list), .or(let list): list.forEach(walk)
            }
        }
        walk(expr)
        return terms
    }

    // MARK: - Modifiers (`@title`, `@ocr`)

    /// The modifiers are query-wide switches, wherever they appear (`system or @title`
    /// = titles containing `system`); a negated one is ignored.
    private static func containsModifier(_ e: SearchExpr, _ modifier: SpecialSearch) -> Bool {
        switch e {
        case .special(let s): s == modifier
        case .and(let list), .or(let list): list.contains { containsModifier($0, modifier) }
        default: false
        }
    }

    /// The expression without modifiers; `nil` when nothing is left of it. Groups that only held
    /// modifiers disappear (`@todo or @title` = `@todo`).
    private static func removingModifiers(_ e: SearchExpr) -> SearchExpr? {
        switch e {
        case .special(.title), .special(.ocr):
            return nil
        case .not(let inner):
            return removingModifiers(inner).map { .not($0) }
        case .and(let list):
            guard !list.isEmpty else { return e }
            let kept = list.compactMap(removingModifiers)
            return kept.isEmpty ? nil : .and(kept)
        case .or(let list):
            let kept = list.compactMap(removingModifiers)
            return kept.isEmpty ? nil : .or(kept)
        default:
            return e
        }
    }

    // MARK: - Predicates

    enum TextColumns {
        case all, title, ocr

        /// FTS5 column filter prefix for a MATCH argument.
        var matchPrefix: String {
            switch self {
            case .all: ""
            case .title: "title : "
            case .ocr: "ocrText : "
            }
        }

        var contentColumns: [String] {
            switch self {
            case .all: ["c.title", "c.body", "c.attachmentNames", "c.ocrText"]
            case .title: ["c.title"]
            case .ocr: ["c.ocrText"]
            }
        }
    }

    struct Context {
        let columns: TextColumns
        let now: Date
        let calendar: Calendar
        var arguments: [(any DatabaseValueConvertible)?] = []

        init(columns: TextColumns, now: Date, calendar: Calendar) {
            self.columns = columns; self.now = now; self.calendar = calendar
        }

        /// A SQL boolean that is never NULL (so `NOT` is exact).
        mutating func predicate(_ e: SearchExpr) -> String {
            switch e {
            case .and(let list):
                guard !list.isEmpty else { return "1" }
                return "(" + list.map { predicate($0) }.joined(separator: " AND ") + ")"
            case .or(let list):
                guard !list.isEmpty else { return "0" }
                return "(" + list.map { predicate($0) }.joined(separator: " OR ") + ")"
            case .not(let inner):
                return "NOT " + predicate(inner)
            case .term(let s):
                return substring(SearchText.fold(s))
            case .phrase(let s):
                return phrase(SearchText.fold(s))
            case .tag(let name, let mode):
                return tag(CanonicalKey.make(name), mode: mode)
            case .special(let special):
                return self.special(special)
            }
        }

        private mutating func bind(_ value: (any DatabaseValueConvertible)?) -> String {
            arguments.append(value)
            return "?"
        }

        /// One FTS5 string: the term in double quotes, embedded quotes doubled.
        private func ftsString(_ s: String) -> String {
            columns.matchPrefix + "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }

        private mutating func substring(_ needle: String) -> String {
            if needle.isEmpty { return "1" }
            if needle.unicodeScalars.count >= 3 {
                return "COALESCE(c.rowid IN (SELECT rowid FROM note_fts_trigram WHERE note_fts_trigram MATCH \(bind(ftsString(needle)))), 0)"
            }
            let tests = columns.contentColumns.map { "instr(\($0), \(bind(needle))) > 0" }
            return "COALESCE(" + tests.joined(separator: " OR ") + ", 0)"
        }

        /// With whitespace inside (or no letters/digits, or CJK): the substring. A single word:
        /// whole tokens of the word index; one with inner punctuation (`adhd-founder`) also needs
        /// the exact substring, since the word index ignores the punctuation.
        private mutating func phrase(_ folded: String) -> String {
            let scalars = folded.unicodeScalars
            let hasWordChar = scalars.contains { $0.properties.isAlphabetic || $0.properties.numericType != nil }
            if scalars.contains(where: { Chars.isSpace($0) || $0.properties.isWhitespace }) || !hasWordChar
                || scalars.contains(where: Self.isCJK) {
                return substring(folded)
            }
            let word = "COALESCE(c.rowid IN (SELECT rowid FROM note_fts WHERE note_fts MATCH \(bind(ftsString(folded)))), 0)"
            let onlyWordChars = scalars.allSatisfy {
                $0.properties.isAlphabetic || $0.properties.numericType != nil || $0.properties.generalCategory == .nonspacingMark
            }
            return onlyWordChars ? word : "(\(word) AND \(substring(folded)))"
        }

        static func isCJK(_ c: Unicode.Scalar) -> Bool {
            switch c.value {
            case 0x1100...0x11FF, 0x2E80...0x9FFF, 0xA960...0xA97F, 0xAC00...0xD7FF, 0xF900...0xFAFF,
                 0xFF66...0xFF9F, 0x20000...0x3FFFF:
                true
            default:
                false
            }
        }

        private mutating func tag(_ key: String, mode: TagMode) -> String {
            switch mode {
            case .withDescendants:
                return "n.id IN (SELECT nt.noteId FROM note_tag nt JOIN tag t ON t.id = nt.tagId WHERE t.pathKey = \(bind(key)))"
            case .exact:
                let prefix = key + "/"
                return """
                    n.id IN (SELECT nt.noteId FROM note_tag nt JOIN tag t ON t.id = nt.tagId
                        WHERE t.pathKey = \(bind(key)) AND nt.isDirect AND NOT EXISTS (
                            SELECT 1 FROM note_tag nt2 JOIN tag t2 ON t2.id = nt2.tagId
                            WHERE nt2.noteId = nt.noteId AND substr(t2.pathKey, 1, \(bind(prefix.unicodeScalars.count))) = \(bind(prefix))))
                    """
            case .subtagsOnly:
                let suffix = "/" + key
                let length = suffix.unicodeScalars.count
                return """
                    n.id IN (SELECT nt.noteId FROM note_tag nt JOIN tag t ON t.id = nt.tagId
                        WHERE length(t.pathKey) > \(bind(length)) AND substr(t.pathKey, -\(bind(length))) = \(bind(suffix)))
                    """
            }
        }

        private mutating func special(_ special: SpecialSearch) -> String {
            switch special {
            case .tagged: return "n.id IN (SELECT noteId FROM note_tag)"
            case .untagged: return LibraryQueries.untaggedExpr
            case .today: return range("n.modifiedAt", day(0), day(1))
            case .yesterday: return range("n.modifiedAt", day(-1), day(0))
            case .lastDays(let x): return "n.modifiedAt >= \(bind(day(-x)))"
            case .modified(let filter): return date("n.modifiedAt", filter)
            case .createdToday: return range("n.createdAt", day(0), day(1))
            case .createdDays(let x): return "n.createdAt >= \(bind(day(-x)))"
            case .created(let filter): return date("n.createdAt", filter)
            case .images: return "COALESCE(s.hasImages, 0)"
            case .files: return "COALESCE(s.hasFiles, 0)"
            case .attachments: return "COALESCE(s.hasImages OR s.hasFiles, 0)"
            case .task: return "COALESCE(s.openTodos + s.doneTodos > 0, 0)"
            case .todo: return "COALESCE(s.openTodos > 0, 0)"
            case .done: return "COALESCE(s.doneTodos > 0 AND s.openTodos = 0, 0)"
            case .code: return "COALESCE(s.hasCode, 0)"
            case .title, .ocr: return "1"
            case .locked: return "n.isLocked"
            case .pinned: return "n.isPinnedGlobal"
            case .readOnly: return "n.isReadOnly"
            // A locked note's text is not stored in the clear, so its derived title/stats are blank.
            case .empty: return "(COALESCE(s.isEmpty, 0) AND NOT n.isLocked)"
            case .untitled: return "(n.title = '' AND NOT n.isLocked)"
            case .wikiLinks: return "n.id IN (SELECT sourceNoteId FROM wiki_link)"
            case .backlinks:
                return """
                    (n.titleKey != '' AND EXISTS (SELECT 1 FROM wiki_link w JOIN note src ON src.id = w.sourceNoteId
                        WHERE w.targetKey = n.titleKey AND src.id != n.id AND src.location != 'trash'))
                    """
            }
        }

        /// Start of the local day `offset` days from today.
        private func day(_ offset: Int) -> Date {
            let start = calendar.startOfDay(for: now)
            return calendar.date(byAdding: .day, value: offset, to: start) ?? (offset < 0 ? .distantPast : .distantFuture)
        }

        private mutating func range(_ column: String, _ lower: Date, _ upper: Date) -> String {
            "(\(column) >= \(bind(lower)) AND \(column) < \(bind(upper)))"
        }

        /// A query date is a Gregorian year/month/day (whatever `calendar`'s system, e.g. Buddhist)
        /// in `calendar`'s time zone. Bounds past year 9999 do not exist as stored `YYYY-…` text,
        /// so they are left out (`.after` such a bound matches nothing).
        private mutating func date(_ column: String, _ filter: DateFilter) -> String {
            var gregorian = Calendar(identifier: .gregorian)
            gregorian.timeZone = calendar.timeZone
            let start = gregorian.date(from: DateComponents(year: filter.year, month: filter.month ?? 1, day: filter.day ?? 1))
                ?? .distantPast
            let unit: Calendar.Component = filter.day != nil ? .day : filter.month != nil ? .month : .year
            let end = gregorian.date(byAdding: unit, value: 1, to: start)
                .flatMap { gregorian.component(.year, from: $0) <= 9999 ? $0 : nil }
            switch filter.comparison {
            case .on: return end.map { range(column, start, $0) } ?? "\(column) >= \(bind(start))"
            case .before: return "\(column) < \(bind(start))"
            case .after: return end.map { "\(column) >= \(bind($0))" } ?? "0"
            }
        }
    }
}
