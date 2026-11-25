// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import UIKit
import WebKit

/// A SwiftUI keyboard shortcut can outlive the pane that installed it. Resolve ownership when
/// the command runs, using the actual UIKit responder rather than the last selected note.
@MainActor enum MobileShortcutRouter {
    static func newCapture(source: CaptureSource, library: MobileLibrary) async throws -> String {
        try await library.captureThought(source: source)
    }
    enum Destination { case editor, textInput, library }

    static func firstResponder(editorView: UIView) -> UIResponder? {
        let window = editorView.window ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        guard let window else { return nil }
        return findResponder(in: window)
    }
    private static func findResponder(in view: UIView) -> UIResponder? {
        if view.isFirstResponder { return view }
        for child in view.subviews { if let found = findResponder(in: child) { return found } }
        return nil
    }
    static func destination(responder: UIResponder?, editorView: UIView) -> Destination {
        if let view = responder as? UIView, view === editorView || view.isDescendant(of: editorView) { return .editor }
        if responder is any UITextInput { return .textInput }
        return .library
    }
    static func selectAll(responder: UIResponder?, editorView: UIView, editor: () -> Void, library: () -> Void) {
        switch destination(responder: responder, editorView: editorView) {
        case .editor: editor()
        case .textInput:
            guard let input = responder as? any UITextInput else { return }
            input.selectedTextRange = input.textRange(from: input.beginningOfDocument, to: input.endOfDocument)
        case .library: library()
        }
    }
    static func selectEditor(in webView: WKWebView, command: () -> Void) async {
        // UIKit sees the same WKContentView for CodeMirror and its HTML find fields.
        let fieldSelected = try? await webView.evaluateJavaScript("(() => { const el = document.activeElement; if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) { el.select(); return true; } return false; })()") as? Bool
        if fieldSelected != true { command() }
    }
    static func find(responder: UIResponder?, editorView: UIView, editor: () -> Void, library: () -> Void) {
        if destination(responder: responder, editorView: editorView) == .editor { editor() }
        else { library() }
    }
    /// Scene-level search has no dependency on a row or a nonempty result set.
    static func searchNotes(canActivate: Bool, focus: () -> Void) {
        guard canActivate else { return }
        focus()
    }
    /// Hardware Files action only. Explicit menu taps keep their existing path.
    /// WKContentView is also first responder for HTML find fields, so ask the page
    /// before capturing a note origin and fail closed if that query cannot complete.
    static func insertFile(responder: UIResponder?, editorView: WKWebView,
                           stillCurrent: @MainActor () -> Bool,
                           action: @MainActor () -> Void) async {
        guard stillCurrent() else { return }
        switch destination(responder: responder, editorView: editorView) {
        case .textInput: return
        case .editor:
            let field = try? await editorView.evaluateJavaScript("(() => { const el = document.activeElement; return el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement || el instanceof HTMLSelectElement; })()") as? Bool
            guard field == false else { return }
        case .library: break
        }
        guard stillCurrent() else { return }
        action()
    }
    static func trashSelection(responder: UIResponder?, editorView: UIView, action: () -> Void) {
        guard destination(responder: responder, editorView: editorView) == .library else { return }
        action()
    }
}
