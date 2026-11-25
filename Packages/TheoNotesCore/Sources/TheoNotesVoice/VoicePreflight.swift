// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AVFoundation
import Foundation
import Speech

/// Whether a voice note can start for a locale.
public enum VoiceAvailability: Equatable, Sendable {
    case ready
    /// The on-device speech model for this (supported) locale is not installed. Downloading it
    /// needs the user's OK (FOC-R9).
    case needsModelDownload(Locale)
    case unsupportedLocale
    /// On-device transcription is not available on this device.
    case unavailable
    case microphoneDenied
}

/// The questions asked before a voice note starts. There is deliberately no speech-recognition
/// authorization here: on-device transcription needs the microphone only (FOC-R9).
public protocol VoicePreflighting: Sendable {
    /// Never prompts and never touches the network.
    func availability(locale: Locale) async -> VoiceAvailability
    /// Shows the system's microphone prompt the first time; afterwards answers at once.
    func requestMicrophone() async -> Bool
    /// Downloads and installs the speech model for `locale` from Apple. Only after the user's OK.
    func downloadModel(locale: Locale) async throws
}

public enum VoicePreflight {
    /// The checks in order: the microphone first (denied: nothing else is asked); then
    /// availability; a missing model calls `askToDownload`, and only a yes downloads it (then the
    /// availability is checked again). Not Now returns `.needsModelDownload` with no network call.
    public static func check(
        locale: Locale,
        using preflight: any VoicePreflighting,
        askToDownload: (Locale) async -> Bool
    ) async throws -> VoiceAvailability {
        guard await preflight.requestMicrophone() else { return .microphoneDenied }
        let availability = await preflight.availability(locale: locale)
        guard case .needsModelDownload(let modelLocale) = availability else { return availability }
        guard await askToDownload(modelLocale) else { return availability }
        try await preflight.downloadModel(locale: modelLocale)
        return await preflight.availability(locale: locale)
    }
}

/// The device's answers: `SpeechTranscriber` and `AssetInventory` for the model, the microphone
/// permission of the platform. No `SFSpeechRecognizer`.
public struct LiveVoicePreflight: VoicePreflighting {
    public init() {}

    public func availability(locale: Locale) async -> VoiceAvailability {
        if Self.microphoneDenied { return .microphoneDenied }
        guard SpeechTranscriber.isAvailable else { return .unavailable }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return .unsupportedLocale }
        // A model the system already has counts, even when this app never reserved it:
        // `AssetInventory.status` then says `.supported`, yet transcription works offline.
        if await Self.isInstalled(supported) { return .ready }
        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed: return .ready
        case .supported, .downloading: return .needsModelDownload(supported)
        case .unsupported: return .unsupportedLocale
        @unknown default: return .unavailable
        }
    }

    public func requestMicrophone() async -> Bool {
        #if os(iOS)
        await AVAudioApplication.requestRecordPermission()
        #else
        await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }

    public func downloadModel(locale: Locale) async throws {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return }
        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    /// Whether `SpeechTranscriber.installedLocales` holds `locale` (no network, no reservation).
    static func isInstalled(_ locale: Locale) async -> Bool {
        let wanted = locale.identifier(.bcp47)
        return await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == wanted }
    }

    /// Already refused (no prompt is shown for this check).
    private static var microphoneDenied: Bool {
        #if os(iOS)
        AVAudioApplication.shared.recordPermission == .denied
        #else
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted: true
        default: false
        }
        #endif
    }
}
