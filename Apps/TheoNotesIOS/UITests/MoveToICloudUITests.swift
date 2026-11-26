// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import XCTest

/// Settings ▸ iCloud offers the move and a tap opens the confirmation; after a move the "move your other devices
/// now" notice shows. Cancel only: the move itself is covered by the unit tests. Runs only against the disposable --ui-testing library.
/// For the evidence screenshots (taken with `simctl io` from the host) each test holds its screen for a few seconds after writing a
/// marker file into the host's caches folder; without a host (a device) it does not wait.
@MainActor final class MoveToICloudUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func openICloudSettings(_ app: XCUIApplication) {
        if !app.buttons["Library Options"].waitForExistence(timeout: 60) {
            let back = app.navigationBars.buttons.firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 30))
            back.tap()
        }
        app.buttons["Library Options"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 30))
        app.buttons["Settings"].tap()
        let icloud = app.buttons["iCloud"].firstMatch
        XCTAssertTrue(icloud.waitForExistence(timeout: 30))
        icloud.tap()
    }

    /// Swipes up, as a finger does, until the element is on screen: at the largest text sizes the list builds a row only when it
    /// scrolls in.
    private func swipeUntilVisible(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !(element.exists && element.isHittable) { app.swipeUp() }
    }

    /// Writes `<host caches>/TheoNotesMoveShots/<name>` and holds the screen so the host can take its screenshot.
    private func holdForScreenshot(_ name: String) {
        guard let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] else { return }
        let folder = URL(fileURLWithPath: home).appendingPathComponent("Library/Caches/TheoNotesMoveShots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data())
        Thread.sleep(forTimeInterval: 10)
    }

    func testTheSettingsOfferTheMoveAndATapOpensTheConfirmation() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["--ui-testing", "--reset-library", "--private-server-fixture"]
        app.launch()
        openICloudSettings(app)
        let move = app.buttons["cloud-sync-move"].firstMatch
        XCTAssertTrue(move.waitForExistence(timeout: 30))
        XCTAssertTrue(app.descendants(matching: .any)["cloud-sync-private-server"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "do not change notes in between")).firstMatch.exists,
                      "the row says what the move asks")
        holdForScreenshot("settings")
        move.tap()
        XCTAssertTrue(app.buttons["Move to iCloud"].firstMatch.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Move This Library to iCloud?"].firstMatch.exists, "Title Case title")
        holdForScreenshot("confirmation")
    }

    func testAfterAMoveTheSettingsAskToMoveTheOtherDevicesUntilDismissed() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["--ui-testing", "--reset-library", "--private-server-fixture", "--moved-fixture"]
        app.launch()
        openICloudSettings(app)
        let notice = app.descendants(matching: .any)["cloud-sync-move-notice"].firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["cloud-sync-move"].exists, "the library no longer syncs through the private server")
        XCTAssertTrue(notice.label.hasPrefix("Move Your Other Devices Now"), "the notice starts with its title: \(notice.label)")
        holdForScreenshot("notice")
        // The fixture moved without switching iCloud on: the settings say so next to the notice.
        let notStarted = app.descendants(matching: .any)["cloud-sync-move-not-started"].firstMatch
        swipeUntilVisible(notStarted, in: app)
        XCTAssertTrue(notStarted.label.hasPrefix("iCloud Sync Is Off"), "the line starts with its title: \(notStarted.label)")
        let dismiss = app.buttons["cloud-sync-move-notice-dismiss"].firstMatch
        swipeUntilVisible(dismiss, in: app)
        if !notice.isHittable { holdForScreenshot("notice-end") }
        dismiss.tap()
        XCTAssertFalse(notice.waitForExistence(timeout: 3))
    }

    /// The refusal for files no device ever had shows the card and offers "Move to iCloud Without These Files…",
    /// which opens the same confirmation as the move. The fixture stands in for the private server's answer (the move itself is
    /// covered by the unit tests); the taps are real.
    private func refuseForMissingFiles(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-library", "--private-server-fixture", "--missing-files-fixture"] + extra
        app.launch()
        openICloudSettings(app)
        let move = app.buttons["cloud-sync-move"].firstMatch
        XCTAssertTrue(app.descendants(matching: .any)["cloud-sync-private-server"].firstMatch.waitForExistence(timeout: 30))
        swipeUntilVisible(move, in: app)
        XCTAssertTrue(move.exists)
        move.tap()
        let confirm = app.buttons["Move to iCloud"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 30))
        confirm.tap()
        let card = app.descendants(matching: .any)["cloud-sync-missing-files"].firstMatch
        if !card.waitForExistence(timeout: 30) { swipeUntilVisible(card, in: app) }
        XCTAssertTrue(card.exists)
        return app
    }

    func testMissingFilesNoDeviceHadOfferMoveWithoutTheseFiles() {
        let app = refuseForMissingFiles([])
        defer { app.terminate() }
        let card = app.descendants(matching: .any)["cloud-sync-missing-files"].firstMatch
        XCTAssertTrue(card.label.hasPrefix("Some Attachments Are Missing"), "the card starts with its title: \(card.label)")
        XCTAssertTrue(card.label.contains("2 notes link to files") && card.label.contains("Trip photos"), card.label)
        let without = app.buttons["cloud-sync-move-without-files"].firstMatch
        swipeUntilVisible(without, in: app)
        XCTAssertEqual(without.label, "Move to iCloud Without These Files…")
        holdForScreenshot("missing-files")
        without.tap()
        XCTAssertTrue(app.staticTexts["Move This Library to iCloud?"].firstMatch.waitForExistence(timeout: 30), "the move's own title")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "The missing attachment files stay missing.")).firstMatch.exists)
        XCTAssertTrue(app.buttons["Move to iCloud"].firstMatch.exists)
        holdForScreenshot("confirmation-without-files")
    }

    /// The owner's case: six notes. Five titles, each on one line, then "and 1 more".
    func testSixNotesShowFiveTitlesAndHowManyMore() {
        let app = refuseForMissingFiles(["--six-notes"])
        defer { app.terminate() }
        let card = app.descendants(matching: .any)["cloud-sync-missing-files"].firstMatch
        XCTAssertTrue(card.label.contains("6 notes link to files") && card.label.contains("and 1 more"), card.label)
        let without = app.buttons["cloud-sync-move-without-files"].firstMatch
        swipeUntilVisible(without, in: app)
        holdForScreenshot("missing-files-six")
        // At the largest text sizes the card is taller than the screen: its top half too.
        if card.frame.minY < app.navigationBars.firstMatch.frame.maxY {
            app.swipeDown()
            holdForScreenshot("missing-files-six-top")
        }
    }
}
