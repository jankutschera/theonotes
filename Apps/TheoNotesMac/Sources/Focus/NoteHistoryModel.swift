// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import GRDB

/// Note ▸ Note History… for one note (spec A5): the earlier versions
/// the app kept of it, a preview of each, Restore as Copy and Replace This Note.
///
/// The list follows the `note_snapshot` table itself. Snapshot writes post no change notification
///, so waiting for one would leave the window stale when a new version is taken while
/// it is open. A locked note's history is sealed: it is listed, previewed and restored only while
/// the vault is unlocked, and nothing of it is shown while App Lock is engaged.
@MainActor
final class NoteHistoryModel: ObservableObject {
    static let title = "Note History"
    static let restoreTitle = "Restore as Copy"
    static let replaceTitle = "Replace This Note…"
    static let replaceQuestion = "Replace the note with this version? The current text is kept in the history."
    static let replaceConfirmTitle = "Replace"
    static let cancelTitle = "Cancel"
    static let emptyText = "No earlier versions yet."
    static let needsVaultText = "Unlock your protected notes to see the history of this one."
    static let unsavedNotice = "This note has changes that are not saved yet."
    static let changedNotice = "The note changed meanwhile. Open the history again and retry."
    static let typingNotice = "Your latest typing has not been saved yet. Try again in a moment."
    static let failedNotice = "That did not work."

    let noteId: String
    /// Newest first. Empty while App Lock is engaged, and for a locked note while the vault is locked.
    @Published private(set) var items: [NoteSnapshot] = []
    /// The version shown in the preview, and its text (nil until `preview(_:)` was called).
    @Published private(set) var previewedId: String?
    @Published private(set) var previewText: String?
    /// The note is locked and the vault is not unlocked: nothing can be listed or opened.
    @Published private(set) var needsVault = false
    /// App Lock is engaged: the window shows nothing and does nothing.
    @Published private(set) var isAppLocked = false
    /// A short remark: why an action did not happen.
    @Published private(set) var notice: String?

    /// Asks before Replace (the sheet shows the alert); false when the person cancelled.
    var confirmReplace: () -> Bool = { false }
    /// Whether every editor showing the note has handed over what was typed (tests replace it).
    lazy var syncEditors: (String) async -> Bool = { [environment] in await environment.confirmEditorsInSync(noteId: $0) }
    /// Shows a note in a window of its own; true when it was shown.
    var openNote: (_ noteId: String) -> Bool = { _ in false }

    private let environment: AppEnvironment
    private var observation: AnyDatabaseCancellable?
    private var lockToken: AppLock.HandlerToken?
    private var closed = false

    init(noteId: String, environment: AppEnvironment) {
        self.noteId = noteId
        self.environment = environment
        isAppLocked = environment.appLock.isLocked
        lockToken = environment.appLock.addDidLockHandler { [weak self] in self?.appLockEngaged() }
        reload()
        followVault()
        let noteId = noteId
        observation = ValueObservation
            .tracking { db in
                // Every row id, marked when sealed: a retention swap (one row in, one out) and an
                // in-place seal both change it, which a count or a newest id would not show.
                try String.fetchAll(
                    db,
                    sql: "SELECT id || CASE WHEN sealedText IS NULL THEN '' ELSE ':sealed' END FROM note_snapshot WHERE noteId = ? ORDER BY id",
                    arguments: [noteId])
            }
            .removeDuplicates()
            .start(in: environment.database.pool, scheduling: .immediate, onError: { error in
                appLogger.error("note history observation failed: \(error)")
            }, onChange: { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            })
    }

    isolated deinit {
        close()
    }

    /// The window closed: no observation, no handlers.
    func close() {
        closed = true
        observation?.cancel()
        observation = nil
        if let lockToken { environment.appLock.removeDidLockHandler(lockToken) }
        lockToken = nil
    }

    /// The vault opening or closing changes what can be read although no row changes: a relock must
    /// take the previews of a locked note off the screen. The change is seen before it is made, so
    /// the read waits for the next turn.
    private func followVault() {
        guard !closed else { return }
        withObservationTracking {
            _ = environment.vault.isUnlocked
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                self.reload()
                self.followVault()
            }
        }
    }

    // MARK: Reading

    /// The note this history belongs to, nil when it is gone.
    private var note: Note? { (try? environment.store.note(id: noteId)) ?? nil }

    /// Reads the list again. Nothing is read while App Lock is engaged.
    func reload() {
        isAppLocked = environment.appLock.isLocked
        guard !isAppLocked else { return clear() }
        guard let note else { return clear() }
        do {
            if note.isLocked {
                guard let access = environment.vault.access else {
                    needsVault = true
                    return clear(keepingNeedsVault: true)
                }
                needsVault = false
                set(items: try access.snapshots(noteId: noteId))
            } else {
                needsVault = false
                set(items: try environment.store.snapshots(noteId: noteId))
            }
        } catch {
            environment.logSessionFailure("note history not read", noteId: noteId, keyed: note.isLocked, error: error)
            clear()
        }
        if let previewedId, !items.contains(where: { $0.id == previewedId }) { dropPreview() }
    }

    private func set(items new: [NoteSnapshot]) {
        if items != new { items = new }
    }

    private func clear(keepingNeedsVault: Bool = false) {
        if !keepingNeedsVault { needsVault = false }
        if !items.isEmpty { items = [] }
        dropPreview()
    }

    private func dropPreview() {
        previewedId = nil
        previewText = nil
    }

    private func appLockEngaged() {
        notice = nil
        reload()
    }

    /// Whether the actions may run now: App Lock off, the note there, and the vault open for a locked note.
    private var canAct: Bool {
        guard !environment.appLock.isLocked, let note else { return false }
        return !note.isLocked || environment.vault.access != nil
    }

    // MARK: Actions

    /// Shows a version's text. Writes nothing.
    @discardableResult
    func preview(_ snapshot: NoteSnapshot) -> String? {
        notice = nil
        guard canAct else { return nil }
        do {
            let text = try snapshotText(snapshot.id)
            previewedId = snapshot.id
            previewText = text
            return text
        } catch {
            fail("note history preview failed", error)
            return nil
        }
    }

    /// Makes a new note from a version and shows it in a window of its own. The note and its history
    /// stay as they were. A locked note's copy is locked.
    @discardableResult
    func restoreAsCopy(_ snapshot: NoteSnapshot) -> Note? {
        notice = nil
        guard canAct else { return nil }
        do {
            let copy: Note
            if let access = lockedAccess() {
                copy = try access.restoreSnapshotAsCopy(id: snapshot.id)
            } else {
                copy = try environment.store.restoreSnapshotAsCopy(id: snapshot.id)
            }
            if !openNote(copy.id) { notice = "The copy is in your notes; it could not be opened." }
            return copy
        } catch {
            fail("note history restore failed", error)
            return nil
        }
    }

    /// Replace This Note: asks; on yes this note's typed text is saved (the editor is asked first
    /// whether a transaction is still on its way), the current text becomes a version of its own and
    /// the chosen version is written as an ordinary edit, in one transaction. Nothing is saved or
    /// written before the answer, and nothing for another note. False when nothing was replaced.
    @discardableResult
    func replace(_ snapshot: NoteSnapshot) async -> Bool {
        notice = nil
        guard canAct else { return false }
        guard confirmReplace() else { return false }
        // The person may have locked the app while the question was up.
        guard canAct else { return false }
        environment.flushSession(noteId: noteId)
        guard await syncEditors(noteId) else {
            notice = Self.typingNotice
            return false
        }
        guard canAct else { return false }
        guard environment.flushSession(noteId: noteId), let revision = note?.revision else {
            notice = Self.unsavedNotice
            return false
        }
        do {
            if let access = lockedAccess() {
                _ = try access.replaceNote(withSnapshot: snapshot.id, expectedRevision: revision)
            } else {
                _ = try environment.store.replaceNote(withSnapshot: snapshot.id, expectedRevision: revision)
            }
            reload()
            return true
        } catch StoreError.revisionConflict {
            notice = Self.changedNotice
            return false
        } catch {
            fail("note history replace failed", error)
            return false
        }
    }

    // MARK: Helpers

    /// The vault's access when the note is locked (it seals and opens); nil for an unlocked note.
    private func lockedAccess() -> LockedNoteAccess? {
        guard note?.isLocked == true else { return nil }
        return environment.vault.access
    }

    private func snapshotText(_ id: String) throws -> String {
        if let access = lockedAccess() { return try access.snapshotText(id: id) }
        return try environment.store.snapshotText(id: id)
    }

    /// Logs the note id and the failure's code; a locked note's error can carry protected text.
    private func fail(_ what: String, _ error: Error) {
        environment.logSessionFailure(what, noteId: noteId, keyed: note?.isLocked == true, error: error)
        notice = Self.failedNotice
    }
}
