// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import SwiftUI

/// Settings ▸ Privacy: the Note Password (Touch ID, relock delay, change, emergency reset) and App Lock.
struct PrivacySettingsPane: View {
    let environment: AppEnvironment

    @State private var model: PrivacySettingsModel
    @State private var changeSheet: PasswordSheetModel?
    @State private var showsReset = false
    @State private var changeToken: ObservationToken?

    init(environment: AppEnvironment) {
        self.environment = environment
        _model = State(initialValue: PrivacySettingsModel(environment: environment))
    }

    var body: some View {
        Form {
            notesSection
            appLockSection
            resetSection
        }
        .formStyle(.grouped)
        .onAppear {
            model.refreshStatus()
            // Counts follow the library while the pane is open (notes locked, Trash emptied).
            let model = model
            changeToken = environment.notifier.observe { Task { @MainActor in model.refreshStatus() } }
        }
        .onDisappear { changeToken = nil }
        .sheet(item: $changeSheet) { sheet in
            PasswordSheetView(model: sheet)
        }
        .sheet(isPresented: $showsReset) {
            ResetNotePasswordSheet(model: model)
        }
    }

    private var notesSection: some View {
        Section {
            Toggle("Use Touch ID to unlock notes", isOn: Binding(
                get: { model.usesTouchID }, set: { model.setUsesTouchID($0) }
            ))
            .disabled(!model.touchIDSupported && !model.usesTouchID)
            if let error = model.touchIDError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Picker("Lock notes again after", selection: Binding(
                get: { model.noteRelockDelay }, set: { model.setNoteRelockDelay($0) }
            )) {
                ForEach(model.noteRelockOptions, id: \.self) { Text(PrivacySettingsModel.label(forDelay: $0)).tag($0) }
            }
            Button("Change Note Password…") { presentChangePassword() }
                .disabled(!model.canChangePassword)
        } header: {
            Text("Protected Notes")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    model.touchIDSupported
                        ? "Touch ID keeps the key that opens your protected notes in this Mac’s Keychain, guarded by your fingerprint. The key never leaves this Mac, is swapped for a new one when you change the Note Password, and stops working if the fingerprints on this Mac change. Your Note Password always works too."
                        : "Touch ID is not set up on this Mac, so protected notes open with the Note Password only.")
                Text("The delay counts from when Theo Notes is no longer the front app. Sleep and the lock screen lock notes at once.")
                if !model.canChangePassword {
                    Text("Lock a note to choose a Note Password.")
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    private var appLockSection: some View {
        Section {
            Toggle("Require Touch ID or your Mac password to open Theo Notes", isOn: Binding(
                get: { model.appLockEnabled }, set: { value in Task { await model.setAppLockEnabled(value) } }
            ))
            Picker("Lock after inactivity", selection: Binding(
                get: { model.appLockDelay }, set: { model.setAppLockDelay($0) }
            )) {
                ForEach(model.appLockOptions, id: \.self) { Text(PrivacySettingsModel.label(forDelay: $0)).tag($0) }
            }
            .disabled(!model.appLockEnabled)
            if let message = model.appLockMessage {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        } header: {
            Text("App Lock")
        } footer: {
            Text("Hides every window until you unlock, and refuses requests from other apps while locked. It applies at launch, after the time above away from the app or without input, and when the Mac sleeps or locks. The command line tool and the MCP server read your library directly, not through the app, so App Lock does not stop them.")
                .foregroundStyle(.secondary)
        }
    }

    private var resetSection: some View {
        Section {
            ForEach(model.resetBlockers, id: \.self) { blocker in
                Label(blocker, systemImage: "xmark.circle").foregroundStyle(.secondary)
            }
            if model.resetBlockers.isEmpty {
                Label("Nothing stands in the way of a reset.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            }
            Button("Reset Note Password…", role: .destructive) {
                model.resetPhrase = ""
                showsReset = true
            }
            .disabled(!model.canReset)
        } header: {
            Text("Emergency")
        } footer: {
            Text("For a Note Password you have lost. It removes the password itself. It deletes no note, and it only works once no locked note is left, because a locked note cannot be opened without the password.")
                .foregroundStyle(.secondary)
        }
    }
}

/// The emergency reset. It says what is lost, then asks for a typed word.
private struct ResetNotePasswordSheet: View {
    @Bindable var model: PrivacySettingsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Reset Note Password", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text("This removes the Note Password for good. Backups and other devices that were locked with it still need the old password, and nothing can bring it back once it is gone.")
            Text("No notes are deleted. To protect a note again later you choose a new password.")
                .foregroundStyle(.secondary)
            Text("Type “\(PrivacySettingsModel.resetPhrase)” to confirm.")
            TextField("", text: $model.resetPhrase)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Confirmation")
            if let error = model.resetError { Text(error).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Remove Password", role: .destructive) {
                    Task { if await model.resetNotePassword() { dismiss() } }
                }
                .disabled(!model.canConfirmReset || model.isResetting)
            }
        }
        .padding(20)
        .frame(width: 400)
        .alert("Discard unsaved edits and reset?", isPresented: Binding(
            get: { model.pendingJournalDiscard != nil }, set: { if !$0 { model.cancelJournalDiscard() } }
        ), presenting: model.pendingJournalDiscard) { plan in
            Button("Cancel", role: .cancel) { model.cancelJournalDiscard() }
            Button("Discard Unsaved Edits and Reset", role: .destructive) {
                Task { if await model.resetNotePassword(discarding: plan) { dismiss() } }
            }
        } message: { plan in Text(MissingJournalRecovery.resetWarning(noteIDs: plan.noteIDs)) }
    }
}

extension PrivacySettingsPane {
    /// The one Change Note Password sheet (M9 task 5), opened from Settings.
    fileprivate func presentChangePassword() {
        let sheet = PasswordSheetModel(kind: .change, vault: environment.vault)
        sheet.beginAuthenticationScope()
        sheet.onSuccess = { [weak sheet] in close(sheet) }
        sheet.onCancel = { [weak sheet] in close(sheet) }
        changeSheet = sheet
    }

    private func close(_ sheet: PasswordSheetModel?) {
        sheet?.clearFields()
        sheet?.endAuthenticationScope()
        changeSheet = nil
        model.refreshStatus()
    }
}
