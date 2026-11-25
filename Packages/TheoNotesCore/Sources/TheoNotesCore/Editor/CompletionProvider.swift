// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import os

/// What the editor completes (bridge `requestCompletions.kind`): `#` tags, `[[` note titles,
/// `[[Title/` (and `[[/`) headings, `:` + two letters emoji.
public enum CompletionKind: String, Codable, CaseIterable, Sendable {
    case tag, note, heading, emoji
}

/// One completion: `label` is listed, `insert` replaces the typed query (`#wo` → `#work `,
/// `:cat` → `🐈`, the text after `[[` or `[[Title/`). `icon` is a TagCon (SF Symbol name).
public struct CompletionItem: Codable, Equatable, Sendable {
    public var label: String
    public var insert: String
    public var detail: String?
    public var icon: String?

    public init(label: String, insert: String, detail: String? = nil, icon: String? = nil) {
        self.label = label
        self.insert = insert
        self.detail = detail
        self.icon = icon
    }
}

/// `requestCompletions`: the editor's query in note `noteId`. `noteTitle` (headings only) is the
/// link target before the `/`; empty or nil means the note itself (`[[/`).
public struct CompletionRequest: Equatable, Sendable {
    public var noteId: String
    public var requestId: String
    public var kind: CompletionKind
    public var query: String
    public var noteTitle: String?

    public init(noteId: String, requestId: String, kind: CompletionKind, query: String, noteTitle: String?) {
        self.noteId = noteId
        self.requestId = requestId
        self.kind = kind
        self.query = query
        self.noteTitle = noteTitle
    }
}

/// The editor's completion data (M3 Task 7). Matching is case- and diacritic-insensitive
/// (`SearchText.fold`); each source ranks its matches in tiers (prefix before word prefix before
/// substring …), then by its own order.
public struct CompletionProvider: Sendable {
    /// Tags, notes and headings listed at most.
    public static let limit = 50
    public static let emojiLimit = 30

    private let db: AppDatabase
    private let titles = NoteTitleIndex()
    private let liveHeadings = LiveHeadings()

    public init(db: AppDatabase) {
        self.db = db
    }

    /// Drops cached note titles; call when the database changed (a change notification).
    public func invalidateCaches() {
        titles.invalidate()
    }

    /// How often the live note's headings were parsed (tests).
    var liveHeadingParses: Int { liveHeadings.parses }
    /// The note title cache (tests).
    var titleIndex: NoteTitleIndex { titles }

    public func items(
        kind: CompletionKind, query: String, noteTitle: String?, sourceNoteId: String, sourceText: String?,
        sourceRevision: Int? = nil
    ) throws -> [CompletionItem] {
        switch kind {
        case .tag: try tags(matching: query, sourceNoteId: sourceNoteId)
        case .note: try notes(matching: query, sourceNoteId: sourceNoteId)
        case .heading:
            try headings(
                noteTitle: noteTitle ?? "", matching: query, sourceNoteId: sourceNoteId, sourceText: sourceText,
                sourceRevision: sourceRevision
            )
        case .emoji: Self.emoji(matching: query)
        }
    }

    // MARK: Tags

    /// Tags of notes outside the Trash, other than the note being edited (its own tags include
    /// the one being typed, indexed by the debounced commit). Ranked: the path starts with the
    /// query, then a component or word does, then it contains it; within a tier by note count,
    /// then name. `detail` is the note count, `icon` the TagCon.
    public func tags(matching query: String, sourceNoteId: String) throws -> [CompletionItem] {
        let q = Match.fold(query)
        let rows = try db.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT t.displayPath, t.iconName, COUNT(DISTINCT n.id) AS notes
                FROM tag t JOIN note_tag nt ON nt.tagId = t.id JOIN note n ON n.id = nt.noteId
                WHERE n.location != 'trash' AND n.deletedAt IS NULL AND n.id != ?
                GROUP BY t.id
                """, arguments: [sourceNoteId])
        }
        struct Candidate {
            var tier: Int, notes: Int, key: String, path: String, icon: String?
        }
        var found: [Candidate] = []
        for row in rows {
            let path: String = row["displayPath"]
            let key = Match.fold(path)
            let tier: Int?
            if q.isEmpty || key.hasPrefix(q) {
                tier = 0
            } else if Match.words(key).contains(where: { $0.hasPrefix(q) }) {
                tier = 1
            } else {
                tier = key.contains(q) ? 2 : nil
            }
            guard let tier else { continue }
            found.append(Candidate(tier: tier, notes: row["notes"], key: key, path: path, icon: row["iconName"]))
        }
        found.sort { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            if a.notes != b.notes { return a.notes > b.notes }
            return a.key != b.key ? a.key < b.key : a.path < b.path
        }
        return found.prefix(Self.limit).map {
            CompletionItem(
                label: $0.path, insert: Self.tagInsert($0.path), detail: String($0.notes),
                icon: TagIcons.symbol(forTagPath: $0.path, iconName: $0.icon)
            )
        }
    }

    /// `#path ` when that parses back as the tag, else the closed form `#path# ` (spaces,
    /// numbers, punctuation that ends a single-word tag).
    static func tagInsert(_ path: String) -> String {
        TagScanner.tags(inLine: "#\(path) ") == [path] ? "#\(path) " : "#\(path)# "
    }

    /// Tag path key (`tag.pathKey`) → TagCon of every tag: the custom icon, else the keyword
    /// table's (`TagIcons`). The editor shows it next to tag pills (bridge `tagIcons`).
    public func tagIconMap() throws -> [String: String] {
        try db.pool.read { db in
            var map: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT pathKey, displayPath, iconName FROM tag") {
                map[row["pathKey"]] = TagIcons.symbol(forTagPath: row["displayPath"], iconName: row["iconName"])
            }
            return map
        }
    }

    // MARK: Notes

    /// Note titles a wiki link can name, one per title: the note the link resolves to (ruling
    /// R16 — Trash excluded, the most recently modified duplicate wins), never the note being
    /// edited. Titles a link cannot spell (`[`, `]`, `|`) are left out; `/` is escaped in `insert`.
    /// Ranked: equal, starts with, a word starts with, contains, fuzzy (the query's characters in
    /// order); within a tier Notes before Archive (`detail` "Archive"), then most recent first.
    /// The folded titles are cached (`NoteTitleIndex`); cancelling the calling task stops the scan
    /// (`CancellationError`).
    public func notes(matching query: String, sourceNoteId: String) throws -> [CompletionItem] {
        let entries = try db.pool.read { try titles.entries(in: $0) }
        let q = Array(Match.fold(query).utf8)
        // Buckets in rank order: tier × (Notes, Archive); entries arrive most recent first.
        var buckets = Array(repeating: [Int](), count: 10)
        try q.withUnsafeBufferPointer { q in
            for (index, entry) in entries.enumerated() {
                if index & 1023 == 0, Task.isCancelled { throw CancellationError() }
                guard entry.id != sourceNoteId else { continue }
                let tier = q.isEmpty ? 0 : NoteTitleIndex.tier(entry, q)
                if let tier { buckets[tier * 2 + (entry.archived ? 1 : 0)].append(index) }
            }
        }
        var items: [CompletionItem] = []
        for index in buckets.joined() {
            let entry = entries[index]
            // Only the titles listed are checked for being linkable.
            guard let link = NoteStore.mentionLink(forTitle: entry.title) else { continue }
            let insert = String(String.UnicodeScalarView(link.dropFirst(2).dropLast(2)))
            items.append(CompletionItem(label: entry.title, insert: insert, detail: entry.archived ? "Archive" : nil))
            if items.count == Self.limit { break }
        }
        return items
    }

    // MARK: Headings

    /// The headings of the note `[[noteTitle/` resolves to (R16), or of the note being edited
    /// for an empty title (`[[/`), from `sourceText` (the editor's live text) when given. Ranked
    /// starts with, a word starts with, contains, fuzzy; then document order. `insert` is the
    /// heading text, which `WikiLinkResolver.headingKey` matches back when the link is followed.
    /// With `sourceRevision`, the live text's headings are parsed once per revision.
    public func headings(
        noteTitle: String, matching query: String, sourceNoteId: String, sourceText: String?, sourceRevision: Int? = nil
    ) throws -> [CompletionItem] {
        let title = Chars.collapse(noteTitle)
        let noteId = title.isEmpty
            ? sourceNoteId
            : try db.pool.read { try WikiLinkResolver.resolve(titleKey: TitleKey.make(title), in: $0) }
        guard let noteId else { return [] }
        let headings: [(level: Int, text: String)]
        if noteId == sourceNoteId, let sourceText {
            headings = liveHeadings.headings(noteId: noteId, revision: sourceRevision, text: sourceText)
        } else {
            headings = try db.pool.read { db in
                try Row.fetchAll(db, sql: "SELECT level, text FROM heading WHERE noteId = ? ORDER BY ordinal", arguments: [noteId])
                    .map { ($0["level"], $0["text"]) }
            }
        }
        let q = Match.fold(query)
        var found: [(tier: Int, index: Int, item: CompletionItem)] = []
        for (index, heading) in headings.enumerated() {
            let text = Chars.collapse(heading.text)
            guard Self.isLinkableHeading(text), let tier = Match.tier(Match.fold(text), q, exactTier: false) else { continue }
            found.append((tier, index, CompletionItem(label: text, insert: text, detail: "H\(heading.level)")))
        }
        found.sort { $0.tier != $1.tier ? $0.tier < $1.tier : $0.index < $1.index }
        return found.prefix(Self.limit).map(\.item)
    }

    /// `[[x/heading]]` parses back to this heading (no `[`, `]` or `|`).
    static func isLinkableHeading(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let link = Array("[[x/\(text)]]".unicodeScalars)
        guard let parsed = WikiLinkParser.parse(link, at: 0), parsed.end == link.count, parsed.ref.alias == nil,
              let heading = parsed.ref.heading else { return false }
        return WikiLinkResolver.headingKey(heading) == WikiLinkResolver.headingKey(text)
    }

    // MARK: Emoji

    struct EmojiEntry: Decodable, Sendable {
        /// The emoji.
        var e: String
        /// CLDR name first, then keywords.
        var en: [String]
        var de: [String]
    }

    private struct PreparedEmoji: Sendable {
        var emoji: String
        var names: [(raw: String, folded: String)]
        var keywords: [String]
    }

    /// `Resources/emoji.json` (scripts/make-emoji-json.py, Unicode CLDR en + de).
    static let emojiEntries: [EmojiEntry] = {
        do {
            guard let url = Bundle.module.url(forResource: "emoji", withExtension: "json") else {
                throw CocoaError(.fileNoSuchFile)
            }
            return try JSONDecoder().decode([EmojiEntry].self, from: Data(contentsOf: url))
        } catch {
            Logger(subsystem: "com.truebrewbirdie.baerchen", category: "editor").error("emoji.json: \(error)")
            return []
        }
    }()

    private static let preparedEmoji: [PreparedEmoji] = emojiEntries.map { entry in
        let names = [entry.en.first, entry.de.first].compactMap { $0 }.map { ($0, Match.fold($0)) }
        let keywords = (entry.en.dropFirst() + entry.de.dropFirst()).map(Match.fold)
        return PreparedEmoji(emoji: entry.e, names: names, keywords: keywords)
    }

    /// Emoji whose English or German name or keywords match: the name equals the query, starts
    /// with it, a word of it does, a keyword starts with it, the name contains it; then data
    /// order. The label shows the name that matched (`🐈 Katze` for `:katze`).
    public static func emoji(matching query: String) -> [CompletionItem] {
        let q = Match.fold(query)
        guard !q.isEmpty else { return [] }
        var found: [(tier: Int, index: Int, item: CompletionItem)] = []
        for (index, entry) in preparedEmoji.enumerated() {
            var best: (tier: Int, name: String)?
            for name in entry.names {
                let tier: Int? = name.folded == q ? 0
                    : name.folded.hasPrefix(q) ? 1
                    : Match.words(name.folded).contains(where: { $0.hasPrefix(q) }) ? 2
                    : nil
                if let tier, tier < (best?.tier ?? .max) { best = (tier, name.raw) }
            }
            if best == nil, entry.keywords.contains(where: { $0.hasPrefix(q) || Match.words($0).contains { $0.hasPrefix(q) } }) {
                best = (3, entry.names[0].raw)
            }
            if best == nil, let name = entry.names.first(where: { $0.folded.contains(q) }) {
                best = (4, name.raw)
            }
            guard let best else { continue }
            found.append((best.tier, index, CompletionItem(label: "\(entry.emoji) \(best.name)", insert: entry.emoji)))
        }
        found.sort { $0.tier != $1.tier ? $0.tier < $1.tier : $0.index < $1.index }
        return found.prefix(emojiLimit).map(\.item)
    }

    // MARK: Matching

    enum Match {
        /// Whitespace collapsed, case and diacritics folded.
        static func fold(_ s: String) -> String {
            SearchText.fold(Chars.collapse(s))
        }

        static func words(_ folded: String) -> [Substring] {
            folded.split { !$0.isLetter && !$0.isNumber }
        }

        /// 0 equal (when `exactTier`), then starts with, a word starts with, contains, fuzzy; nil
        /// no match. An empty query matches everything in tier 0.
        static func tier(_ candidate: String, _ q: String, exactTier: Bool = true) -> Int? {
            if q.isEmpty { return 0 }
            let shift = exactTier ? 1 : 0
            if exactTier && candidate == q { return 0 }
            if candidate.hasPrefix(q) { return shift }
            if words(candidate).contains(where: { $0.hasPrefix(q) }) { return shift + 1 }
            if candidate.contains(q) { return shift + 2 }
            return isSubsequence(q, of: candidate) ? shift + 3 : nil
        }

        static func isSubsequence(_ q: String, of s: String) -> Bool {
            var it = q.makeIterator()
            var next = it.next()
            for c in s where c == next {
                next = it.next()
                if next == nil { return true }
            }
            return next == nil
        }
    }
}
