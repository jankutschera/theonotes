// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AVFoundation
import TheoNotesCore
import CoreImage.CIFilterBuiltins
import SwiftUI
import VisionKit

struct MobilePairingWords: View {
    let phrase: String
    @Environment(\.scenePhase) private var phase
    var body: some View {
        Text(phase == .active ? phrase : "Verification words hidden").font(.title2.monospaced()).textSelection(.enabled)
            .padding(.vertical).privacySensitive()
            .accessibilityLabel(phase == .active ? "Verification words: " + phrase : "Verification words hidden")
    }
}

struct MobilePairingReceiver: View {
    @Bindable var sync: MobileSyncController
    @State private var matched = false
    @Environment(\.scenePhase) private var phase
    var body: some View {
        Section("Approve on Your Other Device") {
            if let pending = sync.pendingPairing {
                Text("Compare all six words with the sending device. Continue only if every word matches in the same order.")
                MobilePairingWords(phrase: pending.verificationWords)
                Toggle("All six words match", isOn: $matched)
                Button("Unlock Sync on This Device") { Task { await sync.confirmPairing() } }
                    .disabled(!matched || sync.busy)
            } else if let invitation = sync.receivingInvitation,
                      let code = try? invitation.qrPayload(endpoint: MobileSyncController.endpoint) {
                Text("Open Theo Notes → Sync on a device that already has your notes. Compare all six words on both devices, then approve sending the sync key on your connected device.")
                if let words = sync.receivingVerificationWords {
                    MobilePairingWords(phrase: words)
                    Text("Compare all six words in the same order on your other device. Confirm the match there to send your sync key. If any word differs, cancel pairing.")
                }
                Label("Waiting for approval", systemImage: "clock")
                DisclosureGroup("Other connection options") {
                    if phase == .active {
                        if let image = qrImage(code) {
                            Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                                .frame(maxWidth: 320).padding(16).background(.white)
                                .accessibilityLabel("Pairing QR code. You can also copy the pairing code below.")
                        }
                        ShareLink("Share Pairing Code", item: code)
                        Button("Copy Pairing Code") { UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: code]], options: [.localOnly: true, .expirationDate: invitation.expiration]) }
                        Text("Expires " + invitation.expiration.formatted(date: .omitted, time: .shortened))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Open Theo Notes → Sync on a device that already has your notes. Compare all six words on both devices, then approve sending the sync key on your connected device.")
                Button("Request Approval Again") { Task { await sync.restartReceiving() } }.disabled(sync.busy)
            }
            if sync.receivingInvitation != nil || sync.pendingPairing != nil {
                Button("Cancel Pairing", role: .cancel) { matched = false; Task { await sync.cancelPairing() } }.disabled(sync.busy)
            }
        }
        .onChange(of: sync.pendingPairing?.transferID) { _, _ in matched = false }
        .onChange(of: phase) { _, value in if value != .active { matched = false } }
    }
    private func qrImage(_ value: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}

struct MobilePairingSender: View {
    @Bindable var sync: MobileSyncController
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @Environment(\.scenePhase) private var phase
    @State private var scanning = false
    @State private var cameraError: String?
    var body: some View {
        NavigationStack {
            Form {
                if sync.senderVerificationWords == nil { MobilePairingRequests(sync: sync) }
                if let words = sync.senderVerificationWords {
                    Section("Compare Both Devices") {
                        MobileSendingConfirmation(sync: sync, words: words)
                    }
                } else {
                    Section {
                        Text("On the new device, sign in with your passkey. Its request appears in Sync on this device. Compare all six words, then approve sending the sync key there.")
                        DisclosureGroup("Other connection options") {
                            if phase == .active {
                                Button("Scan Pairing QR Code", systemImage: "qrcode.viewfinder") {
                                    Task {
                                        guard DataScannerViewController.isSupported,
                                              await AVCaptureDevice.requestAccess(for: .video),
                                              DataScannerViewController.isAvailable else {
                                            cameraError = "Camera scanning is unavailable. Paste the pairing code below, or allow camera access in Settings."
                                            return
                                        }
                                        scanning = true
                                    }
                                }
                                TextField("Or paste pairing code", text: $code, axis: .vertical)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                Button("Send Sync Key") { Task { await sync.sendPairingKey(code: code) } }
                                    .disabled(code.isEmpty || sync.busy)
                                if sync.busy { ProgressView() }
                                if let error = sync.errorMessage { Text(error).foregroundStyle(.red) }
                                if let cameraError { Text(cameraError).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Connect Another Device")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(sync.busy) } }
            .sheet(isPresented: $scanning) {
                NavigationStack {
                    PairingScanner { result in
                        scanning = false
                        switch result {
                        case .success(let value): code = value
                        case .failure(let error): cameraError = error.localizedDescription
                        }
                    }
                    .navigationTitle("Scan Pairing Code")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scanning = false } } }
                }
            }
        }
        .interactiveDismissDisabled(sync.busy)
        .onChange(of: phase) { _, value in
                if value != .active { code = ""; scanning = false }
            }
            .onDisappear { code = ""; sync.clearSenderWords() }
    }
}

private struct PairingScanner: UIViewControllerRepresentable {
    let completion: (Result<String, Error>) -> Void
    func makeUIViewController(context: Context) -> ScannerHost { ScannerHost(completion: completion) }
    func updateUIViewController(_ controller: ScannerHost, context: Context) {}

    final class ScannerHost: UIViewController, DataScannerViewControllerDelegate {
        private let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
            recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        private let completion: (Result<String, Error>) -> Void
        private var delivered = false
        init(completion: @escaping (Result<String, Error>) -> Void) {
            self.completion = completion
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidLoad() {
            super.viewDidLoad()
            scanner.delegate = self
            addChild(scanner); view.addSubview(scanner.view)
            scanner.view.frame = view.bounds; scanner.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            scanner.didMove(toParent: self)
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            do { try scanner.startScanning() } catch { finish(.failure(error)) }
        }
        override func viewWillDisappear(_ animated: Bool) {
            scanner.stopScanning(); super.viewWillDisappear(animated)
        }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let barcode) in addedItems {
                if let value = barcode.payloadStringValue { finish(.success(value)); return }
            }
        }
        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) { finish(.failure(error)) }
        private func finish(_ result: Result<String, Error>) {
            guard !delivered else { return }; delivered = true
            scanner.stopScanning(); completion(result)
        }
    }
}

struct MobilePairingRequests: View {
    @Bindable var sync: MobileSyncController
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Section("Device Connection Request") {
            if phase == .active {
                if let words = sync.senderVerificationWords {
                    MobileSendingConfirmation(sync: sync, words: words)
                } else {
                    if sync.pendingDeviceRequests.isEmpty {
                        Text("To connect another device, sign in there with your passkey. Its approval request will appear here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(sync.pendingDeviceRequests) { request in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("A new device is asking to connect.")
                            Text("Expires " + request.invitation.expiration.formatted(date: .omitted, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Compare With This Device") { Task { await sync.approvePairingRequest(request) } }
                                .disabled(sync.busy)
                        }
                    }
                }
                Button("Refresh Requests") { Task { await sync.refreshPairingRequests() } }.disabled(sync.busy)
                if sync.pairingRequestError != nil {
                    Text("Could not refresh connection requests. Try again.").foregroundStyle(.red)
                }
            }
        }
    }
}

struct MobileSendingConfirmation: View {
    @Bindable var sync: MobileSyncController
    let words: String
    @State private var matched = false
    @Environment(\.scenePhase) private var phase

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if phase == .active {
                MobilePairingWords(phrase: words)
                if sync.senderAwaitingConfirmation {
                    Text("Compare all six words with the new device, in the same order. Send your sync key only if every word matches. If any word differs, cancel this comparison and restart the request on the new device. A new request is needed to compare again.")
                    Toggle("All six words match", isOn: $matched)
                    Button("Approve and Send Sync Key") { Task { await sync.confirmSendingTransfer() } }
                        .disabled(!matched || sync.busy)
                    Button("Cancel Comparison") { matched = false; sync.clearSenderWords() }.disabled(sync.busy)
                    Text("After cancelling, restart the request on the new device before trying again.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("Waiting for confirmation on the new device.")
                    Text("Confirm the matching words on the new device to finish connecting.")
                    Button("Done Comparing") { sync.clearSenderWords() }.disabled(sync.busy)
                }
                if sync.errorMessage != nil {
                    Text("Could not complete the connection. Try again.").foregroundStyle(.red)
                    Button(sync.senderAwaitingConfirmation ? "Retry Comparison" : "Retry Sending Key") { Task { await sync.retrySendingTransfer() } }.disabled(sync.busy)
                }
            }
        }
        .onChange(of: words) { _, _ in matched = false }
        .onChange(of: sync.senderAwaitingConfirmation) { _, _ in matched = false }
        .onChange(of: phase) { _, value in if value != .active { matched = false } }
    }
}
