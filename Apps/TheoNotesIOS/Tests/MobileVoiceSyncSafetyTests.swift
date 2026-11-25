// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import TheoNotesCore
import TheoNotesVoice
@testable import BaerchenIOS

private actor SyncSafetyVoicePreflight: VoicePreflighting {
    private var permission: CheckedContinuation<Bool, Never>?
    private(set) var entered = false
    func requestMicrophone() async -> Bool {
        entered = true
        return await withCheckedContinuation { permission = $0 }
    }
    func availability(locale: Locale) async -> VoiceAvailability { .ready }
    func downloadModel(locale: Locale) async throws {}
    func release() { permission?.resume(returning: true); permission = nil }
}

private actor SyncSafetyVoiceEngine: VoiceEngine {
    nonisolated func isRecordingReadable(at url: URL) -> Bool { ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 }
    private var output: AsyncThrowingStream<VoiceEvent, any Error>.Continuation?
    private var finishGate: AsyncStream<Void>?
    func start(recordingTo url: URL) async throws -> AsyncThrowingStream<VoiceEvent, any Error> {
        try Data("sync-safety-fixture-audio".utf8).write(to: url)
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: VoiceEvent.self)
        output = continuation
        return stream
    }
    func holdFinish() -> AsyncStream<Void>.Continuation {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        finishGate = stream
        return continuation
    }
    func finish() async throws {
        if let finishGate { for await _ in finishGate { break } }
        output?.finish()
    }
    func cancel() async { output?.finish() }
    func send(_ event: VoiceEvent) { output?.yield(event) }
}

@Suite(.serialized) @MainActor struct MobileVoiceSyncSafetyTests {
    @Test(arguments: [SyncCommitScope.unrelated, .note("another-note"), .globalPrivacy, .unknown])
    func busyVoiceDefersEverySyncScopeBeforeMutationAndPreservesSessionIdentity(scope: SyncCommitScope) async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let other = try library.store.create(text: "# Another cached note")
        let otherSession = try library.session(for: other.id)
        let preflight = SyncSafetyVoicePreflight(), engine = SyncSafetyVoiceEngine()
        library.makeVoiceCapture = { owner in
            MobileVoiceCaptureModel(library: owner, engineFactory: { engine }, preflight: preflight)
        }
        let voice = library.voiceCapture
        library.displayedEditorNoteID = { nil } // Exercise the .note fast path as well as .unrelated.
        let coordinator = MobileSyncCommitCoordinator(library: library)
        let store = library.store
        let begin = Task { await voice.begin() }
        defer { begin.cancel() }
        for _ in 0..<400 {
            if await preflight.entered { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await preflight.entered)
        #expect(voice.isBusy)
        // Deletion would make commitSyncedChange remove ALL cached sessions, including Voice's.
        // Verify the boundary even before the recorder has acquired its target session.
        await #expect(throws: CancellationError.self) {
            _ = try await coordinator.commit(scope: scope) {
                try store.deletePermanently([other.id]); return .applied
            }
        }
        #expect(try library.store.note(id: other.id)?.text == other.text)
        #expect(library.cachedSession(for: other.id) === otherSession)
        await preflight.release()
        await begin.value
        let id = try #require(voice.noteID)
        let voiceSession = try #require(library.cachedSession(for: id))
        #expect(voice.isBusy && voice.state == .listening)
        await engine.send(.transcript(TranscriptUpdate(text: "Words before deferred sync", isFinal: true)))
        for _ in 0..<400 where !voiceSession.text.contains("Words before deferred sync") {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(voiceSession.text.contains("Words before deferred sync"))
        await #expect(throws: CancellationError.self) {
            _ = try await coordinator.commit(scope: scope) {
                try store.deletePermanently([other.id]); return .applied
            }
        }
        #expect(try library.store.note(id: other.id)?.text == other.text)
        #expect(library.cachedSession(for: other.id) === otherSession)
        #expect(try library.session(for: id) === voiceSession)
        await engine.send(.transcript(TranscriptUpdate(text: "Words after deferred sync", isFinal: true)))
        for _ in 0..<400 where !voiceSession.text.contains("Words after deferred sync") {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(voiceSession.text.contains("Words after deferred sync"))
        let finish = await engine.holdFinish()
        let stopping = Task { await voice.stop() }
        defer { finish.finish(); stopping.cancel() }
        for _ in 0..<400 where voice.state != .finishing { try await Task.sleep(for: .milliseconds(5)) }
        #expect(voice.isBusy && voice.state == .finishing)
        await #expect(throws: CancellationError.self) {
            _ = try await coordinator.commit(scope: scope) {
                try store.deletePermanently([other.id]); return .applied
            }
        }
        #expect(try library.session(for: id) === voiceSession)
        finish.yield(()); finish.finish()
        await stopping.value
        #expect(!voice.isBusy)
        #expect(try library.store.note(id: id)?.text.contains("Words before deferred sync") == true)
        let result = try await coordinator.commit(scope: scope) {
            try store.deletePermanently([other.id]); return .applied
        }
        #expect(result == .applied)
        #expect(try library.store.note(id: other.id) == nil)
        #expect(try library.store.note(id: id)?.text.contains("Words before deferred sync") == true)
        #expect(try library.store.note(id: id)?.text.contains("Words after deferred sync") == true)
    }
}
