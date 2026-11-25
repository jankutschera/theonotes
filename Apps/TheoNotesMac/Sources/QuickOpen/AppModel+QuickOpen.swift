// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import SwiftUI

/// The window ⌘O was pressed in: where Quick Open shows what is chosen.
enum QuickOpenSource {
    case main(MainWindowState)
    case note(NoteWindowState)
}

extension AppModel {
    /// File ▸ Quick Open… (⌘O) from `main` or `noteWindow` (the focused window's state; the
    /// frontmost main window when neither has focus). Again while shown: back to the field.
    func showQuickOpen(main: MainWindowState?, noteWindow: NoteWindowState?) {
        guard !isLocked else { return }
        if quickOpen.isShown { return quickOpen.focusField() }
        present(QuickOpenModel(index: nil), in: quickOpen, main: main, noteWindow: noteWindow)
    }

    /// Shows `model` in `panel` for the window ⌘O / ⇧⌘N was pressed in; a chosen result goes to
    /// `performQuickOpen`.
    func present(
        _ model: QuickOpenModel, in panel: QuickOpenController, main: MainWindowState?, noteWindow: NoteWindowState?
    ) {
        let source: QuickOpenSource? = main.map { .main($0) } ?? noteWindow.map { .note($0) }
            ?? frontmostMainWindow.map { .main($0) }
        // The panel shows at once; its snapshot is read off the main thread (ruling R26).
        model.onChoose = { [weak self] result, newWindow in
            self?.performQuickOpen(result, newWindow: newWindow, from: source)
        }
        panel.show(model, over: NSApp.keyWindow ?? NSApp.mainWindow, appearance: environment.appearance)
        let environment = environment
        let workspace = quickOpenWorkspace(for: source)
        Task { [weak self, weak model] in
            do {
                let index = try await QuickOpenModel.loadIndex(environment: environment, workspace: workspace)
                model?.install(index)
            } catch {
                appLogger.error("quick open could not read the library: \(error)")
                // Never leave the panel on "Loading…": a dismissed panel released its model.
                guard let self, model != nil, panel.isShown else { return }
                panel.dismiss(restoringFocus: true)
                NSSound.beep()
            }
        }
    }

    /// The workspace Quick Open lists (spec §3.5: it respects the active workspace): a main
    /// window's own. A note window has none of its own; it uses the frontmost main window's,
    /// because tags, sections and searches chosen there act on that window, so the panel lists
    /// what that window's sidebar and list show (none when no main window is open).
    func quickOpenWorkspace(for source: QuickOpenSource?) -> Workspace? {
        switch source {
        case .main(let main)?: main.model.workspace
        case .note?: frontmostMainWindow?.model.workspace
        case nil: nil
        }
    }

    /// What a chosen result does (spec §4.5). A note opens where ⌘O was pressed: in a main window
    /// it is revealed in the list and shown in the editor; in a note window it replaces the shown
    /// note there (a visit in that window's history, like a wiki link clicked in it). ⌘↩ opens it
    /// in a new note window. Tags, sections and special searches act on the source main window,
    /// from a note window on the frontmost one. A template makes a new note; from a main window it
    /// is tagged and shown like ⌘N's, elsewhere opened like a note.
    func performQuickOpen(_ result: QuickOpenResult, newWindow: Bool, from source: QuickOpenSource?) {
        switch result.target {
        case .note(let id):
            showFromQuickOpen(noteId: id, caret: nil, newWindow: newWindow, in: source)
        case .template(let id):
            // From a main window the note is tagged like ⌘N's (the selected tag, the search's
            // tags, the workspace's) and shown like it (final review I3).
            var extraTags: [String] = []
            if case .main(let main)? = source {
                do {
                    extraTags = try main.model.newNoteTagPaths()
                } catch {
                    appLogger.error("could not tag a note from template \(id, privacy: .public): \(error)")
                    return beep()
                }
            }
            let outcome = createNoteFromTemplate(id: id, workspace: quickOpenWorkspace(for: source), extraTags: extraTags)
            guard case .created(let noteId, let caret) = outcome else {
                if outcome != .cancelled { beep() }
                return
            }
            if !newWindow, case .main(let main)? = source { return main.showNewNote(noteId, caret: caret) }
            showFromQuickOpen(noteId: noteId, caret: caret, newWindow: newWindow, in: source)
        case .scope(let scope):
            guard let main = mainWindow(for: source) else { return newMainWindow() }
            if case .tag(let path) = scope, main.model.selectTag(named: path) { return }
            main.model.selectScope(scope)
        case .search(let query):
            guard let main = mainWindow(for: source) else { return newMainWindow() }
            main.model.selectScope(.notes)
            main.model.search.query = query
            main.focusSearch()
        }
    }

    /// Shows `noteId` where the panel was opened (a note made from a template in a note window or
    /// a new window opens like a note; in a main window like ⌘N's, `MainWindowState.showNewNote`).
    func showFromQuickOpen(noteId: String, caret: Int?, newWindow: Bool, in source: QuickOpenSource?) {
        switch (newWindow, source) {
        case (false, .main(let main)?):
            if main.links.showNote(noteId, caret) { main.editor.focusEditor() }
        case (false, .note(let window)?):
            window.show(noteId: noteId, caret: caret)
        default:
            openNoteInNewWindow(id: noteId, caret: caret)
        }
    }

    /// The main window a sidebar choice acts on; from a note window the frontmost one, brought forward.
    private func mainWindow(for source: QuickOpenSource?) -> MainWindowState? {
        if case .main(let main)? = source { return main }
        guard let main = frontmostMainWindow else { return nil }
        showMainWindow()
        return main
    }
}
