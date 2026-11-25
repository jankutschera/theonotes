// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import XCTest

/// Actual system authentication cancellation on an explicitly owned disposable simulator.
/// Never enters a device credential or substitutes a simulated authentication result.
@MainActor
final class AppLockAcceptanceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if targetEnvironment(simulator)
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BAERCHEN_APP_LOCK_ACCEPTANCE"] == "1",
                          "Requires an owned disposable simulator with the system passcode prompt.")
        #else
        throw XCTSkip("Never modifies authentication settings on a physical device.")
        #endif
    }

    func testCancelledSystemAuthenticationCannotEnableAppLock() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-library"]
        app.launch()
        XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 60))
        openPrivacy(in: app)
        let protection = app.switches["Require Authentication to Open Theo Notes"]
        XCTAssertTrue(protection.waitForExistence(timeout: 10))
        XCTAssertEqual(protection.value as? String, "0")
        let nativeSwitch = protection.switches.firstMatch
        XCTAssertTrue(nativeSwitch.waitForExistence(timeout: 10))
        XCTAssertTrue(nativeSwitch.isHittable)
        XCTAssertLessThan(nativeSwitch.frame.width, protection.frame.width,
                          "Tap the actual nested native switch, not its full-width label wrapper.")
        attachHierarchy(app, name: "Before actual native switch tap")
        nativeSwitch.tap()
        attachHierarchy(app, name: "After actual native switch tap")
        let authentication = XCUIApplication(bundleIdentifier: "com.apple.LocalAuthenticationUIService")
        let passcode = authentication.secureTextFields["Passcode"]
        XCTAssertTrue(passcode.waitForExistence(timeout: 20),
                      "The real system passcode sheet must be observed before cancellation.")
        attachHierarchy(authentication, name: "Observed actual system passcode sheet")
        let cancel = authentication.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "Close"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5),
                      "System authentication must expose a named Cancel or Close button; no coordinate guess.")
        XCTAssertTrue(cancel.isHittable)
        cancel.tap()
        attachHierarchy(app, name: "After cancelling actual system authentication")
        // The root error alert can dismiss Settings and obstruct its controls.
        // Handle the observed alert before checking touchability in Privacy.
        let failure = app.alerts["Theo Notes"]
        if failure.waitForExistence(timeout: 5) {
            XCTAssertTrue(failure.staticTexts["Access protection was not changed. Authenticate to try again."].exists)
            failure.buttons["OK"].tap()
        }
        if !app.navigationBars["Privacy"].waitForExistence(timeout: 3) {
            openPrivacy(in: app)
        }
        // Query only app elements after cancelling: the remote service disappears.
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true AND hittable == true"), object: nativeSwitch)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        XCTAssertEqual(protection.value as? String, "0")
        attachHierarchy(app, name: "Cancelled authentication leaves protection off and usable")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Real LocalAuthentication cancellation outcome"
        attachment.lifetime = .keepAlways; add(attachment)
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 30),
                      "Rejected enrollment must not persist an inaccessible app lock")
    }

    private func openPrivacy(in app: XCUIApplication) {
        // The iPhone initially opens its note list; reveal the sidebar if needed.
        if !app.buttons["Library Options"].exists {
            let back = app.navigationBars.buttons.firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 10))
            back.tap()
        }
        app.buttons["Library Options"].tap()
        app.buttons["Settings"].tap()
        app.buttons["Privacy"].tap()
        XCTAssertTrue(app.navigationBars["Privacy"].waitForExistence(timeout: 10))
    }

    private func attachHierarchy(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
