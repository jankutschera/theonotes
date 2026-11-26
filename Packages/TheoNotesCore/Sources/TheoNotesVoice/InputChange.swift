// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AVFoundation
import Foundation
#if os(macOS)
import AudioToolbox
import CoreAudio
#endif

/// The audio input a recording is bound to: its channel count, sample rate and, when it can be
/// read, the device's identity (its CoreAudio UID on the Mac, the route's port UID on iOS).
struct InputFormatSummary: Equatable, Sendable {
    var channels: UInt32
    var sampleRate: Double
    var device: String?

    init(channels: UInt32, sampleRate: Double, device: String? = nil) {
        self.channels = channels
        self.sampleRate = sampleRate
        self.device = device
    }
}

/// What to do when the audio engine reports a configuration change while recording.
enum InputChangeDecision: Equatable, Sendable {
    /// The input is the same and the engine still runs: nothing to do.
    case ignore
    /// The input is the same but the engine stopped itself: start it again.
    case restart
    /// The same device now delivers another format (a Bluetooth headset switching profile when the
    /// microphone opens): the tap is installed again in the new format and the recording goes on.
    case restartWithNewFormat
    /// The input is gone or different: the recording ends (the Stop path).
    case inputChanged
}

enum InputChange {
    /// A recording is written by one device; another device, or none, cannot continue it. The same
    /// format does not make the same microphone, so two devices that are both known and differ end
    /// the recording. The same known device with another format continues in the new
    /// format: headsets change profile and rate when the microphone opens. When either
    /// identity is unknown a changed format cannot be told from a changed device and ends it.
    static func decide(recording: InputFormatSummary, current: InputFormatSummary, engineIsRunning: Bool) -> InputChangeDecision {
        guard current.channels > 0, current.sampleRate > 0 else { return .inputChanged }
        if let was = recording.device, let now = current.device, was != now { return .inputChanged }
        if current.channels != recording.channels || current.sampleRate != recording.sampleRate {
            guard let was = recording.device, let now = current.device, was == now else { return .inputChanged }
            return .restartWithNewFormat
        }
        return engineIsRunning ? .ignore : .restart
    }
}

enum AudioInputIdentity {
    /// The identity of the device the engine records from now, or nil when it cannot be read.
    static func current(of engine: AVAudioEngine) -> String? {
        #if os(macOS)
        let bound = engine.inputNode.auAudioUnit.deviceID
        if bound != 0, let uid = uid(of: bound) { return uid }
        return defaultInputUID()
        #else
        return AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid
        #endif
    }

    #if os(macOS)
    private static func defaultInputUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        return uid(of: device)
    }

    private static func uid(of device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
    #endif
}
