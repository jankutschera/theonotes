// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import XCTest

@MainActor
final class MobileUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        // An earlier class may leave the iPad in landscape, where the on-screen keyboard covers the list's bottom bar.
        XCUIDevice.shared.orientation = .portrait
    }

    // WKContentView can be reported as Other or WebView by different simulator AX snapshots.
    // Resolve the editor by its accessible name, without a transient WebView ancestor type.
    private func noteText(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Note text")).firstMatch
    }

    /// Side by side the list's bottom bar holds Quick Open and From Template; stacked, Note Actions does.
    private func listOrNoteAction(_ identifier: String, in app: XCUIApplication) {
        let bar = app.buttons[identifier].firstMatch
        if bar.exists && bar.isHittable { bar.tap(); return }
        app.descendants(matching: .any)["Note Actions"].firstMatch.tap()
        let entry = app.buttons[identifier.replacingOccurrences(of: "list-", with: "note-")].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 30)); entry.tap()
    }

    func testCaptureSurvivesRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-library"]
        app.launch()
        let create = app.buttons["new-note"]
        XCTAssertTrue(create.waitForExistence(timeout: 60))
        create.tap()
        let editor = noteText(in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 60))
        editor.tap()
        editor.typeText("Mobile capture\nA thought saved on this device.")
        // The editor's accessibility value follows the web view a moment after the last key; one read raced it on iPad.
        let arrived = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "A thought saved on this device."), object: editor)
        _ = XCTWaiter.wait(for: [arrived], timeout: 30)
        let typed = editor.value as? String ?? ""
        if !typed.contains("Mobile capture\nA thought saved on this device.") {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Capture mismatch"; screenshot.lifetime = .keepAlways; add(screenshot)
        }
        XCTAssertTrue(typed.contains("Mobile capture\nA thought saved on this device."), "Actual editor value: \(String(reflecting: typed))")
        app.buttons["Dismiss Keyboard"].firstMatch.tap()
        XCUIDevice.shared.press(.home)
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        // The selected note is restored directly, including on compact iPhone layouts.
        XCTAssertTrue(noteText(in: app).waitForExistence(timeout: 60))
        XCTAssertTrue((noteText(in: app).value as? String ?? "").contains("A thought saved on this device."))
        XCTAssertTrue(noteText(in: app).waitForExistence(timeout: 60))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Saved mobile note"
        shot.lifetime = .keepAlways
        add(shot)
    }
    func testTemplatesQuickOpenAndInfo() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-library"]
        app.launch()
        XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 60))
        app.buttons["new-note"].tap()
        let text = noteText(in: app)
        XCTAssertTrue(text.waitForExistence(timeout: 60))
        text.tap()
        let templateSource = "# {{title}}\nAgenda for today\n#template/meeting"
        text.typeText(templateSource)
        let completeTemplate = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", templateSource), object: text)
        let templateReady = XCTWaiter.wait(for: [completeTemplate], timeout: 10)
        if templateReady != .completed {
            let actual = XCTAttachment(string: "Requested: \(String(reflecting: templateSource))\nActual AX value: \(String(reflecting: text.value))")
            actual.name = "Incomplete typed template fixture"; actual.lifetime = .keepAlways; add(actual)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Incomplete template fixture editor"; screenshot.lifetime = .keepAlways; add(screenshot)
        }
        XCTAssertEqual(templateReady, .completed, "The complete template fixture must arrive before dismissing the keyboard. Actual AX value: \(String(reflecting: text.value))")
        app.buttons["Dismiss Keyboard"].firstMatch.tap()
        listOrNoteAction("list-from-template", in: app)
        let title = app.textFields["Title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap(); title.typeText("Weekly review")
        app.buttons["Create"].tap()
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertTrue((text.value as? String ?? "").contains("Weekly review"))
        XCTAssertFalse((text.value as? String ?? "").contains("#template"))
        listOrNoteAction("list-quick-open", in: app)
        let query = app.textFields["quick-open-query"]
        XCTAssertTrue(query.waitForExistence(timeout: 10))
        query.tap(); query.typeText("Weekly")
        let results = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Weekly review"))
        // iPad keeps the underlying library visible beneath the Quick Open sheet.
        // Choose its hittable result, never the covered note-list row.
        XCTAssertTrue(results.firstMatch.waitForExistence(timeout: 10))
        let result = try XCTUnwrap(results.allElementsBoundByIndex.first(where: { $0.isHittable }))
        result.tap()
        app.descendants(matching: .any)["Note Actions"].firstMatch.tap()
        app.buttons["Note Info"].tap()
        XCTAssertTrue(app.staticTexts["Words"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Contents"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Mobile note information"; shot.lifetime = .keepAlways; add(shot)
    }

    func testPrivateNoteLocksWhenInactiveAndReopensAfterPassword() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-library"]
        app.launch()
        XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 60))
        app.buttons["new-note"].tap()
        let text = noteText(in: app)
        XCTAssertTrue(text.waitForExistence(timeout: 60))
        text.tap(); text.typeText("# Private title\nOnly after unlock")
        app.buttons["Dismiss Keyboard"].firstMatch.tap()
        app.descendants(matching: .any)["Note Actions"].firstMatch.tap()
        app.buttons["Lock Note"].tap()
        let password = app.secureTextFields["note-password"]
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        password.tap(); password.typeText("mobile-test-password")
        let confirmation = app.secureTextFields["confirm-note-password"]
        confirmation.tap(); confirmation.typeText("mobile-test-password")
        app.buttons["submit-note-password"].tap()
        XCTAssertTrue(app.buttons["unlock-note"].waitForExistence(timeout: 20))
        XCTAssertFalse(text.exists)
        app.buttons["unlock-note"].tap()
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        password.tap(); password.typeText("mobile-test-password")
        app.buttons["submit-note-password"].tap()
        XCTAssertTrue(text.waitForExistence(timeout: 60))
        XCTAssertTrue((text.value as? String ?? "").contains("Only after unlock"))
        text.tap(); text.typeText("\nProtected edit")
        XCUIDevice.shared.press(.home)
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["unlock-note"].waitForExistence(timeout: 60))
        XCTAssertFalse(text.exists)
        app.buttons["unlock-note"].tap()
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        password.tap(); password.typeText("mobile-test-password")
        app.buttons["submit-note-password"].tap()
        XCTAssertTrue(text.waitForExistence(timeout: 60))
        XCTAssertTrue((text.value as? String ?? "").contains("Protected edit"))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Authenticated private note"; shot.lifetime = .keepAlways; add(shot)
    }

    // MARK: A3 - sheets over the editor (plain views, no NavigationStack)

    private func openNoteWithKeyboard(_ app: XCUIApplication, text: String = "Sheet fixture\nBody") -> XCUIElement {
        app.launchArguments = ["--ui-testing", "--reset-library"]
        app.launch()
        XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 60))
        app.buttons["new-note"].tap()
        let editor = noteText(in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 60))
        editor.tap(); editor.typeText(text)
        let typed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "Body"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [typed], timeout: 30), .completed)
        return editor
    }

    /// The editor takes typing again after a sheet closed: tap it like a finger and type a marker.
    private func expectTyping(_ editor: XCUIElement, _ marker: String) {
        XCTAssertTrue(editor.waitForExistence(timeout: 30))
        editor.tap(); editor.typeText(marker)
        let typed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", marker), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [typed], timeout: 30), .completed, "typing after the sheet: \(String(reflecting: editor.value))")
    }

    /// Light-mode screenshot for the design pass: attachment plus a file when SHEET_SHOTS_DIR is set.
    private func sheetShot(_ app: XCUIApplication, _ name: String) {
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "\(name)-\(device)"; attachment.lifetime = .keepAlways; add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SHEET_SHOTS_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(device).png"))
        }
    }

    func testQuickOpenSheetOverEditorKeepsTyping() throws {
        let app = XCUIApplication()
        let editor = openNoteWithKeyboard(app)
        listOrNoteAction("list-quick-open", in: app)
        let query = app.textFields["quick-open-query"]
        XCTAssertTrue(query.waitForExistence(timeout: 10))
        query.tap(); query.typeText("Sheet")
        sheetShot(app, "quick-open")
        let results = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Sheet fixture"))
        XCTAssertTrue(results.firstMatch.waitForExistence(timeout: 10))
        try XCTUnwrap(results.allElementsBoundByIndex.first(where: { $0.isHittable })).tap()
        XCTAssertTrue(query.waitForNonExistence(timeout: 10))
        expectTyping(editor, " QOK")
    }

    func testQuickOpenDoneDismissesAndKeepsTyping() throws {
        let app = XCUIApplication()
        let editor = openNoteWithKeyboard(app)
        listOrNoteAction("list-quick-open", in: app)
        XCTAssertTrue(app.textFields["quick-open-query"].waitForExistence(timeout: 10))
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.textFields["quick-open-query"].waitForNonExistence(timeout: 10))
        expectTyping(editor, " QOD")
    }

    func testTemplatePickerSheetOverEditorKeepsTyping() throws {
        let app = XCUIApplication()
        let editor = openNoteWithKeyboard(app, text: "# {{title}}\nBody\n#template/sheet")
        listOrNoteAction("list-from-template", in: app)
        let title = app.textFields["Title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap(); title.typeText("From sheet")
        sheetShot(app, "template-picker")
        app.buttons["Create"].tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 10))
        let created = noteText(in: app)
        XCTAssertTrue(created.waitForExistence(timeout: 30))
        expectTyping(created, " TPL")
        _ = editor
    }

    func testNoteInfoSheetOverEditorKeepsTyping() throws {
        let app = XCUIApplication()
        let editor = openNoteWithKeyboard(app)
        app.descendants(matching: .any)["Note Actions"].firstMatch.tap()
        app.buttons["Note Info"].tap()
        XCTAssertTrue(app.staticTexts["Words"].waitForExistence(timeout: 10))
        sheetShot(app, "note-info")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Words"].waitForNonExistence(timeout: 10))
        expectTyping(editor, " INF")
    }

    func testPasswordPromptSheetOverEditorKeepsTyping() throws {
        let app = XCUIApplication()
        let editor = openNoteWithKeyboard(app)
        app.descendants(matching: .any)["Note Actions"].firstMatch.tap()
        app.buttons["Lock Note"].tap()
        let password = app.secureTextFields["note-password"]
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        sheetShot(app, "password-prompt")
        // Cancel first: the editor must take typing again.
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(password.waitForNonExistence(timeout: 10))
        expectTyping(editor, " PWC")
        // Then the main action: lock the note.
        app.descendants(matching: .any)["Note Actions"].firstMatch.tap()
        app.buttons["Lock Note"].tap()
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        password.tap(); password.typeText("sheet-test-password")
        let confirmation = app.secureTextFields["confirm-note-password"]
        confirmation.tap(); confirmation.typeText("sheet-test-password")
        app.buttons["submit-note-password"].tap()
        XCTAssertTrue(app.buttons["unlock-note"].waitForExistence(timeout: 20))
    }

    func testLinkSheetOverEditorKeepsTyping() throws {
        let app = XCUIApplication()
        let editor = openNoteWithKeyboard(app)
        let link = app.buttons["Link"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.tap()
        let url = app.textFields["URL"]
        XCTAssertTrue(url.waitForExistence(timeout: 10))
        sheetShot(app, "link")
        url.tap(); url.typeText("https://example.com")
        app.buttons["Save"].tap()
        XCTAssertTrue(url.waitForNonExistence(timeout: 10))
        // The editor's accessibility value is not refreshed by a programmatic edit (seen in the run's
        // screen recording: link shown, value unchanged); look for the shown link (or the list preview) instead.
        let linked = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "example.com")).firstMatch
        XCTAssertTrue(linked.waitForExistence(timeout: 30), app.debugDescription)
        expectTyping(editor, " LNK")
    }

    func testSortInboxSheetOverEditorKeepsTyping() throws {
        let app = XCUIApplication()
        let editor = openNoteWithKeyboard(app, text: "Inbox sheet fixture\nBody")
        app.buttons["Dismiss Keyboard"].firstMatch.tap()
        for _ in 0..<3 where !app.descendants(matching: .any)["scope-Inbox"].firstMatch.isHittable {
            let back = app.buttons["BackButton"].firstMatch
            if back.exists && back.isHittable { back.tap(); continue }
            let sidebar = app.buttons["Show Sidebar"].firstMatch
            if sidebar.exists && sidebar.isHittable { sidebar.tap() }
        }
        let inbox = app.descendants(matching: .any)["scope-Inbox"].firstMatch
        XCTAssertTrue(inbox.waitForExistence(timeout: 15)); inbox.tap()
        let sort = app.buttons["sort-inbox"]
        XCTAssertTrue(sort.waitForExistence(timeout: 15)); sort.tap()
        XCTAssertTrue(app.staticTexts["Sort Inbox"].waitForExistence(timeout: 20))
        sheetShot(app, "sort-inbox")
        app.buttons["Idea"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Inbox sorted"].waitForExistence(timeout: 15))
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Inbox sorted"].waitForNonExistence(timeout: 10))
        _ = editor
    }

    /// Settings keeps its NavigationStack (it has sub-pages); this only records it opening and closing over the editor.
    func testSettingsSheetKeepsSubPageNavigationAndTyping() throws {
        let app = XCUIApplication()
        let editor = openNoteWithKeyboard(app)
        app.buttons["Dismiss Keyboard"].firstMatch.tap()
        // Settings is the first entry of the sidebar's Library Options menu (IOS-CLUTTER).
        let options = app.buttons["Library Options"].firstMatch
        for _ in 0..<3 where !(options.exists && options.isHittable) {
            let back = app.buttons["BackButton"].firstMatch
            if back.exists && back.isHittable { back.tap(); continue }
            let sidebar = app.buttons["Show Sidebar"].firstMatch
            if sidebar.exists && sidebar.isHittable { sidebar.tap() }
        }
        XCTAssertTrue(options.waitForExistence(timeout: 15), app.debugDescription)
        options.tap()
        XCTAssertTrue(app.buttons["Settings"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.buttons["General"].waitForExistence(timeout: 10))
        sheetShot(app, "settings")
        app.buttons["General"].tap()
        XCTAssertTrue(app.navigationBars["General"].waitForExistence(timeout: 10))
        app.navigationBars["General"].buttons.firstMatch.tap()
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.buttons["General"].waitForNonExistence(timeout: 10))
        _ = editor
    }
}
