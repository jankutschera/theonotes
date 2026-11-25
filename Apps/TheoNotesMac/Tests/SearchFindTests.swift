// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import SwiftUI
import Testing
@testable import TheoNotes

/// Opening a search result highlights its matches in the editor (bridge `searchHighlight`),
/// Edit ▸ Find ▸ Find Next / Previous (⌘G / ⇧⌘G), and the search field (⇧⌘F, ↓, Esc).
@MainActor
@Suite struct SearchFindTests {
    @MainActor
    final class Env {
        let root: URL
        let suiteName = "TheoNotesSearchFindTests-\(UUID().uuidString)"
        let environment: AppEnvironment
        let page = FakeEditorPage()
        let editor: EditorBridgeController
        let state: MainWindowState

        init(ready: Bool = true) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("TheoNotesSearchFind-\(UUID().uuidString)", isDirectory: true)
            environment = try AppEnvironment(paths: AppPaths(root: root))
            editor = EditorBridgeController(
                environment: environment, page: page, openExternally: { _ in }, checksumInterval: nil
            )
            if ready { _ = editor.handle(.ready(version: EditorBridge.version)) }
            state = MainWindowState(
                environment: environment, defaults: UserDefaults(suiteName: suiteName)!, editor: editor
            )
        }

        deinit {
            UserDefaults().removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        var store: NoteStore { environment.store }
        var model: LibraryModel { state.model }

        /// The messages after the last `loadNote` of `noteId`, that one included.
        func deliveredSinceLoad(of noteId: String) -> [HostToEditorMessage] {
            guard let index = page.delivered.lastIndex(where: {
                if case .loadNote(let id, _, _, _, _, _, _) = $0 { id == noteId } else { false }
            }) else { return [] }
            return Array(page.delivered[index...])
        }

        var highlights: [HostToEditorMessage] { page.delivered.filter(isHighlight) }

        var commands: [EditorCommandName] {
            page.delivered.compactMap { if case .applyCommand(let name, _) = $0 { name } else { nil } }
        }
    }

    private static func isHighlight(_ message: HostToEditorMessage) -> Bool {
        if case .searchHighlight = message { true } else { false }
    }

    private func isHighlight(_ message: HostToEditorMessage) -> Bool { Self.isHighlight(message) }

    // MARK: - Delivery

    @Test func testHighlightIsSentRightAfterTheLoadNoteOfTheShownNote() throws {
        let env = try Env()
        let note = try env.store.create(text: "hello world")
        try env.editor.open(noteId: note.id)
        env.editor.highlightSearch(query: "wor", terms: ["wor"])
        let since = env.deliveredSinceLoad(of: note.id)
        #expect(since.count == 2)
        #expect(since.last == .searchHighlight(noteId: note.id, query: "wor", terms: ["wor"]))
    }

    @Test func testHighlightBeforeTheEditorIsReadyFollowsTheFirstLoadNote() throws {
        let env = try Env(ready: false)
        let note = try env.store.create(text: "hello world")
        try env.editor.open(noteId: note.id)
        env.editor.highlightSearch(query: "hello", terms: ["hello"])
        #expect(!env.page.delivered.contains(where: isHighlight))

        _ = env.editor.handle(.ready(version: EditorBridge.version))
        #expect(env.deliveredSinceLoad(of: note.id).map(isHighlight) == [false, true])

        // Later reloads (checksum mismatch, errors) do not jump back to the first match.
        _ = env.editor.handle(.error(message: "boom", stack: nil))
        #expect(env.deliveredSinceLoad(of: note.id).map(isHighlight) == [false])
    }

    @Test func testOpeningASearchResultHighlightsTheTerms() async throws {
        let env = try Env()
        let other = try env.store.create(text: "Unrelated", now: Date(timeIntervalSince1970: 2_000_000_000))
        let match = try env.store.create(text: "Recipe\nbake the bread", now: Date(timeIntervalSince1970: 1_000_000_000))
        env.model.refresh()
        env.model.selectNotes([other.id])
        env.state.showFocusedNote()

        env.model.search.query = "bread"
        try await waitUntil("result focused") { env.model.focusedNoteID == match.id }
        env.state.showFocusedNote() // what EditorPane's onChange(focusedNoteID) does
        #expect(env.deliveredSinceLoad(of: match.id).last == .searchHighlight(noteId: match.id, query: "bread", terms: ["bread"]))

        // Clearing the search clears the highlights in the shown note.
        env.model.search.query = ""
        env.state.searchTermsChanged()
        #expect(env.page.delivered.last == .searchHighlight(noteId: match.id, query: "", terms: []))
    }

    @Test func testShowingANoteWithoutASearchSendsNoHighlight() throws {
        let env = try Env()
        let note = try env.store.create(text: "Plain")
        env.model.refresh()
        env.model.selectNotes([note.id])
        env.state.showFocusedNote()
        #expect(!env.page.delivered.contains(where: isHighlight))
    }

    /// I1: the new note is being written; a highlight must never land in it.
    @Test func testANewNoteWhileSearchingATagGetsNoHighlight() async throws {
        let env = try Env()
        _ = try env.store.create(text: "Work #work")
        env.model.refresh()
        env.model.search.query = "#work"
        try await waitUntil("results") { env.model.search.resultIDs?.count == 1 }
        env.state.newNote()
        let id = try #require(env.model.focusedNoteID)
        env.state.showFocusedNote() // EditorPane's onChange(focusedNoteID) after ⌘N
        try await waitUntil("new note listed") { env.model.search.resultIDs?.contains(id) == true }
        env.state.searchTermsChanged()
        #expect(!env.deliveredSinceLoad(of: id).contains(where: isHighlight))
        #expect(try env.store.note(id: id)?.text == "\n\n#work")
    }

    /// The real bundle in a real web view: the highlight marks the matches and the current one,
    /// scrolls, and never moves the caret or changes the text.
    @Test func testLiveEditorHighlightsWithoutMovingTheCaret() async throws {
        let live = try LiveEditor(text: "Müller one\nmuller two")
        defer { live.close() }
        try await live.waitUntilLoaded("Müller one\nmuller two")
        let caret = try await live.selection()
        live.controller.highlightSearch(query: "muller", terms: ["muller"])
        try await waitUntil("highlighted") {
            (try await live.js("return document.querySelectorAll('.cm-bc-searchMatch').length") as? Int) == 2
        }
        let current = try await live.js("return document.querySelector('.cm-bc-searchMatch-current')?.textContent ?? null")
        #expect(current as? String == "Müller")
        #expect(try await live.selection() == caret)
        #expect(await live.editorText() == "Müller one\nmuller two")
        #expect(live.session.revision == 0)

        // ⌘G (applyCommand findNext) moves the current match; still no caret change.
        live.controller.apply(.findNext)
        try await waitUntil("next match current") {
            (try await live.js("return document.querySelector('.cm-bc-searchMatch-current')?.textContent ?? null") as? String) == "muller"
        }
        #expect(try await live.selection() == caret)

        live.controller.highlightSearch(query: "", terms: [])
        try await waitUntil("highlights cleared") {
            (try await live.js("return document.querySelectorAll('.cm-bc-searchMatch').length") as? Int) == 0
        }
    }

    // MARK: - Find Next / Previous (R18)

    @Test func testFindNextAndPreviousRunInTheShownNotesEditorAlsoReadOnly() throws {
        let env = try Env()
        let note = try env.store.create(text: "two two")
        try env.store.trash([note.id])
        env.model.selectScope(.trash)
        env.model.selectNotes([note.id])
        env.state.showFocusedNote()
        #expect(env.editor.status.isEditable == false)

        // From the menu (note list focused): the menu item's action.
        let next = try #require(FindMenu.items.first { $0.command == .findNext })
        #expect(next.isEnabled(in: env.state.editorMenuState))
        env.state.perform(next)
        let previous = try #require(FindMenu.items.first { $0.command == .findPrevious })
        env.state.perform(previous)
        #expect(env.commands == [.findNext, .findPrevious])
        // A Format command stays off in a read-only note.
        env.state.perform(FormatMenuItem("Bold", .bold))
        #expect(env.commands == [.findNext, .findPrevious])
    }

    @Test func testFindAndFindAndReplaceOpenTheEditorsPanelAlsoReadOnly() throws {
        let env = try Env()
        let note = try env.store.create(text: "two two")
        try env.store.trash([note.id])
        env.model.selectScope(.trash)
        env.model.selectNotes([note.id])
        env.state.showFocusedNote()
        #expect(env.editor.status.isEditable == false)
        for command in [EditorCommandName.find, .findAndReplace] {
            let item = try #require(FindMenu.items.first { $0.command == command })
            #expect(item.isEnabled(in: env.state.editorMenuState), "\(item.title)")
            env.state.perform(item)
        }
        // The editor opens Find and Replace… as Find in a read-only note.
        #expect(env.commands == [.find, .findAndReplace])
    }

    @Test func testCommandFAndOptionCommandFInTheEditorAreTheMenuShortcuts() throws {
        func event(_ flags: NSEvent.ModifierFlags, _ characters: String) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: characters, charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3
            ))
        }
        #expect(FormatMenu.item(for: try event(.command, "f"))?.command == .find)
        #expect(FormatMenu.item(for: try event([.command, .option], "ƒ"))?.command == .findAndReplace)
        // ⇧⌘F is Search Notes (the note list), not the in-note find.
        #expect(FormatMenu.item(for: try event([.command, .shift], "F")) == nil)
    }

    @Test func testFindItemsAreDisabledWithoutANote() throws {
        let env = try Env()
        #expect(env.model.focusedNoteID == nil)
        for item in FindMenu.items { #expect(!item.isEnabled(in: env.state.editorMenuState)) }
    }

    @Test func testCommandGInTheEditorIsTheMenuShortcut() throws {
        let commandG = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
            context: nil, characters: "g", charactersIgnoringModifiers: "g", isARepeat: false, keyCode: 5
        ))
        #expect(FormatMenu.item(for: commandG)?.command == .findNext)
        let shiftCommandG = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0,
            context: nil, characters: "G", charactersIgnoringModifiers: "G", isARepeat: false, keyCode: 5
        ))
        #expect(FormatMenu.item(for: shiftCommandG)?.command == .findPrevious)
    }

    @Test func testEditFindMenuHasTheItemsAndNothingElseUsesCommandG() throws {
        let mainMenu = try #require(NSApp.mainMenu)
        func all(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(all) ?? []) } }
        let edit = try #require(mainMenu.items.first { $0.title == "Edit" }?.submenu)
        let find = try #require(edit.items.first { $0.title == "Find" && $0.submenu != nil }?.submenu)
        let titles = find.items.map(\.title)
        #expect(titles.contains("Search Notes") && titles.contains("Find Next") && titles.contains("Find Previous"))
        #expect(titles.contains("Find…") && titles.contains("Find and Replace…"))
        let commandF = all(mainMenu).filter {
            $0.keyEquivalent.lowercased() == "f" && $0.keyEquivalentModifierMask.contains(.command)
                && !$0.keyEquivalentModifierMask.contains(.shift) && !$0.keyEquivalentModifierMask.contains(.control)
        }
        #expect(Set(commandF.map(\.title)) == ["Find…", "Find and Replace…"], "\(commandF.map(\.title))")
        let commandG = all(mainMenu).filter {
            $0.keyEquivalent.lowercased() == "g" && $0.keyEquivalentModifierMask.contains(.command)
                && !$0.keyEquivalentModifierMask.contains(.option) && !$0.keyEquivalentModifierMask.contains(.control)
        }
        #expect(Set(commandG.map(\.title)) == ["Find Next", "Find Previous"], "\(commandG.map(\.title))")
        #expect(commandG.count == 2)
    }

    // MARK: - Search field

    @Test func testSearchNotesFocusesTheFieldAndShowsTheNoteList() throws {
        let env = try Env()
        env.state.setLayout(.editorOnly)
        let before = env.state.searchFocusRequest
        env.state.focusSearch()
        #expect(env.state.searchFocusRequest == before + 1)
        #expect(env.state.layout != .editorOnly)
    }

    @Test func testSearchFieldKeys() {
        final class Box { var text = "abc"; var downs = 0; var leaves = 0 }
        let box = Box()
        let field = NoteSearchField(
            text: Binding(get: { box.text }, set: { box.text = $0 }), focusRequest: 0,
            onMoveDown: { box.downs += 1 }, onLeave: { box.leaves += 1 }
        )
        let coordinator = field.makeCoordinator()
        let nsField = NSSearchField()
        nsField.stringValue = "abc"

        #expect(coordinator.handle(#selector(NSResponder.moveDown(_:)), in: nsField))
        #expect(box.downs == 1)
        // Esc clears a non-empty field, then leaves the empty one.
        #expect(coordinator.handle(#selector(NSResponder.cancelOperation(_:)), in: nsField))
        #expect(box.text == "" && nsField.stringValue == "" && box.leaves == 0)
        #expect(coordinator.handle(#selector(NSResponder.cancelOperation(_:)), in: nsField))
        #expect(box.leaves == 1)
        #expect(!coordinator.handle(#selector(NSResponder.insertNewline(_:)), in: nsField))
    }

    @Test func testArrowDownFromTheSearchFieldSelectsTheFirstResult() async throws {
        let env = try Env()
        let a = try env.store.create(text: "Lemon tart", now: Date(timeIntervalSince1970: 2_000_000_000))
        _ = try env.store.create(text: "Lemon curd", now: Date(timeIntervalSince1970: 1_000_000_000))
        _ = try env.store.create(text: "Lime", now: Date(timeIntervalSince1970: 3_000_000_000))
        env.model.refresh()
        env.model.search.query = "lemon"
        try await waitUntil("results") { env.model.search.resultIDs?.count == 2 }
        env.model.selectNotes([])
        #expect(env.state.selectFirstResult())
        #expect(env.model.selectedNoteIDs == [a.id])
        #expect(env.model.focusedNoteID == a.id)
    }

    @Test func testArrowDownDuringTheDebounceSelectsTheFirstFreshResult() async throws {
        let env = try Env()
        let lime = try env.store.create(text: "Lime", now: Date(timeIntervalSince1970: 3_000_000_000))
        let tart = try env.store.create(text: "Lemon tart", now: Date(timeIntervalSince1970: 2_000_000_000))
        let curd = try env.store.create(text: "Lemon curd", now: Date(timeIntervalSince1970: 1_000_000_000))
        env.model.refresh()
        env.model.search.query = "li"
        try await waitUntil("li results") { env.model.search.resultIDs == [lime.id] }
        env.model.selectNotes([curd.id])

        env.model.search.query = "lemon"
        #expect(env.state.selectFirstResult(), "↓ is taken")
        #expect(env.model.selectedNoteIDs == [curd.id], "the stale result (Lime) is not selected")
        try await waitUntil("fresh results") { env.model.search.resultIDs?.count == 2 }
        #expect(env.model.selectedNoteIDs == [tart.id])
        #expect(env.model.focusedNoteID == tart.id)
    }
}
