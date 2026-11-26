// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore

/// What `app open` (and the `open-note` x-callback) asks the app to show, after the note, the heading
/// and the selection were checked. Offsets are UTF-16 (the editor's unit).
struct OpenNoteRequest: Equatable {
    var noteId: String
    /// `NoteParser` heading ordinal to scroll to.
    var headingIndex: Int?
    /// Put the caret in the editor, ready for typing.
    var edit = false
    var newWindow = false
    /// A note window that floats on top.
    var float = false
    var selection: SelectionRange?
    /// A term the editor highlights (x-callback `open-note` with `search`).
    var find: String?
    /// False: show the note without bringing Theo Notes or its window forward (`show_window=no`).
    var showWindow = true
}

extension AppModel {
    /// Shows a note the way `app open` asks: in the frontmost main window, or in a note window when
    /// `newWindow` / `float` is set (a window that already shows the note is reused). Brings Theo Notes to
    /// the front. The one open path that `AppAutomationHandler` and the x-callback handler share.
    /// False when the window could not even be queued (the app is still starting and its queue is full).
    @discardableResult
    func openNote(_ request: OpenNoteRequest) -> Bool {
        guard !isLocked else { return false }
        if request.newWindow || request.float {
            if let window = noteWindow(showing: request.noteId) {
                apply(request, to: window)
                if request.showWindow { window.hostWindow?.makeKeyAndOrderFront(nil) }
            } else {
                pendingNoteOpens[request.noteId] = request
                guard openNoteInNewWindow(id: request.noteId, headingIndex: request.headingIndex) else {
                    pendingNoteOpens[request.noteId] = nil
                    return false
                }
            }
            if request.showWindow { activate() }
            return true
        }
        // Shown by `makeMainWindow` once the window exists, in arrival order with the other actions that
        // wait for it. A window that is up shows it now.
        let waits = frontmostMainWindow == nil
        guard withMainWindow({ [weak self] main in self?.show(request, in: main) }) else { return false }
        if waits, request.showWindow { activate() }
        return true
    }

    /// Selects the note in `main`'s list, shows it in its editor and applies the request. The window is
    /// not made here (it may not be attached yet): a window that is up is brought forward.
    /// False when the note could not be shown (it is gone); the log names no note.
    @discardableResult
    func show(_ request: OpenNoteRequest, in main: MainWindowState) -> Bool {
        main.model.refresh()
        guard main.links.showNote(request.noteId, nil) else {
            appLogger.error("open: a note could not be shown")
            return false
        }
        if request.showWindow {
            main.window?.makeKeyAndOrderFront(nil)
            activate()
        }
        if let headingIndex = request.headingIndex { main.editor.scrollToHeading(headingIndex) }
        applyEditorActions(request, to: main.editor)
        return true
    }

    /// A note window that is open and shows `noteId`.
    func noteWindow(showing noteId: String) -> NoteWindowState? {
        noteWindowRefs.compactMap(\.state).first { $0.isOpen && $0.noteExists && $0.noteId == noteId }
    }

    /// Float, heading, selection and focus for a note window (new, or one that was open already).
    func apply(_ request: OpenNoteRequest, to window: NoteWindowState) {
        if request.float { window.isFloating = true }
        if let headingIndex = request.headingIndex { window.editor.scrollToHeading(headingIndex) }
        applyEditorActions(request, to: window.editor)
    }

    /// The selection is made after the heading scroll, so it wins when both are given. A selection
    /// gives the editor focus as `edit` does (`edit` is ignored when a selection is set, and a
    /// selection in an unfocused editor would be drawn grey). Both are queued by the editor until its
    /// page is ready.
    private func applyEditorActions(_ request: OpenNoteRequest, to editor: EditorBridgeController) {
        if let find = request.find { editor.highlightSearch(query: find, terms: [find]) }
        if let selection = request.selection { editor.selectRange(anchor: selection.anchor, head: selection.head) }
        if request.edit || request.selection != nil { editor.focusEditor() }
    }

    /// Most actions that wait for a main window.
    static let maxPendingMainActions = 16

    /// Runs `action` on the frontmost main window, or keeps it until `makeMainWindow` makes one; the
    /// kept actions (note opens and sidebar or workspace changes alike) run in arrival order. The first
    /// one asks for a window, unless the launch window is still to come; the rest wait for
    /// the same window. False when the queue is full.
    @discardableResult
    func withMainWindow(_ action: @escaping (MainWindowState) -> Void) -> Bool {
        if let main = frontmostMainWindow {
            action(main)
            return true
        }
        guard pendingMainActions.count < Self.maxPendingMainActions else { return false }
        let first = pendingMainActions.isEmpty
        pendingMainActions.append(action)
        if first, openWindowRequest != nil { newMainWindow() }
        return true
    }

    /// The editor of the window the user works in: the key window's, else the frontmost Theo Notes
    /// window that has one, else the window that was key most recently (main and note windows alike;
    /// ties and windows never key go to the newest),.
    func keyEditor() -> EditorBridgeController? {
        func editor(of window: NSWindow) -> EditorBridgeController? {
            if let main = mainWindows.first(where: { $0.window === window }) { return main.editor }
            return noteWindowRefs.compactMap(\.state).first { $0.isOpen && $0.hostWindow === window }?.editor
        }
        if let key = NSApp?.keyWindow, let found = editor(of: key) { return found }
        // Only windows that are on screen (or minimized) have a place in the order.
        for window in NSApp?.orderedWindows ?? [] where window.isVisible || window.isMiniaturized {
            if let found = editor(of: window) { return found }
        }
        func activation(_ window: NSWindow?) -> Int {
            window.flatMap { windowActivation.object(forKey: $0)?.intValue } ?? 0
        }
        var candidates: [(editor: EditorBridgeController, activation: Int, serial: Int)] = mainWindowSerials.map {
            ($0.state.editor, activation($0.state.window), $0.serial)
        }
        for ref in noteWindowRefs {
            guard let state = ref.state, state.isOpen else { continue }
            candidates.append((state.editor, activation(state.hostWindow), ref.serial))
        }
        return candidates.max { ($0.activation, $0.serial) < ($1.activation, $1.serial) }?.editor
    }
}
