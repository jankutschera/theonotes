// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import AVFoundation
import UIKit
import GRDB
import Testing
import TheoNotesCore
import TheoNotesVoice
@testable import BaerchenIOS

private actor MobileVoiceTestEngine: VoiceEngine {
    nonisolated func isRecordingReadable(at url: URL) -> Bool { ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 }
    private var output: AsyncThrowingStream<VoiceEvent, any Error>.Continuation?
    private(set) var starts = 0
    private(set) var finishes = 0
    private(set) var cancels = 0
    private var finishGate: AsyncStream<Void>?
    private var startGate: AsyncStream<Void>?
    private(set) var recordingURL: URL?
    private let audio: Data
    init(audio: Data = Data("fixture-audio".utf8)) { self.audio = audio }
    func start(recordingTo url: URL) async throws -> AsyncThrowingStream<VoiceEvent, any Error> {
        starts += 1; recordingURL = url
        try audio.write(to: url)
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: VoiceEvent.self)
        output = continuation
        if let startGate { for await _ in startGate { break } }
        return stream
    }
    func holdStart() -> AsyncStream<Void>.Continuation {
        let (gate, release) = AsyncStream.makeStream(of: Void.self)
        startGate = gate; return release
    }
    func holdFinish() -> AsyncStream<Void>.Continuation {
        let (gate, release) = AsyncStream.makeStream(of: Void.self)
        finishGate = gate; return release
    }
    func finish() async throws {
        finishes += 1
        if let finishGate { for await _ in finishGate { break } }
        output?.finish()
    }
    func cancel() async { cancels += 1; output?.finish() }
    func send(_ event: VoiceEvent) { output?.yield(event) }
    func fail() { output?.finish(throwing: CocoaError(.fileReadUnknown)) }
}

private actor MobileVoiceTestPreflight: VoicePreflighting {
    let allowed: Bool
    var missing: Bool
    private(set) var downloads = 0
    init(allowed: Bool = true, missing: Bool = false) { self.allowed = allowed; self.missing = missing }
    func requestMicrophone() async -> Bool { allowed }
    func availability(locale: Locale) async -> VoiceAvailability { missing ? .needsModelDownload(locale) : .ready }
    func downloadModel(locale: Locale) async throws { downloads += 1; missing = false }
}

private actor HeldMicrophonePreflight: VoicePreflighting {
    private var answer: CheckedContinuation<Bool, Never>?
    var waiting: Bool { answer != nil }
    func requestMicrophone() async -> Bool { await withCheckedContinuation { answer = $0 } }
    func respond(_ allowed: Bool) { let current = answer; answer = nil; current?.resume(returning: allowed) }
    func availability(locale: Locale) async -> VoiceAvailability { .ready }
    func downloadModel(locale: Locale) async throws {}
}

/// The non-cooperative variant models an OS asset download which only returns after its
/// own completion, even if its calling Task was cancelled. Tests always release both fakes.
private actor HeldModelDownloadPreflight: VoicePreflighting {
    let cooperative: Bool
    private(set) var started = false
    private(set) var cancellationObserved = false
    private var installed = false
    private var releaseStream: AsyncStream<Void>.Continuation?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    init(cooperative: Bool) { self.cooperative = cooperative }
    func requestMicrophone() async -> Bool { true }
    func availability(locale: Locale) async -> VoiceAvailability { installed ? .ready : .needsModelDownload(locale) }
    func downloadModel(locale: Locale) async throws {
        started = true
        if cooperative {
            let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
            releaseStream = continuation
            for await _ in stream { break }
            cancellationObserved = Task.isCancelled
            try Task.checkCancellation()
        } else {
            await withCheckedContinuation { releaseContinuation = $0 }
            cancellationObserved = Task.isCancelled
        }
        installed = true
    }
    func release() {
        releaseStream?.finish(); releaseStream = nil
        let continuation = releaseContinuation; releaseContinuation = nil; continuation?.resume()
    }
}

@Suite(.serialized) @MainActor
struct MobileVoiceCaptureTests {
    @Test func inactiveThenActiveWithoutBackgroundFinishesProvisionalVoiceAndAudio() async throws {
        let library = try library(); defer { cleanup(library) }
        let engine = MobileVoiceTestEngine()
        let model = MobileVoiceCaptureModel(library: library, engineFactory: { engine }, preflight: MobileVoiceTestPreflight())
        await model.begin()
        let id = try #require(model.noteID)
        await engine.send(.transcript(TranscriptUpdate(text: "Provisional words", isFinal: false)))
        try await wait("provisional transcript") { model.refresh(); return model.transcript == "Provisional words" }
        let release = await engine.holdFinish()
        defer { release.finish() }
        model.updateSceneActivity(active: false, background: false)
        model.updateSceneActivity(active: true, background: false)
        try await wait("preserving stop") { model.state == .finishing }
        #expect(model.isBusy)
        #expect(await engine.finishes == 1)
        release.finish()
        try await wait("capture finished") { !model.isBusy }
        let note = try #require(try library.store.note(id: id))
        #expect(note.text.contains("Provisional words"))
        #expect(NoteParser.attachmentLinks(in: note.text).count == 1)
    }
    private func writePlayableAudio(to url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
        buffer.frameLength = 4_410
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1])
        try file.write(from: buffer)
        file.close()
    }

    @Test func activationRecoversPlayableRecordingOnlyAfterUnlock() async throws {
        let library = try library(); defer { cleanup(library) }
        let note = try library.store.create(text: "Recovered words", captureSource: .voice)
        let directory = library.paths.recordings.appendingPathComponent(note.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("Recovered.m4a")
        try writePlayableAudio(to: file)
        let model = MobileVoiceCaptureModel(library: library)
        library.enableAppLockForTesting(); library.lockApplication()
        model.updateSceneActivity(active: true, background: false)
        for _ in 0..<10 { await Task.yield() }
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try library.store.note(id: note.id)?.text == "Recovered words")
        library.unlockAppForTesting()
        model.updateSceneActivity(active: true, background: false)
        try await wait("recording recovered") { (try? library.store.note(id: note.id)?.text.contains("Recovered.m4a")) == true }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
    /// 1.1 A2 (d), an unplayable leftover is never removed in the launch that marked it;
    /// one marked by an earlier launch a day ago is removed and the user is told once.
    @Test func anUnplayableLeftoverGoesOnlyInALaterLaunchAndTheUserIsToldOnce() async throws {
        let library = try library(); defer { cleanup(library) }
        let note = try library.store.create(text: "Memo", captureSource: .voice)
        let directory = library.paths.recordings.appendingPathComponent(note.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("Broken.m4a")
        try Data("not audio".utf8).write(to: file)
        let model = MobileVoiceCaptureModel(library: library)
        try await model.recoverLeftovers()
        try await model.recoverLeftovers()
        #expect(FileManager.default.fileExists(atPath: file.path), "never in the launch that marked it")
        #expect(library.errorMessage == nil)
        VoiceRecordingRecovery.mark(file, wordsInserted: false, at: Date().addingTimeInterval(-2 * 86_400), launch: "earlier")
        try await model.recoverLeftovers()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(library.errorMessage == "A voice recording could not be read and was removed.")
        library.errorMessage = nil
        try await model.recoverLeftovers()
        #expect(library.errorMessage == nil)
        #expect(try library.store.note(id: note.id)?.text == "Memo")
    }
    /// Unfinished words are journaled but not stored; after the app is killed, the next
    /// launch replays the journal and they are back.
    @Test func unfinishedWordsSurviveAKilledApp() async throws {
        let library = try library(); defer { cleanup(library) }
        let engine = MobileVoiceTestEngine()
        let model = MobileVoiceCaptureModel(library: library, engineFactory: { engine }, preflight: MobileVoiceTestPreflight())
        await model.begin()
        let id = try #require(model.noteID)
        await engine.send(.transcript(TranscriptUpdate(text: "Buy milk.", isFinal: true)))
        await engine.send(.transcript(TranscriptUpdate(text: "and bread", isFinal: false)))
        try await wait("provisional transcript") { model.refresh(); return model.transcript == "Buy milk. and bread" }
        try library.flush()
        #expect(try library.store.note(id: id)?.text == "Buy milk.")
        // A second library on the same folder stands in for the next launch after a kill.
        let relaunched = try MobileLibrary(paths: library.paths)
        #expect(try relaunched.store.note(id: id)?.text == "Buy milk. and bread")
        _ = await model.cancel(keepStartedRecording: true)
        try? relaunched.close()
    }
    /// 1.1 A2 (c), no words and nothing that plays: nothing is kept and no error shows.
    @Test func stopWithNoWordsAndNoUsableAudioKeepsNothing() async throws {
        let library = try library(); defer { cleanup(library) }
        let engine = MobileVoiceTestEngine(audio: Data())
        let model = MobileVoiceCaptureModel(library: library, engineFactory: { engine }, preflight: MobileVoiceTestPreflight())
        await model.begin()
        let id = try #require(model.noteID)
        await model.stop()
        #expect(model.state == .idle)
        #expect(library.errorMessage == nil)
        #expect(try library.store.note(id: id)?.location == .trash)
        #expect(!FileManager.default.fileExists(atPath: library.paths.recordings.appendingPathComponent(id).path))
    }
    @Test func backgroundAssertionEndsOnlyAfterTextAndAudioAreCommitted() async throws {
        let library = try library(); defer { cleanup(library) }
        let engine = MobileVoiceTestEngine()
        let model = MobileVoiceCaptureModel(library: library, engineFactory: { engine }, preflight: MobileVoiceTestPreflight())
        var begins = 0, ends = 0, savedWhenEnded = false
        var noteID: String?
        model.beginBackgroundAssertion = { _ in begins += 1; return UIBackgroundTaskIdentifier(rawValue: 71) }
        model.endBackgroundAssertion = { _ in
            ends += 1
            if let noteID, let note = try? library.store.note(id: noteID) {
                savedWhenEnded = note.text.contains("Interrupted words") && NoteParser.attachmentLinks(in: note.text).count == 1
            }
        }
        await model.begin()
        let id = try #require(model.noteID)
        noteID = id
        await engine.send(.transcript(TranscriptUpdate(text: "Interrupted words", isFinal: false)))
        try await wait("provisional transcript") { model.refresh(); return model.transcript == "Interrupted words" }
        let release = await engine.holdFinish()
        model.prepareForBackground(); model.prepareForBackground()
        let stopping = Task { await model.suspendForBackground() }
        try await wait("stop entered") { model.state == .finishing }
        #expect(begins == 1 && ends == 0)
        release.finish()
        await stopping.value
        let note = try #require(try library.store.note(id: id))
        #expect(note.text.contains("Interrupted words") && NoteParser.attachmentLinks(in: note.text).count == 1)
        #expect(ends == 1 && savedWhenEnded)
    }
    private func library() throws -> MobileLibrary {
        try MobileLibrary(paths: AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    }
    private func cleanup(_ library: MobileLibrary) {
        try? library.close(); try? FileManager.default.removeItem(at: library.paths.root)
    }
    private func wait(_ stage: String, _ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Voice stage timed out: \(stage)")
        throw CocoaError(.coderReadCorrupt)
    }

    @Test func successfulCloseReleasesLibraryOwnedVoiceModelAndLibrary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        weak var releasedLibrary: MobileLibrary?
        weak var releasedModel: MobileVoiceCaptureModel?
        @MainActor func openAndClose() throws {
            let library = try MobileLibrary(paths: AppPaths(root: root))
            releasedLibrary = library
            releasedModel = library.voiceCapture // Actual library-owned model; no recorder/preflight starts.
            #expect(releasedModel != nil)
            try library.close()
            #expect(library.isClosed)
        }
        try openAndClose()
        #expect(releasedModel == nil)
        #expect(releasedLibrary == nil)
    }

    @Test(arguments: ["stop", "interrupted", "inputChanged", "cancel", "privacy"])
    func captureFinalTextAudioAndCancellation(ending: String) async throws {
        let library = try library(); defer { cleanup(library) }
        let engine = MobileVoiceTestEngine()
        let model = MobileVoiceCaptureModel(library: library, engineFactory: { engine }, preflight: MobileVoiceTestPreflight())
        await model.begin()
        let id = try #require(model.noteID)
        await engine.send(.transcript(TranscriptUpdate(text: "Fixture words", isFinal: true)))
        try await wait("journaled final transcript") { model.refresh(); return model.transcript == "Fixture words" }
        switch ending {
        case "cancel": await model.cancel()
        case "privacy": await model.invalidateForPrivacy()
        case "interrupted": await engine.send(.interrupted)
        case "inputChanged": await engine.send(.inputChanged)
        default: await model.stop()
        }
        try await wait("capture ended") { model.refresh(); return !model.isBusy }
        let note = try #require(try library.store.note(id: id))
        if ending == "cancel" {
            #expect(note.location == .trash)
            #expect(model.transcript.isEmpty)
            #expect((try? FileManager.default.contentsOfDirectory(atPath: library.paths.attachments.appendingPathComponent(id).path))?.isEmpty ?? true)
        } else {
            #expect(note.text.contains("Fixture words"))
            let links = NoteParser.attachmentLinks(in: note.text)
            #expect(links.count == 1)
            let link = try #require(links.first)
            let url = try #require(try library.attachmentURL(link.filename, noteID: id))
            #expect(try Data(contentsOf: url) == Data("fixture-audio".utf8))
            #expect(model.state == (ending == "privacy" ? .idle : ending == "stop" ? .finished : .interrupted))
            if ending == "privacy" { #expect(model.transcript.isEmpty) }
        }
    }

    @Test func deniedPermissionDoesNotCreateNoteOrStartEngine() async throws {
        let library = try library(); defer { cleanup(library) }
        let before = try await library.database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note") }
        let engine = MobileVoiceTestEngine()
        let model = MobileVoiceCaptureModel(library: library, engineFactory: { engine }, preflight: MobileVoiceTestPreflight(allowed: false))
        await model.begin()
        #expect(model.state == .permissionDenied)
        #expect(await engine.starts == 0)
        #expect(try await library.database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note") } == before)
    }

    @Test(arguments: [false, true])
    func modelDownloadRequiresExplicitConsent(download: Bool) async throws {
        let library = try library(); defer { cleanup(library) }
        let engine = MobileVoiceTestEngine(), preflight = MobileVoiceTestPreflight(missing: true)
        let model = MobileVoiceCaptureModel(library: library, engineFactory: { engine }, preflight: preflight)
        let start = Task { await model.begin() }
        try await wait("model consent") { if case .needsModel = model.state { return true }; return false }
        model.answerModelDownload(download)
        await start.value
        #expect(await preflight.downloads == (download ? 1 : 0))
        #expect(await engine.starts == (download ? 1 : 0))
        await model.cancel()
    }

    @Test func failureKeepsHeardTextAndAudio() async throws {
        let library = try library(); defer { cleanup(library) }
        let engine = MobileVoiceTestEngine()
        let model = MobileVoiceCaptureModel(library: library, engineFactory: { engine }, preflight: MobileVoiceTestPreflight())
        await model.begin()
        let id = try #require(model.noteID)
        await engine.send(.transcript(TranscriptUpdate(text: "Retained words", isFinal: true)))
        try await wait("heard before engine failure") { model.refresh(); return model.transcript == "Retained words" }
        await engine.fail()
        try await wait("failed engine teardown") { model.refresh(); return !model.isBusy }
        guard case .failed = model.state else { Issue.record("Engine failure must be visible"); return }
        let note = try #require(try library.store.note(id: id))
        #expect(note.text.contains("Retained words"))
        #expect(NoteParser.attachmentLinks(in: note.text).count == 1)
    }

    @Test func privacyCancellationDismissesModelConsentWithoutStartingEngine() async throws {
        let library = try library(); defer { cleanup(library) }
        let engine = MobileVoiceTestEngine(), preflight = MobileVoiceTestPreflight(missing: true)
        let model = MobileVoiceCaptureModel(library: library, engineFactory: { engine }, preflight: preflight)
        let start = Task { await model.begin() }
        try await wait("consent before privacy cancellation") { if case .needsModel = model.state { return true }; return false }
        await model.invalidateForPrivacy()
        await start.value
        #expect(!model.isBusy)
        #expect(model.state == .idle)
        #expect(model.transcript.isEmpty)
        #expect(await engine.starts == 0)
        #expect(await preflight.downloads == 0)
    }

    @Test func backgroundSuspensionCancelsPendingConsentAndStopsLiveRecording() async throws {
        let library = try library(); defer { cleanup(library) }
        let pendingEngine = MobileVoiceTestEngine()
        let pending = MobileVoiceCaptureModel(library: library, engineFactory: { pendingEngine }, preflight: MobileVoiceTestPreflight(missing: true))
        let start = Task { await pending.begin() }
        try await wait("model consent before background") { if case .needsModel = pending.state { return true }; return false }
        await pending.suspendForBackground()
        await start.value
        #expect(!pending.isBusy)
        #expect(await pendingEngine.starts == 0)
        let engine = MobileVoiceTestEngine()
        let active = MobileVoiceCaptureModel(library: library, engineFactory: { engine }, preflight: MobileVoiceTestPreflight())
        await active.begin()
        let id = try #require(active.noteID)
        await engine.send(.transcript(TranscriptUpdate(text: "Background keeps words", isFinal: true)))
        try await wait("words before background") { active.refresh(); return active.transcript == "Background keeps words" }
        let selectedBeforeBackground = library.selectedID
        await active.suspendForBackground()
        #expect(!active.isBusy)
        // The recording is saved, but a privacy suspension must not restore its words or
        // navigate to the note. conclude() deliberately returns the presentation to idle.
        #expect(active.state == .idle)
        #expect(active.transcript.isEmpty)
        #expect(library.selectedID == selectedBeforeBackground)
        let note = try #require(try library.store.note(id: id))
        #expect(note.text.contains("Background keeps words"))
        #expect(NoteParser.attachmentLinks(in: note.text).count == 1)
    }

    @Test(arguments: [false, true])
    func failedBackgroundStopKeepsTextAndAudioWithoutRestoringPrivatePresentation(lockApp: Bool) async throws {
        let library = try library(); defer { cleanup(library) }
        if lockApp { try await library.setAppLock(true, authenticate: {}) }
        let engine = MobileVoiceTestEngine()
        let model = MobileVoiceCaptureModel(library: library, engineFactory: { engine }, preflight: MobileVoiceTestPreflight())
        await model.begin()
        let id = try #require(model.noteID)
        await engine.send(.transcript(TranscriptUpdate(text: "Keep failed-stop fixture words", isFinal: true)))
        try await wait("words before failing private stop") {
            model.refresh(); return model.transcript == "Keep failed-stop fixture words"
        }
        let selection = library.selectedID
        let release = await engine.holdFinish()
        defer { release.finish() }
        model.prepareForBackground()
        if lockApp { library.lockApplication() }
        #expect(model.transcript.isEmpty)
        let stopping = Task { await model.suspendForBackground() }
        try await wait("preserving stop before stream failure") { model.state == .finishing }
        await engine.fail()
        release.finish()
        await stopping.value
        #expect(!model.isBusy && model.state == .idle)
        #expect(library.errorMessage == "The voice note did not finish saving. Check the note and try again.")
        #expect(model.transcript.isEmpty)
        #expect(library.selectedID == selection)
        let note = try #require(try library.store.note(id: id))
        #expect(note.text.contains("Keep failed-stop fixture words"))
        let links = NoteParser.attachmentLinks(in: note.text)
        #expect(links.count == 1)
        let link = try #require(links.first)
        // Inspect the Core store directly: the app's locked attachment resolver must stay gated.
        let file = library.paths.attachments.appendingPathComponent(id).appendingPathComponent(link.filename)
        #expect(try Data(contentsOf: file) == Data("fixture-audio".utf8))
    }

    @Test func synchronousPrivacyHideAndInFlightStopPreserveRecording() async throws {
        let library = try library(); defer { cleanup(library) }
        let engine = MobileVoiceTestEngine()
        let model = MobileVoiceCaptureModel(library: library, engineFactory: { engine }, preflight: MobileVoiceTestPreflight())
        await model.begin()
        let id = try #require(model.noteID)
        await engine.send(.transcript(TranscriptUpdate(text: "Keep on lock", isFinal: true)))
        try await wait("words before lock") { model.refresh(); return model.transcript == "Keep on lock" }
        let release = await engine.holdFinish()
        defer { release.finish() }
        model.prepareForBackground()
        #expect(model.transcript.isEmpty) // Before any await or the lock flag changes.
        #expect(model.isBusy)
        library.enableAppLockForTesting()
        library.lockApplication()
        let stopping = Task { await model.suspendForBackground() }
        let secondStop = Task { await model.suspendForBackground() }
        let thirdStop = Task { await model.suspendForBackground() }
        try await wait("stop started under lock") { model.state == .finishing }
        for _ in 0..<30 { await Task.yield() }
        model.refresh() // A late/manual refresh must not turn a preserving stop into Cancel.
        #expect(model.isBusy)
        #expect(model.transcript.isEmpty)
        #expect(await engine.cancels == 0)
        release.finish()
        await stopping.value
        await secondStop.value
        await thirdStop.value
        #expect(!model.isBusy)
        #expect(await engine.finishes == 1)
        #expect(await engine.cancels == 0)
        let note = try #require(try library.store.note(id: id))
        #expect(note.text.contains("Keep on lock"))
        #expect(NoteParser.attachmentLinks(in: note.text).count == 1)
    }

    @Test func concurrentRecoveryCallersAdoptExactlyOnce() async throws {
        let library = try library(); defer { cleanup(library) }
        let note = try library.store.create(text: "Concurrent recovery", captureSource: .voice)
        let directory = library.paths.recordings.appendingPathComponent(note.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writePlayableAudio(to: directory.appendingPathComponent("Recovered.m4a"))
        let model = MobileVoiceCaptureModel(library: library)
        async let first: Void = model.recoverLeftovers()
        async let second: Void = model.recoverLeftovers()
        _ = try await (first, second)
        let recovered = try #require(try library.store.note(id: note.id))
        #expect(NoteParser.attachmentLinks(in: recovered.text).count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.paths.attachments.appendingPathComponent(note.id).path).count == 1)
    }

    @Test func recoveryAdoptsRecordingOnceBeforeCapture() async throws {
        let library = try library(); defer { cleanup(library) }
        let note = try library.store.create(text: "Recovered words", captureSource: .voice)
        let directory = library.paths.recordings.appendingPathComponent(note.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writePlayableAudio(to: directory.appendingPathComponent("Recovered.m4a"))
        let model = MobileVoiceCaptureModel(library: library, engineFactory: { MobileVoiceTestEngine() }, preflight: MobileVoiceTestPreflight())
        try await model.recoverLeftovers()
        try await model.recoverLeftovers()
        let recovered = try #require(try library.store.note(id: note.id))
        #expect(NoteParser.attachmentLinks(in: recovered.text).count == 1)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
    private func waitForPermission(_ preflight: HeldMicrophonePreflight) async throws {
        for _ in 0..<400 {
            if await preflight.waiting { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CocoaError(.fileReadUnknown)
    }

    @Test func microphoneConsentSurvivesInactiveButRecordingWaitsUntilActive() async throws {
        let library = try library(); defer { cleanup(library) }
        let preflight = HeldMicrophonePreflight(), engine = MobileVoiceTestEngine()
        let model = MobileVoiceCaptureModel(library: library, engineFactory: { engine }, preflight: preflight)
        let starting = Task { await model.begin() }
        await Task.yield()
        try await waitForPermission(preflight)
        #expect(model.preservesInactiveMicrophoneRequest)
        model.updateSceneActivity(active: false, background: false)
        await preflight.respond(true)
        for _ in 0..<20 { await Task.yield() }
        #expect(model.preservesInactiveMicrophoneRequest)
        #expect(await engine.starts == 0)
        #expect(try library.store.allNotes().isEmpty)
        model.updateSceneActivity(active: true, background: false)
        await starting.value
        #expect(!model.preservesInactiveMicrophoneRequest)
        #expect(await engine.starts == 1)
        await model.cancel()
    }

    @Test(arguments: ["background", "lock", "deny"])
    func pendingMicrophoneCannotStartAfterPrivacyBoundaryOrDenial(boundary: String) async throws {
        let library = try library(); defer { cleanup(library) }
        if boundary == "lock" { try await library.setAppLock(true, authenticate: {}) }
        let preflight = HeldMicrophonePreflight(), engine = MobileVoiceTestEngine()
        let model = MobileVoiceCaptureModel(library: library, engineFactory: { engine }, preflight: preflight)
        let starting = Task { await model.begin() }
        try await waitForPermission(preflight)
        model.updateSceneActivity(active: false, background: false)
        if boundary == "background" { model.updateSceneActivity(active: false, background: true) }
        if boundary == "lock" { library.lockApplication() }
        await preflight.respond(boundary != "deny")
        await starting.value
        if boundary == "background" { await model.suspendForBackground() }
        model.updateSceneActivity(active: true, background: false)
        #expect(await engine.starts == 0)
        #expect(try library.store.allNotes().isEmpty)
        #expect(model.transcript.isEmpty)
        if boundary == "deny" { #expect(model.state == .permissionDenied) }
        await model.cancel()
    }

    @Test(arguments: ["dismiss", "refreshAccessLoss"])
    func involuntaryDismissalAndRefreshAccessLossKeepTextAndAudio(ending: String) async throws {
        let library = try library(); defer { cleanup(library) }
        if ending == "refreshAccessLoss" { try await library.setAppLock(true, authenticate: {}) }
        let engine = MobileVoiceTestEngine()
        let model = MobileVoiceCaptureModel(library: library, engineFactory: { engine }, preflight: MobileVoiceTestPreflight())
        await model.begin()
        let id = try #require(model.noteID)
        await engine.send(.transcript(TranscriptUpdate(text: "Keep involuntary dismissal", isFinal: true)))
        try await wait("words before involuntary end") { model.refresh(); return model.transcript == "Keep involuntary dismissal" }
        let selection = library.selectedID
        if ending == "dismiss" { await model.finishForDismissal() }
        else {
            library.lockApplication()
            model.refresh()
            #expect(model.transcript.isEmpty)
            try await wait("access-loss preserving stop") { !model.isBusy }
        }
        #expect(model.transcript.isEmpty)
        #expect(library.selectedID == selection)
        #expect(await engine.finishes == 1)
        #expect(await engine.cancels == 0)
        let note = try #require(try library.store.note(id: id))
        #expect(note.location == .notes)
        #expect(note.text.contains("Keep involuntary dismissal"))
        let link = try #require(NoteParser.attachmentLinks(in: note.text).first)
        let file = library.paths.attachments.appendingPathComponent(id).appendingPathComponent(link.filename)
        #expect(try Data(contentsOf: file) == Data("fixture-audio".utf8))
        // Duplicate parent dismissal must not cancel/delete the already-saved recording.
        await model.finishForDismissal()
        #expect(try Data(contentsOf: file) == Data("fixture-audio".utf8))
    }

    @Test func destructiveCancelNeedsConfirmationAfterTenSecondsOnlyWhileRecordingExists() async throws {
        let library = try library(); defer { cleanup(library) }
        let engine = MobileVoiceTestEngine()
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let model = MobileVoiceCaptureModel(library: library, engineFactory: { engine }, preflight: MobileVoiceTestPreflight(), now: { clock })
        #expect(!model.requiresCancelConfirmation)
        await model.begin()
        clock = clock.addingTimeInterval(9.99)
        #expect(!model.requiresCancelConfirmation)
        clock = clock.addingTimeInterval(0.02)
        #expect(model.requiresCancelConfirmation)
        await model.finishForDismissal()
        #expect(!model.requiresCancelConfirmation)
    }

    @Test func explicitCancelFencesBeforeDiscardAndPublishesAfterward() async throws {
        let library = try library(); defer { cleanup(library) }
        let engine = MobileVoiceTestEngine()
        var id: String?, events: [String] = []
        let model = MobileVoiceCaptureModel(library: library, engineFactory: { engine }, preflight: MobileVoiceTestPreflight(),
            privacyFence: {
                let noteID = try #require(id)
                let location = try library.store.note(id: noteID)?.location
                #expect(location == .notes)
                events.append("scrub")
            }, publishAfterMutation: {
                #expect((try? library.store.note(id: id ?? "")?.location) == .trash)
                events.append("publish")
            })
        await model.begin(); id = model.noteID
        #expect(await model.cancel())
        #expect(events.first == "scrub" && events.last == "publish")
        #expect(await engine.cancels == 1)
    }

    @Test(arguments: [1, 2])
    func failedCancelScrubKeepsLiveRecordingAndItsExactFiles(failureAt: Int) async throws {
        let library = try library(); defer { cleanup(library) }
        let engine = MobileVoiceTestEngine()
        var attempts = 0
        let model = MobileVoiceCaptureModel(library: library, engineFactory: { engine }, preflight: MobileVoiceTestPreflight(), privacyFence: {
            attempts += 1
            if attempts == failureAt { throw CocoaError(.fileWriteNoPermission) }
        }, publishAfterMutation: {})
        await model.begin()
        let id = try #require(model.noteID), file = try #require(await engine.recordingURL)
        await engine.send(.transcript(TranscriptUpdate(text: "Keep after failed scrub", isFinal: true)))
        try await wait("words before scrub failure") { model.refresh(); return model.transcript == "Keep after failed scrub" }
        let originalText = try library.store.note(id: id)?.text
        let before = try Data(contentsOf: file)
        #expect(!(await model.cancel()))
        #expect(try Data(contentsOf: file) == before)
        #expect(try library.store.note(id: id)?.text == originalText)
        #expect(try library.store.note(id: id)?.location == .notes)
        #expect(await engine.cancels == 0)
        #expect(await engine.finishes == 0)
        #expect(model.state == .listening && model.isBusy)
        #expect(model.cancellationError != nil)
        await model.finishForDismissal()
    }

    @Test(arguments: [false, true])
    func lateEngineStartCancelUsesHostFenceAndKeepsRecordingIfItFails(failLateFence: Bool) async throws {
        let library = try library(); defer { cleanup(library) }
        let engine = MobileVoiceTestEngine(), release = await engine.holdStart()
        defer { release.finish() }
        var attempts = 0
        let model = MobileVoiceCaptureModel(library: library, engineFactory: { engine }, preflight: MobileVoiceTestPreflight(), privacyFence: {
            attempts += 1
            if failLateFence && attempts == 2 { throw CocoaError(.fileWriteNoPermission) }
        }, publishAfterMutation: {})
        let starting = Task { await model.begin() }
        try await wait("late engine start") { model.noteID != nil }
        for _ in 0..<400 {
            if await engine.starts == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let id = try #require(model.noteID), file = try #require(await engine.recordingURL)
        let cancelling = Task { await model.cancel() }
        try await wait("pre-start privacy fence") { attempts == 1 }
        release.finish()
        await starting.value
        #expect(await cancelling.value == !failLateFence)
        #expect(attempts == 2)
        if failLateFence {
            #expect(try Data(contentsOf: file) == Data("fixture-audio".utf8))
            #expect(try library.store.note(id: id)?.location == .notes)
            #expect(await engine.cancels == 0)
            #expect(await engine.finishes == 0)
            #expect(model.isBusy && model.state == .listening)
            await model.finishForDismissal()
        } else {
            #expect(try library.store.note(id: id)?.location == .trash)
            #expect(await engine.cancels == 1)
        }
    }

    @Test func backgroundWaitsForPreservingStopAfterLateStartCancelScrubFailure() async throws {
        let library = try library(); defer { cleanup(library) }
        let engine = MobileVoiceTestEngine()
        let releaseStart = await engine.holdStart(), releaseFinish = await engine.holdFinish()
        defer { releaseStart.finish(); releaseFinish.finish() }
        var attempts = 0, suspended = false
        let model = MobileVoiceCaptureModel(library: library, engineFactory: { engine }, preflight: MobileVoiceTestPreflight(), privacyFence: {
            attempts += 1
            if attempts == 2 { throw CocoaError(.fileWriteNoPermission) }
        }, publishAfterMutation: {})
        let starting = Task { await model.begin() }
        try await wait("held engine creation") { model.noteID != nil }
        for _ in 0..<400 {
            if await engine.starts == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let id = try #require(model.noteID), selection = library.selectedID
        let cancelling = Task { await model.cancel() }
        try await wait("destructive cancel awaiting startup") { attempts == 1 }
        model.updateSceneActivity(active: false, background: true)
        let suspension = Task { await model.suspendForBackground(); suspended = true }
        for _ in 0..<30 { await Task.yield() }
        #expect(!suspended)
        await engine.send(.transcript(TranscriptUpdate(text: "Keep late start background words", isFinal: true)))
        releaseStart.finish()
        try await wait("background preserving finish after failed second fence") { model.state == .finishing && attempts == 2 }
        // An unfinished engine Stop is a real teardown barrier, not just a hidden transcript.
        #expect(!suspended && model.isBusy)
        #expect(model.transcript.isEmpty)
        releaseFinish.finish()
        await starting.value
        #expect(!(await cancelling.value))
        await suspension.value
        #expect(!model.isBusy && model.state == .idle)
        #expect(model.transcript.isEmpty && library.selectedID == selection)
        #expect(await engine.starts == 1)
        #expect(await engine.finishes == 1)
        #expect(await engine.cancels == 0)
        let note = try #require(try library.store.note(id: id))
        #expect(note.location == .notes && note.text.contains("Keep late start background words"))
        let link = try #require(NoteParser.attachmentLinks(in: note.text).first)
        #expect(try Data(contentsOf: library.paths.attachments.appendingPathComponent(id).appendingPathComponent(link.filename)) == Data("fixture-audio".utf8))
        model.updateSceneActivity(active: true, background: false)
        #expect(await engine.starts == 1) // Foreground does not restart the ended recorder.
    }

    @Test func beginImmediatelyAfterHeldStopCannotOvertakePendingCancel() async throws {
        let library = try library(); defer { cleanup(library) }
        let engine = MobileVoiceTestEngine(), release = await engine.holdFinish()
        defer { release.finish() }
        var fences = 0
        let model = MobileVoiceCaptureModel(library: library, engineFactory: { engine }, preflight: MobileVoiceTestPreflight(),
            privacyFence: { fences += 1 }, publishAfterMutation: {})
        await model.begin()
        let originalID = try #require(model.noteID)
        let stopping = Task { await model.stop(); await model.begin() }
        try await wait("held stop before explicit cancel") { model.state == .finishing }
        let cancelling = Task { await model.cancel() }
        try await wait("cancel waiting for old stop") { fences == 1 }
        #expect(model.isBusy)
        release.finish()
        await stopping.value
        _ = await cancelling.value
        #expect(await engine.starts == 1)
        #expect(model.noteID == originalID)
        #expect(!model.isBusy)
        #expect(try library.store.allNotes().count == 1)
    }

    @Test(arguments: [false, true])
    func cancellingHeldModelDownloadReturnsBeforeDownloadFinishesAndNeverCreatesNote(cooperative: Bool) async throws {
        let library = try library(); defer { cleanup(library) }
        let engine = MobileVoiceTestEngine(), preflight = HeldModelDownloadPreflight(cooperative: cooperative)
        var purges = 0, publications = 0, cancelled: Bool?
        let model = MobileVoiceCaptureModel(library: library, engineFactory: { engine }, preflight: preflight,
            privacyFence: { purges += 1 }, publishAfterMutation: { publications += 1 })
        let starting = Task { await model.begin() }
        try await wait("download model consent") { if case .needsModel = model.state { return true }; return false }
        model.answerModelDownload(true)
        for _ in 0..<400 {
            if await preflight.started { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await preflight.started)
        #expect(model.state == .downloading)
        let cancelling = Task { cancelled = await model.cancel() }
        // Bound the observation, not the OS work. Release below even on a failed expectation,
        // so this regression also terminates against the old implementation that hangs here.
        for _ in 0..<200 {
            if cancelled != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(cancelled == true)
        #expect(!model.isBusy && model.state == .idle)
        #expect(purges == 0 && publications == 0)
        #expect(await engine.starts == 0)
        #expect(try library.store.allNotes().isEmpty)
        await preflight.release()
        await cancelling.value
        await starting.value
        #expect(await preflight.cancellationObserved)
        #expect(await engine.starts == 0)
        #expect(try library.store.allNotes().isEmpty)
        #expect(!model.isBusy && model.state == .idle)
    }

}
