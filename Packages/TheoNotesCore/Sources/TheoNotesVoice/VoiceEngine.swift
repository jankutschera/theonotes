// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// One transcription result. Volatile results (`isFinal == false`) are replaced by the next
/// result; a final one is never revised.
public struct TranscriptUpdate: Equatable, Sendable {
    public let text: String
    public let isFinal: Bool

    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}

/// What an engine reports while it listens.
public enum VoiceEvent: Equatable, Sendable {
    case transcript(TranscriptUpdate)
    /// The audio session was interrupted (a call, Siri, another app took the input).
    case interrupted
    /// The input changed under the recording (route lost, headset, default input).
    case inputChanged
}

/// Records the microphone to a file and transcribes it on the device. `VoiceCapture` drives it;
/// tests use a scripted fake.
///
/// - `start` begins recording to `url` and returns the event stream.
/// - `finish` stops the input, delivers the remaining final results and then ends the stream.
/// - `cancel` stops everything and ends the stream without waiting for results.
/// The stream ends with an error when the engine fails.
public protocol VoiceEngine: AnyObject, Sendable {
    func start(recordingTo url: URL) async throws -> AsyncThrowingStream<VoiceEvent, any Error>
    func finish() async throws
    func cancel() async
    func isRecordingReadable(at url: URL) -> Bool
}

extension VoiceEngine {
    public func isRecordingReadable(at url: URL) -> Bool { VoiceRecordingRecovery.isPlayable(url) }
}
