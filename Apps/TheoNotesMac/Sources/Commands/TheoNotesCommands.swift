// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import SwiftUI

/// What the note commands may do for a scope and a selection; only listed notes count.
struct NoteCommandState: Equatable {
    static let unavailable = NoteCommandState(scope: .notes, items: [], selectedNoteIDs: [], counts: SidebarCounts())

    /// The vault facts the privacy commands depend on.
    struct PrivacyState: Equatable {
        var hasPassword = false
        var isUnlocked = false
    }

    let scope: SidebarScope
    let hasSelection: Bool
    let allPinned: Bool
    let trashCount: Int
    /// Notes Sort Inbox would go through (the active workspace's Inbox).
    let inboxCount: Int
    let selectedCount: Int
    /// How many of the selected notes are locked.
    let lockedCount: Int
    let privacy: PrivacyState
    /// The sidebar counts: which sections the View ▸ Show … items can reach.
    let counts: SidebarCounts
    /// Every selected note is read-only (the command then offers Allow Editing).
    let allReadOnly: Bool
    /// The type the unlocked selected notes share; nil for none or a mix (see `hasMixedTypes`).
    let currentType: NoteType?
    let hasMixedTypes: Bool
    /// Some selected note is neither locked nor read-only (those are never typed).
    private let hasTypeable: Bool
    /// Every unlocked selected note is read-only: the type actions are off, with a hint.
    let onlyReadOnlyTypeable: Bool

    init(
        scope: SidebarScope, items: [NoteListItem], selectedNoteIDs: Set<String>, counts: SidebarCounts,
        privacy: PrivacyState = PrivacyState(), typeFallback: NoteListItem? = nil
    ) {
        let selected = items.filter { selectedNoteIDs.contains($0.id) }
        // Without a listed selection the type commands act on `typeFallback` (LibraryModel.unlistedFocusedItem).
        let typed = selected.isEmpty ? [typeFallback].compactMap { $0 } : selected
        self.scope = scope
        hasSelection = !selected.isEmpty
        allPinned = hasSelection && selected.allSatisfy(\.isPinned)
        trashCount = counts.trash
        inboxCount = counts.inbox
        selectedCount = selected.count
        lockedCount = selected.filter(\.isLocked).count
        self.privacy = privacy
        self.counts = counts
        allReadOnly = hasSelection && selected.allSatisfy(\.isReadOnly)
        let types = Set(typed.filter { !$0.isLocked }.map(\.noteType))
        hasTypeable = typed.contains { !$0.isLocked && !$0.isReadOnly }
        onlyReadOnlyTypeable = !hasTypeable && !types.isEmpty
        hasMixedTypes = types.count > 1
        currentType = types.count == 1 ? types.first.flatMap { $0 } : nil
    }

    private var inTrash: Bool { scope == .trash }
    private var inArchive: Bool { scope == .archive }

    var canPin: Bool { hasSelection }
    var pinTitle: String { allPinned ? "Unpin" : "Pin" }
    var canArchive: Bool { hasSelection && !inArchive && !inTrash }
    var canTrash: Bool { hasSelection && !inTrash }
    var canRestore: Bool { hasSelection && (inArchive || inTrash) }
    var canDeletePermanently: Bool { hasSelection && inTrash }
    /// A copy of a locked note would need its text; the store refuses it, so the command is hidden.
    var canDuplicate: Bool { hasSelection && !inTrash && lockedCount == 0 }
    var canEmptyTrash: Bool { trashCount > 0 }
    /// A note in the Trash cannot be changed, so it has no read-only switch.
    var canSetReadOnly: Bool { hasSelection && !inTrash }
    var readOnlyTitle: String { allReadOnly ? NoteCommandMenu.allowEditing : NoteCommandMenu.makeReadOnly }
    var canCopyLink: Bool { hasSelection }
    var canSortInbox: Bool { inboxCount > 0 }
    /// Some selected note can carry a type: not locked or read-only, outside the Trash.
    var canSetType: Bool { hasTypeable && !inTrash }
    /// Exactly one selected note outside the Trash (a locked one gets a whole-note reminder).
    var canRemind: Bool { selectedCount == 1 && !inTrash }
    /// Exactly one selected note outside the Trash (a locked one needs the vault open to show anything).
    var canShowHistory: Bool { selectedCount == 1 && !inTrash }

    /// Some selected note is not locked yet, outside the Trash. Offered before a password
    /// exists and while the vault is locked: the command asks for what it needs.
    var canLockNote: Bool { selectedCount > lockedCount && !inTrash }
    /// Exactly one selected note, locked, outside the Trash. A locked vault asks for the password first.
    var canRemoveLock: Bool { selectedCount == 1 && lockedCount == 1 && !inTrash }
    /// Needs a password, not a selection.
    var canChangePassword: Bool { privacy.hasPassword }
    var canLockNow: Bool { privacy.isUnlocked }

    /// The selected tag, when the selection can have it removed.
    var removableTag: String? {
        guard hasSelection, case .tag(let path) = scope else { return nil }
        return path
    }
}

/// Note ▸ Make Read-Only / Allow Editing, Copy Link, Copy Identifier (also the note row's context menu).
enum NoteCommandMenu {
    static let makeReadOnly = "Make Read-Only"
    static let allowEditing = "Allow Editing"
    static let copyLink = "Copy Link"
    static let copyIdentifier = "Copy Identifier"
}

/// The titles of the privacy commands (Note ▸ Privacy and the note list's context menu).
enum NotePrivacyMenu {
    static let submenu = "Privacy"
    static let lockNote = "Lock Note"
    static let removeLock = "Remove Lock from Note"
    static let changePassword = "Change Password…"
    static let lockNow = "Lock Now"
}

/// Note ▸ Remind Me…: the title, and when the command is off.
enum RemindMeMenu {
    static let title = "Remind Me…"

    /// Off without an app, while App Lock is engaged, and without a note to remind about.
    @MainActor
    static func isDisabled(app: AppModel?, hasMainWindow: Bool, hasNoteWindow: Bool, state: NoteCommandState) -> Bool {
        guard let app, !app.isLocked else { return true }
        if hasNoteWindow { return false }
        return !(hasMainWindow && state.canRemind)
    }
}

/// View ▸ Show <section> (and the note list title menu): the sidebar's sections, with Bear's ⌥⌘ numbers where it has them.
@MainActor
enum SectionMenu {
    struct Entry: Identifiable {
        let scope: SidebarScope
        /// The ⌥⌘ number; nil for a section Bear's mapping has no slot for.
        let key: Character?
        var id: SidebarScope { scope }
        var shortcut: KeyboardShortcut? { key.map { KeyboardShortcut(KeyEquivalent($0), modifiers: [.command, .option]) } }
    }

    private static let keys: [SidebarScope: Character] = [
        .notes: "1", .untagged: "2", .todo: "3", .today: "4", .locked: "5", .pinned: "6", .archive: "9", .trash: "0",
    ]

    /// The sidebar's sections in the sidebar's order and under its names.
    static let items: [Entry] = SidebarView.fixedScopes.map { Entry(scope: $0, key: keys[$0]) }

    static func title(_ scope: SidebarScope) -> String { "Show " + scope.displayName }
}

/// View ▸ Note Sorting and the note list title menu: the sort field and order, one setting
/// (`noteSort`), checkmarks on the current choice.
enum NoteSortMenu {
    static let submenu = "Note Sorting"

    static func orderTitle(ascending: Bool, field: NoteSortField) -> String {
        field == .title ? (ascending ? "A to Z" : "Z to A") : (ascending ? "Oldest First" : "Newest First")
    }
}

struct NoteSortMenuItems: View {
    let settings: SettingsModel

    var body: some View {
        let sort = settings.snapshot.noteSort
        ForEach(NoteSortField.allCases) { field in
            Toggle(field.title, isOn: Binding(
                get: { sort.field == field },
                set: { if $0 { settings.set(.noteSort, NoteSort(field: field, ascending: sort.isAscending)) } }
            ))
        }
        Divider()
        ForEach([false, true], id: \.self) { ascending in
            Toggle(NoteSortMenu.orderTitle(ascending: ascending, field: sort.field), isOn: Binding(
                get: { sort.isAscending == ascending },
                set: { if $0 { settings.set(.noteSort, NoteSort(field: sort.field, ascending: ascending)) } }
            ))
        }
    }
}

extension FocusedValues {
    @Entry var mainWindow: MainWindowState?
    /// Published separately so the menus re-validate whenever scope or selection change.
    @Entry var noteCommandState: NoteCommandState?
    /// ⌘⌫ trashes notes only while the note list has keyboard focus (read from AppKit, see
    /// `WindowBridge`); in the editor it stays "delete to the beginning of the line".
    @Entry var noteListFocused: Bool?
    /// The focused separate note window (Float on Top, its own history).
    @Entry var noteWindow: NoteWindowState?
    /// Published separately (like `noteCommandState`) so Go Back / Go Forward and the Float on
    /// Top checkmark re-validate.
    @Entry var windowCommandState: WindowCommandState?
    /// The Format menu's enabled state and checkmarks (`MainWindowState.editorMenuState`).
    @Entry var editorMenuState: EditorMenuState?
}

/// Menu bar commands (inventory §2.17.1): File ▸ New Note / New Window / Empty Trash, Note ▸ …,
/// View ▸ layouts, history and Dismiss Workspace, Window ▸ Float on Top / Main Window.
struct TheoNotesCommands: Commands {
    let app: AppModel?

    @FocusedValue(\.mainWindow) private var window
    @FocusedValue(\.noteCommandState) private var focusedState
    @FocusedValue(\.noteListFocused) private var noteListFocused
    @FocusedValue(\.noteWindow) private var noteWindow
    @FocusedValue(\.windowCommandState) private var windowCommandState
    @FocusedValue(\.editorMenuState) private var editorMenuState
    @AppStorage(FormattingBar.shownKey) private var showsFormattingBar = true

    private var state: NoteCommandState { focusedState ?? .unavailable }

    private func setZoom(_ step: (Double) -> Double) {
        guard let settings = app?.settings else { return }
        settings.set(.editorZoom, step(EditorZoom.snap(settings.snapshot.editorZoom)))
    }
    private var windowState: WindowCommandState { windowCommandState ?? WindowCommandState() }
    /// Find Next / Previous act on the key window's editor, a main or a note window.
    private var findTarget: (any FormatTarget)? { FormatRouting.target(mainWindow: window, noteWindow: noteWindow) }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") {
                if let window { window.newNote() } else { app?.newNoteInMainWindow() }
            }
            .keyboardShortcut("n")
            .disabled(app?.isLocked == true || (app == nil && window == nil))
            Button("New Note in New Window") { app?.newNoteInNewWindow(from: window ?? app?.frontmostMainWindow) }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(app == nil || app?.isLocked == true)
            Button("New Note from Template…") { app?.showTemplatePicker(main: window, noteWindow: noteWindow) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(app == nil || app?.isLocked == true)
            // No shortcut on purpose.
            Button("New Window") { app?.newMainWindow() }
                .disabled(app == nil)
            Divider()
            // Capture Thought lives on its global shortcut and the menu bar item (A7).
            // No keyboard shortcut.
            CaptureVoiceNoteButton(app: app)
            // Not in a `.saveItem` group: a non-document app has none, and SwiftUI then drops the group's items.
            Divider()
            Button("Empty Trash…") { window?.confirm(.emptyTrash) }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(!state.canEmptyTrash)
        }
        // No system Show/Hide Toolbar (⌥⌘T) or Customize Toolbar, so ⌥⌘T has one owner,
        // Format ▸ Table ▸ Create Table, as in Bear.
        CommandGroup(replacing: .toolbar) {}

        CommandGroup(after: .textEditing) {
            Menu("Find") {
                // Main windows only: a note window has no note list to search.
                Button("Search Notes") { window?.focusSearch() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(window == nil)
                ForEach(FindMenu.items) { item in
                    Button(item.title) { findTarget?.perform(item) }
                        .keyboardShortcut(item.shortcut)
                        .disabled(!item.isEnabled(in: editorMenuState ?? .unavailable))
                }
            }
            // M6 Task 14: Edit ▸ Typewriter Mode (⌃⌘T), an app-wide setting. ⌃⌘T has
            // one owner; View ▸ Zoom (⌘+ ⌘- ⌘0) uses other keys.
            Toggle("Typewriter Mode", isOn: Binding(
                get: { app?.settings.snapshot.typewriterMode ?? false },
                set: { app?.settings.set(.typewriterMode, $0) }
            ))
            .keyboardShortcut("t", modifiers: [.command, .control])
            .disabled(app == nil)
            // No keyboard shortcut. Needs an editable note with the keyboard focus in its editor.
            InsertVoiceNoteButton(
                app: app, main: window, noteWindow: noteWindow, editorEnabled: editorMenuState?.enabled == true)
        }

        CommandMenu("Note") {
            Button("Open In New Window") { window?.openInNewWindows(window?.model.selectedNoteIDs ?? []) }
                .disabled(!state.hasSelection)
            Divider()
            Button(state.pinTitle) { window?.model.togglePinSelected() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!state.canPin)
            Button("Archive") { window?.model.archiveSelected() }
                .disabled(!state.canArchive)
            Button("Move to Trash") { window?.model.trashSelected() }
                .keyboardShortcut(noteListFocused == true ? KeyboardShortcut(.delete, modifiers: .command) : nil)
                .disabled(!state.canTrash)
            Button("Restore") { window?.model.restoreSelected() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!state.canRestore)
            Button("Delete Permanently…") { window?.confirm(.deletePermanently) }
                .disabled(!state.canDeletePermanently)
            Divider()
            Button("Duplicate") { window?.model.duplicateSelected() }
                .disabled(!state.canDuplicate)
            Button(state.readOnlyTitle) { window?.model.toggleReadOnlySelected() }
                .disabled(!state.canSetReadOnly)
            Button(NoteCommandMenu.copyLink) { window?.model.copyLinkSelected() }
                .keyboardShortcut("l", modifiers: [.command, .option, .shift])
                .disabled(!state.canCopyLink)
            Button(NoteCommandMenu.copyIdentifier) { window?.model.copyIdentifierSelected() }
                .keyboardShortcut("i", modifiers: [.command, .option, .shift])
                .disabled(!state.canCopyLink)
            Button(RemindMeMenu.title) {
                app?.remindMe(main: window, noteWindow: noteWindow, editorFocused: editorMenuState?.canOpenLink == true)
            }
            .disabled(RemindMeMenu.isDisabled(app: app, hasMainWindow: window != nil, hasNoteWindow: noteWindow != nil, state: state))
            // No keyboard shortcut.
            Button(NoteHistoryMenu.title) { app?.showNoteHistory(main: window, noteWindow: noteWindow) }
                .disabled(NoteHistoryMenu.isDisabled(
                    app: app, hasMainWindow: window != nil, hasNoteWindow: noteWindow != nil, state: state))
            // No keyboard shortcut.
            Button(NextUpMenu.title) { app?.showNextUp(preferring: window) }
                .disabled(NextUpMenu.isDisabled(app: app, hasMainWindow: window != nil || app?.frontmostMainWindow != nil))
            Divider()
            Menu(NoteTypeMenu.submenu) {
                NoteTypeMenuItems(state: state, shortcuts: true) { window?.model.setType($0, undoManager: window?.model.undoManager) }
            }
            Menu(NotePrivacyMenu.submenu) {
                Button(NotePrivacyMenu.lockNote) { Task { await window?.privacy.lockSelectedNotes() } }
                    .disabled(!state.canLockNote)
                Button(NotePrivacyMenu.removeLock) { Task { await window?.privacy.removeLockFromSelectedNote() } }
                    .disabled(!state.canRemoveLock)
                Divider()
                Button(NotePrivacyMenu.changePassword) { window?.privacy.changePassword() }
                    .disabled(window == nil || !state.canChangePassword)
                // Any window: relocking needs no sheet.
                Button(NotePrivacyMenu.lockNow) { Task { await app?.environment.vault.relockAndFinishCleanup() } }
                    .disabled(app?.environment.vault.isUnlocked != true)
            }
            if let tag = state.removableTag {
                Button("Remove Tag “\(tag)”") { window?.model.removeScopeTagFromSelected() }
            }
        }

        CommandGroup(before: .sidebar) {
            // Bear's numbering (⌥⌘1–6, 9, 0); a section the sidebar hides (nothing pinned, locked or archived) is off.
            ForEach(SectionMenu.items) { entry in
                Button(SectionMenu.title(entry.scope)) { window?.model.selectScope(entry.scope) }
                    .keyboardShortcut(entry.shortcut)
                    .disabled(window == nil || !SidebarView.isShown(entry.scope, in: state.counts))
            }
            Divider()
            Group {
                Button("Show Editor Only") { window?.setLayout(.editorOnly) }
                    .keyboardShortcut("1", modifiers: .control)
                Button("Show Notes and Editor") { window?.setLayout(.notesAndEditor) }
                    .keyboardShortcut("2", modifiers: .control)
                Button("Show Tags, Notes and Editor") { window?.setLayout(.all) }
                    .keyboardShortcut("3", modifiers: .control)
            }
            .disabled(window == nil)
            Divider()
            // History of the notes this window showed (per window, also in note windows).
            Button("Go Back") {
                if let window { window.model.goBack() } else { noteWindow?.goBack() }
            }
            .keyboardShortcut("[")
            .disabled(!windowState.canGoBack)
            Button("Go Forward") {
                if let window { window.model.goForward() } else { noteWindow?.goForward() }
            }
            .keyboardShortcut("]")
            .disabled(!windowState.canGoForward)
            Divider()
            // ⇧⌘0 (the insert-hours date shortcut moved to ⌃⇧⌘0, spec §4.2).
            Button("Dismiss Workspace") { window?.model.dismissWorkspace() }
                .keyboardShortcut("0", modifiers: [.command, .shift])
                .disabled(window == nil || !windowState.isInWorkspace)
            // Quick Open lives in View.
            Button("Quick Open…") { app?.showQuickOpen(main: window, noteWindow: noteWindow) }
                .keyboardShortcut("o")
                .disabled(app == nil || app?.isLocked == true)
            Divider()
            Menu(NoteSortMenu.submenu) {
                if let settings = app?.settings { NoteSortMenuItems(settings: settings) }
            }
            .disabled(app == nil)
            // No keyboard shortcut: its buttons use single keys inside the sheet.
            Button("Sort Inbox") { window?.showSortInbox() }
                .disabled(window == nil || !state.canSortInbox)
            Divider()
            // M7 Task 10: one app-wide editor zoom (`EditorZoom`) under View ▸ Zoom. ⌘+ is its
            // own key on German layouts; a ⌘= item would be ⇧⌘0 there (Dismiss Workspace), so there is none.
            Button("Zoom In") { setZoom(EditorZoom.zoomIn) }
                .keyboardShortcut("+")
                .disabled(app == nil)
            Button("Zoom Out") { setZoom(EditorZoom.zoomOut) }
                .keyboardShortcut("-")
                .disabled(app == nil)
            Button("Actual Size") { setZoom { _ in EditorZoom.actualSize } }
                .keyboardShortcut("0")
                .disabled(app == nil || EditorZoom.snap(app?.settings.snapshot.editorZoom ?? 1) == EditorZoom.actualSize)
            Divider()
            // One app-wide switch for the bar under the editor of every window.
            Button(FormattingBar.viewMenuTitle(shown: showsFormattingBar)) { showsFormattingBar.toggle() }
                .keyboardShortcut(FormattingBar.shortcut)
            Divider()
        }

        CommandGroup(after: .windowArrangement) {
            Divider()
            // Note windows only (Bear: Window ▸ Float on Top for a detached note window).
            Toggle("Float on Top", isOn: Binding(
                get: { windowState.isFloating ?? false },
                set: { noteWindow?.isFloating = $0 }
            ))
            .disabled(noteWindow == nil || windowState.isFloating == nil)
            Button("Main Window") { app?.showMainWindow() }
                .keyboardShortcut("\\")
                .disabled(app == nil)
        }
    }
}
