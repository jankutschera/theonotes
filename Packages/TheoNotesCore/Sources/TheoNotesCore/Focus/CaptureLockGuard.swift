// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import os

private let captureGuardLogger = Logger(subsystem: "com.truebrewbirdie.baerchen", category: "capture")

/// A capture that writes into a note while it records (a voice note) registers one of these, so
/// that locking the note stops it before the lock commits (FOC-R199 and its addenda).
///
/// **Everything that changes a guard runs on the database writer**, the serial queue every lock
/// transaction runs on:
/// - `register` checks that the note is unlocked and adds the guard in one write transaction, so
///   a lock either sees the guard or `register` sees the lock, never neither.
/// - `FocusPurge` calls `noteWillLock` inside the locking transaction (local lock and lock
///   through sync); `lockDetected` (a lock found some other way) runs in a write transaction too.
///
/// Stopping is one state machine: `active → stopping → cleaned | cleanupFailed`. Every caller
/// of a stop that is already running waits for its shared completion and gets the same result. A
/// stop after `cleanupFailed` tries again. Cleanup removes the recording and, with
/// `discardsJournal`, the note's journal files: it lists them, moves each aside and deletes the
/// moved files only after every move worked; any failure moves back what is left and throws.
/// - From `noteWillLock` the failure aborts the lock (it rolls back with the note, its recording
///   and journal as they were).
/// - From `lockDetected` the lock is already committed elsewhere: the failure is thrown to the
///   capture, and a marker `Recordings/.pending-cleanup-<noteId>` keeps the obligation. The next
///   lock or sync pass of the note retries through the still-registered guard, and the next
///   launch through `finishPendingCleanups`.
/// `onLock` runs after the first stop, whatever its result; it must only schedule work.
///
/// A capture that keeps the note's journal (insert mode) never has it deleted: if it journaled
/// text and the journal still holds entries, the stop throws `NotePrivacyError.pendingEdits`, so
/// the lock rolls back until the session has committed that text. `NotePrivacy.lock` and
/// `SyncMaterializer.writeNote` stop the captures first thing (before their own journal check),
/// so nothing can be journaled after a lock looked.
public final class CaptureLockGuard: @unchecked Sendable {
    public enum CleanupError: Error {
        /// The cleanup failed and the marker that keeps the obligation could not be written either.
        case markerNotWritten(cleanup: any Error, marker: any Error)
    }

    public let noteId: String
    private let recording: URL
    private let journalDirectory: URL
    private let discardsJournal: Bool
    private let database: AppDatabase
    private let onLock: @Sendable () -> Void

    private enum State {
        case active
        case stopping(Completion)
        case cleaned
        case cleanupFailed(any Error)
    }

    private let gate = NSLock()
    private var state = State.active
    private var endRequested = false
    /// The capture's journal write was acknowledged under `ifUnlocked` (`markJournaled`).
    private var wroteJournal = false
    /// The capture object is gone (`markDropped`): no journal belongs to it any more.
    private var dropped = false

    private init(noteId: String, recording: URL, journalDirectory: URL, discardsJournal: Bool, database: AppDatabase,
                 onLock: @escaping @Sendable () -> Void) {
        self.noteId = noteId
        self.recording = recording
        self.journalDirectory = journalDirectory
        self.discardsJournal = discardsJournal
        self.database = database
        self.onLock = onLock
    }

    /// Registers a guard until `end()`, in one writer transaction with the check that the note
    /// exists, is not deleted and is unlocked (`StoreError.noteLocked` / `noteNotFound` otherwise).
    public static func register(
        noteId: String, store: NoteStore, recording: URL, discardsJournal: Bool,
        onLock: @escaping @Sendable () -> Void
    ) throws -> CaptureLockGuard {
        let guardian = CaptureLockGuard(
            noteId: noteId, recording: recording, journalDirectory: store.paths.journal, discardsJournal: discardsJournal,
            database: store.db, onLock: onLock)
        try store.db.pool.write { db in
            guard let note = try Note.fetchOne(db, key: noteId), note.deletedAt == nil else {
                throw StoreError.noteNotFound(id: noteId)
            }
            guard !note.isLocked else { throw StoreError.noteLocked(id: noteId) }
            registry.withLock { $0[noteId, default: []].append(guardian) }
        }
        return guardian
    }

    /// Whether a lock (or an attempt to lock) reached this guard: the capture must stop.
    public var isLocked: Bool {
        gate.withLock { if case .active = state { return false } else { return true } }
    }

    /// Whether the recording and journal were removed by a lock.
    public var isCleanedUp: Bool {
        gate.withLock { if case .cleaned = state { return true } else { return false } }
    }

    /// Why the last cleanup failed, while it has not succeeded since.
    public var cleanupError: (any Error)? {
        gate.withLock { if case .cleanupFailed(let error) = state { return error } else { return nil } }
    }

    /// Runs `body` and returns its result, or returns nil without running it once the note was
    /// locked. A lock waits for a running `body`, so `body` must never write to the database (the
    /// lock holds the writer while it waits): use it for journal writes, not store writes.
    /// `body` calls `markJournaled()` once its journal write was acknowledged (FOC-R301).
    public func ifUnlocked<T>(_ body: () throws -> T) rethrows -> T? {
        gate.lock()
        defer { gate.unlock() }
        guard case .active = state else { return nil }
        return try body()
    }

    /// The capture's journal write was acknowledged: its text may sit in the note's journal, so a
    /// stop that finds the journal non-empty must not discard it. Only a write that was acked
    /// counts; a body that wrote nothing (refused, unacked, note locked) never calls this. Call
    /// it only from inside an `ifUnlocked` body (that holds the gate).
    public func markJournaled() {
        wroteJournal = true
    }

    /// The capture is over. The guard leaves the registry now, unless a lock reached it and its
    /// cleanup has not succeeded: then it stays until a later lock attempt cleans up.
    public func end() {
        let leave = gate.withLock { () -> Bool in
            endRequested = true
            switch state {
            case .active, .cleaned: return true
            case .stopping, .cleanupFailed: return false
            }
        }
        if leave { unregister() }
    }

    /// The capture found the note locked by a path that did not run `noteWillLock` (another
    /// process, a direct write). Runs the lock steps in a writer transaction and throws the
    /// cleanup failure; the obligation is kept (see the type's notes).
    public func lockDetected() throws {
        try database.pool.write { _ in try stop(external: true) }
    }

    /// The capture object was dropped. From now on a stop removes only the recording: the journal
    /// (the capture's own text, or the editor's) is no longer the capture's to delete or to
    /// vouch for, and a lock's own journal check decides about it.
    public func markDropped() {
        gate.withLock { dropped = true }
    }

    /// The capture was dropped while it still recorded, and its engine has been cancelled
    /// (FOC-R307). Removes the recording, and only the recording: text the capture journaled stays
    /// for the next launch. It runs the same stop as a lock, on the writer, so a lock that arrives
    /// meanwhile and this cleanup never overlap, and a lock that came first has already done it.
    /// On a failure the obligation is kept like `lockDetected` keeps it (marker, registered guard)
    /// and the error is thrown. Call `end()` afterwards.
    public func releaseDropped() throws {
        try database.pool.write { _ in try stop(external: true, recordingOnly: true) }
    }

    // MARK: - Lock

    private static let registry = Registry()

    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var guards: [String: [CaptureLockGuard]] = [:]
        func withLock<T>(_ body: (inout [String: [CaptureLockGuard]]) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(&guards)
        }
    }

    private func unregister() {
        Self.registry.withLock { guards in
            guards[noteId]?.removeAll { $0 === self }
            if guards[noteId]?.isEmpty == true { guards[noteId] = nil }
        }
    }

    /// The note is being locked (inside the locking transaction, on the writer). Throws, and so
    /// aborts the lock, when a capture's plaintext could not be removed.
    static func noteWillLock(_ noteId: String) throws {
        let affected = registry.withLock { $0[noteId] ?? [] }
        for guardian in affected { try guardian.stop(external: false) }
    }

    /// One completion shared by every caller of a running stop.
    private final class Completion: @unchecked Sendable {
        private let condition = NSCondition()
        private var result: Result<Void, any Error>?
        func resolve(_ value: Result<Void, any Error>) {
            condition.lock()
            result = value
            condition.broadcast()
            condition.unlock()
        }
        func wait() -> Result<Void, any Error> {
            condition.lock()
            defer { condition.unlock() }
            while result == nil { condition.wait() }
            return result!
        }
    }

    private enum Step {
        case run(Completion, first: Bool)
        case wait(Completion)
        case done
    }

    private func stop(external: Bool, recordingOnly: Bool = false) throws {
        let step = gate.withLock { () -> Step in
            switch state {
            case .active:
                let completion = Completion()
                state = .stopping(completion)
                return .run(completion, first: true)
            case .stopping(let completion):
                return .wait(completion)
            case .cleaned:
                return .done
            case .cleanupFailed:
                let completion = Completion()
                state = .stopping(completion)
                return .run(completion, first: false)
            }
        }
        switch step {
        case .done:
            return
        case .wait(let completion):
            try completion.wait().get()
        case .run(let completion, let first):
            let only = recordingOnly || gate.withLock { dropped }
            var result = Result { try cleanUp(recordingOnly: only) }
            switch result {
            case .success:
                removeMarker()
            case .failure(let cleanupError):
                if external {
                    do { try writeMarker(recordingOnly: only) } catch {
                        captureGuardLogger.error("note \(self.noteId, privacy: .public): the pending-cleanup marker could not be written")
                        result = .failure(CleanupError.markerNotWritten(cleanup: cleanupError, marker: error))
                    }
                }
            }
            let leave = gate.withLock { () -> Bool in
                switch result {
                case .success: state = .cleaned
                case .failure(let error): state = .cleanupFailed(error)
                }
                return endRequested && (try? result.get()) != nil
            }
            completion.resolve(result)
            if leave { unregister() }
            if first { onLock() }
            try result.get()
        }
    }

    /// All or nothing up to the last delete: list, move every file aside, delete the moved files.
    /// A failure moves back what is still there and rethrows.
    private func cleanUp(recordingOnly: Bool = false) throws {
        let fm = FileManager.default
        if !discardsJournal, !recordingOnly {
            // Insert mode: the journal is the note's own; text the capture journaled must be
            // committed (or the journal emptied by the session) before the note can lock.
            let wrote = gate.withLock { wroteJournal }
            let entries = journalDirectory.appendingPathComponent(noteId + ".jsonl")
            if wrote, ((try? entries.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 {
                throw NotePrivacyError.pendingEdits
            }
        }
        var targets: [URL] = []
        if (try? recording.checkResourceIsReachable()) == true { targets.append(recording) }
        let folder = recording.deletingLastPathComponent()
        if let names = try? fm.contentsOfDirectory(atPath: folder.path) {
            targets += names.filter { $0.hasPrefix(Self.asidePrefix(noteId)) }.map { folder.appendingPathComponent($0) }
        }
        if discardsJournal, !recordingOnly { targets += try Self.journalFiles(of: noteId, in: journalDirectory) }
        try Self.remove(targets, noteId: noteId)
    }

    /// Moved-aside files are named `.locking-<noteId>-<uuid>`.
    private static func asidePrefix(_ noteId: String) -> String { ".locking-\(noteId)-" }

    /// The note's journal files, and any of its files left moved aside by an earlier cleanup.
    private static func journalFiles(of noteId: String, in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(noteId + ".") || $0.hasPrefix(asidePrefix(noteId)) }
            .map { directory.appendingPathComponent($0) }
    }

    private static func remove(_ targets: [URL], noteId: String) throws {
        let fm = FileManager.default
        var moved: [(original: URL, aside: URL)] = []
        do {
            for url in targets {
                let aside = url.deletingLastPathComponent().appendingPathComponent(asidePrefix(noteId) + UUID().uuidString)
                try fm.moveItem(at: url, to: aside)
                moved.append((url, aside))
            }
            for item in moved { try fm.removeItem(at: item.aside) }
        } catch {
            for item in moved where fm.fileExists(atPath: item.aside.path) {
                try? fm.moveItem(at: item.aside, to: item.original)
            }
            throw error
        }
    }

    // MARK: - The kept obligation

    private static let markerPrefix = ".pending-cleanup-"

    private var marker: URL {
        recording.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(Self.markerPrefix + noteId)
    }

    /// The marker holds only whether the journal goes too (no note text).
    private func writeMarker(recordingOnly: Bool = false) throws {
        try Data((discardsJournal && !recordingOnly ? "journal" : "recording").utf8).write(to: marker, options: .atomic)
    }

    private func removeMarker() {
        try? FileManager.default.removeItem(at: marker)
    }

    /// Whether `name` (an entry of the recordings folder) is a kept cleanup obligation.
    public static func isPendingCleanupMarker(_ name: String) -> Bool { name.hasPrefix(markerPrefix) }

    /// Launch: finishes every cleanup a capture could not finish after its note was locked
    /// elsewhere. For a note that is locked, deleted or gone, its recordings folder and (when the
    /// marker says so) its journal files are removed, and the marker with them; a note that is
    /// unlocked again keeps its files and only the marker goes. A failure leaves the marker for
    /// the next launch and is thrown after every marker was tried. Returns how many were finished.
    ///
    /// It also deletes every `.locking-…` file (one an interrupted cleanup moved aside) in the
    /// journal folder and in the recordings folders.
    @discardableResult
    public static func finishPendingCleanups(store: NoteStore, recordings: URL) throws -> Int {
        let fm = FileManager.default
        var firstError: (any Error)?
        func sweep(_ folder: URL) {
            for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(".locking-") {
                do { try fm.removeItem(at: folder.appendingPathComponent(name)) } catch {
                    if firstError == nil { firstError = error }
                }
            }
        }
        sweep(store.paths.journal)
        for name in (try? fm.contentsOfDirectory(atPath: recordings.path)) ?? [] where !isPendingCleanupMarker(name) {
            sweep(recordings.appendingPathComponent(name, isDirectory: true))
        }
        guard let names = try? fm.contentsOfDirectory(atPath: recordings.path) else {
            if let firstError { throw firstError }
            return 0
        }
        var finished = 0
        for name in names where isPendingCleanupMarker(name) {
            let noteId = String(name.dropFirst(markerPrefix.count))
            let markerURL = recordings.appendingPathComponent(name)
            do {
                let note = try store.note(id: noteId)
                if let note, note.deletedAt == nil, !note.isLocked {
                    try fm.removeItem(at: markerURL)
                    continue
                }
                var targets: [URL] = []
                let folder = recordings.appendingPathComponent(noteId, isDirectory: true)
                if fm.fileExists(atPath: folder.path) {
                    targets += try fm.contentsOfDirectory(atPath: folder.path).map { folder.appendingPathComponent($0) }
                }
                if (try? String(contentsOf: markerURL, encoding: .utf8)) == "journal" {
                    targets += try journalFiles(of: noteId, in: store.paths.journal)
                }
                try remove(targets, noteId: noteId)
                try? fm.removeItem(at: folder)
                try fm.removeItem(at: markerURL)
                finished += 1
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
        return finished
    }
}
