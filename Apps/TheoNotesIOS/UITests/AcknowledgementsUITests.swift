// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import XCTest

/// LIC-R16: Settings ▸ Acknowledgements lists the bundled components and shows the licence text.
/// Runs only against the disposable --ui-testing library.
@MainActor final class AcknowledgementsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testAcknowledgementsListsComponentsAndShowsLicenceText() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-library"]
        app.launch()
        // The iPhone opens its note list; reveal the sidebar if needed.
        if !app.buttons["Library Options"].waitForExistence(timeout: 60) {
            let back = app.navigationBars.buttons.firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 30))
            back.tap()
        }
        app.buttons["Library Options"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 30))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings-privacy-policy"].firstMatch.waitForExistence(timeout: 30))
        XCTAssertTrue(app.descendants(matching: .any)["settings-support"].firstMatch.exists)
        let row = app.descendants(matching: .any)["settings-acknowledgements"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 60))
        let settingsShot = XCTAttachment(screenshot: app.screenshot())
        settingsShot.name = "ios-settings-links"; settingsShot.lifetime = .keepAlways
        add(settingsShot)
        row.tap()
        let mathJax = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "acknowledgement-@mathjax/src")).firstMatch
        let list = app.descendants(matching: .any)["acknowledgements-list"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 60))
        var swipes = 0
        while !mathJax.isHittable && swipes < 40 { list.swipeUp(); swipes += 1 }
        XCTAssertTrue(mathJax.isHittable, "MathJax must be in the list")
        mathJax.tap()
        let text = app.descendants(matching: .any)["acknowledgement-licence-text"].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 60))
        XCTAssertGreaterThan(text.label.count + ((text.value as? String)?.count ?? 0), 200, "the licence text must be shown")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "ios-acknowledgements"; shot.lifetime = .keepAlways
        add(shot)
    }
}
