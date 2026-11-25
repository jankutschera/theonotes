// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import SwiftUI

/// The search field in the note-list header (inventory §2.5): an `NSSearchField`, so Esc, ↓ and
/// focus requests are handled through AppKit's field editor, where they reliably arrive.
struct NoteSearchField: NSViewRepresentable {
    @Binding var text: String
    /// Each change makes the field first responder (⇧⌘F).
    let focusRequest: Int
    /// ↓: move to the results.
    let onMoveDown: () -> Void
    /// Esc in an empty field: leave it.
    let onLeave: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search Notes"
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        field.setAccessibilityIdentifier("noteSearchField")
        field.stringValue = text
        context.coordinator.focusRequest = focusRequest
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            // After SwiftUI's update: the field may only now be in a (re-shown) window.
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NoteSearchField
        var focusRequest = 0

        init(parent: NoteSearchField) {
            self.parent = parent
        }

        @objc func searchChanged(_ sender: NSSearchField) {
            setText(sender.stringValue)
        }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { setText(field.stringValue) }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            handle(selector, in: control as? NSSearchField)
        }

        /// ↓ moves to the results; Esc clears the field, or leaves it when it is empty.
        func handle(_ selector: Selector, in field: NSSearchField?) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveDown()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                if parent.text.isEmpty {
                    parent.onLeave()
                } else {
                    field?.stringValue = ""
                    setText("")
                }
                return true
            default:
                return false
            }
        }

        private func setText(_ value: String) {
            if parent.text != value { parent.text = value }
        }
    }
}
