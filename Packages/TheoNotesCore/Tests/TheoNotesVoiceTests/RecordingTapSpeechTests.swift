// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AVFoundation
import Foundation
import Speech
import Testing
@testable import TheoNotesVoice

/// Speech through the real analyzer: a spoken sentence, played to the tap as a four-channel 48 kHz
/// input (the format K4 met), must come out as text (FOC-R380). It needs the English speech model
/// installed and `say`; without them the test returns without checking (the live engine check
/// in the task report covers the microphone itself).
@Suite struct RecordingTapSpeechTests {
    @Test func aFourChannelInputIsTranscribed() async throws {
        let locale = Locale(identifier: "en-US")
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale),
              await LiveVoicePreflight.isInstalled(supported) else { return }
        let spoken = FileManager.default.temporaryDirectory.appendingPathComponent("tap-say-\(UUID().uuidString).caf")
        let recording = FileManager.default.temporaryDirectory.appendingPathComponent("tap-say-\(UUID().uuidString).m4a")
        defer {
            try? FileManager.default.removeItem(at: spoken)
            try? FileManager.default.removeItem(at: recording)
        }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Samantha", "-o", spoken.path, "--data-format=LEF32@48000", "this is a voice test one two three"]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0, let source = try? AVAudioFile(forReading: spoken) else { return }

        let transcriber = SpeechTranscriber(locale: supported, preset: .transcription)
        let analyzerFormat = try #require(await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]))
        let (sequence, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4))
        let fourChannels = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, interleaved: false, channelLayout: layout)
        let tap = try RecordingTap.make(
            recordingTo: recording, tapFormat: fourChannels, analyzerFormat: analyzerFormat, input: continuation)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collected = Task {
            var text = ""
            for try await result in transcriber.results where result.isFinal { text += " " + String(result.text.characters) }
            return text
        }
        try await analyzer.start(inputSequence: sequence)

        let mono = try #require(AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 4096))
        while source.framePosition < source.length {
            try source.read(into: mono, frameCount: 4096)
            guard mono.frameLength > 0, let four = AVAudioPCMBuffer(pcmFormat: fourChannels, frameCapacity: mono.frameLength) else { break }
            four.frameLength = mono.frameLength
            for channel in 0..<4 {
                four.floatChannelData![channel].update(from: mono.floatChannelData![0], count: Int(mono.frameLength))
            }
            tap.receive(four)
        }
        let stats = tap.close()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let text = try await collected.value.lowercased()

        #expect(stats.failedWrites == 0)
        #expect(stats.deliveredToAnalyzer > 0)
        #expect(text.contains("voice test"), "heard: \(text)")
        #expect((try? AVAudioFile(forReading: recording))?.length ?? 0 > 0, "the recording has audio")
    }
}
