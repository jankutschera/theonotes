// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import SwiftUI

/// The field every Note Password is typed into: an `NSSecureTextField` whose field editor
/// keeps no undo history and which asks for no credential autofill.
///
/// Apple's documentation, as far as it goes: `NSTextField` adopts `NSTextContent`, whose
/// `contentType` is how a field opts into AutoFill (`.password`, `.newPassword`); `nil` asks for
/// none, and that is set explicitly. A field editor is an `NSTextView`, whose `allowsUndo` is
/// documented as whether the view supports undo; it is turned off whenever this field begins
/// editing, and the window's undo stack is emptied when editing ends. SwiftUI's `SecureField`
/// exposes neither, so the sheets and the lock view use this wrapper.
final class PasswordNSTextField: NSSecureTextField {
    init(label: String) {
        super.init(frame: .zero)
        placeholderString = label
        setAccessibilityLabel(label)
        contentType = nil
        isAutomaticTextCompletionEnabled = false
        allowsEditingTextAttributes = false
        importsGraphics = false
        bezelStyle = .roundedBezel
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 22) }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        disableUndo()
        return accepted
    }

    override func textDidBeginEditing(_ notification: Notification) {
        super.textDidBeginEditing(notification)
        disableUndo()
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        forgetUndo()
    }

    private func disableUndo() {
        guard let editor = currentEditor() as? NSTextView else { return }
        editor.allowsUndo = false
        editor.undoManager?.removeAllActions()
    }

    private func forgetUndo() {
        window?.undoManager?.removeAllActions(withTarget: self)
        window?.undoManager?.removeAllActions()
    }
}

/// `PasswordNSTextField` for SwiftUI, bound to a string the model owns (and clears).
struct PasswordTextField: NSViewRepresentable {
    let label: String
    @Binding var text: String
    var focusOnAppear = false
    var isEnabled = true
    var onSubmit: () -> Void = {}

    func makeNSView(context: Context) -> PasswordNSTextField {
        let field = PasswordNSTextField(label: label)
        field.delegate = context.coordinator
        if focusOnAppear {
            DispatchQueue.main.async { [weak field] in
                guard let field, let window = field.window else { return }
                window.makeFirstResponder(field)
            }
        }
        return field
    }

    func updateNSView(_ field: PasswordNSTextField, context: Context) {
        context.coordinator.parent = self
        sync(field)
    }

    /// Brings the field in step with the model: a cleared value empties it.
    func sync(_ field: PasswordNSTextField) {
        if field.stringValue != text { field.stringValue = text }
        if field.isEnabled != isEnabled { field.isEnabled = isEnabled }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PasswordTextField
        init(_ parent: PasswordTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            parent.onSubmit()
            return true
        }
    }
}
