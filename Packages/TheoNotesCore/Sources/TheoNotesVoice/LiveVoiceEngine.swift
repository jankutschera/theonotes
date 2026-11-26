// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AVFoundation
import Foundation
import os
import Speech
import Synchronization

private let engineLogger = Logger(subsystem: "com.truebrewbirdie.baerchen", category: "voice")

public enum VoiceEngineError: Error, Equatable, Sendable {
    /// On-device transcription is not available on this device.
    case unavailable
    case unsupportedLocale
    /// The speech model is not installed. The engine never downloads it: that needs the user's OK
    /// first (`VoicePreflight`).
    case modelNotInstalled(Locale)
    /// There is no usable audio input (no microphone, or a format of zero channels or rate).
    case noAudioInput
    case noAnalyzerFormat
    case alreadyRunning
    /// The recording file could not be written (the microphone's format, a full disk).
    case recordingFailed
}

/// The device engine: an `AVAudioEngine` input tap writes the microphone to an AAC
/// `.m4a` file and, converted by `AVAudioConverter` to the analyzer's
/// `bestAvailableAudioFormat`, feeds `AnalyzerInput(buffer:)` to a `SpeechAnalyzer` with a
/// `SpeechTranscriber(locale:preset: .progressiveTranscription)`. Everything runs on the device.
///
/// It reports `AudioInputObserver`'s route loss and configuration change as `.inputChanged` and an
/// interruption as `.interrupted`. It uses only macOS/iOS 26 API (no `AnalyzerInputConverter` or
/// `CaptureInputSequenceProvider`).
public final class LiveVoiceEngine: VoiceEngine {
    private let pipeline: Pipeline

    public init(locale: Locale = .current) {
        pipeline = Pipeline(locale: locale)
    }

    public func start(recordingTo url: URL) async throws -> AsyncThrowingStream<VoiceEvent, any Error> {
        try await pipeline.start(recordingTo: url)
    }

    public func finish() async throws {
        try await pipeline.finish()
    }

    public func cancel() async {
        await pipeline.cancel()
    }
}

private actor Pipeline {
    let locale: Locale
    private var audioEngine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var sink: RecordingTap?
    private var output: AsyncThrowingStream<VoiceEvent, any Error>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    /// Teardown runs each step once, whichever of a failed start, `finish` and `cancel` gets there.
    private var tapInstalled = false
    private var inputStopped = true
    private var running = false
    /// The input the recording is bound to; it moves to the new format when the same device changes it.
    private var recorded = InputFormatSummary(channels: 0, sampleRate: 0)

    init(locale: Locale) {
        self.locale = locale
    }

    func start(recordingTo url: URL) async throws -> AsyncThrowingStream<VoiceEvent, any Error> {
        guard !running else { throw VoiceEngineError.alreadyRunning }
        guard SpeechTranscriber.isAvailable else { throw VoiceEngineError.unavailable }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw VoiceEngineError.unsupportedLocale
        }
        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        guard await LiveVoicePreflight.isInstalled(supported) else {
            throw VoiceEngineError.modelNotInstalled(supported)
        }
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw VoiceEngineError.noAnalyzerFormat
        }

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        #endif

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let tapFormat = input.outputFormat(forBus: 0)
        engineLogger.info("voice: input format \(tapFormat.channelCount, privacy: .public) ch, \(tapFormat.sampleRate, privacy: .public) Hz; analyzer \(analyzerFormat.channelCount, privacy: .public) ch, \(analyzerFormat.sampleRate, privacy: .public) Hz")
        guard tapFormat.sampleRate > 0, tapFormat.channelCount > 0 else {
            deactivateSession()
            throw VoiceEngineError.noAudioInput
        }
        let (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let (events, output) = AsyncThrowingStream.makeStream(of: VoiceEvent.self)
        let sink: RecordingTap
        do {
            // A recording that cannot be written ends the stream with its own error: it is not a
            // microphone change.
            sink = try RecordingTap.make(
                recordingTo: url, tapFormat: tapFormat, analyzerFormat: analyzerFormat, input: inputBuilder,
                onWriteFailure: { output.finish(throwing: VoiceEngineError.recordingFailed) })
        } catch {
            deactivateSession()
            throw error
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    output.yield(.transcript(TranscriptUpdate(text: String(result.text.characters), isFinal: result.isFinal)))
                }
                output.finish()
            } catch {
                output.finish(throwing: error)
            }
        }
        // Only this engine's configuration change counts.
        let observer = AudioInputObserver(engine: engine)
        recorded = InputFormatSummary(
            channels: tapFormat.channelCount, sampleRate: tapFormat.sampleRate, device: AudioInputIdentity.current(of: engine))
        inputTask = Task {
            for await event in observer.events {
                engineLogger.info("voice: input event \(String(describing: event), privacy: .public)")
                switch event {
                case .routeLost: output.yield(.inputChanged)
                case .configurationChanged:
                    if !keepsRecording(after: engine, sink: sink) { output.yield(.inputChanged) }
                case .interruptionBegan: output.yield(.interrupted)
                case .interruptionEnded: break
                }
            }
        }

        audioEngine = engine
        self.analyzer = analyzer
        self.sink = sink
        self.output = output
        running = true
        inputStopped = false
        do {
            try await analyzer.start(inputSequence: inputSequence)
            input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, _ in
                sink.receive(buffer)
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
        } catch {
            // The same single teardown as `cancel`: the tap is removed only if it was installed.
            await cancel()
            throw error
        }
        return events
    }

    /// Stops the input, delivers the remaining results, then tears down. It tears down even when
    /// finalizing throws, so the event stream always ends.
    func finish() async throws {
        guard running, let analyzer else { return }
        stopInput()
        defer { tearDown() }
        // The input sequence has ended: finalize the remaining results and end the session.
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
    }

    func cancel() async {
        guard running, let analyzer else { return }
        stopInput()
        await analyzer.cancelAndFinishNow()
        tearDown()
    }

    /// The engine reported a configuration change. It can come from the output side (a Bluetooth
    /// headset switching profile) and leave the microphone as it was: then the recording goes on,
    /// and an engine that stopped itself is started again. A different or missing input ends it.
    private func keepsRecording(after engine: AVAudioEngine, sink: RecordingTap) -> Bool {
        guard running, !inputStopped else { return true }
        let format = engine.inputNode.outputFormat(forBus: 0)
        let current = InputFormatSummary(
            channels: format.channelCount, sampleRate: format.sampleRate, device: AudioInputIdentity.current(of: engine))
        switch InputChange.decide(recording: recorded, current: current, engineIsRunning: engine.isRunning) {
        case .ignore:
            return true
        case .restart:
            do {
                engine.prepare()
                try engine.start()
                engineLogger.info("voice: the engine was started again after a configuration change")
                return true
            } catch {
                engineLogger.error("voice: the engine could not be started again")
                return false
            }
        case .restartWithNewFormat:
            // The same microphone in another format: the tap is installed again in it, and the tap
            // brings the new buffers to the format the recording was opened with.
            let input = engine.inputNode
            if tapInstalled { input.removeTap(onBus: 0) }
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
                sink.receive(buffer)
            }
            tapInstalled = true
            do {
                engine.prepare()
                try engine.start()
            } catch {
                engineLogger.error("voice: the engine could not be started in the new input format")
                return false
            }
            engineLogger.info("voice: the same input changed format to \(format.channelCount, privacy: .public) ch, \(format.sampleRate, privacy: .public) Hz; recording goes on")
            recorded = current
            return true
        case .inputChanged:
            return false
        }
    }

    /// Stops the microphone and closes the recording and the analyzer input, once.
    private func stopInput() {
        guard !inputStopped else { return }
        inputStopped = true
        audioEngine?.stop()
        if tapInstalled {
            audioEngine?.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        sink?.close()
    }

    /// Ends the event stream and releases everything, once.
    private func tearDown() {
        guard running else { return }
        running = false
        stopTasks()
        output?.finish()
        output = nil
        audioEngine = nil
        analyzer = nil
        sink = nil
        deactivateSession()
    }

    private func stopTasks() {
        resultsTask?.cancel()
        inputTask?.cancel()
        resultsTask = nil
        inputTask = nil
    }

    private func deactivateSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
