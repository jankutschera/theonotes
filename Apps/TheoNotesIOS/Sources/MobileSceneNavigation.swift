// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Observation
import TheoNotesCore

/// One scene's navigation only. The library retains the sole session registry, database,
/// sync and privacy owners; each scene creates its own editor/WKWebView against that registry.
///
/// List isolation requires a scene-owned observation/search adapter as a separate migration:
/// capture queryContextGeneration with each request and reject callbacks after it changes.
@MainActor @Observable final class MobileSceneNavigation {
    let id: UUID
    var scope: SidebarScope {
        didSet { if scope != oldValue { queryContextGeneration &+= 1 } }
    }
    var query: String {
        didSet { queryContextGeneration &+= 1 }
    }
    var workspace: Workspace? {
        didSet { if workspace != oldValue { queryContextGeneration &+= 1 } }
    }
    var selectedID: String? {
        didSet {
            // Deliberately preserve MobileLibrary's explicit-selection echo semantics.
            if !restoringDisplayedSelection { selectionIntentGeneration &+= 1 }
            if let selectedID { history.visit(selectedID) }
        }
    }
    var history: NoteHistory
    var pendingCaret: [String: Int] = [:]
    var pendingCallbackNavigation: MobileCallbackNavigation?
    private(set) var selectionIntentGeneration = 0
    private(set) var queryContextGeneration = 0
    @ObservationIgnored private var restoringDisplayedSelection = false

    init(id: UUID = UUID(), restoration: MobileRestoration = MobileRestoration(),
         historyCapacity: Int = NoteHistory.defaultCapacity) {
        self.id = id
        scope = restoration.scopeValue
        query = ""
        workspace = restoration.workspace.map(Workspace.init(path:))
        selectedID = restoration.noteID
        history = NoteHistory(capacity: historyCapacity)
        // Property observers do not run in init. Seed the restored displayed note so the
        // first subsequent selection can go Back to it using ordinary NoteHistory rules.
        if let selectedID { history.visit(selectedID) }
    }

    var restoration: MobileRestoration {
        MobileRestoration(scope: scope, workspace: workspace?.path, noteID: selectedID)
    }

    /// Roll back a deferred/interrupted presentation without manufacturing another user intent.
    /// The existing history.visit behavior is retained, including its browser branch rules.
    func restoreDisplayedSelection(_ id: String) {
        restoringDisplayedSelection = true
        defer { restoringDisplayedSelection = false }
        selectedID = id
    }

    /// Call only after shared-store lookup/flush succeeds. Workspace membership is resolved
    /// by the caller against the shared database, never guessed from this scene's filtered list.
    func reveal(_ note: Note, containedInWorkspace: Bool = true) throws {
        guard note.deletedAt == nil else { throw StoreError.noteNotFound(id: note.id) }
        if workspace != nil, !containedInWorkspace { workspace = nil }
        query = ""
        scope = note.location == .trash ? .trash : note.location == .archive ? .archive : .notes
        selectedID = note.id
    }

    /// Store flushing and recordWorkspaceUse remain caller-owned side effects. A failure there
    /// must occur before this method, preserving the currently displayed scene context.
    func enterWorkspace(_ next: Workspace?) {
        workspace = next
        scope = .notes
        query = ""
        selectedID = nil
    }

    /// Resolve the destination through the shared store and then reveal it. NoteHistory owns
    /// capacity, skip-unavailable and forward-branch semantics; no second history is invented.
    func historyDestination(back: Bool, where isAvailable: (String) -> Bool = { _ in true }) -> String? {
        back ? history.goBack(where: isAvailable) : history.goForward(where: isAvailable)
    }

    /// Library-switch boundary only: invalidate pending routing/search intents without touching
    /// another scene, the shared session cache, or its acknowledged-but-uncommitted edits.
    func reset(restoration: MobileRestoration = MobileRestoration()) {
        pendingCaret.removeAll()
        pendingCallbackNavigation = nil
        history = NoteHistory(capacity: history.capacity)
        workspace = restoration.workspace.map(Workspace.init(path:))
        scope = restoration.scopeValue
        query = ""
        selectedID = restoration.noteID
    }
}
