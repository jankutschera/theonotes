// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import XCTest

/// Opt-in native audits on disposable simulators; these do not prove VoiceOver speech/rotor behavior.
@MainActor
final class NativeAccessibilityAuditUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if targetEnvironment(simulator)
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BAERCHEN_ACCESSIBILITY_AUDIT"] == "1",
                          "Enable native audits only on a dedicated disposable simulator.")
        #else
        throw XCTSkip("Accessibility audit fixtures are restricted to disposable simulators.")
        #endif
    }

    func testLibraryAccessibility() throws {
        let app = fixtureApp()
        XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 60))
        try audit(app, screen: "Library")
    }

    func testEditorAccessibility() throws {
        let app = fixtureApp()
        try createNote(in: app, text: "# Accessibility fixture\nA readable paragraph.\n\n- [ ] A task\n\n## Second heading\nMore text.")
        app.buttons["Dismiss Keyboard"].firstMatch.tap()
        try audit(app, screen: "Editor")
    }

    func testLockedNoteAccessibility() throws {
        let app = try lockedFixtureApp()
        try audit(app, screen: "Locked note")
    }

    // These focused checks isolate the observed selected-row color defect. The
    // all-category acceptance audits above still report every search issue.
    func testSelectedNoteRowContrast() throws {
        let app = fixtureApp()
        try createNote(in: app, text: "# Accessibility fixture\nA readable paragraph.")
        app.buttons["Dismiss Keyboard"].firstMatch.tap()
        _ = selectedFixtureRow(in: app, title: "Accessibility fixture", subtitle: "A readable paragraph.")
        try audit(app, screen: "Selected note row contrast", types: .contrast)
    }

    func testSelectedLockedNoteRowContrast() throws {
        let app = try lockedFixtureApp()
        _ = selectedFixtureRow(in: app, title: "Protected fixture", subtitle: "Locked note")
        try audit(app, screen: "Selected locked note row contrast", types: .contrast)
    }

    func testSearchAtMaximumDynamicType() throws {
        let title = "Search fixture"
        let subtitle = "Visible sample."
        let text = "# \(title)\n\(subtitle)"
        let baseline = fixtureApp(contentSize: "UICTContentSizeCategoryL")
        try createNote(in: baseline, text: text)
        baseline.buttons["Dismiss Keyboard"].firstMatch.tap()
        let baselineRow = selectedFixtureRow(in: baseline, title: title, subtitle: subtitle)
        let baselineHeight = baselineRow.staticTexts[subtitle].frame.height
        XCTAssertGreaterThan(baselineHeight, 0)
        attachScreen(baseline, name: "Search baseline Large")
        baseline.terminate()

        // App launch preference override, not a simulator-wide Settings change.
        // Require measured text growth so a silently ignored override cannot pass.
        let app = fixtureApp(contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
        try createNote(in: app, text: text)
        app.buttons["Dismiss Keyboard"].firstMatch.tap()
        let row = selectedFixtureRow(in: app, title: title, subtitle: subtitle)
        let maximumHeight = row.staticTexts[subtitle].frame.height
        let sizes = XCTAttachment(string: "Launch override: Large -> AccessibilityXXXL (AX5)\nSubtitle height: \(baselineHeight) -> \(maximumHeight) points")
        sizes.name = "Actual Dynamic Type text growth"; sizes.lifetime = .keepAlways; add(sizes)
        XCTAssertGreaterThan(maximumHeight, baselineHeight * 1.5,
                             "Maximum-size launch must visibly enlarge real row text before search acceptance.")

        let search = app.searchFields["Search notes"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        XCTAssertTrue(search.isHittable)
        XCTAssertEqual(search.placeholderValue, "Search notes")
        let placeholderIssues = try recordAudit(app, screen: "AX5 search placeholder", types: [.textClipped, .dynamicType])
        search.tap(); search.typeText("fixture")
        let entered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "fixture"), object: search)
        XCTAssertEqual(XCTWaiter.wait(for: [entered], timeout: 10), .completed)
        XCTAssertTrue(app.cells.containing(.staticText, identifier: title).firstMatch.waitForExistence(timeout: 10))
        let queryIssues = try recordAudit(app, screen: "AX5 search typed query", types: [.textClipped, .dynamicType])
        // Capture both rendered states before asserting. Predictive clipping
        // remains a failure; screenshots distinguish it from actual AX5 clipping.
        let issues = placeholderIssues + queryIssues
        XCTAssertTrue(issues.isEmpty, "Maximum Dynamic Type search: \(issues.joined(separator: "\n\n"))")
    }

    private func lockedFixtureApp() throws -> XCUIApplication {
        let app = fixtureApp()
        try createNote(in: app, text: "# Protected fixture\nConfidential fixture body")
        app.buttons["Dismiss Keyboard"].firstMatch.tap()
        app.descendants(matching: .any)["Note Actions"].firstMatch.tap()
        app.buttons["Lock Note"].tap()
        let password = app.secureTextFields["note-password"]
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        password.tap(); password.typeText("audit-test-password")
        let confirmation = app.secureTextFields["confirm-note-password"]
        confirmation.tap(); confirmation.typeText("audit-test-password")
        app.buttons["submit-note-password"].tap()
        XCTAssertTrue(app.buttons["unlock-note"].waitForExistence(timeout: 20))
        XCTAssertFalse(noteText(in: app).exists)
        XCTAssertFalse(app.staticTexts["Confidential fixture body"].exists)
        return app
    }

    private func fixtureApp(contentSize: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-library"]
        if let contentSize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize]
        }
        app.launch()
        return app
    }

    private func selectedFixtureRow(in app: XCUIApplication, title: String, subtitle: String) -> XCUIElement {
        let row = app.cells.containing(.staticText, identifier: title).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Run on an iPad with the note list visible.")
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 10), .completed,
                       "The regression requires the native selected background, not merely an open editor.")
        XCTAssertTrue(row.staticTexts[title].isHittable)
        XCTAssertTrue(row.staticTexts[subtitle].waitForExistence(timeout: 10))
        XCTAssertTrue(row.staticTexts[subtitle].isHittable)
        let date = row.staticTexts.matching(NSPredicate(format: "label != %@ AND label != %@", title, subtitle)).firstMatch
        XCTAssertTrue(date.exists, "The date must be rendered for its contrast to be audited.")
        XCTAssertTrue(date.isHittable)
        XCTAssertFalse(date.label.isEmpty)
        return row
    }

    private func createNote(in app: XCUIApplication, text: String) throws {
        XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 60))
        app.buttons["new-note"].tap()
        let editor = noteText(in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 60))
        editor.tap(); editor.typeText(text)
        // The setup check needs the visible body, not Markdown markers that the
        // rich accessibility tree may expose as separate heading/task elements.
        let body = String(text.split(separator: "\n").last ?? "")
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", body), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 10), .completed,
                       "Typed fixture body unavailable: \(String(reflecting: editor.value))")
    }

    private func noteText(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Note text")).firstMatch
    }

    private func audit(_ app: XCUIApplication, screen: String, types: XCUIAccessibilityAuditType = .all) throws {
        let issues = try recordAudit(app, screen: screen, types: types)
        XCTAssertTrue(issues.isEmpty, "\(screen): \(issues.count) native accessibility issues.\n\(issues.joined(separator: "\n\n"))")
    }

    private func recordAudit(_ app: XCUIApplication, screen: String, types: XCUIAccessibilityAuditType) throws -> [String] {
        var issues: [String] = []
        try app.performAccessibilityAudit(for: types) { issue in
            issues.append("Type: \(issue.auditType.rawValue)\n\(issue.compactDescription)\n\(issue.detailedDescription)\nElement: \(issue.element?.debugDescription ?? "not supplied")")
            // Collect every report, then fail below if any was found. Nothing is ignored.
            return true
        }
        let report = XCTAttachment(string: issues.joined(separator: "\n\n"))
        report.name = "\(screen) native audit issues"; report.lifetime = .keepAlways; add(report)
        attachScreen(app, name: "\(screen) audited screen")
        return issues
    }

    private func attachScreen(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "\(name) accessibility tree"; tree.lifetime = .keepAlways; add(tree)
    }
}
