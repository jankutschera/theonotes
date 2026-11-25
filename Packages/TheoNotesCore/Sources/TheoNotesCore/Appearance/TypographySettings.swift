// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// The typography the user chose (Settings > Appearance), stored as one JSON value. A family of ""
/// is the editor's default font. `Fixtures/themes/typography-defaults.json` holds the numbers
/// below for the editor's tests; `TypographySettingsTests` pins both to each other.
public struct TypographySettings: Codable, Equatable, Sendable {
    public var fontText: String
    public var fontHeading: String
    public var fontCode: String
    public var fontSize: Double
    public var lineHeight: Double
    public var lineWidth: Double
    public var paragraphSpacing: Double
    public var paragraphIndent: Double

    public static let `default` = TypographySettings()

    /// The ranges the bridge protocol accepts (`EditorTypography`, `protocol.ts`).
    public static let fontSizeRange: ClosedRange<Double> = 8...72
    public static let lineHeightRange: ClosedRange<Double> = 1...3
    public static let lineWidthRange: ClosedRange<Double> = 320...4000
    public static let paragraphSpacingRange: ClosedRange<Double> = 0...3
    public static let paragraphIndentRange: ClosedRange<Double> = 0...4

    public init(
        fontText: String = "", fontHeading: String = "", fontCode: String = "", fontSize: Double = 16,
        lineHeight: Double = 1.6, lineWidth: Double = 720, paragraphSpacing: Double = 0.4, paragraphIndent: Double = 0
    ) {
        self.fontText = fontText
        self.fontHeading = fontHeading
        self.fontCode = fontCode
        self.fontSize = fontSize
        self.lineHeight = lineHeight
        self.lineWidth = lineWidth
        self.paragraphSpacing = paragraphSpacing
        self.paragraphIndent = paragraphIndent
    }

    /// A stored value missing a field (an older build, a hand-edited row) keeps the default for it.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TypographySettings.default
        fontText = try c.decodeIfPresent(String.self, forKey: .fontText) ?? d.fontText
        fontHeading = try c.decodeIfPresent(String.self, forKey: .fontHeading) ?? d.fontHeading
        fontCode = try c.decodeIfPresent(String.self, forKey: .fontCode) ?? d.fontCode
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? d.fontSize
        lineHeight = try c.decodeIfPresent(Double.self, forKey: .lineHeight) ?? d.lineHeight
        lineWidth = try c.decodeIfPresent(Double.self, forKey: .lineWidth) ?? d.lineWidth
        paragraphSpacing = try c.decodeIfPresent(Double.self, forKey: .paragraphSpacing) ?? d.paragraphSpacing
        paragraphIndent = try c.decodeIfPresent(Double.self, forKey: .paragraphIndent) ?? d.paragraphIndent
    }

    /// Every number inside the protocol's range (a value that is not a number becomes the default).
    public func clamped() -> TypographySettings {
        func fit(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            value.isNaN ? fallback : min(max(value, range.lowerBound), range.upperBound)
        }
        let d = TypographySettings.default
        var result = self
        result.fontSize = fit(fontSize, Self.fontSizeRange, d.fontSize)
        result.lineHeight = fit(lineHeight, Self.lineHeightRange, d.lineHeight)
        result.lineWidth = fit(lineWidth, Self.lineWidthRange, d.lineWidth)
        result.paragraphSpacing = fit(paragraphSpacing, Self.paragraphSpacingRange, d.paragraphSpacing)
        result.paragraphIndent = fit(paragraphIndent, Self.paragraphIndentRange, d.paragraphIndent)
        return result
    }

    /// What the editor is sent: only the fields that differ from the default (clamped first). A family goes
    /// out only when it is not empty and installed; one that is missing (the font was removed) leaves the
    /// editor's default font instead of an unresolvable name.
    public func editorTypography(installedFamilies: Set<String>) -> EditorTypography {
        let value = clamped()
        let d = TypographySettings.default
        func family(_ name: String) -> String? { !name.isEmpty && installedFamilies.contains(name) ? name : nil }
        return EditorTypography(
            fontSize: value.fontSize == d.fontSize ? nil : value.fontSize,
            lineHeight: value.lineHeight == d.lineHeight ? nil : value.lineHeight,
            lineWidth: value.lineWidth == d.lineWidth ? nil : value.lineWidth,
            paragraphSpacing: value.paragraphSpacing == d.paragraphSpacing ? nil : value.paragraphSpacing,
            paragraphIndent: value.paragraphIndent == d.paragraphIndent ? nil : value.paragraphIndent,
            fontText: family(value.fontText), fontHeading: family(value.fontHeading), fontCode: family(value.fontCode))
    }

    /// Whether any font family is chosen (the host reads the installed families only then).
    public var choosesFonts: Bool { !fontText.isEmpty || !fontHeading.isEmpty || !fontCode.isEmpty }
}
