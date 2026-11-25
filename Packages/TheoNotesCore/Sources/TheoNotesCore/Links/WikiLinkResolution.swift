// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

/// Where a clicked wiki link goes.
public struct WikiLinkTarget: Equatable, Sendable {
    public var noteId: String
    /// The heading's ordinal in the target note (the editor's `scrollToHeading` index); nil without
    /// a heading or when no heading of the note matches.
    public var headingIndex: Int?
    /// No note had the title, so one was created (Bear).
    public var created: Bool
    /// For a created note: where its editor starts, the end of the title line (UTF-16).
    public var caretOffset: Int?

    public init(noteId: String, headingIndex: Int?, created: Bool, caretOffset: Int? = nil) {
        self.noteId = noteId
        self.headingIndex = headingIndex
        self.created = created
        self.caretOffset = caretOffset
    }
}

extension NoteStore {
    /// Ruling R16: the note `[[title]]` resolves to, by `WikiLinkResolver`'s rule (the only
    /// implementation; the title-change rewrite judges with the same rule).
    static func wikiLinkTargetId(title: String, in db: Database) throws -> String? {
        try WikiLinkResolver.resolve(titleKey: TitleKey.make(title), in: db)
    }

    /// The note `[[title]]` links to, if any.
    public func noteId(forWikiTitle title: String) throws -> String? {
        try db.pool.read { try Self.wikiLinkTargetId(title: title, in: $0) }
    }

    /// The ordinal of the note's first heading that `heading` names (`WikiLinkResolver.headingOrdinal`).
    public func headingIndex(noteId: String, heading: String) throws -> Int? {
        try db.pool.read { try WikiLinkResolver.headingOrdinal(heading, inNote: noteId, in: $0) }
    }

    /// Resolves `[[title/heading]]` written in `sourceNoteId` (an empty title is that note). A title no
    /// note has becomes a new note `# title` (Bear); a blank title with no source throws. Clicked in
    /// a window in `workspace`, the new note also gets the workspace's tag on the line under the
    /// title (ruling R31, `newNoteTagTokens`), so it stays in the workspace.
    public func resolveOrCreateWikiLink(
        title: String, heading: String?, from sourceNoteId: String, workspace: Workspace? = nil, now: Date = .now
    ) throws -> WikiLinkTarget {
        let name = Self.collapsed(title)
        var created = false
        var caret: Int?
        let target: String
        if name.isEmpty {
            guard !sourceNoteId.isEmpty else { throw StoreError.noteNotFound(id: sourceNoteId) }
            target = sourceNoteId
        } else if let found = try noteId(forWikiTitle: name) {
            target = found
        } else if case let rendered = NoteParser.metadata(for: "# " + name).title, !rendered.isEmpty,
                  let found = try noteId(forWikiTitle: rendered) {
            // The note this link would create is titled without markup (`[[**Plan**]]` → "Plan"):
            // a second click finds the one the first click made.
            target = found
        } else {
            let titleLine = "# " + name
            let tokens = try Self.newNoteTagTokens(
                carrying: NoteParser.metadata(for: titleLine).tags, extraTags: [], workspace: workspace)
            let text = tokens.isEmpty ? titleLine : titleLine + "\n" + tokens.joined(separator: " ")
            target = try create(text: text, now: now).id
            created = true
            caret = titleLine.utf16.count
        }
        let index = try heading.flatMap { try headingIndex(noteId: target, heading: $0) }
        return WikiLinkTarget(noteId: target, headingIndex: index, created: created, caretOffset: caret)
    }

    /// The note imported from the Bear note `bearId` (`external_ref`, source `bear`).
    public func noteId(forBearId bearId: String) throws -> String? {
        try db.pool.read {
            try String.fetchOne(
                $0, sql: "SELECT noteId FROM external_ref WHERE source = 'bear' AND externalId = ? AND noteId IS NOT NULL",
                arguments: [bearId]
            )
        }
    }

    /// Whitespace runs collapsed to one space, trimmed (the wiki-link parser's `collapse`).
    private static func collapsed(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
