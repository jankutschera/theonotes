// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import XCTest

/// Native picker regressions, run only against the explicitly disposable --ui-testing library.
@MainActor final class MediaPickerLifecycleUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    private func noteText(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Note text")).firstMatch
    }
    private func fixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-library"]
        app.launch()
        XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 60))
        app.buttons["new-note"].tap()
        let text = noteText(app)
        XCTAssertTrue(text.waitForExistence(timeout: 60))
        text.tap(); text.typeText("Picker lifecycle fixture")
        app.buttons["Dismiss Keyboard"].firstMatch.tap()
        return app
    }
    /// Pickers open from the bar's Attach menu; Lock Note stays in Note Actions.
    private static let attachEntries = ["Insert File": "toolbar-attach-file", "Photo Library": "toolbar-attach-photos"]
    private func action(_ name: String, app: XCUIApplication) {
        let attach = Self.attachEntries[name]
        let menu = attach == nil ? app.descendants(matching: .any)["Note Actions"].firstMatch
            : app.descendants(matching: .any)["toolbar-attach"].firstMatch
        let menuReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: menu)
        XCTAssertEqual(XCTWaiter.wait(for: [menuReady], timeout: 15), .completed,
                       "The menu must be hittable after the native picker transition before opening it")
        menu.tap()
        let action = attach.map { app.buttons[$0].firstMatch } ?? app.buttons[name].firstMatch
        // Native menus clip long collections. XCTest's actual tap scrolls the exact
        // item into view; requiring hittable first would prevent that supported action.
        let actionReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true"), object: action)
        XCTAssertEqual(XCTWaiter.wait(for: [actionReady], timeout: 10), .completed,
                       "\(name) must exist and be enabled in the opened native menu")
        XCTAssertTrue(action.isEnabled, "\(name) must be enabled after the previous picker ended")
        if name == "Insert File" {
            XCTAssertEqual(app.buttons.matching(identifier: "toolbar-attach-file").count, 1,
                           "The visible Files menu action must have a unique identifier")
            XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", name)).count, 1,
                           "An invisible keyboard command must not alias the visible Insert File label")
            XCTAssertEqual(action.label, "Insert File")
        }
        action.tap()
    }
    private func cancelPicker(_ app: XCUIApplication) {
        let cancel = app.buttons["Cancel"].firstMatch
        guard cancel.waitForExistence(timeout: 20) else {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Picker failure accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "Picker failure screenshot"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            XCTFail("The native picker must actually be presented")
            return
        }
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 20), "The native picker must finish dismissing")
        XCTAssertTrue(noteText(app).waitForExistence(timeout: 20))
    }
    func testFilesCancelReleasesGateAndAllowsPhotosAndAnotherFilePicker() {
        let app = fixture()
        action("Insert File", app: app); cancelPicker(app)
        action("Photo Library", app: app); cancelPicker(app)
        action("Insert File", app: app); cancelPicker(app)
        XCTAssertTrue((noteText(app).value as? String ?? "").contains("Picker lifecycle fixture"))
        XCTAssertFalse((noteText(app).value as? String ?? "").contains("]("))
    }
    func testPrivacyCloseDismissesFilePickerAndAllowsCaptureAfterUnlock() {
        assertPrivacyClose(picker: "Insert File")
    }
    func testPrivacyCloseDismissesPhotoPickerAndAllowsCaptureAfterUnlock() {
        assertPrivacyClose(picker: "Photo Library")
    }
    private func assertPrivacyClose(picker: String) {
        let app = fixture()
        action("Lock Note", app: app)
        let password = app.secureTextFields["note-password"]
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        password.tap(); password.typeText("picker-fixture-password")
        let confirmation = app.secureTextFields["confirm-note-password"]
        confirmation.tap(); confirmation.typeText("picker-fixture-password")
        app.buttons["submit-note-password"].tap()
        XCTAssertTrue(app.buttons["unlock-note"].waitForExistence(timeout: 20))
        unlock(app)
        action(picker, app: app)
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 20))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["unlock-note"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["Cancel"].firstMatch.exists, "Privacy close must dismiss the active media picker")
        unlock(app)
        // Repeated immediate reuse must remain independent of the old privacy-dismiss callbacks.
        action("Photo Library", app: app); cancelPicker(app)
        action("Insert File", app: app); cancelPicker(app)
        action("Photo Library", app: app); cancelPicker(app)
        action("Insert File", app: app); cancelPicker(app)
    }
    private func unlock(_ app: XCUIApplication) {
        app.buttons["unlock-note"].tap()
        let password = app.secureTextFields["note-password"]
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        password.tap(); password.typeText("picker-fixture-password")
        app.buttons["submit-note-password"].tap()
        XCTAssertTrue(noteText(app).waitForExistence(timeout: 60))
    }
}
