// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import XCTest

/// Actual Files export/import, restricted to the disposable simulator's UI-testing library.
@MainActor
final class BackupFilesUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if targetEnvironment(simulator)
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BAERCHEN_BACKUP_FILES_ACCEPTANCE"] == "1",
                          "Backup Files acceptance requires a dedicated disposable simulator.")
        #else
        throw XCTSkip("Backup fixtures never run on physical devices or a personal library.")
        #endif
    }

    func testBackupExportAndRestorePickerCancellationPreservesNote() throws {
        let app = launchFixture()
        let source = "# Backup cancellation fixture\nThis exact source survives both canceled pickers."
        try createNote(in: app, source: source)
        try openBackups(in: app)
        app.buttons["Create Backup"].tap()
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 30))
        record(app, "Actual backup export picker before cancellation")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Create Backup"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        app.buttons["Choose Backup to Restore"].tap()
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 20))
        record(app, "Actual restore picker before cancellation")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Create Backup"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertFalse(app.buttons["Merge Backup"].exists)
        try closeBackups(in: app)
        assertSource(source, in: app)
        record(app, "Exact source after both canceled backup pickers")
    }

    func testMissingProtectedNoteMergeWithForeignPasswordWrongThenRetry() throws {
        let app = launchFixture()
        let foreignSource = "# Foreign backup source\nProtected body from the first library."
        let currentSource = "# Current backup destination\nExisting protected body must stay exact."
        let foreignPassword = "backup-source-password"
        let currentPassword = "backup-current-password"
        try createNote(in: app, source: foreignSource)
        try lockNote(in: app, password: foreignPassword)
        try openBackups(in: app)
        app.buttons["Create Backup"].tap()
        XCTAssertTrue(app.buttons["Save"].firstMatch.waitForExistence(timeout: 30))
        record(app, "Foreign-password backup actual export picker")
        try chooseLocalLocation(in: app)
        let nameField = try XCTUnwrap(app.textFields.allElementsBoundByIndex.first {
            ($0.value as? String ?? "").hasPrefix("Theo Notes Backup ")
        }, "The export picker must expose the proposed backup filename.")
        let filename = try XCTUnwrap(nameField.value as? String)
        let basename = filename.replacingOccurrences(of: ".theonotes-backup", with: "")
        app.buttons["Save"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Backup exported. A local recovery copy is also saved on this device."].waitForExistence(timeout: 30))
        record(app, "Foreign backup saved through Files: " + basename)

        // Only this explicitly isolated test library is reset. The Files provider copy remains.
        app.terminate()
        app.launchArguments = ["--ui-testing", "--reset-library"]
        app.launch()
        try createNote(in: app, source: currentSource)
        try lockNote(in: app, password: currentPassword)
        try openBackups(in: app)
        app.buttons["Choose Backup to Restore"].tap()
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 20))
        try chooseLocalLocation(in: app)
        let exported = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", basename))
        XCTAssertTrue(exported.firstMatch.waitForExistence(timeout: 20))
        let file = try XCTUnwrap(exported.allElementsBoundByIndex.first(where: { $0.isHittable }))
        file.tap()
        XCTAssertTrue(app.buttons["Merge Backup"].waitForExistence(timeout: 30))
        record(app, "Foreign protected backup inspected through restore picker")
        app.buttons["Merge Backup"].tap()
        let backupPassword = app.secureTextFields["Password Used for This Backup"]
        let existingPassword = app.secureTextFields["Current Note Password"]
        XCTAssertTrue(backupPassword.waitForExistence(timeout: 30))
        let wrong = "incorrect-backup-password"
        backupPassword.tap(); backupPassword.typeText(wrong)
        existingPassword.tap(); existingPassword.typeText(currentPassword)
        if app.buttons["Hide keyboard"].firstMatch.exists { app.buttons["Hide keyboard"].firstMatch.tap() }
        app.collectionViews.containing(.secureTextField, identifier: "Current Note Password").firstMatch.swipeUp()
        app.buttons["Merge Backup"].tap()
        XCTAssertTrue(app.alerts["Backup and Restore"].waitForExistence(timeout: 30))
        record(app, "Wrong foreign backup password rejected")
        app.alerts["Backup and Restore"].buttons["OK"].tap()
        XCTAssertTrue(backupPassword.waitForExistence(timeout: 10))
        backupPassword.tap()
        backupPassword.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: wrong.count))
        backupPassword.typeText(foreignPassword)
        if app.buttons["Hide keyboard"].firstMatch.exists { app.buttons["Hide keyboard"].firstMatch.tap() }
        app.collectionViews.containing(.secureTextField, identifier: "Current Note Password").firstMatch.swipeUp()
        app.buttons["Merge Backup"].tap()
        XCTAssertTrue(app.staticTexts["Restored 1 notes. Kept 0 existing notes."].waitForExistence(timeout: 30))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        record(app, "Missing protected note merged after correct-password retry")
        try closeBackups(in: app)

        try openNote(in: app, title: "Foreign backup source")
        try unlockNote(in: app, password: currentPassword)
        assertSource(foreignSource, in: app)
        try openNote(in: app, title: "Current backup destination")
        assertSource(currentSource, in: app)
        record(app, "Both protected note sources remain exact under current password")
    }

    private func launchFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-library"]
        app.launch()
        return app
    }

    private func createNote(in app: XCUIApplication, source: String) throws {
        XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 60))
        let title = String(source.split(separator: "\n", omittingEmptySubsequences: false)[0].dropFirst(2))
        let basename = "Backup Files Fixture - " + title
        let filename = basename + ".md"
        // These synthetic files are staged in this owned simulator's local provider.
        // Fixture creation uses the actual importer, avoiding unrelated WebView typing
        // and never touching the host clipboard, app hooks or the database directly.
        try showLibraryOptions(in: app)
        app.buttons["Library Options"].tap()
        app.buttons["Import Notes"].tap()
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 20))
        try chooseLocalLocation(in: app)
        // Use the observed document cell, not a similarly named parent or text node.
        let candidates = app.cells.matching(identifier: basename + ", md")
        guard candidates.firstMatch.waitForExistence(timeout: 15),
              let file = candidates.allElementsBoundByIndex.first(where: { $0.isHittable }) else {
            record(app, "Missing staged synthetic backup fixture: " + filename)
            XCTFail("Stage \(filename) in the owned simulator's local Files provider before this opt-in run.")
            throw NSError(domain: "BackupFilesUITestFixture", code: 1)
        }
        file.tap()
        // Import Notes uses a multi-selection picker. A merely existing Open button
        // can still be disabled while selection settles; tapping it does nothing.
        let open = app.buttons["Open"].firstMatch
        let openReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"), object: open)
        guard XCTWaiter.wait(for: [openReady], timeout: 15) == .completed else {
            record(app, "Selected fixture did not enable the actual Files Open control")
            XCTFail("The actual Files Open button must be enabled and hittable before importing the fixture.")
            throw NSError(domain: "BackupFilesUITestFixture", code: 2)
        }
        open.tap()
        let pickerRoot = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "DOC.browsingRoot Source:")).firstMatch
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: pickerRoot)
        guard XCTWaiter.wait(for: [dismissed], timeout: 20) == .completed else {
            record(app, "Actual Files picker remained after opening the selected fixture")
            XCTFail("The actual Files browsing root must disappear before navigating the underlying app.")
            throw NSError(domain: "BackupFilesUITestFixture", code: 3)
        }
        // 1.1 (A14): the import options step sits between the picker and the import; defaults stay as they are.
        let importButton = app.buttons["Import"].firstMatch
        XCTAssertTrue(importButton.waitForExistence(timeout: 30), "the import options step must open after the picker")
        importButton.tap()
        let notes = app.descendants(matching: .any)["scope-Notes"].firstMatch
        let notesReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"), object: notes)
        guard XCTWaiter.wait(for: [notesReady], timeout: 15) == .completed else {
            record(app, "Notes scope unavailable after actual picker dismissal")
            XCTFail("Notes must be enabled and hittable after the system picker has dismissed.")
            throw NSError(domain: "BackupFilesUITestFixture", code: 4)
        }
        notes.tap()
        let imported = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Imported 1 notes")).firstMatch
        XCTAssertTrue(imported.waitForExistence(timeout: 30))
        try openNote(in: app, title: title)
        XCTAssertTrue(noteText(in: app).waitForExistence(timeout: 30))
        assertSource(source, in: app)
        record(app, "Synthetic backup fixture imported with exact source: " + title)
    }

    private func assertSource(_ source: String, in app: XCUIApplication) {
        let editor = noteText(in: app)
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", source), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 15), .completed,
                       "Actual fixture editor value: \(String(reflecting: editor.value))")
    }

    private func lockNote(in app: XCUIApplication, password: String) throws {
        app.descendants(matching: .any)["Note Actions"].firstMatch.tap()
        app.buttons["Lock Note"].tap()
        let field = app.secureTextFields["note-password"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap(); field.typeText(password)
        let confirmation = app.secureTextFields["confirm-note-password"]
        confirmation.tap(); confirmation.typeText(password)
        app.buttons["submit-note-password"].tap()
        XCTAssertTrue(app.buttons["unlock-note"].waitForExistence(timeout: 30))
        XCTAssertFalse(noteText(in: app).exists)
    }

    private func unlockNote(in app: XCUIApplication, password: String) throws {
        XCTAssertTrue(app.buttons["unlock-note"].waitForExistence(timeout: 20))
        app.buttons["unlock-note"].tap()
        let field = app.secureTextFields["note-password"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap(); field.typeText(password)
        app.buttons["submit-note-password"].tap()
        XCTAssertTrue(noteText(in: app).waitForExistence(timeout: 30))
    }

    private func openNote(in app: XCUIApplication, title: String) throws {
        let rows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15))
        try XCTUnwrap(rows.allElementsBoundByIndex.first(where: { $0.isHittable })).tap()
    }

    private func openBackups(in app: XCUIApplication) throws {
        try showLibraryOptions(in: app)
        app.buttons["Library Options"].tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["Advanced"].waitForExistence(timeout: 15))
        app.buttons["Advanced"].tap()
        app.buttons["Backup and Restore"].tap()
        XCTAssertTrue(app.buttons["Create Backup"].waitForExistence(timeout: 15))
    }

    private func showLibraryOptions(in app: XCUIApplication) throws {
        if !app.buttons["Library Options"].isHittable {
            let sidebar = app.buttons.matching(NSPredicate(format: "label IN %@", ["Show Sidebar", "Toggle sidebar"])).firstMatch
            XCTAssertTrue(sidebar.waitForExistence(timeout: 10)); sidebar.tap()
        }
        XCTAssertTrue(app.buttons["Library Options"].waitForExistence(timeout: 10))
    }

    private func chooseLocalLocation(in app: XCUIApplication) throws {
        let local = app.descendants(matching: .any).matching(
            NSPredicate(format: "label IN %@", ["On My iPad", "On My iPhone"]))
        if !local.allElementsBoundByIndex.contains(where: { $0.isHittable }) {
            let browse = app.buttons.matching(identifier: "Browse").allElementsBoundByIndex.first(where: { $0.isHittable })
            try XCTUnwrap(browse, "Files must expose Browse before selecting the local provider.").tap()
        }
        XCTAssertTrue(local.firstMatch.waitForExistence(timeout: 15))
        let location = try XCTUnwrap(local.allElementsBoundByIndex.first(where: { $0.isHittable }),
                                     "Files must expose a hittable On My iPad or On My iPhone location.")
        location.tap()
        // Observed in the real Files AX tree: verify the browsing root, rather
        // than trusting that a sidebar label exists or its tap navigated.
        let localRoot = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (identifier ENDSWITH %@ OR identifier ENDSWITH %@)",
            "DOC.browsingRoot Source: com.apple.FileProvider.LocalStorage, Title: ",
            "On My iPad", "On My iPhone")).firstMatch
        XCTAssertTrue(localRoot.waitForExistence(timeout: 15),
                      "Files did not navigate to its local provider root.")
        record(app, "Verified actual Files local provider root")
    }

    private func closeBackups(in app: XCUIApplication) throws {
        let advanced = app.navigationBars["Backup and Restore"].buttons["Advanced"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 10)); advanced.tap()
        let settings = app.navigationBars["Advanced"].buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
    }

    private func noteText(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Note text")).firstMatch
    }

    private func record(_ app: XCUIApplication, _ name: String) {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + " hierarchy"; tree.lifetime = .keepAlways; add(tree)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }
}
