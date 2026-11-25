// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import CoreText
import Foundation
import SwiftUI
import Testing
@testable import TheoNotes

/// M7 Task 8: the Appearance and Typography panes.
@MainActor
@Suite struct SettingsAppearanceTests {
    let environment: AppEnvironment
    let model: SettingsModel

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TheoNotesMacTests-\(UUID().uuidString)")
        environment = try AppEnvironment(paths: AppPaths(root: root))
        model = SettingsModel(database: environment.database)
    }

    @Test func typographyFieldRangesMatchTheProtocol() {
        let bounds: [TypographyField: ClosedRange<Double>] = [
            .fontSize: TypographySettings.fontSizeRange,
            .lineHeight: TypographySettings.lineHeightRange,
            .lineWidth: TypographySettings.lineWidthRange,
            .paragraphSpacing: TypographySettings.paragraphSpacingRange,
            .paragraphIndent: TypographySettings.paragraphIndentRange,
        ]
        for field in TypographyField.allCases {
            let protocolRange = bounds[field]!
            #expect(protocolRange.contains(field.range.lowerBound), "\(field.title) lower bound")
            #expect(protocolRange.contains(field.range.upperBound), "\(field.title) upper bound")
            #expect(field.step > 0 && field.step <= field.range.upperBound - field.range.lowerBound)
            // The default sits on the slider.
            #expect(field.range.contains(TypographySettings.default[keyPath: field.keyPath]), "\(field.title) default")
        }
    }

    @Test func typographyFieldRangesAndLabelsAreTheBriefsValues() {
        #expect(TypographyField.fontSize.range == 10...40 && TypographyField.fontSize.step == 1)
        #expect(TypographyField.lineHeight.range == 1.0...2.5 && TypographyField.lineHeight.step == 0.1)
        #expect(TypographyField.lineWidth.range == 400...1600 && TypographyField.lineWidth.step == 20)
        #expect(TypographyField.paragraphSpacing.range == 0...2 && TypographyField.paragraphSpacing.step == 0.1)
        #expect(TypographyField.paragraphIndent.range == 0...4 && TypographyField.paragraphIndent.step == 0.5)
        #expect(TypographyField.allCases.map(\.title) == [
            "Font size", "Line height", "Line width", "Paragraph spacing", "Paragraph indentation",
        ])
        let d = TypographySettings.default
        #expect(TypographyField.fontSize.format(d.fontSize) == "16 pt")
        #expect(TypographyField.lineHeight.format(d.lineHeight) == "1.6")
        #expect(TypographyField.lineWidth.format(d.lineWidth) == "720 pt")
        #expect(TypographyField.paragraphSpacing.format(d.paragraphSpacing) == "0.4 em")
        #expect(TypographyField.paragraphIndent.format(d.paragraphIndent) == "0 em")
        // 0.1 steps accumulate float noise; the label must not show it.
        #expect(TypographyField.paragraphSpacing.format(0.1 + 0.2) == "0.3 em")
        #expect(TypographyField.paragraphIndent.format(1.5) == "1.5 em")
    }

    @Test func codeFamiliesListFixedPitchFirst() throws {
        let code = FontFamilies.code()
        let menlo = try #require(code.firstIndex(of: "Menlo"))
        let helvetica = try #require(code.firstIndex(of: "Helvetica"))
        #expect(menlo < helvetica)
        // Same families, only reordered.
        #expect(Set(code) == Set(FontFamilies.text()))
        #expect(code.count == FontFamilies.text().count)
    }

    @Test func fontPickersOfferOnlyNamesTheEditorAccepts() {
        let usable = FontFamilies.usable(["Zeta", ".SF NS", "Alpha", "Bad;Name", "Bad{Name}", "Quo\"te", "", String(repeating: "x", count: 101), "Line\nBreak", "alpha 2"])
        #expect(usable == ["Alpha", "alpha 2", "Zeta"])
        #expect(FontFamilies.text().allSatisfy(EditorTypography.isValidFontFamily))
    }

    @Test func aStoredFontThatIsNotInstalledShowsAsMissing() {
        let options = FontOptions.options(families: ["Georgia", "Menlo"], stored: "Vanished Sans")
        #expect(options.map(\.label) == ["Default", "Default (Vanished Sans missing)", "Georgia", "Menlo"])
        #expect(options.map(\.id) == ["", "Vanished Sans", "Georgia", "Menlo"])
        #expect(options.map(\.isMissing) == [false, true, false, false])
        // An installed or empty choice adds no entry.
        #expect(FontOptions.options(families: ["Georgia"], stored: "Georgia").map(\.label) == ["Default", "Georgia"])
        #expect(FontOptions.options(families: ["Georgia"], stored: "").map(\.label) == ["Default", "Georgia"])
    }

    @Test func aStoredInstalledFontShowsNoWarning() throws {
        let installed = try #require(FontFamilies.text().first { $0 == "Georgia" } ?? FontFamilies.text().first)
        let options = FontOptions.options(families: FontFamilies.text(), stored: installed)
        #expect(options.allSatisfy { !$0.isMissing })
        #expect(options.map(\.label).contains(installed))
        // The lists are read once and cached: the first render already has them.
        #expect(FontFamilies.lists() == FontFamilies.lists())
        #expect(!FontFamilies.lists().text.isEmpty)
    }

    @Test func sliderValuesSnapToTheirStepWithoutFloatNoise() {
        #expect(TypographyField.paragraphSpacing.snapped(0.1 + 0.2) == 0.3)
        #expect(TypographyField.paragraphSpacing.snapped(0.4000000001) == TypographySettings.default.paragraphSpacing)
        #expect(TypographyField.lineHeight.snapped(1.6000000000000001) == TypographySettings.default.lineHeight)
        #expect(TypographyField.lineHeight.snapped(1.7000000000000002) == 1.7)
        #expect(TypographyField.fontSize.snapped(16.4) == 16)
        #expect(TypographyField.lineWidth.snapped(729) == 720)
        #expect(TypographyField.paragraphIndent.snapped(1.3) == 1.5)
        for field in TypographyField.allCases {
            #expect(field.snapped(-1000) == field.range.lowerBound)
            #expect(field.snapped(1e9) == field.range.upperBound)
            #expect(field.snapped(.nan) == field.range.lowerBound)
        }
    }

    @Test func aDragBurstWritesAtMostTwiceAndThenTheFinalValue() async throws {
        let coalescer = WriteCoalescer(interval: .milliseconds(80))
        var written: [Double] = []
        for step in 0..<200 { coalescer.update(Double(step)) { written.append($0) } }
        // The first value goes out at once, the rest wait.
        #expect(written == [0])
        coalescer.finish(199) { written.append($0) }
        #expect(written == [0, 199])
        // Nothing stays pending after the end of the drag.
        try await Task.sleep(for: .milliseconds(200))
        #expect(written == [0, 199])
    }

    @Test func aPausedDragWritesItsLastValueWithoutWaitingForTheEnd() async throws {
        let coalescer = WriteCoalescer(interval: .milliseconds(60))
        var written: [Double] = []
        for step in 0..<50 { coalescer.update(Double(step)) { written.append($0) } }
        try await waitUntil("the trailing write") { written.last == 49 }
        #expect(written == [0, 49])
        // A later step after the pause is written at once again.
        try await Task.sleep(for: .milliseconds(100))
        coalescer.update(60) { written.append($0) }
        #expect(written == [0, 49, 60])
    }

    @Test func theFontListFollowsTheSameEventsAsTheController() async throws {
        var calls = 0
        let observer = InstalledFontsObserver { calls += 1 }
        withExtendedLifetime(observer) {}
        NotificationCenter.default.post(name: Notification.Name("NSFontSetChangedNotification"), object: nil)
        NotificationCenter.default.post(name: Notification.Name(kCTFontManagerRegisteredFontsChangedNotification as String), object: nil)
        try await waitUntil("both font events reach the observer") { calls >= 2 }
        #expect(InstalledFontsObserver.events.count == 3)
        #expect(InstalledFontsObserver.events.contains { $0.center === DistributedNotificationCenter.default() })
    }

    @Test func darkPickerListsOnlyDarkThemes() {
        let dark = ThemePicker.options(.dark)
        #expect(!dark.isEmpty)
        #expect(dark.allSatisfy { $0.appearance == .dark })
        #expect(dark.map(\.order) == dark.map(\.order).sorted())
        let light = ThemePicker.options(.light)
        #expect(light.allSatisfy { $0.appearance == .light })
        // Every bundled theme is in one of the two pickers.
        #expect(Set(dark.map(\.id)).union(light.map(\.id)) == Set(ThemeCatalog.all().map(\.id)))
        #expect(light.count + dark.count == 18)
        #expect(light.map(\.id).first == ThemeCatalog.defaultLightId)
        #expect(dark.map(\.id).first == ThemeCatalog.defaultDarkId)
    }

    @Test func aPickerFallsBackToTheSlotDefaultForAnUnknownOrForeignTheme() {
        #expect(ThemePicker.selection(stored: "nord", appearance: .dark) == "nord")
        #expect(ThemePicker.selection(stored: "nord", appearance: .light) == ThemeCatalog.defaultLightId)
        #expect(ThemePicker.selection(stored: "no-such-theme", appearance: .dark) == ThemeCatalog.defaultDarkId)
    }

    @Test func creditLineNamesThePaletteOrTheOwnTheme() throws {
        let nord = try #require(ThemeCatalog.theme(id: "nord"))
        #expect(ThemePicker.credit(for: nord) == "Palette: Nord · MIT · Copyright (c) 2016-present Sven Greb")
        let red = try #require(ThemeCatalog.theme(id: "baerchen-red"))
        #expect(ThemePicker.credit(for: red) == "Theo Notes theme")
        for theme in ThemeCatalog.all() {
            #expect(!ThemePicker.credit(for: theme).isEmpty)
        }
    }

    @Test func theIncreaseContrastNoteAppearsOnlyWhenTheChoiceWasSwapped() throws {
        let swapped = ThemePicker.contrastOverride(increaseContrast: true, resolvedId: "high-contrast", chosenId: "nord-light")
        #expect(swapped?.id == "high-contrast")
        #expect(ThemePicker.contrastOverride(increaseContrast: true, resolvedId: "oled-black", chosenId: "nord")?.id == "oled-black")
        // Off, or the choice stands (a high contrast theme chosen on purpose).
        #expect(ThemePicker.contrastOverride(increaseContrast: false, resolvedId: "high-contrast", chosenId: "nord-light") == nil)
        #expect(ThemePicker.contrastOverride(increaseContrast: true, resolvedId: "high-contrast", chosenId: "high-contrast") == nil)
        #expect(ThemePicker.contrastOverride(increaseContrast: true, resolvedId: "nord", chosenId: "nord") == nil)
        // A stale stored id the resolver replaced by the default is not the contrast setting's doing.
        #expect(ThemePicker.contrastOverride(increaseContrast: true, resolvedId: "baerchen-red", chosenId: "no-such-theme") == nil)
    }

    @Test func swatchesUseTheThemeColours() throws {
        let theme = try #require(ThemeCatalog.theme(id: "dracula"))
        let image = ThemeSwatch.image(for: theme)
        #expect(!image.isTemplate)
        let rep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 80, height: 32))
        NSGraphicsContext.restoreGraphicsState()
        // The page colour fills the swatch away from its dots.
        let page = try #require(rep.colorAt(x: 33, y: 16)?.usingColorSpace(.sRGB))
        let expected = theme.color(.background)
        #expect(abs(Double(page.redComponent) - expected.red) < 0.02)
        #expect(abs(Double(page.greenComponent) - expected.green) < 0.02)
        #expect(abs(Double(page.blueComponent) - expected.blue) < 0.02)
    }

    @Test func settingsTabsRenderOffscreen() async throws {
        let all = SettingsTab.order(syncSetup: true, icloud: true)
        #expect(all.map(\.title) == ["General", "Capture", "Appearance", "Typography", "Automation", "Sync", "iCloud", "Privacy", "Advanced"])
        #expect(Set(all) == Set(SettingsTab.allCases))
        #expect(SettingsTab.order == SettingsTab.order(syncSetup: true, icloud: ReleaseFeatures.cloudSyncAvailable()), "the dev build keeps Sync; iCloud follows its own flag")
        let captureDefaults = UserDefaults(suiteName: "SettingsAppearanceTests.\(UUID().uuidString)")!
        let captureModel = CaptureSettingsModel(
            settings: CaptureSettings(defaults: captureDefaults, identity: .production), hotKey: { nil }, loginItem: InertLoginItem())
        // The iCloud pane is built only in a build that has the flag; CloudSyncViewsTests renders it with the flag on.
        for tab in all where tab != .icloud || environment.cloudSyncAvailable {
            let hosting = NSHostingView(rootView: SettingsPane(tab: tab, settings: model, environment: environment, capture: captureModel, home: FileManager.default.temporaryDirectory.appendingPathComponent("TheoNotesSettingsHome-\(UUID().uuidString)")).frame(width: 500))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            hosting.layoutSubtreeIfNeeded()
            #expect(hosting.fittingSize.width > 0 && hosting.fittingSize.height > 0, "\(tab.title) renders")
            // Optional look at the panes: TEST_RUNNER_BAERCHEN_SETTINGS_PNG_DIR=/some/dir xcodebuild … test
            if let dir = ProcessInfo.processInfo.environment["BAERCHEN_SETTINGS_PNG_DIR"] {
                window.appearance = NSAppearance(named: .aqua)
                hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
                hosting.layoutSubtreeIfNeeded()
                if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(tab.rawValue).png"))
                }
            }
            window.contentView = nil
            window.close()
        }
        // The window itself, with the tab control.
        let hosting = NSHostingView(rootView: SettingsView(settings: model, environment: environment))
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.width > 0 && hosting.fittingSize.height > 0)
    }

    @Test func restoreDefaultsResetsTypography() throws {
        let custom = TypographySettings(
            fontText: "Georgia", fontHeading: "Menlo", fontCode: "Menlo", fontSize: 22, lineHeight: 2, lineWidth: 900,
            paragraphSpacing: 1, paragraphIndent: 1.5)
        model.set(.typography, custom)
        #expect(model.snapshot.typography == custom)
        model.restoreTypographyDefaults()
        #expect(model.snapshot.typography == .default)
        // Stored, not only shown.
        #expect(try TheoNotesCore.Settings(db: environment.database).snapshot().typography == .default)
    }

    @Test func aSliderValueIsStoredAndReachesTheResolvedLook() async throws {
        var typography = model.snapshot.typography
        typography[keyPath: TypographyField.fontSize.keyPath] = 22
        model.set(.typography, typography)
        try await waitUntil("the editor look follows the font size") { environment.appearance.editorLook.typography.fontSize == 22 }
        model.set(.appearanceMode, .dark)
        try await waitUntil("dark mode resolves") { environment.appearance.editorLook.appearance == .dark }
        model.set(.darkTheme, "nord")
        try await waitUntil("the dark theme resolves") { environment.appearance.resolved.theme.id == "nord" }
    }
}
