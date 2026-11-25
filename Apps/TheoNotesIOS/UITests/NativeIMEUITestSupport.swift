// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import XCTest

/// Native-keyboard acceptance helpers; note input always uses actual XCUI key taps.
@MainActor
class NativeIMEUITestCase: XCTestCase {
    func openInstalledKeyboards(in settings: XCUIApplication) throws {
        settings.launch()
        if let cancel = settings.buttons.matching(identifier: "Cancel").allElementsBoundByIndex.first(where: { $0.isHittable }) {
            cancel.tap()
        }
        let general = settings.buttons["com.apple.settings.general"]
        for _ in 0..<6 where !general.isHittable {
            guard let back = settings.navigationBars.buttons.matching(identifier: "BackButton")
                .allElementsBoundByIndex.first(where: { $0.isHittable }) else { break }
            back.tap()
        }
        try require(general, in: settings, named: "Settings General", timeout: 20).tap()
        let keyboard = settings.buttons["com.apple.settings.general.keyboard"]
        for _ in 0..<4 where !keyboard.isHittable { settings.swipeUp() }
        try require(keyboard, in: settings, named: "Settings Keyboard").tap()
        try require(settings.cells["KEYBOARDS"], in: settings, named: "installed Keyboards row").tap()
    }

    /// Settings setup only. Note composition below still uses individual native key taps.
    func searchAvailableKeyboards(_ language: String, in settings: XCUIApplication) throws {
        let add = settings.cells["AddNewKeyboard"]
        // iOS 27.1 exposes the actionable control inside a cell whose own hit-test can fail.
        let addButton = add.buttons.firstMatch
        if addButton.waitForExistence(timeout: 5) {
            try require(addButton, in: settings, named: "Add New Keyboard button").tap()
        } else {
            try require(add, in: settings, named: "Add New Keyboard").tap()
        }
        let search = settings.searchFields["Search"].firstMatch
        // Newer Settings initially exposes a toolbar Search button, not a search field.
        if !search.exists {
            try require(settings.buttons["Search"].firstMatch, in: settings,
                        named: "activate keyboard search").tap()
        }
        try require(search, in: settings, named: "keyboard search").tap()
        let clear = search.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Clear")).firstMatch
        if clear.exists && clear.isHittable { clear.tap() }
        // The setup screen can retain the previous language query between test cases.
        if let existing = search.value as? String, !existing.isEmpty, existing != search.placeholderValue {
            search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        search.typeText(language) // ASCII setup query only; never note input.
        let entered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", language), object: search)
        guard XCTWaiter.wait(for: [entered], timeout: 10) == .completed else {
            capture("Keyboard search query did not match " + language, in: settings)
            let tree = XCTAttachment(string: settings.debugDescription)
            tree.name = "Native keyboard search query"; tree.lifetime = .keepAlways; self.add(tree)
            XCTFail("Settings keyboard search did not contain the exact setup query: \(language)")
            throw NativeControlUnavailable(name: "exact keyboard search query")
        }
    }

    func noteText(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Note text")).firstMatch
    }

    func tapLetter(_ letter: String, in app: XCUIApplication) throws {
        let key = app.keys.matching(NSPredicate(format: "label ==[c] %@", letter)).firstMatch
        try require(key, in: app, named: "native software key \(letter)", timeout: 5).tap()
    }

    func tapDelete(in app: XCUIApplication) throws {
        try require(app.keys["delete"], in: app, named: "native software delete key", timeout: 5).tap()
    }

    func assertValue(_ expected: String, in editor: XCUIElement) {
        // WK AX exposes only an empty CodeMirror line as one structural newline.
        let expectedAX = expected.isEmpty ? "\n" : expected
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expectedAX), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 5), .completed,
                       "Expected exact AX value \(String(reflecting: expectedAX)), got \(String(reflecting: editor.value as? String))")
        let changes = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", expectedAX), object: editor)
        changes.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [changes], timeout: 0.3), .completed)
        XCTAssertEqual(editor.value as? String, expectedAX, "Fresh AX read after stability interval must match exactly")
    }

    func require(_ element: XCUIElement, in app: XCUIApplication, named name: String,
                 timeout: TimeInterval = 10) throws -> XCUIElement {
        if !element.exists { _ = element.waitForExistence(timeout: timeout) }
        if element.exists && !element.isHittable {
            let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: element)
            _ = XCTWaiter.wait(for: [hittable], timeout: timeout)
        }
        guard element.exists && element.isHittable else {
            capture("Unavailable native control: \(name)", in: app)
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "Native tree missing \(name)"; tree.lifetime = .keepAlways; add(tree)
            XCTFail("Required native control unavailable: \(name). See native screenshot and accessibility-tree attachments.")
            throw NativeControlUnavailable(name: name)
        }
        return element
    }

    func capture(_ name: String, in app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    private struct NativeControlUnavailable: Error { let name: String }
}
