// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import CoreImage.CIFilterBuiltins
import SwiftUI

struct MacPairingReceiver: View {
    @Bindable var sync: MacSyncController
    @State private var matched = false
    @Environment(\.scenePhase) private var phase
    var body: some View {
        Section("Approve on Your Other Device") {
            if let pending = sync.pendingPairing {
                Text("Compare all six words with the sending device. Continue only if every word matches in the same order.")
                Text(phase == .active ? pending.verificationWords : "Verification words hidden").font(.title2.monospaced()).textSelection(.enabled).privacySensitive()
                Toggle("All six words match", isOn: $matched)
                Button("Unlock Sync on This Device") { Task { await sync.confirmPairing() } }.disabled(!matched || sync.busy)
            } else if let invitation = sync.receivingInvitation,
                      let code = try? invitation.qrPayload(endpoint: MacSyncController.endpoint) {
                Text("Open Theo Notes → Sync on a device that already has your notes. Compare all six words on both devices, then approve sending the sync key on your connected device.")
                if let words = sync.receivingVerificationWords {
                    Text(phase == .active ? words : "Verification words hidden").font(.title2.monospaced()).textSelection(.enabled).privacySensitive()
                    Text("Compare all six words in the same order on your other device. Confirm the match there to send your sync key. If any word differs, cancel pairing.")
                }
                Label("Waiting for approval", systemImage: "clock")
                DisclosureGroup("Other connection options") {
                    if phase == .active {
                        if let image = qrImage(code) {
                            Image(nsImage: image).interpolation(.none).resizable().scaledToFit().frame(width: 230,height:230)
                                .padding(12).background(.white).accessibilityLabel("Pairing QR code. Copy Pairing Code is also available.")
                        }
                        Button("Copy Pairing Code") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string) }
                        Text("Expires " + invitation.expiration.formatted(date: .omitted, time: .shortened)).font(.caption)
                    }
                }
            } else {
                Text("Open Theo Notes → Sync on a device that already has your notes. Compare all six words on both devices, then approve sending the sync key on your connected device.")
                Button("Request Approval Again") { Task { await sync.restartReceiving() } }.disabled(sync.busy)
            }
            if sync.receivingInvitation != nil || sync.pendingPairing != nil {
                Button("Cancel Pairing") { matched = false; Task { await sync.cancelPairing() } }.disabled(sync.busy)
            }
        }.onChange(of: sync.pendingPairing?.transferID) { _, _ in matched = false }
        .onChange(of: phase) { _, value in if value != .active { matched = false } }
    }
    private func qrImage(_ value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(value.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX:6,y:6)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width:image.width,height:image.height))
    }
}

struct MacPairingSender: View {
    @Bindable var sync: MacSyncController
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @Environment(\.scenePhase) private var phase
    var body: some View {
        Form {
            if sync.senderVerificationWords == nil { MacPairingRequests(sync: sync) }
            if let words = sync.senderVerificationWords {
                Section("Compare Both Devices") {
                    MacSendingConfirmation(sync: sync, words: words)
                }
            } else {
                Section("Connect Another Device") {
                    Text("On the new device, sign in with your passkey. Its request appears in Sync on this device. Compare all six words, then approve sending the sync key there.")
                    DisclosureGroup("Other connection options") {
                        if phase == .active {
                            TextField("Pairing code", text: $code, axis: .vertical)
                            Button("Send Sync Key") { Task { await sync.sendPairingKey(code: code) } }.disabled(code.isEmpty || sync.busy)
                        }
                    }
                }
            }
            if sync.busy { ProgressView() }
            if let error = sync.errorMessage { Text(error).foregroundStyle(.red) }
            Button("Close") { dismiss() }.disabled(sync.busy)
        }.formStyle(.grouped).frame(width:480,height:350)
            .interactiveDismissDisabled(sync.busy)
            .onChange(of: phase) { _, value in
                if value != .active { code = "" }
            }
            .onDisappear { code = ""; sync.clearSenderWords() }
    }
}

struct MacPairingRequests: View {
    @Bindable var sync: MacSyncController
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Section("Device Connection Request") {
            if phase == .active {
                if let words = sync.senderVerificationWords {
                    MacSendingConfirmation(sync: sync, words: words)
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

struct MacSendingConfirmation: View {
    @Bindable var sync: MacSyncController
    let words: String
    @State private var matched = false
    @Environment(\.scenePhase) private var phase

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if phase == .active {
                Text(words).font(.title2.monospaced()).textSelection(.enabled).privacySensitive()
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
