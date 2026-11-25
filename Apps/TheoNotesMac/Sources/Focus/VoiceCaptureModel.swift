// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import TheoNotesVoice
import Foundation
import os

private let voiceUILogger = Logger(subsystem: "com.truebrewbirdie.baerchen", category: "voice")

/// File ▸ Capture Voice Note and Edit ▸ Insert Voice Note: what the user sees of one spoken note
/// (spec A2, FOC-R9, FOC-R310 … FOC-R319). It asks the questions before anything starts (microphone,
/// then the speech model), drives one `VoiceCapture` (TheoNotesVoice) and tells the window code which
/// note to show afterwards. The library work is all `VoiceCapture`'s.
///
/// While App Lock is engaged nothing starts, and engaging it cancels a running capture (the core has
/// no hook for that, FOC-R199).
@MainActor
final class VoiceCaptureModel: ObservableObject {
    enum State: Equatable {
        case idle
        /// The speech model for this locale is missing; the panel asks Download / Not Now.
        case askingForModel(Locale)
        /// Recording; the text is what has been heard so far.
        case listening(String)
        /// The microphone changed under the recording (or a call took it). The text and audio so far
        /// are kept; the panel says so until it is dismissed.
        case stoppedByInput
        case unavailable(String)
        case done
    }

    static let stopNotice = "Recording stopped because the microphone changed."
    static let microphoneDeniedMessage =
        "Theo Notes cannot use the microphone. Allow it under Privacy & Security in System Settings, then try again."
    static let unsupportedLocaleMessage = "Voice notes are not available for your language yet."
    static let unavailableMessage = "Voice notes are not available on this Mac."
    static let downloadFailedMessage = "The speech model could not be downloaded. Check your connection and try again."
    static let startFailedMessage = "The voice note could not be started."
    static let noteLockedMessage = "The note was locked, so the voice note was discarded."
    static let noteUnavailableMessage = "That note cannot take a voice note."
    static let interruptedMessage = "Recording stopped unexpectedly. What was heard so far is kept."

    /// The question the panel puts to the user for a missing model.
    static func modelQuestion(for locale: Locale) -> String {
        let name = Locale(identifier: "en").localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        return "Voice notes need the speech model for \(name). Download it from Apple now?"
    }

    @Published private(set) var state: State = .idle
    /// The model is being downloaded (after Download); the panel shows progress instead of the buttons.
    @Published private(set) var isDownloading = false

    /// Shows a new voice note's note once the capture ended (set by the app). True when it was shown.
    var openNote: (_ noteId: String) -> Bool = { _ in false }

    private let environment: AppEnvironment
    private let engineFactory: () -> any VoiceEngine
    private let preflight: any VoicePreflighting
    private let locale: Locale
    private let pollInterval: Duration

    private var capture: VoiceCapture? { didSet { syncBusy() } }
    private var target: VoiceCapture.Target?
    private var watcher: Task<Void, Never>?
    /// The run that tears a capture down after App Lock engaged (tests wait for it).
    private(set) var teardown: Task<Void, Never>?
    private var modelAnswer: CheckedContinuation<Bool, Never>?
    /// Bumped by every begin and by App Lock; an older run ignores what it was waiting for.
    private var generation = 0
    private var isStarting = false { didSet { syncBusy() } }
    /// The capture's note was found locked: the transcript is gone from the panel (FOC-R320).
    private var lockSeen = false
    /// The note whose session this model keeps from being evicted (FOC-R318).
    private var pinnedNoteId: String?

    /// `engineFactory` makes the engine of one capture; `preflight` answers the microphone and model
    /// questions (the app passes the live ones). `pollInterval` is how often a running capture is read.
    init(
        environment: AppEnvironment,
        engineFactory: @escaping () -> any VoiceEngine = { LiveVoiceEngine() },
        preflight: any VoicePreflighting = LiveVoicePreflight(),
        locale: Locale = .current,
        pollInterval: Duration = .milliseconds(100)
    ) {
        self.environment = environment
        self.engineFactory = engineFactory
        self.preflight = preflight
        self.locale = locale
        self.pollInterval = pollInterval
        // Before the lock screen changes hands: the live text must not stay on screen (FOC-R312).
        environment.appLock.addWillLockHandler { [weak self] in self?.appLockEngaged() }
        environment.addNoteLockStateHandler { [weak self] in self?.noteLockStateMayHaveChanged() }
    }

    isolated deinit {
        watcher?.cancel()
    }

    /// A capture is being set up or is running; another one cannot start. Published so the menus follow.
    @Published private(set) var isBusy = false

    private func syncBusy() {
        let busy = isStarting || capture != nil
        if isBusy != busy { isBusy = busy }
    }

    /// The panel has something to show.
    var isShowingPanel: Bool {
        switch state {
        case .idle, .done: false
        default: true
        }
    }

    // MARK: Begin

    /// File ▸ Capture Voice Note: a new note, filled as the words arrive.
    func beginNewNote() async {
        await begin(.newNote)
    }

    /// Edit ▸ Insert Voice Note: what is said goes into `noteId` at `utf16Offset` when it is stopped.
    func beginInsert(noteId: String, utf16Offset: Int) async {
        await begin(.insert(noteId: noteId, utf16Offset: utf16Offset))
    }

    private func begin(_ target: VoiceCapture.Target) async {
        guard !environment.appLock.isLocked, !isBusy else { return }
        generation += 1
        let run = generation
        isStarting = true
        defer { if generation == run { isStarting = false } }
        self.target = target
        lockSeen = false
        state = .idle
        let availability: VoiceAvailability
        do {
            availability = try await VoicePreflight.check(locale: locale, using: preflight) { @Sendable [weak self] modelLocale in
                await self?.askAboutModel(modelLocale, run: run) ?? false
            }
        } catch {
            guard generation == run else { return }
            isDownloading = false
            voiceUILogger.error("the speech model download failed")
            state = .unavailable(Self.downloadFailedMessage)
            return
        }
        // An older run (cancelled, overtaken) must not end a newer run's download display.
        guard generation == run else { return }
        isDownloading = false
        switch availability {
        case .ready: await startCapture(target, run: run)
        // Not Now: nothing starts, nothing was downloaded.
        case .needsModelDownload: state = .idle
        case .microphoneDenied: state = .unavailable(Self.microphoneDeniedMessage)
        case .unsupportedLocale: state = .unavailable(Self.unsupportedLocaleMessage)
        case .unavailable: state = .unavailable(Self.unavailableMessage)
        }
    }

    /// Suspends the preflight on the panel's answer; true downloads the model.
    private func askAboutModel(_ modelLocale: Locale, run: Int) async -> Bool {
        guard generation == run else { return false }
        state = .askingForModel(modelLocale)
        let download = await withCheckedContinuation { modelAnswer = $0 }
        if download, generation == run { isDownloading = true }
        return download && generation == run
    }

    /// The panel's Download (true) or Not Now (false).
    func answerModelQuestion(download: Bool) {
        guard case .askingForModel = state, let answer = modelAnswer else { return }
        modelAnswer = nil
        if !download { state = .idle }
        answer.resume(returning: download)
    }

    private func startCapture(_ target: VoiceCapture.Target, run: Int) async {
        let voice = VoiceCapture(
            target: target, store: environment.store,
            attachments: AttachmentStore(paths: environment.paths, database: environment.database),
            // The note counts as shown from the moment its session exists, before the engine starts (FOC-R318).
            session: { [weak self, environment] noteId in
                self?.pin(noteId)
                return try environment.session(for: noteId)
            },
            engine: engineFactory(), recordingsDirectory: environment.paths.recordings)
        do {
            try await voice.start()
        } catch {
            unpin()
            guard generation == run else { return }
            state = .unavailable(Self.message(forStartFailure: error))
            return
        }
        guard generation == run, !environment.appLock.isLocked else {
            // App Lock engaged (or the start was cancelled) while the engine was starting: the capture is
            // cancelled, never shown.
            await voice.cancel()
            unpin()
            return
        }
        capture = voice
        state = .listening(voice.liveText)
        startWatching()
    }

    private static func message(forStartFailure error: any Error) -> String {
        switch error as? VoiceCaptureError {
        case .noteLocked: noteLockedMessage
        case .noteUnavailable, .insertModeUnavailable: noteUnavailableMessage
        default: startFailedMessage
        }
    }

    // MARK: Stop, Cancel, Dismiss

    /// Stop: what was said is kept, and a new note is shown.
    func stop() async {
        guard let voice = capture, case .listening = state else { return }
        do { try await voice.stop() } catch {
            voiceUILogger.error("a voice note ended with an error")
        }
        conclude(voice)
    }

    /// Cancel: nothing is kept; a new note goes to the Trash and the recording is deleted.
    func cancel() async {
        if case .askingForModel = state, modelAnswer != nil {
            answerModelQuestion(download: false)
            return
        }
        if isStarting, capture == nil {
            // Waiting for the microphone prompt or the download: the run ignores its result.
            generation += 1
            isStarting = false
            isDownloading = false
            state = .idle
            return
        }
        guard let voice = capture else { return }
        watcher?.cancel()
        watcher = nil
        capture = nil
        unpin()
        state = .idle
        await voice.cancel()
    }

    /// OK on the stop notice or on a message.
    func dismiss() {
        switch state {
        case .stoppedByInput, .unavailable, .done: state = .idle
        default: break
        }
    }

    // MARK: Reading the capture

    /// The capture has no change signal, so a running one is read a few times a second.
    private func startWatching() {
        watcher?.cancel()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.pollInterval ?? .milliseconds(100))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    /// Takes over what the capture reports. A phase that ended it hands over to `conclude`.
    func refresh() {
        guard let voice = capture else { return }
        switch voice.phase {
        case .idle, .listening, .finishing:
            if case .listening(let shown) = state, shown != voice.liveText { state = .listening(voice.liveText) }
        case .finished, .stoppedByInput, .failed, .cancelled:
            conclude(voice)
        }
    }

    /// The capture ended on its own or through Stop: show its note, drop the capture and its session.
    private func conclude(_ voice: VoiceCapture) {
        guard capture === voice else { return }
        watcher?.cancel()
        watcher = nil
        capture = nil
        unpin()
        let isNew = target == .newNote
        switch voice.phase {
        case .finished(let noteId):
            if isNew { show(noteId) }
            state = .done
        case .stoppedByInput(let noteId):
            if isNew { show(noteId) }
            state = .stoppedByInput
        case .failed:
            // Locked meanwhile: nothing is kept. Any other failure keeps what was heard.
            if let noteId = voice.noteId, let note = (try? environment.store.note(id: noteId)) ?? nil, !note.isLocked {
                if isNew { show(noteId) }
                state = .unavailable(Self.interruptedMessage)
            } else if !(lockSeen && state == .idle) {
                // (A message already shown and dismissed is not shown again.)
                state = .unavailable(Self.noteLockedMessage)
            }
        case .cancelled, .idle, .listening, .finishing:
            state = .idle
        }
    }

    /// Shows a new note without recording an open: it is not read yet, and the Next Up card still
    /// offers it as captured (FOC-R3).
    private func show(_ noteId: String) {
        environment.suppressOpenRecord(noteId: noteId)
        if !openNote(noteId) { _ = environment.consumeOpenRecordSuppression(noteId) }
    }

    // MARK: A note locked under the panel

    /// Called when a note's lock state may have changed (a lock here, through sync, from the CLI). If the
    /// capture's note is locked now, its transcript leaves the panel at once instead of at the next read
    /// (FOC-R320). The capture stops itself through its lock guard (FOC-R199) and is released by `conclude`.
    private func noteLockStateMayHaveChanged() {
        guard let voice = capture, case .listening = state, let noteId = voice.noteId,
              let note = (try? environment.store.note(id: noteId)) ?? nil, note.isLocked else { return }
        lockSeen = true
        state = .unavailable(Self.noteLockedMessage)
    }

    // MARK: App Lock

    /// App Lock engaged: a pending question is answered No, a start in progress is abandoned and a
    /// running capture is cancelled, at once as far as the panel goes.
    private func appLockEngaged() {
        generation += 1
        isStarting = false
        isDownloading = false
        if let answer = modelAnswer {
            modelAnswer = nil
            answer.resume(returning: false)
        }
        state = .idle
        guard let voice = capture else { return }
        watcher?.cancel()
        watcher = nil
        capture = nil
        unpin()
        teardown = Task { await voice.cancel() }
    }

    // MARK: Session pin

    /// The capture's note counts as shown, so the environment keeps its session instead of evicting it
    /// (an editor opening the note meanwhile would otherwise make a second session for the same note).
    private func pin(_ noteId: String) {
        pinnedNoteId = noteId
        environment.setOpenNoteIds([noteId], for: ObjectIdentifier(self))
    }

    /// Released on every way out: Stop, Cancel, a failed start, App Lock, a lock.
    private func unpin() {
        guard pinnedNoteId != nil else { return }
        pinnedNoteId = nil
        environment.setOpenNoteIds([], for: ObjectIdentifier(self))
    }
}
