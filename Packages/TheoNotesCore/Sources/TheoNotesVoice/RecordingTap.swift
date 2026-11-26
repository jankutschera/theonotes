// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AVFoundation
import Foundation
import os
import Speech

private let tapLogger = Logger(subsystem: "com.truebrewbirdie.baerchen", category: "voice")

/// What a `RecordingTap` did with the buffers it was given.
struct RecordingTapStats: Equatable, Sendable {
    var received = 0
    var failedWrites = 0
    var deliveredToAnalyzer = 0
}

/// What the input tap writes to, called on the audio thread. A lock makes `close` (from the
/// pipeline) and `receive` exclusive, so no buffer is written to a closed file.
///
/// The recording and the analyzer feed are both mono: whatever the microphone delivers is averaged
/// to one channel at the buffer's sample rate first. The file keeps the rate it was opened with;
/// should the same microphone change its rate mid-recording, later buffers are resampled to it. A USB audio interface reported four channels
/// at 48 kHz, which the AAC encoder cannot write: every write failed.
final class RecordingTap: @unchecked Sendable {
    private struct State {
        var file: AVAudioFile?
        /// The mono format the file was opened with; later buffers of another rate are brought to it.
        let mono: AVAudioFormat
        let analyzerFormat: AVAudioFormat
        /// One converter per input sample rate, made when that rate first arrives.
        var toAnalyzer: [Double: AVAudioConverter] = [:]
        var toFile: [Double: AVAudioConverter] = [:]
        let input: AsyncStream<AnalyzerInput>.Continuation
        var stats = RecordingTapStats()
        /// Buffers in a row that could not be written.
        var failedRun = 0
    }

    /// This many buffers in a row (about a second of audio) make the recording a failed one.
    static let failedRunLimit = 10

    private let lock = NSLock()
    private var state: State
    private let onWriteFailure: @Sendable () -> Void

    private init(file: AVAudioFile, mono: AVAudioFormat, converter: AVAudioConverter, analyzerFormat: AVAudioFormat,
                 input: AsyncStream<AnalyzerInput>.Continuation, onWriteFailure: @escaping @Sendable () -> Void) {
        self.onWriteFailure = onWriteFailure
        state = State(file: file, mono: mono, analyzerFormat: analyzerFormat, input: input)
        state.toAnalyzer[mono.sampleRate] = converter
    }

    static func make(
        recordingTo url: URL, tapFormat: AVAudioFormat, analyzerFormat: AVAudioFormat,
        input: AsyncStream<AnalyzerInput>.Continuation,
        onWriteFailure: @escaping @Sendable () -> Void = {}
    ) throws -> RecordingTap {
        guard let mono = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: tapFormat.sampleRate, channels: 1, interleaved: false)
        else { throw VoiceEngineError.noAudioInput }
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: mono.sampleRate,
                AVNumberOfChannelsKey: 1,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false)
        guard let converter = AVAudioConverter(from: mono, to: analyzerFormat) else {
            throw VoiceEngineError.noAnalyzerFormat
        }
        return RecordingTap(
            file: file, mono: mono, converter: converter, analyzerFormat: analyzerFormat, input: input,
            onWriteFailure: onWriteFailure)
    }

    func receive(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let file = state.file else { return }
        state.stats.received += 1
        var written = false
        let mixed = mixToMono(buffer)
        if let mixed, let forFile = fileBuffer(from: mixed) {
            do {
                try file.write(from: forFile)
                written = true
            } catch {}
        }
        if written {
            state.failedRun = 0
        } else {
            state.stats.failedWrites += 1
            state.failedRun += 1
            if state.failedRun == Self.failedRunLimit { onWriteFailure() }
        }
        if let mixed, let converted = convert(mixed) {
            state.input.yield(AnalyzerInput(buffer: converted))
            state.stats.deliveredToAnalyzer += 1
        }
    }

    /// Closes the file (its header is written now) and ends the analyzer input. Idempotent.
    @discardableResult
    func close() -> RecordingTapStats {
        lock.lock()
        defer { lock.unlock() }
        guard let file = state.file else { return state.stats }
        file.close()
        state.file = nil
        state.input.finish()
        if state.stats.failedWrites > 0 {
            tapLogger.error("voice recording: \(self.state.stats.failedWrites, privacy: .public) buffers not written")
        }
        return state.stats
    }

    /// The channels averaged into one, at the buffer's own sample rate. Only 32-bit float input, which
    /// is what the input node delivers, can be mixed; anything else counts as a failed write.
    private func mixToMono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let channels = Int(buffer.format.channelCount)
        guard channels > 0, let source = buffer.floatChannelData,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate, channels: 1, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let target = out.floatChannelData?[0] else { return nil }
        let frames = Int(buffer.frameLength), stride = buffer.stride
        let scale = 1 / Float(channels)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels { sum += source[channel][frame * stride] }
            target[frame] = sum * scale
        }
        out.frameLength = buffer.frameLength
        return out
    }

    /// The mixed buffer in the file's format: as it is when the rate is the one the file was opened
    /// with, else resampled (the same device changed its format mid-recording).
    private func fileBuffer(from mixed: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let rate = mixed.format.sampleRate
        if rate == state.mono.sampleRate { return mixed }
        guard let converter = converter(for: rate, in: \.toFile, to: state.mono) else { return nil }
        return convert(mixed, with: converter, to: state.mono)
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let rate = buffer.format.sampleRate
        guard let converter = converter(for: rate, in: \.toAnalyzer, to: state.analyzerFormat) else { return nil }
        return convert(buffer, with: converter, to: state.analyzerFormat)
    }

    private func converter(
        for rate: Double, in table: WritableKeyPath<State, [Double: AVAudioConverter]>, to format: AVAudioFormat
    ) -> AVAudioConverter? {
        if let known = state[keyPath: table][rate] { return known }
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let made = AVAudioConverter(from: source, to: format) else { return nil }
        state[keyPath: table][rate] = made
        return made
    }

    private func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, out.frameLength > 0 else { return nil }
        return out
    }
}
