// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

@Suite struct TypographySettingsTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private struct Fixture: Decodable {
        let fontSize, lineHeight, lineWidth, paragraphSpacing, paragraphIndent: Double
    }

    @Test func testDefaultsMatchTheSharedFixture() throws {
        let url = Self.repoRoot.appendingPathComponent("Fixtures/themes/typography-defaults.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let d = TypographySettings.default
        #expect(d.fontSize == fixture.fontSize)
        #expect(d.lineHeight == fixture.lineHeight)
        #expect(d.lineWidth == fixture.lineWidth)
        #expect(d.paragraphSpacing == fixture.paragraphSpacing)
        #expect(d.paragraphIndent == fixture.paragraphIndent)
        #expect([d.fontText, d.fontHeading, d.fontCode] == ["", "", ""])
    }

    @Test func testOnlyChangedFieldsAreSent() {
        #expect(TypographySettings.default.editorTypography(installedFamilies: []) == EditorTypography())
        var t = TypographySettings.default
        t.fontSize = 18
        t.paragraphIndent = 1.5
        #expect(t.editorTypography(installedFamilies: []) == EditorTypography(fontSize: 18, paragraphIndent: 1.5))
    }

    @Test func testMissingFamilyIsNotSent() {
        var t = TypographySettings.default
        t.fontText = "Gone Sans"
        #expect(t.editorTypography(installedFamilies: ["Georgia"]).fontText == nil)
        t.fontText = "Georgia"
        t.fontCode = "Menlo"
        let sent = t.editorTypography(installedFamilies: ["Georgia"])
        #expect(sent.fontText == "Georgia")
        #expect(sent.fontCode == nil)
        t.fontHeading = ""
        #expect(t.editorTypography(installedFamilies: [""]).fontHeading == nil, "an empty family is the default font")
    }

    @Test func testClampedToProtocolRanges() {
        let low = TypographySettings(
            fontSize: 1, lineHeight: 0.5, lineWidth: 10, paragraphSpacing: -1, paragraphIndent: -2
        ).clamped()
        #expect((low.fontSize, low.lineHeight, low.lineWidth, low.paragraphSpacing, low.paragraphIndent) == (8, 1, 320, 0, 0))
        let high = TypographySettings(
            fontSize: 200, lineHeight: 9, lineWidth: 9000, paragraphSpacing: 9, paragraphIndent: 9
        ).clamped()
        #expect((high.fontSize, high.lineHeight, high.lineWidth, high.paragraphSpacing, high.paragraphIndent) == (72, 3, 4000, 3, 4))
        #expect(TypographySettings(fontSize: .nan).clamped().fontSize == 16)
        // What the editor is sent is the clamped value.
        #expect(TypographySettings(fontSize: 200).editorTypography(installedFamilies: []).fontSize == 72)
        // A value that clamps to the default is not sent.
        #expect(TypographySettings(paragraphIndent: -3).editorTypography(installedFamilies: []) == EditorTypography())
    }

    @Test func testRoundTripAndMissingFields() throws {
        var t = TypographySettings.default
        t.fontHeading = "Avenir Next"
        t.lineWidth = 900
        let data = try JSONEncoder().encode(t)
        #expect(try JSONDecoder().decode(TypographySettings.self, from: data) == t)
        #expect(try JSONDecoder().decode(TypographySettings.self, from: Data("{}".utf8)) == .default)
    }
}
