// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Synchronization
import Testing
@testable import TheoNotesVoice

/// Records every question asked. `VoicePreflighting` has no speech-authorization member, so a
/// legacy speech prompt cannot even be recorded (microphone only).
final class FakePreflight: VoicePreflighting {
    enum Call: Equatable, Sendable { case availability(Locale), requestMicrophone, downloadModel(Locale) }

    private let calls_ = Mutex<[Call]>([])
    private let availabilities: Mutex<[VoiceAvailability]>
    let microphone: Bool

    init(microphone: Bool, availabilities: [VoiceAvailability]) {
        self.microphone = microphone
        self.availabilities = Mutex(availabilities)
    }

    var calls: [Call] { calls_.withLock { $0 } }

    func availability(locale: Locale) async -> VoiceAvailability {
        calls_.withLock { $0.append(.availability(locale)) }
        return availabilities.withLock { $0.count > 1 ? $0.removeFirst() : $0.first ?? .unavailable }
    }

    func requestMicrophone() async -> Bool {
        calls_.withLock { $0.append(.requestMicrophone) }
        return microphone
    }

    func downloadModel(locale: Locale) async throws {
        calls_.withLock { $0.append(.downloadModel(locale)) }
    }
}

@Suite struct VoicePreflightTests {
    private let german = Locale(identifier: "de_DE")

    @Test func missingModelNeverDownloadsWithoutConsent() async throws {
        // Not Now: no download is started, and the answer stays "needs the model".
        let declined = FakePreflight(microphone: true, availabilities: [.needsModelDownload(german)])
        let asked = Mutex<[Locale]>([])
        let result = try await VoicePreflight.check(locale: german, using: declined) { locale in
            asked.withLock { $0.append(locale) }
            return false
        }
        #expect(result == .needsModelDownload(german))
        #expect(asked.withLock { $0 } == [german])
        #expect(!declined.calls.contains(.downloadModel(german)))
        #expect(declined.calls == [.requestMicrophone, .availability(german)])

        // Download: exactly one download, then the check is repeated.
        let accepted = FakePreflight(microphone: true, availabilities: [.needsModelDownload(german), .ready])
        let ready = try await VoicePreflight.check(locale: german, using: accepted) { _ in true }
        #expect(ready == .ready)
        #expect(accepted.calls == [.requestMicrophone, .availability(german), .downloadModel(german), .availability(german)])

        // A model that is there asks nothing.
        let installed = FakePreflight(microphone: true, availabilities: [.ready])
        let none = Mutex(0)
        #expect(try await VoicePreflight.check(locale: german, using: installed) { _ in
            none.withLock { $0 += 1 }
            return true
        } == .ready)
        #expect(none.withLock { $0 } == 0)
        #expect(!installed.calls.contains(.downloadModel(german)))
    }

    @Test func deniedMicrophoneIsReportedAndNothingElseIsAsked() async throws {
        let preflight = FakePreflight(microphone: false, availabilities: [.needsModelDownload(german)])
        let asked = Mutex(0)

        let result = try await VoicePreflight.check(locale: german, using: preflight) { _ in
            asked.withLock { $0 += 1 }
            return true
        }

        #expect(result == .microphoneDenied)
        #expect(preflight.calls == [.requestMicrophone])
        #expect(asked.withLock { $0 } == 0)
    }
}
