// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

/// What wiki links point at in a note: its title and headings, and when it was last modified
/// (which decides between notes with the same title, spec §3.5). The app captures it before a
/// title change and hands it to `rewriteWikiLinks(to:from:)` once the new title is stable.
public struct LinkTargetState: Equatable, Sendable {
    public var title: String
    /// Heading texts in order, as the indexer stores them.
    public var headings: [String]
    /// The level (1–6) of each heading in `headings`.
    public var headingLevels: [Int]
    /// Levels of heading lines with no text (`## ` while a heading is retyped); not in `headings`.
    public var emptyHeadingLevels: [Int]
    public var modifiedAt: Date

    public init(
        title: String, headings: [String], headingLevels: [Int]? = nil, emptyHeadingLevels: [Int] = [],
        modifiedAt: Date
    ) {
        self.title = title
        self.headings = headings
        self.headingLevels = headingLevels ?? headings.map { _ in 1 }
        self.emptyHeadingLevels = emptyHeadingLevels
        self.modifiedAt = modifiedAt
    }

    /// The state of `text` as the indexer would derive it.
    public init(text: String, modifiedAt: Date) {
        let (meta, empty) = NoteParser.metadataAndEmptyHeadingLevels(for: text)
        self.init(
            title: meta.title, headings: meta.headings.map(\.text), headingLevels: meta.headings.map(\.level),
            emptyHeadingLevels: empty, modifiedAt: modifiedAt
        )
    }

    /// What a rewrite depends on: the title key and the heading keys.
    public var changeKey: [String] { [TitleKey.make(title)] + headings.map(WikiLinkResolver.headingKey) }
}

/// What a wiki-link rewrite changed, and what undoing it needs.
public struct LinkRewriteResult: Equatable, Sendable {
    /// Notes whose text was rewritten, in id order.
    public var changedNoteIds: [String] = []
    /// Locked notes with links to rewrite; their text is not readable, so they were left alone.
    public var skippedLocked: [String] = []
    /// Read-only notes with links to rewrite, left alone like locked ones (R10).
    public var skippedReadOnly: [String] = []
    /// Notes passed in `skipping` (open with unsaved text) that had links to rewrite.
    public var skippedUnsaved: [String] = []
    /// A note in `deferringIfTouching` had links to rewrite: nothing was written; try again later.
    public var deferred = false
    /// Text of each changed note before the rewrite.
    public var previousTexts: [String: String] = [:]
    /// Text the rewrite gave each changed note (undo only restores notes still at it).
    public var rewrittenTexts: [String: String] = [:]

    public var didChange: Bool { !changedNoteIds.isEmpty }

    public init() {}
}

/// Bear's "wiki link name update" (spec §3.5): when a note's title or one of its headings is
/// renamed, `[[Old…]]` links become `[[New…]]` in one write transaction through `writeText`.
/// Links in code, math, comments and front matter are not links and are never touched.
extension NoteStore {
    public func linkTargetState(id: String) throws -> LinkTargetState? {
        try db.pool.read { db in
            try Note.fetchOne(db, key: id).map { try Self.linkTargetState(of: $0, in: db) }
        }
    }

    /// Rewrites the links that pointed at the note as it was in `previous` to what it is now:
    /// - a renamed title (other than case only; neither old nor new empty): `[[Old…]]` →
    ///   `[[New…]]`, only if `Old` resolved to this note before the change
    ///   (`WikiLinkResolver`'s rule, judged with the note's `modifiedAt` from `previous`);
    /// - one renamed heading (same count, exactly one changed, the old one unique):
    ///   `[[Title/Old heading…]]` likewise, and `[[/Old heading…]]` in the note itself.
    /// The `/Heading` and `|alias` parts, spacing and `\/` escapes stay as written. Locked and
    /// read-only notes are skipped and reported, and so are notes in `skipping` (open with
    /// unsaved edits). If a note in `deferringIfTouching` (an editor busy typing) would be
    /// rewritten, nothing is written and the result is `deferred`.
    @discardableResult
    public func rewriteWikiLinks(
        to noteId: String, from previous: LinkTargetState, skipping: Set<String> = [],
        deferringIfTouching busy: Set<String> = [], now: Date = .now
    ) throws -> LinkRewriteResult {
        try write { db in
            let note = try Self.require(noteId, in: db)
            let current = try Self.linkTargetState(of: note, in: db)
            let oldKey = TitleKey.make(previous.title)
            let titled = !previous.title.isEmpty && !current.title.isEmpty
            let titleRenamed = titled && oldKey != TitleKey.make(current.title)
            let heading = Self.renamedHeading(from: previous.headings, to: current.headings)
            guard titleRenamed || heading != nil else { return LinkRewriteResult() }
            let resolved = try titled
                && WikiLinkResolver.resolved(titleKey: oldKey, to: note, modifiedAt: previous.modifiedAt, in: db)
            var rule = WikiLinkRewriteRule(
                targetKey: resolved ? oldKey : nil,
                newTitle: titleRenamed ? current.title : nil,
                heading: heading.map { (WikiLinkResolver.headingKey($0.old), $0.new) },
                sameNote: false
            )

            var result = LinkRewriteResult()
            var writes: [(note: Note, text: String)] = []
            let rows = try Row.fetchAll(db, sql: """
                SELECT sourceNoteId, targetKey, targetHeading FROM wiki_link
                WHERE (? IS NOT NULL AND targetKey = ?) OR (sourceNoteId = ? AND targetKey = '')
                ORDER BY sourceNoteId, ordinal
                """, arguments: [rule.targetKey, rule.targetKey, noteId])
            for (id, links) in Dictionary(grouping: rows, by: { $0[0] as String }).sorted(by: { $0.key < $1.key }) {
                rule.sameNote = id == noteId
                guard links.contains(where: { rule.matches(targetKey: $0[1], heading: $0[2]) }) else { continue }
                let source = try Self.require(id, in: db)
                if source.isLocked {
                    result.skippedLocked.append(id)
                } else if source.isReadOnly {
                    result.skippedReadOnly.append(id)
                } else if skipping.contains(id) {
                    result.skippedUnsaved.append(id)
                } else if let text = Self.rewritingWikiLinks(in: source.text, rule) {
                    writes.append((source, text))
                }
            }
            if writes.contains(where: { busy.contains($0.note.id) }) {
                var deferred = LinkRewriteResult()
                deferred.deferred = true
                return deferred
            }
            for (source, text) in writes {
                let written = try Self.writeText(id: source.id, text: text, expectedRevision: source.revision, now: now, in: db)
                result.changedNoteIds.append(source.id)
                result.previousTexts[source.id] = source.text
                result.rewrittenTexts[source.id] = written.text
            }
            return result
        }
    }

    /// Restores the texts of a rewrite, only in notes still at the rewritten text (notes edited
    /// since are left alone). Returns the restored note ids.
    @discardableResult
    public func undoLinkRewrite(_ result: LinkRewriteResult, now: Date = .now) throws -> [String] {
        try write { db in
            try Self.replaceTexts(result.changedNoteIds, expecting: result.rewrittenTexts, with: result.previousTexts, now: now, in: db)
        }
    }

    /// Re-applies an undone rewrite, only in notes still at their text from before it.
    @discardableResult
    public func redoLinkRewrite(_ result: LinkRewriteResult, now: Date = .now) throws -> [String] {
        try write { db in
            try Self.replaceTexts(result.changedNoteIds, expecting: result.previousTexts, with: result.rewrittenTexts, now: now, in: db)
        }
    }

    /// The one heading renamed between `old` and `new`: same count, exactly one position whose key
    /// changed, and both the old and the new heading unique in their lists (otherwise links to it
    /// are ambiguous). Else nil.
    public static func renamedHeading(from old: [String], to new: [String]) -> (old: String, new: String)? {
        guard old.count == new.count else { return nil }
        let key = WikiLinkResolver.headingKey
        let changed = old.indices.filter { key(old[$0]) != key(new[$0]) }
        guard changed.count == 1, let index = changed.first else { return nil }
        let oldKey = key(old[index])
        let newKey = key(new[index])
        guard old.count(where: { key($0) == oldKey }) == 1,
              new.count(where: { key($0) == newKey }) == 1 else { return nil }
        return (old[index], new[index])
    }

    // MARK: - Internals

    /// Which links a rewrite changes and into what.
    struct WikiLinkRewriteRule {
        /// Links whose target has this key are the note's (nil: none are).
        var targetKey: String?
        /// The target those links get (nil keeps the target as written).
        var newTitle: String?
        /// A renamed heading: links to `oldKey` (in `targetKey` links, and same-note links when
        /// `sameNote`) get `new`.
        var heading: (oldKey: String, new: String)?
        /// The text is the renamed note's own, so its `[[/heading]]` links point at it.
        var sameNote: Bool

        func headingMatches(_ heading: String?) -> Bool {
            guard let heading, let renamed = self.heading else { return false }
            return WikiLinkResolver.headingKey(heading) == renamed.oldKey
        }

        func matches(targetKey: String, heading: String?) -> Bool {
            if targetKey.isEmpty { return sameNote && headingMatches(heading) }
            return targetKey == self.targetKey && (newTitle != nil || headingMatches(heading))
        }
    }

    /// Applies `rule` to every wiki link the indexer counts; `nil` when no link changed. A link the
    /// new title or heading cannot be written into (`|`, `[`, `]`, …) is left as it is.
    static func rewritingWikiLinks(in text: String, _ rule: WikiLinkRewriteRule) -> String? {
        let text = TextNormalization.normalizeLineEndings(text)
        let occurrences = NoteParser.wikiLinkOccurrences(in: text)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { Array($0.unicodeScalars) }
        var changed = false
        for (lineIndex, group) in Dictionary(grouping: occurrences, by: \.line) {
            let offset = lineIndex == 0 && lines[0].first == "\u{FEFF}" ? 1 : 0
            for occurrence in group.sorted(by: { $0.link.end > $1.link.end }) {
                let link = occurrence.link
                guard let replacement = rewrittenLink(link, in: lines[lineIndex], offset: offset, rule) else { continue }
                lines[lineIndex].replaceSubrange(link.targetRange.lowerBound - 2 + offset..<link.end + offset, with: replacement)
                changed = true
            }
        }
        guard changed else { return nil }
        return lines.map { String(String.UnicodeScalarView($0)) }.joined(separator: "\n")
    }

    /// The link's new scalars, or nil when the rule leaves it (or the result would not parse
    /// back to the intended target, heading and alias).
    private static func rewrittenLink(
        _ link: WikiLinkParser.Link, in line: [Unicode.Scalar], offset: Int, _ rule: WikiLinkRewriteRule
    ) -> [Unicode.Scalar]? {
        let ref = link.ref
        guard rule.matches(targetKey: TitleKey.make(ref.target), heading: ref.heading) else { return nil }
        let newTarget = ref.target.isEmpty ? nil : rule.newTitle
        let newHeading = rule.headingMatches(ref.heading) ? rule.heading?.new : nil
        let shift = { (range: Range<Int>) in range.lowerBound + offset..<range.upperBound + offset }

        var out = Array(line[link.targetRange.lowerBound - 2 + offset..<link.targetRange.lowerBound + offset])
        let rawTarget = line[shift(link.targetRange)]
        out += newTarget.map { respaced(rawTarget, escapingSlashes($0)) } ?? Array(rawTarget)
        var rest = link.targetRange.upperBound
        if let headingRange = link.headingRange {
            out += line[shift(link.targetRange.upperBound..<headingRange.lowerBound)]
            let rawHeading = line[shift(headingRange)]
            let escapes = Chars.find(["\\", "/"], in: Array(rawHeading), from: 0) != nil
            out += newHeading.map { respaced(rawHeading, escapes ? escapingSlashes($0) : $0) } ?? Array(rawHeading)
            rest = headingRange.upperBound
        }
        out += line[shift(rest..<link.end)]

        let key = { (s: String?) in s.map(TitleKey.make) }
        guard let parsed = WikiLinkParser.parse(out, at: 0), parsed.end == out.count,
              key(parsed.ref.target) == key(newTarget ?? ref.target),
              parsed.ref.heading.map(WikiLinkResolver.headingKey) == (newHeading ?? ref.heading).map(WikiLinkResolver.headingKey),
              parsed.ref.alias == ref.alias else { return nil }
        return out
    }

    /// `\/` keeps a slash in a link target (`[[a\/b]]`).
    private static func escapingSlashes(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "\\/")
    }

    /// `core` with the whitespace `raw` had around its text (`[[ Old ]]` → `[[ New ]]`).
    private static func respaced(_ raw: ArraySlice<Unicode.Scalar>, _ core: String) -> [Unicode.Scalar] {
        let lead = raw.prefix(while: Chars.isSpace)
        let trail = lead.count == raw.count ? [] : Array(raw.reversed().prefix(while: Chars.isSpace).reversed())
        return Array(lead) + Array(core.unicodeScalars) + trail
    }

    /// Parsed from the note's text (the indexer derives `title` and `heading` the same way).
    static func linkTargetState(of note: Note, in db: Database) throws -> LinkTargetState {
        LinkTargetState(text: note.text, modifiedAt: note.modifiedAt)
    }

    /// Writes `replacement[id]` to each note still at `expected[id]`; returns the ids written.
    static func replaceTexts(
        _ ids: [String], expecting expected: [String: String], with replacement: [String: String],
        now: Date, in db: Database
    ) throws -> [String] {
        var written: [String] = []
        for id in ids {
            guard let note = try Note.fetchOne(db, key: id), let current = expected[id], let text = replacement[id],
                  TextNormalization.identical(note.text, current) else { continue }
            _ = try writeText(id: id, text: text, expectedRevision: note.revision, now: now, in: db)
            written.append(id)
        }
        return written
    }
}
