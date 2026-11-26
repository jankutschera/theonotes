// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore
@testable import TheoNotesVoice

/// Stop must end: K4 saw an insert-mode capture stay at "Listening" through two Stops.
/// An engine that never delivers its last results is cancelled after `finishTimeout`; what was
/// heard until then is kept and the failure is reported.
@MainActor
@Suite struct VoiceStopTimeoutTests {
    @Test func aStopThatTheEngineNeverAnswersEndsAfterTheTimeout() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "onetwo")
        let engine = FakeVoiceEngine()
        let capture = library.capture(.insert(noteId: note.id, utf16Offset: 3), engine: engine, finishTimeout: .milliseconds(200))
        try await capture.start()
        engine.final("and")
        await eventually("the final result") { capture.liveText == "and" }
        _ = engine.holdNextFinish()

        let stopped = Flag()
        let stopping = Task {
            defer { stopped.set() }
            return try await capture.stop()
        }
        await eventually("Stop to end") { stopped.isSet }
        guard stopped.isSet else { return }

        await #expect(throws: VoiceCaptureError.stopTimedOut) { try await stopping.value }
        #expect(capture.phase == .failed)
        #expect(engine.calls.contains(.cancel), "the engine was told to give up")
        let text = try #require(try library.store.note(id: note.id)?.text)
        #expect(text.hasPrefix("one"), "what was there stays: \(text)")
        #expect(text.contains("and"), "what was heard is kept: \(text)")
    }

    /// Stop with a finish that hangs; true when Stop returned within the wait.
    private func stopReturns(_ capture: VoiceCapture) async -> Bool {
        let stopped = Flag()
        let stopping = Task {
            defer { stopped.set() }
            return try? await capture.stop()
        }
        await eventually("Stop to end") { stopped.isSet }
        if !stopped.isSet { stopping.cancel() }
        return stopped.isSet
    }

    @Test func aCancelThatNeverReturnsDoesNotHoldStop() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "onetwo")
        let engine = FakeVoiceEngine()
        let capture = library.capture(.insert(noteId: note.id, utf16Offset: 3), engine: engine, finishTimeout: .milliseconds(200))
        try await capture.start()
        engine.final("and")
        await eventually("the final result") { capture.liveText == "and" }
        _ = engine.holdNextFinish()
        _ = engine.holdNextCancel()

        #expect(await stopReturns(capture), "Stop must not wait for a cancel that never returns")
        #expect(capture.phase == .failed)
        #expect(try library.store.note(id: note.id)?.text.contains("and") == true)
    }

    @Test func anEventStreamThatNeverEndsDoesNotHoldStop() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "onetwo")
        let engine = FakeVoiceEngine()
        let capture = library.capture(.insert(noteId: note.id, utf16Offset: 3), engine: engine, finishTimeout: .milliseconds(200))
        try await capture.start()
        engine.final("and")
        await eventually("the final result") { capture.liveText == "and" }
        _ = engine.holdNextFinish()
        engine.keepStreamOpen()

        #expect(await stopReturns(capture), "Stop must not wait for a stream that never ends")
        #expect(capture.phase == .failed)
        #expect(try library.store.note(id: note.id)?.text.contains("and") == true)
    }

    @Test func aProvisionalResultIsKeptWhenStopTimesOut() async throws {
        for target in ["insert", "new"] {
            let library = try VoiceTestLibrary(); defer { library.cleanup() }
            let note = try library.store.create(text: "onetwo")
            let engine = FakeVoiceEngine()
            let kind: VoiceCapture.Target = target == "insert" ? .insert(noteId: note.id, utf16Offset: 3) : .newNote
            let capture = library.capture(kind, engine: engine, finishTimeout: .milliseconds(200))
            try await capture.start()
            engine.partial("only provisional")
            await eventually("the provisional result") { capture.liveText == "only provisional" }
            _ = engine.holdNextFinish()

            #expect(await stopReturns(capture), Comment(rawValue: target))
            let id = try #require(capture.noteId)
            let text = try #require(try library.store.note(id: id)?.text)
            #expect(text.contains("only provisional"), "\(target): the provisional words are kept: \(text)")
        }
    }

    /// After a timeout the file may not be closed yet, so a Stop with no
    /// words keeps the recording and the note for recovery instead of dropping them.
    @Test func aTimedOutStopWithNoWordsKeepsTheRecording() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let engine = FakeVoiceEngine(audio: Data(), writesCloseMarker: false)
        let capture = library.capture(.newNote, engine: engine, finishTimeout: .milliseconds(200))
        try await capture.start()
        let id = try #require(capture.noteId)
        _ = engine.holdNextFinish()

        #expect(await stopReturns(capture))
        #expect(capture.phase == .failed)
        #expect(library.recordingFiles().count == 1)
        #expect(try library.store.note(id: id)?.location == .notes)
    }

    @Test func aStopThatAnswersInTimeIsUnaffected() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "onetwo")
        let engine = FakeVoiceEngine()
        let capture = library.capture(.insert(noteId: note.id, utf16Offset: 3), engine: engine, finishTimeout: .seconds(5))
        try await capture.start()
        engine.final("and")
        await eventually("the final result") { capture.liveText == "and" }

        let heard = try await capture.stop()

        #expect(heard == "and")
        #expect(capture.phase == .finished(noteId: note.id))
        #expect(engine.calls.contains(.cancel) == false)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
