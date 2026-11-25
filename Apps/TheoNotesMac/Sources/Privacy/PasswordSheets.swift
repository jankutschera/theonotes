// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Observation
import SwiftUI

/// The state behind the three password sheets: create the Note Password, change it, and unlock to
/// lock notes or to remove a lock. It holds what the user typed and nothing of any note. The
/// sheet holds `vault.beginAuthentication()` for as long as it is open, so leaving the app while
/// typing does not start the relock countdown.
@MainActor
@Observable
final class PasswordSheetModel: Identifiable {
    enum Purpose: Equatable { case lockNotes, removeLock, recoverJournals }
    enum Kind: Equatable {
        case create
        case change
        case unlock(Purpose)
    }

    static let createTitle = "Create a Note Password"
    static let changeTitle = "Change Note Password"
    static let unlockTitle = "Unlock Notes"
    static let passwordLabel = "Password"
    static let confirmLabel = "Confirm Password"
    static let currentLabel = "Current Password"
    static let newLabel = "New Password"
    static let confirmNewLabel = "Confirm New Password"
    static let notePasswordLabel = "Note Password"
    static let mismatchMessage = "The two passwords do not match."
    static let createFailedMessage = "The password could not be created."
    static let changeFailedMessage = "The password could not be changed."
    static let alreadySetMessage = "A Note Password already exists. Close this window and try again."
    static let recoveryWarning = "This password cannot be recovered. If you forget it, your locked notes cannot be opened again."
    static let changeWarning = "The new password cannot be recovered either. Keep it somewhere safe."

    let id = UUID()
    let kind: Kind
    /// Create and unlock: the password. Change: the current password.
    var password = ""
    /// Change only: the new password.
    var newPassword = ""
    /// Create: confirms `password`. Change: confirms `newPassword`.
    var confirmation = ""
    private(set) var errorMessage: String?
    private(set) var isWorking = false

    @ObservationIgnored private let vault: NoteVault
    @ObservationIgnored private var scopeIsOpen = false
    /// Runs on the main actor right after the vault accepted the password, before the sheet's
    /// authentication scope ends (set by the controller).
    @ObservationIgnored var onSuccess: @MainActor () async -> Void = {}
    /// Asks the controller to close the sheet (set by the controller).
    @ObservationIgnored var onCancel: @MainActor () -> Void = {}

    init(kind: Kind, vault: NoteVault) {
        self.kind = kind
        self.vault = vault
    }

    isolated deinit {
        endAuthenticationScope()
    }

    // MARK: Copy

    var title: String {
        switch kind {
        case .create: Self.createTitle
        case .change: Self.changeTitle
        case .unlock: Self.unlockTitle
        }
    }

    var message: String {
        switch kind {
        case .create: "Choose a password for your locked notes. You will type it to open them."
        case .change: "Locked notes stay locked and readable with the new password."
        case .unlock(.lockNotes): "Enter your Note Password to lock the selected notes."
        case .unlock(.removeLock): "Enter your Note Password to remove the lock from this note."
        case .unlock(.recoverJournals): "Enter your Note Password to continue recovery for the affected note."
        }
    }

    /// The line that says the password cannot be recovered; the unlock sheet has none.
    var warning: String? {
        switch kind {
        case .create: Self.recoveryWarning
        case .change: Self.changeWarning
        case .unlock: nil
        }
    }

    var submitTitle: String {
        switch kind {
        case .create: "Create Password"
        case .change: "Change Password"
        case .unlock: "Unlock"
        }
    }

    /// The fields in order, for the view: (label, which one).
    enum Field: Equatable { case password, newPassword, confirmation }
    var fields: [(label: String, field: Field)] {
        switch kind {
        case .create: [(Self.passwordLabel, .password), (Self.confirmLabel, .confirmation)]
        case .change:
            [(Self.currentLabel, .password), (Self.newLabel, .newPassword), (Self.confirmNewLabel, .confirmation)]
        case .unlock: [(Self.notePasswordLabel, .password)]
        }
    }

    /// Whether Touch ID can answer an unlock sheet (never prompts by itself).
    var canUseTouchID: Bool {
        if case .unlock = kind { return vault.canUnlockWithBiometrics }
        return false
    }

    /// Everything the sheet renders or announces; never anything of a note.
    var visibleStrings: [String] {
        var strings = [title, message] + fields.map(\.label) + [submitTitle, "Cancel"]
        if let warning { strings.append(warning) }
        if canUseTouchID { strings.append(LockedNoteModel.touchIDTitle) }
        if let mismatch = mismatchMessage { strings.append(mismatch) }
        if let errorMessage { strings.append(errorMessage) }
        return strings
    }

    // MARK: Validation

    /// Shown once the confirmation field has something in it that differs.
    var mismatchMessage: String? {
        guard !confirmation.isEmpty else { return nil }
        switch kind {
        case .create: return confirmation == password ? nil : Self.mismatchMessage
        case .change: return confirmation == newPassword ? nil : Self.mismatchMessage
        case .unlock: return nil
        }
    }

    var canSubmit: Bool {
        guard !isWorking else { return false }
        switch kind {
        case .create: return !password.isEmpty && confirmation == password
        case .change: return !password.isEmpty && !newPassword.isEmpty && confirmation == newPassword
        case .unlock: return !password.isEmpty
        }
    }

    // MARK: Authentication scope

    /// Safe to call twice; the controller opens it when it shows the sheet.
    func beginAuthenticationScope() {
        guard !scopeIsOpen else { return }
        scopeIsOpen = true
        vault.beginAuthentication()
    }

    func endAuthenticationScope() {
        guard scopeIsOpen else { return }
        scopeIsOpen = false
        vault.endAuthentication()
    }

    // MARK: Actions

    /// Runs the vault operation (the key derivation is off the main actor). A wrong password
    /// clears the fields and says so; the sheet stays. Success calls `onSuccess`.
    func submit() async {
        guard canSubmit else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            switch kind {
            case .create: try await vault.createPassword(password)
            case .change: try await vault.changePassword(old: password, new: newPassword)
            case .unlock: try await vault.unlock(password: password)
            }
        } catch {
            clearFields()
            errorMessage = failureMessage(for: error)
            let code = PrivacyErrorCode.code(for: error)
            appLogger.notice("password sheet failed: \(code, privacy: .public)")
            return
        }
        clearFields()
        await onSuccess()
    }

    func unlockWithTouchID() async {
        guard canUseTouchID, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            switch try await vault.unlockWithBiometrics() {
            case .unlocked:
                clearFields()
                await onSuccess()
            case .cancelled: break
            case .unavailable, .noCachedKey, .temporarilyUnavailable: errorMessage = LockedNoteModel.touchIDUnavailableMessage
            case .staleCacheRemoved: errorMessage = LockedNoteModel.touchIDExpiredMessage
            }
        } catch {
            errorMessage = LockedNoteModel.unlockFailedMessage
        }
    }

    /// Cancel (and Escape): the fields are wiped and the controller closes the sheet.
    func cancel() {
        clearFields()
        onCancel()
    }

    func clearFields() {
        password = ""
        newPassword = ""
        confirmation = ""
    }

    private func failureMessage(for error: Error) -> String {
        if case CryptoError.wrongPassword = error { return LockedNoteModel.wrongPasswordMessage }
        switch kind {
        case .create:
            if case NotePrivacyError.passwordAlreadySet = error { return Self.alreadySetMessage }
            return Self.createFailedMessage
        case .change: return Self.changeFailedMessage
        case .unlock: return LockedNoteModel.unlockFailedMessage
        }
    }
}

/// The sheet for `PasswordSheetModel`: a title, one line of help, the fields, the recovery warning
/// where there is one, and Cancel / the action.
struct PasswordSheetView: View {
    @Bindable var model: PasswordSheetModel
    @Environment(\.shellPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.title).font(.headline)
            Text(model.message)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.fields, id: \.label) { entry in
                    PasswordTextField(
                        label: entry.label, text: binding(for: entry.field),
                        focusOnAppear: entry.field == model.fields.first?.field,
                        isEnabled: !model.isWorking, onSubmit: submit)
                        .frame(height: 22)
                }
            }
            if let mismatch = model.mismatchMessage {
                Text(mismatch).font(.callout).foregroundStyle(.red)
            }
            if let warning = model.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(palette.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            HStack(spacing: 10) {
                if model.isWorking { ProgressView().controlSize(.small) }
                Spacer()
                if model.canUseTouchID {
                    Button(LockedNoteModel.touchIDTitle) { Task { await model.unlockWithTouchID() } }
                        .disabled(model.isWorking)
                }
                Button("Cancel", role: .cancel) { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button(model.submitTitle, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSubmit)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            model.beginAuthenticationScope()
        }
    }

    private func submit() { Task { await model.submit() } }

    private func binding(for field: PasswordSheetModel.Field) -> Binding<String> {
        switch field {
        case .password: $model.password
        case .newPassword: $model.newPassword
        case .confirmation: $model.confirmation
        }
    }
}
