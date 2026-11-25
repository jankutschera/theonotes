// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import AVFoundation
import TheoNotesCore
import TheoNotesVoice
import Foundation
import GRDB
import SwiftUI
import Testing
@testable import TheoNotes

// MARK: - Fakes (no microphone, no speech model, no network)

/// A scripted engine: `start` writes `audio` to the recording URL (standing in for the microphone) and
/// hands out a stream the test drives with `send`. `finish` ends the stream like the live one does.
final class ScriptedVoiceEngine: VoiceEngine, @unchecked Sendable {
    func isRecordingReadable(at url: URL) -> Bool { ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 }
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<VoiceEvent, any Error>.Continuation?
    private var log: [String] = []
    let audio: Data
    private let startGate: AsyncStream<Void>?
    private let startFails: Bool
    private var entered = false

    init(audio: Data, startGate: AsyncStream<Void>? = nil, startFails: Bool = false) {
        self.audio = audio
        self.startGate = startGate
        self.startFails = startFails
    }

    var calls: [String] { lock.withLock { log } }
    /// `start` was called (it may still be waiting on its gate).
    var startEntered: Bool { lock.withLock { entered } }

    func send(_ event: VoiceEvent) { _ = lock.withLock { continuation }?.yield(event) }

    func start(recordingTo url: URL) async throws -> AsyncThrowingStream<VoiceEvent, any Error> {
        lock.withLock { entered = true }
        if let startGate { for await _ in startGate { break } }
        if startFails { throw DownloadFailed() }
        try audio.write(to: url)
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: VoiceEvent.self, throwing: (any Error).self)
        lock.withLock {
            self.continuation = continuation
            log.append("start")
        }
        return stream
    }

    func finish() async throws {
        lock.withLock { log.append("finish") }
        lock.withLock { continuation }?.finish()
    }

    func cancel() async {
        lock.withLock { log.append("cancel") }
        lock.withLock { continuation }?.finish()
    }
}

/// Hands out `ScriptedVoiceEngine`s and remembers them.
final class EngineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var engines: [ScriptedVoiceEngine] = []
    let audio: Data

    init(audio: Data = Data("fake m4a bytes".utf8)) { self.audio = audio }

    private var nextGate: AsyncStream<Void>?
    private var nextFails = false

    /// The next engine's `start` waits until the returned continuation yields.
    func holdNextStart() -> AsyncStream<Void>.Continuation {
        let (gate, opener) = AsyncStream.makeStream(of: Void.self)
        lock.withLock { nextGate = gate }
        return opener
    }

    func failNextStart() { lock.withLock { nextFails = true } }

    func make() -> any VoiceEngine {
        let (gate, fails) = lock.withLock { () -> (AsyncStream<Void>?, Bool) in
            defer { nextGate = nil; nextFails = false }
            return (nextGate, nextFails)
        }
        let engine = ScriptedVoiceEngine(audio: audio, startGate: gate, startFails: fails)
        lock.withLock { engines.append(engine) }
        return engine
    }

    var made: [ScriptedVoiceEngine] { lock.withLock { engines } }
    var last: ScriptedVoiceEngine? { made.last }
}

/// Answers the questions of `VoicePreflight`; records what was asked and in which order.
final class FakeVoicePreflight: VoicePreflighting, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var answers: [VoiceAvailability]
    private var micGranted: Bool
    private var downloadFailure: (any Error)?
    private var downloadGates: [AsyncStream<Void>] = []

    init(_ answers: [VoiceAvailability] = [.ready], microphone: Bool = true, downloadFails: (any Error)? = nil) {
        self.answers = answers
        micGranted = microphone
        downloadFailure = downloadFails
    }

    var calls: [String] { lock.withLock { log } }

    func availability(locale: Locale) async -> VoiceAvailability {
        lock.withLock {
            log.append("availability")
            return answers.count > 1 ? answers.removeFirst() : answers[0]
        }
    }

    func requestMicrophone() async -> Bool {
        lock.withLock {
            log.append("microphone")
            return micGranted
        }
    }

    /// The next `downloadModel` waits until the returned continuation yields (gates are used in call order).
    func holdNextDownload() -> AsyncStream<Void>.Continuation {
        let (gate, opener) = AsyncStream.makeStream(of: Void.self)
        lock.withLock { downloadGates.append(gate) }
        return opener
    }

    func downloadModel(locale: Locale) async throws {
        let (failure, gate) = lock.withLock { () -> ((any Error)?, AsyncStream<Void>?) in
            log.append("download")
            return (downloadFailure, downloadGates.isEmpty ? nil : downloadGates.removeFirst())
        }
        if let gate { for await _ in gate { break } }
        if let failure { throw failure }
    }
}

struct DownloadFailed: Error {}

// MARK: - The model

/// Focus layer C13: File ▸ Capture Voice Note and Edit ▸ Insert Voice Note on the Mac (spec A2, FOC-R9,
/// FOC-R310 … FOC-R319). The library, the sessions and App Lock are the real ones; the engine and the
/// preflight are fakes, so no test touches the microphone or the speech model.
@MainActor
@Suite struct VoiceCaptureModelTests {
    @MainActor
    final class Env {
        let root = URL(fileURLWithPath: "/tmp/theo-voice-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let suiteName = "TheoNotesVoice-\(UUID().uuidString)"
        let authenticator = FakeAppAuthenticator()
        let environment: AppEnvironment
        let engines: EngineBox
        let preflight: FakeVoicePreflight
        let model: VoiceCaptureModel
        var opened: [String] = []
        /// Whether the open of each shown note was marked as "not an open" when `openNote` ran.
        var suppressed: [String: Bool] = [:]
        private nonisolated(unsafe) let pool: any DatabaseWriter

        init(
            preflight: FakeVoicePreflight = FakeVoicePreflight(), audio: Data = Data("fake m4a bytes".utf8),
            pollInterval: Duration = .milliseconds(5)
        ) throws {
            let engines = EngineBox(audio: audio)
            self.engines = engines
            self.preflight = preflight
            environment = try AppEnvironment(
                paths: AppPaths(root: root), vaultCache: FakeVaultKeyCache(), vaultLifecycle: nil,
                appAuthenticator: authenticator, appLockLifecycle: nil, appIdleSeconds: { 0 })
            pool = environment.database.pool
            model = VoiceCaptureModel(
                environment: environment, engineFactory: { engines.make() }, preflight: preflight,
                locale: Locale(identifier: "en_US"), pollInterval: pollInterval)
            wireOpening()
        }

        deinit {
            UserDefaults().removePersistentDomain(forName: suiteName)
            try? pool.close()
            try? FileManager.default.removeItem(at: root)
        }

        var store: NoteStore { environment.store }

        /// Plays the editor: a load that was marked as not an open is not recorded (FOC-R251).
        private func wireOpening() {
            model.openNote = { [unowned self] noteId in
                opened.append(noteId)
                let mark = environment.consumeOpenRecordSuppression(noteId)
                suppressed[noteId] = mark
                if !mark { environment.recordOpened(noteId: noteId) }
                return true
            }
        }

        func noteCount() throws -> Int {
            try pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note") ?? 0 }
        }

        func lastOpenedAt(_ noteId: String) throws -> Double? {
            try pool.read { try Double.fetchOne($0, sql: "SELECT lastOpenedAt FROM note_ui_state WHERE noteId = ?", arguments: [noteId]) }
        }

        func text(_ id: String) throws -> String { try #require(try store.note(id: id)).text }

        /// Starts a new-note capture and waits until it listens; returns the note's id.
        @discardableResult
        func startNewNote() async throws -> String {
            await model.beginNewNote()
            guard case .listening = model.state else {
                Issue.record("expected the model to listen, got \(model.state)")
                throw CancellationError()
            }
            return try #require(try store.allNotes().first?.id)
        }

        func waitUntil(_ what: String = "", _ condition: () -> Bool) async {
            for _ in 0..<2500 where !condition() { try? await Task.sleep(for: .milliseconds(2)) }
            if !condition() { Issue.record("timed out waiting for \(what)") }
        }

        func hear(_ text: String, final: Bool = true) async {
            engines.last?.send(.transcript(TranscriptUpdate(text: text, isFinal: final)))
            await waitUntil("the text \(text)") { model.state == .listening(text) }
        }
    }

    // MARK: Asking first

    @Test func missingModelAsksAndNotNowStartsNothing() async throws {
        let env = try Env(preflight: FakeVoicePreflight([.needsModelDownload(Locale(identifier: "en_US"))]))
        let run = Task { await env.model.beginNewNote() }
        await env.waitUntil("the model question") { env.model.state == .askingForModel(Locale(identifier: "en_US")) }
        #expect(env.model.isBusy)

        env.model.answerModelQuestion(download: false)
        await run.value

        #expect(env.model.state == .idle)
        #expect(!env.model.isBusy)
        #expect(env.preflight.calls == ["microphone", "availability"], "no download, no second check")
        #expect(env.engines.made.isEmpty)
        #expect(try env.noteCount() == 0)
    }

    @Test func downloadThenStartCreatesTheNote() async throws {
        let env = try Env(preflight: FakeVoicePreflight([.needsModelDownload(Locale(identifier: "en_US")), .ready]))
        let run = Task { await env.model.beginNewNote() }
        await env.waitUntil("the model question") { env.model.state == .askingForModel(Locale(identifier: "en_US")) }
        #expect(try env.noteCount() == 0, "nothing is made while the question is up")

        env.model.answerModelQuestion(download: true)
        await run.value

        #expect(env.model.state == .listening(""))
        #expect(env.preflight.calls == ["microphone", "availability", "download", "availability"])
        let id = try #require(try env.store.allNotes().first?.id)
        #expect(try env.store.captureSource(noteId: id) == .voice)
        #expect(env.engines.made.count == 1)
        await env.model.cancel()
    }

    @Test func aFailedDownloadShowsUnavailableAndCreatesNothing() async throws {
        let env = try Env(preflight: FakeVoicePreflight(
            [.needsModelDownload(Locale(identifier: "en_US"))], downloadFails: DownloadFailed()))
        let run = Task { await env.model.beginNewNote() }
        await env.waitUntil("the model question") { env.model.state == .askingForModel(Locale(identifier: "en_US")) }
        env.model.answerModelQuestion(download: true)
        await run.value

        #expect(env.model.state == .unavailable(VoiceCaptureModel.downloadFailedMessage))
        #expect(!env.model.isDownloading)
        #expect(try env.noteCount() == 0)
        #expect(env.engines.made.isEmpty)
    }

    @Test func microphoneDeniedShowsUnavailableAndCreatesNothing() async throws {
        let env = try Env(preflight: FakeVoicePreflight([.ready], microphone: false))
        await env.model.beginNewNote()

        #expect(env.model.state == .unavailable(VoiceCaptureModel.microphoneDeniedMessage))
        #expect(env.preflight.calls == ["microphone"], "nothing else is asked once the microphone is refused")
        #expect(env.engines.made.isEmpty)
        #expect(try env.noteCount() == 0)
        #expect(!env.model.isBusy)

        env.model.dismiss()
        #expect(env.model.state == .idle)
    }

    @Test func otherUnavailableAnswersShowTheirMessage() async throws {
        for (answer, message) in [
            (VoiceAvailability.unsupportedLocale, VoiceCaptureModel.unsupportedLocaleMessage),
            (.unavailable, VoiceCaptureModel.unavailableMessage),
        ] {
            let env = try Env(preflight: FakeVoicePreflight([answer]))
            await env.model.beginNewNote()
            #expect(env.model.state == .unavailable(message))
            #expect(try env.noteCount() == 0)
        }
    }

    // MARK: New note

    @Test func stopOpensTheNoteWithoutRecordingAnOpen() async throws {
        let env = try Env()
        let id = try await env.startNewNote()
        await env.hear("buy milk")
        #expect(try env.environment.session(for: id).text == "buy milk", "every final result is in the note's session as it arrives")

        await env.model.stop()

        #expect(env.model.state == .done)
        #expect(env.opened == [id])
        #expect(env.suppressed[id] == true, "the window's load is marked as not an open before it is requested")
        #expect(try env.lastOpenedAt(id) == nil)
        let text = try env.text(id)
        #expect(text.hasPrefix("buy milk\n") && text.contains(".m4a"), "the recording is linked on its own line: \(text)")
        #expect(try env.store.captureSource(noteId: id) == .voice)
        #expect(!env.model.isBusy)
        #expect(env.environment.openNoteIds.isEmpty, "the pin on the session is gone")
    }

    @Test func theCapturesSessionIsTheAppsCachedOne() async throws {
        let env = try Env()
        let id = try await env.startNewNote()
        await env.hear("first")

        // The provider hands out the app's cached session, so an editor opening the note sees the text.
        let session = try env.environment.session(for: id)
        #expect(session.text == "first")
        #expect(env.environment.openSessionCount == 1)
        #expect(env.environment.openNoteIds == [id], "the capture keeps its note's session from being evicted")
        await env.model.stop()
    }

    @Test func cancelLeavesTheTrashedNote() async throws {
        let env = try Env()
        let id = try await env.startNewNote()
        await env.hear("never mind")

        await env.model.cancel()

        #expect(env.model.state == .idle)
        #expect(!env.model.isBusy)
        let note = try #require(try env.store.note(id: id))
        #expect(note.location == .trash, "a note the capture made goes to the Trash")
        #expect(env.opened.isEmpty)
        #expect(env.engines.last?.calls.contains("cancel") == true)
        let recordings = (try? FileManager.default.contentsOfDirectory(atPath: env.environment.paths.recordings.path)) ?? []
        #expect(recordings.isEmpty, "the recording is deleted")
    }

    @Test func inputChangeShowsTheStopNoticeAndKeepsTheNote() async throws {
        let env = try Env()
        let id = try await env.startNewNote()
        await env.hear("heard before the headset")

        env.engines.last?.send(.inputChanged)
        await env.waitUntil("the stop notice") { env.model.state == .stoppedByInput }

        #expect(VoiceCaptureModel.stopNotice == "Recording stopped because the microphone changed.")
        let note = try #require(try env.store.note(id: id))
        #expect(note.location == .notes && note.deletedAt == nil)
        #expect(note.text.hasPrefix("heard before the headset") && note.text.contains(".m4a"))
        #expect(env.opened == [id], "the kept note is shown")
        #expect(!env.model.isBusy)

        env.model.dismiss()
        #expect(env.model.state == .idle)
    }

    @Test func aSecondBeginWhileBusyDoesNothing() async throws {
        let env = try Env()
        try await env.startNewNote()
        await env.model.beginNewNote()
        #expect(env.engines.made.count == 1)
        #expect(try env.noteCount() == 1)
        await env.model.cancel()
    }

    // MARK: Insert

    @Test func insertStopsIntoTheFocusedNoteAtTheCaret() async throws {
        let env = try Env()
        let note = try env.store.create(text: "Hello world")

        await env.model.beginInsert(noteId: note.id, utf16Offset: 6)
        guard case .listening = env.model.state else {
            Issue.record("expected listening, got \(env.model.state)")
            return
        }
        await env.hear("big")
        #expect(try env.text(note.id) == "Hello world", "nothing changes until Stop")

        await env.model.stop()

        #expect(env.model.state == .done)
        let text = try env.text(note.id)
        #expect(text.hasPrefix("Hello big\n") && text.contains(".m4a") && text.hasSuffix("\nworld"),
                "the words land at the caret, the recording on its own line: \(text)")
        #expect(env.opened.isEmpty, "the note is already in front")
        #expect(try env.noteCount() == 1)
    }

    @Test func cancelledInsertLeavesTheNoteByteIdentical() async throws {
        let env = try Env()
        let note = try env.store.create(text: "Hello world")
        await env.model.beginInsert(noteId: note.id, utf16Offset: 5)
        await env.hear("lost words")

        await env.model.cancel()

        let after = try #require(try env.store.note(id: note.id))
        #expect(after.text == "Hello world" && after.location == .notes)
        #expect(env.model.state == .idle)
    }

    @Test func insertIntoALockedNoteShowsUnavailable() async throws {
        let first = try ReminderEnv()
        let note = try first.store.create(text: "Secret")
        try await first.lockNote(note.id)
        let engines = EngineBox()
        let model = VoiceCaptureModel(
            environment: first.environment, engineFactory: { engines.make() }, preflight: FakeVoicePreflight(),
            locale: Locale(identifier: "en_US"), pollInterval: .milliseconds(5))

        await model.beginInsert(noteId: note.id, utf16Offset: 0)

        #expect(model.state == .unavailable(VoiceCaptureModel.noteUnavailableMessage))
        #expect(!model.isBusy)
    }

    @Test func insertModeStaysOn() {
        #expect(VoiceCapture.isInsertModeEnabled, "insert mode ships (final C11 review)")
    }

    // MARK: App Lock

    @Test func appLockDuringListeningCancels() async throws {
        let env = try Env()
        env.authenticator.script(.success)
        #expect(await env.environment.appLock.setEnabled(true) == .enabled)
        let id = try await env.startNewNote()
        await env.hear("private words")

        env.environment.appLock.lock()

        #expect(env.environment.appLock.isLocked)
        #expect(env.model.state == .idle, "the live text leaves the screen before the lock does")
        await env.model.teardown?.value
        #expect(!env.model.isBusy)
        #expect(env.engines.last?.calls.contains("cancel") == true)
        let note = try #require(try env.store.note(id: id))
        #expect(note.location == .trash, "the cancelled capture's note is in the Trash")
        #expect(env.opened.isEmpty)
        #expect(env.environment.openNoteIds.isEmpty)
    }

    @Test func nothingStartsWhileAppLockIsEngaged() async throws {
        let env = try Env()
        env.authenticator.script(.success)
        _ = await env.environment.appLock.setEnabled(true)
        env.environment.appLock.lock()

        await env.model.beginNewNote()

        #expect(env.model.state == .idle)
        #expect(env.preflight.calls.isEmpty, "not even the microphone is asked")
        #expect(try env.noteCount() == 0)
    }

    @Test func appLockWhileTheModelQuestionIsUpAnswersNo() async throws {
        let env = try Env(preflight: FakeVoicePreflight([.needsModelDownload(Locale(identifier: "en_US"))]))
        env.authenticator.script(.success)
        _ = await env.environment.appLock.setEnabled(true)
        let run = Task { await env.model.beginNewNote() }
        await env.waitUntil("the model question") { env.model.state == .askingForModel(Locale(identifier: "en_US")) }

        env.environment.appLock.lock()
        await run.value

        #expect(env.model.state == .idle)
        #expect(!env.preflight.calls.contains("download"))
        #expect(try env.noteCount() == 0)
    }

    // MARK: A lock that arrives through sync

    @Test func aLockThroughSyncStopsTheCaptureAndDropsTheSession() async throws {
        let fixture = try await LockedFixture()
        defer { fixture.destroy() }
        let engines = EngineBox()
        let model = VoiceCaptureModel(
            environment: fixture.environment, engineFactory: { engines.make() }, preflight: FakeVoicePreflight(),
            locale: Locale(identifier: "en_US"), pollInterval: .milliseconds(5))
        await model.beginNewNote()
        guard case .listening = model.state else {
            Issue.record("expected listening, got \(model.state)")
            return
        }
        let voiceNote = try #require(try fixture.environment.store.allNotes().first { $0.id != fixture.noteId })
        engines.last?.send(.transcript(TranscriptUpdate(text: "plaintextzqx", isFinal: true)))
        for _ in 0..<2500 where model.state != .listening("plaintextzqx") { try await Task.sleep(for: .milliseconds(2)) }
        #expect(fixture.environment.openSessionCount == 1, "the capture's session is held in memory")

        let remote = NoteStore(db: fixture.environment.database, notifier: nil, paths: fixture.environment.paths)
        let password = LockedFixture.password
        _ = try fixture.environment.commitSyncedChange {
            let access = try NotePrivacy(store: remote).unlock(password: password)
            defer { access.revoke() }
            try access.lock(noteId: voiceNote.id)
            return .applied
        }

        #expect(fixture.environment.openSessionCount == 0, "the session that held the plaintext is dropped")
        // The panel shows the message at once (FOC-R320); the capture itself ends a moment later.
        #expect(model.state == .unavailable(VoiceCaptureModel.noteLockedMessage))
        for _ in 0..<2500 where model.isBusy { try await Task.sleep(for: .milliseconds(2)) }
        #expect(model.state == .unavailable(VoiceCaptureModel.noteLockedMessage))
        #expect(!model.isBusy)
        #expect(try #require(try fixture.environment.store.note(id: voiceNote.id)).isLocked)
        let journals = (try? FileManager.default.contentsOfDirectory(atPath: fixture.environment.paths.journal.path)) ?? []
        #expect(!journals.contains { $0.hasPrefix(voiceNote.id + ".jsonl") || $0.hasPrefix(".locking-") }, "no plaintext journal is left")
        let recordings = (try? FileManager.default.contentsOfDirectory(atPath: fixture.environment.paths.recordings.path)) ?? []
        #expect(recordings.isEmpty, "the recording is gone")
    }

    // MARK: Fix round 1 (FOC-R320 … FOC-R323)

    /// A capture on the locked-notes fixture's library whose model never reads the capture by itself
    /// (a minute between reads), so only a synchronous lock notification can redact the panel.
    @MainActor
    final class LockEnv {
        let fixture: LockedFixture
        let engines: EngineBox
        let model: VoiceCaptureModel
        let noteId: String

        init() async throws {
            fixture = try await LockedFixture()
            let engines = EngineBox()
            self.engines = engines
            model = VoiceCaptureModel(
                environment: fixture.environment, engineFactory: { engines.make() }, preflight: FakeVoicePreflight(),
                locale: Locale(identifier: "en_US"), pollInterval: .seconds(60))
            await model.beginNewNote()
            guard case .listening = model.state else {
                Issue.record("expected listening, got \(model.state)")
                throw CancellationError()
            }
            let lockedFixtureNote = fixture.noteId
            let others = try fixture.environment.store.allNotes().filter { $0.id != lockedFixtureNote }
            let voiceNoteId = try #require(others.first).id
            noteId = voiceNoteId
            // The transcript reaches the panel when the model reads the capture.
            engines.last?.send(.transcript(TranscriptUpdate(text: "plaintextzqx", isFinal: true)))
            let environment = fixture.environment
            for _ in 0..<2500 where (try? environment.session(for: voiceNoteId).text) != "plaintextzqx" {
                try await Task.sleep(for: .milliseconds(2))
            }
            model.refresh()
            #expect(model.state == .listening("plaintextzqx"))
        }

        /// A store of the same library, as sync or the CLI would use it.
        var remote: NoteStore { NoteStore(db: fixture.environment.database, notifier: nil, paths: fixture.environment.paths) }

        nonisolated static func lock(_ noteId: String, password: String, in remote: NoteStore) throws {
            let access = try NotePrivacy(store: remote).unlock(password: password)
            defer { access.revoke() }
            try access.lock(noteId: noteId)
        }

        func remoteLock() throws { try Self.lock(noteId, password: LockedFixture.password, in: remote) }
    }

    @Test func aLocalLockHidesTheTranscriptWhenItCompletes() async throws {
        let lock = try await LockEnv()
        defer { lock.fixture.destroy() }

        let outcome = try await lock.fixture.environment.lockNotes(ids: [lock.noteId])

        #expect(outcome.locked == [lock.noteId])
        #expect(lock.model.state == .unavailable(VoiceCaptureModel.noteLockedMessage), "no tick needed: the transcript is gone at once")
    }

    @Test func aLockThroughSyncHidesTheTranscriptWhenItCompletes() async throws {
        let lock = try await LockEnv()
        defer { lock.fixture.destroy() }

        let remote = lock.remote, noteId = lock.noteId, password = LockedFixture.password
        _ = try lock.fixture.environment.commitSyncedChange {
            try LockEnv.lock(noteId, password: password, in: remote)
            return .applied
        }

        #expect(lock.model.state == .unavailable(VoiceCaptureModel.noteLockedMessage))
    }

    @Test func aLockByAnotherProcessHidesTheTranscriptOnTheNextDatabaseChange() async throws {
        let lock = try await LockEnv()
        defer { lock.fixture.destroy() }

        try lock.remoteLock()
        lock.fixture.environment.databaseDidChange()

        #expect(lock.model.state == .unavailable(VoiceCaptureModel.noteLockedMessage))
    }

    @Test func aDismissedLockMessageIsNotShownAgainWhenTheCaptureEnds() async throws {
        let lock = try await LockEnv()
        defer { lock.fixture.destroy() }
        let remote = lock.remote, noteId = lock.noteId, password = LockedFixture.password
        _ = try lock.fixture.environment.commitSyncedChange {
            try LockEnv.lock(noteId, password: password, in: remote)
            return .applied
        }
        lock.model.dismiss()
        #expect(lock.model.state == .idle)

        lock.model.refresh()
        for _ in 0..<2500 where lock.model.isBusy { try await Task.sleep(for: .milliseconds(2)); lock.model.refresh() }

        #expect(!lock.model.isBusy, "the capture ended by itself")
        #expect(lock.model.state == .idle, "the dismissed message is not shown again")
    }

    @Test func theSessionIsPinnedWhileTheEngineStarts() async throws {
        let env = try Env()
        let opener = env.engines.holdNextStart()
        let run = Task { await env.model.beginNewNote() }
        await env.waitUntil("the engine start") { env.engines.last?.startEntered == true }

        let id = try #require(try env.store.allNotes().first?.id)
        #expect(env.environment.openNoteIds == [id], "pinned as soon as the session exists")
        // Another window's change evicts every session nobody shows.
        env.environment.setOpenNoteIds([], for: ObjectIdentifier(env))
        #expect(env.environment.openSessionCount == 1, "the capture's session survived")

        opener.yield()
        opener.finish()
        await run.value
        #expect(env.model.state == .listening(""))
        await env.model.cancel()
        #expect(env.environment.openNoteIds.isEmpty)
    }

    @Test func aFailedStartReleasesThePin() async throws {
        let env = try Env()
        env.engines.failNextStart()

        await env.model.beginNewNote()

        #expect(env.model.state == .unavailable(VoiceCaptureModel.startFailedMessage))
        #expect(env.environment.openNoteIds.isEmpty)
        #expect(env.environment.openSessionCount == 0, "nothing keeps the failed capture's session")
    }

    @Test func cancelDuringTheEngineStartReleasesThePin() async throws {
        let env = try Env()
        let opener = env.engines.holdNextStart()
        let run = Task { await env.model.beginNewNote() }
        await env.waitUntil("the engine start") { env.engines.last?.startEntered == true }

        await env.model.cancel()
        opener.yield()
        opener.finish()
        await run.value

        #expect(env.model.state == .idle)
        #expect(!env.model.isBusy)
        #expect(env.environment.openNoteIds.isEmpty)
        #expect(env.engines.last?.calls.contains("cancel") == true)
    }

    @Test func anOlderDownloadEndingDoesNotEndANewerOnesDisplay() async throws {
        let locale = Locale(identifier: "en_US")
        let env = try Env(preflight: FakeVoicePreflight([.needsModelDownload(locale), .needsModelDownload(locale), .ready, .ready]))
        let openA = env.preflight.holdNextDownload()
        let openB = env.preflight.holdNextDownload()

        let runA = Task { await env.model.beginNewNote() }
        await env.waitUntil("the first question") { env.model.state == .askingForModel(locale) }
        env.model.answerModelQuestion(download: true)
        await env.waitUntil("the first download") { env.model.isDownloading }
        await env.model.cancel()
        #expect(!env.model.isDownloading)

        let runB = Task { await env.model.beginNewNote() }
        await env.waitUntil("the second question") { env.model.state == .askingForModel(locale) }
        env.model.answerModelQuestion(download: true)
        await env.waitUntil("the second download") { env.model.isDownloading }

        openA.yield()
        await runA.value
        #expect(env.model.isDownloading, "the first run ended; the second is still downloading")

        openB.yield()
        await runB.value
        #expect(env.model.state == .listening(""))
        #expect(!env.model.isDownloading)
        await env.model.cancel()
    }

    @Test func anOlderDownloadFailingDoesNotEndANewerOnesDisplay() async throws {
        let locale = Locale(identifier: "en_US")
        let env = try Env(preflight: FakeVoicePreflight([.needsModelDownload(locale)], downloadFails: DownloadFailed()))
        let openA = env.preflight.holdNextDownload()
        let openB = env.preflight.holdNextDownload()

        let runA = Task { await env.model.beginNewNote() }
        await env.waitUntil("the first question") { env.model.state == .askingForModel(locale) }
        env.model.answerModelQuestion(download: true)
        await env.waitUntil("the first download") { env.model.isDownloading }
        await env.model.cancel()

        let runB = Task { await env.model.beginNewNote() }
        await env.waitUntil("the second question") { env.model.state == .askingForModel(locale) }
        env.model.answerModelQuestion(download: true)
        await env.waitUntil("the second download") { env.model.isDownloading }

        openA.yield()
        await runA.value
        #expect(env.model.isDownloading, "the first download failed; the second is still going")
        #expect(env.model.state == .askingForModel(locale), "and its failure is not shown for the second")

        openB.yield()
        await runB.value
        #expect(env.model.state == .unavailable(VoiceCaptureModel.downloadFailedMessage))
        #expect(!env.model.isDownloading)
    }

    @Test func thePanelIsBroughtToTheFrontOnlyWhenItOpens() async throws {
        let env = try Env()
        let controller = VoicePanelController(model: env.model)
        defer { env.model.dismiss(); controller.update() }
        try await env.startNewNote()
        controller.update()
        #expect(controller.frontCount == 1)

        await env.hear("one", final: false)
        controller.update()
        await env.hear("one more", final: false)
        controller.update()
        #expect(controller.frontCount == 1, "later updates leave the window order alone")

        await env.model.cancel()
        controller.update()
        #expect(!controller.isShown)
    }

    // MARK: The app wiring

    @MainActor
    final class AppEnv {
        let env: Env
        let app: AppModel
        let defaults: UserDefaults

        init() throws {
            env = try Env(audio: Data())
            defaults = UserDefaults(suiteName: env.suiteName)!
            let environment = env.environment
            let engines = env.engines
            let preflight = env.preflight
            app = AppModel(environment: environment, defaults: defaults, makeVoice: { _ in
                VoiceCaptureModel(
                    environment: environment, engineFactory: { engines.make() }, preflight: preflight,
                    locale: Locale(identifier: "en_US"), pollInterval: .milliseconds(5))
            })
            app.openWindowRequest = { _ in }
        }

        func editor() -> EditorBridgeController {
            let controller = EditorBridgeController(
                environment: env.environment, page: FakeEditorPage(), openExternally: { _ in }, checksumInterval: nil)
            _ = controller.handle(.ready(version: EditorBridge.version))
            return controller
        }
    }

    @Test func theRealEmptyCardOffersTheVoiceButtonAndItStartsACapture() async throws {
        let a = try AppEnv()
        let main = a.app.makeMainWindow(editor: a.editor())
        main.nextUp.refresh()
        #expect(main.nextUp.candidate == nil)
        #expect(main.nextUp.offersVoiceCapture, "the app wires the empty card's button")

        // The real panel, rendered: the button makes the card taller than the same card without it.
        func cardHeight() -> CGFloat { NSHostingView(rootView: NextUpPanel(model: main.nextUp)).fittingSize.height }
        let withButton = cardHeight()
        let wired = main.nextUp.startVoiceCapture
        main.nextUp.startVoiceCapture = nil
        let without = cardHeight()
        main.nextUp.startVoiceCapture = wired
        #expect(withButton > without, "the empty card shows the button (\(withButton) vs \(without))")

        main.nextUp.captureVoice()
        await a.env.waitUntil("the capture to listen") { a.app.voice.state == .listening("") }
        #expect(try a.env.noteCount() == 1)
        #expect(try a.env.store.captureSource(noteId: try #require(try a.env.store.allNotes().first?.id)) == .voice)
        await a.app.voice.cancel()
    }

    @Test func aCardWithSomethingOnItDoesNotOfferVoice() async throws {
        let a = try AppEnv()
        _ = try a.env.store.create(text: "Groceries\n- [ ] milk")
        let main = a.app.makeMainWindow(editor: a.editor())
        main.nextUp.refresh()
        #expect(main.nextUp.candidate != nil)
        #expect(!main.nextUp.offersVoiceCapture)
    }

    @Test func insertVoiceNoteUsesTheFocusedEditorsNoteAndCaret() async throws {
        let a = try AppEnv()
        let note = try a.env.store.create(text: "Hello world")
        let editor = a.editor()
        try editor.open(noteId: note.id, caret: 6)
        let main = a.app.makeMainWindow(editor: editor)

        a.app.insertVoiceNote(main: main, noteWindow: nil)
        await a.env.waitUntil("the capture to listen") { a.app.voice.state == .listening("") }
        a.env.engines.last?.send(.transcript(TranscriptUpdate(text: "big", isFinal: true)))
        await a.env.waitUntil("the text") { a.app.voice.state == .listening("big") }
        await a.app.voice.stop()

        #expect(try a.env.text(note.id) == "Hello bigworld")
        #expect(try a.env.noteCount() == 1)
    }

    @Test func captureVoiceNoteDoesNothingWhileLocked() async throws {
        let a = try AppEnv()
        a.env.authenticator.script(.success)
        _ = await a.env.environment.appLock.setEnabled(true)
        a.env.environment.appLock.lock()

        a.app.captureVoiceNote()
        await Task.yield()

        #expect(a.app.voice.state == .idle)
        #expect(a.env.preflight.calls.isEmpty)
        #expect(VoiceMenu.isCaptureDisabled(app: a.app))
    }

    @Test func menuItemsFollowTheAppState() async throws {
        let a = try AppEnv()
        #expect(VoiceMenu.isCaptureDisabled(app: nil))
        #expect(!VoiceMenu.isCaptureDisabled(app: a.app))
        #expect(VoiceMenu.isInsertDisabled(app: a.app, editorEnabled: false), "no editable note with the focus")
        #expect(!VoiceMenu.isInsertDisabled(app: a.app, editorEnabled: true))

        a.app.captureVoiceNote()
        await a.env.waitUntil("the capture to listen") { a.app.voice.state == .listening("") }
        await a.env.waitUntil("the busy mirror") { a.app.isMakingVoiceNote }
        #expect(VoiceMenu.isCaptureDisabled(app: a.app), "one voice note at a time")
        #expect(VoiceMenu.isInsertDisabled(app: a.app, editorEnabled: true))
        await a.app.voice.cancel()
        await a.env.waitUntil("the busy mirror to clear") { !a.app.isMakingVoiceNote }
        #expect(!VoiceMenu.isCaptureDisabled(app: a.app))
    }

    // MARK: Launch

    private let leftoverName = "Voice Note 2026-10-27 09.00.m4a"

    @Test func launchAdoptsALeftoverRecordingBeforeThePrivacyCleanup() async throws {
        let first = try ReminderEnv()
        let note = try first.store.create(text: "Memo")
        let folder = first.environment.paths.recordings.appendingPathComponent(note.id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Real audio: launch recovery adopts only a recording that can be played.
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
        buffer.frameLength = 4_410
        do {
            let file = try AVAudioFile(
                forWriting: folder.appendingPathComponent(leftoverName),
                settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1])
            try file.write(from: buffer)
            file.close()
        }

        let second = try first.relaunch()

        #expect(second.environment.launchSteps == [.attachments, .journals, .voiceRecordings, .privacyCleanup])
        let text = try #require(try second.store.note(id: note.id)).text
        #expect(text.hasPrefix("Memo\n") && text.contains(".m4a"), "the recording is attached to its note: \(text)")
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    /// 1.1 A2 (d), FOC-R399: a leftover that cannot be played is marked and never removed in the
    /// launch that marked it; one marked by an earlier launch a day ago goes, and the first window
    /// says so once.
    @Test func anUnplayableLeftoverGoesInALaterLaunchAndTheUserIsToldOnce() async throws {
        let first = try ReminderEnv()
        let note = try first.store.create(text: "Memo")
        let folder = first.environment.paths.recordings.appendingPathComponent(note.id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(leftoverName)
        try Data("not audio".utf8).write(to: file)

        let second = try first.relaunch()
        #expect(FileManager.default.fileExists(atPath: file.path), "this process marked it: it stays")
        #expect(LibraryModel(environment: second.environment).banner == nil)

        VoiceRecordingRecovery.mark(file, wordsInserted: false, at: Date().addingTimeInterval(-2 * 86_400), launch: "earlier")
        let third = try second.relaunch()
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        let window = LibraryModel(environment: third.environment)
        #expect(window.banner == .voiceRecordingRemoved)
        #expect(window.banner?.message == "A voice recording could not be read and was removed.")
        #expect(LibraryModel(environment: third.environment).banner == nil, "a second window is not told again")
        #expect(try third.store.note(id: note.id)?.text == "Memo")
    }

    /// FOC-R395: unfinished words are journaled but not stored; a launch after a crash replays the
    /// journal and they are back.
    @Test func unfinishedWordsSurviveACrash() async throws {
        let env = try Env()
        let id = try await env.startNewNote()
        await env.hear("buy milk")
        env.engines.last?.send(.transcript(TranscriptUpdate(text: "and bread", isFinal: false)))
        await env.waitUntil("the provisional words") { env.model.state == .listening("buy milk and bread") }
        env.environment.flushAll()
        #expect(try env.text(id) == "buy milk")
        // A second environment on the same folder stands in for the launch after a crash.
        let relaunched = try AppEnvironment(
            paths: AppPaths(root: env.root), vaultCache: FakeVaultKeyCache(), vaultLifecycle: nil,
            appAuthenticator: FakeAppAuthenticator(), appLockLifecycle: nil, appIdleSeconds: { 0 })
        #expect(try relaunched.store.note(id: id)?.text == "buy milk and bread")
        try? relaunched.database.pool.close()
        await env.model.cancel()
    }

    /// 1.1 A2: Stop with words but a recording that cannot be played keeps the words, says so, and
    /// a later launch a day on removes the file without a notice (FOC-R399).
    @Test func stopWithAnUnplayableRecordingKeepsTheWordsAndTheFileGoesInALaterLaunch() async throws {
        let env = try Env(audio: Data())
        let id = try await env.startNewNote()
        await env.hear("buy milk")
        await env.model.stop()
        #expect(env.model.state == .unavailable(VoiceCaptureModel.interruptedMessage))
        #expect(try env.text(id) == "buy milk")
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: env.environment.paths.recordings.appendingPathComponent(id).path)
        #expect(leftovers.count == 1)

        var removed: [Int] = []
        func launch(_ id: String, after seconds: TimeInterval) throws {
            _ = try VoiceRecordingRecovery.adoptLeftovers(
                store: env.store, attachments: AttachmentStore(paths: env.environment.paths, database: env.environment.database),
                directory: env.environment.paths.recordings, now: Date().addingTimeInterval(seconds), launch: id,
                onUnreadableRemoved: { removed.append($0) })
        }
        try launch(VoiceRecordingRecovery.currentLaunch, after: 2 * 86_400)
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: env.environment.paths.recordings.appendingPathComponent(id).path).count == 1)
        try launch("later", after: 86_400 + 60)
        #expect(!FileManager.default.fileExists(atPath: env.environment.paths.recordings.appendingPathComponent(id).path))
        #expect(removed.isEmpty)
        #expect(try env.text(id) == "buy milk")
    }

    /// 1.1 A2 (c), FOC-R398: no words and nothing that plays: the panel closes, nothing is kept.
    @Test func stopWithNoWordsAndNoUsableAudioKeepsNothing() async throws {
        let env = try Env(audio: Data())
        let id = try await env.startNewNote()
        await env.model.stop()
        #expect(env.model.state == .idle)
        #expect(env.opened.isEmpty)
        #expect(try env.store.note(id: id)?.location == .trash)
        #expect(!FileManager.default.fileExists(atPath: env.environment.paths.recordings.appendingPathComponent(id).path))
    }

    @Test func theCaptureCleanupFinishesBeforeThePrivacyCleanupRuns() async throws {
        let first = try ReminderEnv()
        let note = try first.store.create(text: "Locked memo")
        try await first.lockNote(note.id)
        // What a crash during a capture's lock left: the lock's own cleanup is pending, the capture's
        // plaintext journal is still on disk and its marker says so.
        try await first.environment.database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO privacy_transition(noteId, targetLocked, filenames) VALUES (?, 1, '[]')", arguments: [note.id])
        }
        let paths = first.environment.paths
        let journal = paths.journal.appendingPathComponent(note.id + ".jsonl")
        try Data("{\"plaintext\":true}\n".utf8).write(to: journal)
        let marker = paths.recordings.appendingPathComponent(".pending-cleanup-\(note.id)")
        try Data("journal".utf8).write(to: marker)

        let second = try first.relaunch()

        #expect(second.environment.vault.cleanupState == .clean, "the privacy cleanup is not stopped by the capture's journal")
        #expect(!FileManager.default.fileExists(atPath: journal.path))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        let rows = try await second.environment.database.pool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM privacy_transition") ?? -1
        }
        #expect(rows == 0)
    }

    @Test func aRecordingThatCannotBeRemovedIsLoggedAndTheLaunchContinues() async throws {
        let first = try ReminderEnv()
        let recordings = first.environment.paths.recordings
        let stray = recordings.appendingPathComponent("stray.m4a")
        try Data("loose".utf8).write(to: stray)
        first.shutDown()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: recordings.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recordings.path) }

        let second = try ReminderEnv(root: first.root, clock: first.clock)

        #expect(second.environment.launchSteps == [.attachments, .journals, .voiceRecordings, .privacyCleanup],
                "the failed removal does not stop the launch")
        #expect(FileManager.default.fileExists(atPath: stray.path), "it stays for the next launch")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recordings.path)
    }

    // MARK: Project settings and copy

    @Test func microphoneIsTheOnlyPermissionAndTheEntitlementIsSet() throws {
        let info = Bundle.main.infoDictionary ?? [:]
        #expect(info["NSMicrophoneUsageDescription"] as? String
            == "Theo Notes records your voice note and keeps the recording with the note.")
        #expect(info["NSSpeechRecognitionUsageDescription"] == nil, "on-device transcription needs the microphone only (FOC-R9)")

        let entitlements = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("TheoNotes.entitlements")
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: Data(contentsOf: entitlements), format: nil) as? [String: Any])
        #expect(plist["com.apple.security.device.audio-input"] as? Bool == true)
    }

    @Test func theCopyIsOurOwnAndNeverNamesACondition() {
        let en = Locale(identifier: "en_US")
        #expect(VoiceCaptureModel.modelQuestion(for: en)
            == "Voice notes need the speech model for English (United States). Download it from Apple now?")
        let all = [
            VoiceCaptureModel.stopNotice, VoiceCaptureModel.microphoneDeniedMessage, VoiceCaptureModel.unsupportedLocaleMessage,
            VoiceCaptureModel.unavailableMessage, VoiceCaptureModel.downloadFailedMessage, VoiceCaptureModel.startFailedMessage,
            VoiceCaptureModel.noteLockedMessage, VoiceCaptureModel.noteUnavailableMessage, VoiceCaptureModel.interruptedMessage,
            VoiceMenu.captureTitle, VoiceMenu.insertTitle, VoiceMenu.panelTitle,
        ]
        for text in all {
            #expect(!text.localizedCaseInsensitiveContains("adhd") && !text.localizedCaseInsensitiveContains("adhs"))
            #expect(!text.localizedCaseInsensitiveContains("bear"))
        }
        #expect(VoiceMenu.captureTitle == "Capture Voice Note" && VoiceMenu.insertTitle == "Insert Voice Note")
    }
}
