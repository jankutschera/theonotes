// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import SwiftUI
import Testing
@testable import TheoNotes

/// M7 Task 9: the shell draws the resolved theme's `shell.*` tokens through `ShellPalette`.
@MainActor
@Suite struct ShellPaletteTests {
    private func theme(_ id: String) throws -> Theme { try #require(ThemeCatalog.theme(id: id)) }

    private func resolved(
        _ id: String, reduceTransparency: Bool = false, increaseContrast: Bool = false, reduceMotion: Bool = false
    ) throws -> ResolvedAppearance {
        ResolvedAppearance(
            theme: try theme(id), reduceMotion: reduceMotion, reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast)
    }

    private func source(_ file: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/\(file)"), encoding: .utf8)
    }

    @Test func paletteUsesThemeColours() throws {
        let red = try theme("baerchen-red")
        let palette = ShellPalette.resolve(try resolved("baerchen-red"))
        #expect(palette.themeColor(.background) == ThemeColor(hex: "#ffffff"))
        for token in ShellToken.allCases {
            #expect(palette.themeColor(token) == red.color(token), "\(token)")
        }
        let accent = red.color(.accent)
        #expect(palette.accent == Color(.sRGB, red: accent.red, green: accent.green, blue: accent.blue, opacity: accent.alpha))
        // A dark theme gives different colours: the palette follows the theme it was resolved from.
        let dark = ShellPalette.resolve(try resolved("baerchen-dark"))
        #expect(dark != palette)
        #expect(dark.themeColor(.background) == (try theme("baerchen-dark")).color(.background))
    }

    @Test func everyThemeHasAPalette() {
        for theme in ThemeCatalog.all() {
            let palette = ShellPalette.resolve(
                ResolvedAppearance(theme: theme, reduceMotion: false, reduceTransparency: false, increaseContrast: false))
            for token in ShellToken.allCases {
                #expect(palette.themeColor(token) == theme.color(token), "\(theme.id) \(token)")
            }
        }
    }

    @Test func reduceTransparencyMakesEveryColourOpaque() throws {
        var checked = 0
        for theme in ThemeCatalog.all() {
            let palette = ShellPalette.resolve(
                ResolvedAppearance(theme: theme, reduceMotion: false, reduceTransparency: true, increaseContrast: false))
            let background = palette.themeColor(.background)
            #expect(background.alpha == 1, "\(theme.id) background")
            for token in ShellToken.allCases {
                let drawn = palette.themeColor(token)
                #expect(drawn.alpha == 1, "\(theme.id) \(token)")
                if token == .background { continue }
                let expected = ShellPalette.composite(theme.color(token), over: background)
                #expect(drawn == expected, "\(theme.id) \(token) is composited over the background")
                checked += 1
            }
        }
        #expect(checked > 0)
        // A concrete case: Theo Notes Red's selection (#c22c28 at 20 %) over white.
        let red = ShellPalette.resolve(try resolved("baerchen-red", reduceTransparency: true))
        let selection = red.themeColor(.selection)
        #expect(abs(selection.red - (194.0 / 255 * 0.2 + 0.8)) < 0.001)
        #expect(abs(selection.green - (44.0 / 255 * 0.2 + 0.8)) < 0.001)
        // Without the option the tints stay translucent.
        let plain = ShellPalette.resolve(try resolved("baerchen-red"))
        #expect(plain.themeColor(.selection).alpha < 1)
        #expect(plain.themeColor(.searchHighlight).alpha < 1)
    }

    @Test func increaseContrastPaletteComesFromTheHighContrastTheme() throws {
        let light = ThemeResolver.resolve(
            mode: .light, systemIsDark: false, increaseContrast: true, lightThemeId: "baerchen-red",
            darkThemeId: "baerchen-dark")
        #expect(light.id == "high-contrast")
        let palette = ShellPalette.resolve(
            ResolvedAppearance(theme: light, reduceMotion: false, reduceTransparency: false, increaseContrast: true))
        let high = try theme("high-contrast")
        for token in ShellToken.allCases { #expect(palette.themeColor(token) == high.color(token), "\(token)") }
        #expect(palette != ShellPalette.resolve(try resolved("baerchen-red")))

        let dark = ThemeResolver.resolve(
            mode: .dark, systemIsDark: true, increaseContrast: true, lightThemeId: "baerchen-red",
            darkThemeId: "baerchen-dark")
        #expect(dark.id == "oled-black")
    }

    @Test func paletteFollowsTheControllersResolvedLook() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TheoNotesShell-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let system = FakeSystemAppearance()
        let environment = try AppEnvironment(paths: AppPaths(root: root), systemAppearance: system)
        #expect(ShellPalette.resolve(environment.appearance.resolved) == ShellPalette.default)
        system.reduceTransparency = true
        system.reduceMotion = true
        system.fire()
        let palette = ShellPalette.resolve(environment.appearance.resolved)
        #expect(palette.reduceTransparency && palette.reduceMotion)
        #expect(palette.themeColor(.selection).alpha == 1)
        system.increaseContrast = true
        system.fire()
        #expect(environment.appearance.resolved.theme.id == "high-contrast")
        #expect(ShellPalette.resolve(environment.appearance.resolved).themeColor(.text) == (try theme("high-contrast")).color(.text))
    }

    @Test func noteRowUsesPaletteColoursNotSystemPrimary() throws {
        let row = try source("Library/NoteRow.swift")
        for style in [".primary", ".secondary", ".tertiary", ".quaternary", ".tint"] {
            #expect(!row.contains("foregroundStyle(\(style))"), "NoteRow still uses foregroundStyle(\(style))")
        }
        #expect(!row.contains("Color.yellow"))
        #expect(row.contains("palette.text") && row.contains("palette.secondaryText") && row.contains("palette.searchHighlight"))
        let list = try source("Library/NoteListView.swift")
        #expect(list.contains(".scrollContentBackground(.hidden)") && list.contains(".background(palette.background)"))
        #expect(!list.contains(".background(.bar)"))
    }

    /// The selection fill is the system's (the user's accent), so selected rows use the system's
    /// text colour for it, and no theme tint changes that fill.
    @Test func selectedRowsUseTheSystemSelectionPair() throws {
        #expect(NoteRow.selectedText == Color(nsColor: .alternateSelectedControlTextColor))
        let row = try source("Library/NoteRow.swift")
        #expect(!row.contains("onAccent"), "on-accent is only checked against the theme accent, not the system fill")
        #expect(!(try source("Library/NoteListView.swift")).contains(".tint("))
        #expect(!(try source("Library/SidebarView.swift")).contains(".tint("))
    }

    /// "system selection, system text". A selected row that is not emphasized (the list is not
    /// focused: the editor has focus, or another window is key) sits on the system's grey
    /// `unemphasizedSelectedContentBackgroundColor`, so it uses the system label colours, never the theme's
    /// text (15 of 18 themes' secondary text fell under 4.5:1 there).
    @Test func anUnfocusedSelectedRowUsesTheSystemLabelColours() throws {
        #expect(NoteRow.selectionStyle(isSelected: true, prominence: .standard) == .unemphasized)
        let colours = try #require(NoteRow.systemText(for: .unemphasized))
        #expect(colours.primary == NSColor.labelColor)
        #expect(colours.secondary == NSColor.secondaryLabelColor)
        #expect(NoteRow.underlinesMatches(in: .unemphasized), "a theme highlight on the grey fill is unchecked")
    }

    @Test func aFocusedSelectedRowUsesTheSystemSelectedTextColour() throws {
        for isSelected in [true, false] {
            #expect(NoteRow.selectionStyle(isSelected: isSelected, prominence: .increased) == .emphasized)
        }
        let colours = try #require(NoteRow.systemText(for: .emphasized))
        #expect(colours.primary == NSColor.alternateSelectedControlTextColor)
        #expect(colours.secondary == NSColor.alternateSelectedControlTextColor)
        #expect(NoteRow.underlinesMatches(in: .emphasized))
    }

    @Test func anUnselectedRowKeepsTheThemeColours() {
        #expect(NoteRow.selectionStyle(isSelected: false, prominence: .standard) == .none)
        #expect(NoteRow.systemText(for: .none) == nil)
        #expect(!NoteRow.underlinesMatches(in: .none))
    }

    @Test func theListTellsEachRowWhetherItIsSelected() throws {
        #expect(try source("Library/NoteListView.swift").contains("isSelected: model.selectedNoteIDs.contains(item.id)"))
    }

    /// On the selection fill a (Reduce Transparency: opaque) highlight under selected text is
    /// unreadable, so matches are underlined there instead.
    @Test func selectedRowsUnderlineMatchesInsteadOfHighlighting() {
        let underlined = SearchHighlight.attributed("Weekly review", terms: ["week"], background: nil)
        let marked = underlined.runs.filter { $0.underlineStyle != nil }
        #expect(marked.count == 1)
        #expect(underlined.runs.allSatisfy { $0.backgroundColor == nil })
        let highlighted = SearchHighlight.attributed("Weekly review", terms: ["week"], background: .yellow)
        #expect(highlighted.runs.contains { $0.backgroundColor != nil })
        #expect(highlighted.runs.allSatisfy { $0.underlineStyle == nil })
    }

    // MARK: - OLED Black reaches the shell (carried from M7 Task 3)

    @Test func oledBlackIsPureBlackInThePalette() throws {
        let palette = ShellPalette.resolve(try resolved("oled-black"))
        #expect(palette.themeColor(.background) == ThemeColor(hex: "#000000"))
        #expect(palette.sidebarIsOpaque, "glass cannot guarantee #000000, so the sidebar draws the background")
        #expect(!ShellPalette.resolve(try resolved("baerchen-red")).sidebarIsOpaque, "other themes keep the system glass")
        #expect(ShellPalette.resolve(try resolved("baerchen-red", reduceTransparency: true)).sidebarIsOpaque)
    }

    /// The bitmap of `view` as a window shows it, the way `LibrarySnapshotTests` renders, sampled at
    /// `points` (view points, top-left origin; scaled to the bitmap's pixels).
    private func pixels(of view: some View, size: CGSize, at points: [CGPoint], appearance: NSAppearance.Name) async throws -> [NSColor] {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        hosting.layoutSubtreeIfNeeded()
        hosting.display()
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.contentView = nil
        window.close()
        let scale = CGFloat(rep.pixelsWide) / hosting.bounds.width
        return try points.map { point in
            let color = try #require(rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale)))
            return try #require(color.usingColorSpace(.sRGB))
        }
    }

    private func isBlack(_ c: NSColor) -> Bool {
        (c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent) == (0, 0, 0, 1)
    }

    private struct Panes: View {
        enum Kind { case sidebar, list }
        let kind: Kind
        let state: MainWindowState
        @FocusState private var pane: Pane?

        var body: some View {
            switch kind {
            case .sidebar: SidebarView(model: state.model, showNoteCounts: true, pane: $pane)
            case .list: NavigationStack { NoteListView(state: state, pane: $pane) }
            }
        }
    }

    @Test func oledBlackReachesTheNoteListAndTheSidebarBackgrounds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TheoNotesShell-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = try AppEnvironment(paths: AppPaths(root: root))
        _ = try environment.store.create(text: "One note\nWith a preview line.")
        let suite = "TheoNotesShell-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = MainWindowState(environment: environment, defaults: defaults)
        let palette = ShellPalette.resolve(try resolved("oled-black"))

        let size = CGSize(width: 300, height: 400)
        // Empty spots in the lower third: below the one row and the sidebar sections, away from controls.
        let empty = [CGPoint(x: 280, y: 380), CGPoint(x: 150, y: 370), CGPoint(x: 40, y: 390)]
        for kind in [Panes.Kind.list, .sidebar] {
            let samples = try await pixels(
                of: Panes(kind: kind, state: state).environment(\.shellPalette, palette), size: size, at: empty,
                appearance: .darkAqua)
            #expect(samples.allSatisfy(isBlack), "\(kind) \(samples)")
        }
        // Negative control: Theo Notes Dark's graphite list is not black, so the samples hit the background.
        let dark = ShellPalette.resolve(try resolved("baerchen-dark"))
        let control = try await pixels(
            of: Panes(kind: .list, state: state).environment(\.shellPalette, dark), size: size, at: empty,
            appearance: .darkAqua)
        #expect(!control.contains(where: isBlack), "Theo Notes Dark list \(control)")
    }

    // MARK: - Reduce Motion

    @Test func quickOpenPanelDoesNotAnimateUnderReduceMotion() throws {
        #expect(QuickOpenPanel.animationBehavior(reduceMotion: true) == .none)
        #expect(QuickOpenPanel.animationBehavior(reduceMotion: false) == .utilityWindow)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TheoNotesShell-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let system = FakeSystemAppearance()
        system.reduceMotion = true
        let environment = try AppEnvironment(paths: AppPaths(root: root), systemAppearance: system)
        let controller = QuickOpenController()
        controller.show(try QuickOpenModel.load(environment: environment), over: nil, appearance: environment.appearance)
        #expect(controller.panel?.animationBehavior == NSWindow.AnimationBehavior.none)
        controller.dismiss(restoringFocus: false)
        system.reduceMotion = false
        system.fire()
        controller.show(try QuickOpenModel.load(environment: environment), over: nil, appearance: environment.appearance)
        #expect(controller.panel?.animationBehavior == .utilityWindow)
        controller.dismiss(restoringFocus: false)
    }

    @Test func quickOpenKeepsItsSelectedRowColoursWhateverTheTheme() throws {
        let source = try source("QuickOpen/QuickOpenPanel.swift")
        #expect(source.contains("NSColor(named: \"AccentColor\")") && source.contains("NSColor(named: \"OnAccentColor\")"))
        #expect(source.contains("Color(nsColor: QuickOpenColors.selectedFill)"), "M7-R9: the selected fill is the asset colour")
    }
}
