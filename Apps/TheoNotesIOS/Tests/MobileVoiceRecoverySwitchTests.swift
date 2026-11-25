// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Observation
import Testing
import TheoNotesCore
import TheoNotesVoice
@testable import BaerchenIOS

private actor RecoverySwitchPreflight: VoicePreflighting {
    private var reply: CheckedContinuation<Bool, Never>?
    private(set) var entered = false
    func requestMicrophone() async -> Bool {
        entered = true
        return await withCheckedContinuation { reply = $0 }
    }
    func availability(locale: Locale) async -> VoiceAvailability { .ready }
    func downloadModel(locale: Locale) async throws {}
    func deny() { reply?.resume(returning: false); reply = nil }
}

private actor RecoverySwitchVoiceEngine: VoiceEngine {
    private(set) var starts = 0
    func start(recordingTo url: URL) async throws -> AsyncThrowingStream<VoiceEvent, any Error> {
        starts += 1
        throw CocoaError(.fileWriteUnknown) // Held preflight must prevent any recorder start.
    }
    func finish() async throws {}
    func cancel() async {}
}

@Suite(.serialized) @MainActor struct MobileVoiceRecoverySwitchTests {
    private func selectedBytes(base: AppPaths) throws -> Data? {
        let file = base.root.appendingPathComponent(".active-recovery-library.json")
        return FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
    }

    @Test(arguments: [false, true])
    func busyVoicePreflightCannotChangePersistentRecoverySelection(returnToOriginal: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("Original")))
        defer { try? original.close(); try? FileManager.default.removeItem(at: root) }
        _ = try original.store.create(text: "# Recovery guard fixture")
        let archive = try await original.makeBackup()
        let prepared = try SyncRecoveryLibrary.prepare(source: original.paths, archive: archive)
        defer { try? FileManager.default.removeItem(at: prepared.paths.root) }
        if returnToOriginal { try SyncRecoveryLibrary.select(prepared) }
        let current = returnToOriginal ? try MobileLibrary(paths: prepared.paths) : original
        defer { if current !== original { try? current.close() } }
        let sync = MobileSyncController(library: current)
        defer { sync.stopScheduling() }
        #expect(returnToOriginal || sync.preparedRecoveryLibrary != nil)
        let preflight = RecoverySwitchPreflight(), engine = RecoverySwitchVoiceEngine()
        current.makeVoiceCapture = { library in
            MobileVoiceCaptureModel(library: library, engineFactory: { engine }, preflight: preflight)
        }
        #expect(!current.voiceCaptureBusy)
        let voice = current.voiceCapture
        let starting = Task { await voice.begin() }
        defer { starting.cancel() }
        for _ in 0..<400 {
            if await preflight.entered { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await preflight.entered)
        #expect(current.voiceCaptureBusy && voice.state == .preparing)
        let before = try selectedBytes(base: original.paths)
        let active = try SyncRecoveryLibrary.activePaths(base: original.paths).root
        if returnToOriginal { await sync.returnToOriginalLibrary() }
        else { await sync.openRecoveryCopy() }
        #expect(sync.errorMessage == BackupError.pendingFiles.localizedDescription)
        #expect(try SyncRecoveryLibrary.activePaths(base: original.paths).root == active)
        #expect(try selectedBytes(base: original.paths) == before)
        #expect(current.voiceCaptureBusy)
        #expect(await engine.starts == 0)
        await preflight.deny()
        await starting.value
        await voice.cancel()
        #expect(!current.voiceCaptureBusy)
    }

    @Test func voiceBecomingBusyAtPauseTransitionPreservesRecoverySelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("Original")))
        defer { try? original.close(); try? FileManager.default.removeItem(at: root) }
        _ = try original.store.create(text: "# Post-pause guard fixture")
        let archive = try await original.makeBackup()
        let prepared = try SyncRecoveryLibrary.prepare(source: original.paths, archive: archive)
        defer { try? FileManager.default.removeItem(at: prepared.paths.root) }
        try SyncRecoveryLibrary.select(prepared)
        let current = try MobileLibrary(paths: prepared.paths)
        defer { try? current.close() }
        let sync = MobileSyncController(library: current)
        defer { sync.stopScheduling() }
        let voice = current.voiceCapture
        #expect(!current.voiceCaptureBusy && !sync.paused)
        let before = try selectedBytes(base: original.paths)
        // Observe the actual production pause property. Its synchronous will-change callback
        // enters a valid Voice teardown window AFTER return's initial guard, without relying
        // on scheduler timing or mocking the method whose second guard is under test.
        withObservationTracking {
            _ = sync.paused
        } onChange: {
            MainActor.assumeIsolated { voice.prepareForBackground() }
        }
        await sync.returnToOriginalLibrary()
        #expect(sync.paused)
        #expect(current.voiceCaptureBusy)
        #expect(sync.errorMessage == BackupError.pendingFiles.localizedDescription)
        #expect(try SyncRecoveryLibrary.activePaths(base: original.paths).root == prepared.paths.root)
        #expect(try selectedBytes(base: original.paths) == before)
        await voice.suspendForBackground()
        #expect(!current.voiceCaptureBusy)
    }
}
