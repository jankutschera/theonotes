// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AVFoundation
import Foundation
import Testing
@testable import TheoNotesVoice

/// What a configuration change of the audio engine means for a running recording (FOC-R381): the
/// engine posts it for any change of its hardware, including ones that leave the microphone alone
/// (a Bluetooth headset switching profile on the output side). Only a changed input ends the note.
@Suite struct InputChangeTests {
    private let usb = InputFormatSummary(channels: 4, sampleRate: 48000)

    @Test func theSameInputThatKeepsRunningIsIgnored() {
        #expect(InputChange.decide(recording: usb, current: usb, engineIsRunning: true) == .ignore)
    }

    @Test func theSameInputWithAStoppedEngineIsRestarted() {
        #expect(InputChange.decide(recording: usb, current: usb, engineIsRunning: false) == .restart)
    }

    @Test func aDifferentInputEndsTheRecording() {
        let bluetooth = InputFormatSummary(channels: 1, sampleRate: 16000)
        #expect(InputChange.decide(recording: usb, current: bluetooth, engineIsRunning: true) == .inputChanged)
        #expect(InputChange.decide(recording: usb, current: bluetooth, engineIsRunning: false) == .inputChanged)
        let otherRate = InputFormatSummary(channels: 4, sampleRate: 44100)
        #expect(InputChange.decide(recording: usb, current: otherRate, engineIsRunning: true) == .inputChanged)
    }

    @Test func noInputAtAllEndsTheRecording() {
        let none = InputFormatSummary(channels: 0, sampleRate: 0)
        #expect(InputChange.decide(recording: usb, current: none, engineIsRunning: false) == .inputChanged)
    }

    /// Two USB interfaces, or a headset and the built-in mic, can share a channel count and rate
    /// (FOC-R384): the notice is for the device, not the format.
    @Test func aDifferentDeviceWithTheSameFormatEndsTheRecording() {
        let builtIn = InputFormatSummary(channels: 1, sampleRate: 48000, device: "BuiltInMicrophoneDevice")
        let headset = InputFormatSummary(channels: 1, sampleRate: 48000, device: "AA-BB-CC-DD-EE-FF:input")
        #expect(InputChange.decide(recording: builtIn, current: headset, engineIsRunning: true) == .inputChanged)
        #expect(InputChange.decide(recording: builtIn, current: headset, engineIsRunning: false) == .inputChanged)
        #expect(InputChange.decide(recording: builtIn, current: builtIn, engineIsRunning: true) == .ignore)
        #expect(InputChange.decide(recording: builtIn, current: builtIn, engineIsRunning: false) == .restart)
    }

    /// K5 (FOC-R393): a Bluetooth headset switches its profile and format when the microphone opens.
    /// The same device with a new format goes on in the new format; another device still stops.
    @Test func theSameDeviceWithANewFormatContinuesInTheNewFormat() {
        let uid = "AA-BB-CC-DD-EE-FF:input"
        let before = InputFormatSummary(channels: 1, sampleRate: 24000, device: uid)
        let after = InputFormatSummary(channels: 1, sampleRate: 16000, device: uid)
        #expect(InputChange.decide(recording: before, current: after, engineIsRunning: false) == .restartWithNewFormat)
        #expect(InputChange.decide(recording: before, current: after, engineIsRunning: true) == .restartWithNewFormat)
        let moreChannels = InputFormatSummary(channels: 2, sampleRate: 24000, device: uid)
        #expect(InputChange.decide(recording: before, current: moreChannels, engineIsRunning: false) == .restartWithNewFormat)
    }

    @Test func aDifferentDeviceWithANewFormatStillEndsTheRecording() {
        let before = InputFormatSummary(channels: 1, sampleRate: 24000, device: "AA-BB-CC-DD-EE-FF:input")
        let other = InputFormatSummary(channels: 1, sampleRate: 16000, device: "BuiltInMicrophoneDevice")
        #expect(InputChange.decide(recording: before, current: other, engineIsRunning: false) == .inputChanged)
        #expect(InputChange.decide(recording: before, current: other, engineIsRunning: true) == .inputChanged)
    }

    @Test func aNewFormatWithoutAKnownDeviceStillEndsTheRecording() {
        let known = InputFormatSummary(channels: 1, sampleRate: 24000, device: "AA-BB-CC-DD-EE-FF:input")
        let unknown = InputFormatSummary(channels: 1, sampleRate: 16000, device: nil)
        #expect(InputChange.decide(recording: known, current: unknown, engineIsRunning: false) == .inputChanged)
        #expect(InputChange.decide(recording: unknown, current: known, engineIsRunning: false) == .inputChanged)
    }

    @Test func noInputAtAllStillEndsTheRecordingOnTheSameDevice() {
        let uid = "AA-BB-CC-DD-EE-FF:input"
        let before = InputFormatSummary(channels: 1, sampleRate: 24000, device: uid)
        let none = InputFormatSummary(channels: 0, sampleRate: 0, device: uid)
        #expect(InputChange.decide(recording: before, current: none, engineIsRunning: false) == .inputChanged)
    }

    @Test func anUnknownDeviceFallsBackToTheFormat() {
        let known = InputFormatSummary(channels: 1, sampleRate: 48000, device: "BuiltInMicrophoneDevice")
        let unknown = InputFormatSummary(channels: 1, sampleRate: 48000, device: nil)
        #expect(InputChange.decide(recording: known, current: unknown, engineIsRunning: true) == .ignore)
        #expect(InputChange.decide(recording: unknown, current: known, engineIsRunning: false) == .restart)
    }

    @Test func aChangeOfAnotherEngineIsNotOurs() async {
        let center = NotificationCenter()
        let ours = AVAudioEngine(), other = AVAudioEngine()
        let observer = AudioInputObserver(center: center, engine: ours)
        center.post(name: .AVAudioEngineConfigurationChange, object: other)
        center.post(name: .AVAudioEngineConfigurationChange, object: ours)
        let tally = Tally()
        let events = observer.events
        let counter = Task { for await _ in events { tally.bump() } }
        try? await Task.sleep(for: .milliseconds(300))
        counter.cancel()
        #expect(tally.count == 1, "only the notification of our engine counts")
    }
}

private final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
