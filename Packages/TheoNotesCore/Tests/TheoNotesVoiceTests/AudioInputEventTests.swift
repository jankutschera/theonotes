// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AVFoundation
import Foundation
import Testing
@testable import TheoNotesVoice

/// The first event, or nil after two seconds (so a missing event fails instead of hanging).
private func firstEvent(_ events: AsyncStream<AudioInputEvent>) async -> AudioInputEvent? {
    await withTaskGroup(of: AudioInputEvent?.self) { group in
        group.addTask {
            for await event in events { return event }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(2))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

@Suite struct AudioInputEventTests {
    @Test func mapsInterruptionAndConfigurationNotifications() {
        // Both platforms: the engine's configuration change (headset, USB microphone, default input).
        #expect(AudioInputEvent.from(Notification(name: .AVAudioEngineConfigurationChange)) == .configurationChanged)
        #expect(AudioInputEvent.from(Notification(name: .AVAudioEngineConfigurationChange, object: AVAudioEngine()))
            == .configurationChanged)

        #if os(iOS)
        func interruption(_ type: AVAudioSession.InterruptionType?) -> Notification {
            Notification(name: AVAudioSession.interruptionNotification, object: nil,
                         userInfo: type.map { [AVAudioSessionInterruptionTypeKey: $0.rawValue] })
        }
        #expect(AudioInputEvent.from(interruption(.began)) == .interruptionBegan)
        #expect(AudioInputEvent.from(interruption(.ended)) == .interruptionEnded)
        #expect(AudioInputEvent.from(interruption(nil)) == nil)
        #else
        // macOS has no audio session: its notification names mean nothing here.
        #expect(AudioInputEvent.from(Notification(name: Notification.Name("AVAudioSessionInterruptionNotification"),
                                                  userInfo: ["AVAudioSessionInterruptionTypeKey": UInt(1)])) == nil)
        #endif

        // Anything else gives nil.
        #expect(AudioInputEvent.from(Notification(name: Notification.Name("SomethingElse"))) == nil)
        #expect(AudioInputEvent.from(Notification(name: NSNotification.Name.NSSystemClockDidChange)) == nil)
    }

    @Test func observerDeliversAPostedConfigurationChange() async {
        let center = NotificationCenter()
        let observer = AudioInputObserver(center: center)
        center.post(name: Notification.Name("SomethingElse"), object: nil)
        center.post(name: .AVAudioEngineConfigurationChange, object: nil)
        #expect(await firstEvent(observer.events) == .configurationChanged)
    }

    #if os(iOS)
    @Test func mapsRouteLossOnIOS() {
        func routeChange(_ reason: AVAudioSession.RouteChangeReason) -> Notification {
            Notification(name: AVAudioSession.routeChangeNotification, object: nil,
                         userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue])
        }
        #expect(AudioInputEvent.from(routeChange(.oldDeviceUnavailable)) == .routeLost)
        #expect(AudioInputEvent.from(routeChange(.noSuitableRouteForCategory)) == .routeLost)
        // A new device is caught by the engine's configuration change instead.
        #expect(AudioInputEvent.from(routeChange(.newDeviceAvailable)) == nil)
        #expect(AudioInputEvent.from(routeChange(.categoryChange)) == nil)
        #expect(AudioInputEvent.from(Notification(name: AVAudioSession.routeChangeNotification)) == nil)
    }

    @Test func observerDeliversAPostedRouteChange() async {
        let center = NotificationCenter()
        let observer = AudioInputObserver(center: center)
        center.post(name: AVAudioSession.routeChangeNotification, object: nil,
                    userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue])
        center.post(name: AVAudioSession.routeChangeNotification, object: nil,
                    userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        #expect(await firstEvent(observer.events) == .routeLost)
    }
    #endif
}
