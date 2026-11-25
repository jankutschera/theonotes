// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import SwiftUI

/// What the Appearance pane shows for the bundled themes. All colours come from the theme files
/// (`ThemeCatalog`), none are literals here.
enum ThemePicker {
    /// The themes a picker offers: only those of `appearance` (a dark theme never shows in the light picker),
    /// in catalog order.
    static func options(_ appearance: ThemeAppearance) -> [Theme] {
        ThemeCatalog.themes(appearance).sorted { ($0.order, $0.id) < ($1.order, $1.id) }
    }

    /// The theme a picker shows as selected: the stored id, or the slot default while the stored id is
    /// unknown or of the other appearance (the resolver falls back the same way).
    static func selection(stored: String, appearance: ThemeAppearance) -> String {
        let options = options(appearance)
        if options.contains(where: { $0.id == stored }) { return stored }
        let fallback = appearance == .light ? ThemeCatalog.defaultLightId : ThemeCatalog.defaultDarkId
        return options.contains { $0.id == fallback } ? fallback : (options.first?.id ?? stored)
    }

    /// "Palette: <project> · <license> · <copyright>"; the app's own themes: "Theo Notes theme".
    static func credit(for theme: Theme) -> String {
        if theme.source.project == "Theo Notes" { return "Theo Notes theme" }
        return "Palette: \(theme.source.project) · \(theme.source.license) · \(theme.source.copyright)"
    }

    /// The theme Increase Contrast put in place of the chosen one, or nil when the choice stands.
    static func contrastOverride(increaseContrast: Bool, resolvedId: String, chosenId: String) -> Theme? {
        guard increaseContrast, resolvedId != chosenId,
            let resolved = ThemeCatalog.theme(id: resolvedId), resolved.contrast == .high,
            let chosen = ThemeCatalog.theme(id: chosenId), chosen.contrast == .standard
        else { return nil }
        return resolved
    }
}

/// A small preview of a theme: its page colour with a text dot and an accent dot.
enum ThemeSwatch {
    static func image(for theme: Theme) -> NSImage {
        let size = NSSize(width: 40, height: 16) // 6 pt of air to the right, before the name
        // `ThemeColor` is Sendable; the drawing handler may run off the main actor and makes its own NSColors.
        let background = theme.color(.background)
        let text = theme.color(.text)
        let accent = theme.color(.accent)
        let separator = theme.color(.separator)
        let image = NSImage(size: size, flipped: false) { rect in
            let swatch = NSRect(x: 0, y: 0, width: 34, height: rect.height)
            let body = NSBezierPath(roundedRect: swatch.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            NSColor(background).setFill()
            body.fill()
            NSColor(separator).setStroke()
            body.lineWidth = 1
            body.stroke()
            NSColor(text).setFill()
            NSBezierPath(ovalIn: NSRect(x: 7, y: 4.5, width: 7, height: 7)).fill()
            NSColor(accent).setFill()
            NSBezierPath(ovalIn: NSRect(x: 19, y: 4.5, width: 7, height: 7)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// Settings > Appearance: the mode and the light and dark theme. Writes `appearanceMode`, `lightTheme` and
/// `darkTheme`; `AppearanceController` resolves them and updates the app and every editor.
struct AppearanceSettingsPane: View {
    let settings: SettingsModel
    let appearance: AppearanceController

    var body: some View {
        let snapshot = settings.snapshot
        let resolved = appearance.resolved
        let activeSlot = resolved.theme.appearance
        let chosen = activeSlot == .light ? snapshot.lightTheme : snapshot.darkTheme
        let override = ThemePicker.contrastOverride(
            increaseContrast: resolved.increaseContrast, resolvedId: resolved.theme.id, chosenId: chosen)
        Form {
            Section {
                Picker("Appearance", selection: settings.binding(.appearanceMode, \.appearanceMode)) {
                    Text("Match System").tag(AppearanceMode.system)
                    Text("Light").tag(AppearanceMode.light)
                    Text("Dark").tag(AppearanceMode.dark)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Appearance")
            } footer: {
                if let override {
                    Label(
                        "Increase Contrast is on in System Settings, so the \(activeSlot.rawValue) theme shows as \(override.name).",
                        systemImage: "circle.lefthalf.filled"
                    )
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            themeSection(
                "Light theme", appearance: .light, stored: snapshot.lightTheme,
                binding: settings.binding(.lightTheme, \.lightTheme))
            themeSection(
                "Dark theme", appearance: .dark, stored: snapshot.darkTheme,
                binding: settings.binding(.darkTheme, \.darkTheme))
        }
        .formStyle(.grouped)
    }

    private func themeSection(
        _ title: String, appearance: ThemeAppearance, stored: String, binding: Binding<String>
    ) -> some View {
        let selected = ThemePicker.selection(stored: stored, appearance: appearance)
        let theme = ThemeCatalog.theme(id: selected)
        return Section {
            Picker(
                title,
                selection: Binding(get: { selected }, set: { binding.wrappedValue = $0 })
            ) {
                ForEach(ThemePicker.options(appearance)) { option in
                    Label {
                        Text(option.name)
                    } icon: {
                        Image(nsImage: ThemeSwatch.image(for: option))
                    }
                    .tag(option.id)
                    .accessibilityLabel(option.name)
                }
            }
            .accessibilityLabel(title)
        } footer: {
            if let theme {
                Text(ThemePicker.credit(for: theme))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
