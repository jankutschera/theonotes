// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Observation
import SwiftUI

/// A separate note window (inventory §2.1 "Separate note windows"): one editor, its own history,
/// Float on Top. The note's session is shared with every other window showing it.
@MainActor
@Observable
final class NoteWindowState: FormatTarget {
    let environment: AppEnvironment
    let editor: EditorBridgeController
    /// What the editor's links do: a linked note opens in this window (with its own history).
    @ObservationIgnored let links: LinkRouter
    /// The Info panel of the note this window shows.
    let info: InfoPanelModel
    private(set) var noteId: String
    private(set) var title = ""
    /// False once the note is gone (deleted, or never existed for a restored window).
    private(set) var noteExists = false
    private(set) var history = NoteHistory()
    /// Window ▸ Float on Top.
    var isFloating = false {
        didSet { applyLevel() }
    }
    /// The editor has keyboard focus (follows the window's first responder); the Format menu
    /// is enabled only then.
    private(set) var isEditorFocused = false
    /// Find Next / Previous work whenever the note is shown.
    var canFind: Bool { noteExists }

    /// Called with the note the window navigated to (the host keeps its scene value in sync).
    @ObservationIgnored var onNoteChange: (String) -> Void = { _ in }
    /// Runs once, when the window closes. It owns letting go of the editor: it must call the `finish`
    /// it is given (commit the note, detach the editor, release the window's note) exactly once, now
    /// or after an asynchronous check; Capture Thought decides there whether to cancel an untouched
    /// capture. Without one `close()` runs `finish` itself.
    @ObservationIgnored var onClose: ((_ editor: EditorBridgeController, _ finish: @escaping @MainActor () -> Void) -> Void)?
    /// Tests stand in for the window's undo manager.
    @ObservationIgnored weak var undoManagerOverride: UndoManager?

    /// What decides whether the editor is read-only (spec §4.9), as of the last `loadNote`.
    private struct Access: Equatable {
        var location: NoteLocation
        var isReadOnly: Bool
        var isLocked: Bool

        init(_ note: Note) {
            location = note.location
            isReadOnly = note.isReadOnly
            isLocked = note.isLocked
        }
    }

    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var closeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var responderObservation: NSKeyValueObservation?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var notifierObservation: ObservationToken?
    @ObservationIgnored private var isClosed = false
    /// Nil while no note is shown.
    @ObservationIgnored private var loadedAccess: Access?

    /// `editor` is injected by tests (with a fake page); `caret` is where a new note starts,
    /// `headingIndex` the heading a wiki link opened it at.
    init(
        environment: AppEnvironment, noteId: String, editor: EditorBridgeController? = nil, caret: Int? = nil,
        headingIndex: Int? = nil
    ) {
        self.environment = environment
        let editor = editor ?? EditorBridgeController(environment: environment)
        self.editor = editor
        links = LinkRouter(environment: environment, editor: editor)
        let this = WeakReference<NoteWindowState>()
        info = InfoPanelModel(
            environment: environment, editor: editor,
            shownNoteId: { this.object.flatMap { $0.noteExists ? $0.noteId : nil } },
            open: { this.object?.show(noteId: $0) },
            link: { this.object?.linkMention($0, to: $1) ?? false }
        )
        self.noteId = noteId
        this.object = self
        history.visit(noteId)
        notifierObservation = environment.notifier.observe { [weak self] in
            Task { @MainActor in self?.noteDidChange() }
        }
        links.shownNoteId = { [weak self] in self?.noteId }
        links.showNote = { [weak self] noteId, caret in
            guard let self else { return false }
            self.show(noteId: noteId, caret: caret)
            return self.noteId == noteId && self.noteExists
        }
        load(caret: caret)
        // Queued by the editor until its page is ready.
        if let headingIndex, noteExists { editor.scrollToHeading(headingIndex) }
    }

    isolated deinit {
        close()
    }

    /// The window shows this state until it closes.
    var isOpen: Bool { !isClosed }
    /// The window this state is shown in, once it is on screen.
    var hostWindow: NSWindow? { window }

    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }

    /// Navigates inside this window (e.g. a wiki link clicked in it), recording a visit; `caret`
    /// for a note the link just created.
    func show(noteId: String, caret: Int? = nil) {
        guard noteId != self.noteId else { return }
        history.visit(noteId)
        navigate(to: noteId, caret: caret)
    }

    /// The database changed (this or another process): follows renames, re-evaluates read-only
    /// when the note was trashed, archived, restored, locked or made read-only, and lets go when
    /// it was deleted without `closeSessions` (e.g. by the CLI).
    func noteDidChange() {
        guard !isClosed else { return }
        let wasShown = loadedAccess != nil
        guard let note = readNote() else {
            if wasShown { letGoOfDeletedNote() }
            return
        }
        guard wasShown else { return }
        let access = Access(note)
        if access != loadedAccess {
            loadedAccess = access
            if editor.session == nil {
                // Locked meanwhile (its session was closed): the lock view, or the editor again.
                try? editor.open(noteId: noteId)
            } else {
                editor.reloadShownNote()
            }
        }
    }

    func goBack() {
        if let id = history.goBack(where: Self.exists(in: environment)) { navigate(to: id) }
    }

    func goForward() {
        if let id = history.goForward(where: Self.exists(in: environment)) { navigate(to: id) }
    }

    /// A Format shortcut typed in this window's editor runs the Format command here (like the
    /// main window's key monitor); anything else passes on.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, editorIsFirstResponder(in: window) else { return false }
        return handleFormatShortcut(event)
    }

    /// The window this state is shown in: applies Float on Top, follows its first responder for
    /// the Format menu, routes Format shortcuts and closes with it.
    func attach(window: NSWindow) {
        guard window !== self.window else { return }
        self.window = window
        applyLevel()
        responderObservation = window.observe(\.firstResponder, options: [.initial, .new]) { [weak self] window, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let focused = self.editorIsFirstResponder(in: window)
                if focused != self.isEditorFocused { self.isEditorFocused = focused }
            }
        }
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated { self?.handleKeyDown(event) ?? false }
                return handled ? nil : event
            }
        }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    /// The window closed: commits the note, runs link updates still waiting, and lets go of its session.
    /// With an `onClose` the editor is let go of by it (it gets `finish` to call, now or later); a
    /// capture window waits there until its editor has drained (FOC-R343).
    func close() {
        guard !isClosed else { return }
        isClosed = true
        info.close()
        notifierObservation?.cancel()
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        responderObservation = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        let editor = editor, environment = environment, window = ObjectIdentifier(self)
        let finish: @MainActor () -> Void = {
            editor.showNoNote()
            environment.linkUpdater?.runPendingNow()
            environment.setOpenNoteIds([], for: window)
        }
        let onClose = onClose
        self.onClose = nil
        if let onClose { onClose(editor, finish) } else { finish() }
    }

    /// The Info panel's "Link" in this window: one "Link Mention" step on the window's undo
    /// manager (`LinkRewriteUndo`; a note window has no note list for the banner). A refused link
    /// beeps.
    @discardableResult
    func linkMention(_ mention: Mention, to targetId: String) -> Bool {
        do {
            let result = try LinkRewriteUndo.linkMention(mention, to: targetId, in: environment)
            if let undoManager = undoManagerOverride ?? window?.undoManager {
                LinkRewriteUndo.register(
                    result, actionName: "Link Mention", target: LinkUndoTarget(), on: undoManager, in: environment
                )
            }
            return true
        } catch {
            appLogger.error("linking a mention in note \(mention.noteId, privacy: .public) failed: \(error)")
            NSSound.beep()
            return false
        }
    }

    private func editorIsFirstResponder(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder as? NSView else { return false }
        return responder === editor.webView || responder.isDescendant(of: editor.webView)
    }

    // MARK: - Private

    private static func exists(in environment: AppEnvironment) -> (String) -> Bool {
        { ((try? environment.store.note(id: $0)) ?? nil) != nil }
    }

    private func navigate(to id: String, caret: Int? = nil) {
        noteId = id
        load(caret: caret)
        onNoteChange(id)
    }

    private func load(caret: Int?) {
        guard let note = readNote() else {
            loadedAccess = nil
            editor.showNoNote()
            environment.setOpenNoteIds([], for: ObjectIdentifier(self))
            return
        }
        loadedAccess = Access(note)
        do {
            try editor.open(noteId: noteId, caret: caret)
        } catch {
            appLogger.error("could not open note \(self.noteId, privacy: .public) in its window: \(error)")
        }
        environment.setOpenNoteIds([noteId], for: ObjectIdentifier(self))
        editor.focusEditor()
    }

    /// Reads the note and updates `noteExists` and the title (it follows renames, inventory §2.1).
    private func readNote() -> Note? {
        let note = (try? environment.store.note(id: noteId)) ?? nil
        if noteExists != (note != nil) { noteExists = note != nil }
        let newTitle = note.map { $0.title.isEmpty ? "Untitled" : $0.title } ?? "Note Not Found"
        if title != newTitle { title = newTitle }
        return note
    }

    /// Deleted behind `closeSessions`' back: its session is dropped app-wide first, so no editor
    /// (here or in another window) can still type into it.
    private func letGoOfDeletedNote() {
        loadedAccess = nil
        environment.closeSessionsOfDeletedNotes()
        editor.showNoNote()
        environment.setOpenNoteIds([], for: ObjectIdentifier(self))
    }

    private func applyLevel() {
        window?.level = isFloating ? .floating : .normal
    }
}

/// The content of a note window: just the editor (no sidebar, no note list).
struct NoteWindow: View {
    let state: NoteWindowState
    @AppStorage(FormattingBar.shownKey) private var showsFormattingBar = true
    /// This view is the root that injects the palette, so it reads the resolved look itself.
    private var palette: ShellPalette { ShellPalette.resolve(state.environment.appearance.resolved) }

    var body: some View {
        let lockedNoteId = state.editor.status.lockedNoteId
        EditorWebView(controller: state.editor)
            .opacity(state.noteExists && lockedNoteId == nil ? 1 : 0)
            .accessibilityHidden(lockedNoteId != nil)
            .allowsHitTesting(lockedNoteId == nil)
            .overlay {
                if let lockedNoteId, state.noteExists {
                    LockedNotePane(environment: state.environment, noteId: lockedNoteId)
                        .id(lockedNoteId)
                } else if !state.noteExists {
                    Text("Note Not Found")
                        .font(.title3)
                        .foregroundStyle(palette.secondaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .formattingBar(state, isShown: state.noteExists && showsFormattingBar)
            .background(palette.background)
            .background(WindowAccessor { state.attach(window: $0) })
            .navigationTitle(state.title)
            // The system draws a window title dim when the window is not frontmost, which on a dark
            // canvas was hard to read. The title text stays the window's title (Window menu,
            // accessibility); the visible one is drawn in the theme's primary text colour (FOC-R367).
            .toolbar(removing: .title)
            .focusedSceneValue(\.noteWindow, state)
            .focusedSceneValue(\.editorMenuState, state.editorMenuState)
            .focusedSceneValue(\.infoPanel, state.info)
            .toolbar {
                ToolbarItem(placement: .navigation) { NoteWindowTitle(title: state.title, palette: palette) }
                ToolbarItem(placement: .primaryAction) { InfoToolbarButton(info: state.info) }
            }
            .focusedSceneValue(\.windowCommandState, WindowCommandState(
                canGoBack: state.canGoBack, canGoForward: state.canGoForward, isFloating: state.isFloating
            ))
            .shellPalette(from: state.environment.appearance)
    }
}

/// The title of a note window, in the shell's primary text colour (FOC-R367).
struct NoteWindowTitle: View {
    let title: String
    let palette: ShellPalette

    static func color(for palette: ShellPalette) -> Color { palette.text }

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(Self.color(for: palette))
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// Hands the window a view lives in to `onWindow` (once it is in one).
struct WindowAccessor: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> AccessorView {
        let view = AccessorView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: AccessorView, context: Context) {
        view.onWindow = onWindow
    }

    final class AccessorView: NSView {
        var onWindow: (@MainActor (NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Lets `NoteWindowState` hand closures to the Info panel it owns before `self` exists.
@MainActor
private final class WeakReference<Object: AnyObject> {
    weak var object: Object?
}

/// One mention link's steps on a note window's undo manager.
private final class LinkUndoTarget {}
