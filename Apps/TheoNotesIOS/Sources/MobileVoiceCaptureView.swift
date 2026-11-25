// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import SwiftUI
import UIKit

/// Presented by the shared capture route; the model owns all recorder and teardown work.
struct MobileVoiceCaptureView: View {
    @Bindable var model: MobileVoiceCaptureModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingCancellation = false
    var body: some View {
        VStack(spacing: 20) {
                HStack {
                    Text("Voice Note").font(.headline).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button(model.state == .downloading ? "Cancel Download" : model.isBusy ? "Cancel Recording" : "Close") {
                        if model.isBusy {
                            if model.requiresCancelConfirmation { confirmingCancellation = true }
                            else { Task { if await model.cancel() { dismiss() } } }
                        } else { Task { await model.finishForDismissal(); dismiss() } }
                    }
                }
                Image(systemName: model.state == .listening ? "waveform" : "mic")
                    .font(.largeTitle).accessibilityHidden(true)
                status
                if !model.library.appLocked && !model.transcript.isEmpty {
                    ScrollView { Text(model.transcript).frame(maxWidth: .infinity, alignment: .leading) }
                        .accessibilityLabel("Transcript")
                }
                Spacer()
                switch model.state {
                case .needsModel(let locale):
                    Text("Download Apple's on-device speech model for \(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)?")
                    Button("Download Model") { model.answerModelDownload(true) }.buttonStyle(.borderedProminent)
                    Button("Not Now") { model.answerModelDownload(false); dismiss() }
                case .listening:
                    Button("Stop Recording") { Task { await model.stop() } }.buttonStyle(.borderedProminent)
                case .preparing, .downloading, .finishing:
                    ProgressView()
                case .permissionDenied:
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                case .finished, .interrupted, .failed, .idle:
                    Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
                }
        }
        .padding()
        .confirmationDialog("Discard this recording?", isPresented: $confirmingCancellation, titleVisibility: .visible) {
            Button("Discard Recording", role: .destructive) { Task { if await model.cancel() { dismiss() } } }
            Button("Keep Recording", role: .cancel) {}
        } message: {
            Text("The recording and its captured text will be discarded. Use Stop Recording to save them.")
        }
        .alert("Recording Kept", isPresented: Binding(get: { model.cancellationError != nil && !model.library.appLocked },
            set: { if !$0 { model.clearCancellationError() } })) {
            Button("OK") { model.clearCancellationError() }
        } message: { Text(model.cancellationError ?? "") }
        .onChange(of: model.library.appLocked) { _, locked in if locked { confirmingCancellation = false } }
        .onChange(of: model.isBusy) { _, busy in if !busy { confirmingCancellation = false } }
        .interactiveDismissDisabled(model.isBusy)
        .task { await model.begin() }
    }

    @ViewBuilder private var status: some View {
        switch model.state {
        case .idle: Text("Ready for a voice note.")
        case .preparing: Text("Preparing voice capture…")
        case .needsModel: Text("Speech Model Required").font(.headline)
        case .downloading: Text("Downloading speech model…")
        case .listening: Text("Recording on this device").font(.headline)
        case .finishing: Text("Saving your voice note…")
        case .finished: Text("Voice note saved.")
        case .interrupted: Text("Recording stopped because the microphone changed or was interrupted. Text and audio have been kept.")
        case .permissionDenied: Text("Allow microphone access in Settings to record a voice note.")
        case .failed(let message): Text(message)
        }
    }
}
