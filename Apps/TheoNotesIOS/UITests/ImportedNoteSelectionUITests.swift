// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import XCTest

/// Opt-in selection probes, restricted to the disposable simulator's UI-test library.
@MainActor
final class ImportedNoteSelectionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if targetEnvironment(simulator)
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BAERCHEN_IMPORTED_NOTE_SELECTION"] == "1",
                          "Requires an owned disposable simulator; retained probes also require their named fixture.")
        #else
        throw XCTSkip("Selection diagnosis is restricted to an owned disposable simulator.")
        #endif
    }

    func testRetainedImportedRowOpensEditor() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        let rows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Foreign backup source"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 30))
        let row = try XCTUnwrap(rows.allElementsBoundByIndex.first(where: { $0.isHittable }),
                                "The retained imported note must have a hittable row.")
        let editor = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Note text")).firstMatch
        record(app, "Retained imported row before tap")
        XCTAssertFalse(editor.exists, "This minimized loop requires an initially unselected note.")
        row.tap()
        let opened = editor.waitForExistence(timeout: 10)
        record(app, opened ? "Editor appeared after imported row tap" : "Imported row tap left editor absent")
        XCTAssertTrue(opened, "A hittable imported note row was tapped but Note text did not appear within 10 seconds.")
        app.terminate()
    }

    func testRetainedImportedRowOpensAfterReselectingNotesScope() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        let sidebar = app.buttons.matching(NSPredicate(format: "label IN %@", ["Show Sidebar", "Sidebar"])).firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 30))
        sidebar.tap()
        let notes = app.descendants(matching: .any)["scope-Notes"].firstMatch
        XCTAssertTrue(notes.waitForExistence(timeout: 10))
        notes.tap()
        XCTAssertTrue(app.buttons["Show Sidebar"].firstMatch.waitForExistence(timeout: 10),
                      "Selecting a scope must dismiss an overlay sidebar before tapping a note.")
        let rows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Foreign backup source"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        let row = try XCTUnwrap(rows.allElementsBoundByIndex.first(where: { $0.isHittable }))
        let editor = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Note text")).firstMatch
        XCTAssertFalse(editor.exists, "Choosing Notes should clear the previous note selection.")
        record(app, "Retained row after Notes scope before tap")
        row.tap()
        let opened = editor.waitForExistence(timeout: 10)
        record(app, opened ? "Editor appeared after Notes scope and row tap" : "Notes scope then row tap left editor absent")
        XCTAssertTrue(opened, "Re-selecting Notes must not prevent opening an existing note.")
        app.terminate()
    }

    private func record(_ app: XCUIApplication, _ name: String) {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + " AX"; tree.lifetime = .keepAlways; add(tree)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}

/// Self-contained regression; never depends on a retained imported fixture.
@MainActor
final class NoteSelectionNavigationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if targetEnvironment(simulator)
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BAERCHEN_NOTE_SELECTION_ACCEPTANCE"] == "1",
                          "Requires an owned disposable simulator and its isolated UI-test library.")
        #else
        throw XCTSkip("Selection fixtures never run on physical devices.")
        #endif
    }

    func testCreatedNoteReopensAfterReselectingNotesScope() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-library"]
        app.launch()
        XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 30))
        app.buttons["new-note"].tap()
        let editor = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Note text")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 20))
        let source = "Selection fixture\nThe body must still open."
        editor.tap(); editor.typeText(source)
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", source), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
        app.buttons["Dismiss Keyboard"].firstMatch.tap()
        let sidebar = app.buttons.matching(NSPredicate(format: "label IN %@", ["Show Sidebar", "Sidebar"])).firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10))
        sidebar.tap()
        let notes = app.descendants(matching: .any)["scope-Notes"].firstMatch
        XCTAssertTrue(notes.waitForExistence(timeout: 10))
        notes.tap()
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 10), .completed)
        XCTAssertTrue(app.buttons["Show Sidebar"].firstMatch.waitForExistence(timeout: 10),
                      "Selecting a scope must dismiss an overlay sidebar before tapping a note.")
        let rows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Selection fixture"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        let row = try XCTUnwrap(rows.allElementsBoundByIndex.first(where: { $0.isHittable }))
        record(app, "Created note after Notes scope before tap")
        row.tap()
        let opened = editor.waitForExistence(timeout: 10)
        record(app, opened ? "Created note reopened" : "Created note remains unselected")
        XCTAssertTrue(opened, "A note must reopen after returning to Notes, without restarting the app.")
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", source), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 10), .completed)
        app.terminate()
    }

    func testSettingsDismissesOverlayBeforeOpeningNote() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-library"]
        app.launch()
        XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 30))
        app.buttons["new-note"].tap()
        let editor = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Note text")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 20))
        let source = "Settings fixture\nThe body must remain intact."
        editor.tap(); editor.typeText(source)
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", source), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
        app.buttons["Dismiss Keyboard"].firstMatch.tap()
        let sidebar = app.buttons["Show Sidebar"].firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10)); sidebar.tap()
        let notes = app.descendants(matching: .any)["scope-Notes"].firstMatch
        XCTAssertTrue(notes.waitForExistence(timeout: 10)); notes.tap()
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 10), .completed)
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10)); sidebar.tap()
        let options = app.buttons["Library Options"]
        XCTAssertTrue(options.waitForExistence(timeout: 10)); options.tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10)); app.buttons["Done"].tap()
        record(app, "After settings before note tap")
        XCTAssertTrue(app.buttons["Show Sidebar"].firstMatch.waitForExistence(timeout: 10),
                      "Returning from settings must dismiss an overlay sidebar.")
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Settings fixture")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", source), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 10), .completed)
        app.terminate()
    }

    func testSectionKeyDismissesOverlayBeforeOpeningNote() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-library"]
        app.launch()
        XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 30)); app.buttons["new-note"].tap()
        let editor = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Note text")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 20)); editor.tap()
        let source = "Menu fixture\nThe body must remain intact."
        editor.typeText(source)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", source), object: editor)], timeout: 10), .completed)
        app.buttons["Dismiss Keyboard"].firstMatch.tap()
        let sidebar = app.buttons["Show Sidebar"].firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10)); sidebar.tap()
        // IOS-CLUTTER-R6: the Navigate menu is gone; its section keys (Mac numbering) remain.
        XCTAssertTrue(app.buttons["Library Options"].waitForExistence(timeout: 10))
        app.typeKey("1", modifierFlags: [.command, .option])
        record(app, "After section key scope selection")
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10), "A section key must dismiss an overlay sidebar.")
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 10), .completed)
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Menu fixture")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", source), object: editor)], timeout: 10), .completed)
        app.terminate()
    }

    func testCompactScopeAndSettingsReturnToNoteList() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BAERCHEN_COMPACT_LAYOUT_ACCEPTANCE"] == "1", "Requires the owned compact iPhone simulator.")
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-library"]
        app.launch()
        XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 30))
        app.buttons["new-note"].tap()
        let editor = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Note text")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 20)); editor.tap()
        let source = "Compact fixture\nThe body must remain intact."
        editor.typeText(source)
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", source), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
        app.buttons["Dismiss Keyboard"].firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        let listBack = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(listBack.waitForExistence(timeout: 10)); listBack.tap()
        let notes = app.descendants(matching: .any)["scope-Notes"].firstMatch
        XCTAssertTrue(notes.waitForExistence(timeout: 10)); notes.tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Compact fixture")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", source), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 10), .completed)
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        let options = app.buttons["Library Options"]
        XCTAssertTrue(options.waitForExistence(timeout: 10)); options.tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10)); app.buttons["Done"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", source), object: editor)], timeout: 10), .completed)
        app.terminate()
    }

    func testWideSidebarStaysVisibleAfterScopeAndSettings() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BAERCHEN_WIDE_LAYOUT_ACCEPTANCE"] == "1", "Requires the owned wide iPad simulator.")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-library"]
        app.launch()
        XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 30))
        app.buttons["new-note"].tap()
        let editor = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Note text")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 20)); editor.tap(); editor.typeText("Wide fixture")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Wide fixture"), object: editor)], timeout: 10), .completed)
        app.buttons["Dismiss Keyboard"].firstMatch.tap()
        let notes = app.descendants(matching: .any)["scope-Notes"].firstMatch
        if !notes.isHittable { app.buttons["Show Sidebar"].firstMatch.tap() }
        XCTAssertTrue(notes.waitForExistence(timeout: 10)); XCTAssertTrue(notes.isHittable)
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Wide fixture")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        record(app, "Wide layout before scope selection")
        let title = row.staticTexts["Wide fixture"].firstMatch
        XCTAssertTrue(title.exists)
        XCTAssertLessThanOrEqual(notes.frame.maxX, title.frame.minX, "The wide test must start with separate sidebar and list columns.")
        notes.tap()
        XCTAssertTrue(notes.isHittable, "The persistent sidebar must stay visible after scope selection.")
        record(app, "Wide layout after scope selection")
        app.buttons["Library Options"].tap(); app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10)); app.buttons["Done"].tap()
        XCTAssertTrue(notes.isHittable, "The persistent sidebar must stay visible after settings.")
        record(app, "Wide layout after settings")
        XCTAssertTrue(row.isHittable); row.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Wide fixture"), object: editor)], timeout: 10), .completed)
        app.terminate()
    }

    private func record(_ app: XCUIApplication, _ name: String) {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + " AX"; tree.lifetime = .keepAlways; add(tree)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
