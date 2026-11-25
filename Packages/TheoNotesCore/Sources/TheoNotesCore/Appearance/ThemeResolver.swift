// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

public enum ThemeResolver {
    static let highContrastLightId = "high-contrast"
    static let highContrastDarkId = "oled-black"

    public static func resolve(
        mode: AppearanceMode, systemIsDark: Bool, increaseContrast: Bool, lightThemeId: String, darkThemeId: String
    ) -> Theme {
        resolve(
            mode: mode, systemIsDark: systemIsDark, increaseContrast: increaseContrast, lightThemeId: lightThemeId,
            darkThemeId: darkThemeId, catalog: ThemeCatalog.all())
    }

    /// `catalog` is injectable so the rules are testable before every theme file exists.
    static func resolve(
        mode: AppearanceMode, systemIsDark: Bool, increaseContrast: Bool, lightThemeId: String, darkThemeId: String,
        catalog: [Theme]
    ) -> Theme {
        let slot: ThemeAppearance =
            switch mode {
            case .light: .light
            case .dark: .dark
            case .system: systemIsDark ? .dark : .light
            }
        let requested = slot == .light ? lightThemeId : darkThemeId
        let chosen =
            catalog.first { $0.id == requested && $0.appearance == slot }
            ?? slotDefault(slot, in: catalog)
        if increaseContrast, chosen.contrast == .standard {
            let id = slot == .light ? highContrastLightId : highContrastDarkId
            if let high = catalog.first(where: { $0.id == id && $0.appearance == slot }) { return high }
        }
        return chosen
    }

    /// The slot default. If `baerchen-dark` failed to load, the dark slot uses `baerchen-red`.
    private static func slotDefault(_ slot: ThemeAppearance, in catalog: [Theme]) -> Theme {
        let id = slot == .light ? ThemeCatalog.defaultLightId : ThemeCatalog.defaultDarkId
        if let theme = catalog.first(where: { $0.id == id && $0.appearance == slot }) { return theme }
        if let red = catalog.first(where: { $0.id == ThemeCatalog.defaultLightId }) { return red }
        appearanceLogger.fault("default theme \(ThemeCatalog.defaultLightId, privacy: .public) is not in the catalog")
        // Another theme of the slot's own appearance, never the other one (no dark editor in a light shell).
        if let theme = catalog.first(where: { $0.appearance == slot }) { return theme }
        appearanceLogger.fault("no \(slot.rawValue, privacy: .public) theme loaded, using the built-in fallback theme")
        return builtin
    }

    /// Last resort when no usable theme loaded (a packaging error): black text on white, every fill white or
    /// translucent, so nothing is unreadable.
    private static let builtin: Theme = {
        var editor: [String: String] = [:]
        for token in ThemeSchema.editorTokens {
            editor[token] =
                switch token {
                case "color-bg", "color-popup-bg": "#ffffff"
                case "color-selection": "#0a84ff40"
                case "color-popup-selected-bg": "#0a84ff33"
                case "color-search-match", "color-search-match-current": "#ffd60a73"
                case "color-shadow": "#00000033"
                case "color-rule", "color-quote-bar": "#80808080"
                case let t where t.hasSuffix("-border"): "#808080"
                case let t where t.hasSuffix("-bg"), let t where t.hasPrefix("highlight") && !t.contains("dot"):
                    "#ffffff00"
                default: "#000000"
                }
        }
        var shell = Dictionary(uniqueKeysWithValues: ThemeSchema.shellTokens.map { ($0, "#000000") })
        shell["background"] = "#ffffff"
        shell["selection"] = "#0a84ff40"
        shell["search-highlight"] = "#ffd60a73"
        shell["separator"] = "#80808080"
        shell["on-accent"] = "#ffffff"
        return Theme(
            id: ThemeCatalog.defaultLightId, name: "Theo Notes", order: 0, appearance: .light, contrast: .standard,
            source: ThemeSource(project: "Theo Notes", url: "", license: "LicenseRef-TrueBrewBirdie", copyright: ""),
            editor: editor, shell: shell)
    }()
}
