// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AVFoundation
import Foundation
import Speech
import Testing
@testable import TheoNotesVoice

/// The input tap's format on real hardware varies: a built-in microphone array reported four
/// channels at 48 kHz (K4), and the AAC encoder cannot write that layout. The tap turns
/// whatever arrives into one mono recording and one analyzer feed.
@Suite struct RecordingTapTests {
    /// 16 kHz mono Int16: what the speech analyzer asks for.
    private static var analyzerFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
    }

    private static func tapFormat(channels: AVAudioChannelCount, rate: Double = 48000, interleaved: Bool = false) -> AVAudioFormat {
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)!
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: interleaved, channelLayout: layout)
    }

    /// `frames` of a 440 Hz sine, the same in every channel.
    private static func sine(_ format: AVAudioFormat, frames: AVAudioFrameCount, from start: Int) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channels = Int(format.channelCount)
        let stride = buffer.stride
        let data = buffer.floatChannelData!
        for frame in 0..<Int(frames) {
            let value = Float(0.5 * sin(2 * Double.pi * 440 * Double(start + frame) / format.sampleRate))
            for channel in 0..<channels { data[channel][frame * stride] = value }
        }
        return buffer
    }

    private func record(channels: AVAudioChannelCount, interleaved: Bool = false) async throws -> (RecordingTapStats, URL, Int) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tap-\(UUID().uuidString).m4a")
        let (sequence, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let format = Self.tapFormat(channels: channels, interleaved: interleaved)
        let tap = try RecordingTap.make(
            recordingTo: url, tapFormat: format, analyzerFormat: Self.analyzerFormat, input: continuation)
        for index in 0..<20 { tap.receive(Self.sine(format, frames: 4096, from: index * 4096)) }
        let stats = tap.close()
        var delivered = 0
        for await _ in sequence { delivered += 1 }
        return (stats, url, delivered)
    }

    @Test(arguments: [1, 2, 4, 6] as [AVAudioChannelCount])
    func everyBufferIsWrittenAndFed(channels: AVAudioChannelCount) async throws {
        let (stats, url, delivered) = try await record(channels: channels)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(stats.received == 20)
        #expect(stats.failedWrites == 0, "\(channels) channels")
        #expect(stats.deliveredToAnalyzer == 20)
        #expect(delivered == 20)
        let written = try AVAudioFile(forReading: url)
        // 20 x 4096 frames at 48 kHz; the encoder pads a little at the ends.
        #expect(written.length >= 20 * 4096 - 2048)
        #expect(written.processingFormat.sampleRate == 48000)
        #expect(written.processingFormat.channelCount == 1, "a mono recording")
    }

    /// The same microphone changes its format mid-recording (a headset leaving its call
    /// profile). Both rates end up in one recording at the first rate, and the analyzer hears both.
    @Test func aChangeOfSampleRateMidRecordingKeepsRecording() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tap-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let (sequence, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let first = Self.tapFormat(channels: 1, rate: 24000)
        let second = Self.tapFormat(channels: 1, rate: 16000)
        let tap = try RecordingTap.make(recordingTo: url, tapFormat: first, analyzerFormat: Self.analyzerFormat, input: continuation)
        for index in 0..<10 { tap.receive(Self.sine(first, frames: 2400, from: index * 2400)) }
        for index in 0..<10 { tap.receive(Self.sine(second, frames: 1600, from: index * 1600)) }
        let stats = tap.close()
        var delivered = 0
        for await _ in sequence { delivered += 1 }

        #expect(stats.received == 20)
        #expect(stats.failedWrites == 0, "buffers of the new rate are written too")
        #expect(stats.deliveredToAnalyzer == 20 && delivered == 20)
        let written = try AVAudioFile(forReading: url)
        #expect(written.processingFormat.sampleRate == 24000, "the file keeps the rate it was opened with")
        // 10 x 0.1 s at each rate: about two seconds of audio, give or take the encoder's padding.
        #expect(written.length >= 24000 * 2 - 4096, "length \(written.length)")
        #expect(written.length <= 24000 * 2 + 4096, "length \(written.length)")
    }

    @Test func aChangeOfChannelCountMidRecordingKeepsRecording() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tap-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let (sequence, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let mono = Self.tapFormat(channels: 1, rate: 48000)
        let quad = Self.tapFormat(channels: 4, rate: 48000)
        let tap = try RecordingTap.make(recordingTo: url, tapFormat: mono, analyzerFormat: Self.analyzerFormat, input: continuation)
        for index in 0..<5 { tap.receive(Self.sine(mono, frames: 4096, from: index * 4096)) }
        for index in 0..<5 { tap.receive(Self.sine(quad, frames: 4096, from: index * 4096)) }
        let stats = tap.close()
        var delivered = 0
        for await _ in sequence { delivered += 1 }
        #expect(stats.failedWrites == 0 && stats.deliveredToAnalyzer == 10 && delivered == 10)
    }

    @Test func interleavedInputIsHandledToo() async throws {
        let (stats, url, delivered) = try await record(channels: 4, interleaved: true)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(stats.failedWrites == 0)
        #expect(delivered == 20)
    }

    @Test func theRecordingHoldsTheSignal() async throws {
        let (_, url, _) = try await record(channels: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let written = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: written.processingFormat, frameCapacity: 8192)!
        try written.read(into: buffer, frameCount: 8192)
        let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        let peak = samples.map(abs).max() ?? 0
        #expect(peak > 0.25, "the mix keeps the level of one channel, peak \(peak)")
    }

    @Test func closingTwiceIsHarmless() async throws {
        let (_, url, _) = try await record(channels: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let url2 = FileManager.default.temporaryDirectory.appendingPathComponent("tap-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url2) }
        let (_, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let format = Self.tapFormat(channels: 1)
        let tap = try RecordingTap.make(recordingTo: url2, tapFormat: format, analyzerFormat: Self.analyzerFormat, input: continuation)
        tap.receive(Self.sine(format, frames: 4096, from: 0))
        let first = tap.close()
        #expect(tap.close() == first)
        tap.receive(Self.sine(format, frames: 4096, from: 0))
        #expect(tap.close() == first, "nothing is written after close")
    }
}
