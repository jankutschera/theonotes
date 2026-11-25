// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import SwiftUI
import UIKit

enum MobilePasswordAction: String, Identifiable {
    case setup, unlock, change
    var id: String { rawValue }
    var title: String {
        switch self { case .setup: "Set Note Password"; case .unlock: "Unlock Notes"; case .change: "Change Note Password" }
    }
}

struct MobilePasswordPrompt: View {
    @Bindable var library: MobileLibrary
    let action: MobilePasswordAction
    var completed: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var password = ""
    @State private var replacement = ""
    @State private var confirmation = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        MobileSheetChrome(title: action.title, leading: { Button("Cancel") { dismiss() }.disabled(busy) }, trailing: {
            Button(action == .unlock ? "Unlock" : "Save") { submit() }.buttonStyle(.glassProminent)
                .disabled(busy || password.isEmpty || (action == .change && replacement.isEmpty))
                .accessibilityIdentifier("submit-note-password")
        }) {
            Form {
                Section {
                    SecureField(action == .change ? "Current Password" : "Note Password", text: $password)
                        .textContentType(action == .setup ? .newPassword : .password)
                        .focused($focused).accessibilityIdentifier("note-password")
                    if action == .change {
                        SecureField("New Password", text: $replacement).textContentType(.newPassword)
                            .accessibilityIdentifier("new-note-password")
                    }
                    if action != .unlock {
                        SecureField("Confirm Password", text: $confirmation).textContentType(.newPassword)
                            .accessibilityIdentifier("confirm-note-password")
                    }
                } footer: {
                    Text(action == .setup
                         ? "One password protects your locked notes. Keep it somewhere safe: it cannot be recovered."
                         : "Locked notes stay encrypted on this device. Access closes when Theo Notes becomes inactive.")
                }
                if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("password-error") }
                if busy { ProgressView("Unlocking…") }
            }
            .onAppear { focused = true }
            .onDisappear { password = ""; replacement = ""; confirmation = "" }
            .onChange(of: phase) { _, value in
                if value != .active {
                    password = ""; replacement = ""; confirmation = ""; focused = false
                    library.cancelPendingUnlock()
                }
            }
        }
        .interactiveDismissDisabled(busy)
        .privacySensitive()
    }

    private func submit() {
        guard action == .unlock || confirmation == (action == .setup ? password : replacement) else {
            error = "The passwords do not match."; return
        }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                if action == .change {
                    let privacy = NotePrivacy(store: library.store), old = password, new = replacement
                    try await Task.detached { try privacy.changePassword(from: old, to: new) }.value
                    try await library.acceptNotePasswordRewrap(new)
                    try library.disableBiometrics()
                } else {
                    try await library.unlockNotes(password: password, createPassword: action == .setup)
                }
                password = ""; replacement = ""; confirmation = ""
                dismiss()
                completed()
            } catch CryptoError.wrongPassword {
                self.error = "That password did not unlock your notes."
            } catch NotePrivacyError.accessRevoked {
                self.error = "Theo Notes was locked. Please try again."
            } catch CloudVaultConversionError.syncMustBeOff {
                self.error = MobileCloudSyncStrings.turnSyncOffFirst
            } catch {
                self.error = "Unable to unlock your notes. Your encrypted data has been kept."
            }
        }
    }
}

/// A native cover sits above presented sheets too, before iOS takes the app-switcher snapshot.
@MainActor enum MobilePrivacyShield {
    private static let tag = 0xBAE2026
    /// Global cover is reserved for an explicit shared-vault/App-Lock boundary.
    static func cover() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows where window.windowLevel == .normal { cover(in: window) }
        }
    }
    static func cover(in window: UIWindow?) {
        guard let window, window.viewWithTag(tag) == nil else { return }
        let view = UIView(frame: window.bounds)
        view.tag = tag; view.backgroundColor = .systemBackground
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let icon = UIImageView(image: UIImage(systemName: "lock.fill"))
        icon.tintColor = .secondaryLabel; icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(icon)
        NSLayoutConstraint.activate([icon.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: view.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 36),
            icon.heightAnchor.constraint(equalToConstant: 36)])
        window.addSubview(view)
    }
    static func uncover() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows { uncover(in: window) }
        }
    }
    static func uncover(in window: UIWindow?) { window?.viewWithTag(tag)?.removeFromSuperview() }
    static func isCovered(_ window: UIWindow) -> Bool { window.viewWithTag(tag) != nil }

}

struct MobileAppUnlockScreen: View {
    @Bindable var library: MobileLibrary
    @State private var failed = false
    var body: some View {
        ContentUnavailableView {
            Label("Theo Notes is Locked", systemImage: "lock.fill")
        } description: {
            Text(failed ? "Authentication was not completed. Try again to open your library." : "Authenticate with your device to open your library.")
        } actions: {
            Button("Unlock Theo Notes") {
                Task {
                    do { try await library.unlockApplication(); failed = false }
                    catch { failed = true }
                }
            }.buttonStyle(.borderedProminent).disabled(library.authenticatingDevice)
        }
        .accessibilityIdentifier("app-lock-screen")
    }
}
