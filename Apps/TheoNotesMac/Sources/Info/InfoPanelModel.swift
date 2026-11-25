// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import Observation
import SwiftUI

/// One window's Info panel (spec §4.6, inventory §2.8): Statistics, Table of Contents and
/// Backlinks of the note its editor shows — a main window's or a note window's (the menu
/// commands route to the key window's panel, like the Format menu). Shown as a popover from the ⓘ toolbar button, or
/// detached into a floating utility panel. Content is recomputed for the visible tab only, on
/// `refresh()`: when a tab opens, the shown note or the editor selection changes, and after
/// writes to the notes while a view shows the panel (this process: GRDB observation; other
/// processes: `ChangeNotifier`, which also echoes this process's writes — both go through one
/// debounce, so a write computes once). Backlinks are read in the background
/// (`NoteStore.backlinksInBackground`), debounced after writes, and a newer request cancels an
/// older one.
@MainActor
@Observable
final class InfoPanelModel {
    enum Tab: String, CaseIterable, Identifiable {
        case statistics, contents, backlinks

        var id: Self { self }

        /// The tab's name in the panel's picker.
        var label: String {
            switch self {
            case .statistics: "Statistics"
            case .contents: "Contents"
            case .backlinks: "Backlinks"
            }
        }

        /// The View menu item (Bear's shortcuts ⇧⌘I / ⇧⌘A / ⇧⌘B).
        var menuTitle: String {
            switch self {
            case .statistics: "Statistics"
            case .contents: "Table of Contents"
            case .backlinks: "Backlinks"
            }
        }

        var shortcutKey: KeyEquivalent {
            switch self {
            case .statistics: "i"
            case .contents: "a"
            case .backlinks: "b"
            }
        }
    }

    /// The popover is open.
    var isPresented = false {
        didSet { if isPresented && !oldValue { refresh() } }
    }
    var tab: Tab = .statistics {
        didSet { if tab != oldValue { refresh() } }
    }
    /// Shown in its own floating panel instead of the popover.
    private(set) var isDetached = false

    /// The note the content belongs to (the editor's), nil when none is shown.
    private(set) var noteId: String?
    private(set) var statistics = NoteStatistics.zero
    /// `statistics` counts the editor's selection, not the whole note.
    private(set) var isSelection = false
    private(set) var lastEdit: Date?
    private(set) var headings: [HeadingRef] = []
    private(set) var backlinks = Backlinks()

    @ObservationIgnored let environment: AppEnvironment
    @ObservationIgnored let editor: EditorBridgeController
    /// The note the window shows (read through observable state, so views follow it).
    @ObservationIgnored private let shownNoteId: @MainActor () -> String?
    /// Shows a mentioning note in the window.
    @ObservationIgnored private let openNote: @MainActor (String) -> Void
    /// Links a mention to the shown note (with undo and banner where the window has them);
    /// false when it was refused.
    @ObservationIgnored private let linkMention: @MainActor (Mention, String) -> Bool
    @ObservationIgnored private var visibleViews = 0
    @ObservationIgnored private var tokens: [ObservationToken] = []
    /// How long writes are coalesced before the panel refreshes (tests shorten it).
    @ObservationIgnored var writeDebounce: Duration
    @ObservationIgnored private var writeRefresh: Task<Void, Never>?
    /// Bumped by every write notification: backlinks loaded for an older one are stale.
    @ObservationIgnored private var dataGeneration = 0
    /// What the last backlinks request was for (note, generation): asking again is a no-op.
    @ObservationIgnored private var backlinksRequest: (noteId: String, generation: Int)?
    @ObservationIgnored private(set) var backlinksTask: Task<Void, Never>?
    /// Backlinks reads started (tests check that one change computes once).
    @ObservationIgnored private(set) var backlinksComputations = 0
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var panelCloseObserver: (any NSObjectProtocol)?

    init(
        environment: AppEnvironment, editor: EditorBridgeController,
        shownNoteId: @escaping @MainActor () -> String?,
        open: @escaping @MainActor (String) -> Void,
        link: @escaping @MainActor (Mention, String) -> Bool,
        writeDebounce: Duration = .milliseconds(400)
    ) {
        self.environment = environment
        self.editor = editor
        self.shownNoteId = shownNoteId
        openNote = open
        linkMention = link
        self.writeDebounce = writeDebounce
    }

    /// A main window's panel: the list's focused note; mentions open in the list; links go
    /// through the library model (undo step + banner).
    convenience init(library: LibraryModel, editor: EditorBridgeController, writeDebounce: Duration = .milliseconds(400)) {
        self.init(
            environment: library.environment, editor: editor,
            shownNoteId: { [weak library] in library?.focusedNoteID },
            open: { [weak library] in library?.reveal($0) },
            link: { [weak library] in library?.linkMention($0, to: $1) ?? false },
            writeDebounce: writeDebounce
        )
    }

    /// The note the window shows now.
    var currentNoteId: String? { shownNoteId() }

    private var store: NoteStore { environment.store }

    // MARK: - Showing

    /// ⇧⌘I / ⇧⌘A / ⇧⌘B ("Toggle statistics panel", …): shows the panel on `tab`, or hides the
    /// popover when it already shows that tab. A detached panel just switches tabs.
    func toggle(_ tab: Tab) {
        if isDetached {
            self.tab = tab
            panel?.orderFront(nil)
            return
        }
        if isPresented && self.tab == tab {
            isPresented = false
            return
        }
        self.tab = tab
        isPresented = true
    }

    /// View ▸ Toggle Info Panel and the ⓘ button: the popover, or the detached panel, opens or closes.
    func togglePanel() {
        if isDetached {
            closeDetachedPanel()
        } else {
            isPresented.toggle()
        }
    }

    /// The popover's "Detach" button: the panel moves into a floating utility window.
    func detach() {
        isPresented = false
        guard panel == nil else { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 420),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered, defer: true
        )
        panel.title = "Info"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(
            rootView: InfoPanelView(info: self, isDetached: true).shellPalette(from: environment.appearance))
        panel.setContentSize(NSSize(width: 320, height: 420))
        if let frame = editor.webView.window?.frame {
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - 340, y: frame.maxY - 60))
        } else {
            panel.center()
        }
        panelCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.detachedPanelClosed() }
        }
        self.panel = panel
        isDetached = true
        panel.orderFront(nil)
        refresh()
    }

    /// Closes the detached panel (its window closing does the rest).
    func closeDetachedPanel() {
        panel?.close()
    }

    private func detachedPanelClosed() {
        if let panelCloseObserver { NotificationCenter.default.removeObserver(panelCloseObserver) }
        panelCloseObserver = nil
        panel = nil
        isDetached = false
    }

    /// The window closed: the detached panel goes with it.
    func close() {
        closeDetachedPanel()
        isPresented = false
    }

    // MARK: - Content

    /// A view showing the panel appeared: while any is visible, writes to the notes refresh it.
    func viewAppeared() {
        visibleViews += 1
        if visibleViews == 1 {
            let changed: @Sendable () -> Void = { [weak self] in
                Task { @MainActor in self?.notesDidChange() }
            }
            tokens = [
                store.observeNoteWrites(onError: { appLogger.error("info panel: note observation failed: \($0)") }, changed),
                environment.notifier.observe(changed),
            ]
        }
        refresh()
    }

    func viewDisappeared() {
        visibleViews = max(0, visibleViews - 1)
        if visibleViews == 0 {
            // Nothing is observed while hidden: what was read so far may be stale on reopening.
            dataGeneration += 1
            tokens.forEach { $0.cancel() }
            tokens = []
            writeRefresh?.cancel()
            writeRefresh = nil
        }
    }

    /// Waits for a pending write refresh and backlinks read (tests).
    func settle() async {
        await writeRefresh?.value
        await backlinksTask?.value
    }

    /// A write to the notes (any source): the content is stale; one refresh follows the burst.
    func notesDidChange() {
        dataGeneration += 1
        writeRefresh?.cancel()
        let delay = writeDebounce
        writeRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.writeRefresh = nil
            self.refresh()
        }
    }

    /// Recomputes the visible tab for the shown note. Statistics and the table of contents come
    /// from the editor's live text (the open session: typing not yet committed is included); the
    /// headings are `NoteParser`'s, the same the indexer writes to `heading` and the editor counts
    /// for `scrollToHeading`.
    func refresh() {
        let id = shownNoteId()
        if id != noteId { dropBacklinks() }
        noteId = id
        guard let id else {
            statistics = .zero
            isSelection = false
            lastEdit = nil
            headings = []
            cancelBacklinks()
            return
        }
        let note: Note?
        do {
            note = try store.note(id: id)
        } catch {
            appLogger.error("info panel: reading note \(id, privacy: .public) failed: \(error)")
            note = nil
        }
        lastEdit = note?.modifiedAt
        let shown = editor.session?.noteId == id ? editor.session : nil
        let text = shown?.text ?? environment.existingSession(for: id)?.text ?? note?.text ?? ""
        switch tab {
        case .statistics:
            // The selection's UTF-16 offsets apply to the session text, which holds every
            // transaction the editor sent before reporting the selection (the bridge keeps their
            // order). A transaction the host had to reject makes the editor reload, and the next
            // commit's write notification recomputes the counts.
            let selected = shown == nil ? nil : editor.status.selection.flatMap { Self.selectedText(in: text, selection: $0) }
            isSelection = selected != nil
            statistics = NoteStatistics.of(selected ?? text)
        case .contents:
            headings = NoteParser.metadata(for: text).headings
        case .backlinks:
            loadBacklinks(for: id)
        }
    }

    /// Reads the backlinks in the background unless that read (same note, no write since) was
    /// already asked for; a newer read cancels an older one.
    private func loadBacklinks(for id: String) {
        if let request = backlinksRequest, request.noteId == id, request.generation == dataGeneration { return }
        backlinksTask?.cancel()
        backlinksRequest = (id, dataGeneration)
        backlinksComputations += 1
        let store = self.store
        backlinksTask = Task { @MainActor [weak self] in
            let result: Backlinks
            do {
                result = try await store.backlinksInBackground(to: id)
            } catch {
                guard !Task.isCancelled else { return }
                appLogger.error("info panel: backlinks of note \(id, privacy: .public) failed: \(error)")
                self?.backlinksRequest = nil  // asking again retries
                return
            }
            guard !Task.isCancelled, let self else { return }
            guard self.noteId == id else {
                // Discarded: the same request must read again when this note comes back.
                if self.backlinksRequest?.noteId == id { self.backlinksRequest = nil }
                return
            }
            self.backlinks = result
        }
    }

    private func cancelBacklinks() {
        dropBacklinks()
    }

    /// Clears the list together with what it was read for, and stops a read in flight; the next
    /// request reads again.
    private func dropBacklinks() {
        backlinksTask?.cancel()
        backlinksTask = nil
        backlinksRequest = nil
        backlinks = Backlinks()
    }

    /// The footer under the unlinked mentions when the search stopped early.
    static func unlinkedFooter(_ backlinks: Backlinks) -> String? {
        guard backlinks.unlinkedTruncated else { return nil }
        let count = backlinks.unlinked.reduce(0) { $0 + $1.mentions.count }
        guard count > 0 else {
            return "No mentions in the first \(Backlinks.candidateScanLimit.formatted()) candidates"
        }
        return "Showing the first \(count.formatted()) \(count == 1 ? "mention" : "mentions")"
    }

    /// The footer under the linked mentions when more notes link here than are listed.
    static func linkedFooter(_ backlinks: Backlinks) -> String? {
        guard backlinks.linkedTruncated else { return nil }
        let count = backlinks.linked.count
        return "Showing the first \(count.formatted()) \(count == 1 ? "note" : "notes")"
    }

    /// The selected text (UTF-16 offsets from the editor, clamped, widened off a split surrogate
    /// pair); nil for an empty selection.
    static func selectedText(in text: String, selection: SelectionRange) -> String? {
        let utf16 = text.utf16
        var lower = min(max(0, min(selection.anchor, selection.head)), utf16.count)
        var upper = min(max(0, max(selection.anchor, selection.head)), utf16.count)
        if !TextOffsets.isValidUTF16Boundary(lower, in: text) { lower -= 1 }
        if !TextOffsets.isValidUTF16Boundary(upper, in: text) { upper += 1 }
        guard lower < upper else { return nil }
        let start = utf16.index(utf16.startIndex, offsetBy: lower)
        let end = utf16.index(start, offsetBy: upper - lower)
        return String(text[start..<end])
    }

    /// "< 1 min", "4 min", "1 hr, 5 min" (localized units).
    static func readTimeText(seconds: Int) -> String {
        if seconds == 0 { return Duration.seconds(0).formatted(.units(allowed: [.minutes], width: .abbreviated)) }
        if seconds < 60 { return "< " + Duration.seconds(60).formatted(.units(allowed: [.minutes], width: .abbreviated)) }
        let minutes = Int((Double(seconds) / 60).rounded())
        return Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    // MARK: - Actions

    /// Table of contents: the editor scrolls the `index`-th heading to the top.
    func scrollToHeading(_ index: Int) {
        editor.scrollToHeading(index)
    }

    /// Shows a mentioning note in this window.
    func open(_ noteId: String) {
        openNote(noteId)
    }

    /// "Link": rewrites the unlinked mention into `[[Title]]` (one undo step, banner with Undo).
    /// The mention leaves the list at once; the write's notification reloads the backlinks.
    func link(_ mention: Mention) {
        guard let noteId, linkMention(mention, noteId) else { return }
        // A read in flight saw the state before the link: drop it; the next refresh reads again.
        backlinksTask?.cancel()
        backlinksTask = nil
        backlinksRequest = nil
        backlinks.unlinked = backlinks.unlinked.compactMap { note in
            var note = note
            note.mentions.removeAll { $0 == mention }
            return note.mentions.isEmpty ? nil : note
        }
    }
}
