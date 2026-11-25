// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import SwiftUI

/// Which note File ▸ Print… prints (M8-R7): the note in the focused editor, else the one selected
/// note. A locked note, or a selection of none or several, prints nothing (the item is disabled).
enum PrintTarget {
    struct Note: Equatable {
        var id: String
        var isLocked: Bool
    }

    static func noteId(focusedEditorNote: Note?, selection: [Note]) -> String? {
        if let focusedEditorNote { return focusedEditorNote.isLocked ? nil : focusedEditorNote.id }
        guard selection.count == 1, let only = selection.first, !only.isLocked else { return nil }
        return only.id
    }

    /// The target in a main window: its editor's note while the editor has focus, else the selection.
    @MainActor
    static func noteId(in window: MainWindowState, store: NoteStore) -> String? {
        let model = window.model
        let selection = model.items.filter { model.selectedNoteIDs.contains($0.id) }
            .map { Note(id: $0.id, isLocked: $0.isLocked) }
        let editorNote = window.isEditorFocused ? window.editor.session.map { session in
            Note(id: session.noteId, isLocked: model.items.first { $0.id == session.noteId }?.isLocked
                ?? (try? store.note(id: session.noteId)?.isLocked) ?? true)
        } : nil
        return noteId(focusedEditorNote: editorNote, selection: selection)
    }

    /// The target in a note window: the note it shows.
    @MainActor
    static func noteId(in window: NoteWindowState) -> String? {
        guard window.noteExists else { return nil }
        let locked = (try? window.environment.store.note(id: window.noteId)?.isLocked) ?? true
        return noteId(focusedEditorNote: Note(id: window.noteId, isLocked: locked), selection: [])
    }
}

/// File ▸ Print… (⌘P): prints the target note with the light-slot theme and the Settings
/// typography through the shared `NoteRenderer`, with the print panel as a sheet on the window.
struct PrintCommands: Commands {
    let app: AppModel?

    @FocusedValue(\.mainWindow) private var mainWindow
    @FocusedValue(\.noteWindow) private var noteWindow
    // Read so the item re-validates when the selection changes.
    @FocusedValue(\.noteCommandState) private var noteCommandState

    private var target: String? {
        _ = noteCommandState
        guard let store = app?.environment.store else { return nil }
        if let mainWindow { return PrintTarget.noteId(in: mainWindow, store: store) }
        if let noteWindow { return PrintTarget.noteId(in: noteWindow) }
        return nil
    }

    var body: some Commands {
        CommandGroup(replacing: .printItem) {
            Button("Print…") {
                guard let app, let noteId = target else { return }
                let host = mainWindow?.window ?? noteWindow?.hostWindow ?? NSApp.keyWindow
                Task { await Self.print(noteId, environment: app.environment, window: host) }
            }
            .keyboardShortcut("p")
            .disabled(app == nil || target == nil)
        }
    }

    @MainActor
    static func print(_ noteId: String, environment: AppEnvironment, window: NSWindow?) async {
        guard let window else { return NSSound.beep() }
        let appLock = environment.appLock
        let generation = appLock.generation
        guard !appLock.isLocked else { return }
        do {
            // The open editor's acknowledged text is what prints.
            try environment.existingSession(for: noteId)?.flush()
            guard let note = try environment.store.note(id: noteId), !note.isLocked else { return NSSound.beep() }
            let look = environment.appearance.exportLook(themeId: nil)
            let request = try RenderRequestBuilder(store: environment.store, paths: environment.paths).request(
                for: note, mode: .document, theme: look.theme, appearance: look.appearance, typography: look.typography,
                attachments: .assetURLs, wikiLinks: .sameNote, keepTags: true)
            _ = try await environment.renderer.print(request, for: window, mayProceed: { appLock.isCurrent(generation) })
        } catch RenderError.cancelled {
            return
        } catch {
            appLogger.error("print failed: \(error)")
            let alert = NSAlert()
            alert.messageText = "The note could not be printed"
            alert.informativeText = error.localizedDescription
            _ = await alert.beginSheetModal(for: window)
        }
    }
}
