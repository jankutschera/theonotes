// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// `[[target/heading|alias]]`; `[[/Heading]]` links into the same note (target `""`).
public struct WikiLinkRef: Equatable, Hashable, Sendable, Codable {
    public var target: String
    public var heading: String?
    public var alias: String?

    public init(target: String, heading: String? = nil, alias: String? = nil) {
        self.target = target
        self.heading = heading
        self.alias = alias
    }
}

public struct HeadingRef: Equatable, Hashable, Sendable, Codable {
    public var level: Int
    public var text: String
    /// 1-based line number in the note text (front matter lines included).
    public var line: Int

    public init(level: Int, text: String, line: Int) {
        self.level = level
        self.text = text
        self.line = line
    }
}

public struct AttachmentRef: Equatable, Hashable, Sendable, Codable {
    /// Percent-decoded relative path as written in the link destination.
    public var filename: String
    public var isImage: Bool
    /// Trailing `<!-- {"embed":"true"} -->` style metadata; values stringified.
    public var metadata: [String: String]

    public init(filename: String, isImage: Bool, metadata: [String: String] = [:]) {
        self.filename = filename
        self.isImage = isImage
        self.metadata = metadata
    }
}

/// Everything the library derives from a note's Markdown.
public struct NoteMetadata: Equatable, Sendable, Codable {
    /// The first body line (after front matter) as the title: block and inline markup
    /// stripped, tags and HTML comments kept verbatim, trimmed, ≤ 500 characters. `""` when that
    /// line is blank or markup-only (untitled), even if later lines have text.
    public var title: String
    /// Preview: text after the title line, markup and tags stripped, whitespace collapsed, ≤ 300 characters.
    public var subtitle: String
    /// Direct tags without `#`, display spelling of first occurrence, deduped by `CanonicalKey`.
    public var tags: [String]
    public var openTodos: Int
    public var doneTodos: Int
    public var wikiLinks: [WikiLinkRef]
    public var headings: [HeadingRef]
    public var attachments: [AttachmentRef]
    /// A fenced code block exists.
    public var hasCode: Bool
    /// A code span exists outside code blocks.
    public var hasInlineCode: Bool
    /// No title, no subtitle and no attachments.
    public var isEmpty: Bool

    public init(
        title: String = "", subtitle: String = "", tags: [String] = [],
        openTodos: Int = 0, doneTodos: Int = 0, wikiLinks: [WikiLinkRef] = [],
        headings: [HeadingRef] = [], attachments: [AttachmentRef] = [],
        hasCode: Bool = false, hasInlineCode: Bool = false, isEmpty: Bool = true
    ) {
        self.title = title
        self.subtitle = subtitle
        self.tags = tags
        self.openTodos = openTodos
        self.doneTodos = doneTodos
        self.wikiLinks = wikiLinks
        self.headings = headings
        self.attachments = attachments
        self.hasCode = hasCode
        self.hasInlineCode = hasInlineCode
        self.isEmpty = isEmpty
    }
}
