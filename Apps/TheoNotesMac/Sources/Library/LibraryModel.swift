// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import Observation

/// A non-modal notice in the note list header.
enum LibraryBanner: Equatable {
    /// "N conflict copies created"; `showBannerNote()` selects them.
    case conflictCopiesCreated(noteIds: [String])
    /// Launch recovery could not replay these journals; they are listed in Settings → Advanced.
    case journalsMovedAside(count: Int)
    /// A tag rename or delete, or a link update, left these locked, read-only (R10) and unsaved
    /// (open with edits not in the store) notes unchanged.
    case notesSkipped(locked: Int, readOnly: Int, unsaved: Int = 0)
    /// A tag rename or delete was refused or failed.
    case tagOperationFailed(message: String)
    /// A title change updated wiki links in these many other notes; the action undoes it.
    case linksUpdated(noteCount: Int, rewriteId: UUID)
    /// A note command the store refused (nothing changed); `action` as in `perform`.
    case commandFailed(action: String)
    /// The Info panel's "Link" was refused; nothing changed.
    case mentionNotLinked(MentionLinkError)
    /// Copy As left out locked notes.
    case notesNotCopied(locked: Int)
    /// Lock Note left these notes unlocked: in the Trash, or busy (unsaved text, attachments still
    /// being stored, a refused store).
    case notesNotLocked(inTrash: Int, other: Int)
    /// Launch recovery removed a voice recording that could not be played.
    case voiceRecordingRemoved
}

/// One main window's state behind the three panes: workspace, scope, selection, history, the
/// listed notes, tag tree and counts, plus the note commands. Refreshed by one GRDB observation (this process's
/// writes) and by the change notifier (other processes' writes). Everything shared between windows
/// (store, sessions, conflict-copy reports) lives in `AppEnvironment`.
@MainActor
@Observable
final class LibraryModel: LinkUpdatePresenter {
    /// Where the editor puts the caret when it first shows a note made by `newNote()`.
    struct Caret: Equatable {
        var noteId: String
        var utf16Offset: Int
    }

    let environment: AppEnvironment

    var scope: SidebarScope = .notes {
        didSet { if scope != oldValue { locationChanged() } }
    }
    /// The window's workspace (spec §3.5): lists, counts, the tag tree and search cover only the
    /// notes carrying its tag or a descendant. Set through `enterWorkspace` / `dismissWorkspace`.
    private(set) var workspace: Workspace? {
        didSet { if workspace != oldValue { locationChanged() } }
    }
    /// The workspace switcher's pinned root tags and recent workspaces.
    private(set) var workspaceChoices = WorkspaceChoices()
    /// False when the workspace's tag no longer exists (`MainWindowState` then dismisses it).
    private(set) var workspaceTagExists = true
    /// The note-list search; while it shows results, `items` are the scope's matching notes.
    let search: NoteSearch
    var selectedNoteIDs: Set<String> = []
    /// The note shown in the editor; every note shown is a visit in this window's history.
    var focusedNoteID: String? {
        didSet {
            guard focusedNoteID != oldValue, !isClosed else { return }
            let open = Set([focusedNoteID].compactMap { $0 })
            environment.setOpenNoteIds(open, for: ObjectIdentifier(self))
            if let focusedNoteID { history.visit(focusedNoteID) }
            updateUnlistedFocusedItem()
        }
    }
    /// The note the editor shows when the list no longer has it (typing an Inbox note moves it
    /// out): the type commands keep acting on it while nothing listed is selected.
    private(set) var unlistedFocusedItem: NoteListItem?
    /// Back/forward through the notes this window showed (⌘[ / ⌘]).
    private(set) var history = NoteHistory()
    /// The listed notes: the scope's, or while searching the loaded results (in the same order).
    private(set) var items: [NoteListItem] = []
    @ObservationIgnored private var scopeItems: [NoteListItem] = []
    private(set) var tagTree: [TagNode] = []
    private(set) var counts = SidebarCounts()
    private(set) var sort = SettingKey<NoteSort>.noteSort.defaultValue
    /// The notice shown; later ones wait in `queuedBanners` until it is dismissed.
    var banner: LibraryBanner?
    private(set) var newNoteCaret: Caret?
    /// The window's undo manager, for link rewrites (they happen after typing, not on a user
    /// action that could pass one).
    @ObservationIgnored weak var undoManager: UndoManager?
    /// This window's editor (set by `MainWindowState`): a type set on the note it shows is an edit in it.
    @ObservationIgnored weak var editor: EditorBridgeController?

    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var observation: ObservationToken?
    @ObservationIgnored private var queuedBanners: [LibraryBanner] = []
    @ObservationIgnored private var notifierObservation: ObservationToken?
    /// Link rewrites whose banner may still offer Undo.
    @ObservationIgnored private var linkRewrites: [UUID: LinkRewriteRecord] = [:]
    @ObservationIgnored private var conflictCopyObserver: AppEnvironment.ObserverToken?
    @ObservationIgnored private var tagRenameObserver: AppEnvironment.ObserverToken?
    @ObservationIgnored private var isClosed = false
    /// Scope and workspace change together: one restart of the observation and the search.
    @ObservationIgnored private var isChangingLocation = false

    init(
        environment: AppEnvironment, calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.environment = environment
        self.calendar = calendar
        self.now = now
        search = NoteSearch(runner: NoteSearch.live(database: environment.database, calendar: calendar, now: now))
        environment.linkUpdater?.addPresenter(self)
        conflictCopyObserver = environment.addConflictCopyObserver { [weak self] in self?.conflictCopyCreated($0) }
        environment.takePendingConflictCopies().forEach(conflictCopyCreated)
        tagRenameObserver = environment.addTagRenameObserver { [weak self] in self?.followRename(from: $0, to: $1) }
        if banner == nil, !environment.journalsMovedAsideAtLaunch.isEmpty {
            banner = .journalsMovedAside(count: environment.journalsMovedAsideAtLaunch.count)
        }
        if banner == nil, let aborted = try? environment.abortedJournalNoteIDs(), !aborted.isEmpty {
            banner = .journalsMovedAside(count: aborted.count)
        }
        if banner == nil, let pending = try? environment.pendingVariantNoteIDs(), !pending.isEmpty {
            banner = .journalsMovedAside(count: pending.count)
        }
        if banner == nil, !environment.recoveredVariantGroups.isEmpty {
            banner = .journalsMovedAside(count: environment.recoveredVariantGroups.count)
        }
        if banner == nil, !environment.recoveredSingleJournals.isEmpty {
            banner = .journalsMovedAside(count: environment.recoveredSingleJournals.count)
        }
        if banner == nil, !environment.variantQuarantineFiles.isEmpty {
            banner = .journalsMovedAside(count: environment.variantQuarantineFiles.count)
        }
        if banner == nil, !environment.markerMoveNames.isEmpty {
            banner = .journalsMovedAside(count: environment.markerMoveNames.count)
        }
        if banner == nil, environment.journalKeyState != nil {
            banner = .journalsMovedAside(count: 1)
        }
        if banner == nil, !environment.variantRetryNoteIDs.isEmpty {
            banner = .journalsMovedAside(count: environment.variantRetryNoteIDs.count)
        }
        if environment.takeUnplayableRecordingNotice() { post(.voiceRecordingRemoved) }
        notifierObservation = environment.notifier.observe { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        startObservation()
        search.onResults = { [weak self] in self?.searchResultsChanged(isNewSearch: $0) }
    }

    isolated deinit {
        close()
    }

    /// The window closed: link updates still waiting run now (still presented here), then it
    /// shows no note any more and stops receiving conflict copies and link updates.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        runPendingLinkRewrites()
        environment.linkUpdater?.removePresenter(self)
        environment.setOpenNoteIds([], for: ObjectIdentifier(self))
        if let conflictCopyObserver { environment.removeConflictCopyObserver(conflictCopyObserver) }
        conflictCopyObserver = nil
        if let tagRenameObserver { environment.removeTagRenameObserver(tagRenameObserver) }
        tagRenameObserver = nil
        observation?.cancel()
        notifierObservation?.cancel()
    }

    private var store: NoteStore { environment.store }

    // MARK: - Refresh

    /// Re-reads everything synchronously (other processes' writes, the clock for Today).
    func refresh() {
        do {
            let scope = scope, workspace = workspace, now = now(), calendar = calendar
            apply(try environment.database.pool.read {
                try LibraryQueries.snapshot(scope: scope, workspace: workspace, now: now, calendar: calendar, db: $0)
            })
        } catch {
            appLogger.error("library refresh failed: \(error)")
        }
    }

    private func locationChanged() {
        guard !isChangingLocation else { return }
        search.update(scope: scope, sort: sort, workspace: workspace)
        startObservation()
    }

    /// Sets scope and workspace with one restart (when either changed).
    private func setLocation(scope newScope: SidebarScope, workspace newWorkspace: Workspace?) {
        let changed = newScope != scope || newWorkspace != workspace
        isChangingLocation = true
        scope = newScope
        workspace = newWorkspace
        isChangingLocation = false
        if changed { locationChanged() }
    }

    private func startObservation() {
        observation?.cancel()
        observation = LibraryQueries.observeSnapshot(
            scope: scope, workspace: workspace, database: environment.database, calendar: calendar, now: now,
            onError: { appLogger.error("library observation failed: \($0)") },
            onChange: { [weak self] in self?.apply($0) }
        )
    }

    private func apply(_ snapshot: LibrarySnapshot) {
        let listChanged = scopeItems != snapshot.items
        if listChanged {
            scopeItems = snapshot.items
            showListedItems()
        }
        if tagTree != snapshot.tagTree { tagTree = snapshot.tagTree }
        if counts != snapshot.counts { counts = snapshot.counts }
        if sort != snapshot.sort { sort = snapshot.sort }
        if workspaceChoices != snapshot.workspaceChoices { workspaceChoices = snapshot.workspaceChoices }
        if workspaceTagExists != snapshot.workspaceExists { workspaceTagExists = snapshot.workspaceExists }
        search.update(scope: scope, sort: sort, workspace: workspace)
        // Any change to the scope's list (text, pins, locations) may change what matches.
        if listChanged { search.refresh() }
        updateUnlistedFocusedItem()
    }

    private func updateUnlistedFocusedItem() {
        var item: NoteListItem?
        if let id = focusedNoteID, !items.contains(where: { $0.id == id }) {
            item = (try? environment.database.pool.read { try LibraryQueries.item(id: id, db: $0) }) ?? nil
        }
        if unlistedFocusedItem != item { unlistedFocusedItem = item }
    }

    /// The scope's notes, filtered to the search results while a search shows them. Both come in
    /// the same order (pinned, then `sort`), and the scope rows are the fresher ones.
    private func showListedItems() {
        var listed = scopeItems
        if let ids = search.resultIDs {
            let matching = Set(ids)
            listed = scopeItems.filter { matching.contains($0.id) }
        }
        if items != listed { items = listed }
    }

    /// A new query or scope keeps the shown note when it matches, else shows the first result. A
    /// refresh (the library changed, e.g. typing in the shown note) never moves the editor.
    private func searchResultsChanged(isNewSearch: Bool) {
        showListedItems()
        updateUnlistedFocusedItem()
        guard isNewSearch else { return }
        let selectFirst = selectFirstWhenResultsArrive
        selectFirstWhenResultsArrive = false
        if selectFirst, let first = items.first {
            selectNotes([first.id])
        } else {
            keepFocusOrSelectFirst()
        }
    }

    /// ↓ in the search field before the results of the typed query arrived: the first of those
    /// becomes the selection (never a stale result of the query before).
    @ObservationIgnored var selectFirstWhenResultsArrive = false

    // MARK: - Commands

    /// A new note, tagged with the selected tag and the tags the search requires (`tagPosition`
    /// decides where), selected and focused. A search that the note may not match ends.
    @discardableResult
    func newNote() throws -> String {
        let caret = try createNoteForScope()
        return showNewNote(caret.noteId, caret: caret.utf16Offset)
    }

    /// Selects and focuses a note just made for this window (by `newNote()`, or from a template
    /// with `newNoteTagPaths()`): a search it may not match ends, and the scope only changes
    /// when the note is not listed in it. `caret` is where its editor starts (nil: the default).
    @discardableResult
    func showNewNote(_ id: String, caret: Int?) -> String {
        let keepsSearch = searchRequiredTags.onlyTags
        newNoteCaret = caret.map { Caret(noteId: id, utf16Offset: $0) }
        if !keepsSearch { search.clear() }
        refresh()
        if !scopeItems.contains(where: { $0.id == id }) { scope = .notes }
        selectedNoteIDs = [id]
        focusedNoteID = id
        return id
    }

    /// The tags a new note gets from the search; `onlyTags` when the search may stay (none runs, or
    /// the note matches it).
    private var searchRequiredTags: NoteSearch.RequiredTags {
        search.isActive ? NoteSearch.requiredTags(in: search.query) : .init(tags: [], onlyTags: true)
    }

    /// The tags a new note gets from the selected tag and the tags the search requires, once each.
    private func scopeAndSearchTags() throws -> [(name: String, token: String)] {
        var tags: [(name: String, token: String)] = []
        if case .tag(let path) = scope { tags.append(try NoteStore.tagToken(path)) }
        for path in searchRequiredTags.tags {
            guard let tag = try? NoteStore.tagToken(path),
                  !tags.contains(where: { CanonicalKey.make($0.name) == CanonicalKey.make(tag.name) }) else { continue }
            tags.append(tag)
        }
        return tags
    }

    /// The same tags as paths, for a note made from a template (the workspace's tag is added by
    /// `NoteStore.createFromTemplate`, under the same rule as `createNoteForScope`).
    func newNoteTagPaths() throws -> [String] {
        try scopeAndSearchTags().map(\.name)
    }

    /// Creates a note for the selected scope (tagged with the selected tag, the tags the search
    /// requires and, unless one of those lies inside it, the workspace's tag, where `tagPosition`
    /// says) and returns it with the caret its editor starts with. Selects nothing and leaves the
    /// search alone.
    func createNoteForScope() throws -> Caret {
        var text = "", caret = 0
        let tokens = try NoteStore.newNoteTagTokens(carrying: [], extraTags: newNoteTagPaths(), workspace: workspace)
        if !tokens.isEmpty {
            let token = tokens.joined(separator: " ")
            switch Settings(db: environment.database).tagPosition {
            case .bottom:
                text = "\n\n" + token
            case .top:
                text = token + "\n\n"
                caret = text.utf16.count
            }
        }
        return Caret(noteId: try store.create(text: text).id, utf16Offset: caret)
    }

    func trashSelected() {
        perform("trash") { try store.trash($0) }
    }

    func restoreSelected() {
        perform("restore") { try store.restore($0) }
    }

    func archiveSelected() {
        perform("archive") { try store.archive($0) }
    }

    /// Where `archiveWithUndo` / `trashWithUndo` put notes.
    enum Relocation: Sendable {
        case archive, trash

        var actionName: String { self == .archive ? "Archive" : "Move to Trash" }
    }

    /// Archives notes as one undo step on `undoManager` (its undo and redo move them back and
    /// again). False when the store refused.
    @discardableResult
    func archiveWithUndo(_ ids: [String], undoManager: UndoManager?) -> Bool {
        relocate(ids, to: .archive, undoManager: undoManager)
    }

    @discardableResult
    func trashWithUndo(_ ids: [String], undoManager: UndoManager?) -> Bool {
        relocate(ids, to: .trash, undoManager: undoManager)
    }

    private func relocate(_ ids: [String], to place: Relocation, undoManager: UndoManager?) -> Bool {
        guard !ids.isEmpty else { return true }
        let previousOrder = items.map(\.id)
        do {
            switch place {
            case .archive: try store.archive(ids)
            case .trash: try store.trash(ids)
            }
        } catch {
            appLogger.error("\(place.actionName, privacy: .public) of \(ids.count) notes failed: \(error)")
            banner = .commandFailed(action: place.actionName.lowercased())
            return false
        }
        refresh()
        repairFocus(previousOrder: previousOrder)
        guard let undoManager else { return true }
        undoManager.registerUndo(withTarget: self) { [weak undoManager] model in
            MainActor.assumeIsolated {
                do {
                    try model.store.restore(ids)
                } catch {
                    appLogger.error("undo \(place.actionName, privacy: .public) failed: \(error)")
                }
                model.refresh()
                guard let undoManager else { return }
                undoManager.registerUndo(withTarget: model) { [weak undoManager] model in
                    MainActor.assumeIsolated { model.relocate(ids, to: place, undoManager: undoManager) }
                }
                undoManager.setActionName(place.actionName)
            }
        }
        undoManager.setActionName(place.actionName)
        return true
    }

    /// Pins all selected notes unless all are pinned already (then unpins). Within a tag scope
    /// the pin is per tag, elsewhere global.
    func togglePinSelected() {
        perform("pin") { ids in
            let pin = !items.filter { ids.contains($0.id) }.allSatisfy(\.isPinned)
            if case .tag(let path) = scope {
                try store.setPinned(ids, pinned: pin, inTag: path)
            } else {
                try store.setPinned(ids, pinned: pin)
            }
        }
    }

    func deleteSelectedPermanently() {
        perform("delete") { ids in
            try environment.closeSessions(ids: ids) { try store.deletePermanently(ids) }
        }
    }

    func emptyTrash() {
        let previousOrder = items.map(\.id)
        do {
            let ids = try store.allNotes(location: .trash).map(\.id)
            _ = try environment.closeSessions(ids: ids) { try store.emptyTrash(ids: ids) }
        } catch {
            appLogger.error("empty trash failed: \(error)")
            banner = .commandFailed(action: "empty trash")
        }
        refresh()
        repairFocus(previousOrder: previousOrder)
    }

    /// Copies of the selected notes, which become the selection (the first one focused).
    func duplicateSelected() {
        var copies: [String] = []
        perform("duplicate") { ids in copies = try ids.map { try store.duplicate(id: $0).id } }
        guard !copies.isEmpty else { return }
        selectedNoteIDs = Set(copies)
        focusedNoteID = copies[0]
    }

    /// Make Read-Only / Allow Editing on the selected notes: all become editable when every one is
    /// read-only, else all become read-only (the core's `setReadOnly`, as on iPhone and iPad).
    func toggleReadOnlySelected() {
        let makeReadOnly = !items.filter { selectedNoteIDs.contains($0.id) }.allSatisfy(\.isReadOnly)
        environment.flushAll()
        perform("read-only") { ids in
            for id in ids { try store.setReadOnly(id, readOnly: makeReadOnly) }
        }
    }

    /// Copy Link: the note's `theonotes://` link; several notes give one link per line.
    func copyLinkSelected() {
        copyToPasteboard(selectedListedIDs.map { NoteLink.url(id: $0).absoluteString })
    }

    /// Copy Identifier: the note's id, one per line for several notes.
    func copyIdentifierSelected() {
        copyToPasteboard(selectedListedIDs)
    }

    private var selectedListedIDs: [String] { items.map(\.id).filter(selectedNoteIDs.contains) }

    /// Where Copy Link and Copy Identifier write (a test's own pasteboard, never the user's).
    @ObservationIgnored var pasteboard = NSPasteboard.general

    private func copyToPasteboard(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
    }

    // MARK: - Banner

    /// Shows what the banner is about: the conflict copies in Notes.
    func showBannerNote() {
        guard case .conflictCopiesCreated(let ids) = banner else { return }
        dismissBanner()
        search.clear()
        ids.forEach(leaveWorkspaceUnlessItHolds)
        scope = .notes
        refresh()
        selectedNoteIDs = Set(ids)
        focusedNoteID = ids.first
    }

    /// Hides the banner and shows the next queued one, if any.
    func dismissBanner() {
        if case .linksUpdated(_, let id)? = banner { linkRewrites[id] = nil }
        banner = queuedBanners.isEmpty ? nil : queuedBanners.removeFirst()
    }

    /// Shows `notice`, or queues it behind the banner already showing.
    func showNotice(_ notice: LibraryBanner) { post(notice) }

    private func post(_ notice: LibraryBanner) {
        if banner == nil {
            banner = notice
        } else if banner != notice && !queuedBanners.contains(notice) {
            queuedBanners.append(notice)
        }
    }

    private func conflictCopyCreated(_ noteId: String) {
        if case .conflictCopiesCreated(let ids) = banner {
            banner = .conflictCopiesCreated(noteIds: ids + [noteId])
        } else if let index = queuedBanners.firstIndex(where: {
            if case .conflictCopiesCreated = $0 { true } else { false }
        }), case .conflictCopiesCreated(let ids) = queuedBanners[index] {
            queuedBanners[index] = .conflictCopiesCreated(noteIds: ids + [noteId])
        } else {
            post(.conflictCopiesCreated(noteIds: [noteId]))
        }
    }

    // MARK: - Selection

    /// A selection made in the note list. One note is shown in the editor; a multi-selection
    /// keeps the shown note when it is part of it, otherwise shows its first note in list order.
    func selectNotes(_ ids: Set<String>) {
        selectedNoteIDs = ids
        if ids.count == 1 {
            focusedNoteID = ids.first
        } else if let focused = focusedNoteID, ids.contains(focused) {
            return
        } else {
            focusedNoteID = items.first { ids.contains($0.id) }?.id
        }
    }

    /// A sidebar selection. The shown note stays when the new scope lists it; otherwise the
    /// scope's first note is selected (none when the scope is empty). While searching, that waits
    /// for the search's results in the new scope.
    func selectScope(_ newScope: SidebarScope) {
        scope = newScope
        if !search.isActive { keepFocusOrSelectFirst() }
    }

    private func keepFocusOrSelectFirst() {
        let listed = items.map(\.id)
        if let focused = focusedNoteID, listed.contains(focused) {
            selectedNoteIDs = selectedNoteIDs.filter(listed.contains).union([focused])
        } else {
            focusedNoteID = listed.first
            selectedNoteIDs = listed.first.map { [$0] } ?? []
        }
    }

    // MARK: - History

    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }

    /// ⌘[: the previous note this window showed that still exists.
    func goBack() {
        if let id = history.goBack(where: noteExists) { reveal(noteId: id) }
    }

    /// ⌘]: the next note in this window's history that still exists.
    func goForward() {
        if let id = history.goForward(where: noteExists) { reveal(noteId: id) }
    }

    private func noteExists(_ id: String) -> Bool {
        ((try? store.note(id: id)) ?? nil) != nil
    }

    /// Selects and shows `noteId`; when the selected scope doesn't list it, switches to the
    /// section holding it (Notes, Archive or Trash), leaving a workspace it is not part of.
    func reveal(noteId: String) {
        leaveWorkspaceUnlessItHolds(noteId)
        if !items.contains(where: { $0.id == noteId }) {
            guard let note = (try? store.note(id: noteId)) ?? nil else { return }
            switch note.location {
            case .notes: scope = .notes
            case .archive: scope = .archive
            case .trash: scope = .trash
            }
            refresh()
        }
        selectedNoteIDs = [noteId]
        focusedNoteID = noteId
    }

    /// The caret `newNote()` chose for `noteId`, handed out once.
    func takeNewNoteCaret(for noteId: String) -> Int? {
        guard let caret = newNoteCaret, caret.noteId == noteId else { return nil }
        newNoteCaret = nil
        return caret.utf16Offset
    }

    /// What the note commands may do with the current scope and selection.
    var commandState: NoteCommandState {
        NoteCommandState(
            scope: scope, items: items, selectedNoteIDs: selectedNoteIDs, counts: counts,
            privacy: environment.privacyState, typeFallback: unlistedFocusedItem)
    }

    // MARK: - Tags

    /// Notes dropped on a sidebar tag get it (where the `tagPosition` setting says). Open
    /// sessions are flushed first so the rewrite starts from their acknowledged text.
    func addTag(_ path: String, toNoteIDs ids: [String]) {
        guard !ids.isEmpty else { return }
        environment.flushAll()
        do {
            try store.addTag(path, to: ids, position: Settings(db: environment.database).tagPosition)
        } catch {
            appLogger.error("adding a tag to \(ids.count) notes failed: \(error)")
        }
        refresh()
    }

    /// Removes the selected tag from the selected notes (they leave the list).
    func removeScopeTagFromSelected() {
        guard case .tag(let path) = scope else { return }
        environment.flushAll()
        perform("remove tag") { try store.removeTag(path, from: $0) }
    }

    // MARK: - Tag management

    /// Renames (or moves, `a` → `b/a`) a tag in every note as one undo step on `undoManager`.
    /// Open sessions are flushed first and adopt the rewrite right away (before an editor could
    /// send an edit on the old revision). A selected tag and the workspace follow the rename and
    /// its undo, in every main window. False when the store refused.
    @discardableResult
    func renameTag(_ path: String, to newPath: String, undoManager: UndoManager?) -> Bool {
        environment.flushAll()
        let result: TagRewriteResult
        do {
            result = try store.renameTag(path, to: newPath)
        } catch {
            appLogger.error("renaming a tag failed: \(error)")
            post(.tagOperationFailed(message: Self.failureMessage(error, renaming: path)))
            return false
        }
        environment.databaseDidChange()
        environment.tagRenamed(from: path, to: newPath)
        finishTagRewrite(
            result, actionName: "Rename Tag", undoManager: undoManager,
            afterUndo: { $0.environment.tagRenamed(from: newPath, to: path) },
            redo: { $0.renameTag(path, to: newPath, undoManager: $1) }
        )
        return true
    }

    // MARK: - Note type

    /// Sets (or with nil removes) the type of the selected notes (none listed: `unlistedFocusedItem`) as
    /// one undo step on `undoManager`.
    /// The one note the editor shows is edited there (its own undo); the others go through the store.
    func setType(_ type: NoteType?, undoManager: UndoManager?) {
        var ids = items.map(\.id).filter(selectedNoteIDs.contains)
        if ids.isEmpty, let unlisted = unlistedFocusedItem { ids = [unlisted.id] }
        guard !ids.isEmpty else { return }
        if ids.count == 1, setTypeInEditor(ids[0], type) { return }
        setType(type, noteIds: ids, undoManager: undoManager)
    }

    /// The store path for exactly `ids` (Sort Inbox types the note it shows, whatever is selected).
    /// The result says what changed and what was refused (`skippedNotApplied`); nil when the store failed.
    @discardableResult
    func setType(_ type: NoteType?, noteIds ids: [String], undoManager: UndoManager?) -> TagRewriteResult? {
        environment.flushAll()
        let result: TagRewriteResult
        do {
            result = try store.setType(type, noteIds: ids)
        } catch {
            appLogger.error("setting the type of \(ids.count) notes failed: \(error)")
            banner = .commandFailed(action: "set type")
            return nil
        }
        environment.databaseDidChange()
        if !result.skippedNotApplied.isEmpty { postTypeNotApplied() }
        finishTagRewrite(
            result, actionName: "Set Type", undoManager: undoManager, afterUndo: { _ in },
            redo: { $0.setType(type, noteIds: ids, undoManager: $1) }
        )
        return result
    }

    private func postTypeNotApplied() {
        post(.tagOperationFailed(message: "The type was not set: the end of the note is inside a code block"))
    }

    /// True when `noteId` is the editable, unlocked note the editor shows: the change is sent as one
    /// `replaceRange`. Known gap: a stale span (the editor typed on since) is refused by the editor
    /// and does nothing; the bridge does not report whether a command was handled.
    private func setTypeInEditor(_ noteId: String, _ type: NoteType?) -> Bool {
        guard let editor, editor.status.isEditable, let session = editor.session, session.noteId == noteId,
              (items.first(where: { $0.id == noteId }) ?? unlistedFocusedItem)?.isLocked == false else { return false }
        let old = TextNormalization.normalizeLineEndings(session.text)
        guard let written = NoteTypeText.settingIfEffective(type, in: session.text) else {
            postTypeNotApplied()
            return true
        }
        let new = TextNormalization.normalizeLineEndings(written)
        if let change = NoteTypeText.smallestChange(from: old, to: new) {
            editor.apply(.replaceRange, args: [
                "from": .int(change.from), "to": .int(change.to),
                "expect": .string(change.expect), "text": .string(change.text),
                // The caret and the scroll position stay where the user is typing.
                "keepSelection": .bool(true),
            ])
        }
        return true
    }

    /// Removes the tag (and its descendants) from every note; the notes stay. One undo step; its
    /// undo also brings back the workspace and the selected tag the delete left.
    func deleteTag(_ path: String, undoManager: UndoManager?) {
        environment.flushAll()
        let result: TagRewriteResult
        do {
            result = try store.deleteTag(path)
        } catch {
            appLogger.error("deleting a tag failed: \(error)")
            post(.tagOperationFailed(message: "Could not delete the tag “\(path)”"))
            return
        }
        environment.databaseDidChange()
        var leftWorkspace: Workspace?, leftScope: SidebarScope?
        if let workspace, NoteStore.renamedTagPath(workspace.path, from: path, to: path) != nil {
            leftWorkspace = workspace
            dismissWorkspace()
        }
        if case .tag(let selected) = scope, NoteStore.renamedTagPath(selected, from: path, to: path) != nil {
            leftScope = scope
            refresh()
            selectScope(.notes)
        }
        finishTagRewrite(
            result, actionName: "Delete Tag", undoManager: undoManager,
            afterUndo: { [leftWorkspace, leftScope] in $0.returnAfterUndoneDelete(workspace: leftWorkspace, scope: leftScope) },
            redo: { $0.deleteTag(path, undoManager: $1) }
        )
    }

    /// Undo of Delete Tag: back to the workspace and the selected tag the delete left, unless the
    /// window went elsewhere since.
    private func returnAfterUndoneDelete(workspace leftWorkspace: Workspace?, scope leftScope: SidebarScope?) {
        let newWorkspace = workspace ?? leftWorkspace
        let newScope = scope == .notes ? leftScope ?? scope : scope
        guard newWorkspace != workspace || newScope != scope else { return }
        setLocation(scope: newScope, workspace: newWorkspace)
        refresh()
        if !search.isActive { keepFocusOrSelectFirst() }
    }

    /// Drag a tag onto another: `child` becomes `parent/<child's last component>`.
    @discardableResult
    func nestTag(_ child: String, into parent: String, undoManager: UndoManager?) -> Bool {
        guard let newPath = Self.nestedPath(child, into: parent) else { return false }
        return renameTag(child, to: newPath, undoManager: undoManager)
    }

    /// The path a tag dropped on `parent` gets; nil onto itself, its own descendant, or the
    /// parent it already sits in.
    static func nestedPath(_ child: String, into parent: String) -> String? {
        guard let name = child.split(separator: "/").last.map(String.init) else { return nil }
        let newPath = parent + "/" + name
        guard !NoteStore.isRenameIntoOwnSubtree(child, to: newPath),
              CanonicalKey.make(newPath) != CanonicalKey.make(child) else { return nil }
        return newPath
    }

    private static func failureMessage(_ error: Error, renaming path: String) -> String {
        switch error {
        case StoreError.tagIntoOwnSubtree: "“\(path)” can’t be moved into its own subtag"
        case StoreError.invalidTag(let name): "“\(name)” can’t be used as a tag name"
        case StoreError.reservedTagName(let name): "“\(name)” is reserved for note types"
        default: "Could not rename the tag “\(path)”"
        }
    }

    /// Bear pins root tags only.
    static func canPin(_ tag: TagNode) -> Bool {
        !tag.path.contains("/")
    }

    func setTagPinned(_ path: String, pinned: Bool) {
        do {
            try store.setTagPinned(path, pinned: pinned)
        } catch {
            appLogger.error("pinning a tag failed: \(error)")
        }
        refresh()
    }

    /// `nil` resets the tag to its default TagCon.
    func setTagIcon(_ path: String, symbol: String?) {
        do {
            try store.setTagIcon(path, symbol: symbol)
        } catch {
            appLogger.error("setting a tag icon failed: \(error)")
        }
        refresh()
    }

    /// Notes a rename or delete of the tag would touch (for the confirmations).
    func noteCount(forTag path: String) -> Int {
        (try? store.noteCount(forTag: path)) ?? 0
    }

    /// A selected tag and the workspace follow a rename made in any main window, or its undo
    /// (`AppEnvironment.tagRenamed`; the store moved the recent workspaces with it).
    private func followRename(from old: String, to new: String) {
        var newScope = scope, newWorkspace = workspace
        if case .tag(let selected) = scope, let moved = NoteStore.renamedTagPath(selected, from: old, to: new) {
            newScope = .tag(moved)
        }
        if let workspace, let moved = NoteStore.renamedTagPath(workspace.path, from: old, to: new) {
            newWorkspace = Workspace(path: moved)
        }
        guard newScope != scope || newWorkspace?.path != workspace?.path else { return }
        setLocation(scope: newScope, workspace: newWorkspace)
        refresh()
    }

    // MARK: - Workspaces

    /// Tag context menu "Set as Workspace", or the switcher: the window shows only the notes of
    /// `path` (Bear: the Notes row becomes the workspace), starting at Notes. Switches directly
    /// from another workspace; becomes the most recent one.
    /// Refused (false, with a message) for the tags that mark note types.
    @discardableResult
    func enterWorkspace(_ path: String) -> Bool {
        guard !NoteType.isReservedWorkspace(path: path) else {
            post(.tagOperationFailed(message: Self.failureMessage(StoreError.reservedTagName(path), renaming: path)))
            return false
        }
        let entered = Workspace(path: path)
        recordUse(entered)
        setLocation(scope: .notes, workspace: entered)
        if !search.isActive { keepFocusOrSelectFirst() }
        return true
    }

    /// The switcher's "Notes", View ▸ Dismiss Workspace (⇧⌘0): back to the whole library; the
    /// selected section stays.
    func dismissWorkspace() {
        guard workspace != nil else { return }
        setLocation(scope: scope, workspace: nil)
        if !search.isActive { keepFocusOrSelectFirst() }
    }

    /// The workspace's tag tree node (spelling and TagCon as the sidebar shows them), if listed.
    var workspaceNode: TagNode? {
        guard let workspace else { return nil }
        func find(_ nodes: [TagNode]) -> TagNode? {
            for node in nodes {
                if node.id == workspace.key { return node }
                if let found = find(node.children) { return found }
            }
            return nil
        }
        return find(tagTree)
    }

    /// The Notes row's name in a workspace: the tag as the tag tree spells it (it follows a
    /// rename, also one made elsewhere), else as chosen; nil outside a workspace.
    var workspaceTitle: String? {
        workspaceNode?.path ?? workspace?.path
    }

    /// A restored window's workspace: no recent-use entry (nothing was chosen).
    func restoreWorkspace(_ path: String, scope restoredScope: SidebarScope) {
        setLocation(scope: restoredScope, workspace: Workspace(path: path))
    }

    private func recordUse(_ workspace: Workspace) {
        do {
            try store.recordWorkspaceUse(workspace, now: now())
        } catch {
            appLogger.error("recording a recent workspace failed: \(error)")
        }
    }

    /// Before showing a note the workspace does not hold (a link, history, a backlink): leave it.
    private func leaveWorkspaceUnlessItHolds(_ noteId: String) {
        guard let workspace, noteExists(noteId) else { return }
        let holds = (try? environment.database.pool.read { try workspace.contains(noteId: noteId, db: $0) }) ?? true
        if !holds { setLocation(scope: scope, workspace: nil) }
    }

    /// Reports skipped locked/read-only notes and registers the undo record (the previous texts)
    /// when something changed; undoing registers `redo`, which re-runs the action and so
    /// registers its own undo again. The undo manager is held weakly (it owns the handler).
    private func finishTagRewrite(
        _ result: TagRewriteResult, actionName: String, undoManager: UndoManager?,
        afterUndo: @escaping @MainActor (LibraryModel) -> Void,
        redo: @escaping @MainActor (LibraryModel, UndoManager?) -> Void
    ) {
        if !result.skippedLocked.isEmpty || !result.skippedReadOnly.isEmpty {
            post(.notesSkipped(locked: result.skippedLocked.count, readOnly: result.skippedReadOnly.count))
        }
        refresh()
        guard let undoManager, result.didChange else { return }
        undoManager.registerUndo(withTarget: self) { [weak undoManager] model in
            MainActor.assumeIsolated {
                model.environment.flushAll()
                do {
                    let restored = try model.store.undoTagRewrite(result)
                    model.environment.databaseDidChange()
                    if restored.count < result.changedNoteIds.count {
                        appLogger.notice("undo \(actionName, privacy: .public): \(result.changedNoteIds.count - restored.count) notes edited since were kept")
                    }
                } catch {
                    appLogger.error("undo \(actionName, privacy: .public) failed: \(error)")
                }
                model.refresh()
                afterUndo(model)
                guard let undoManager else { return }
                undoManager.registerUndo(withTarget: model) { [weak undoManager] model in
                    MainActor.assumeIsolated { redo(model, undoManager) }
                }
                undoManager.setActionName(actionName)
            }
        }
        undoManager.setActionName(actionName)
    }

    // MARK: - Wiki-link rewrite (debounced by `TitleChangeMonitor`)

    private struct LinkRewriteRecord {
        var result: LinkRewriteResult
        var undoTarget: LinkRewriteUndoTarget
    }

    /// Identifies one rewrite's steps on the undo manager (so the banner's Undo can drop them).
    private final class LinkRewriteUndoTarget {}

    /// Selects `noteId` in the list (Info panel backlinks); the scope follows (Notes or Archive)
    /// when it is not listed.
    func reveal(_ noteId: String) {
        guard let note = try? environment.store.note(id: noteId), note.location != .trash else { return }
        leaveWorkspaceUnlessItHolds(noteId)
        refresh()
        if !items.contains(where: { $0.id == noteId }) {
            selectScope(note.location == .archive ? .archive : .notes)
        }
        selectNotes([noteId])
    }

    func shows(noteId: String) -> Bool {
        focusedNoteID == noteId
    }

    /// `LinkUpdater` rewrote the links (sessions adopted it): the banner "Updated links in N
    /// notes — Undo" (N = the other notes), the undo step on this window's undo manager, then the
    /// skipped notes.
    func present(_ result: LinkRewriteResult, renamedNoteId noteId: String) {
        refresh()
        if result.didChange {
            let changed = Set(result.changedNoteIds)
            // An older banner whose notes this rewrite changed again could no longer undo them.
            for (id, record) in linkRewrites where !changed.isDisjoint(with: record.result.changedNoteIds) {
                removeLinkBanner(id)
            }
            let undoTarget = LinkRewriteUndoTarget()
            let others = result.changedNoteIds.filter { $0 != noteId }.count
            var rewriteId: UUID?
            if others > 0 {
                let id = UUID()
                rewriteId = id
                linkRewrites[id] = LinkRewriteRecord(result: result, undoTarget: undoTarget)
                post(.linksUpdated(noteCount: others, rewriteId: id))
            }
            if let undoManager {
                registerLinkUndo(result, rewriteId: rewriteId, target: undoTarget, actionName: "Update Links", on: undoManager)
            }
        }
        if !result.skippedLocked.isEmpty || !result.skippedReadOnly.isEmpty || !result.skippedUnsaved.isEmpty {
            post(.notesSkipped(
                locked: result.skippedLocked.count, readOnly: result.skippedReadOnly.count,
                unsaved: result.skippedUnsaved.count
            ))
        }
    }

    /// Runs link updates still waiting for their debounce now, after flushing (every window's:
    /// there is one updater).
    func runPendingLinkRewrites() {
        environment.linkUpdater?.runPendingNow()
    }

    /// The Info panel's "Link" (spec §4.6): rewrites one unlinked mention into `[[Title]]` like a
    /// link rewrite — open sessions flushed first and adopting the change right away, one undo
    /// step ("Link Mention"), the banner with Undo. False (with a banner) when the store refused:
    /// the note changed since the mention was listed, or it is not editable (R10).
    @discardableResult
    func linkMention(_ mention: Mention, to targetId: String) -> Bool {
        let result: LinkRewriteResult
        do {
            result = try LinkRewriteUndo.linkMention(mention, to: targetId, in: environment)
        } catch {
            appLogger.error("linking a mention in note \(mention.noteId, privacy: .public) failed: \(error)")
            post((error as? MentionLinkError).map(LibraryBanner.mentionNotLinked) ?? .commandFailed(action: "link mention"))
            return false
        }
        refresh()
        recordLinkRewrite(result, actionName: "Link Mention")
        return true
    }

    /// The banner (with Undo) and the undo manager's step for a rewrite that changed notes.
    private func recordLinkRewrite(_ result: LinkRewriteResult, actionName: String) {
        let changed = Set(result.changedNoteIds)
        // An older banner whose notes this rewrite changed again could no longer undo them.
        for (id, record) in linkRewrites where !changed.isDisjoint(with: record.result.changedNoteIds) {
            removeLinkBanner(id)
        }
        let rewriteId = UUID()
        let undoTarget = LinkRewriteUndoTarget()
        linkRewrites[rewriteId] = LinkRewriteRecord(result: result, undoTarget: undoTarget)
        post(.linksUpdated(noteCount: result.changedNoteIds.count, rewriteId: rewriteId))
        if let undoManager {
            registerLinkUndo(result, rewriteId: rewriteId, target: undoTarget, actionName: actionName, on: undoManager)
        }
    }

    /// The banner's Undo: restores the links and removes the undo manager's step for them.
    func undoLinkRewrite(_ rewriteId: UUID) {
        guard let record = linkRewrites[rewriteId] else { return }
        removeLinkBanner(rewriteId)
        undoManager?.removeAllActions(withTarget: record.undoTarget)
        restoreLinks(record.result, redo: false)
    }

    private func restoreLinks(_ result: LinkRewriteResult, redo: Bool) {
        LinkRewriteUndo.restore(result, redo: redo, in: environment)
        refresh()
    }

    /// One "Update Links" (or "Link Mention") step (`LinkRewriteUndo.register`); the first undo
    /// takes the banner down.
    private func registerLinkUndo(
        _ result: LinkRewriteResult, rewriteId: UUID?, target: LinkRewriteUndoTarget, actionName: String,
        on undoManager: UndoManager
    ) {
        LinkRewriteUndo.register(
            result, actionName: actionName, target: target, on: undoManager, in: environment,
            didUndo: rewriteId.map { id -> @MainActor () -> Void in { [weak self] in self?.removeLinkBanner(id) } },
            didRestore: { [weak self] in self?.refresh() }
        )
    }

    /// Takes the rewrite's banner down (shown or queued); its Undo would no longer do anything.
    private func removeLinkBanner(_ rewriteId: UUID) {
        if case .linksUpdated(_, rewriteId)? = banner {
            dismissBanner()
        } else {
            queuedBanners.removeAll { if case .linksUpdated(_, rewriteId) = $0 { true } else { false } }
        }
        linkRewrites[rewriteId] = nil
    }

    // MARK: - Private

    /// Runs `body` on the selected notes that are listed (in list order), then refreshes and,
    /// if the focused note left the list, focuses its next neighbour (or the previous one).
    private func perform(_ name: String, _ body: ([String]) throws -> Void) {
        refresh()
        let previousOrder = items.map(\.id)
        let ids = previousOrder.filter(selectedNoteIDs.contains)
        guard !ids.isEmpty else { return }
        do {
            try body(ids)
        } catch {
            appLogger.error("\(name, privacy: .public) of \(ids.count) notes failed: \(error)")
            banner = .commandFailed(action: name)
        }
        refresh()
        repairFocus(previousOrder: previousOrder)
    }

    private func repairFocus(previousOrder: [String]) {
        let listed = Set(items.map(\.id))
        selectedNoteIDs = selectedNoteIDs.filter(listed.contains)
        guard let focused = focusedNoteID, !listed.contains(focused) else { return }
        var next: String?
        if let index = previousOrder.firstIndex(of: focused) {
            next = previousOrder[(index + 1)...].first(where: listed.contains)
                ?? previousOrder[..<index].last(where: listed.contains)
        }
        focusedNoteID = next
        selectedNoteIDs = next.map { [$0] } ?? []
    }
}
