// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import XCTest

/// Actual VoiceOver speech, restricted to an explicitly opted-in disposable simulator.
/// This exercises linear focus navigation; the SDK does not expose rotor selection.
@MainActor
final class VoiceOverPrivacyUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if targetEnvironment(simulator)
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BAERCHEN_VOICEOVER_ACCEPTANCE"] == "1",
                          "VoiceOver acceptance requires a dedicated disposable simulator.")
        #else
        throw XCTSkip("VoiceOver fixtures never run on physical devices or a personal library.")
        #endif
    }

    /// A separate, zero-typing probe distinguishes service capability from fixture timing.
    /// This does not establish a protected-note workflow or rotor acceptance.
    func testVoiceOverServiceProducesNavigationSpeech() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("Requires iOS 27 VoiceOver service.") }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 60))
        let service = XCUIDevice.shared.voiceOverService
        try XCTSkipIf(service.isEnabled, "Preserve an already enabled VoiceOver session.")
        disableVoiceOverAtTeardown(service)
        try service.enable()
        XCTAssertTrue(service.isEnabled)
        var speech: [String] = []
        defer { attach("Capability probe actual VoiceOver speech", text: speech.joined(separator: "\n")) }
        for _ in 0..<3 {
            let utterance = try service.moveForward().utterance
            speech.append(utterance)
            XCTAssertFalse(utterance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    func testProtectedBodySpeechAcrossFailedUnlockAndRelock() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("Requires iOS 27 VoiceOver service.") }
        let service = XCUIDevice.shared.voiceOverService
        // Do not take ownership of a service already enabled by another session.
        try XCTSkipIf(service.isEnabled, "VoiceOver is already enabled; preserve its owner's session.")
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-library"]
        app.launch()
        XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 60))
        app.buttons["new-note"].tap()
        let editor = noteText(in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 60))
        let secret = "Violet lantern confidential body"
        // The service cuts each utterance after about 64 characters ("Note text # VoiceOver private fixture\nViolet lantern
        // confidentia"), so speech is checked for the body's first words: a leak shows them even when the rest is cut.
        let spoken = "Violet lantern"
        editor.tap(); editor.typeText("# VoiceOver private fixture\n" + secret)
        assertBody(secret, in: editor)
        app.buttons["Dismiss Keyboard"].firstMatch.tap()
        app.descendants(matching: .any)["Note Actions"].firstMatch.tap()
        app.buttons["Lock Note"].tap()
        let password = app.secureTextFields["note-password"]
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        password.tap(); password.typeText("voiceover-fixture-password")
        let confirmation = app.secureTextFields["confirm-note-password"]
        confirmation.tap(); confirmation.typeText("voiceover-fixture-password")
        app.buttons["submit-note-password"].tap()
        XCTAssertTrue(app.buttons["unlock-note"].waitForExistence(timeout: 20))
        XCTAssertFalse(editor.exists)

        disableVoiceOverAtTeardown(service)
        do { try service.enable() }
        catch {
            attach("VoiceOver service unavailable", text: String(describing: error))
            throw XCTSkip("SDK VoiceOver service could not enable on this simulator: \(error)")
        }
        XCTAssertTrue(service.isEnabled)
        try speakUntil(service, phase: "Locked note", contains: "Unlock Note", forbidden: spoken)
        // With VoiceOver on, one tap only moves the VoiceOver cursor; a double tap activates, as a VoiceOver user does.

        app.buttons["unlock-note"].doubleTap()
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        password.doubleTap(); password.typeText("incorrect-fixture-password")
        app.buttons["submit-note-password"].doubleTap()
        XCTAssertTrue(app.staticTexts["password-error"].waitForExistence(timeout: 20))
        XCTAssertFalse(editor.exists)
        try speakUntil(service, phase: "Wrong password", contains: "That password did not unlock your notes", forbidden: spoken)

        // Cancel preserves the failed-unlock privacy boundary and gives a clean secure field.
        app.buttons["Cancel"].doubleTap()
        app.buttons["unlock-note"].doubleTap()
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        password.doubleTap(); password.typeText("voiceover-fixture-password")
        app.buttons["submit-note-password"].doubleTap()
        XCTAssertTrue(editor.waitForExistence(timeout: 60))
        assertBody(secret, in: editor)
        try speakUntil(service, phase: "Unlocked note", contains: spoken)

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["unlock-note"].waitForExistence(timeout: 30))
        XCTAssertFalse(editor.exists)
        try speakUntil(service, phase: "Relocked after background", contains: "Unlock Note", forbidden: spoken)
    }

    /// A failed assertion stops the test by an exception (continueAfterFailure is false), which skips a Swift `defer`:
    /// the final 1.1 pass left VoiceOver on in the shared simulators that way. A teardown block always runs.
    @available(iOS 27.0, *)
    private func disableVoiceOverAtTeardown(_ service: XCUIVoiceOverService) {
        addTeardownBlock {
            do {
                if service.isEnabled { try service.disable() }
                XCTAssertFalse(service.isEnabled, "VoiceOver must be disabled after the owned test session")
            } catch { XCTFail("Could not restore VoiceOver to disabled: \(error)") }
        }
    }

    private func noteText(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Note text")).firstMatch
    }

    private func assertBody(_ body: String, in editor: XCUIElement) {
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", body), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 10), .completed,
                       "Actual editor value: \(String(reflecting: editor.value))")
    }

    @available(iOS 27.0, *)
    private func speakUntil(_ service: XCUIVoiceOverService, phase: String,
                            contains expected: String, forbidden: String? = nil) throws {
        var utterances: [String] = []
        // Attached before any failure: a failed assertion stops the test before a `defer` would run.
        let record = { self.attach(phase + " actual VoiceOver speech", text: utterances.joined(separator: "\n")) }
        let initial: XCUIVoiceOverService.Output
        do { initial = try service.currentSpeech() }
        catch {
            let failure = error as NSError
            // XCUIVoiceOverServiceError.h documents code 3 as NoSpeech. Enabling the
            // service need not establish a focused element, so explicitly move focus.
            guard failure.domain == XCUIVoiceOverServiceErrorDomain, failure.code == 3 else { throw error }
            attach(phase + " initial focus", text: "currentSpeech returned documented NoSpeech; moving forward to establish focus.")
            initial = try service.moveForward()
        }
        for index in 0..<60 {
            let speech = try (index == 0 ? initial : service.moveForward()).utterance
            utterances.append(speech)
            if let forbidden, speech.contains(forbidden) { record(); XCTFail("Protected body spoken during \(phase)") }
            if speech.localizedCaseInsensitiveContains(expected) { record(); return }
        }
        record()
        XCTFail("VoiceOver did not speak \(String(reflecting: expected)) during \(phase). See utterance attachment.")
    }

    private func attach(_ name: String, text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
