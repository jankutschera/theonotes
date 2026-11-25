// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import OSLog

let appearanceLogger = Logger(subsystem: "com.truebrewbirdie.baerchen", category: "appearance")

/// Every bundled `theme-*.json`. Adding a theme is adding a file; no shared code changes.
public enum ThemeCatalog {
    public static let defaultLightId = LegacyNames.lightThemeID
    public static let defaultDarkId = LegacyNames.darkThemeID

    private static let loaded: [Theme] = load()

    /// Sorted by `order` (then id), cached.
    public static func all() -> [Theme] { loaded }

    public static func theme(id: String) -> Theme? { loaded.first { $0.id == id } }

    public static func themes(_ appearance: ThemeAppearance) -> [Theme] { loaded.filter { $0.appearance == appearance } }

    private struct Header: Decodable {
        let schemaVersion: Int
    }

    /// Parses one theme file. Returns nil for a file that is unreadable, newer than schema v1, or incomplete
    /// without a fallback. Tokens outside the schema and values that are not `#rrggbb[aa]` are dropped (they must
    /// never reach the editor); a missing or dropped token is filled from `fallback` and logged.
    static func parse(_ data: Data, fallback: Theme?, file: String = "theme") -> Theme? {
        do {
            let header = try JSONDecoder().decode(Header.self, from: data)
            guard (1...Theme.schemaVersion).contains(header.schemaVersion) else {
                appearanceLogger.error("\(file, privacy: .public): schemaVersion \(header.schemaVersion) is outside 1...\(Theme.schemaVersion), skipped")
                return nil
            }
            var theme = try JSONDecoder().decode(Theme.self, from: data)
            guard let editor = complete(theme.editor, known: ThemeSchema.editorTokens, fallback: fallback?.editor, file: file),
                  let shell = complete(theme.shell, known: ThemeSchema.shellTokens, fallback: fallback?.shell, file: file)
            else { return nil }
            theme.editor = editor
            theme.shell = shell
            return theme
        } catch {
            appearanceLogger.error("\(file, privacy: .public): \(error, privacy: .public)")
            return nil
        }
    }

    private static func complete(
        _ values: [String: String], known: Set<String>, fallback: [String: String]?, file: String
    ) -> [String: String]? {
        var result: [String: String] = [:]
        for (token, value) in values {
            guard known.contains(token) else {
                appearanceLogger.error("\(file, privacy: .public): unknown token \(token, privacy: .public) dropped")
                continue
            }
            guard ThemeColor(hex: value) != nil else {
                appearanceLogger.error("\(file, privacy: .public): \(token, privacy: .public) is not #rrggbb[aa], dropped")
                continue
            }
            result[token] = value
        }
        for token in known.sorted() where result[token] == nil {
            guard let value = fallback?[token] else {
                appearanceLogger.error("\(file, privacy: .public): token \(token, privacy: .public) missing and no fallback, theme skipped")
                return nil
            }
            appearanceLogger.error("\(file, privacy: .public): token \(token, privacy: .public) missing, filled from \(ThemeCatalog.defaultLightId, privacy: .public)")
            result[token] = value
        }
        return result
    }

    private static func load() -> [Theme] {
        let urls = (Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("theme-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let redName = "theme-\(defaultLightId).json"
        var red: Theme?
        if let url = urls.first(where: { $0.lastPathComponent == redName }), let data = try? Data(contentsOf: url) {
            red = parse(data, fallback: nil, file: redName)
        }
        if red == nil {
            appearanceLogger.fault("default theme \(defaultLightId, privacy: .public) failed to load")
        }
        var themes: [Theme] = red.map { [$0] } ?? []
        for url in urls where url.lastPathComponent != redName {
            guard let data = try? Data(contentsOf: url),
                  let theme = parse(data, fallback: red, file: url.lastPathComponent) else { continue }
            guard !themes.contains(where: { $0.id == theme.id }) else {
                appearanceLogger.error("\(url.lastPathComponent, privacy: .public): duplicate id \(theme.id, privacy: .public), skipped")
                continue
            }
            themes.append(theme)
        }
        return themes.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
    }
}
