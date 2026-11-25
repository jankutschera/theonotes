// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Testing
import UIKit
import TheoNotesCore
import WebKit
@testable import BaerchenIOS

@Suite @MainActor struct MobileShortcutRouterTests {
    @Test func editorSelectAllAndFindNeverSelectOrSearchTheLibrary() {
        let editor = UIView(), input = UITextView()
        editor.addSubview(input)
        var selectedEditor = 0, foundEditor = 0, changedLibrary = 0
        MobileShortcutRouter.selectAll(responder: input, editorView: editor,
            editor: { selectedEditor += 1 }, library: { changedLibrary += 1 })
        MobileShortcutRouter.find(responder: input, editorView: editor,
            editor: { foundEditor += 1 }, library: { changedLibrary += 1 })
        MobileShortcutRouter.trashSelection(responder: input, editorView: editor) { changedLibrary += 1 }
        #expect(selectedEditor == 1 && foundEditor == 1)
        #expect(changedLibrary == 0)
    }
    @Test func nativeSearchFieldSelectsItsTextAndNeverTouchesNoteSelection() {
        let editor = UIView(), field = UITextField()
        field.text = "Search 👩‍💻 text"
        var changedNotes = 0
        MobileShortcutRouter.selectAll(responder: field, editorView: editor,
            editor: { changedNotes += 1 }, library: { changedNotes += 1 })
        let range = field.selectedTextRange
        #expect(range.map { field.offset(from: $0.start, to: $0.end) } == field.text?.utf16.count)
        MobileShortcutRouter.trashSelection(responder: field, editorView: editor) { changedNotes += 1 }
        #expect(changedNotes == 0)
    }
    @Test func webFindFieldSelectsItsOwnTextInsteadOfTheNote() async throws {
        let webView = WKWebView()
        webView.loadHTMLString("<input id='search' value='Find 👩‍💻 text'>", baseURL: nil)
        var ready = false
        for _ in 0..<200 {
            ready = (try? await webView.evaluateJavaScript("document.getElementById('search') !== null")) as? Bool == true
            if ready { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(ready)
        _ = try await webView.evaluateJavaScript("document.getElementById('search').focus()")
        var noteCommands = 0
        await MobileShortcutRouter.selectEditor(in: webView) { noteCommands += 1 }
        let selected = try await webView.evaluateJavaScript("(() => { const el = document.getElementById('search'); return el.selectionStart === 0 && el.selectionEnd === el.value.length; })()") as? Bool
        #expect(selected == true)
        #expect(noteCommands == 0)
    }

    @Test func listContextReceivesLibraryCommandsIncludingExplicitSelectionTrash() {
        let editor = UIView(), list = UIButton()
        var selected = false, searched = false, trashed = false, editorCommands = 0
        MobileShortcutRouter.selectAll(responder: list, editorView: editor,
            editor: { editorCommands += 1 }, library: { selected = true })
        MobileShortcutRouter.find(responder: list, editorView: editor,
            editor: { editorCommands += 1 }, library: { searched = true })
        MobileShortcutRouter.trashSelection(responder: list, editorView: editor) { trashed = true }
        #expect(selected && searched && trashed)
        #expect(editorCommands == 0)
    }
    @Test func emptySceneStillRoutesSearchNotesWithoutChangingSelection() throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let navigation = MobileSceneNavigation()
        #expect(library.items.isEmpty)
        var focused = false
        MobileShortcutRouter.searchNotes(canActivate: true) { focused = true }
        #expect(focused && navigation.selectedID == nil && library.selectedID == nil)
        focused = false
        MobileShortcutRouter.searchNotes(canActivate: false) { focused = true }
        #expect(!focused)
    }

    @Test func filesChordRejectsNativeFieldButAllowsListAndDropsLateAdmission() async {
        let web = WKWebView(), field = UITextField(), list = UIButton()
        var opened = 0
        await MobileShortcutRouter.insertFile(responder: field, editorView: web, stillCurrent: { true }) { opened += 1 }
        #expect(opened == 0)
        await MobileShortcutRouter.insertFile(responder: list, editorView: web, stillCurrent: { true }) { opened += 1 }
        #expect(opened == 1)
        await MobileShortcutRouter.insertFile(responder: list, editorView: web, stillCurrent: { false }) { opened += 1 }
        #expect(opened == 1)
    }

    @Test func filesChordRejectsHTMLFindInputButKeepsEditorPath() async throws {
        let web = WKWebView()
        web.loadHTMLString("<input id='find' value='search'><div id='note' contenteditable='true'>note</div>", baseURL: nil)
        var ready = false
        for _ in 0..<200 {
            if (try? await web.evaluateJavaScript("document.getElementById('note') !== null")) as? Bool == true { ready = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(ready)
        _ = try await web.evaluateJavaScript("document.getElementById('find').focus()")
        var opened = 0
        await MobileShortcutRouter.insertFile(responder: web, editorView: web, stillCurrent: { true }) { opened += 1 }
        #expect(opened == 0)
        #expect(try await web.evaluateJavaScript("document.activeElement.id") as? String == "find")
        _ = try await web.evaluateJavaScript("document.getElementById('note').focus()")
        await MobileShortcutRouter.insertFile(responder: web, editorView: web, stillCurrent: { true }) { opened += 1 }
        #expect(opened == 1)
        var admissionChecks = 0
        await MobileShortcutRouter.insertFile(responder: web, editorView: web, stillCurrent: {
            admissionChecks += 1
            return admissionChecks == 1 // Focus/privacy changed during the asynchronous page check.
        }) { opened += 1 }
        #expect(admissionChecks == 2 && opened == 1)
        #expect(try await web.evaluateJavaScript("document.getElementById('note').textContent") as? String == "note")
    }

}
