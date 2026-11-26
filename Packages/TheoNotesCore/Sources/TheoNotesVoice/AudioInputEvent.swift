// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AVFoundation
import Foundation

/// Something that happened to the audio input while recording.
public enum AudioInputEvent: Equatable, Sendable {
    /// iOS: a call, Siri or another app took the audio session.
    case interruptionBegan
    case interruptionEnded
    /// The engine's input or output hardware changed (a headset or USB microphone came or went,
    /// the default input changed). The engine has stopped itself.
    case configurationChanged
    /// iOS: the input in use went away (`.oldDeviceUnavailable`, `.noSuitableRouteForCategory`).
    case routeLost

    /// The event a notification stands for, or nil. A route change for any other reason gives nil,
    /// because a newly connected device is caught by the engine's configuration change.
    public static func from(_ notification: Notification) -> AudioInputEvent? {
        if notification.name == .AVAudioEngineConfigurationChange { return .configurationChanged }
        #if os(iOS)
        let info = notification.userInfo ?? [:]
        if notification.name == AVAudioSession.interruptionNotification {
            guard let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return nil }
            switch type {
            case .began: return .interruptionBegan
            case .ended: return .interruptionEnded
            @unknown default: return nil
            }
        }
        if notification.name == AVAudioSession.routeChangeNotification {
            guard let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return nil }
            switch reason {
            case .oldDeviceUnavailable, .noSuitableRouteForCategory: return .routeLost
            default: return nil
            }
        }
        #endif
        return nil
    }
}

/// Turns the audio notifications into `AudioInputEvent`s. It observes the engine configuration
/// change (any engine) on both platforms and, on iOS, the audio session's interruption and route
/// change. `events` has one consumer; observing stops when the observer is released.
public final class AudioInputObserver: Sendable {
    public let events: AsyncStream<AudioInputEvent>
    private let center: NotificationCenter
    private let continuation: AsyncStream<AudioInputEvent>.Continuation
    /// Set in `init`, read only in `deinit`.
    nonisolated(unsafe) private let tokens: [any NSObjectProtocol]

    /// `engine` limits the configuration change to that engine's own; nil takes any engine's.
    public init(center: NotificationCenter = .default, engine: AVAudioEngine? = nil) {
        let (events, continuation) = AsyncStream.makeStream(of: AudioInputEvent.self)
        var names: [Notification.Name] = [.AVAudioEngineConfigurationChange]
        #if os(iOS)
        names += [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification]
        #endif
        self.center = center
        self.events = events
        self.continuation = continuation
        tokens = names.map { name in
            center.addObserver(forName: name, object: name == .AVAudioEngineConfigurationChange ? engine : nil, queue: nil) { notification in
                if let event = AudioInputEvent.from(notification) { continuation.yield(event) }
            }
        }
    }

    deinit {
        for token in tokens { center.removeObserver(token) }
        continuation.finish()
    }
}
