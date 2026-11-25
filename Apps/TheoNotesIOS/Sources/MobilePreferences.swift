// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import SwiftUI

struct MobilePreferences: Codable, Equatable, Sendable {
    var appearance = "system"
    var palette = "berry"
    var lightThemeID = ThemeCatalog.defaultLightId
    var darkThemeID = ThemeCatalog.defaultDarkId
    var textFont = "system"
    var headingFont = "text"
    var codeFont = "system"
    var fontSize = 17.0
    var lineHeight = 1.65
    var lineWidth = 720.0
    var paragraphSpacing = 0.5
    var paragraphIndent = 0.0
    var useDynamicType = true
    var previewLines = 2
    var showThumbnails = true
    var startContent = "empty"
    var keepTagsOnExport = true
    var relativeWikiLinksOnExport = true
    var exportIncludeAttachments = true
    var exportEmbedImages = false
    var recentTemplateIDs: [String] = []

    init() {}
    private enum CodingKeys: String, CodingKey {
        case appearance, palette, lightThemeID, darkThemeID, textFont, headingFont, codeFont, fontSize, lineHeight, lineWidth, paragraphSpacing, paragraphIndent, useDynamicType, previewLines, showThumbnails, startContent, keepTagsOnExport, recentTemplateIDs, relativeWikiLinksOnExport, exportIncludeAttachments, exportEmbedImages
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? "system"
        palette = try c.decodeIfPresent(String.self, forKey: .palette) ?? "berry"
        lightThemeID = try c.decodeIfPresent(String.self, forKey: .lightThemeID) ?? ThemeCatalog.defaultLightId
        darkThemeID = try c.decodeIfPresent(String.self, forKey: .darkThemeID) ?? ThemeCatalog.defaultDarkId
        textFont = try c.decodeIfPresent(String.self, forKey: .textFont) ?? "system"
        headingFont = try c.decodeIfPresent(String.self, forKey: .headingFont) ?? "text"
        codeFont = try c.decodeIfPresent(String.self, forKey: .codeFont) ?? "system"
        fontSize = min(30, max(13, try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 17))
        lineHeight = min(2.2, max(1.2, try c.decodeIfPresent(Double.self, forKey: .lineHeight) ?? 1.65))
        lineWidth = min(1000, max(400, try c.decodeIfPresent(Double.self, forKey: .lineWidth) ?? 720))
        paragraphSpacing = min(2, max(0, try c.decodeIfPresent(Double.self, forKey: .paragraphSpacing) ?? 0.5))
        paragraphIndent = min(4, max(0, try c.decodeIfPresent(Double.self, forKey: .paragraphIndent) ?? 0))
        useDynamicType = try c.decodeIfPresent(Bool.self, forKey: .useDynamicType) ?? true
        previewLines = min(3, max(0, try c.decodeIfPresent(Int.self, forKey: .previewLines) ?? 2))
        showThumbnails = try c.decodeIfPresent(Bool.self, forKey: .showThumbnails) ?? true
        startContent = try c.decodeIfPresent(String.self, forKey: .startContent) ?? "empty"
        keepTagsOnExport = try c.decodeIfPresent(Bool.self, forKey: .keepTagsOnExport) ?? true
        relativeWikiLinksOnExport = try c.decodeIfPresent(Bool.self, forKey: .relativeWikiLinksOnExport) ?? true
        exportIncludeAttachments = try c.decodeIfPresent(Bool.self, forKey: .exportIncludeAttachments) ?? true
        exportEmbedImages = try c.decodeIfPresent(Bool.self, forKey: .exportEmbedImages) ?? false
        recentTemplateIDs = Array((try c.decodeIfPresent([String].self, forKey: .recentTemplateIDs) ?? []).prefix(5))
    }

    var colorScheme: ColorScheme? { appearance == "light" ? .light : appearance == "dark" ? .dark : nil }
    func theme(dark: Bool, increasedContrast: Bool = false) -> Theme {
        ThemeResolver.resolve(mode: AppearanceMode(rawValue: appearance) ?? .system, systemIsDark: dark,
            increaseContrast: increasedContrast, lightThemeId: lightThemeID, darkThemeId: darkThemeID)
    }
    var textFontCSS: String {
        switch textFont { case "georgia": "Georgia, serif"; case "palatino": "Palatino, serif"; case "menlo": "Menlo, monospace"; default: "-apple-system, system-ui, sans-serif" }
    }
    var textFontFamily: String? {
        switch textFont {
        case "system": nil
        case "georgia": "Georgia"
        case "palatino": "Palatino"
        case "menlo": "Menlo"
        default: EditorTypography.isValidFontFamily(textFont) ? textFont : nil
        }
    }
    /// Existing preferences keep headings matched to body text. An explicit System choice
    /// supplies its own family so the bridge does not fall back to a custom body font.
    var headingFontFamily: String? {
        switch headingFont {
        case "text": textFontFamily
        case "system": "-apple-system"
        case "georgia": "Georgia"
        case "palatino": "Palatino"
        case "menlo": "Menlo"
        default: EditorTypography.isValidFontFamily(headingFont) ? headingFont : textFontFamily
        }
    }
    var codeFontFamily: String? {
        switch codeFont {
        case "system": nil
        case "menlo": "Menlo"
        case "courier": "Courier"
        default: EditorTypography.isValidFontFamily(codeFont) ? codeFont : nil
        }
    }
    var codeFontCSS: String {
        switch codeFont { case "menlo": "Menlo, monospace"; case "courier": "Courier, monospace"; default: "ui-monospace, Menlo, monospace" }
    }
    var accent: Color {
        switch palette {
        case "forest": .green
        case "ocean": .blue
        case "graphite": .gray
        default: Color(red: 0.76, green: 0.20, blue: 0.28)
        }
    }
    var accentHex: String {
        switch palette { case "forest": "#32805c"; case "ocean": "#3078b8"; case "graphite": "#808080"; default: "#c23347" }
    }
}

extension ThemeColor {
    var mobileColor: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
}

struct MobileRestoration: Codable, Sendable {
    var scope: String
    var workspace: String?
    var noteID: String?
    init(scope: SidebarScope = .notes, workspace: String? = nil, noteID: String? = nil) {
        self.workspace = workspace; self.noteID = noteID
        self.scope = switch scope {
        case .notes: "notes"; case .inbox: "inbox"; case .type(let type): "type-" + type.rawValue; case .pinned: "pinned"; case .today: "today"; case .todo: "todo"
        case .untagged: "untagged"; case .locked: "locked"; case .archive: "archive"; case .trash: "trash"
        case .tag(let path): "tag:" + path
        }
    }
    var scopeValue: SidebarScope {
        if scope.hasPrefix("tag:") { return .tag(String(scope.dropFirst(4))) }
        return switch scope {
        case "inbox": .inbox; case "type-idea": .type(.idea); case "type-log": .type(.log); case "type-reference": .type(.reference)
        case "pinned": .pinned; case "today": .today; case "todo": .todo; case "untagged": .untagged
        case "locked": .locked; case "archive": .archive; case "trash": .trash; default: .notes
        }
    }
}

extension SettingKey where Value == MobilePreferences {
    static var mobilePreferences: Self { .init("mobile.preferences", default: MobilePreferences()) }
}
extension SettingKey where Value == MobileRestoration {
    static var mobileRestoration: Self { .init("mobile.restoration", default: MobileRestoration()) }
}

// Biometric convenience is local to this installation, never a synced preference.
extension SettingKey where Value == Bool {
    static var mobileBiometry: Self { .init("mobile.biometry", default: false) }
    static var mobileAppLock: Self { .init("mobile.appLock", default: false) }
}
