// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Observation
import TheoNotesCore

@MainActor final class MobileSortUndoCoordinator {
    private struct Request {
        let model: MobileSortInboxModel
        let stepID: UUID
        let manager: UndoManager
    }
    private var requests: [Request] = []
    private var running = false

    func enqueue(_ model: MobileSortInboxModel, stepID: UUID, manager: UndoManager) {
        requests.append(Request(model: model, stepID: stepID, manager: manager))
        model.pendingUndos += 1
        guard !running else { return }
        running = true
        Task { @MainActor in
            while !requests.isEmpty {
                let request = requests.removeFirst()
                guard request.model.active else { request.model.pendingUndos -= 1; continue }
                do {
                    try await request.model.undo(expected: request.stepID)
                    request.model.pendingUndos -= 1
                } catch {
                    request.model.library.errorMessage = error.localizedDescription
                    let restore = [request] + requests
                    requests.removeAll()
                    for item in restore.reversed() {
                        item.model.pendingUndos -= 1
                        if item.model.active && item.model.hasUndoStep(item.stepID) {
                            let groupsByEvent = item.manager.groupsByEvent
                            item.manager.groupsByEvent = false
                            item.manager.beginUndoGrouping()
                            item.model.registerUndo(item.manager, stepID: item.stepID)
                            item.manager.endUndoGrouping()
                            item.manager.groupsByEvent = groupsByEvent
                        }
                    }
                }
            }
            running = false
        }
    }
}

@MainActor @Observable final class MobileSortInboxModel: Identifiable {
    nonisolated let id = UUID()
    enum Action { case type(NoteType), archive, trash, skip }
    struct Summary { var typed = 0, archived = 0, trashed = 0, skipped = 0 }
    private enum Change {
        case type(TagRewriteResult)
        case location([String: Int], NoteLocation)
        case skip
    }
    private struct Step { let id = UUID(); let items: [NoteListItem]; let change: Change }

    fileprivate let library: MobileLibrary
    private let workspace: Workspace?
    private let navigation: MobileSceneNavigation?
    private var currentWorkspace: Workspace? {
        if let navigation { return navigation.workspace }
        return library.workspace
    }
    private var selectedNoteID: String? {
        get { if let navigation { return navigation.selectedID }; return library.selectedID }
        set { if let navigation { navigation.selectedID = newValue } else { library.selectedID = newValue } }
    }
    private(set) var queue: [NoteListItem]
    private(set) var summary = Summary()
    var notice: String?
    private(set) var total: Int
    private var history: [Step] = []
    fileprivate var active = true
    @ObservationIgnored private weak var undoManager: UndoManager?
    fileprivate var pendingUndos = 0
    var undoing: Bool { pendingUndos > 0 }
    var current: NoteListItem? { queue.first }
    var remaining: Int { queue.count }
    var canUndo: Bool { !history.isEmpty && !undoing }
    var historyCount: Int { history.count }
    var completed: Int { summary.typed + summary.archived + summary.trashed + summary.skipped }
    fileprivate func hasUndoStep(_ id: UUID) -> Bool { history.contains { $0.id == id } }
    private func showNotice(_ message: String) { notice = message; library.recoveryMessage = message }

    init(library: MobileLibrary, navigation: MobileSceneNavigation? = nil) throws {
        guard !library.appLocked, !library.libraryOperationBusy, !library.isClosed, !library.isClosing else {
            throw CancellationError()
        }
        self.library = library
        self.navigation = navigation
        if let navigation { workspace = navigation.workspace } else { workspace = library.workspace }
        let notes = try Self.inbox(library, workspace: workspace)
        total = notes.count
        queue = notes.filter { !$0.isReadOnly }
        summary.skipped = notes.count - queue.count
    }

    private static func inbox(_ library: MobileLibrary, workspace: Workspace?) throws -> [NoteListItem] {
        try library.database.pool.read {
            try LibraryQueries.notes(in: .inbox, sort: .createdAscending, workspace: workspace, now: .now, calendar: .current, db: $0)
        }.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    private func eligible() throws -> Set<String> {
        try ensureAvailable()
        guard currentWorkspace == workspace else { throw Failure.workspaceChanged }
        return Set(try Self.inbox(library, workspace: workspace).filter { !$0.isReadOnly }.map(\.id))
    }

    private func ensureAvailable() throws {
        guard active, !library.appLocked, !library.libraryOperationBusy, !library.isClosed, !library.isClosing else {
            throw CancellationError()
        }
    }

    private func withDrainedEditor<T>(_ action: () throws -> T) async throws -> T {
        try await library.withDrainedEditor(allowUnavailable: false) {
            try library.requireNoOrphanSessionsBeforeEviction()
            return try action()
        }
    }

    func eligibleRemaining() throws -> Int {
        let valid = try eligible()
        return queue.filter { valid.contains($0.id) }.count
    }

    func invalidate() {
        active = false
        undoManager?.removeAllActions(withTarget: self)
        undoManager = nil
        queue.removeAll()
        history.removeAll()
        summary = Summary()
        total = 0
    }

    func discardPendingQueue() { queue.removeAll() }

    func registerUndo(_ manager: UndoManager?) {
        guard let manager, let id = history.last?.id else { return }
        undoManager = manager
        registerUndo(manager, stepID: id)
    }

    fileprivate func registerUndo(_ manager: UndoManager, stepID: UUID) {
        manager.registerUndo(withTarget: self) { [weak manager] model in
            MainActor.assumeIsolated {
                guard model.active, let manager else { return }
                model.library.sortUndoCoordinator.enqueue(model, stepID: stepID, manager: manager)
            }
        }
        manager.setActionName("Sort Inbox")
    }

    func apply(_ action: Action) async throws {
        try await withDrainedEditor {
            try ensureAvailable()
            try library.flush()
            guard let item = current else { return }
            guard try eligible().contains(item.id) else { queue.removeFirst(); total -= 1; return }
            let change: Change
            switch action {
            case .type(let type):
                let result = try library.store.setType(type, noteIds: [item.id])
                if result.didChange { change = .type(result); summary.typed += 1 }
                else { change = .skip; summary.skipped += 1 }
                if !result.skippedNotApplied.isEmpty { showNotice("The type could not be added inside an unfinished code block.") }
            case .archive:
                let revisions = try nextRevisions([item.id])
                try library.store.archive([item.id]); change = .location(revisions, .archive); summary.archived += 1
                if selectedNoteID == item.id { selectedNoteID = nil }
            case .trash:
                let revisions = try nextRevisions([item.id])
                try library.store.trash([item.id]); change = .location(revisions, .trash); summary.trashed += 1
                if selectedNoteID == item.id { selectedNoteID = nil }
            case .skip:
                change = .skip; summary.skipped += 1
            }
            queue.removeFirst()
            history.append(Step(items: [item], change: change))
            try library.refreshSessions()
        }
    }

    @discardableResult func archiveRest(expectedCount: Int? = nil) async throws -> Int {
        try await withDrainedEditor {
            try ensureAvailable()
            try library.flush()
            let valid = try eligible()
            let moving = queue.filter { valid.contains($0.id) }
            guard expectedCount == nil || expectedCount == moving.count else { throw Failure.inboxChanged }
            total -= queue.count - moving.count
            queue = moving
            guard !moving.isEmpty else { return 0 }
            let ids = moving.map(\.id)
            let revisions = try nextRevisions(ids)
            try library.store.archive(ids)
            if let selected = selectedNoteID, ids.contains(selected) { selectedNoteID = nil }
            summary.archived += moving.count
            history.append(Step(items: moving, change: .location(revisions, .archive)))
            queue = []
            try library.refreshSessions()
            return moving.count
        }
    }

    func undo(expected: UUID? = nil) async throws {
        try await withDrainedEditor {
            try ensureAvailable()
            try library.flush()
            guard let step = history.last else { return }
            guard expected == nil || expected == step.id else { throw Failure.undoOrderChanged }
            switch step.change {
            case .type(let result):
                let restored = try library.store.undoTagRewrite(result)
                if Set(restored) != Set(result.changedNoteIds) { showNotice(Failure.noteChanged.localizedDescription) }
                summary.typed -= step.items.count
            case .location(let revisions, let location):
                let ids = try revisions.compactMap { id, revision -> String? in
                    guard let note = try library.store.note(id: id), note.location == location, note.revision == revision else { return nil }
                    return id
                }
                if ids.count != revisions.count { showNotice(Failure.noteChanged.localizedDescription) }
                try library.store.restore(ids)
                if let selected = selectedNoteID, ids.contains(selected) { selectedNoteID = nil }
                if location == .archive { summary.archived -= revisions.count } else { summary.trashed -= revisions.count }
            case .skip: summary.skipped -= step.items.count
            }
            history.removeLast()
            queue.insert(contentsOf: step.items, at: 0)
            try library.refreshSessions()
        }
    }

    private func nextRevisions(_ ids: [String]) throws -> [String: Int] {
        try Dictionary(uniqueKeysWithValues: ids.map { id in
            guard let note = try library.store.note(id: id) else { throw Failure.noteChanged }
            return (id, note.revision + 1)
        })
    }

    enum Failure: LocalizedError {
        case workspaceChanged, inboxChanged, noteChanged, undoOrderChanged
        var errorDescription: String? {
            switch self {
            case .workspaceChanged: "The workspace changed. Reopen Sort Inbox to continue."
            case .inboxChanged: "The inbox changed. Review the remaining notes and try again."
            case .noteChanged: "The note changed since sorting, so it was left unchanged."
            case .undoOrderChanged: "The sort history changed. Reopen Sort Inbox to continue."
            }
        }
    }
}
