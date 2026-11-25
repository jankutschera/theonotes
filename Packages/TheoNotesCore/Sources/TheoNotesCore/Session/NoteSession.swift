// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import CryptoKit

public enum ApplyResult: Equatable, Sendable {
    case acked(revision: Int)
    case duplicate(revision: Int)
    case needsFullText(currentRevision: Int)
}

public enum ExternalChangeOutcome: Equatable, Sendable {
    case unchanged
    case adopted
    case merged
    case conflictCopy(noteId: String)
}

public enum NoteSessionError: Error, Equatable { case sessionClosed }
public enum NoteSessionFenceError: Error, Equatable { case stale }

/// An opaque, content-free snapshot of live session registrations and revisions.
public struct NoteSessionFence: Equatable, Sendable {
    struct Stamp: Hashable, Sendable {
        let registrationID: UUID
        let noteID: String
        let revision: Int
        let committedStoreRevision: Int
    }
    let directory: URL
    let noteIDs: Set<String>
    let stamps: Set<Stamp>
}

/// Swift's authoritative copy of one open note. Every editor transaction is applied, journaled
/// (fsync) and only then acked; commits to SQLite are debounced.
///
/// Journal invariant: while it has entries, `base.baseText` + entries == `text`. The base record
/// is written before the first entry, so recovery never depends on what the store holds now.
@MainActor
public final class NoteSession {
    public let noteId: String
    public private(set) var text: String
    /// Local editor revision: +1 per applied transaction and per adopted/merged external change.
    public private(set) var revision: Int
    public private(set) var committedText: String
    /// The note's store revision as of the last load or commit.
    public private(set) var committedStoreRevision: Int
    /// The copy made while replaying the journal in `init`, if the store had diverged.
    public private(set) var recoveryConflictCopyId: String?

    /// Identifies one registered listener; pass it to `removeListener(_:)` and, for text
    /// listeners, as `apply(origin:)` so an editor is not sent its own transaction back.
    public struct ListenerToken: Hashable, Sendable {
        fileprivate let id: Int
    }

    /// Called whenever `text` changed other than by the listener's own transaction: an external
    /// change was adopted or merged, or another listener's transaction was applied. Gets the new
    /// text and the changeset transforming the previous `text` into it; `revision` is already
    /// incremented (by exactly one).
    public typealias TextListener = @MainActor (_ newText: String, _ changeSet: ChangeSet) -> Void
    /// Called with the new note's id whenever an external change conflicted with local edits and
    /// the remote text was kept as a copy (from `flush()`, a debounced commit or
    /// `handleExternalChange()`). Recovery during `init` reports via `recoveryConflictCopyId`.
    public typealias ConflictCopyListener = @MainActor (_ copyId: String) -> Void

    private var nextListenerId = 0
    /// In registration order, so delivery order is deterministic.
    private var textListeners: [(token: ListenerToken, handler: TextListener)] = []
    private var conflictCopyListeners: [(token: ListenerToken, handler: ConflictCopyListener)] = []

    /// The number of attached editors (text listeners).
    public var textListenerCount: Int { textListeners.count }

    /// What happened to the note's text, so the app can tell the editor's typing from changes
    /// made elsewhere (CLI, tag rename, sync, …) — e.g. to follow only title edits made here (R15).
    public enum Activity: Sendable {
        /// An editor transaction was applied and acked (not committed yet).
        case edited
        /// The session committed its text: the editor's typing on top of any external change
        /// reported before it (a merge reports `externalChange` first, then this).
        case committed(text: String, modifiedAt: Date)
        /// Text from outside the editor came in (adopted, or merged with unsaved typing);
        /// `previous` → `text` is that change alone. Not reported for a conflict, whose external
        /// text goes to a copy.
        case externalChange(previous: String, text: String, modifiedAt: Date)
    }

    /// Called synchronously for each `Activity`. Recovery during `init` happens before any is added.
    public typealias ActivityListener = @MainActor (_ activity: Activity) -> Void
    private var activityListeners: [(token: ListenerToken, handler: ActivityListener)] = []

    private let store: any NoteSessionStore
    private let originallyLocked: Bool
    public var wasOriginallyLocked: Bool { originallyLocked }
    let journal: EditJournal
    private let commitDelay: Duration
    private let clock: any Clock<Duration>
    private var journalHasEntries = false
    /// The journal no longer reproduces `text` (an external replacement could not be journaled).
    private var journalBroken = false
    public private(set) var isInvalidated = false
    private var recentTxIds: [String] = []
    private var recentTxIdSet: Set<String> = []
    private static let rememberedTxIds = 512
    private static let maxConflictAttempts = 3
    /// The pending debounced commit; internal so tests can await it.
    private(set) var commitTask: Task<Void, Never>?
    /// Test seam: runs right before each store write.
    var beforeCommitForTesting: (() -> Void)?

    public convenience init(
        noteId: String,
        store: any NoteSessionStore,
        journalDirectory: URL,
        journalKey: SymmetricKey? = nil,
        commitDelay: Duration = .milliseconds(400),
        clock: any Clock<Duration> = ContinuousClock()
    ) throws {
        try self.init(
            noteId: noteId, store: store, journalDirectory: journalDirectory, journalKey: journalKey,
            commitDelay: commitDelay, clock: clock, journalFaultInjector: nil
        )
    }

    /// Test seam: `journalFaultInjector` is installed before recovery runs.
    init(
        noteId: String,
        store: any NoteSessionStore,
        journalDirectory: URL,
        journalKey: SymmetricKey? = nil,
        commitDelay: Duration = .milliseconds(400),
        clock: any Clock<Duration> = ContinuousClock(),
        journalFaultInjector: ((JournalOperation, FileHandle) throws -> Void)?
    ) throws {
        try JournalVariantRecovery.requireReplaySafe(noteId: noteId, directory: journalDirectory)
        guard let note = try store.note(id: noteId) else { throw StoreError.noteNotFound(id: noteId) }
        guard !note.isLocked || journalKey != nil else { throw StoreError.noteLocked(id: noteId) }
        self.noteId = noteId
        self.store = store
        originallyLocked = note.isLocked
        self.commitDelay = commitDelay
        self.clock = clock
        journal = try EditJournal(directory: journalDirectory, noteId: noteId, encryptionKey: journalKey)
        journal.faultInjector = journalFaultInjector
        // Rows written before line endings were normalised may hold "\r\n"/"\r" (see TextNormalization).
        let loaded = TextNormalization.normalizeLineEndings(note.text)
        text = loaded
        committedText = loaded
        committedStoreRevision = note.revision
        revision = 0
        try recover(storeNote: note)
        NoteSessionRegistry.register(self, directory: journalDirectory, noteID: noteId)
    }

    isolated deinit {
        commitTask?.cancel()
    }

    /// The caller must first preserve or explicitly discard pending edits under its library fence.
    /// This permanently disables the session and closes its journal descriptor without writing.
    public func invalidate() throws {
        isInvalidated = true
        cancelCommit()
        removeAllListeners()
        try journal.close()
    }

    /// Invalidates even sessions still retained by editors outside a host's session cache.
    public static func invalidateSessions(journalDirectory: URL, noteIDs: Set<String>) throws {
        try NoteSessionRegistry.invalidate(directory: journalDirectory, noteIDs: noteIDs)
    }

    /// Includes sessions retained outside a host's cache, without retaining or mutating them.
    public static func liveSessionIDs(journalDirectory: URL) -> Set<String> {
        NoteSessionRegistry.liveSessionIDs(directory: journalDirectory)
    }

    public static func captureSessionFence(journalDirectory: URL, noteIDs: Set<String>) -> NoteSessionFence {
        NoteSessionRegistry.capture(directory: journalDirectory, noteIDs: noteIDs)
    }

    /// Compare every live holder before invalidating any; caller holds its host admission fence.
    public static func invalidateSessions(journalDirectory: URL, noteIDs: Set<String>, matching fence: NoteSessionFence) throws {
        try NoteSessionRegistry.invalidate(directory: journalDirectory, noteIDs: noteIDs, matching: fence)
    }

    // MARK: - Listeners

    public func addTextListener(_ handler: @escaping TextListener) -> ListenerToken {
        let token = makeToken()
        textListeners.append((token, handler))
        return token
    }

    public func addConflictCopyListener(_ handler: @escaping ConflictCopyListener) -> ListenerToken {
        let token = makeToken()
        conflictCopyListeners.append((token, handler))
        return token
    }

    /// Activity listeners do not count as editors (`textListenerCount`).
    public func addActivityListener(_ handler: @escaping ActivityListener) -> ListenerToken {
        let token = makeToken()
        activityListeners.append((token, handler))
        return token
    }

    /// Removing a token that is not (or no longer) registered does nothing.
    public func removeListener(_ token: ListenerToken) {
        textListeners.removeAll { $0.token == token }
        conflictCopyListeners.removeAll { $0.token == token }
        activityListeners.removeAll { $0.token == token }
    }

    /// The session is being dropped (its note was deleted): nobody is told anything any more.
    public func removeAllListeners() {
        textListeners.removeAll()
        conflictCopyListeners.removeAll()
        activityListeners.removeAll()
    }

    /// Like `notifyTextListeners`: the listeners registered when it happened, minus removed ones.
    private func report(_ activity: Activity) {
        for listener in activityListeners {
            guard activityListeners.contains(where: { $0.token == listener.token }) else { continue }
            listener.handler(activity)
        }
    }

    private func makeToken() -> ListenerToken {
        nextListenerId += 1
        return ListenerToken(id: nextListenerId)
    }

    /// Delivers to the listeners registered when the change happened; one that is removed by an
    /// earlier listener's callback is skipped.
    private func notifyTextListeners(_ newText: String, _ changeSet: ChangeSet, except origin: ListenerToken?) {
        for listener in textListeners where listener.token != origin {
            guard textListeners.contains(where: { $0.token == listener.token }) else { continue }
            listener.handler(newText, changeSet)
        }
    }

    private func notifyConflictCopy(_ copyId: String) {
        for listener in conflictCopyListeners {
            guard conflictCopyListeners.contains(where: { $0.token == listener.token }) else { continue }
            listener.handler(copyId)
        }
    }

    // MARK: - Editing

    /// Preserve the browser document before a reload can discard transactions we never acknowledged.
    @discardableResult public func preserveBrowserRecovery(text browserText: String, baseRevision: Int) throws -> String {
        try preserveBrowserRecoveryResult(text: browserText, baseRevision: baseRevision).note.id
    }

    public func preserveBrowserRecoveryResult(text browserText: String, baseRevision: Int) throws -> BrowserRecoveryResult {
        guard !isInvalidated else { throw NoteSessionError.sessionClosed }
        guard baseRevision >= 0 else { throw CocoaError(.fileWriteUnknown) }
        if let original = try store.note(id: noteId), original.deletedAt == nil,
           original.isLocked == originallyLocked,
           TextNormalization.identical(TextNormalization.normalizeLineEndings(browserText), text) {
            return BrowserRecoveryResult(note: original, created: false)
        }
        let copy = try store.preserveBrowserRecovery(noteId: noteId, text: browserText, baseRevision: baseRevision, now: .now)
        if copy.created { notifyConflictCopy(copy.note.id) }
        return copy
    }

    /// Only for an explicitly confirmed orphan discard, fenced by the revision shown to the user.
    public func discardPendingJournalAfterConfirmation(expectedRevision: Int) throws {
        guard !isInvalidated else { throw NoteSessionError.sessionClosed }
        guard revision == expectedRevision else { throw CocoaError(.fileWriteUnknown) }
        commitTask?.cancel()
        try journal.truncate()
        journalHasEntries = false
    }

    /// Applies one editor transaction. Once it is journaled and acked, every other text listener
    /// receives it like an external change (same text, revision one up), so several editors on
    /// this note stay on one revision sequence. `origin` is the sending editor's token; nil (or a
    /// removed token) means no listener sent it, so every listener receives it. It has no default
    /// so an editor cannot forget it and be sent its own transaction back.
    public func apply(
        txId: String, baseRevision: Int, changeSet: ChangeSet, origin: ListenerToken?
    ) -> ApplyResult {
        guard !isInvalidated else { return .needsFullText(currentRevision: revision) }
        if recentTxIdSet.contains(txId) { return .duplicate(revision: revision) }
        if journalUnusable {
            // Get the text into the store so the journal can be reset; never ack meanwhile.
            do { try flush() } catch {
                sessionLogger.error("note \(self.noteId, privacy: .public): forced flush failed")
            }
            if journalUnusable { return .needsFullText(currentRevision: revision) }
        }
        let (result, deliver) = applyJournaled(txId: txId, baseRevision: baseRevision, changeSet: changeSet, origin: origin)
        deliver()
        return result
    }

    /// Whether the journal can take an entry now. When it cannot, `apply` first flushes to the
    /// store (a database write); `applyJournaled` refuses instead.
    public var isJournalUsable: Bool { !isInvalidated && !journalUnusable }

    /// `apply` without its side trips, for a caller that holds a lock a database writer may wait
    /// for (a voice capture's lock guard): it never writes to the store (an unusable journal gives
    /// `.needsFullText`, no forced flush) and tells no listener. The returned `deliver` tells the
    /// listeners and reports `.edited`; call it once the lock is released (it does nothing unless
    /// the result is `.acked`).
    public func applyJournaled(
        txId: String, baseRevision: Int, changeSet: ChangeSet, origin: ListenerToken?
    ) -> (result: ApplyResult, deliver: @MainActor () -> Void) {
        guard !isInvalidated else { return (.needsFullText(currentRevision: revision), {}) }
        if recentTxIdSet.contains(txId) { return (.duplicate(revision: revision), {}) }
        guard !journalUnusable, baseRevision == revision, let newText = try? changeSet.apply(to: text) else {
            return (.needsFullText(currentRevision: revision), {})
        }
        do {
            try appendToJournal(JournalEntry(txId: txId, baseRevision: baseRevision, changeSet: changeSet))
        } catch {
            sessionLogger.error("note \(self.noteId, privacy: .public): journal append failed, tx not acked")
            return (.needsFullText(currentRevision: revision), {})
        }
        text = newText
        revision += 1
        remember(txId)
        scheduleCommit()
        let acked = revision
        return (.acked(revision: acked), { [weak self] in
            guard let self, !self.isInvalidated else { return }
            self.notifyTextListeners(newText, changeSet, except: origin)
            if !self.isInvalidated { self.report(.edited) }
        })
    }

    /// Words a voice capture is still recognising (a UTF-16 range of `text`): journaled like any
    /// edit, but `flush` and the debounced commit leave them out of the store (FOC-R395). The
    /// capture keeps it current and clears it.
    public var heldRange: Range<Int>?

    /// Commits pending text now, except `heldRange`. On a store revision conflict the external
    /// change is merged (or a conflict copy is made) via `handleExternalChange()`.
    public func flush() throws {
        guard !isInvalidated else { throw NoteSessionError.sessionClosed }
        cancelCommit()
        guard isDirty else {
            truncateJournal()
            return
        }
        do {
            try commitUnheld(text, held: heldRange, expectedRevision: committedStoreRevision)
        } catch StoreError.revisionConflict {
            _ = try handleExternalChange()
        }
        journalUncommittedText()
    }

    /// Commits `text` without its `held` range; nothing when only held words are new (the journal
    /// keeps them). Fail-open: a range that does not fit commits everything (FOC-R400).
    private func commitUnheld(_ text: String, held: Range<Int>?, expectedRevision: Int) throws {
        var committing = text
        if let held, held.upperBound <= text.utf16.count,
           let without = try? ChangeSet(sections: [
               .retain(held.lowerBound), .replace(deleteLength: held.count, insert: ""),
               .retain(text.utf16.count - held.upperBound),
           ]).apply(to: text) {
            committing = without
        }
        guard !TextNormalization.identical(committing, committedText) else { return }
        try commit(committing, expectedRevision: expectedRevision)
    }

    /// A commit that left held words out emptied the journal; they go back in, so they still
    /// survive a crash (base = the committed text, one entry = the rest).
    private func journalUncommittedText() {
        guard isDirty, !journalHasEntries, !journalUnusable else { return }
        do {
            try journal.writeBase(JournalBase(storeRevision: committedStoreRevision, baseText: committedText))
            try journal.append(JournalEntry(txId: "held-\(UUID().uuidString)", baseRevision: revision,
                                            changeSet: ThreeWayMerge.changeSet(from: committedText, to: text)))
            journalHasEntries = true
        } catch {
            journalBroken = true
            sessionLogger.error("note \(self.noteId, privacy: .public): held text could not be journaled again")
        }
    }

    public func handleExternalChange() throws -> ExternalChangeOutcome {
        guard !isInvalidated else { throw NoteSessionError.sessionClosed }
        let outcome = try handleExternalChange(attempt: 1)
        journalUncommittedText()
        return outcome
    }

    // MARK: - Private

    private var journalUnusable: Bool { journalBroken || journal.isPoisoned }

    /// Byte comparison: a normalisation-only edit (NFC → NFD) is a change that must be committed.
    private var isDirty: Bool { !TextNormalization.identical(text, committedText) }

    private func handleExternalChange(attempt: Int) throws -> ExternalChangeOutcome {
        func retry(_ current: Int) throws -> ExternalChangeOutcome {
            guard attempt < Self.maxConflictAttempts else {
                sessionLogger.error("note \(self.noteId, privacy: .public): giving up after \(attempt) revision conflicts")
                throw StoreError.revisionConflict(current: current)
            }
            return try handleExternalChange(attempt: attempt + 1)
        }

        guard let note = try store.note(id: noteId) else { throw StoreError.noteNotFound(id: noteId) }
        guard note.revision != committedStoreRevision else { return .unchanged }
        let remote = TextNormalization.normalizeLineEndings(note.text)
        if TextNormalization.identical(remote, committedText) {
            // Revision bumped without a text change (e.g. an identical write): re-base, and
            // commit pending local text on top so callers like flush() leave the session clean.
            committedStoreRevision = note.revision
            if isDirty {
                do {
                    try commitUnheld(text, held: heldRange, expectedRevision: note.revision)
                } catch StoreError.revisionConflict(let current) {
                    return try retry(current)
                }
            }
            return .unchanged
        }

        if !isDirty {
            cancelCommit()
            let previous = committedText
            committedText = remote
            committedStoreRevision = note.revision
            truncateJournal()
            replaceText(with: remote)
            report(.externalChange(previous: previous, text: remote, modifiedAt: note.modifiedAt))
            return .adopted
        }

        switch ThreeWayMerge.merge(base: committedText, local: text, remote: remote) {
        case .clean(let merged):
            cancelCommit()
            report(.externalChange(previous: committedText, text: remote, modifiedAt: note.modifiedAt))
            // The held words move with the merge; touched by it, they are committed (fail-open).
            let held = heldRange.flatMap { ThreeWayMerge.changeSet(from: text, to: merged).mapped($0) }
            do {
                try commitUnheld(merged, held: held, expectedRevision: note.revision)
            } catch StoreError.revisionConflict(let current) {
                return try retry(current)
            }
            replaceText(with: merged)
            return .merged
        case .conflict:
            cancelCommit()
            let copy = try store.createConflictCopy(of: noteId, text: remote, now: .now)
            notifyConflictCopy(copy.id)  // reported even if committing the local text fails below
            committedText = remote
            committedStoreRevision = note.revision
            do {
                try commitUnheld(text, held: heldRange, expectedRevision: note.revision)
            } catch StoreError.revisionConflict(let current) {
                _ = try retry(current)
            }
            return .conflictCopy(noteId: copy.id)
        }
    }

    /// Replays the journal onto its saved base and reconciles with what the store holds now.
    private func recover(storeNote note: Note) throws {
        func setAside() throws {
            sessionLogger.error("note \(self.noteId, privacy: .public): journal recovery failed; journal moved aside")
            try journal.moveAside()
        }
        let entries: [JournalEntry]
        do {
            entries = try journal.entries()
        } catch is JournalError {
            return try setAside()
        }
        guard !entries.isEmpty else { return }
        // Replaying onto anything but the recorded base could silently misplace edits.
        let base: JournalBase
        do {
            guard let saved = try journal.base() else { return try setAside() }
            base = saved
        } catch let error as JournalProtectionError {
            throw error
        } catch {
            return try setAside()
        }

        var states = [base.baseText]
        for entry in entries {
            do {
                states.append(try entry.changeSet.apply(to: states[states.count - 1]))
            } catch {
                return try setAside()
            }
        }
        let replayed = states[states.count - 1]
        let storeText = TextNormalization.normalizeLineEndings(note.text)
        journalHasEntries = true
        revision = entries.count
        entries.forEach { remember($0.txId) }

        if note.revision == base.storeRevision || states.contains(where: { TextNormalization.identical($0, storeText) }) {
            // Store is at our base or at a state we produced (an earlier commit landed): fast-forward.
            text = replayed
        } else {
            switch ThreeWayMerge.merge(base: base.baseText, local: replayed, remote: storeText) {
            case .clean(let merged):
                journalExternalChange(ThreeWayMerge.changeSet(from: replayed, to: merged))
                text = merged
            case .conflict:
                let copy = try store.createConflictCopy(of: noteId, text: storeText, now: .now)
                recoveryConflictCopyId = copy.id
                sessionLogger.notice("note \(self.noteId, privacy: .public): recovery conflict, store text kept as \(copy.id, privacy: .public)")
                text = replayed
            }
        }
        try flush()
    }

    /// Writes `newText` to the store and makes it the committed base. A journal truncation
    /// failure after a successful write is not thrown: the journal is marked broken (no acks)
    /// and truncation is retried on the next flush.
    private func commit(_ newText: String, expectedRevision: Int) throws {
        beforeCommitForTesting?()
        guard !isInvalidated else { throw NoteSessionError.sessionClosed }
        let note = try store.updateText(id: noteId, text: newText, expectedRevision: expectedRevision, now: .now)
        committedText = note.text
        committedStoreRevision = note.revision
        truncateJournal()
        report(.committed(text: note.text, modifiedAt: note.modifiedAt))
    }

    private func appendToJournal(_ entry: JournalEntry) throws {
        guard !isInvalidated else { throw NoteSessionError.sessionClosed }
        if try !journalHasEntries || journal.isEmpty() {
            try journal.writeBase(JournalBase(storeRevision: committedStoreRevision, baseText: text))
        }
        try journal.append(entry)
        journalHasEntries = true
    }

    private func replaceText(with newText: String) {
        let changeSet = ThreeWayMerge.changeSet(from: text, to: newText)
        journalExternalChange(changeSet)
        text = newText
        revision += 1
        notifyTextListeners(newText, changeSet, except: nil)
    }

    /// Keeps base + entries == text when `text` is about to change outside `apply` while the
    /// journal still has entries. Never writes to an unusable journal (a torn tail could swallow it).
    private func journalExternalChange(_ changeSet: ChangeSet) {
        guard journalHasEntries else { return }
        guard !journalUnusable else {
            journalBroken = true
            return
        }
        do {
            try journal.append(JournalEntry(
                txId: "external-\(UUID().uuidString)", baseRevision: revision, changeSet: changeSet
            ))
        } catch {
            journalBroken = true
            sessionLogger.error("note \(self.noteId, privacy: .public): could not journal external change")
        }
    }

    private func truncateJournal() {
        guard !isInvalidated else { return }
        guard journalHasEntries || journalUnusable else { return }
        do {
            try journal.truncate()
            journalHasEntries = false
            journalBroken = false
        } catch {
            // The file may be half-truncated (or revert on crash): stop acking until a reset succeeds.
            journalBroken = true
            sessionLogger.error("note \(self.noteId, privacy: .public): journal truncation failed, will retry")
        }
    }

    private func remember(_ txId: String) {
        recentTxIds.append(txId)
        recentTxIdSet.insert(txId)
        if recentTxIds.count > Self.rememberedTxIds {
            recentTxIdSet.remove(recentTxIds.removeFirst())
        }
    }

    private func scheduleCommit() {
        commitTask?.cancel()
        let sleep = clock.sleeper(for: commitDelay)
        commitTask = Task { [weak self] in
            do { try await sleep() } catch { return }
            guard let self, !Task.isCancelled else { return }
            do {
                try self.flush()
            } catch {
                sessionLogger.error("note \(self.noteId, privacy: .public): debounced commit failed")
            }
        }
    }

    private func cancelCommit() {
        commitTask?.cancel()
        commitTask = nil
    }
}

extension Clock {
    /// Fixes the deadline now (not when the returned closure first runs) so a debounce is
    /// measured from the call site.
    fileprivate func sleeper(for delay: Duration) -> @Sendable () async throws -> Void {
        let deadline = now.advanced(by: delay)
        return { try await self.sleep(until: deadline, tolerance: nil) }
    }
}
