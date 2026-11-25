// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import XCTest

/// Design review tour (1.1 A5/A6): drives the screens a reviewer looks at and pauses at each one so the host can take
/// a full simulator screenshot (`xcrun simctl io <udid> screenshot`). Opt-in: set TEST_RUNNER_THEONOTES_SHOT_DIR to a
/// folder; the test writes `<name>.ready` there and waits for the host to write `<name>.done`.
@MainActor final class ScreenshotTourUITests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("Only disposable simulator libraries are used.")
        #endif
        let path = ProcessInfo.processInfo.environment["THEONOTES_SHOT_DIR"] ?? ""
        try XCTSkipIf(path.isEmpty, "Set TEST_RUNNER_THEONOTES_SHOT_DIR to run the screenshot tour.")
        folder = URL(fileURLWithPath: path)
    }

    private func pause(_ name: String) {
        let ready = folder.appendingPathComponent(name + ".ready"), done = folder.appendingPathComponent(name + ".done")
        try? FileManager.default.removeItem(at: done)
        FileManager.default.createFile(atPath: ready.path, contents: Data())
        let deadline = Date().addingTimeInterval(60)
        while !FileManager.default.fileExists(atPath: done.path), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: done.path), "the host did not take \(name)")
    }

    private func noteText(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Note text")).firstMatch
    }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private func showList(_ app: XCUIApplication) {
        let select = app.buttons["select-notes"].firstMatch
        if select.exists && select.isHittable { return }
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(select.waitForExistence(timeout: 30))
    }

    private func showSidebar(_ app: XCUIApplication) {
        let options = app.buttons["Library Options"].firstMatch
        for _ in 0..<3 where !(options.exists && options.isHittable) {
            let toggle = app.buttons.matching(NSPredicate(format: "label IN %@", ["Show Sidebar", "Toggle sidebar"])).firstMatch
            if toggle.exists && toggle.isHittable { toggle.tap() } else { app.navigationBars.buttons.firstMatch.tap() }
            _ = options.waitForExistence(timeout: 5)
        }
    }

    private func closeMenu(_ app: XCUIApplication) {
        // Outside every menu: the left edge (the nav bar's middle opens the title menu).
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.45)).tap()
        Thread.sleep(forTimeInterval: 1.5)
    }

    private func selectionMenu(_ title: String, _ app: XCUIApplication) {
        app.buttons["select-notes"].firstMatch.tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30)); row.tap()
        // On iPad the first tap can go to keyboard focus handover only; tap once more if nothing was selected.
        let menu = app.buttons.matching(NSPredicate(format: "label == %@", "1 Selected")).firstMatch
        if !menu.waitForExistence(timeout: 5) { row.tap() }
        if !menu.waitForExistence(timeout: 10) {
            try? app.debugDescription.write(to: folder.appendingPathComponent("debug.txt"), atomically: true, encoding: .utf8)
            pause("debug-selection")
        }
        app.buttons.matching(NSPredicate(format: "label == %@", "1 Selected")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Select All"].firstMatch.waitForExistence(timeout: 30))
    }

    func testTour() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-library"]
        app.launch()
        XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 60))
        let count = isPad ? 18 : 12
        let newest = "Tour note 01"
        for index in 1...count {
            let label = String(format: "%02d", index)
            showList(app)
            app.buttons["new-note"].tap()
            let editor = noteText(app)
            XCTAssertTrue(editor.waitForExistence(timeout: 60))
            editor.tap(); editor.typeText("Tour note \(label)\nA short line for the preview. #t\(label) ")
        }
        app.buttons["toolbar-dismiss-keyboard"].firstMatch.tap()
        pause("editor-bar")
        // Make the current line a heading first, so the submenu shows its checkmark.
        app.descendants(matching: .any)["toolbar-format"].firstMatch.tap()
        app.buttons["Heading"].firstMatch.tap()
        app.buttons["Heading 2"].firstMatch.tap()
        app.descendants(matching: .any)["toolbar-format"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Heading"].firstMatch.waitForExistence(timeout: 30))
        pause("formatting-menu")
        app.buttons["Insert"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Date"].firstMatch.waitForExistence(timeout: 30))
        pause("formatting-insert-submenu")
        closeMenu(app)
        if !app.buttons["Heading"].firstMatch.exists { app.descendants(matching: .any)["toolbar-format"].firstMatch.tap() }
        app.buttons["Heading"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Heading 2"].firstMatch.waitForExistence(timeout: 30))
        pause("formatting-heading-submenu")
        closeMenu(app)
        app.descendants(matching: .any)["Note Actions"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Find in Note"].firstMatch.waitForExistence(timeout: 30))
        pause("note-actions")
        closeMenu(app)

        showList(app)
        // The note list, not the first collection view: on iPad that is the sidebar, which left the oldest note off screen.
        let notes = app.collectionViews.containing(NSPredicate(format: "label BEGINSWITH %@", "Tour note")).firstMatch
        let list = notes.exists ? notes : app.tables.firstMatch
        for _ in 0..<6 { list.swipeUp() }
        pause("note-list-last-row")

        selectionMenu(newest, app)
        pause("selection-notes")
        app.buttons["selection-archive"].tap()
        app.typeKey("9", modifierFlags: [.command, .option])
        XCTAssertTrue(app.navigationBars["Archive"].waitForExistence(timeout: 30))
        selectionMenu(newest, app)
        pause("selection-archive")
        app.buttons["selection-trash"].tap()
        app.typeKey("0", modifierFlags: [.command, .option])
        XCTAssertTrue(app.navigationBars["Trash"].waitForExistence(timeout: 30))
        selectionMenu(newest, app)
        pause("selection-trash")
        app.buttons["selection-restore"].tap()
        app.typeKey("1", modifierFlags: [.command, .option])

        showSidebar(app)
        let sidebar = app.collectionViews.firstMatch
        for _ in 0..<6 { sidebar.swipeUp() }
        pause("sidebar-last-row")
        app.buttons["Library Options"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Settings"].firstMatch.waitForExistence(timeout: 30))
        pause("library-options")
        app.buttons["Settings"].firstMatch.tap()
        let general = app.buttons["General"].firstMatch
        XCTAssertTrue(general.waitForExistence(timeout: 30)); general.tap()
        XCTAssertTrue(app.switches["Checked To-Dos at Bottom"].firstMatch.waitForExistence(timeout: 30))
        pause("settings-general")
        for _ in 0..<3 { app.swipeUp() }
        pause("settings-general-export")
    }
}
