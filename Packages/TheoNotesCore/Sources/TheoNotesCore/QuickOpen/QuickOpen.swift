// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

/// What choosing a Quick Open result does.
public enum QuickOpenTarget: Hashable, Sendable {
    /// Show the note (⌘↩: in a new window).
    case note(id: String)
    /// Select a sidebar section or tag.
    case scope(SidebarScope)
    /// Run a special search (`@images`, …) in Notes.
    case search(String)
    /// Create a note from the template.
    case template(id: String)
}

public struct QuickOpenResult: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case note, tag, section, search, template
    }

    public var target: QuickOpenTarget
    public var kind: Kind
    /// The note or template title (empty for an untitled note), tag path, or section name.
    public var title: String
    /// "Archive" for archived notes, the query of a special search; nil otherwise.
    public var detail: String?
    /// A tag's own icon (`tag.iconName`), if any.
    public var iconName: String?
    /// Higher is better; comparable within one query only.
    public var score: Int

    public var id: QuickOpenTarget { target }

    public init(
        target: QuickOpenTarget, kind: Kind, title: String, detail: String? = nil, iconName: String? = nil, score: Int
    ) {
        self.target = target; self.kind = kind; self.title = title; self.detail = detail
        self.iconName = iconName; self.score = score
    }
}

/// What a Quick Open query asks for (inventory §2.7, spec §4.5/§4.10): plain text matches note
/// titles; `#` tags; `@` sidebar sections and special searches; `+` or `/template` (`/` followed
/// by any prefix of `template`, e.g. `/t`) templates. The rest after the prefix is the filter.
/// Any other `/…` is a title query.
public enum QuickOpenQuery: Equatable, Sendable {
    case notes(String)
    case tags(String)
    case locations(String)
    case templates(String)

    public static func parse(_ raw: String) -> QuickOpenQuery {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = query.first else { return .notes("") }
        let rest = query.dropFirst()
        let filter = rest.trimmingCharacters(in: .whitespaces)
        switch first {
        case "#": return .tags(filter)
        case "@": return .locations(filter)
        case "+": return .templates(filter)
        case "/":
            let command = rest.prefix { !$0.isWhitespace }
            guard "template".hasPrefix(command.lowercased()) else { return .notes(query) }
            return .templates(rest.dropFirst(command.count).trimmingCharacters(in: .whitespaces))
        default:
            return .notes(query)
        }
    }
}

/// Quick Open (⌘O): an in-memory snapshot of what the panel can jump to, loaded once when it
/// opens (`load`), then filtered on every keystroke (`results`) without touching the database.
///
/// Notes are matched by title (`SearchText.fold`, the folding the note search uses, so case,
/// diacritics and `ß`/`ss` don't matter) as a fuzzy subsequence: every query character (spaces
/// ignored) must occur in order. The best alignment wins (`QuickOpenFuzzy.swift`): +16 per
/// character, +10 at the start of the title, +8 at a word start (after a non-alphanumeric
/// character), the first query character's bonus doubled, a consecutive run keeps the bonus of
/// its first character (at least +4), gaps cost 3 + 1 per further character. Then recency: up to
/// +12, halved every 30 days since the last edit. Trash is excluded; Archive is included but
/// ranked lower (−20, so an equally good title in Notes always comes first). Templates (exactly
/// what `Templates.list` lists, spec §4.10) are not note results. Ties: most recent first.
///
/// In the prefix modes (`#`, `@`, `+`, `/template`) notes whose titles match the whole query
/// (e.g. "#1 priorities", "@home") follow the mode's results, so no title becomes unreachable.
public struct QuickOpen: Sendable {
    public static let defaultLimit = 50

    static let recencyWeight = 12.0
    static let recencyHalfLifeDays = 30.0
    static let archivePenalty = 20

    // Notes, column-wise (no per-note structs to retain while ranking 10k of them).
    var noteIds: [String] = []
    var noteTitles: [String] = []
    /// `modifiedAt` as a Julian day.
    var noteModified: [Double] = []
    var noteArchived: [Bool] = []
    /// Recency and the Archive penalty.
    var noteBaseScores: [Int] = []
    var noteCorpus = Corpus()
    /// Note indexes, most recent first, of the notes in Notes and in Archive. Each list is in
    /// empty-query order already (the base score falls with age), so merging them gives it.
    var inNotesByRecency: [Int] = []
    var archivedByRecency: [Int] = []
    /// The sidebar tag tree in pre-order.
    var tags = Entries()
    /// Sections in sidebar order, then the special searches; matched by name and alias.
    var locations = Entries()
    /// Most recently modified first.
    var templates = Entries()

    /// Reads everything Quick Open shows (once per panel; safe off the main thread). In a
    /// `workspace` (M4 Task 8) notes, tags and the section counts are the workspace's (its
    /// `predicate`, as in `LibraryQueries`); templates are not limited.
    public static func load(
        db: Database, now: Date, calendar: Calendar = .current, workspace: Workspace? = nil
    ) throws -> QuickOpen {
        var quickOpen = QuickOpen()
        // The template condition is `Templates.predicate` (archived or locked `#template` notes are
        // plain notes).
        let template = Templates.predicate(note: "n")
        var arguments = template.arguments
        var inWorkspace = ""
        if let predicate = workspace?.predicate(note: "n") {
            arguments += predicate.arguments
            inWorkspace = " AND " + predicate.sql
        }
        // Most recent first: the order of the empty query. Dates as Julian days.
        let cursor = try Row.fetchCursor(db, sql: """
            SELECT n.id, n.title, julianday(n.modifiedAt), n.location = 'archive', c.title
            FROM note n LEFT JOIN note_search_content c ON c.noteId = n.id
            WHERE n.location != 'trash' AND n.deletedAt IS NULL AND NOT \(template.sql)
            """ + inWorkspace + " ORDER BY n.modifiedAt DESC, n.id DESC", arguments: StatementArguments(arguments))
        let today = now.timeIntervalSince1970 / 86_400 + 2_440_587.5
        while let row = try cursor.next() {
            let title: String = row[1]
            let modified: Double = row[2]
            let isArchived: Bool = row[3]
            let ageDays = max(0, today - modified)
            let recency = Int((recencyWeight * pow(0.5, ageDays / recencyHalfLifeDays)).rounded())
            let index = quickOpen.noteIds.count
            quickOpen.noteIds.append(row[0])
            quickOpen.noteTitles.append(title)
            quickOpen.noteModified.append(modified)
            quickOpen.noteArchived.append(isArchived)
            quickOpen.noteBaseScores.append(recency - (isArchived ? archivePenalty : 0))
            if isArchived { quickOpen.archivedByRecency.append(index) } else { quickOpen.inNotesByRecency.append(index) }
            // The search content holds the folded title; locked notes have none.
            let folded: String? = row[4]
            quickOpen.noteCorpus.append(folded ?? SearchText.fold(title))
        }

        // The sidebar's tag tree (in a workspace: the workspace's tree).
        func addTags(_ nodes: [TagNode]) {
            for node in nodes {
                quickOpen.tags.append(
                    QuickOpenResult(
                        target: .scope(.tag(node.path)), kind: .tag, title: node.path, iconName: node.iconName,
                        score: 0),
                    folded: [SearchText.fold(node.path)])
                addTags(node.children)
            }
        }
        addTags(try LibraryQueries.tagTree(workspace: workspace, db: db))

        // Sections as the sidebar shows them (the counts, within the workspace, decide Pinned,
        // Locked and Archive).
        let counts = try LibraryQueries.counts(workspace: workspace, now: now, calendar: calendar, db: db)
        for section in sections where section.isShown(counts) {
            quickOpen.locations.append(
                QuickOpenResult(target: .scope(section.scope), kind: .section, title: section.title, score: 0),
                folded: names(of: section.token))
        }
        for special in specialSearches {
            quickOpen.locations.append(
                QuickOpenResult(
                    target: .search("@" + special.token), kind: .search, title: special.title,
                    detail: "Search “@\(special.token)”", score: 0),
                folded: names(of: special.token))
        }

        for template in try Templates.list(db: db) {
            quickOpen.templates.append(
                QuickOpenResult(target: .template(id: template.id), kind: .template, title: template.title, score: 0),
                folded: [SearchText.fold(template.title)])
        }
        return quickOpen
    }

    /// The best `limit` results for `query` (see `QuickOpenQuery`), best first. `locale` reads
    /// dates in `@date(…)`.
    public func results(query: String, limit: Int = QuickOpen.defaultLimit, locale: Locale = .current) -> [QuickOpenResult] {
        guard limit > 0 else { return [] }
        let mode: [QuickOpenResult]
        switch QuickOpenQuery.parse(query) {
        case .notes(let filter): return noteResults(filter, limit: limit)
        case .tags(let filter): mode = ranked(tags, filter, limit: limit)
        case .locations(let filter): mode = Array((searchRow(filter, locale: locale) + ranked(locations, filter, limit: limit)).prefix(limit))
        case .templates(let filter): mode = ranked(templates, filter, limit: limit)
        }
        guard mode.count < limit else { return mode }
        let titles = noteResults(query.trimmingCharacters(in: .whitespacesAndNewlines), limit: limit - mode.count)
        return mode + titles
    }

    // MARK: - Ranking

    /// One hit: `index` into its candidates; `modified` (notes) and `index` break score ties.
    struct Hit {
        var index: Int
        var score: Int
        var modified: Double
    }

    private func noteResults(_ filter: String, limit: Int) -> [QuickOpenResult] {
        let pattern = Self.pattern(filter)
        let order = { (a: Hit, b: Hit) -> Bool in
            if a.score != b.score { return a.score > b.score }
            if a.modified != b.modified { return a.modified > b.modified }
            return noteIds[a.index] > noteIds[b.index]
        }
        var best: [Hit] = []
        if pattern.isEmpty {
            // Merge the two recency lists (load order: modified, then id, descending).
            var i = 0, j = 0
            while best.count < limit, i < inNotesByRecency.count || j < archivedByRecency.count {
                let a = i < inNotesByRecency.count ? hit(inNotesByRecency[i]) : nil
                let b = j < archivedByRecency.count ? hit(archivedByRecency[j]) : nil
                if let a, b == nil || order(a, b!) {
                    best.append(a); i += 1
                } else if let b {
                    best.append(b); j += 1
                }
            }
        } else {
            var hits: [Hit] = []
            noteBaseScores.withUnsafeBufferPointer { base in
                noteModified.withUnsafeBufferPointer { modified in
                    noteCorpus.forEachMatch(pattern) { index, score in
                        hits.append(Hit(index: index, score: score + base[index], modified: modified[index]))
                    }
                }
            }
            best = Self.top(hits, limit: limit, by: order)
        }
        return best.map { hit in
            QuickOpenResult(
                target: .note(id: noteIds[hit.index]), kind: .note, title: noteTitles[hit.index],
                detail: noteArchived[hit.index] ? "Archive" : nil, score: hit.score)
        }
    }

    private func hit(_ index: Int) -> Hit {
        Hit(index: index, score: noteBaseScores[index], modified: noteModified[index])
    }

    /// Entries matching `filter` by any of their names, best first, then in their given order.
    private func ranked(_ entries: Entries, _ filter: String, limit: Int) -> [QuickOpenResult] {
        var best = [Int?](repeating: nil, count: entries.results.count)
        entries.corpus.forEachMatch(Self.pattern(filter)) { index, score in
            let owner = entries.owners[index]
            if score > best[owner] ?? Int.min { best[owner] = score }
        }
        let hits = best.enumerated().compactMap { index, score in score.map { Hit(index: index, score: $0, modified: 0) } }
        return Self.top(hits, limit: limit) { a, b in
            a.score != b.score ? a.score > b.score : a.index < b.index
        }.map {
            var result = entries.results[$0.index]
            result.score = $0.score
            return result
        }
    }

    /// `@last7days`, `@date(…)`, `@title`, …: a search the list has no row for runs as typed.
    private func searchRow(_ filter: String, locale: Locale) -> [QuickOpenResult] {
        let token = "@" + filter
        guard !filter.isEmpty, case .special(let special)? = SearchParser.special(fromToken: token, locale: locale),
              !Self.listedSpecials.contains(special.canonical) else { return [] }
        return [QuickOpenResult(target: .search(token), kind: .search, title: "Search for “\(token)”", score: 0)]
    }

    /// The first `limit` of `hits` in `order` (a full sort only when most of them are kept).
    private static func top(_ hits: [Hit], limit: Int, by order: (Hit, Hit) -> Bool) -> [Hit] {
        guard hits.count > limit * 4 else { return Array(hits.sorted(by: order).prefix(limit)) }
        // Keep the `limit` best seen so far, sorted; most hits fall below the worst kept.
        var kept: [Hit] = []
        kept.reserveCapacity(limit + 1)
        for hit in hits {
            if kept.count == limit, !order(hit, kept[limit - 1]) { continue }
            var position = kept.count
            while position > 0, order(hit, kept[position - 1]) { position -= 1 }
            kept.insert(hit, at: position)
            if kept.count > limit { kept.removeLast() }
        }
        return kept
    }

    // MARK: - Candidates

    /// Results with their folded names (tags, sections, templates); a result may have several
    /// names (`owners` maps each corpus text to its result).
    struct Entries: Sendable {
        var results: [QuickOpenResult] = []
        var corpus = Corpus()
        var owners: [Int] = []

        mutating func append(_ result: QuickOpenResult, folded names: [String]) {
            let index = results.count
            results.append(result)
            for name in names {
                corpus.append(name)
                owners.append(index)
            }
        }
    }

    // MARK: - Sections and special searches

    private struct Section: Sendable {
        var token: String
        var title: String
        var scope: SidebarScope

        /// Pinned, Locked and Archive are in the sidebar only when non-empty.
        func isShown(_ counts: SidebarCounts) -> Bool {
            switch scope {
            case .pinned: counts.pinned > 0
            case .locked: counts.locked > 0
            case .archive: counts.archive > 0
            default: true
            }
        }
    }

    /// The sidebar sections in sidebar order (spec §4.2).
    private static let sections: [Section] = [
        Section(token: "notes", title: "Notes", scope: .notes),
        Section(token: "pinned", title: "Pinned", scope: .pinned),
        Section(token: "untagged", title: "Untagged", scope: .untagged),
        Section(token: "todo", title: "Todo", scope: .todo),
        Section(token: "today", title: "Today", scope: .today),
        Section(token: "locked", title: "Locked", scope: .locked),
        Section(token: "archive", title: "Archive", scope: .archive),
        Section(token: "trash", title: "Trash", scope: .trash),
    ]

    /// The `@` searches without arguments that have no sidebar section of the same name.
    private static let specialSearches: [(token: String, title: String)] = [
        ("tagged", "Tagged"), ("yesterday", "Yesterday"), ("ctoday", "Created Today"), ("task", "Tasks"),
        ("done", "Done"), ("images", "Images"), ("files", "Files"), ("attachments", "Attachments"),
        ("code", "Code"), ("readonly", "Read-only"), ("empty", "Empty"), ("untitled", "Untitled"),
        ("wikilinks", "Wiki Links"), ("backlinks", "Backlinks"),
    ]

    /// The specials a listed row stands for (sections with a search of the same name included).
    private static let listedSpecials: Set<String> = Set(
        ["@today", "@todo", "@untagged", "@locked", "@pinned"] + specialSearches.map { "@" + $0.token })

    /// A row's names: its token and the localized aliases `SearchParser` accepts for it (folded).
    private static func names(of token: String) -> [String] {
        let canonical = SearchParser.special(fromToken: "@" + token).flatMap { expr -> String? in
            if case .special(let special) = expr { return special.canonical } else { return nil }
        }
        var names = [token]
        if let canonical {
            names += SearchParser.simpleSpecials
                .filter { $0.value.canonical == canonical && $0.key != token }
                .map(\.key).sorted()
        }
        return names.map(SearchText.fold)
    }
}
