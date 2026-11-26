// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import SwiftUI

/// The shell colours of the resolved theme (`shell.*` tokens), as the note list, the editor column, banners,
/// Quick Open and the Info panel draw them. Built from `ResolvedAppearance` (the one place themes are
/// resolved), never from a theme id.
///
/// With Reduce Transparency every colour is opaque: a tint is composited over `background`, and a background
/// that itself has alpha is composited over white (light) or black (dark).
struct ShellPalette: Equatable, Sendable {
    /// The token values as drawn (alpha 1 under Reduce Transparency).
    let tokens: [ShellToken: ThemeColor]
    let reduceTransparency: Bool
    let reduceMotion: Bool

    var accent: Color { color(.accent) }
    var background: Color { color(.background) }
    var text: Color { color(.text) }
    var secondaryText: Color { color(.secondaryText) }
    var selection: Color { color(.selection) }
    var selectionText: Color { color(.selectionText) }
    var separator: Color { color(.separator) }
    var searchHighlight: Color { color(.searchHighlight) }
    /// Text and icons on an opaque `accent` fill. No view uses it: selected rows draw the system's selection
    /// colours and Quick Open the asset `OnAccentColor`; it stays a checked schema token.
    var onAccent: Color { color(.onAccent) }

    /// The sidebar draws the theme background instead of the system glass: under Reduce Transparency (glass
    /// falls back to a solid), and for a pure black background (OLED Black), which glass cannot guarantee.
    var sidebarIsOpaque: Bool {
        let background = themeColor(.background)
        return reduceTransparency || (background.red == 0 && background.green == 0 && background.blue == 0)
    }

    private func color(_ token: ShellToken) -> Color {
        let value = tokens[token] ?? ThemeColor(red: 0, green: 0, blue: 0)
        return Color(.sRGB, red: value.red, green: value.green, blue: value.blue, opacity: value.alpha)
    }

    func themeColor(_ token: ShellToken) -> ThemeColor {
        tokens[token] ?? ThemeColor(red: 0, green: 0, blue: 0)
    }

    static func resolve(_ resolved: ResolvedAppearance) -> ShellPalette {
        let theme = resolved.theme
        var tokens = Dictionary(uniqueKeysWithValues: ShellToken.allCases.map { ($0, theme.color($0)) })
        if resolved.reduceTransparency {
            let base = theme.appearance == .dark ? ThemeColor(red: 0, green: 0, blue: 0) : ThemeColor(red: 1, green: 1, blue: 1)
            let background = composite(theme.color(.background), over: base)
            for token in ShellToken.allCases {
                tokens[token] = token == .background ? background : composite(theme.color(token), over: background)
            }
        }
        return ShellPalette(
            tokens: tokens, reduceTransparency: resolved.reduceTransparency, reduceMotion: resolved.reduceMotion)
    }

    /// `top` painted over the opaque `base` (non-premultiplied sRGB, like the browser and Core Graphics).
    static func composite(_ top: ThemeColor, over base: ThemeColor) -> ThemeColor {
        let alpha = top.alpha
        return ThemeColor(
            red: top.red * alpha + base.red * (1 - alpha),
            green: top.green * alpha + base.green * (1 - alpha),
            blue: top.blue * alpha + base.blue * (1 - alpha))
    }

    /// Theo Notes Red with no accessibility options: what a view outside a themed root draws (tests, previews).
    static let `default` = ShellPalette.resolve(
        ResolvedAppearance(
            theme: ThemeResolver.resolve(
                mode: .light, systemIsDark: false, increaseContrast: false,
                lightThemeId: ThemeCatalog.defaultLightId, darkThemeId: ThemeCatalog.defaultDarkId),
            reduceMotion: false, reduceTransparency: false, increaseContrast: false))
}

extension EnvironmentValues {
    @Entry var shellPalette = ShellPalette.default
}

/// Puts the palette of `appearance.resolved` into the environment of everything below. Reading `resolved` in
/// `body` makes the view follow a theme change, a system flip and the accessibility options.
private struct ShellPaletteInjector: ViewModifier {
    let appearance: AppearanceController

    func body(content: Content) -> some View {
        content.environment(\.shellPalette, ShellPalette.resolve(appearance.resolved))
    }
}

extension View {
    /// Roots of windows, panels and popover hosts that SwiftUI's environment does not reach (a detached panel).
    func shellPalette(from appearance: AppearanceController) -> some View {
        modifier(ShellPaletteInjector(appearance: appearance))
    }
}
