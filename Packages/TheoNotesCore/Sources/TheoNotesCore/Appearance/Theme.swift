// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

public enum ThemeAppearance: String, Codable, Sendable {
    case light, dark
}

public enum ThemeContrast: String, Codable, Sendable {
    case standard, high
}

public enum AppearanceMode: String, Codable, Sendable, CaseIterable {
    case system, light, dark
}

public struct ThemeSource: Codable, Equatable, Sendable {
    public var project: String
    public var url: String
    public var license: String
    public var copyright: String

    public init(project: String, url: String, license: String, copyright: String) {
        self.project = project
        self.url = url
        self.license = license
        self.copyright = copyright
    }
}

/// A palette value that was moved to pass the contrast gate (`Fixtures/themes/theme-schema.json`).
public struct ThemeDeviation: Codable, Equatable, Sendable {
    public var token: String
    public var palette: String
    public var value: String
    public var reason: String

    public init(token: String, palette: String, value: String, reason: String) {
        self.token = token
        self.palette = palette
        self.value = value
        self.reason = reason
    }
}

/// An sRGB colour with components in 0...1. Parsed from `#rrggbb` or `#rrggbbaa` only.
public struct ThemeColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init?(hex: String) {
        let bytes = Array(hex.utf8)
        guard bytes.first == UInt8(ascii: "#"), bytes.count == 7 || bytes.count == 9 else { return nil }
        var channels: [Double] = []
        var index = 1
        while index < bytes.count {
            guard let high = Self.nibble(bytes[index]), let low = Self.nibble(bytes[index + 1]) else { return nil }
            channels.append(Double(high * 16 + low) / 255)
            index += 2
        }
        self.init(red: channels[0], green: channels[1], blue: channels[2], alpha: channels.count == 4 ? channels[3] : 1)
    }

    private static func nibble(_ byte: UInt8) -> Int? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): Int(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): Int(byte - UInt8(ascii: "a")) + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): Int(byte - UInt8(ascii: "A")) + 10
        default: nil
        }
    }
}

public enum ShellToken: String, CaseIterable, Sendable {
    case accent, background, text
    case secondaryText = "secondary-text"
    case selection
    case selectionText = "selection-text"
    case separator
    case searchHighlight = "search-highlight"
    /// Text and icons drawn on an opaque `accent` fill (Quick Open's selected row).
    case onAccent = "on-accent"
}

/// The token names of schema v1. Pinned to `Fixtures/themes/theme-schema.json` by `ThemeTests`, so a theme
/// author edits the schema and the test names the Swift list to update.
public enum ThemeSchema {
    /// Kept as an array (not a Set literal) so `ThemeTests` can see a duplicate.
    public static let editorTokenList: [String] = [
        "color-text", "color-secondary", "color-accent", "color-bg", "color-code-bg", "color-code-keyword",
        "color-code-string", "color-code-number", "color-code-comment", "color-code-type", "color-code-function",
        "color-code-property", "color-code-tag", "color-code-meta", "color-rule", "color-quote", "color-quote-bar",
        "color-link", "color-tag", "color-tag-bg", "highlight", "highlight-green", "highlight-red", "highlight-blue",
        "highlight-yellow", "highlight-purple", "highlight-dot-green", "highlight-dot-red", "highlight-dot-blue",
        "highlight-dot-yellow", "highlight-dot-purple", "color-selection", "color-search-match",
        "color-search-match-current", "color-popup-bg", "color-popup-text", "color-popup-selected-bg",
        "color-popup-selected-text", "color-shadow", "color-callout-note-bg", "color-callout-note-border",
        "color-callout-note-icon", "color-callout-note-title", "color-callout-tip-bg", "color-callout-tip-border",
        "color-callout-tip-icon", "color-callout-tip-title", "color-callout-important-bg",
        "color-callout-important-border", "color-callout-important-icon", "color-callout-important-title",
        "color-callout-warning-bg", "color-callout-warning-border", "color-callout-warning-icon",
        "color-callout-warning-title", "color-callout-caution-bg", "color-callout-caution-border",
        "color-callout-caution-icon", "color-callout-caution-title", "color-table-header-bg", "color-table-border",
        "color-math-error", "color-math-error-bg", "color-error",
    ]

    public static let editorTokens: Set<String> = Set(editorTokenList)

    public static let shellTokens: Set<String> = Set(ShellToken.allCases.map(\.rawValue))

    public static let variablePrefix = "--bc-"

    /// Keeps only `--bc-<schema editor token>` keys whose value is `#rrggbb` or `#rrggbbaa`. Anything else is
    /// dropped, so a hostile or stale map can never put an unknown variable or a CSS fragment into the editor.
    public static func sanitize(variables: [String: String]) -> [String: String] {
        variables.filter { key, value in
            key.hasPrefix(variablePrefix) && editorTokens.contains(String(key.dropFirst(variablePrefix.count)))
                && ThemeColor(hex: value) != nil
        }
    }
}

public struct Theme: Codable, Equatable, Sendable, Identifiable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var order: Int
    public var appearance: ThemeAppearance
    public var contrast: ThemeContrast
    public var source: ThemeSource
    public var deviations: [ThemeDeviation]
    public var editor: [String: String] {
        didSet { editorVariables = Self.variables(of: editor) }
    }
    public var shell: [String: String]
    /// The editor tokens as the CSS variables the bridge sends: `"--bc-" + token`. Built once per
    /// theme (and again when `editor` changes), not on every settings send.
    public private(set) var editorVariables: [String: String]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, order, appearance, contrast, source, deviations, editor, shell
    }

    private static func variables(of editor: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: editor.map { (ThemeSchema.variablePrefix + $0.key, $0.value) })
    }

    public init(
        schemaVersion: Int = Theme.schemaVersion, id: String, name: String, order: Int, appearance: ThemeAppearance,
        contrast: ThemeContrast, source: ThemeSource, deviations: [ThemeDeviation] = [], editor: [String: String],
        shell: [String: String]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.order = order
        self.appearance = appearance
        self.contrast = contrast
        self.source = source
        self.deviations = deviations
        self.editor = editor
        self.shell = shell
        editorVariables = Self.variables(of: editor)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        order = try container.decode(Int.self, forKey: .order)
        appearance = try container.decode(ThemeAppearance.self, forKey: .appearance)
        contrast = try container.decode(ThemeContrast.self, forKey: .contrast)
        source = try container.decode(ThemeSource.self, forKey: .source)
        deviations = try container.decodeIfPresent([ThemeDeviation].self, forKey: .deviations) ?? []
        editor = try container.decode([String: String].self, forKey: .editor)
        shell = try container.decode([String: String].self, forKey: .shell)
        editorVariables = Self.variables(of: editor)
    }

    /// A shell colour. A theme that did not come through `ThemeCatalog` and lacks the token reads as opaque black.
    public func color(_ token: ShellToken) -> ThemeColor {
        shell[token.rawValue].flatMap(ThemeColor.init(hex:)) ?? ThemeColor(red: 0, green: 0, blue: 0)
    }
}
