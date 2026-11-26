// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// The export page's request and result (M8 Task 10). The TypeScript definition is
/// `web/editor/src/export/protocol.ts`; both are checked against
/// `Fixtures/bridge/render-request.json`.

/// How the page renders: a standalone HTML document (HTML export, PDF, print) or an inline-styled
/// body fragment (RTF, Copy as Rich Text),.
public enum RenderMode: String, Codable, Equatable, Sendable {
    case document
    case richText
}

/// The `href` the host gives one wiki link occurrence.
public struct RenderWikiLink: Codable, Equatable, Sendable {
    public var href: String

    public init(href: String) {
        self.href = href
    }

    /// Exactly `href`, like the page's `parseRenderRequest`.
    public init(from decoder: any Decoder) throws {
        try RenderDecoding.requireOnly(["href"], in: decoder)
        href = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .href)
    }

    private enum CodingKeys: String, CodingKey { case href }
}

/// Strict decoding, field for field what `parseRenderRequest` accepts (protocol.ts).
enum RenderDecoding {
    struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Throws when the object at `decoder` has a key outside `allowed`.
    static func requireOnly(_ allowed: Set<String>, in decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
        try check(keys, allowed: allowed, codingPath: decoder.codingPath)
    }

    static func check(_ keys: [String], allowed: Set<String>, codingPath: [any CodingKey]) throws {
        if let unknown = keys.first(where: { !allowed.contains($0) }) {
            throw DecodingError.dataCorrupted(
                .init(codingPath: codingPath, debugDescription: "Unknown field \(unknown)"))
        }
    }
}

public struct RenderRequest: Codable, Equatable, Sendable {
    public static let version = 1

    /// The protocol version; the page refuses any other.
    public var v: Int
    public var noteId: String
    public var title: String
    public var text: String
    public var mode: RenderMode
    /// `--bc-<schema editor token>` → `#rrggbb[aa]`, over the default theme.
    public var theme: [String: String]
    public var appearance: EditorAppearance
    public var typography: EditorTypography
    /// Where each attachment loads from, by filename as written in the note.
    public var attachmentSources: [String: String]
    /// Byte sizes by filename (non-negative integers), for the file cards; absent is allowed.
    public var attachmentSizes: [String: Int]?
    /// One entry per wiki link occurrence in text order; `nil` renders as plain text.
    public var wikiLinks: [RenderWikiLink?]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case v, noteId, title, text, mode, theme, appearance, typography, attachmentSources, attachmentSizes, wikiLinks
    }

    private static let typographyKeys: Set<String> = [
        "fontSize", "lineHeight", "lineWidth", "paragraphSpacing", "paragraphIndent", "fontText", "fontHeading", "fontCode",
    ]

    /// As strict as the page: version 1 only, no unknown field (also in `typography` and each wiki
    /// link), theme variables only from the schema with hex values, fonts the editor accepts, sizes
    /// non-negative integers. `attachmentSizes` may be absent.
    public init(from decoder: any Decoder) throws {
        try RenderDecoding.requireOnly(Set(CodingKeys.allCases.map(\.rawValue)), in: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func corrupt(_ key: CodingKeys, _ message: String) -> DecodingError {
            .dataCorrupted(.init(codingPath: c.codingPath + [key], debugDescription: message))
        }
        v = try c.decode(Int.self, forKey: .v)
        guard v == Self.version else { throw corrupt(.v, "Unsupported render protocol version \(v)") }
        noteId = try c.decode(String.self, forKey: .noteId)
        title = try c.decode(String.self, forKey: .title)
        text = try c.decode(String.self, forKey: .text)
        mode = try c.decode(RenderMode.self, forKey: .mode)
        theme = try c.decode([String: String].self, forKey: .theme)
        guard ThemeSchema.sanitize(variables: theme) == theme else { throw corrupt(.theme, "Not a theme token map") }
        appearance = try c.decode(EditorAppearance.self, forKey: .appearance)
        let typographyKeys = try c.nestedContainer(keyedBy: RenderDecoding.AnyKey.self, forKey: .typography).allKeys
        try RenderDecoding.check(
            typographyKeys.map(\.stringValue), allowed: Self.typographyKeys, codingPath: c.codingPath + [CodingKeys.typography])
        typography = try c.decode(EditorTypography.self, forKey: .typography)
        guard typography.invalidFonts.isEmpty else { throw corrupt(.typography, "A font the editor would reject") }
        attachmentSources = try c.decode([String: String].self, forKey: .attachmentSources)
        attachmentSizes = try c.decodeIfPresent([String: Int].self, forKey: .attachmentSizes)
        guard attachmentSizes?.values.allSatisfy({ $0 >= 0 }) ?? true else { throw corrupt(.attachmentSizes, "Negative size") }
        wikiLinks = try c.decode([RenderWikiLink?].self, forKey: .wikiLinks)
    }

    public init(
        noteId: String, title: String, text: String, mode: RenderMode, theme: [String: String] = [:],
        appearance: EditorAppearance = .light, typography: EditorTypography = EditorTypography(),
        attachmentSources: [String: String] = [:], attachmentSizes: [String: Int] = [:],
        wikiLinks: [RenderWikiLink?] = []
    ) {
        v = Self.version
        self.noteId = noteId
        self.title = title
        self.text = text
        self.mode = mode
        self.theme = theme
        self.appearance = appearance
        self.typography = typography
        self.attachmentSources = attachmentSources
        self.attachmentSizes = attachmentSizes
        self.wikiLinks = wikiLinks
    }
}

public struct RenderedHeading: Codable, Equatable, Sendable {
    public var level: Int
    public var text: String
    /// `h-<n>`, 1-based over the note's non-empty headings (the `id` in the rendered body).
    public var anchor: String

    public init(level: Int, text: String, anchor: String) {
        self.level = level
        self.text = text
        self.anchor = anchor
    }
}

public struct RenderResult: Codable, Equatable, Sendable {
    public var html: String
    public var headings: [RenderedHeading]

    public init(html: String, headings: [RenderedHeading]) {
        self.html = html
        self.headings = headings
    }
}
