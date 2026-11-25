// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import XCTest

/// Actual local document picker acceptance on an explicitly opted-in disposable simulator.
@MainActor
final class LocalFilesZIPImportUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if targetEnvironment(simulator)
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BAERCHEN_LOCAL_FILES_ZIP"] == "1",
                          "Enable only on a disposable simulator with the ZIP fixture staged in Files.")
        #else
        throw XCTSkip("Local Files fixtures are restricted to disposable simulators.")
        #endif
    }

    func testZIPImportAndPickerCancellation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-library"]
        app.launch()
        XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 60))
        // Open the real library sidebar rather than calling the importer service.
        if !app.buttons["Library Options"].exists {
            app.navigationBars.buttons.firstMatch.tap()
        }
        try openImport(in: app)
        capture("ZIP picker before cancellation", app)
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 15))
        app.buttons["Cancel"].tap()
        capture("ZIP picker cancelled", app)
        XCTAssertTrue(app.buttons["Library Options"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.alerts.firstMatch.exists, "Picker cancellation must not report an import failure")

        try openImport(in: app)
        if app.buttons["Browse"].exists { app.buttons["Browse"].tap() }
        let local = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "On My iPhone")).firstMatch
        if !local.waitForExistence(timeout: 5), app.navigationBars.buttons["Browse"].exists {
            app.navigationBars.buttons["Browse"].tap()
        }
        XCTAssertTrue(local.waitForExistence(timeout: 15), app.debugDescription)
        local.tap()
        let zip = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Baerchen ZIP Acceptance")).firstMatch
        XCTAssertTrue(zip.waitForExistence(timeout: 15), app.debugDescription)
        zip.tap()
        capture("Local ZIP selected in system picker", app)
        if app.buttons["Open"].exists { app.buttons["Open"].tap() }
        // 1.1 (A14): the import options step sits between the picker and the import; defaults stay as they are.
        let importButton = app.buttons["Import"].firstMatch
        XCTAssertTrue(importButton.waitForExistence(timeout: 30), "the import options step must open after the picker")
        importButton.tap()
        let notes = app.descendants(matching: .any)["scope-Notes"].firstMatch
        XCTAssertTrue(notes.waitForExistence(timeout: 15), app.debugDescription)
        notes.tap()
        let imported = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Imported 1 notes")).firstMatch
        XCTAssertTrue(imported.waitForExistence(timeout: 30), app.debugDescription)
        capture("ZIP import completed", app)
        app.terminate()
    }

    private func openImport(in app: XCUIApplication) throws {
        XCTAssertTrue(app.buttons["Library Options"].waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["Library Options"].tap()
        XCTAssertTrue(app.buttons["Import Notes"].waitForExistence(timeout: 10))
        app.buttons["Import Notes"].tap()
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + " AX"; tree.lifetime = .keepAlways; add(tree)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
