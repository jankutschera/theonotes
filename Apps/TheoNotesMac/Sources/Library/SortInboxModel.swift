// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import GRDB
import Observation

/// What the Sort Inbox buttons do to the note shown.
enum SortInboxAction: Equatable {
    case type(NoteType), archive, trash, skip
}

/// How the notes handled so far were sorted; read-only notes count as skipped.
struct SortInboxSummary: Equatable {
    var typed = 0, archived = 0, trashed = 0, skipped = 0

    var total: Int { typed + archived + trashed + skipped }
}

/// View ▸ Sort Inbox (spec §8): the Inbox's notes one at a time, oldest first. The queue is a
/// snapshot taken when the sheet opens; a note is re-read before it is acted on. Every action is one
/// undo step on the manager it is given, which also puts the note back as `current`.
@MainActor
@Observable
final class SortInboxModel {
    /// The notes still to sort, in order; the first is `current`.
    private(set) var queue: [NoteListItem] {
        didSet { if queue.first?.id != oldValue.first?.id { preview = loadPreview() } }
    }
    private(set) var summary = SortInboxSummary()
    /// The first lines of `current` below its title.
    private(set) var preview = ""
    private var totalCount: Int

    @ObservationIgnored private let model: LibraryModel

    private enum Outcome { case typed, archived, trashed, skipped }

    init(model: LibraryModel) {
        self.model = model
        let inbox = (try? model.environment.database.pool.read {
            try LibraryQueries.notes(
                in: .inbox, sort: .createdAscending, workspace: model.workspace, now: .now, calendar: .current, db: $0)
        }) ?? []
        // Pinned notes come first in the query; the queue is strictly oldest first.
        let sorted = inbox.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        totalCount = sorted.count
        queue = sorted.filter { !$0.isReadOnly }
        summary.skipped = totalCount - queue.count
        preview = loadPreview()
    }

    var current: NoteListItem? { queue.first }
    var remaining: Int { queue.count }
    var progress: (done: Int, total: Int) { (summary.total, totalCount) }

    /// Applies `action` to `current` as one undo step on `undoManager`. A note that left the Inbox
    /// since the sheet opened is dropped instead, so no action lands on a note the user did not see.
    func apply(_ action: SortInboxAction, undoManager: UndoManager?) {
        guard let note = current else { return }
        guard isStillInInbox(note.id) else {
            queue.removeFirst()
            totalCount -= 1
            return
        }
        let outcome: Outcome
        let done: Bool
        switch action {
        case .type(let type):
            let result = model.setType(type, noteIds: [note.id], undoManager: undoManager)
            // A note the tag cannot be written into (an unclosed code block) is skipped, not retried.
            let refused = result?.skippedNotApplied.isEmpty == false
            outcome = refused ? .skipped : .typed
            done = refused || result?.didChange == true
        case .archive:
            outcome = .archived
            done = model.archiveWithUndo([note.id], undoManager: undoManager)
        case .trash:
            outcome = .trashed
            done = model.trashWithUndo([note.id], undoManager: undoManager)
        case .skip:
            outcome = .skipped
            done = true
        }
        guard done else { return }
        record([note], outcome, actionName: outcome == .skipped ? "Skip" : nil, undoManager: undoManager)
    }

    /// Archives every note still in the queue that is in the Inbox (and the active workspace) now,
    /// as one undo step. Returns how many moved.
    @discardableResult
    func archiveRest(undoManager: UndoManager?) -> Int {
        let inInbox = inboxIDs()
        let moving = queue.filter { inInbox.contains($0.id) }
        let left = queue.count - moving.count
        if left > 0 {
            queue.removeAll { !inInbox.contains($0.id) }
            totalCount -= left
        }
        guard !moving.isEmpty, model.archiveWithUndo(moving.map(\.id), undoManager: undoManager) else { return 0 }
        record(moving, .archived, actionName: nil, undoManager: undoManager)
        return moving.count
    }

    // MARK: - Steps

    /// Moves `items` (the front of the queue) from the queue into the summary, and registers the
    /// step that puts them back; its redo does it again.
    private func record(_ items: [NoteListItem], _ outcome: Outcome, actionName: String?, undoManager: UndoManager?) {
        let ids = Set(items.map(\.id))
        queue.removeAll { ids.contains($0.id) }
        add(outcome, items.count)
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { [weak undoManager] sort in
            MainActor.assumeIsolated {
                sort.queue = items + sort.queue
                sort.add(outcome, -items.count)
                guard let undoManager else { return }
                undoManager.registerUndo(withTarget: sort) { [weak undoManager] sort in
                    MainActor.assumeIsolated {
                        sort.record(items, outcome, actionName: actionName, undoManager: undoManager)
                    }
                }
                if let actionName { undoManager.setActionName(actionName) }
            }
        }
        if let actionName { undoManager.setActionName(actionName) }
    }

    private func add(_ outcome: Outcome, _ count: Int) {
        switch outcome {
        case .typed: summary.typed += count
        case .archived: summary.archived += count
        case .trashed: summary.trashed += count
        case .skipped: summary.skipped += count
        }
    }

    // MARK: - Reading

    /// Still in Notes, untyped, unlocked and editable (templates and the workspace are not
    /// re-checked: neither changes by sorting).
    private func isStillInInbox(_ id: String) -> Bool {
        let found = try? model.environment.database.pool.read {
            try Bool.fetchOne($0, sql: """
                SELECT EXISTS (SELECT 1 FROM note WHERE id = ? AND location = 'notes' AND noteType IS NULL
                    AND NOT isLocked AND NOT isReadOnly)
                """, arguments: [id])
        }
        return found == true
    }

    private func inboxIDs() -> Set<String> {
        let inbox = try? model.environment.database.pool.read {
            try LibraryQueries.notes(
                in: .inbox, sort: .createdAscending, workspace: model.workspace, now: .now, calendar: .current, db: $0)
        }
        return Set((inbox ?? []).filter { !$0.isReadOnly }.map(\.id))
    }

    private func loadPreview() -> String {
        guard let id = queue.first?.id, let text = (try? model.environment.store.note(id: id))?.text else { return "" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(6)
        return String(lines.joined(separator: "\n").prefix(600))
    }
}
