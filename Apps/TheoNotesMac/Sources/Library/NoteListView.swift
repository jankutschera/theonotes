// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Declared in Info.plist (`UTExportedTypeDeclarations`).
    static let baerchenNoteIDs = UTType(exportedAs: LegacyNames.noteIDsUTI)
}

/// Notes dragged out of the note list (onto a sidebar tag).
struct NoteDragItem: Codable, Equatable, Transferable {
    var noteIDs: [String]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .baerchenNoteIDs)
    }
}

extension LibraryBanner {
    var message: String {
        switch self {
        case .conflictCopiesCreated(let ids):
            ids.count == 1 ? "Conflict copy created" : "\(ids.count) conflict copies created"
        case .journalsMovedAside(let count):
            count == 1 ? "1 edit journal was recovered" : "\(count) edit journals were recovered"
        case .notesSkipped(let locked, let readOnly, let unsaved):
            Self.skippedMessage(locked: locked, readOnly: readOnly, unsaved: unsaved)
        case .tagOperationFailed(let message):
            message
        case .linksUpdated(let count, _):
            count == 1 ? "Updated links in 1 note" : "Updated links in \(count) notes"
        case .commandFailed(let action):
            action.prefix(1).uppercased() + action.dropFirst() + " failed"
        case .mentionNotLinked(let reason):
            Self.mentionMessage(reason)
        case .notesNotCopied(let locked):
            locked == 1 ? "1 locked note was not copied" : "\(locked) locked notes were not copied"
        case .notesNotLocked(let inTrash, let other):
            Self.notLockedMessage(inTrash: inTrash, other: other)
        case .voiceRecordingRemoved:
            "A voice recording could not be read and was removed."
        }
    }

    /// "1 note in the Trash was not locked", "2 notes could not be locked right now".
    private static func notLockedMessage(inTrash: Int, other: Int) -> String {
        var parts: [String] = []
        if inTrash > 0 {
            parts.append(inTrash == 1 ? "1 note in the Trash was not locked" : "\(inTrash) notes in the Trash were not locked")
        }
        if other > 0 {
            parts.append(other == 1 ? "1 note could not be locked right now" : "\(other) notes could not be locked right now")
        }
        return parts.joined(separator: "; ")
    }

    var actionTitle: String {
        switch self {
        case .conflictCopiesCreated: "Show"
        case .journalsMovedAside: "Show in Settings"
        case .notesSkipped(let locked, _, _): locked > 0 ? "Show Locked" : "OK"
        case .tagOperationFailed: "OK"
        case .linksUpdated: "Undo"
        case .commandFailed: "OK"
        case .mentionNotLinked: "OK"
        case .notesNotCopied: "OK"
        case .notesNotLocked: "OK"
        case .voiceRecordingRemoved: "OK"
        }
    }

    /// Why the Info panel's "Link" did nothing.
    static func mentionMessage(_ reason: MentionLinkError) -> String {
        switch reason {
        case .stale: "Not linked: the note changed since the mention was listed"
        case .notEditable: "Not linked: the note is locked, read-only or archived"
        case .resolvesElsewhere: "Not linked: another note with this title gets the link"
        case .titleNotLinkable: "Not linked: this title can’t be written as a wiki link"
        case .sameNote: "Not linked: a note can’t link to itself here"
        }
    }

    /// "1 locked note was not changed", "1 locked and 2 read-only notes were not changed".
    private static func skippedMessage(locked: Int, readOnly: Int, unsaved: Int) -> String {
        let parts = [(locked, "locked"), (readOnly, "read-only"), (unsaved, "unsaved")].filter { $0.0 > 0 }
        let total = locked + readOnly + unsaved
        let subject = parts.map { "\($0.0) \($0.1)" }.joined(separator: parts.count > 2 ? ", " : " and ")
        return "\(subject) \(total == 1 ? "note was" : "notes were") not changed"
    }

    var systemImage: String {
        switch self {
        case .conflictCopiesCreated: "doc.on.doc"
        case .journalsMovedAside: "exclamationmark.triangle"
        case .notesSkipped: "lock"
        case .tagOperationFailed: "exclamationmark.triangle"
        case .linksUpdated: "link"
        case .commandFailed: "exclamationmark.triangle"
        case .mentionNotLinked: "link.badge.plus"
        case .notesNotCopied: "lock"
        case .notesNotLocked: "lock"
        case .voiceRecordingRemoved: "exclamationmark.triangle"
        }
    }
}

/// The middle column: the notes of the selected scope, multi-select, context menu, drag source.
struct NoteListView: View {
    let state: MainWindowState
    var pane: FocusState<Pane?>.Binding

    @Environment(\.openSettings) private var openSettings
    @Environment(\.undoManager) private var undoManager
    @Environment(\.shellPalette) private var palette
    @AppStorage(SettingsTab.storageKey) private var settingsTab = SettingsTab.general

    private var model: LibraryModel { state.model }

    var body: some View {
        List(selection: Binding(get: { model.selectedNoteIDs }, set: { model.selectNotes($0) })) {
            ForEach(model.items) { item in
                NoteRow(
                    item: item, date: date(of: item), thumbnailURL: thumbnailURL(of: item), terms: model.search.terms,
                    isSelected: model.selectedNoteIDs.contains(item.id))
                    // VoiceOver (M7 Task 12): one label with title, flags and date, the preview as value,
                    // and the context menu's actions by name.
                    .accessibilityLabel(NoteListAccessibility.label(for: item, date: item.modifiedAt, now: .now))
                    .accessibilityValue(NoteListAccessibility.value(for: item))
                    .accessibilityIdentifier(item.id)
                    .accessibilityActions {
                        ForEach(NoteListAccessibility.actions(for: item, inTrash: model.scope == .trash)) { action in
                            Button(action.rawValue) { perform(action, on: item.id) }
                        }
                    }
                    .id(item.id)
                    .tag(item.id)
                    .draggable(NoteDragItem(noteIDs: state.draggedNoteIDs(startingAt: item.id)))
                    .onAppear { if item.id == model.items.last?.id { model.search.loadMore() } }
            }
        }
        // The list is content, not chrome: an opaque theme background (OLED Black reaches it as #000000).
        .scrollContentBackground(.hidden)
        .background(palette.background)
        .background(WindowBridgeAnchor(bridge: state.bridge))
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            // Double-click (↩ is handled below): the note in its own window.
            state.openInNewWindows(ids)
        }
        .accessibilityRotor("Pinned Notes") {
            ForEach(model.items.filter(\.isPinned)) { item in
                AccessibilityRotorEntry(item.title.isEmpty ? "Untitled" : item.title, id: item.id)
            }
        }
        .focused(pane, equals: .noteList)
        .onKeyPress(.return) {
            state.focusEditor()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            state.focusEditor()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            pane.wrappedValue = .sidebar
            return .handled
        }
        .overlay {
            if model.items.isEmpty, !model.search.isAwaitingNewResults {
                ContentUnavailableView {
                    Text(model.search.isActive ? "No Results" : "No Notes")
                        .foregroundStyle(palette.text)
                } description: {
                    Text(model.scope.displayName)
                        .foregroundStyle(palette.secondaryText)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                NoteSearchField(
                    text: Binding(get: { model.search.query }, set: { model.search.query = $0 }),
                    focusRequest: state.searchFocusRequest,
                    onMoveDown: { if state.selectFirstResult() { pane.wrappedValue = .noteList } },
                    onLeave: { pane.wrappedValue = .noteList }
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                if model.scope == .inbox, !model.items.isEmpty {
                    Button("Sort Inbox", systemImage: "tray.full") { state.showSortInbox() }
                        .controlSize(.small)
                        .accessibilityLabel("Sort Inbox")
                        .help("Go through the Inbox one note at a time")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                }
                if let banner = model.banner {
                    BannerBar(banner: banner, action: { showBanner(banner) }, dismiss: model.dismissBanner)
                }
            }
            .background(palette.background)
            .overlay(alignment: .bottom) { Rectangle().fill(palette.separator).frame(height: 1) }
        }
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { model.undoManager = $1 }
        .navigationTitle(model.scope.displayName)
        // The list's title is itself a menu (sort, sections, Export…); the plain title is hidden for it.
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Menu {
                    listMenu
                } label: {
                    // A pull-down like the type menu on the right: the name, truncated in the middle, and the system chevron.
                    Text(model.scope.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 150)
                }
                    .accessibilityLabel("\(model.scope.displayName), list options")
                    .help("Sort, sections and export for this list")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("New Note", systemImage: "square.and.pencil", action: state.newNote)
                    .help("New Note (⌘N)")
            }
        }
    }

    /// The menu on the list's title: sort, the sections and Export… for the whole list.
    @ViewBuilder
    private var listMenu: some View {
        Menu(NoteSortMenu.submenu) { NoteSortMenuItems(settings: state.settings) }
        Menu("Show") {
            ForEach(SectionMenu.items) { entry in
                Button(entry.scope.displayName) { model.selectScope(entry.scope) }
                    .disabled(!SidebarView.isShown(entry.scope, in: model.counts))
            }
        }
        Divider()
        Button("Export…") { state.exporter.exportSelection(model.items.map(\.id)) }
            .disabled(state.isExportBlocked || model.items.isEmpty)
    }

    private func date(of item: NoteListItem) -> Date {
        switch model.sort {
        case .createdAscending, .createdDescending: item.createdAt
        default: item.modifiedAt
        }
    }

    private func thumbnailURL(of item: NoteListItem) -> URL? {
        NoteRow.thumbnailFilename(for: item).map {
            model.environment.paths.attachments.appendingPathComponent(item.id, isDirectory: true).appendingPathComponent($0)
        }
    }

    private func showBanner(_ banner: LibraryBanner) {
        switch banner {
        case .conflictCopiesCreated:
            model.showBannerNote()
        case .journalsMovedAside:
            model.dismissBanner()
            settingsTab = .advanced
            openSettings()
        case .notesSkipped(let locked, _, _):
            model.dismissBanner()
            if locked > 0 { model.selectScope(.locked) }
        case .tagOperationFailed:
            model.dismissBanner()
        case .linksUpdated(_, let rewriteId):
            model.undoLinkRewrite(rewriteId)
        case .commandFailed, .mentionNotLinked, .notesNotCopied, .notesNotLocked, .voiceRecordingRemoved:
            model.dismissBanner()
        }
    }

    /// Right-clicking outside the selection acts on the clicked note, which becomes the selection.
    /// A row's VoiceOver action: the context menu's command for that note.
    private func perform(_ action: NoteAXAction, on id: String) {
        if model.selectedNoteIDs != [id] { model.selectNotes([id]) }
        switch action {
        case .pin, .unpin: model.togglePinSelected()
        case .archive: model.archiveSelected()
        case .trash: model.trashSelected()
        case .restore: model.restoreSelected()
        case .deletePermanently: state.confirm(.deletePermanently)
        case .openInNewWindow: state.openInNewWindows([id])
        case .lockNote: Task { await state.privacy.lockSelectedNotes() }
        case .removeLock: Task { await state.privacy.removeLockFromSelectedNote() }
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<String>) -> some View {
        let commands = NoteCommandState(
            scope: model.scope, items: model.items, selectedNoteIDs: ids, counts: model.counts,
            privacy: model.environment.privacyState
        )
        if commands.hasSelection {
            let select = { if ids != model.selectedNoteIDs { model.selectNotes(ids) } }
            Button("Open In New Window") { state.openInNewWindows(ids) }
            Divider()
            Button(commands.pinTitle) { select(); model.togglePinSelected() }
            if commands.canArchive {
                Button("Archive") { select(); model.archiveSelected() }
            }
            if commands.canTrash {
                Button("Move to Trash") { select(); model.trashSelected() }
            }
            if commands.canRestore {
                Button("Restore") { select(); model.restoreSelected() }
            }
            if commands.canDeletePermanently {
                Button("Delete Permanently…") { select(); state.confirm(.deletePermanently) }
            }
            if commands.canDuplicate {
                Divider()
                Button("Duplicate") { select(); model.duplicateSelected() }
            }
            Divider()
            Button(commands.readOnlyTitle) { select(); model.toggleReadOnlySelected() }
                .disabled(!commands.canSetReadOnly)
            Button(NoteCommandMenu.copyLink) { select(); model.copyLinkSelected() }
            Button(NoteCommandMenu.copyIdentifier) { select(); model.copyIdentifierSelected() }
            Divider()
            Menu(NotePrivacyMenu.submenu) {
                Button(NotePrivacyMenu.lockNote) { select(); Task { await state.privacy.lockSelectedNotes() } }
                    .disabled(!commands.canLockNote)
                Button(NotePrivacyMenu.removeLock) { select(); Task { await state.privacy.removeLockFromSelectedNote() } }
                    .disabled(!commands.canRemoveLock)
                Divider()
                Button(NotePrivacyMenu.changePassword) { state.privacy.changePassword() }
                    .disabled(!commands.privacy.hasPassword)
                Button(NotePrivacyMenu.lockNow) { Task { await model.environment.vault.relockAndFinishCleanup() } }
                    .disabled(!commands.canLockNow)
            }
            Divider()
            // M8 Task 14: Copy As (Task 15 edits near here).
            Menu("Copy As") {
                ForEach(CopyAsFormat.allCases) { format in
                    Button(format.title) { state.copyAs(format, ids: ids) }
                }
                Divider()
                CopyAsKeepTags(settings: state.settings)
            }
            Button("Export…") { state.exporter.exportSelection(model.items.map(\.id).filter(ids.contains)) }
                .disabled(state.isExportBlocked)
            if let tag = commands.removableTag {
                Divider()
                Button("Remove Tag “\(tag)”") { select(); model.removeScopeTagFromSelected() }
            }
        }
    }
}

/// A small non-modal notice above the list.
private struct BannerBar: View {
    let banner: LibraryBanner
    let action: () -> Void
    let dismiss: () -> Void

    @Environment(\.shellPalette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: banner.systemImage)
                .foregroundStyle(palette.accent)
            Text(banner.message)
                .font(.callout)
                .foregroundStyle(palette.selectionText)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button(banner.actionTitle, action: action)
                .controlSize(.small)
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background {
            // The theme's selection tint over its background: opaque, and `selectionText` is its checked pair.
            ZStack {
                palette.background
                palette.selection
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(palette.separator).frame(height: 1) }
    }
}
