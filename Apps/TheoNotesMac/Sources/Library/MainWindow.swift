// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Observation
import SwiftUI

/// View ▸ layouts (⌃1 / ⌃2 / ⌃3). Choosing the current one again keeps it.
enum LayoutPreset: String, CaseIterable {
    case editorOnly, notesAndEditor, all

    init(_ visibility: NavigationSplitViewVisibility) {
        switch visibility {
        case .detailOnly: self = .editorOnly
        case .doubleColumn: self = .notesAndEditor
        default: self = .all
        }
    }

    /// Editor only hides the sidebar like "notes and editor"; the note list column is collapsed
    /// through AppKit because macOS ignores `.detailOnly` in a three-column split view.
    var columnVisibility: NavigationSplitViewVisibility {
        switch self {
        case .editorOnly, .notesAndEditor: .doubleColumn
        case .all: .all
        }
    }
}

/// The panes that take keyboard focus through SwiftUI (the editor is an AppKit web view).
enum Pane: Hashable {
    case sidebar, noteList
}

/// Irreversible commands that ask first.
enum DestructiveAction: Identifiable, Equatable {
    case emptyTrash, deletePermanently

    var id: Self { self }

    var title: String {
        switch self {
        case .emptyTrash: "Empty Trash?"
        case .deletePermanently: "Delete Permanently?"
        }
    }

    var message: String {
        switch self {
        case .emptyTrash: "All notes in the Trash will be deleted permanently. You can’t undo this action."
        case .deletePermanently: "The selected notes will be deleted permanently. You can’t undo this action."
        }
    }

    var confirmTitle: String {
        switch self {
        case .emptyTrash: "Empty Trash"
        case .deletePermanently: "Delete"
        }
    }
}

extension SidebarScope {
    /// Persisted form: `notes`, `trash`, … and `tag:<path>`.
    var storageValue: String {
        switch self {
        case .notes: "notes"
        case .inbox: "inbox"
        case .type(let type): "type-" + type.rawValue
        case .pinned: "pinned"
        case .untagged: "untagged"
        case .todo: "todo"
        case .today: "today"
        case .locked: "locked"
        case .archive: "archive"
        case .trash: "trash"
        case .tag(let path): "tag:" + path
        }
    }

    init?(storageValue: String) {
        if storageValue.hasPrefix("tag:") {
            let path = String(storageValue.dropFirst(4))
            guard !path.isEmpty else { return nil }
            self = .tag(path)
            return
        }
        let fixed: [SidebarScope] = [.notes, .inbox] + NoteType.allCases.map(SidebarScope.type) + [.pinned, .untagged, .todo, .today, .locked, .archive, .trash]
        guard let scope = fixed.first(where: { $0.storageValue == storageValue }) else { return nil }
        self = scope
    }
}

/// One main window: the library model, its editor, settings, the layout and pending confirmations.
/// Layout, workspace, scope and shown note are kept in `UserDefaults` across launches (shared by
/// all main windows, ruling R13: the last one written wins).
@MainActor
@Observable
final class MainWindowState: FormatTarget {
    private enum Keys {
        static let layout = "MainWindow.layout"
        static let scope = "MainWindow.scope"
        static let note = "MainWindow.note"
        static let workspace = "MainWindow.workspace"
    }

    let model: LibraryModel
    /// Lock Note, Remove Lock, Change Password… and their sheets (M9 task 5).
    let privacy: NotePrivacyController
    let editor: EditorBridgeController
    /// The Info panel of the note this window's editor shows.
    let info: InfoPanelModel
    let settings: SettingsModel
    let importer: ImportModel
    /// The App Lock handler that closes the import sheet and stops a run (removed on close).
    @ObservationIgnored private var importLockToken: AppLock.HandlerToken?
    /// File ▸ Export Notes…, the note list's Export… and a tag's Export Notes… (M8 Task 13).
    let exporter: ExportModel
    /// File ▸ Backup Notes… and Restore Backup… (M8 Task 15).
    let backup: BackupModel
    /// The Next Up card and its two-minute timer (toolbar button and Note ▸ Next Up).
    let nextUp: NextUpModel
    let bridge = WindowBridge()
    /// Also changed by the split view itself (sidebar toggle in the toolbar, View ▸ Show Sidebar).
    /// Showing the sidebar from editor only brings the note list back too.
    var columnVisibility: NavigationSplitViewVisibility {
        didSet {
            if columnVisibility != .doubleColumn { bridge.setNoteListCollapsed(false) }
            saveLayout()
        }
    }
    /// Read from the split view: editor only while the note list column is really collapsed.
    var layout: LayoutPreset { bridge.isNoteListCollapsed ? .editorOnly : LayoutPreset(columnVisibility) }
    var pendingConfirmation: DestructiveAction?
    /// The Sort Inbox sheet's model while the sheet is open (View ▸ Sort Inbox, the Inbox list's button).
    var sortInbox: SortInboxModel?
    /// What the editor's links do (LinkRouter.swift; this window's side in MainWindow+Links.swift).
    @ObservationIgnored let links: LinkRouter
    /// Opens a note in its own window (set by `AppModel`; double-click, Open In New Window).
    @ObservationIgnored var openNoteWindow: (String) -> Void = { _ in }
    /// Called after the window closed (set by `AppModel`, which forgets the window).
    @ObservationIgnored var onClose: () -> Void = {}
    /// ⌘N with "Start new notes with: Template…" set (set by `AppModel`): makes the note from that
    /// template, tagged like a plain one. nil when no usable template is set (a plain note follows).
    @ObservationIgnored var startNoteFromTemplate: () -> TemplateOutcome? = { nil }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private weak var hostWindow: NSWindow?
    @ObservationIgnored private var closeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var isClosed = false

    /// `editor` is injected by tests (with a fake page); the app makes the WebKit one. `settings`
    /// is shared by all windows (one is made when nil).
    init(
        environment: AppEnvironment, defaults: UserDefaults = .standard, editor: EditorBridgeController? = nil,
        settings: SettingsModel? = nil, exportPanel: ExportModel.PanelPresenter? = nil
    ) {
        self.defaults = defaults
        let model = LibraryModel(environment: environment)
        self.model = model
        privacy = NotePrivacyController(library: model)
        let editor = editor ?? EditorBridgeController(environment: environment)
        self.editor = editor
        model.editor = editor
        links = LinkRouter(environment: environment, editor: editor)
        info = InfoPanelModel(library: model, editor: editor)
        let settings = settings ?? SettingsModel(database: environment.database)
        self.settings = settings
        let importer = ImportModel(
            service: LiveImportService(store: environment.store, paths: environment.paths),
            bearCLIPath: { settings.snapshot.bearCLIPath },
            prepare: { environment.flushAll() },
            didImport: { model.refresh() })
        importer.isBlocked = { environment.operations.isBusy || environment.appLock.isLocked }
        importLockToken = environment.appLock.addDidLockHandler { [weak importer] in importer?.appLockEngaged() }
        self.importer = importer
        let exporter = ExportModel(
            service: LiveExportService(environment: environment),
            keepTags: { settings.snapshot.keepTagsOnExport },
            panel: exportPanel ?? { title, chosen, completion, cancelled in
                ExportPanel.choose(
                    title: title, settings: chosen,
                    lightThemeName: ExportPanel.lightThemeName(environment.appearance.snapshot),
                    completion: completion, cancelled: cancelled)
            })
        self.exporter = exporter
        backup = BackupModel(
            environment: environment, didChange: { model.refresh() },
            isBlockedElsewhere: { importer.isRunning || exporter.isRunning || exporter.isChoosing })
        nextUp = NextUpModel(environment: environment, scheduler: environment.reminders, clock: TaskDebounceScheduler(), now: { .now })
        columnVisibility = Self.restoredLayout(defaults.string(forKey: Keys.layout)).columnVisibility
        restoreSelection()
        bridge.onNoteListCollapsedChange = { [weak self] in self?.saveLayout() }
        bridge.editorView = self.editor.webView
        let bridge = bridge
        self.editor.onWebViewReplaced = { _, new in bridge.editorView = new }
        installLinkNavigation()
        installNextUp()
    }

    /// Next Up opens a note in this window, like a link does, and puts the caret where the card
    /// pointed; its timer opens the panel at the end only in the window the user is working in.
    private func installNextUp() {
        nextUp.openNote = { [weak self] noteId, caret in
            guard let self, links.showNote(noteId, caret) else { return false }
            window?.makeKeyAndOrderFront(nil)
            focusEditor()
            return true
        }
        nextUp.canPresentOnTimerEnd = { [weak self] in self?.window?.isKeyWindow == true }
    }

    /// Safety net when the state goes away without a close notification.
    isolated deinit {
        close()
    }

    /// The Format menu (`FormatTarget`) follows this window's editor focus.
    var isEditorFocused: Bool { bridge.isEditorFocused }
    /// Find Next / Previous work whenever a note is shown, also from the note list.
    var canFind: Bool { model.focusedNoteID != nil }

    private func restoreSelection() {
        let scope = defaults.string(forKey: Keys.scope).flatMap(SidebarScope.init(storageValue:)) ?? .notes
        if let workspace = defaults.string(forKey: Keys.workspace), !workspace.isEmpty {
            model.restoreWorkspace(workspace, scope: scope)
        }
        model.selectScope(scope)
        showNotesIfScopeHidden()
        if let id = defaults.string(forKey: Keys.note), model.items.contains(where: { $0.id == id }) {
            model.selectNotes([id])
        }
    }

    /// Whether the sidebar shows a row for the selected scope (Pinned, Locked and Archive only
    /// when non-empty, a tag only while it is in the tag tree).
    var isScopeInSidebar: Bool {
        let counts = model.counts
        switch model.scope {
        case .pinned: return counts.pinned > 0
        case .locked: return counts.locked > 0
        case .archive: return counts.archive > 0
        case .tag(let path): return Self.tree(model.tagTree, contains: path)
        case .notes, .inbox, .type, .untagged, .todo, .today, .trash: return true
        }
    }

    /// Falls back to Notes when the selected scope's sidebar row disappeared (e.g. the last
    /// archived note was restored), and leaves a workspace whose tag no longer exists.
    func showNotesIfScopeHidden() {
        if model.workspace != nil, !model.workspaceTagExists { model.dismissWorkspace() }
        if !isScopeInSidebar { model.selectScope(.notes) }
    }

    private static func tree(_ nodes: [TagNode], contains path: String) -> Bool {
        nodes.contains { $0.path == path || tree($0.children, contains: path) }
    }

    func saveSelection() {
        defaults.set(model.scope.storageValue, forKey: Keys.scope)
        defaults.set(model.focusedNoteID, forKey: Keys.note)
        defaults.set(model.workspace?.path, forKey: Keys.workspace)
    }

    /// The layout a launch starts with. Editor only is never restored, so a new window always shows
    /// the note list and the sidebar toggle in its toolbar.
    static func restoredLayout(_ stored: String?) -> LayoutPreset {
        switch stored.flatMap(LayoutPreset.init(rawValue:)) {
        case .notesAndEditor: .notesAndEditor
        case .all, .editorOnly, nil: .all
        }
    }

    /// Without a split view to collapse the note list in, editor only stays notes and editor.
    func setLayout(_ preset: LayoutPreset) {
        if columnVisibility != preset.columnVisibility { columnVisibility = preset.columnVisibility }
        if bridge.setNoteListCollapsed(preset == .editorOnly), preset == .editorOnly {
            focusEditor() // the hidden list let go of keyboard focus
        }
        saveLayout()
    }

    private func saveLayout() {
        defaults.set(layout.rawValue, forKey: Keys.layout)
    }

    /// ⌘⌫, ⌫ and ⌦ while the note list has keyboard focus move the selected notes to the Trash.
    /// Anywhere else (the editor: ⌘⌫ deletes to the beginning of the line) the key passes on.
    /// Key repeats are swallowed: holding the key trashes one note, not one after another.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        if let window = event.window, bridge.isEditorFirstResponder(in: window), handleFormatShortcut(event) {
            return true
        }
        guard NoteListKeys.isTrashKey(keyCode: event.keyCode, modifiers: event.modifierFlags),
              let window = event.window, bridge.isNoteListFirstResponder(in: window) else { return false }
        if event.isARepeat { return true }
        guard model.commandState.canTrash else { return false }
        model.trashSelected()
        return true
    }

    /// Installs `handleKeyDown` as a local key monitor (one per main window, each acting only on
    /// its own window's events); it runs before menu key equivalents. Removed by `close()`.
    @discardableResult
    func installKeyMonitor() -> Any? {
        if let keyMonitor { return keyMonitor }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKeyDown(event) ?? false }
            return handled ? nil : event
        }
        return keyMonitor
    }

    /// The window this state is shown in, once it is on screen.
    var window: NSWindow? { hostWindow ?? bridge.window }

    /// The window this state is shown in: `close()` runs when it closes, then `onClose`.
    func attach(window: NSWindow) {
        guard window !== hostWindow else { return }
        hostWindow = window
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.close()
                self.onClose()
            }
        }
    }

    /// The window closed: commits its note, lets go of the session and the key monitor.
    /// Order matters: the editor stops listening and flushes before the window's open notes are
    /// cleared, so the session can be evicted. Runs once (also from `deinit` as a safety net).
    func close() {
        guard !isClosed else { return }
        isClosed = true
        privacy.dismissSheet()
        exporter.close()
        if let importLockToken { model.environment.appLock.removeDidLockHandler(importLockToken) }
        importLockToken = nil
        info.close()
        nextUp.close()
        editor.showNoNote()
        model.close()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
    }

    /// Double-click / Open In New Window: each of `ids` (in list order) in its own note window.
    func openInNewWindows(_ ids: Set<String>) {
        model.items.map(\.id).filter(ids.contains).forEach(openNoteWindow)
    }

    /// Shows the focused note in the editor (with the caret `newNote()` chose for it); with no
    /// focused note the editor lets go of the last one.
    func showFocusedNote() {
        guard let id = model.focusedNoteID else {
            editor.showNoNote()
            return
        }
        let caret = model.takeNewNoteCaret(for: id)
        if caret != nil { createdNoteID = id } else if id != createdNoteID { createdNoteID = nil }
        do {
            try editor.open(noteId: id, caret: caret)
        } catch {
            appLogger.error("could not open note \(id, privacy: .public): \(error)")
            model.banner = .commandFailed(action: "opening the note")
            return
        }
        if model.search.resultIDs != nil { searchTermsChanged() }
    }

    // MARK: - Search

    /// Bumped by Edit ▸ Search Notes (⇧⌘F); the search field takes keyboard focus.
    private(set) var searchFocusRequest = 0
    /// A note `newNote()` made while it is shown: it gets no search highlight (it is being written).
    @ObservationIgnored private var createdNoteID: String?

    func focusSearch() {
        if layout == .editorOnly { setLayout(.notesAndEditor) }
        searchFocusRequest += 1
    }

    /// The shown note highlights the search's terms (none once the search is cleared).
    func searchTermsChanged() {
        guard let id = model.focusedNoteID, id != createdNoteID else { return }
        editor.highlightSearch(query: model.search.query, terms: model.search.terms)
    }

    /// ↓ in the search field: the first result becomes the selection; before the typed query's
    /// results arrived, the first of those. False when nothing is listed or coming.
    @discardableResult
    func selectFirstResult() -> Bool {
        if model.search.isAwaitingNewResults {
            model.selectFirstWhenResultsArrive = true
            return true
        }
        guard let first = model.items.first else { return false }
        model.selectNotes([first.id])
        return true
    }

    func newNote() {
        do {
            switch startNoteFromTemplate() {
            case .created(let id, let caret)?: return showNewNote(id, caret: caret)
            case .cancelled?: return
            case .unavailable?, .failed?, nil: _ = try model.newNote()  // R35: a plain note
            }
        } catch {
            appLogger.error("could not create a note: \(error)")
            model.banner = .commandFailed(action: "new note")
            return
        }
        showNewNoteInEditor()
    }

    /// Shows a note just made for this window (from a template: ⌘N's start template, Quick Open,
    /// the ⇧⌘N picker) exactly as ⌘N shows its note: `LibraryModel.showNewNote` (a search it may
    /// not match ends; the scope changes only when it does not list the note), then the editor
    /// with `caret`, focused.
    func showNewNote(_ id: String, caret: Int?) {
        model.showNewNote(id, caret: caret)
        showNewNoteInEditor()
    }

    private func showNewNoteInEditor() {
        showFocusedNote()
        focusEditor()
        // Again after SwiftUI applied this update: the list may take focus back while it selects
        // the new row, and the editor may just have become visible.
        Task { @MainActor [weak self] in self?.focusEditor() }
    }

    func focusEditor() {
        guard model.focusedNoteID != nil else { return }
        editor.focusEditor()
    }

    func confirm(_ action: DestructiveAction) {
        pendingConfirmation = action
    }

    /// Opens Sort Inbox over the Inbox as it is now (nothing when the Inbox is empty).
    func showSortInbox() {
        model.refresh()
        guard sortInbox == nil, model.counts.inbox > 0 else { return }
        sortInbox = SortInboxModel(model: model)
    }

    /// Sort Inbox's "Open": closes the sheet and shows the note in the editor.
    func openFromSortInbox(_ noteId: String) {
        sortInbox = nil
        model.reveal(noteId: noteId)
        focusEditor()
    }

    func perform(_ action: DestructiveAction) {
        pendingConfirmation = nil
        switch action {
        case .emptyTrash: model.emptyTrash()
        case .deletePermanently: model.deleteSelectedPermanently()
        }
    }

    /// The notes a drag starting on `id` carries: the selection (in list order) when `id` is part
    /// of it, otherwise just `id`.
    func draggedNoteIDs(startingAt id: String) -> [String] {
        guard model.selectedNoteIDs.contains(id) else { return [id] }
        return model.items.map(\.id).filter(model.selectedNoteIDs.contains)
    }
}

/// Saves the workspace with the selection and leaves it when its tag disappears.
private struct WorkspaceTracking: ViewModifier {
    let state: MainWindowState

    func body(content: Content) -> some View {
        content
            .onChange(of: state.model.workspace?.path) { state.saveSelection() }
            .onChange(of: state.model.workspaceTagExists) { state.showNotesIfScopeHidden() }
    }
}

/// Sidebar | note list | editor (spec §4.1).
struct MainWindow: View {
    @Bindable var state: MainWindowState
    @FocusState private var pane: Pane?

    private var windowCommandState: WindowCommandState {
        WindowCommandState(
            canGoBack: state.model.canGoBack, canGoForward: state.model.canGoForward,
            isInWorkspace: state.model.workspace != nil
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $state.columnVisibility) {
            SidebarView(
                model: state.model, showNoteCounts: state.settings.snapshot.showNoteCounts, pane: $pane,
                exportTag: state.isExportBlocked ? nil : { state.exporter.exportTagTree($0) },
                emptyTrash: { state.confirm(.emptyTrash) })
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } content: {
            NoteListView(state: state, pane: $pane)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 440)
        } detail: {
            EditorPane(state: state)
        }
        .defaultFocus($pane, .noteList)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { NextUpToolbarButton(model: state.nextUp) }
        }
        .focusedSceneValue(\.mainWindow, state)
        .focusedSceneValue(\.noteCommandState, state.model.commandState)
        .focusedSceneValue(\.noteListFocused, state.bridge.isNoteListFocused)
        .focusedSceneValue(\.windowCommandState, windowCommandState)
        .focusedSceneValue(\.editorMenuState, state.editorMenuState)
        .focusedSceneValue(\.infoPanel, state.info)
        .onChange(of: state.model.scope) { state.saveSelection() }
        .modifier(WorkspaceTracking(state: state))
        .onChange(of: state.model.focusedNoteID) { state.saveSelection() }
        .onChange(of: state.model.search.terms) { state.searchTermsChanged() }
        .onChange(of: state.model.counts) { state.showNotesIfScopeHidden() }
        .onChange(of: state.model.tagTree) { state.showNotesIfScopeHidden() }
        .onReceive(NotificationCenter.default.publisher(for: AppEnvironment.revealRecoveredNote, object: state.model.environment)) { notification in
            guard let id = notification.userInfo?["noteID"] as? String else { return }
            state.model.reveal(noteId: id)
            state.focusEditor()
        }
        .alert(
            state.pendingConfirmation?.title ?? "",
            isPresented: Binding(
                get: { state.pendingConfirmation != nil },
                set: { if !$0 { state.pendingConfirmation = nil } }
            ),
            presenting: state.pendingConfirmation
        ) { action in
            Button(action.confirmTitle, role: .destructive) { state.perform(action) }
            Button("Cancel", role: .cancel) { state.pendingConfirmation = nil }
        } message: { action in
            Text(action.message)
        }
        .sheet(item: Binding(
            get: { state.privacy.sheet },
            set: { if $0 == nil { state.privacy.dismissSheet() } }
        )) { model in
            PasswordSheetView(model: model)
        }
        .sheet(isPresented: Binding(
            get: { state.sortInbox != nil },
            set: { if !$0 { state.sortInbox = nil } }
        )) {
            if let sort = state.sortInbox {
                SortInboxSheet(model: sort, open: state.openFromSortInbox, close: { state.sortInbox = nil })
            }
        }
        .modifier(ImportPresentation(importer: state.importer))
        .modifier(ExportPresentation(exporter: state.exporter))
        .modifier(BackupPresentation(backup: state.backup))
        // Outermost: the palette of the resolved theme for every pane, popover and sheet below.
        .shellPalette(from: state.model.environment.appearance)
    }
}
