// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import os

private let voiceLogger = Logger(subsystem: "com.truebrewbirdie.baerchen", category: "voice")

public enum VoiceCaptureError: Error, Equatable, Sendable {
    /// `start` was called on a capture that already started.
    case alreadyStarted
    /// `stop` was called before `start`.
    case notListening
    /// The capture was cancelled.
    case cancelled
    /// The insert target is missing, deleted or locked.
    case noteUnavailable(noteId: String)
    /// The session did not take the text (its journal could not be written).
    case textNotApplied(noteId: String)
    /// The note was locked while the capture ran; nothing heard after that was kept.
    case noteLocked(noteId: String)
    /// Insert mode is switched off (`VoiceCapture.isInsertModeEnabled`).
    case insertModeUnavailable
    /// Stop gave up waiting for the engine's last results; what was heard so far is kept.
    case stopTimedOut
    case recordingUnreadable
}

/// One spoken note: the engine records and transcribes, this class puts the result into
/// the library.
///
/// - **New note:** the note (`captureSource = voice`) is created at `start`. Every final result is
///   applied to the note's `NoteSession` as it arrives, so it is journaled at once and survives a
///   crash. Stop links the recording on its own line after the text.
/// - **Insert:** nothing changes until Stop, which inserts the heard text and the recording's link
///   at the caret. Cancel leaves the note byte-identical.
/// - **Stop** waits for the remaining final results, copies the recording into the note's
///   attachments, commits the session and removes the recording from `Recordings/`.
/// - **Interruption or input change** runs the Stop path and ends in `.stoppedByInput`.
/// - **Engine failure** keeps everything received so far (and the recording, if there is one) and
///   ends in `.failed`; nothing is trashed.
/// - **Cancel** trashes a new note only while its text is still exactly what the capture wrote
/// and deletes the recording.
///
/// - **Lock:** a local or remote lock of the note stops the capture before the lock commits
///   (`CaptureLockGuard`): the recording and, for a new note, its journal are deleted, everything
///   heard is dropped, and the phase is `.failed` (`VoiceCaptureError.noteLocked`). Every journal
///   write re-reads the note's lock state first.
///
/// If the recording cannot be attached, it stays in `Recordings/<noteId>/` for
/// `VoiceRecordingRecovery` at the next launch. One that cannot be played is marked when its words
/// are in the note; with no words either and no failure, nothing is kept.
@MainActor
public final class VoiceCapture {
    public enum Target: Equatable, Sendable {
        case newNote
        case insert(noteId: String, utf16Offset: Int)
    }

    public enum Phase: Equatable, Sendable {
        case idle
        case listening
        case finishing
        case finished(noteId: String)
        case stoppedByInput(noteId: String)
        case cancelled
        case failed
    }

    /// The one switch for insert mode (Edit ▸ Insert Voice Note). Off, `start` refuses an insert
    /// target with `insertModeUnavailable`; new-note capture is unaffected.
    public static var isInsertModeEnabled = true

    public private(set) var phase: Phase = .idle
    /// The final results so far plus the current volatile one, for the panel.
    public private(set) var liveText = ""
    /// The new note (set by `start`) or the insert target.
    public private(set) var noteId: String?

    private let target: Target
    private let store: NoteStore
    private let attachments: AttachmentStore
    private let sessionProvider: @MainActor (String) throws -> NoteSession
    private let engine: any VoiceEngine
    private let recordingsDirectory: URL
    private let now: () -> Date
    /// How long Stop waits for the engine to deliver the last results before it gives up.
    private let finishTimeout: Duration

    private enum FinishOutcome: Sendable { case done, failed(any Error), timedOut }
    private enum Ending { case stop, input, cancel, locked }
    private var ending: Ending?
    /// Cancel or a lock ended it: nothing more is written.
    private var abandoned: Bool { ending == .cancel || ending == .locked }
    private var isStarting = false
    private var lockGuard: CaptureLockGuard?
    private var failure: (any Error)?
    private var session: NoteSession?
    private var recording: URL?
    /// The final results, joined.
    private var heard = ""
    private var volatile = ""
    private struct ProvisionalDraft {
        let offset: Int
        let text: String
        let revision: Int
        var separator: String { text.hasPrefix(" ") ? " " : "" }
    }
    /// The provisional words in a new note's session; the session holds them out of the store
    /// and `draftListener` moves them with other editors' changes.
    private var provisionalDraft: ProvisionalDraft? {
        didSet { session?.heldRange = provisionalDraft.map { $0.offset..<($0.offset + $0.text.utf16.count) } }
    }
    private var draftListener: NoteSession.ListenerToken?
    /// New note: final text the session has not taken yet.
    private var pendingNoteText = ""
    /// New note: the text the capture alone made of it (what Cancel compares against).
    private var createdText = ""
    private var pump: Task<Void, Never>?
    /// The one call that tears the engine down (`finish` or `cancel`, never both).
    private var engineStop: Task<Void, Never>?

    /// `session` returns the app's session for a note (its cached one, so an open editor sees the
    /// text arrive); it is called once, at `start`. Recordings go to
    /// `recordingsDirectory/<noteId>/` (`AppPaths.recordings`).
    public init(
        target: Target,
        store: NoteStore,
        attachments: AttachmentStore,
        session: @escaping @MainActor (String) throws -> NoteSession,
        engine: any VoiceEngine,
        recordingsDirectory: URL,
        now: @escaping () -> Date = Date.init,
        finishTimeout: Duration = .seconds(15)
    ) {
        self.finishTimeout = finishTimeout
        self.target = target
        self.store = store
        self.attachments = attachments
        sessionProvider = session
        self.engine = engine
        self.recordingsDirectory = recordingsDirectory
        self.now = now
    }

    /// A capture dropped without Stop or Cancel stops recording: the engine is
    /// cancelled once and then the recording removed, from a detached task. The guard stays
    /// registered until that is done, so a lock that arrives meanwhile still stops this capture
    /// and removes the recording (`CaptureLockGuard`). A removal that fails keeps the guard's
    /// cleanup obligation (marker, launch retry). One that is already finishing or ended has torn
    /// the engine down and keeps its recording for the next launch's recovery.
    isolated deinit {
        // What it journaled stays the note's text; it is committed with the next flush.
        if let draftListener { session?.removeListener(draftListener) }
        session?.heldRange = nil
        guard phase == .listening, engineStop == nil, let guardian = lockGuard else {
            lockGuard?.end()
            return
        }
        guardian.markDropped()
        let engine = engine, recording = recording
        Task.detached {
            await engine.cancel()
            do { try guardian.releaseDropped() } catch {
                voiceLogger.error("a dropped voice capture's recording could not be removed; the launch retries")
            }
            guardian.end()
            if let folder = recording?.deletingLastPathComponent(),
               (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    /// 's file name: `Voice Note yyyy-MM-dd HH.mm.m4a`, local time.
    public static func recordingName(at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "Voice Note \(formatter.string(from: date)).m4a"
    }

    // MARK: - Start, Stop, Cancel

    public func start() async throws {
        guard phase == .idle, !isStarting else { throw VoiceCaptureError.alreadyStarted }
        isStarting = true
        defer { isStarting = false }
        let startedAt = now()
        let id: String
        switch target {
        case .newNote:
            id = try store.create(text: "", now: startedAt, captureSource: .voice).id
        case .insert(let noteId, _):
            guard Self.isInsertModeEnabled else {
                phase = .failed
                throw VoiceCaptureError.insertModeUnavailable
            }
            guard let note = try store.note(id: noteId), note.deletedAt == nil, !note.isLocked else {
                phase = .failed
                throw VoiceCaptureError.noteUnavailable(noteId: noteId)
            }
            id = noteId
        }
        noteId = id
        do {
            let session = try sessionProvider(id)
            self.session = session
            if target == .newNote {
                draftListener = session.addTextListener { [weak self] _, changeSet in self?.follow(changeSet) }
            }
            let url = try Self.makeRecordingURL(in: recordingsDirectory, noteId: id, name: Self.recordingName(at: startedAt))
            recording = url
            // Registration and the lock check are one writer transaction: a lock either finds the
            // guard or is found here, before the engine starts.
            let guardian: CaptureLockGuard
            do {
                guardian = try CaptureLockGuard.register(
                    noteId: id, store: store, recording: url, discardsJournal: target == .newNote
                ) { [weak self] in
                    Task { @MainActor in await self?.noteWasLocked() }
                }
            } catch StoreError.noteLocked {
                throw VoiceCaptureError.noteLocked(noteId: id)
            }
            lockGuard = guardian
            let events = try await engine.start(recordingTo: url)
            if guardian.isLocked {
                await stopEngine(finish: false).value
                throw VoiceCaptureError.noteLocked(noteId: id)
            }
            phase = .listening
            pump = Task { [weak self] in
                var streamError: (any Error)?
                do {
                    for try await event in events { self?.handle(event) }
                } catch {
                    streamError = error
                }
                await self?.streamEnded(with: streamError)
            }
        } catch {
            let locked = lockGuard?.isLocked == true
            endLockGuard()
            if case .newNote = target, !locked {
                do { try store.cancelCapture(noteId: id, createdText: "") } catch {
                    voiceLogger.error("note \(id, privacy: .public): could not trash the unused voice note")
                }
            }
            removeRecording()
            phase = .failed
            throw error
        }
    }

    /// Ends the capture and returns the heard text (the final results, joined by spaces). After an
    /// input change it waits for that Stop and returns the same; after a failure it throws it.
    @discardableResult
    public func stop() async throws -> String {
        switch phase {
        case .idle: throw VoiceCaptureError.notListening
        case .cancelled where abandoned: throw VoiceCaptureError.cancelled
        case .failed: throw failure ?? VoiceCaptureError.notListening
        case .listening: if ending == nil { beginFinishing(.stop) }
        case .finishing, .finished, .stoppedByInput, .cancelled: break
        }
        await engineStop?.value
        await pump?.value
        switch phase {
        case .finished, .stoppedByInput: return heard
        // Ended with nothing to keep: an empty result, not an error.
        case .cancelled where !abandoned: return heard
        case .cancelled: throw VoiceCaptureError.cancelled
        default: throw failure ?? VoiceCaptureError.notListening
        }
    }

    /// Stops without keeping anything: the recording is deleted, an insert target is untouched and
    /// a new note goes to the Trash unless someone else edited it meanwhile.
    public func cancel() async {
        guard phase == .listening || phase == .finishing, !abandoned else { return }
        ending = .cancel
        // A Stop already running finishes the engine; it is not torn down a second time.
        await stopEngine(finish: false).value
        pump?.cancel()
        await pump?.value
        if case .newNote = target, let noteId, let session {
            do {
                applyPendingText()
                retractProvisional()
                try session.flush()
                try store.cancelCapture(noteId: noteId, createdText: createdText)
            } catch {
                voiceLogger.error("note \(noteId, privacy: .public): cancelling the voice note failed")
            }
        }
        removeRecording()
        endLockGuard()
        volatile = ""
        liveText = heard
        phase = .cancelled
    }

    /// The lock path (`CaptureLockGuard`) already deleted the recording and the new note's journal
    /// before the lock committed; this stops the engine and drops what was heard. When that cleanup
    /// failed, the lock was rolled back: the recording and the journal stay as they are (the next
    /// launch's recovery adopts the recording), and the guard stays registered until a later lock
    /// attempt cleans up.
    private func noteWasLocked() async {
        guard phase == .listening || phase == .finishing || phase == .idle, ending != .cancel, ending != .locked,
              let noteId else { return }
        let starting = phase == .idle
        ending = .locked
        // A cleanup that failed is the capture's error (its obligation is kept).
        failure = lockGuard?.cleanupError ?? VoiceCaptureError.noteLocked(noteId: noteId)
        heard = ""
        volatile = ""
        liveText = ""
        pendingNoteText = ""
        createdText = ""
        // A start still waiting for the engine sees the lock and cleans up itself.
        if starting { return }
        await stopEngine(finish: false).value
        pump?.cancel()
        await pump?.value
        if lockGuard?.isCleanedUp == true { removeRecording() }
        endLockGuard()
        phase = .failed
    }

    /// Tears the engine down exactly once: `finish` (Stop, an input change) or `cancel` (Cancel, a
    /// lock, a stream that ended without Stop). A later request waits for the first one.
    @discardableResult
    private func stopEngine(finish: Bool) -> Task<Void, Never> {
        if let engineStop { return engineStop }
        let engine = engine, timeout = finishTimeout
        let task = Task { [weak self] in
            if finish {
                // Not a task group: a finish that ignores cancellation would hold the group open.
                let (outcomes, outcome) = AsyncStream.makeStream(of: FinishOutcome.self)
                let work = Task {
                    do { try await engine.finish(); outcome.yield(.done) } catch { outcome.yield(.failed(error)) }
                }
                let timer = Task {
                    try? await Task.sleep(for: timeout)
                    outcome.yield(.timedOut)
                }
                var result = FinishOutcome.done
                for await first in outcomes { result = first; break }
                timer.cancel()
                switch result {
                case .done: break
                case .failed(let error): if self?.failure == nil { self?.failure = error }
                case .timedOut:
                    voiceLogger.error("voice: the engine did not finish in time; it is stopped")
                    if self?.failure == nil { self?.failure = VoiceCaptureError.stopTimedOut }
                    work.cancel()
                    self?.keepProvisional()
                    // Neither the engine's cancel nor its event stream may hold Stop
                    // the pump is ended here, and the cancel gets the same limit again.
                    self?.pump?.cancel()
                    await Self.bounded(timeout) { await engine.cancel() }
                }
            } else {
                await engine.cancel()
            }
        }
        engineStop = task
        return task
    }

    /// Every way out of a capture passes here: the guard ends and the session lets go of the draft.
    private func endLockGuard() {
        lockGuard?.end()
        if let draftListener { session?.removeListener(draftListener) }
        draftListener = nil
        session?.heldRange = nil
    }

    // MARK: - Events

    private func handle(_ event: VoiceEvent) {
        guard !abandoned, phase == .listening || phase == .finishing else { return }
        switch event {
        case .transcript(let update):
            let piece = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if update.isFinal {
                // A final replaces the provisional words; an empty one retracts them.
                volatile = ""
                if piece.isEmpty { retractProvisional() } else { acceptFinal(piece) }
            } else if !piece.isEmpty {
                volatile = piece
                journalProvisional(piece)
            }
            liveText = Self.join(heard, volatile)
        case .interrupted, .inputChanged:
            guard phase == .listening, ending == nil else { return }
            beginFinishing(.input)
        }
    }

    /// A final result: kept in `heard`, and for a new note appended to its text at once.
    private func acceptFinal(_ piece: String) {
        heard = Self.join(heard, piece)
        if case .newNote = target, let session {
            if let draft = currentDraft {
                let separated = draft.separator + piece
                do {
                    try insert(separated, at: draft.offset, in: session, deleting: draft.text.utf16.count)
                    provisionalDraft = nil
                    createdText += separated
                    return
                } catch { /* Keep the last journaled draft if it cannot be replaced. */ }
            }
            provisionalDraft = nil
            let separated = appendSeparator(in: session) + piece
            createdText += separated
            pendingNoteText += separated
            applyPendingText()
        }
    }

    /// The draft, while the session text still holds it where it was put.
    private var currentDraft: ProvisionalDraft? {
        provisionalDraft.flatMap { $0.revision == session?.revision ? $0 : nil }
    }

    /// Words appended to a new note get a space unless they are its first text.
    private func appendSeparator(in session: NoteSession) -> String {
        createdText.isEmpty && session.text.isEmpty ? "" : " "
    }

    private func journalProvisional(_ piece: String) {
        guard case .newNote = target, let session else { return }
        applyPendingText()
        guard pendingNoteText.isEmpty else { return }
        let text: String, offset: Int, deleting: Int
        if let draft = currentDraft {
            (text, offset, deleting) = (draft.separator + piece, draft.offset, draft.text.utf16.count)
            if draft.text == text { return }
        } else {
            provisionalDraft = nil
            (text, offset, deleting) = (appendSeparator(in: session) + piece, session.text.utf16.count, 0)
        }
        do {
            try insert(text, at: offset, in: session, deleting: deleting)
            provisionalDraft = ProvisionalDraft(offset: offset, text: text, revision: session.revision)
        } catch {
            voiceLogger.error("note \(session.noteId, privacy: .public): a provisional voice result was not journaled")
            if failure == nil { failure = error }
            if phase == .listening, lockGuard?.isLocked != true { beginFinishing(.stop) }
        }
    }

    /// Takes the provisional words out of a new note's session again (an empty final, Cancel). A
    /// draft another editor changed is theirs now and stays.
    private func retractProvisional() {
        guard let draft = currentDraft, let session else { return }
        do {
            try insert("", at: draft.offset, in: session, deleting: draft.text.utf16.count)
            provisionalDraft = nil
        } catch {
            voiceLogger.error("note \(session.noteId, privacy: .public): retracted voice words could not be removed")
        }
    }

    /// Another editor's change (or an external one) moves the draft; one that touches it ends
    /// the draft, and its words stay as that editor left them.
    private func follow(_ changeSet: ChangeSet) {
        guard let draft = provisionalDraft, let session else { return }
        provisionalDraft = changeSet.mapped(draft.offset..<(draft.offset + draft.text.utf16.count)).map {
            ProvisionalDraft(offset: $0.lowerBound, text: draft.text, revision: session.revision)
        }
    }

    /// A Stop that timed out keeps the last provisional words as heard.
    private func keepProvisional() {
        guard !abandoned, !volatile.isEmpty else { return }
        let piece = volatile
        volatile = ""
        acceptFinal(piece)
    }

    /// Runs `work` and returns when it is done or after `limit`, whichever comes first. The work is
    /// not cancelled: it may ignore cancellation, and Stop must not wait for it.
    private static func bounded(_ limit: Duration, _ work: @escaping @Sendable () async -> Void) async {
        let (done, signal) = AsyncStream.makeStream(of: Void.self)
        Task.detached {
            await work()
            signal.yield()
        }
        let timer = Task {
            try? await Task.sleep(for: limit)
            signal.yield()
        }
        for await _ in done { break }
        timer.cancel()
    }

    private func beginFinishing(_ reason: Ending) {
        phase = .finishing
        ending = reason
        stopEngine(finish: true)
    }

    private func streamEnded(with error: (any Error)?) async {
        guard !abandoned, phase == .listening || phase == .finishing else { return }
        if let error, failure == nil { failure = error }
        // Without a Stop the engine did not wind down through `finish`: tear it down (tap removed,
        // file closed) before the recording is attached. With one, wait for that `finish`.
        await stopEngine(finish: false).value
        guard !abandoned, phase == .listening || phase == .finishing else { return }
        complete()
    }

    /// The Stop path's end: link the recording, commit, clean up. Synchronous, so Cancel cannot
    /// run halfway through it.
    private func complete() {
        keepProvisional()
        volatile = ""
        liveText = heard
        guard let noteId, let session else {
            phase = .failed
            return
        }
        do {
            // An unusable journal is reset by committing to the store here, outside the guard.
            if !session.isJournalUsable, lockGuard?.isLocked != true { try session.flush() }
            applyPendingText()
            if !pendingNoteText.isEmpty { throw VoiceCaptureError.textNotApplied(noteId: noteId) }
            if lockGuard?.isLocked == true { throw VoiceCaptureError.noteLocked(noteId: noteId) }
            var link: String?
            let readable = recording.map { engine.isRecordingReadable(at: $0) } ?? false
            if let recording, readable {
                link = AttachmentMarkdown.link(for: try attachments.add(fileAt: recording, to: noteId))
            }
            switch target {
            case .newNote:
                if let link {
                    let text = session.text
                    try insert((text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + link, at: text.utf16.count, in: session)
                }
            case .insert(_, let offset):
                let parts = [heard, link ?? ""].filter { !$0.isEmpty }
                if !parts.isEmpty {
                    let utf16 = Array(session.text.utf16)
                    let at = min(max(offset, 0), utf16.count)
                    var insertion = parts.joined(separator: "\n")
                    // The link keeps its own line: text after the caret moves to the next one.
                    if link != nil, at < utf16.count, utf16[at] != 0x0A { insertion += "\n" }
                    try insert(insertion, at: at, in: session)
                }
            }
            try session.flush()
            guard readable else {
                // After a failure (a Stop that timed out) the file may not be closed yet: recovery
                // decides about it later.
                guard heard.isEmpty, failure == nil else {
                    // The words are in the note: a later launch removes the file.
                    if let recording, !heard.isEmpty { VoiceRecordingRecovery.mark(recording, wordsInserted: true, at: now()) }
                    throw failure ?? VoiceCaptureError.recordingUnreadable
                }
                // Nothing recognised and nothing that plays: nothing is kept.
                if case .newNote = target { try store.cancelCapture(noteId: noteId, createdText: createdText) }
                removeRecording()
                endLockGuard()
                phase = .cancelled
                return
            }
            removeRecording()
            endLockGuard()
            if failure != nil {
                phase = .failed
            } else {
                phase = ending == .input ? .stoppedByInput(noteId: noteId) : .finished(noteId: noteId)
            }
        } catch {
            if lockGuard?.isLocked == true || (try? store.note(id: noteId))?.isLocked == true {
                // Locked meanwhile: nothing of it is kept.
                var cleanupError: (any Error)?
                do { try lockGuard?.lockDetected() } catch {
                    cleanupError = error
                    voiceLogger.error("note \(noteId, privacy: .public): removing the voice recording after a lock failed")
                }
                failure = cleanupError ?? VoiceCaptureError.noteLocked(noteId: noteId)
                ending = .locked
                heard = ""
                liveText = ""
                removeRecording()
            } else if failure == nil {
                // The recording stays in Recordings/ for the next launch's recovery.
                failure = error
            }
            voiceLogger.error("note \(noteId, privacy: .public): finishing the voice note failed")
            endLockGuard()
            phase = .failed
        }
    }

    // MARK: - Text

    private func applyPendingText() {
        guard !pendingNoteText.isEmpty, let session else { return }
        do {
            try insert(pendingNoteText, at: session.text.utf16.count, in: session)
            pendingNoteText = ""
        } catch VoiceCaptureError.noteLocked {
            pendingNoteText = ""
        } catch where lockGuard?.isLocked == true {
            // Locked, and its cleanup failed: nothing more is written; the stop reports the error.
            pendingNoteText = ""
        } catch {
            voiceLogger.error("note \(session.noteId, privacy: .public): a voice result was not journaled yet")
        }
    }

    /// Applies one insertion through the session (journaled before it is acked), only while the
    /// note is unlocked: under the lock guard, after re-reading the note's lock state, so neither a
    /// lock through this process's lock path nor one written elsewhere lets plaintext reach the
    /// journal. A lock found here runs the guard's lock path and throws `noteLocked`.
    private func insert(_ text: String, at offset: Int, in session: NoteSession, deleting: Int = 0) throws {
        let noteId = session.noteId
        guard let lockGuard else { throw VoiceCaptureError.noteLocked(noteId: noteId) }
        // Under the guard only the journal is written: no store write (an unusable journal is
        // refused, not flushed) and no listener (they run after the guard is released), because a
        // lock holding the database writer may be waiting for this guard.
        let outcome = try lockGuard.ifUnlocked { () throws -> (@MainActor () -> Void)? in
            guard let note = try store.note(id: noteId) else { throw VoiceCaptureError.noteUnavailable(noteId: noteId) }
            guard !note.isLocked else { return nil }
            guard session.isJournalUsable else { throw VoiceCaptureError.textNotApplied(noteId: noteId) }
            let length = session.text.utf16.count
            var sections: [ChangeSet.Section] = []
            if offset > 0 { sections.append(.retain(offset)) }
            sections.append(.replace(deleteLength: deleting, insert: text))
            if length > offset + deleting { sections.append(.retain(length - offset - deleting)) }
            let (result, deliver) = session.applyJournaled(
                txId: UUID().uuidString, baseRevision: session.revision, changeSet: ChangeSet(sections: sections), origin: draftListener)
            guard case .acked = result else { throw VoiceCaptureError.textNotApplied(noteId: noteId) }
            lockGuard.markJournaled()
            return deliver
        }
        if let deliver = outcome ?? nil {
            deliver()
            return
        }
        do {
            try lockGuard.lockDetected()
        } catch {
            // Surfaced as the capture's error; the guard keeps the obligation.
            voiceLogger.error("note \(noteId, privacy: .public): removing the voice recording after a lock failed")
            throw error
        }
        throw VoiceCaptureError.noteLocked(noteId: noteId)
    }

    private static func join(_ a: String, _ b: String) -> String {
        a.isEmpty ? b : b.isEmpty ? a : a + " " + b
    }

    // MARK: - Recording file

    /// `directory/<noteId>/<name>`; a name already taken there gets " 2", " 3", ….
    private static func makeRecordingURL(in directory: URL, noteId: String, name: String) throws -> URL {
        let folder = directory.appendingPathComponent(noteId, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name, isDirectory: false)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem) \(number).\(ext)", isDirectory: false)
            number += 1
        }
        return candidate
    }

    private func removeRecording() {
        guard let recording else { return }
        try? FileManager.default.removeItem(at: recording)
        let folder = recording.deletingLastPathComponent()
        if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: folder)
        }
        self.recording = nil
    }
}
