// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import XCTest

/// Opt-in acceptance using real Japanese software-keyboard taps, never injected note text.
/// Use a dedicated disposable simulator: this configures Japanese–Romaji and leaves it enabled.
/// Set BAERCHEN_NATIVE_IME=1 in this test target's .xctestrun EnvironmentVariables dictionary.
@MainActor
final class JapaneseIMEUITests: NativeIMEUITestCase {
    private let romajiID = "ja_JP-Romaji@sw=QWERTY-Japanese;hw=Automatic"

    override func setUpWithError() throws {
        continueAfterFailure = false
        #if targetEnvironment(simulator)
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BAERCHEN_NATIVE_IME"] == "1",
                          "Set BAERCHEN_NATIVE_IME=1 only for a dedicated disposable simulator.")
        #else
        throw XCTSkip("Native Japanese keyboard configuration is restricted to disposable simulators.")
        #endif
    }

    func testJapaneseCompositionCancellationAndPersistence() throws {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        try enableRomaji(in: settings)

        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-library"]
        app.launch()
        try require(app.buttons["new-note"], in: app, named: "New Note", timeout: 60).tap()
        let editor = noteText(in: app)
        try require(editor, in: app, named: "Note text", timeout: 60).tap()
        assertValue("", in: editor)
        try require(app.buttons["Next keyboard"], in: app, named: "native globe key").press(forDuration: 1)
        try require(app.cells["日本語ローマ字"], in: app, named: "Japanese–Romaji keyboard menu entry").tap()
        capture("Japanese software keyboard", in: app)

        for cycle in 1...5 {
            try tapLetter("k", in: app)
            try tapLetter("a", in: app)
            assertValue("か", in: editor)
            capture("Cancellation \(cycle) before delete", in: app)
            try tapDelete(in: app)
            assertValue("", in: editor)
            capture("Cancellation \(cycle) after delete", in: app)
        }

        for letter in ["n", "i", "h", "o", "n"] { try tapLetter(letter, in: app) }
        // The actual native Romaji keyboard exposes this unfinished preedit for these taps.
        assertValue("にほn", in: editor)
        let candidate = try require(app.cells["日本"], in: app, named: "native 日本 candidate")
        capture("Native 日本 candidate before commit", in: app)
        candidate.tap()
        assertValue("日本", in: editor)
        capture("Committed 日本", in: app)

        try tapLetter("k", in: app)
        try tapLetter("a", in: app)
        assertValue("日本か", in: editor)
        capture("Committed prefix before marked-text delete", in: app)
        try tapDelete(in: app)
        assertValue("日本", in: editor)
        capture("Committed prefix after marked-text delete", in: app)

        try require(app.buttons["Dismiss Keyboard"].firstMatch, in: app, named: "Dismiss Keyboard").tap()
        XCUIDevice.shared.press(.home)
        app.terminate()
        app.launchArguments = ["--ui-testing"] // Preserve the fixture on relaunch.
        app.launch()
        let reopened = noteText(in: app)
        _ = try require(reopened, in: app, named: "reopened Note text", timeout: 60)
        assertValue("日本", in: reopened)
        capture("Persisted exact 日本 after relaunch", in: app)
    }

    private func enableRomaji(in settings: XCUIApplication) throws {
        try openInstalledKeyboards(in: settings)
        // Do not reselect an already-enabled layout: its selection UI can toggle it off.
        if !settings.cells[romajiID].exists {
            try searchAvailableKeyboards("Japanese", in: settings)
            try require(settings.cells["ja_JP"], in: settings, named: "Japanese language").tap()
            try require(settings.cells[romajiID], in: settings, named: "Romaji layout").tap()
            try require(settings.buttons["Done"].firstMatch, in: settings, named: "confirm Romaji layout").tap()
        }
        _ = try require(settings.cells[romajiID], in: settings, named: "installed Japanese–Romaji")
        capture("Installed Japanese–Romaji on disposable simulator", in: settings)
    }

}
