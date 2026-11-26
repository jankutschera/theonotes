// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

@Suite struct ThemeTests {
    private struct Schema: Decodable {
        let editorTokens: [String]
        let shellTokens: [String]
    }

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private func schema() throws -> Schema {
        let url = Self.repoRoot.appendingPathComponent("Fixtures/themes/theme-schema.json")
        return try JSONDecoder().decode(Schema.self, from: Data(contentsOf: url))
    }

    private func red() -> Theme { ThemeCatalog.theme(id: ThemeCatalog.defaultLightId)! }

    private func make(
        _ id: String, _ appearance: ThemeAppearance, _ contrast: ThemeContrast = .standard, order: Int = 100
    ) -> Theme {
        let base = red()
        return Theme(
            schemaVersion: 1, id: id, name: id, order: order, appearance: appearance, contrast: contrast,
            source: base.source, deviations: [], editor: base.editor, shell: base.shell)
    }

    @Test func testEveryBundledThemeHasEverySchemaToken() throws {
        let schema = try schema()
        let themes = ThemeCatalog.all()
        #expect(!themes.isEmpty)
        for theme in themes {
            #expect(Set(theme.editor.keys) == Set(schema.editorTokens), "\(theme.id) editor")
            #expect(Set(theme.shell.keys) == Set(schema.shellTokens), "\(theme.id) shell")
            for (token, value) in theme.editor.merging(theme.shell, uniquingKeysWith: { a, _ in a }) {
                #expect(ThemeColor(hex: value) != nil, "\(theme.id) \(token) = \(value)")
            }
        }
    }

    @Test func testSwiftTokenListsMatchTheSchemaFile() throws {
        let schema = try schema()
        // Arrays and counts, so a duplicate on either side is caught (a Set would hide it).
        #expect(ThemeSchema.editorTokenList.sorted() == schema.editorTokens.sorted())
        #expect(ThemeSchema.editorTokenList.count == schema.editorTokens.count)
        #expect(Set(schema.editorTokens).count == schema.editorTokens.count)
        #expect(ShellToken.allCases.map(\.rawValue).sorted() == schema.shellTokens.sorted())
        #expect(ShellToken.allCases.count == schema.shellTokens.count)
    }

    @Test func testBundledThemeFilesAreCompleteWithoutFilling() throws {
        let schema = try schema()
        let dir = Self.repoRoot.appendingPathComponent("Packages/TheoNotesCore/Sources/TheoNotesCore/Resources")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("theme-") && $0.pathExtension == "json" }
        #expect(!files.isEmpty)
        for file in files {
            let data = try Data(contentsOf: file)
            let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect((raw["editor"] as? [String: String])?.keys.sorted() == schema.editorTokens.sorted(), "\(file.lastPathComponent) editor")
            #expect((raw["shell"] as? [String: String])?.keys.sorted() == schema.shellTokens.sorted(), "\(file.lastPathComponent) shell")
            // Parsing without a fallback succeeds only when nothing needs filling or dropping.
            let parsed = try #require(ThemeCatalog.parse(data, fallback: nil, file: file.lastPathComponent))
            #expect(parsed.editor == raw["editor"] as? [String: String], "\(file.lastPathComponent)")
            #expect(parsed.shell == raw["shell"] as? [String: String], "\(file.lastPathComponent)")
        }
    }

    @Test func testHexParsing() {
        #expect(ThemeColor(hex: "#d9534f1c")?.alpha == 28.0 / 255)
        #expect(ThemeColor(hex: "#d9534f")?.alpha == 1)
        #expect(ThemeColor(hex: "#ff0000")?.red == 1)
        #expect(ThemeColor(hex: "#fff") == nil)
        #expect(ThemeColor(hex: "red") == nil)
        #expect(ThemeColor(hex: "d9534f") == nil)
        #expect(ThemeColor(hex: "#gg0000") == nil)
        #expect(ThemeColor(hex: "#d9534f1") == nil)
        #expect(ThemeColor(hex: "#+12345") == nil)
    }

    @Test func testEditorVariablesArePrefixed() {
        let theme = red()
        #expect(theme.editorVariables["--bc-color-text"] == "#2b2b2b")
        #expect(theme.editorVariables.count == theme.editor.count)
        #expect(theme.editorVariables.keys.allSatisfy { $0.hasPrefix("--bc-") })
    }

    /// M7 Task 6: the variables are stored with the theme (not rebuilt per settings send), so they
    /// must follow the map, through a decode and through an edit of `editor`.
    @Test func testEditorVariablesAreCachedAndStayInSync() throws {
        var theme = red()
        let before = theme.editorVariables
        #expect(before == theme.editorVariables)
        theme.editor["color-text"] = "#010203"
        #expect(theme.editorVariables["--bc-color-text"] == "#010203")
        #expect(theme.editorVariables.count == before.count)

        let data = try JSONEncoder().encode(red())
        #expect(try JSONSerialization.jsonObject(with: data) is [String: Any])
        #expect((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["editorVariables"] == nil)
        let decoded = try JSONDecoder().decode(Theme.self, from: data)
        #expect(decoded == red())
        #expect(decoded.editorVariables == red().editorVariables)
    }

    @Test func testShellColorReadsTheShellMap() {
        let theme = red()
        #expect(theme.color(.background) == ThemeColor(hex: "#ffffff"))
        #expect(theme.color(.searchHighlight) == ThemeColor(hex: theme.shell["search-highlight"]!))
    }

    @Test func testResolverSlots() {
        let light = make("l", .light), dark = make("d", .dark)
        let catalog = [red(), light, dark]
        func pick(_ mode: AppearanceMode, _ systemDark: Bool) -> String {
            ThemeResolver.resolve(
                mode: mode, systemIsDark: systemDark, increaseContrast: false, lightThemeId: "l", darkThemeId: "d",
                catalog: catalog
            ).id
        }
        #expect(pick(.light, true) == "l")
        #expect(pick(.dark, false) == "d")
        #expect(pick(.system, false) == "l")
        #expect(pick(.system, true) == "d")
    }

    @Test func testResolverFallsBackForUnknownOrMismatchedIds() {
        let dark = make("d", .dark)
        let catalog = [red(), dark]
        func light(_ id: String) -> String {
            ThemeResolver.resolve(
                mode: .light, systemIsDark: false, increaseContrast: false, lightThemeId: id, darkThemeId: "d",
                catalog: catalog
            ).id
        }
        #expect(light("nope") == "baerchen-red")
        #expect(light("d") == "baerchen-red")
        #expect(light("") == "baerchen-red")
        // Unknown dark id: the dark default does not exist in this catalog, so the light default stands in.
        #expect(
            ThemeResolver.resolve(
                mode: .dark, systemIsDark: true, increaseContrast: false, lightThemeId: "baerchen-red",
                darkThemeId: "nope", catalog: catalog
            ).id == "baerchen-red")
        // A catalog with only the default light theme (baerchen-dark failed to load) gives it to the dark slot too.
        #expect(
            ThemeResolver.resolve(
                mode: .dark, systemIsDark: false, increaseContrast: false, lightThemeId: "nope", darkThemeId: "nope",
                catalog: [red()]
            ).id == "baerchen-red")
        // Public entry point against the bundled catalog: the light slot always lands on a light theme.
        let bundled = ThemeResolver.resolve(
            mode: .light, systemIsDark: false, increaseContrast: false, lightThemeId: "nope", darkThemeId: "nope")
        #expect(bundled.id == "baerchen-red")
    }

    @Test func testResolverUsesTheDarkDefaultWhenPresent() {
        let catalog = [red(), make("baerchen-dark", .dark)]
        let theme = ThemeResolver.resolve(
            mode: .dark, systemIsDark: true, increaseContrast: false, lightThemeId: "baerchen-red",
            darkThemeId: "nope", catalog: catalog)
        #expect(theme.id == "baerchen-dark")
    }

    @Test func testResolverIncreaseContrastSwapsStandardThemes() {
        let catalog = [
            red(), make("d", .dark), make("high-contrast", .light, .high), make("oled-black", .dark, .high),
        ]
        func pick(_ mode: AppearanceMode, _ light: String, _ dark: String) -> String {
            ThemeResolver.resolve(
                mode: mode, systemIsDark: false, increaseContrast: true, lightThemeId: light, darkThemeId: dark,
                catalog: catalog
            ).id
        }
        #expect(pick(.light, "baerchen-red", "d") == "high-contrast")
        #expect(pick(.dark, "baerchen-red", "d") == "oled-black")
        // A high-contrast theme the user picked stays.
        #expect(pick(.light, "high-contrast", "d") == "high-contrast")
        #expect(pick(.dark, "baerchen-red", "oled-black") == "oled-black")
        // Without the high-contrast files the chosen theme stays.
        let bare = [red(), make("d", .dark)]
        #expect(
            ThemeResolver.resolve(
                mode: .light, systemIsDark: false, increaseContrast: true, lightThemeId: "baerchen-red",
                darkThemeId: "d", catalog: bare
            ).id == "baerchen-red")
    }

    @Test func testResolverIncreaseContrastAgainstBundledCatalog() {
        func pick(_ mode: AppearanceMode, _ increaseContrast: Bool, _ light: String, _ dark: String) -> Theme {
            ThemeResolver.resolve(
                mode: mode, systemIsDark: false, increaseContrast: increaseContrast, lightThemeId: light,
                darkThemeId: dark)
        }
        #expect(pick(.light, true, "baerchen-red", "baerchen-dark").id == "high-contrast")
        #expect(pick(.dark, true, "baerchen-red", "baerchen-dark").id == "oled-black")
        #expect(pick(.light, false, "baerchen-red", "baerchen-dark").id == "baerchen-red")
        #expect(pick(.dark, false, "baerchen-red", "baerchen-dark").id == "baerchen-dark")
        // An unknown dark id now lands on the dark default, not on the light one.
        #expect(pick(.dark, false, "baerchen-red", "nope").id == "baerchen-dark")
    }

    @Test func testBundledOwnThemes() throws {
        let expected: [(String, ThemeAppearance, ThemeContrast, Int)] = [
            ("baerchen-red", .light, .standard, 10), ("baerchen-dark", .dark, .standard, 11),
            ("high-contrast", .light, .high, 20), ("oled-black", .dark, .high, 21),
        ]
        for (id, appearance, contrast, order) in expected {
            let theme = try #require(ThemeCatalog.theme(id: id), "\(id)")
            #expect(theme.appearance == appearance, "\(id)")
            #expect(theme.contrast == contrast, "\(id)")
            #expect(theme.order == order, "\(id)")
        }
        #expect(ThemeCatalog.defaultDarkId == "baerchen-dark")
        let oled = try #require(ThemeCatalog.theme(id: "oled-black"))
        #expect(oled.editor["color-bg"] == "#000000")
        #expect(oled.shell["background"] == "#000000")
    }

    /// The asset catalog's colours by appearance key (`[]`, `luminosity=dark`, `contrast=high`, both) as sRGB hex.
    private func assetColors(_ name: String) throws -> [Set<String>: String] {
        struct Asset: Decodable {
            struct Entry: Decodable {
                struct Appearance: Decodable { let appearance: String; let value: String }
                struct Color: Decodable { let components: [String: String] }
                let appearances: [Appearance]?
                let color: Color
            }
            let colors: [Entry]
        }
        let url = Self.repoRoot.appendingPathComponent("Apps/TheoNotesMac/Assets.xcassets/\(name).colorset/Contents.json")
        let asset = try JSONDecoder().decode(Asset.self, from: Data(contentsOf: url))
        var out: [Set<String>: String] = [:]
        for entry in asset.colors {
            let parts = try ["red", "green", "blue"].map { key -> String in
                let raw = try #require(entry.color.components[key], "\(key)")
                let value = try #require(Int(raw.dropFirst(2), radix: 16), "\(raw)")
                return String(format: "%02x", value)
            }
            #expect(entry.color.components["alpha"] == "1.000")
            out[Set((entry.appearances ?? []).map { "\($0.appearance)=\($0.value)" })] = "#" + parts.joined()
        }
        return out
    }

    private static let darkShellPairs: [(Set<String>, String)] = [
        (["luminosity=dark"], "baerchen-dark"), (["luminosity=dark", "contrast=high"], "oled-black"),
    ]

    private static let assetVariants: [Set<String>] = [[], ["luminosity=dark"], ["contrast=high"], ["luminosity=dark", "contrast=high"]]

    /// WCAG 2.x contrast ratio of two `#rrggbb` colours.
    private func contrast(_ a: String, _ b: String) -> Double {
        func luminance(_ hex: String) -> Double {
            let value = Int(hex.dropFirst(), radix: 16) ?? 0
            func channel(_ shift: Int) -> Double {
                let v = Double((value >> shift) & 0xff) / 255
                return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// The asset `AccentColor` is the user's accent under "Multicolor", so the system paints the selected
    /// rows of the note list and the sidebar with it and draws white text on it. It is a fill, decoupled from the
    /// themes' text accent: white on it must pass 4.5:1 in every appearance variant (dark was 2.53:1, #ff7a76).
    @Test(arguments: assetVariants)
    func testAccentColorCarriesWhiteTextOnItsFill(_ variant: Set<String>) throws {
        let colors = try assetColors("AccentColor")
        #expect(colors.count == Self.assetVariants.count, "AccentColor has exactly the four variants")
        let accent = try #require(colors[variant], "AccentColor \(variant)")
        let ratio = contrast(accent, "#ffffff")
        #expect(ratio >= 4.5, "white on AccentColor \(variant.sorted()) \(accent): \(ratio)")
        // The pair Quick Open draws on its selected row is white too.
        let onAccent = try #require(try assetColors("OnAccentColor")[variant], "OnAccentColor \(variant)")
        #expect(onAccent == "#ffffff", "OnAccentColor \(variant.sorted())")
    }

    /// The same asset tints icons and controls in dark mode, so it must stay visible (3:1, WCAG 1.4.11) on the
    /// dark themes' backgrounds: Theo Notes Dark for dark, OLED Black for dark + Increase Contrast.
    @Test(arguments: darkShellPairs)
    func testAccentColorStaysVisibleOnTheDarkShell(_ variant: Set<String>, themeId: String) throws {
        let accent = try #require(try assetColors("AccentColor")[variant])
        let background = try #require(ThemeCatalog.theme(id: themeId)?.shell["background"])
        let ratio = contrast(accent, background)
        #expect(ratio >= 3, "AccentColor \(accent) on \(themeId) \(background): \(ratio)")
    }

    @Test func testCatalogIsSortedByOrderAndIdsAreUnique() {
        let all = ThemeCatalog.all()
        #expect(all.map(\.order) == all.map(\.order).sorted())
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(ThemeCatalog.themes(.light).allSatisfy { $0.appearance == .light })
        #expect(ThemeCatalog.theme(id: "baerchen-red")?.name == "Theo Red")
        #expect(ThemeCatalog.theme(id: "nope") == nil)
    }

    @Test func testResolverNeverPutsADarkThemeInTheLightSlot() {
        let darkOnly = [make("baerchen-dark", .dark), make("other-dark", .dark, order: 5)]
        for mode in [AppearanceMode.light, .system] {
            let theme = ThemeResolver.resolve(
                mode: mode, systemIsDark: false, increaseContrast: false, lightThemeId: "other-dark",
                darkThemeId: "baerchen-dark", catalog: darkOnly)
            #expect(theme.appearance == .light, "\(mode)")
        }
        // The default light theme failed to load but another light theme did: that one, not catalog.first.
        let catalog = [make("a-dark", .dark, order: 1), make("some-light", .light, order: 2)]
        #expect(
            ThemeResolver.resolve(
                mode: .light, systemIsDark: false, increaseContrast: false, lightThemeId: "nope", darkThemeId: "nope",
                catalog: catalog
            ).id == "some-light")
    }

    @Test func testBuiltinFallbackIsReadable() throws {
        let theme = ThemeResolver.resolve(
            mode: .light, systemIsDark: false, increaseContrast: false, lightThemeId: "baerchen-red",
            darkThemeId: "baerchen-dark", catalog: [])
        #expect(theme.appearance == .light)
        #expect(Set(theme.editor.keys) == ThemeSchema.editorTokens)
        #expect(Set(theme.shell.keys) == ThemeSchema.shellTokens)
        func colour(_ token: String) throws -> ThemeColor {
            let hex = try #require(theme.editor[token], "\(token)")
            return try #require(ThemeColor(hex: hex), "\(token)")
        }
        #expect(try colour("color-bg") == ThemeColor(red: 1, green: 1, blue: 1))
        #expect(try colour("color-text") == ThemeColor(red: 0, green: 0, blue: 0))
        // Every fill is white or translucent, so the black text on top stays readable.
        let fills = theme.editor.keys.filter {
            $0.hasSuffix("-bg") || $0.hasPrefix("highlight") && !$0.contains("dot") || $0.hasPrefix("color-search-match")
                || $0 == "color-selection"
        }
        #expect(fills.count > 20)
        for token in fills {
            let c = try colour(token)
            #expect(c.alpha < 1 || (c.red == 1 && c.green == 1 && c.blue == 1), "\(token)")
        }
        #expect(try colour("color-selection").alpha < 1)
        #expect(theme.color(.selection).alpha < 1)
        #expect(theme.color(.background) == ThemeColor(red: 1, green: 1, blue: 1))
        #expect(theme.color(.searchHighlight).alpha < 1)
        // Text on an accent fill (Quick Open's selected row) stays readable: the accent is black, so white.
        #expect(theme.color(.onAccent) == ThemeColor(red: 1, green: 1, blue: 1))
        #expect(theme.color(.accent) == ThemeColor(red: 0, green: 0, blue: 0))
        for (token, value) in theme.editor.merging(theme.shell, uniquingKeysWith: { a, _ in a }) {
            #expect(ThemeColor(hex: value) != nil, "\(token)")
        }
    }

    @Test func testSchemaVersionMustBeInSupportedRange() throws {
        for version in [0, -1, 2] {
            let data = try json(make("v", .light)) { $0["schemaVersion"] = version }
            #expect(ThemeCatalog.parse(data, fallback: red()) == nil, "version \(version)")
        }
        #expect(try ThemeCatalog.parse(json(make("v", .light)), fallback: red()) != nil)
    }

    @Test func testIncreaseContrastPickMustMatchTheSlot() {
        // A dark "high-contrast" file must not land in the light slot.
        let catalog = [red(), make("high-contrast", .dark, .high)]
        let theme = ThemeResolver.resolve(
            mode: .light, systemIsDark: false, increaseContrast: true, lightThemeId: "baerchen-red",
            darkThemeId: "x", catalog: catalog)
        #expect(theme.id == "baerchen-red")
    }

    // MARK: Loading

    private func json(_ theme: Theme, edit: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(theme)) as! [String: Any]
        edit(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func testNewerSchemaVersionIsSkipped() throws {
        let data = try json(make("future", .light)) { $0["schemaVersion"] = 2; $0["editor"] = "restructured" }
        #expect(ThemeCatalog.parse(data, fallback: red()) == nil)
    }

    @Test func testMissingTokensAreFilledFromTheFallback() throws {
        let data = try json(make("partial", .light)) { object in
            var editor = object["editor"] as! [String: String]
            editor["color-text"] = nil
            var shell = object["shell"] as! [String: String]
            shell["accent"] = nil
            object["editor"] = editor
            object["shell"] = shell
        }
        let theme = try #require(ThemeCatalog.parse(data, fallback: red()))
        #expect(theme.editor["color-text"] == red().editor["color-text"])
        #expect(theme.shell["accent"] == red().shell["accent"])
        #expect(Set(theme.editor.keys) == ThemeSchema.editorTokens)
    }

    @Test func testUnknownTokensAndBadValuesNeverReachTheEditor() throws {
        let data = try json(make("hostile", .light)) { object in
            var editor = object["editor"] as! [String: String]
            editor["color-evil"] = "#000000"
            editor["font-size"] = "99px"
            editor["color-text"] = "red; } body { display:none"
            object["editor"] = editor
            var shell = object["shell"] as! [String: String]
            shell["bogus"] = "#123456"
            object["shell"] = shell
        }
        let theme = try #require(ThemeCatalog.parse(data, fallback: red()))
        #expect(theme.editor["color-evil"] == nil)
        #expect(theme.editor["font-size"] == nil)
        #expect(theme.shell["bogus"] == nil)
        #expect(theme.editor["color-text"] == red().editor["color-text"])
        #expect(theme.editorVariables.keys.allSatisfy { ThemeSchema.editorTokens.contains(String($0.dropFirst(5))) })
    }

    @Test func testSanitizeDropsUnknownVariablesAndNonColours() {
        let input = [
            "--bc-color-text": "#112233",
            "--bc-color-evil": "#000000",
            "--bc-color-bg": "url(javascript:1)",
            "color-text": "#112233",
            "--other": "#000000",
        ]
        #expect(ThemeSchema.sanitize(variables: input) == ["--bc-color-text": "#112233"])
        #expect(ThemeSchema.sanitize(variables: [:]).isEmpty)
    }

    @Test func testThemeWithoutAFallbackIsRejectedWhenIncomplete() throws {
        let data = try json(make("partial", .light)) { object in
            var editor = object["editor"] as! [String: String]
            editor["color-text"] = nil
            object["editor"] = editor
        }
        #expect(ThemeCatalog.parse(data, fallback: nil) == nil)
    }

    /// M7 Task 14: the catalog ships the 18 themes of spec section 4.7, each with a licence, and every upstream
    /// project's licence text is bundled.
    @Test func testCatalogShipsTheSpecThemeList() throws {
        let expected: Set<String> = [
            "baerchen-red", "baerchen-dark", "high-contrast", "oled-black", "solarized-light", "solarized-dark",
            "nord", "nord-light", "dracula", "gruvbox", "catppuccin-latte", "catppuccin-macchiato", "tokyo-night",
            "tokyo-night-light", "rose-pine", "rose-pine-dawn", "everforest-light", "everforest-dark",
        ]
        let ids = Set(ThemeCatalog.all().map(\.id))
        #expect(expected.subtracting(ids).isEmpty, "missing: \(expected.subtracting(ids).sorted())")
        #expect(ids.subtracting(expected).isEmpty, "unexpected: \(ids.subtracting(expected).sorted())")
        #expect(ThemeCatalog.all().count == 18)
        let dir = Self.repoRoot.appendingPathComponent("Packages/TheoNotesCore/Sources/TheoNotesCore/Resources")
        for theme in ThemeCatalog.all() {
            #expect(!theme.source.license.isEmpty, "\(theme.id) has no licence")
            if theme.source.license == "LicenseRef-TrueBrewBirdie" { continue }
            let slug = theme.source.project.lowercased().replacingOccurrences(of: " ", with: "-")
                .folding(options: .diacriticInsensitive, locale: nil)
            let file = dir.appendingPathComponent("theme-license-\(slug).txt")
            let text = try #require(try? String(contentsOf: file, encoding: .utf8), "\(theme.id): \(file.lastPathComponent) is missing")
            #expect(text.count > 200, "\(theme.id): licence text is suspiciously short")
        }
    }
}
