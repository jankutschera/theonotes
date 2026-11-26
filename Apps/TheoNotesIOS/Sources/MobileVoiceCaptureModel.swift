// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Observation
import TheoNotesCore
import TheoNotesVoice
import UIKit

/// Permission has already been checked by the model, which owns the scene-active barrier.
private struct AuthorizedVoicePreflight: VoicePreflighting {
    let base: any VoicePreflighting
    func requestMicrophone() async -> Bool { true }
    func availability(locale: Locale) async -> VoiceAvailability { await base.availability(locale: locale) }
    func downloadModel(locale: Locale) async throws { try await base.downloadModel(locale: locale) }
}

/// One instance per open library, shared by its scenes. The owner awaits privacy teardown
/// before locking/closing/switching the library and keeps library mutations disabled while busy.
@MainActor @Observable final class MobileVoiceCaptureModel {
    enum State: Equatable {
        case idle, preparing, needsModel(Locale), downloading, listening, finishing
        case finished, interrupted, permissionDenied, failed(String)
    }
    private(set) var state: State = .idle
    private(set) var transcript = ""
    private(set) var noteID: String?
    private(set) var isBusy = false
    private(set) var cancellationError: String?
    /// True only from this operation's microphone request through its active-scene handoff.
    /// No note/recorder exists in this window. It is NOT an exemption from explicit locking.
    private(set) var preservesInactiveMicrophoneRequest = false
    @ObservationIgnored private var sceneActive = true
    @ObservationIgnored private var permissionActivation: CheckedContinuation<Void, Never>?
    let library: MobileLibrary
    @ObservationIgnored private let engineFactory: () -> any VoiceEngine
    @ObservationIgnored private let preflight: any VoicePreflighting
    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var recordingStartedAt: Date?
    @ObservationIgnored private var pendingDestructiveCancellation = false
    @ObservationIgnored private var cancellationTask: Task<Bool, Never>?
    @ObservationIgnored private let privacyFence: @MainActor () throws -> Void
    @ObservationIgnored private let publishAfterMutation: @MainActor () -> Void
    @ObservationIgnored private var capture: VoiceCapture?
    private enum StartupStage: Equatable { case recovery, preflight, engine }
    @ObservationIgnored private var startupStage = StartupStage.recovery
    @ObservationIgnored private var startup: Task<Void, Never>?
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var suspensionTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryTask: Task<Void, any Error>?
    @ObservationIgnored private var backgroundPending = false
    @ObservationIgnored var beginBackgroundAssertion: (@escaping () -> Void) -> UIBackgroundTaskIdentifier = {
        UIApplication.shared.beginBackgroundTask(withName: "Save voice note", expirationHandler: $0)
    }
    @ObservationIgnored var endBackgroundAssertion: (UIBackgroundTaskIdentifier) -> Void = { UIApplication.shared.endBackgroundTask($0) }
    @ObservationIgnored private var backgroundAssertion = UIBackgroundTaskIdentifier.invalid
    @ObservationIgnored private var backgroundAssertionGeneration = 0
    @ObservationIgnored private var answer: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pinnedID: String?

    init(library: MobileLibrary, engineFactory: @escaping () -> any VoiceEngine = { LiveVoiceEngine() },
         preflight: any VoicePreflighting = LiveVoicePreflight(), locale: Locale = .current,
         now: @escaping @MainActor () -> Date = Date.init,
         privacyFence: (@MainActor () throws -> Void)? = nil,
         publishAfterMutation: (@MainActor () -> Void)? = nil) {
        self.privacyFence = privacyFence ?? { try library.clearSharePublication() }
        self.publishAfterMutation = publishAfterMutation ?? { library.publishRecentNotes() }
        self.library = library; self.engineFactory = engineFactory; self.preflight = preflight; self.locale = locale; self.now = now
    }

    isolated deinit {
        endVoiceBackgroundAssertion()
        watcher?.cancel()
        answer?.resume(returning: false)
        permissionActivation?.resume()
        if let pinnedID { library.store.retention.release(pinnedID) }
        // VoiceCapture's deinit tears down an abandoned live engine and its recording.
    }

    private var canCapture: Bool {
        !backgroundPending && !library.appLocked && !library.libraryOperationBusy && !library.isClosed && !library.isClosing
    }

    /// Recovery removed a leftover that could not be played.
    static let unreadableRemovedMessage = "A voice recording could not be read and was removed."

    /// Call after journal recovery, before starting any recorder. An error keeps recordings for retry.
    func recoverLeftovers() async throws {
        if let recoveryTask { return try await recoveryTask.value }
        guard canCapture, capture == nil else { throw CocoaError(.fileReadNoPermission) }
        let task = Task { @MainActor in
            try await library.withDrainedShareEditors {
                guard canCapture, capture == nil else { throw CocoaError(.fileReadNoPermission) }
                try library.flush()
                _ = try VoiceRecordingRecovery.adoptLeftovers(store: library.store,
                    attachments: AttachmentStore(paths: library.paths, database: library.database), directory: library.paths.recordings,
                    onUnreadableRemoved: { [library] _ in library.errorMessage = Self.unreadableRemovedMessage })
                try library.refreshSessions()
            }
        }
        recoveryTask = task
        do {
            try await task.value
            recoveryTask = nil
        } catch {
            recoveryTask = nil // A later foreground attempt can retry retained recordings.
            throw error
        }
    }

    func begin() async {
        guard !isBusy, cancellationTask == nil, canCapture, sceneActive else { return }
        generation += 1
        recordingStartedAt = nil; cancellationError = nil; startupStage = .recovery
        let run = generation
        isBusy = true; state = .preparing; transcript = ""; noteID = nil
        let task = Task { [weak self] in
            guard let self else { return }
            await self.start(run: run)
        }
        startup = task
        await task.value
        if generation == run { startup = nil; isBusy = capture != nil || cancellationTask != nil || suspensionTask != nil }
    }

    private func start(run: Int) async {
        do {
            try await recoverLeftovers()
            guard run == generation, canCapture, !Task.isCancelled else { return }
            startupStage = .preflight
            preservesInactiveMicrophoneRequest = true
            defer { if generation == run { preservesInactiveMicrophoneRequest = false } }
            let permission = await preflight.requestMicrophone()
            guard run == generation, canCapture, !Task.isCancelled else { return }
            guard permission else { state = .permissionDenied; return }
            if !sceneActive {
                await withCheckedContinuation { permissionActivation = $0 }
            }
            guard run == generation, canCapture, sceneActive, !Task.isCancelled else { return }
            preservesInactiveMicrophoneRequest = false
            let availability = try await VoicePreflight.check(locale: locale, using: AuthorizedVoicePreflight(base: preflight)) { @Sendable [weak self] locale in
                await self?.askAboutModel(locale, run: run) ?? false
            }
            guard run == generation, canCapture, !Task.isCancelled else { return }
            switch availability {
            case .microphoneDenied: state = .permissionDenied; return
            case .unsupportedLocale: state = .failed("Voice notes are not available for this language."); return
            case .unavailable: state = .failed("On-device voice transcription is not supported on this device."); return
            case .needsModelDownload: state = .idle; return
            case .ready: break
            }
            let voice = VoiceCapture(target: .newNote, store: library.store,
                attachments: AttachmentStore(paths: library.paths, database: library.database),
                session: { [weak self, library] id in
                    guard let self, self.generation == run, self.canCapture else { throw CancellationError() }
                    library.store.retention.retain(id); self.pinnedID = id
                    self.noteID = id
                    return try library.session(for: id)
                }, engine: engineFactory(), recordingsDirectory: library.paths.recordings)
            startupStage = .engine
            try await voice.start()
            guard run == generation, canCapture, !Task.isCancelled else {
                if pendingDestructiveCancellation {
                    // Hand ownership back to the cancelling host. It must fence again AFTER
                    // this await before Core may trash/delete anything. A failed fence retains it.
                    capture = voice; recordingStartedAt = now(); isBusy = true
                    return
                }
                // Implicit startup interruption preserves bytes; only explicit host Cancel discards.
                _ = try? await voice.stop()
                unpin(); return
            }
            capture = voice; recordingStartedAt = now(); state = .listening
            startWatcher()
        } catch {
            guard generation == run else { return }
            unpin() // An abandoned preflight must never release a newer capture's retention.
            transcript = ""
            state = .failed("Voice capture could not start. Any recoverable recording has been kept. Try again.")
        }
    }

    private func startWatcher() {
        watcher?.cancel()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    private func askAboutModel(_ locale: Locale, run: Int) async -> Bool {
        guard generation == run, canCapture, !Task.isCancelled else { return false }
        state = .needsModel(locale)
        return await withCheckedContinuation { answer = $0 }
    }

    func answerModelDownload(_ download: Bool) {
        guard let answer else { return }
        self.answer = nil
        state = download ? .downloading : .idle
        answer.resume(returning: download)
    }

    /// Stop keeps final text and the recording. Interruption/input-change use the same Core path.
    func stop() async {
        if let stopTask { await stopTask.value; return }
        guard let voice = capture else { return }
        guard voice.phase == .listening || voice.phase == .finishing else { conclude(voice); return }
        watcher?.cancel(); watcher = nil // Closing/locking must not race this preserving Stop with Cancel.
        state = .finishing
        let task = Task { @MainActor [weak self] in
            do { _ = try await voice.stop() }
            catch { self?.library.errorMessage = "The voice note did not finish saving. Check the note and try again." }
            self?.conclude(voice)
            self?.stopTask = nil
        }
        stopTask = task
        await task.value
    }

    /// Cancel hides words immediately; teardown completes before the caller may close the database.
    @discardableResult
    func cancel(keepStartedRecording: Bool = false) async -> Bool {
        if let cancellationTask { return await cancellationTask.value }
        let task = Task { @MainActor in await performCancel(keepStartedRecording: keepStartedRecording) }
        cancellationTask = task
        let result = await task.value
        cancellationTask = nil
        isBusy = capture != nil || startup != nil || stopTask != nil || suspensionTask != nil
        return result
    }

    private func performCancel(keepStartedRecording: Bool) async -> Bool {
        let originalCapture = capture
        let engineStartBegan = startupStage == .engine
        // Preflight owns no note, recording or pending DB work. A platform model download may
        // ignore cancellation; detach that wait after fencing its generation, not the whole UI.
        let abandonPreflightWait = startup != nil && startupStage == .preflight && capture == nil
        let destructive = !keepStartedRecording && (capture != nil || (startup != nil && engineStartBegan))
        if destructive {
            do { try privacyFence() }
            catch { reportCancellationFailure(); return false } // Nothing changed: continue recording.
        }
        defer { if destructive { publishAfterMutation() } }
        pendingDestructiveCancellation = destructive
        defer { pendingDestructiveCancellation = false }
        generation += 1
        preservesInactiveMicrophoneRequest = false
        let activation = permissionActivation; permissionActivation = nil; activation?.resume()
        watcher?.cancel(); watcher = nil
        transcript = ""; state = destructive ? .finishing : .idle
        if let answer { self.answer = nil; answer.resume(returning: false) }
        let starting = startup
        // Cancel permission/model work promptly, but keep awaiting database recovery and any
        // begun engine start: those can own DB access or files that require fenced teardown.
        if keepStartedRecording || !engineStartBegan { starting?.cancel() }
        if !abandonPreflightWait { await starting?.value }
        // A late preflight result only reaches the run/generation guard before engine creation.
        startup = nil
        _ = try? await recoveryTask?.value
        if let stopTask { await stopTask.value }
        if let voice = capture {
            guard originalCapture == nil || originalCapture === voice else {
                reportCancellationFailure()
                return false // Never stop/discard or unpin a replacement capture.
            }
            if keepStartedRecording {
                await stop()
            } else {
                do { try privacyFence() }
                catch {
                    isBusy = true
                    state = voice.phase == .finishing ? .finishing : .listening
                    transcript = canCapture ? voice.liveText : ""
                    startWatcher()
                    reportCancellationFailure()
                    return false
                }
                await voice.cancel()
                guard capture == nil || capture === voice else {
                    reportCancellationFailure()
                    return false
                }
                if capture === voice { capture = nil }
            }
        }
        cancellationError = nil; state = .idle
        unpin(); isBusy = suspensionTask != nil || cancellationTask != nil
        return true
    }

    private func reportCancellationFailure() {
        cancellationError = "The recording was kept because shared note data could not be cleared. Try again, or use Stop Recording to save it."
        library.errorMessage = cancellationError
    }
    func clearCancellationError() {
        if library.errorMessage == cancellationError { library.errorMessage = nil }
        cancellationError = nil
    }

    /// Inactive permission alerts preserve only preflight. Real background always tears down.
    /// The view still covers app-switcher snapshots; audio cannot start until active again.
    func updateSceneActivity(active: Bool, background: Bool) {
        sceneActive = active
        if active {
            let activation = permissionActivation; permissionActivation = nil; activation?.resume()
            retryRecoveryAfterActivation()
        } else if isBusy && (background || !preservesInactiveMicrophoneRequest) {
            prepareForBackground()
            Task { await suspendForBackground() }
        }
    }

    /// Synchronous privacy boundary, called before the app-lock flag or scene state changes.
    func prepareForBackground() {
        if isBusy && backgroundAssertion == .invalid {
            backgroundAssertionGeneration += 1
            let generation = backgroundAssertionGeneration
            backgroundAssertion = beginBackgroundAssertion { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.backgroundAssertionGeneration == generation else { return }
                    self.endVoiceBackgroundAssertion()
                }
            }
        }
        preservesInactiveMicrophoneRequest = false
        let activation = permissionActivation; permissionActivation = nil; activation?.resume()
        backgroundPending = true
        isBusy = true
        transcript = ""
        watcher?.cancel(); watcher = nil
        if let answer { self.answer = nil; answer.resume(returning: false) }
    }

    /// Scene, lock and close share one teardown. Preflight is abandoned; live audio is kept.
    func suspendForBackground() async {
        if let suspensionTask { await suspensionTask.value; return }
        prepareForBackground()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            if self.capture != nil { await self.stop() }
            else { await self.cancel(keepStartedRecording: true) }
            // The cancel above may have joined an explicit destructive cancel that was waiting
            // for engine startup. A failed late privacy fence hands a live capture back to us.
            // Keep the privacy barrier set until that recorder has actually finished preserving.
            if self.capture != nil { await self.stop() }
            _ = try? await self.recoveryTask?.value
            self.backgroundPending = false
            self.suspensionTask = nil
            self.isBusy = self.capture != nil || self.startup != nil || self.cancellationTask != nil
            self.endVoiceBackgroundAssertion()
            self.retryRecoveryAfterActivation()
        }
        suspensionTask = task
        await task.value
    }

    /// Only an explicit user cancellation discards a recording. Sheet/lifecycle loss keeps it.
    func finishForDismissal() async { await suspendForBackground() }
    func invalidateForPrivacy() async { await suspendForBackground() }

    private func endVoiceBackgroundAssertion() {
        guard backgroundAssertion != .invalid else { return }
        let assertion = backgroundAssertion
        backgroundAssertion = .invalid
        backgroundAssertionGeneration += 1
        endBackgroundAssertion(assertion)
    }

    func retryRecoveryAfterActivation() {
        guard sceneActive, canCapture, !isBusy, capture == nil,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: library.paths.recordings.path), !entries.isEmpty else { return }
        Task { @MainActor [weak self] in try? await self?.recoverLeftovers() }
    }

    var requiresCancelConfirmation: Bool {
        guard capture != nil, let recordingStartedAt else { return false }
        return now().timeIntervalSince(recordingStartedAt) >= 10
    }

    func refresh() {
        guard let voice = capture else { return }
        guard !backgroundPending, stopTask == nil else { return }
        guard canCapture else {
            transcript = ""
            watcher?.cancel(); watcher = nil
            Task { await invalidateForPrivacy() }
            return
        }
        if let id = voice.noteId, (try? library.store.note(id: id))?.isLocked == true {
            transcript = "" // Core lock guard handles engine teardown; never display old words.
        } else { transcript = voice.liveText }
        switch voice.phase {
        case .idle, .listening, .finishing: break
        default: conclude(voice)
        }
    }

    private func conclude(_ voice: VoiceCapture) {
        guard capture === voice else { return }
        watcher?.cancel(); watcher = nil
        capture = nil; unpin(); isBusy = suspensionTask != nil || cancellationTask != nil
        switch voice.phase {
        case .finished(let id), .stoppedByInput(let id):
            guard canCapture, let note = try? library.store.note(id: id), !note.isLocked else {
                transcript = ""; state = .idle; return
            }
            transcript = voice.liveText
            state = voice.phase == .finished(noteId: id) ? .finished : .interrupted
            if canCapture { try? library.reveal(id) }
        case .failed:
            guard canCapture else {
                transcript = ""; state = .idle; return
            }
            let readable = voice.noteId.flatMap { try? library.store.note(id: $0) }.map { !$0.isLocked } ?? false
            transcript = readable ? voice.liveText : ""
            state = .failed(readable ? "Recording ended unexpectedly. Recoverable text and audio have been kept." : "The note was locked. The recording was discarded.")
        default: transcript = ""; state = .idle
        }
    }

    private func unpin() {
        if let pinnedID { library.store.retention.release(pinnedID) }
        pinnedID = nil
    }
}
