// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import SwiftUI
import Testing
@testable import TheoNotes

@MainActor
@Suite struct NoteTypeCommandTests {
    @MainActor
    final class Env {
        let root: URL
        let suiteName = "TheoNotesTypeTests-\(UUID().uuidString)"
        let environment: AppEnvironment
        let page = FakeEditorPage()
        let editor: EditorBridgeController
        let state: MainWindowState
        var model: LibraryModel { state.model }
        var store: NoteStore { environment.store }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("TheoNotesType-\(UUID().uuidString)")
            environment = try AppEnvironment(paths: AppPaths(root: root))
            editor = EditorBridgeController(environment: environment, page: page, openExternally: { _ in }, checksumInterval: nil)
            state = MainWindowState(environment: environment, defaults: UserDefaults(suiteName: suiteName)!, editor: editor)
            _ = editor.handle(.ready(version: EditorBridge.version))
        }

        deinit {
            UserDefaults().removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        func text(_ id: String) throws -> String { try #require(try store.note(id: id)).text }

        var commands: [HostToEditorMessage] {
            page.delivered.filter { if case .applyCommand = $0 { true } else { false } }
        }
    }

    private func makeUndoManager() -> UndoManager {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        return undoManager
    }

    private func item(_ id: String, locked: Bool = false, readOnly: Bool = false, type: NoteType? = nil) -> NoteListItem {
        NoteListItem(
            id: id, title: id, subtitle: "", modifiedAt: .now, createdAt: .now, isPinned: false,
            isLocked: locked, isReadOnly: readOnly, hasAttachments: false, firstImageFilename: nil, noteType: type)
    }

    private func state(_ items: [NoteListItem], selected: Set<String>, scope: SidebarScope = .notes) -> NoteCommandState {
        NoteCommandState(scope: scope, items: items, selectedNoteIDs: selected, counts: SidebarCounts())
    }

    @Test func setTypeOnClosedNotesIsOneUndoStep() throws {
        let env = try Env()
        let a = try env.store.create(text: "first note").id
        let b = try env.store.create(text: "second note").id
        env.model.refresh()
        env.model.selectNotes([a, b])
        let undoManager = makeUndoManager()

        undoManager.beginUndoGrouping()
        env.model.setType(.idea, undoManager: undoManager)
        undoManager.endUndoGrouping()

        #expect(try env.text(a) == "first note\n\n#idea")
        #expect(try env.text(b) == "second note\n\n#idea")
        #expect(undoManager.undoActionName == "Set Type")
        undoManager.undo()
        #expect(try env.text(a) == "first note")
        #expect(try env.text(b) == "second note")
    }

    @Test func setTypeOnOpenNoteUsesOneEditorEdit() throws {
        let env = try Env()
        let id = try env.store.create(text: "Plan the week\n\n#idea").id
        env.model.refresh()
        env.model.selectNotes([id])
        env.state.showFocusedNote()
        #expect(env.editor.status.isEditable)

        env.model.setType(.log, undoManager: nil)

        let old = "Plan the week\n\n#idea"
        let new = NoteTypeText.setting(.log, in: old)
        #expect(new == "Plan the week\n\n#log")
        #expect(env.commands == [
            .applyCommand(name: .replaceRange, args: [
                "from": .int(16), "to": .int(20), "expect": .string("idea"), "text": .string("log"),
                "keepSelection": .bool(true),
            ]),
        ])
        // The editor's edit reaches the store through the session; the store was not written here.
        #expect(try env.text(id) == old)
    }

    @Test func theOpenEditPositionsCountUTF16() {
        let change = NoteTypeText.smallestChange(from: "😀 a\n\n#idea", to: "😀 a\n\n#log")
        #expect(change?.from == 7 && change?.to == 11 && change?.expect == "idea" && change?.text == "log")
        // Never splits a surrogate pair: 😀 and 😁 share their first UTF-16 unit.
        let emoji = NoteTypeText.smallestChange(from: "x😀", to: "x😁")
        #expect(emoji?.from == 1 && emoji?.to == 3 && emoji?.expect == "😀" && emoji?.text == "😁")
        #expect(NoteTypeText.smallestChange(from: "same", to: "same") == nil)
    }

    @Test func removeTypeClearsTag() throws {
        let env = try Env()
        let id = try env.store.create(text: "Recipe\n\n#ref").id
        env.model.refresh()
        env.model.selectNotes([id])

        env.model.setType(nil, undoManager: nil)

        #expect(try env.text(id) == "Recipe")
    }

    @Test func readOnlyNotesAreSkippedAndReported() throws {
        let env = try Env()
        let id = try env.store.create(text: "gone").id
        try env.store.setReadOnly(id, readOnly: true)
        env.model.refresh()
        env.model.selectNotes([id])

        env.model.setType(.idea, undoManager: nil)

        #expect(try env.text(id) == "gone")
        #expect(env.model.banner == .notesSkipped(locked: 0, readOnly: 1))
    }

    /// Typing an Inbox note moves it out of the list while the editor keeps showing it: the type
    /// menus follow that note (and still act on it) instead of showing "No type", disabled.
    @Test func typeMenusFollowTheEditorNoteAfterItLeftTheInbox() throws {
        let env = try Env()
        let id = try env.store.create(text: "Loose thought").id
        env.model.selectScope(.inbox)
        env.model.refresh()
        env.model.selectNotes([id])

        env.model.setType(.idea, undoManager: nil)
        env.model.refresh()

        #expect(!env.model.items.contains { $0.id == id })
        #expect(env.model.focusedNoteID == id)
        let state = env.model.commandState
        #expect(state.canSetType)
        #expect(state.currentType == .idea)
        #expect(NoteTypeMenu.label(for: state) == "Idea")
        // Only the type commands: the others still act on listed notes.
        #expect(!state.hasSelection)

        env.model.setType(.log, undoManager: nil)
        #expect(try env.text(id) == "Loose thought\n\n#log")
        env.model.refresh()
        #expect(env.model.commandState.currentType == .log)
    }

    @Test func menuDisabledForLockedNote() {
        #expect(!state([item("a", locked: true)], selected: ["a"]).canSetType)
        #expect(state([item("a")], selected: ["a"]).canSetType)
        #expect(state([item("a"), item("b", locked: true)], selected: ["a", "b"]).canSetType)
        #expect(!state([item("a")], selected: ["a"], scope: .trash).canSetType)
        #expect(!state([item("a")], selected: []).canSetType)
    }

    @Test func menuDisabledForReadOnlyOnlySelection() {
        let readOnly = state([item("r", readOnly: true)], selected: ["r"])
        #expect(!readOnly.canSetType)
        #expect(NoteTypeMenu.hint(for: readOnly) == "Read-only notes keep their type")
        #expect(state([item("r", readOnly: true), item("b")], selected: ["r", "b"]).canSetType)
        #expect(NoteTypeMenu.hint(for: state([item("b")], selected: ["b"])) == "Note type")
        // A read-only note still shows its type; a locked-only selection has nothing to say about it.
        #expect(readOnly.currentType == nil)
        #expect(state([item("r", readOnly: true, type: .log)], selected: ["r"]).currentType == .log)
    }

    @Test func setTypeRefusedInTheEditorWhenTheTagWouldSitInsideAFence() throws {
        let env = try Env()
        let id = try env.store.create(text: "Plan\n```\ncode").id
        env.model.refresh()
        env.model.selectNotes([id])
        env.state.showFocusedNote()
        #expect(env.editor.status.isEditable)

        env.model.setType(.idea, undoManager: nil)

        #expect(env.commands.isEmpty)
        #expect(try env.text(id) == "Plan\n```\ncode")
        #expect(env.model.banner != nil)
    }

    @Test func setTypeRefusedOnClosedNoteWhenTheTagWouldSitInsideAFence() throws {
        let env = try Env()
        let fenced = try env.store.create(text: "Plan\n```\ncode").id
        let plain = try env.store.create(text: "Fine").id
        env.model.refresh()
        env.model.selectNotes([fenced, plain])

        env.model.setType(.idea, undoManager: nil)

        #expect(try env.text(fenced) == "Plan\n```\ncode")
        #expect(try env.text(plain) == "Fine\n\n#idea")
        #expect(env.model.banner != nil)
    }

    @Test func currentTypeFollowsTheSelection() {
        let items = [item("a", type: .idea), item("b", type: .idea), item("c", type: .log), item("d")]
        #expect(state(items, selected: ["a"]).currentType == .idea)
        #expect(NoteTypeMenu.label(for: state(items, selected: ["a", "b"])) == "Idea")
        #expect(NoteTypeMenu.label(for: state(items, selected: ["a", "c"])) == "Mixed")
        #expect(NoteTypeMenu.label(for: state(items, selected: ["d"])) == "No type")
        #expect(NoteTypeMenu.accessibilityLabel(for: state(items, selected: ["a"])) == "Note type: Idea")
        #expect(NoteTypeMenu.accessibilityLabel(for: state(items, selected: ["d"])) == "Note type: none")
        // A locked note stays out of it (it is never typed).
        let locked = [item("a", type: .idea), item("l", locked: true)]
        #expect(state(locked, selected: ["a", "l"]).currentType == .idea)
    }

    @Test func shortcutsAreBound() throws {
        let bound = NoteTypeMenu.items.map { ($0.title, $0.key, $0.modifiers) }
        #expect(bound.map(\.0) == ["Idea", "Log", "Reference", "Remove Type"])
        #expect(bound.map(\.1) == ["1", "2", "3", "0"])
        #expect(bound.allSatisfy { $0.2 == [.control, .option] })
        #expect(NoteTypeMenu.items.map(\.type) == [.idea, .log, .reference, nil])

        // No other command in Commands/ uses ⌃⌥0–⌃⌥3.
        let commands = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Commands")
        let files = try FileManager.default.contentsOfDirectory(at: commands, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in source.split(separator: "\n") where line.contains("keyboardShortcut") {
                let usesControlOption = line.contains(".control") && line.contains(".option")
                let digit = ["0", "1", "2", "3"].contains { line.contains("(\"\($0)\"") }
                #expect(!(usesControlOption && digit), "\(file.lastPathComponent): \(line)")
            }
        }
    }

    /// The real menu bar, not the definition: Note ▸ Type with ⌃⌥1–3/0 and View ▸ Sort Inbox exist.
    @Test func menuBarHasTypeSubmenuAndSortInbox() throws {
        let mainMenu = try #require(NSApp.mainMenu)
        func menu(_ title: String) throws -> NSMenu {
            try #require(mainMenu.items.first { $0.title == title }?.submenu, "\(title) menu missing")
        }
        let note = try menu("Note")
        // Accessibility (and so the user) never sees a hidden item.
        func visible(_ menu: NSMenu) -> [NSMenuItem] { menu.items.filter { !$0.isHidden } }
        let type = try #require(visible(note).first { $0.title == NoteTypeMenu.submenu }?.submenu,
                                "Note ▸ Type missing: \(visible(note).map(\.title))")
        let items = visible(type).filter { !$0.isSeparatorItem }
        #expect(items.map(\.title) == ["Idea", "Log", "Reference", "Remove Type"])
        #expect(items.map(\.keyEquivalent) == ["1", "2", "3", "0"])
        let mods: NSEvent.ModifierFlags = [.command, .option, .shift, .control]
        #expect(items.allSatisfy { $0.keyEquivalentModifierMask.intersection(mods) == [.control, .option] })
        let view = try menu("View")
        #expect(visible(view).contains { $0.title == "Sort Inbox" }, "View: \(visible(view).map(\.title))")
    }
}
