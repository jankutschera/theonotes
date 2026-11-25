// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import XCTest

/// Real-key acceptance for Simplified Chinese Pinyin QWERTY only.
/// Opt in using BAERCHEN_NATIVE_CHINESE_IME=1 in the test target's .xctestrun
/// EnvironmentVariables. Use a dedicated disposable simulator; the keyboard stays enabled.
@MainActor
final class ChineseIMEUITests: NativeIMEUITestCase {
    private let pinyinID = "zh_Hans-Pinyin@sw=Pinyin-Simplified;hw=Automatic"

    override func setUpWithError() throws {
        continueAfterFailure = false
        #if targetEnvironment(simulator)
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BAERCHEN_NATIVE_CHINESE_IME"] == "1",
                          "Set BAERCHEN_NATIVE_CHINESE_IME=1 only for a dedicated disposable simulator.")
        #else
        throw XCTSkip("Native Chinese keyboard configuration is restricted to disposable simulators.")
        #endif
    }

    func testSimplifiedPinyinCancellationAndPersistence() throws {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        try enablePinyin(in: settings)
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-library"]
        app.launch()
        try require(app.buttons["new-note"], in: app, named: "New Note", timeout: 60).tap()
        let editor = noteText(in: app)
        try require(editor, in: app, named: "Note text", timeout: 60).tap()
        assertValue("", in: editor)
        try require(app.buttons["Next keyboard"], in: app, named: "native globe key").press(forDuration: 1)
        try require(app.cells["简体拼音"], in: app, named: "Simplified Pinyin keyboard menu entry").tap()
        capture("Simplified Pinyin QWERTY software keyboard", in: app)

        for cycle in 1...5 {
            try tapLetter("n", in: app)
            try tapLetter("i", in: app)
            assertValue("ni", in: editor)
            capture("Pinyin cancellation \(cycle) before deletion", in: app)
            try tapDelete(in: app)
            assertValue("n", in: editor)
            capture("Pinyin cancellation \(cycle) partial deletion", in: app)
            try tapDelete(in: app)
            assertValue("", in: editor)
            capture("Pinyin cancellation \(cycle) fully deleted", in: app)
        }

        for key in ["n", "i", "h", "a", "o"] { try tapLetter(key, in: app) }
        // The actual iOS Pinyin preedit separates syllables with U+2006, not an ASCII space.
        assertValue("ni\u{2006}hao", in: editor)
        let candidate = try require(app.cells["你好"], in: app, named: "native 你好 candidate")
        capture("Native 你好 candidate before commit", in: app)
        candidate.tap()
        assertValue("你好", in: editor)
        capture("Committed 你好", in: app)

        try tapLetter("n", in: app)
        try tapLetter("i", in: app)
        assertValue("你好ni", in: editor)
        capture("Pinyin committed prefix before marked-text deletion", in: app)
        try tapDelete(in: app)
        assertValue("你好n", in: editor)
        capture("Pinyin committed prefix with partial preedit deletion", in: app)
        try tapDelete(in: app)
        assertValue("你好", in: editor)
        capture("Pinyin committed prefix after complete preedit deletion", in: app)

        try require(app.buttons["Dismiss Keyboard"].firstMatch, in: app, named: "Dismiss Keyboard").tap()
        XCUIDevice.shared.press(.home)
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        let reopened = noteText(in: app)
        _ = try require(reopened, in: app, named: "reopened Note text", timeout: 60)
        assertValue("你好", in: reopened)
        capture("Persisted exact 你好 after relaunch", in: app)
    }

    private func enablePinyin(in settings: XCUIApplication) throws {
        try openInstalledKeyboards(in: settings)
        // Preserve an already-enabled exact layout; selecting it again can toggle it off.
        if !settings.cells[pinyinID].exists {
            try searchAvailableKeyboards("Chinese", in: settings)
            try require(settings.cells["zh_Hans"], in: settings, named: "Chinese, Simplified language").tap()
            try require(settings.cells[pinyinID], in: settings, named: "Pinyin QWERTY layout").tap()
            try require(settings.buttons["Done"].firstMatch, in: settings, named: "confirm Pinyin QWERTY").tap()
        }
        _ = try require(settings.cells[pinyinID], in: settings, named: "installed Simplified Pinyin QWERTY")
        capture("Installed Simplified Pinyin QWERTY on disposable simulator", in: settings)
    }
}
