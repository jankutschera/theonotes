// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

/// One place a note mentions another: a wiki link to it (linked) or its exact title as plain
/// text (unlinked). `line` is 0-based in the note text split on `\n`; `range` is in unicode
/// scalars of that line (a leading BOM not counted), as in `NoteParser.tagOccurrences`.
public struct Mention: Equatable, Hashable, Sendable, Identifiable {
    public var noteId: String
    public var line: Int
    public var range: Range<Int>
    /// The line's visible text, cut to about `Backlinks.snippetLength` characters around the mention.
    public var snippet: String

    public var id: String { "\(noteId):\(line):\(range.lowerBound)" }

    public init(noteId: String, line: Int, range: Range<Int>, snippet: String) {
        self.noteId = noteId
        self.line = line
        self.range = range
        self.snippet = snippet
    }
}

/// A note in the Backlinks tab with its mentions.
public struct MentioningNote: Equatable, Sendable, Identifiable {
    public var noteId: String
    public var title: String
    public var location: NoteLocation
    public var isLocked: Bool
    public var isReadOnly: Bool
    /// Empty for a locked note (its text is not readable).
    public var mentions: [Mention]

    public var id: String { noteId }

    public init(
        noteId: String, title: String, location: NoteLocation, isLocked: Bool, isReadOnly: Bool, mentions: [Mention]
    ) {
        self.noteId = noteId
        self.title = title
        self.location = location
        self.isLocked = isLocked
        self.isReadOnly = isReadOnly
        self.mentions = mentions
    }

    /// "Link" may rewrite it: in Notes (Archive and Trash are not editable, spec §4.9), not locked
    /// and not read-only (R10).
    public var canLink: Bool { location == .notes && !isLocked && !isReadOnly }
}

/// The Info panel's Backlinks tab (spec §4.6, inventory §2.8).
public struct Backlinks: Equatable, Sendable {
    public static let snippetLength = 120
    /// At most this many linking notes are listed.
    public static let linkedNoteLimit = 200
    /// Candidate notes are read until this many unlinked mentions are verified…
    public static let unlinkedMentionLimit = 50
    /// …or this many candidates were checked (a title most notes carry only as a tag).
    public static let candidateScanLimit = 1_000

    /// Notes with wiki links that resolve to the note (Notes and Archive), most recently modified first.
    public var linked: [MentioningNote] = []
    /// More linking notes exist than `linked` lists.
    public var linkedTruncated = false
    /// Other unlocked notes with the exact title as plain text, not linking to it already, most
    /// recently modified first.
    public var unlinked: [MentioningNote] = []
    /// The search stopped at a limit: older notes may mention the title too.
    public var unlinkedTruncated = false
    /// The title can be written as a wiki link that resolves to the note (`linkMention` would
    /// refuse otherwise).
    public var canLink = false

    public init() {}
}

public enum MentionLinkError: Error, Equatable {
    /// The title cannot be written as `[[Title]]` that resolves back to it (`|`, `[`, `]`,
    /// repeated spaces, a trailing `\`).
    case titleNotLinkable
    /// The note changed since the mention was listed: it is no longer at that place.
    case stale
    /// Locked, read-only, archived or trashed.
    case notEditable
    /// `[[Title]]` resolves to another note with the same title (R16).
    case resolvesElsewhere
    /// The mention is in the note itself.
    case sameNote
}

extension NoteStore {
    /// Linked and unlinked mentions of the note's title. Matching is case-insensitive and
    /// diacritic-sensitive, like link resolution (`CanonicalKey`); a mention must start and end
    /// at word boundaries (not needed next to CJK characters) and lie in plain prose — never in
    /// code, math, comments, front matter, links, wiki links, tags or URLs.
    ///
    /// Unlinked candidates come from the substring index for the title (bound, never
    /// concatenated; substrings rather than words because the word index joins a Latin word with
    /// CJK text next to it, `Appleの`), newest first, read page by page and verified until
    /// `unlinkedLimit` mentions are found or `Backlinks.candidateScanLimit` candidates were
    /// checked; `unlinkedTruncated` says when it stopped early.
    public func backlinks(
        to noteId: String, linkedLimit: Int = Backlinks.linkedNoteLimit,
        unlinkedLimit: Int = Backlinks.unlinkedMentionLimit
    ) throws -> Backlinks {
        try db.pool.read { try Self.backlinks(to: noteId, linkedLimit: linkedLimit, unlinkedLimit: unlinkedLimit, in: $0) }
    }

    /// `backlinks(to:)` on a reader of the pool, off the caller's thread (the app's main actor);
    /// cancelling the task interrupts it.
    public func backlinksInBackground(to noteId: String) async throws -> Backlinks {
        try await db.pool.read { try Self.backlinks(to: noteId, linkedLimit: Backlinks.linkedNoteLimit,
                                                    unlinkedLimit: Backlinks.unlinkedMentionLimit, in: $0) }
    }

    static func backlinks(to noteId: String, linkedLimit: Int, unlinkedLimit: Int, in db: Database) throws -> Backlinks {
        guard let note = try Note.fetchOne(db, key: noteId), !note.title.isEmpty else { return Backlinks() }
        let key = TitleKey.make(note.title)
        var backlinks = Backlinks()
        let resolvesHere = try resolvedLinkTargetId(key: key, in: db) == noteId
        backlinks.canLink = resolvesHere && mentionLink(forTitle: note.title) != nil

        if resolvesHere {
            let linking = try Note.fetchAll(db, sql: """
                SELECT * FROM note WHERE id IN (SELECT sourceNoteId FROM wiki_link WHERE targetKey = ?)
                    AND id != ? AND location != 'trash' AND deletedAt IS NULL
                ORDER BY modifiedAt DESC, id LIMIT ?
                """, arguments: [key, noteId, linkedLimit + 1])
            backlinks.linkedTruncated = linking.count > linkedLimit
            backlinks.linked = linking.prefix(linkedLimit).map { source in
                var entry = mentioningNote(source)
                guard !source.isLocked else { return entry }
                let scan = NoteParser.proseScan(TextNormalization.normalizeLineEndings(source.text), onlyLines: { line in
                    Chars.find(["[", "["], in: Array(line), from: 0) != nil
                })
                let lines = Dictionary(scan.lines.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
                entry.mentions = scan.wikiLinks.compactMap { occurrence in
                    let link = occurrence.link
                    guard TitleKey.make(link.ref.target) == key, let line = lines[occurrence.line] else { return nil }
                    return Mention(
                        noteId: source.id, line: occurrence.line, range: link.targetRange.lowerBound - 2..<link.end,
                        snippet: snippet(line.visibleText, around: link.display)
                    )
                }
                return entry
            }
        }

        var context = SearchCompiler.Context(columns: .all, now: Date(), calendar: .current)
        let substring = context.predicate(.term(note.title))
        let base = """
            SELECT n.* FROM note n JOIN note_search_content c ON c.noteId = n.id
            WHERE \(substring) AND n.id != ? AND n.location != 'trash' AND n.deletedAt IS NULL AND NOT n.isLocked
                AND n.id NOT IN (SELECT sourceNoteId FROM wiki_link WHERE targetKey = ?)
            """
        let order = "ORDER BY n.modifiedAt DESC, n.id LIMIT ?"
        let pageSize = 250
        var found = 0
        var scanned = 0
        var cursor: (modifiedAt: DatabaseValue, id: String)?
        pages: while true {
            var arguments = context.arguments + [noteId, key]
            var sql = base
            if let cursor {
                sql += " AND (n.modifiedAt < ? OR (n.modifiedAt = ? AND n.id > ?))"
                arguments += [cursor.modifiedAt, cursor.modifiedAt, cursor.id]
            }
            arguments.append(pageSize)
            let rows = try Row.fetchAll(db, sql: sql + "\n" + order, arguments: StatementArguments(arguments))
            for row in rows {
                let source = try Note(row: row)
                cursor = (row["modifiedAt"], source.id)
                scanned += 1
                let mentions = unlinkedMentions(of: note.title, in: TextNormalization.normalizeLineEndings(source.text))
                if !mentions.isEmpty {
                    var entry = mentioningNote(source)
                    let take = mentions.prefix(unlinkedLimit - found)
                    entry.mentions = take.map { line, range in
                        Mention(
                            noteId: source.id, line: line.index, range: range,
                            snippet: snippet(line.visibleText, around: string(line.scalars[range]))
                        )
                    }
                    backlinks.unlinked.append(entry)
                    found += take.count
                    if found >= unlinkedLimit {
                        backlinks.unlinkedTruncated = take.count < mentions.count || row != rows.last || rows.count == pageSize
                        break pages
                    }
                }
                if scanned >= Backlinks.candidateScanLimit {
                    backlinks.unlinkedTruncated = row != rows.last || rows.count == pageSize
                    break pages
                }
            }
            if rows.count < pageSize { break }
        }
        return backlinks
    }

    /// Rewrites one unlinked mention into `[[Title]]` (the target's title) in one write
    /// transaction through `writeText`. The mention must still be at the same place in the
    /// note's current text. Undo with `undoLinkRewrite(_:)`.
    @discardableResult
    public func linkMention(_ mention: Mention, to targetId: String, now: Date = .now) throws -> LinkRewriteResult {
        try write { db in
            let target = try Self.require(targetId, in: db)
            guard !target.title.isEmpty, let link = Self.mentionLink(forTitle: target.title) else {
                throw MentionLinkError.titleNotLinkable
            }
            guard try Self.resolvedLinkTargetId(key: TitleKey.make(target.title), in: db) == target.id else {
                throw MentionLinkError.resolvesElsewhere
            }
            let source = try Self.require(mention.noteId, in: db)
            guard source.id != target.id else { throw MentionLinkError.sameNote }
            guard Self.mentioningNote(source).canLink else { throw MentionLinkError.notEditable }
            let text = TextNormalization.normalizeLineEndings(source.text)
            let current = Self.unlinkedMentions(of: target.title, in: text)
            guard current.contains(where: { $0.line.index == mention.line && $0.range == mention.range }) else {
                throw MentionLinkError.stale
            }
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { Array($0.unicodeScalars) }
            let offset = mention.line == 0 && lines[0].first == "\u{FEFF}" ? 1 : 0
            lines[mention.line].replaceSubrange(
                mention.range.lowerBound + offset..<mention.range.upperBound + offset, with: link
            )
            let newText = lines.map { String(String.UnicodeScalarView($0)) }.joined(separator: "\n")
            let written = try Self.writeText(id: source.id, text: newText, expectedRevision: source.revision, now: now, in: db)
            var result = LinkRewriteResult()
            result.changedNoteIds = [source.id]
            result.previousTexts[source.id] = source.text
            result.rewrittenTexts[source.id] = written.text
            return result
        }
    }

    /// Calls `onChange` (on a database queue) after every transaction of this process that wrote
    /// to the `note` table, so a view of one note (the Info panel) can follow edits of any note.
    /// Other processes' writes come through `ChangeNotifier`.
    public func observeNoteWrites(
        onError: @escaping @Sendable (Error) -> Void, _ onChange: @escaping @Sendable () -> Void
    ) -> ObservationToken {
        let cancellable = DatabaseRegionObservation(tracking: Table("note"))
            .start(in: db.pool, onError: onError, onChange: { _ in onChange() })
        return ObservationToken { cancellable.cancel() }
    }

    // MARK: - Internals

    /// The note `[[Title]]` with this title key opens (R16): `WikiLinkResolver`'s rule.
    static func resolvedLinkTargetId(key: String, in db: Database) throws -> String? {
        try WikiLinkResolver.resolve(titleKey: key, in: db)
    }

    private static func mentioningNote(_ note: Note) -> MentioningNote {
        MentioningNote(
            noteId: note.id, title: note.title, location: note.location,
            isLocked: note.isLocked, isReadOnly: note.isReadOnly, mentions: []
        )
    }

    /// `[[Title]]` (a `/` written `\/`), or nil when that would not parse back to exactly the
    /// title (no heading, no alias, same key as the note's `titleKey`).
    static func mentionLink(forTitle title: String) -> [Unicode.Scalar]? {
        let link = Array(("[[" + title.replacingOccurrences(of: "/", with: "\\/") + "]]").unicodeScalars)
        guard let parsed = WikiLinkParser.parse(link, at: 0), parsed.end == link.count,
              parsed.ref.heading == nil, parsed.ref.alias == nil,
              TitleKey.make(parsed.ref.target) == TitleKey.make(title) else { return nil }
        return link
    }

    /// Why Copy Link to Here has no link for a heading.
    public enum HeadingLinkFailure: Error, Equatable, Sendable {
        /// The note has no title; `[[/Heading]]` would point into whichever note it is pasted in.
        case untitled
        /// An earlier heading of the note has the same `headingKey`; R16 resolves to the first match,
        /// so a link to this one would open the earlier heading.
        case repeated
        /// The title or heading cannot be written in a link: `[`, `]` or `|` (no escape exists), a
        /// backslash that would escape the separator, or an empty heading.
        case unspellable
    }

    /// `[[Title/Heading]]` for Copy Link to Here (a `/` in the title is written `\/`; whitespace runs
    /// collapse). `earlierHeadings` are the texts of the note's headings before this one. The link
    /// is built only if it parses back to this title key and heading key (R16: the title by
    /// `titleKey`, the heading by `WikiLinkResolver.headingKey`, first match wins).
    public static func headingLink(
        forTitle title: String, heading: String, earlierHeadings: [String] = []
    ) -> Result<String, HeadingLinkFailure> {
        // A link collapses whitespace runs and `TitleKey` collapses them in the note's title too, so
        // a title with runs ("Big    Title") is written as "Big Title" and resolves to the note.
        let title = Chars.collapse(title)
        let heading = Chars.collapse(heading)
        guard !title.isEmpty else { return .failure(.untitled) }
        guard !heading.isEmpty else { return .failure(.unspellable) }
        let text = "[[" + title.replacingOccurrences(of: "/", with: "\\/") + "/" + heading + "]]"
        let link = Array(text.unicodeScalars)
        guard let parsed = WikiLinkParser.parse(link, at: 0), parsed.end == link.count, parsed.ref.alias == nil,
              TitleKey.make(parsed.ref.target) == TitleKey.make(title),
              let parsedHeading = parsed.ref.heading,
              WikiLinkResolver.headingKey(parsedHeading) == WikiLinkResolver.headingKey(heading) else {
            return .failure(.unspellable)
        }
        let key = WikiLinkResolver.headingKey(heading)
        if earlierHeadings.contains(where: { WikiLinkResolver.headingKey($0) == key }) { return .failure(.repeated) }
        return .success(text)
    }

    /// Every plain-text occurrence of `title` in prose lines.
    static func unlinkedMentions(of title: String, in text: String) -> [(line: NoteParser.ProseLine, range: Range<Int>)] {
        let key = TitleKey.make(title)
        let titleScalars = Array(title.unicodeScalars)
        guard let first = titleScalars.first, let last = titleScalars.last else { return [] }
        var found: [(NoteParser.ProseLine, Range<Int>)] = []
        // Only lines that contain the title at all are scanned inline.
        let lines = NoteParser.proseScan(text, onlyLines: { line in
            string(line).range(of: title, options: .caseInsensitive) != nil
        }).lines
        for line in lines {
            let string = string(line.scalars[...])
            var searchStart = string.startIndex
            while let match = string.range(of: title, options: .caseInsensitive, range: searchStart..<string.endIndex) {
                // A rejected match may overlap the next real one: go on one character after its start.
                searchStart = string.index(after: match.lowerBound)
                let lower = string.unicodeScalars.distance(from: string.startIndex, to: match.lowerBound)
                let upper = lower + string.unicodeScalars.distance(from: match.lowerBound, to: match.upperBound)
                let range = lower..<upper
                guard TitleKey.make(String(string[match])) == key,
                      !line.blocked[range].contains(true),
                      isBoundary(before: lower, in: line.scalars, edge: first),
                      isBoundary(after: upper, in: line.scalars, edge: last) else { continue }
                found.append((line, range))
                searchStart = match.upperBound
            }
        }
        return found
    }

    private static func isWordScalar(_ c: Unicode.Scalar) -> Bool {
        c.properties.isAlphabetic || c.properties.numericType != nil || c.properties.generalCategory == .nonspacingMark
    }

    /// A mention may not continue a word (`apple` in `pineapple`), except next to CJK characters,
    /// which are written without spaces.
    private static func isBoundary(before position: Int, in s: [Unicode.Scalar], edge: Unicode.Scalar) -> Bool {
        guard position > 0, isWordScalar(edge), !NoteStatistics.isSpacelessScript(edge) else { return true }
        let neighbour = s[position - 1]
        return !isWordScalar(neighbour) || NoteStatistics.isSpacelessScript(neighbour)
    }

    private static func isBoundary(after position: Int, in s: [Unicode.Scalar], edge: Unicode.Scalar) -> Bool {
        guard position < s.count, isWordScalar(edge), !NoteStatistics.isSpacelessScript(edge) else { return true }
        let neighbour = s[position]
        return !isWordScalar(neighbour) || NoteStatistics.isSpacelessScript(neighbour)
    }

    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        String(String.UnicodeScalarView(scalars))
    }

    /// `visible`, or a window of `Backlinks.snippetLength` characters around the first
    /// case-insensitive occurrence of `needle`, with `…` where it was cut.
    static func snippet(_ visible: String, around needle: String) -> String {
        let limit = Backlinks.snippetLength
        guard visible.count > limit else { return visible }
        let characters = Array(visible)
        var start = 0
        if !needle.isEmpty, let match = visible.range(of: needle, options: .caseInsensitive) {
            let matchStart = visible.distance(from: visible.startIndex, to: match.lowerBound)
            start = max(0, min(matchStart - limit / 3, characters.count - limit))
            // Start at a word.
            while start > 0 && start < matchStart && !characters[start - 1].isWhitespace { start += 1 }
        }
        let end = min(characters.count, start + limit)
        var out = String(characters[start..<end]).trimmingCharacters(in: .whitespaces)
        if start > 0 { out = "…" + out }
        if end < characters.count { out += "…" }
        return out
    }
}
