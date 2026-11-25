// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation

/// Shows a link update's banner and registers its undo step: a main window's `LibraryModel`.
@MainActor
protocol LinkUpdatePresenter: AnyObject {
    /// Whether this window shows `noteId` now.
    func shows(noteId: String) -> Bool
    /// The rewrite is in the store and open sessions adopted it; report it and make it undoable.
    func present(_ result: LinkRewriteResult, renamedNoteId: String)
}

/// The app's one wiki-link updater (spec §3.5), owned by `AppEnvironment`: its
/// `TitleChangeMonitor` watches every note any window (main or note window) has open and follows
/// title edits made in any of their editors (R15).
///
/// Where the banner and the undo step go: note windows have neither a banner bar nor an undo path
/// outside their editor, so a main window presents every update — the one showing the renamed
/// note (the edit was made there, or it shows the note too), else the frontmost main window
/// (`preferredPresenter`, installed by `AppModel`), else the main window registered last. With no
/// main window open the links are still updated, without banner or undo step.
@MainActor
final class LinkUpdater {
    private weak var environment: AppEnvironment?
    private var monitor: TitleChangeMonitor?
    private var presenters: [WeakPresenter] = []
    /// The frontmost main window's presenter.
    var preferredPresenter: (() -> (any LinkUpdatePresenter)?)?

    init(environment: AppEnvironment, scheduler: any DebounceScheduler) {
        self.environment = environment
        monitor = TitleChangeMonitor(
            scheduler: scheduler,
            read: { [weak environment] id in
                do {
                    return try environment?.store.linkTargetState(id: id)
                } catch {
                    appLogger.error("reading the title of note \(id, privacy: .public) failed: \(error)")
                    return nil
                }
            },
            flush: { [weak environment] in environment?.flushAll() },
            rewrite: { [weak self] in self?.rewrite(to: $0, from: $1, busy: $2) ?? true }
        )
    }

    func addPresenter(_ presenter: any LinkUpdatePresenter) {
        presenters.removeAll { $0.presenter == nil || $0.presenter === presenter }
        presenters.append(WeakPresenter(presenter: presenter))
    }

    func removePresenter(_ presenter: any LinkUpdatePresenter) {
        presenters.removeAll { $0.presenter == nil || $0.presenter === presenter }
    }

    /// Every note open in any window (`AppEnvironment.setOpenNoteIds`).
    func watch(_ ids: Set<String>) {
        monitor?.watch(ids)
    }

    func sessionActivity(_ noteId: String, _ activity: NoteSession.Activity) {
        monitor?.sessionActivity(noteId, activity)
    }

    /// Window close and quit: flushes, then runs every pending update now.
    func runPendingNow() {
        monitor?.runPendingNow()
    }

    /// The monitor flushed every open session. The store rewrites the links in one transaction —
    /// unless it would change a note whose editor is still typing (`busy`): then nothing is
    /// written and this returns false, to be tried again once that editor is idle. Open sessions
    /// adopt the rewrite right away, before an editor can send more edits on the old revision, so
    /// the renamed note's own `[[/heading]]` links reach its editor as an external change. A
    /// session that still has unsaved text (its flush failed) is left out and reported.
    private func rewrite(to noteId: String, from previous: LinkTargetState, busy: Set<String>) -> Bool {
        guard let environment else { return true }
        let result: LinkRewriteResult
        do {
            result = try environment.store.rewriteWikiLinks(
                to: noteId, from: previous, skipping: environment.unsavedNoteIds, deferringIfTouching: busy
            )
        } catch {
            appLogger.error("updating links to note \(noteId, privacy: .public) failed: \(error)")
            return true
        }
        guard !result.deferred else { return false }
        environment.databaseDidChange()
        presenter(for: noteId)?.present(result, renamedNoteId: noteId)
        return true
    }

    private func presenter(for noteId: String) -> (any LinkUpdatePresenter)? {
        let open = presenters.compactMap(\.presenter)
        return open.first { $0.shows(noteId: noteId) } ?? preferredPresenter?() ?? open.last
    }
}

@MainActor
private struct WeakPresenter {
    weak var presenter: (any LinkUpdatePresenter)?
}
