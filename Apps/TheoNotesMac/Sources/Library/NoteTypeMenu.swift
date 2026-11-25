// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import SwiftUI
import TheoNotesCore

/// The note type commands: Note ▸ Type and the toolbar menu share these items (⌃⌥1 Idea, ⌃⌥2 Log,
/// ⌃⌥3 Reference, ⌃⌥0 Remove Type; ⌃1–⌃3 stay the layout presets).
enum NoteTypeMenu {
    static let submenu = "Type"

    struct Item: Identifiable {
        let title: String
        /// nil removes the type.
        let type: NoteType?
        let key: KeyEquivalent
        let modifiers: EventModifiers = [.control, .option]
        var id: String { title }
    }

    static let items: [Item] =
        zip(NoteType.allCases, ["1", "2", "3"]).map { Item(title: $0.displayName, type: $0, key: KeyEquivalent($1)) }
        + [Item(title: "Remove Type", type: nil, key: "0")]

    /// The toolbar menu's title for the selection.
    static func label(for state: NoteCommandState) -> String {
        state.hasMixedTypes ? "Mixed" : state.currentType?.displayName ?? "No type"
    }

    /// The toolbar menu's help text.
    static func hint(for state: NoteCommandState) -> String {
        state.onlyReadOnlyTypeable ? "Read-only notes keep their type" : "Note type"
    }

    static func accessibilityLabel(for state: NoteCommandState) -> String {
        "Note type: " + (state.hasMixedTypes ? "mixed" : state.currentType?.displayName ?? "none")
    }
}

/// The type items, with the shortcuts only where one menu owns them (the toolbar menu has none).
struct NoteTypeMenuItems: View {
    let state: NoteCommandState
    let shortcuts: Bool
    let set: (NoteType?) -> Void

    var body: some View {
        ForEach(NoteTypeMenu.items) { item in
            if item.type == nil { Divider() }
            if shortcuts {
                Button(item.title) { set(item.type) }
                    .keyboardShortcut(item.key, modifiers: item.modifiers)
                    .disabled(!state.canSetType)
            } else {
                Button(item.title) { set(item.type) }.disabled(!state.canSetType)
            }
        }
    }
}

/// The editor toolbar's type menu for the selected notes, titled with their type.
struct NoteTypeToolbarMenu: View {
    let model: LibraryModel

    var body: some View {
        let state = model.commandState
        Menu {
            NoteTypeMenuItems(state: state, shortcuts: false) { model.setType($0, undoManager: model.undoManager) }
        } label: {
            Label(NoteTypeMenu.label(for: state), systemImage: "tag")
                .labelStyle(.titleAndIcon)
        }
        .disabled(!state.canSetType)
        .help(NoteTypeMenu.hint(for: state))
        .accessibilityLabel(NoteTypeMenu.accessibilityLabel(for: state))
    }
}
