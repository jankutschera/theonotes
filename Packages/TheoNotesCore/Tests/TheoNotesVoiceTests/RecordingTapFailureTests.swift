// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AVFoundation
import Foundation
import Speech
import Testing
@testable import TheoNotesVoice

/// A recording that cannot be written is a failure of its own: it is reported once, so the engine
/// can end with an error instead of looking like a microphone change.
@Suite struct RecordingTapFailureTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private static var monoFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
    }

    /// 16-bit interleaved samples are not something the tap can mix: every such buffer fails.
    private func unusableBuffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 2, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 1024
        return buffer
    }

    private func goodBuffer() -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: Self.monoFormat, frameCapacity: 1024)!
        buffer.frameLength = 1024
        return buffer
    }

    private func makeTap(failures: Counter) throws -> (RecordingTap, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tap-\(UUID().uuidString).m4a")
        let analyzer = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
        let (_, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let tap = try RecordingTap.make(
            recordingTo: url, tapFormat: Self.monoFormat, analyzerFormat: analyzer, input: continuation,
            onWriteFailure: { failures.bump() })
        return (tap, url)
    }

    @Test func repeatedFailedWritesAreReportedOnce() throws {
        let failures = Counter()
        let (tap, url) = try makeTap(failures: failures)
        defer { try? FileManager.default.removeItem(at: url) }
        for _ in 0..<3 { tap.receive(unusableBuffer()) }
        #expect(failures.count == 0, "a few bad buffers are not a failed recording")
        for _ in 0..<20 { tap.receive(unusableBuffer()) }
        #expect(failures.count == 1)
        #expect(tap.close().failedWrites == 23)
    }

    @Test func aGoodBufferResetsTheRun() throws {
        let failures = Counter()
        let (tap, url) = try makeTap(failures: failures)
        defer { try? FileManager.default.removeItem(at: url) }
        for _ in 0..<10 {
            for _ in 0..<4 { tap.receive(unusableBuffer()) }
            tap.receive(goodBuffer())
        }
        #expect(failures.count == 0)
        tap.close()
    }
}
