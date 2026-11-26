// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// Records the history of one open note: one snapshot when the
/// session closes and one after 15 minutes without typing. The `writer` decides what is stored and
/// where: `NoteStore` for unlocked notes (it refuses a locked one), `LockedNoteAccess` for locked
/// ones (it seals). The recorder never keeps, logs or writes the text itself.
@MainActor
public final class SnapshotRecorder {
    public static let idleInterval: Duration = .seconds(900)

    private let session: NoteSession
    private let writer: any SnapshotWriting
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date
    private var listener: NoteSession.ListenerToken?
    private var stopped = false
    /// The text the history last got (or already had) from this recorder, starting with the text
    /// the note was opened with. An idle snapshot needs the live text to differ from it.
    private var lastSeen: String
    /// The pending idle snapshot; internal so tests can await it.
    private(set) var idleTask: Task<Void, Never>?

    public init(session: NoteSession, writer: any SnapshotWriting, clock: any Clock<Duration> = ContinuousClock(),
                now: @escaping @Sendable () -> Date = { .now }) {
        self.session = session
        self.writer = writer
        self.clock = clock
        self.now = now
        lastSeen = session.text
        listener = session.addActivityListener { [weak self] activity in
            // Only the editor's typing counts; text that came in from elsewhere is not an edit here.
            guard case .edited = activity else { return }
            self?.edited()
        }
    }

    isolated deinit {
        idleTask?.cancel()
    }

    /// Call right before the session is dropped. Safe to call more than once: the writer skips a
    /// text that equals the newest snapshot.
    public func sessionWillClose() {
        guard !stopped else { return }
        cancelIdle()
        // A note that was opened empty and is still empty has no history worth starting.
        if session.text.isEmpty && lastSeen.isEmpty { return }
        record()
    }

    /// Ends recording: no listener, no timer, and `sessionWillClose()` does nothing any more.
    public func stop() {
        stopped = true
        cancelIdle()
        if let token = listener { session.removeListener(token) }
        listener = nil
    }

    private func edited() {
        guard !stopped else { return }
        idleTask?.cancel()
        let sleep = clock.sleeper(for: Self.idleInterval)
        idleTask = Task { [weak self] in
            do { try await sleep() } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.idleTask = nil
            // Only while there is something new: a transaction that changed nothing, or typing
            // that was taken back, leaves the text as it was.
            guard !TextNormalization.identical(self.session.text, self.lastSeen) else { return }
            self.record()
        }
    }

    private func cancelIdle() {
        idleTask?.cancel()
        idleTask = nil
    }

    /// A failure is swallowed (typing and closing must not depend on the history) and logged with
    /// the note id and the error's type, never its description, which could carry text.
    private func record() {
        let noteId = session.noteId
        let text = session.text
        do {
            _ = try writer.takeSnapshot(noteId: noteId, text: text, now: now())
            lastSeen = text
        } catch {
            let kind = String(describing: type(of: error))
            sessionLogger.error("note \(noteId, privacy: .public): snapshot not recorded (\(kind, privacy: .public))")
        }
    }
}

extension Clock {
    /// Fixes the deadline now, so the idle time is measured from the edit and not from when the
    /// timer task first runs.
    fileprivate func sleeper(for delay: Duration) -> @Sendable () async throws -> Void {
        let deadline = now.advanced(by: delay)
        return { try await self.sleep(until: deadline, tolerance: nil) }
    }
}
