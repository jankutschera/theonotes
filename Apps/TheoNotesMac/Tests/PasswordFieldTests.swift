// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import SwiftUI
import Testing
@testable import TheoNotes

/// M9 Mac task 5, fix round 1: the Note Password fields are secure AppKit fields with no undo and
/// no credential autofill, and every way out of a sheet leaves them empty.
@MainActor
@Suite struct PasswordFieldTests {
    private func hosted(_ field: PasswordNSTextField) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        field.frame = NSRect(x: 10, y: 10, width: 200, height: 24)
        window.contentView!.addSubview(field)
        window.orderFront(nil)
        return window
    }

    @Test func theFieldIsASecureTextFieldWithNoAutofillAndNoCompletion() {
        let field = PasswordNSTextField(label: "Password")
        #expect(field is NSSecureTextField)
        #expect(field.contentType == nil, "no .password / .newPassword: no credential autofill or saving")
        #expect(!field.isAutomaticTextCompletionEnabled)
        #expect(!field.allowsEditingTextAttributes)
        #expect(field.placeholderString == "Password")
        #expect(field.accessibilityLabel() == "Password")
    }

    @Test func theFieldEditorAllowsNoUndoAndKeepsNoUndoHistory() throws {
        let field = PasswordNSTextField(label: "Password")
        let window = hosted(field)
        defer { window.close() }

        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(!editor.allowsUndo)
        editor.insertText("zqxtyped", replacementRange: NSRange(location: 0, length: 0))
        #expect(field.stringValue == "zqxtyped")
        #expect(window.undoManager?.canUndo != true)
        #expect(editor.undoManager?.canUndo != true)

        #expect(window.makeFirstResponder(nil))
        #expect(window.undoManager?.canUndo != true)
    }

    @Test func clearingTheBindingEmptiesTheField() {
        var value = "typed"
        let binding = Binding(get: { value }, set: { value = $0 })
        let field = PasswordNSTextField(label: "Password")
        let representable = PasswordTextField(label: "Password", text: binding)
        field.stringValue = "typed"
        value = ""
        representable.sync(field)
        #expect(field.stringValue.isEmpty)
    }

    @Test func cancellingASheetEmptiesEveryField() throws {
        let fx = try PrivacyFixture()
        defer { fx.destroy() }
        let sheet = PasswordSheetModel(kind: .change, vault: fx.vault)
        sheet.password = "a"
        sheet.newPassword = "b"
        sheet.confirmation = "b"
        sheet.cancel()
        #expect(sheet.password.isEmpty && sheet.newPassword.isEmpty && sheet.confirmation.isEmpty)
    }

    @Test func aWrongAttemptEmptiesEveryFieldOfEverySheet() async throws {
        let fx = try PrivacyFixture()
        defer { fx.destroy() }
        try await fx.makePassword()
        fx.vault.relock()
        let unlock = PasswordSheetModel(kind: .unlock(.lockNotes), vault: fx.vault)
        unlock.password = "wrong"
        await unlock.submit()
        #expect(unlock.password.isEmpty)
        let change = PasswordSheetModel(kind: .change, vault: fx.vault)
        change.password = "wrong"
        change.newPassword = "fresh"
        change.confirmation = "fresh"
        await change.submit()
        #expect(change.password.isEmpty && change.newPassword.isEmpty && change.confirmation.isEmpty)
        #expect(change.errorMessage == LockedNoteModel.wrongPasswordMessage)
    }
}
