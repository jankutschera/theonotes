// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import SwiftUI

/// The backup and restore sheet and the Replace All question, attached to the main window.
struct BackupPresentation: ViewModifier {
    @Bindable var backup: BackupModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { backup.showsSheet }, set: { if !$0 { backup.dismiss() } })) {
                RestoreSheet(model: backup)
                    .interactiveDismissDisabled(!backup.canDismiss)
            }
    }
}

/// Every phase of Backup Notes… and Restore Backup… after the panel: progress, the choice between
/// Merge and Replace All, the report, or the reason it failed.
struct RestoreSheet: View {
    @Bindable var model: BackupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)
            content
        }
        .padding(20)
        .frame(width: 460)
        .alert(
            model.confirmation?.title ?? "",
            isPresented: Binding(get: { model.confirmation != nil }, set: { if !$0 { model.cancelReplace() } }),
            presenting: model.confirmation
        ) { _ in
            Button("Replace All", role: .destructive) { model.confirmReplace() }
            Button("Cancel", role: .cancel) { model.cancelReplace() }
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    private var title: String {
        switch model.phase {
        case .backingUp: "Backing Up Notes"
        case .backedUp: "Backup Saved"
        case .reading: "Checking Backup"
        case .review: "Restore Backup"
        case .restoring: "Restoring Notes"
        case .restored: "Restore Finished"
        case .cancelled: "Restore Cancelled"
        case .failed: "Something Went Wrong"
        case .idle, .choosing: ""
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .choosing:
            EmptyView()
        case .backingUp:
            progress("Saving your notes and attachments…")
        case .backedUp(let url):
            Label("Your notes were saved to “\(url.lastPathComponent)”.", systemImage: "checkmark.circle")
            buttons {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        case .reading(let url):
            progress("Checking “\(url.lastPathComponent)”…")
        case .review(let opened):
            review(opened)
        case .restoring(let mode):
            progress(mode == .replaceAll ? "Saving a safety backup, then replacing your notes…" : "Adding the missing notes…")
            HStack {
                Spacer()
                Button("Cancel") { model.cancelRestore() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(!model.canCancelRestore)
            }
        case .cancelled:
            Label("The restore was cancelled before it changed anything. Your notes are as they were.", systemImage: "stop.circle")
            buttons {}
        case .restored(let report):
            Label(report.headline, systemImage: "checkmark.circle")
            if let safety = report.safetyBackup {
                Label("A safety backup of your previous notes is in the Backups folder.", systemImage: "lifepreserver")
                    .foregroundStyle(.secondary)
                buttons { Button("Show Safety Backup") { NSWorkspace.shared.activateFileViewerSelecting([safety]) } }
            } else {
                buttons {}
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
            buttons {}
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text)
        }
    }

    private func review(_ opened: BackupModel.OpenedBackup) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(opened.summaryLine)
            if let missing = opened.missingFilesLine {
                Text(missing).font(.callout).foregroundStyle(.secondary)
            }
            Picker("When restoring", selection: $model.mode) {
                Text("Merge").tag(BackupRestoreMode.merge)
                Text("Replace All").tag(BackupRestoreMode.replaceAll)
            }
            .pickerStyle(.radioGroup)
            Text(model.mode == .merge
                ? "Add notes that are missing; keep everything you have"
                : "Delete every note here, including the Trash, and use the backup’s notes")
                .font(.callout)
                .foregroundStyle(.secondary)
            if model.needsPasswords && model.mode == .merge {
                SecureField("Note password used for this backup", text: $model.backupPassword)
                SecureField("Your current note password", text: $model.currentPassword)
                Text("This backup has locked notes under another password. Both passwords are needed to keep them under your current one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Restore") { model.requestRestore() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func buttons<Extra: View>(@ViewBuilder _ extra: () -> Extra) -> some View {
        HStack {
            extra()
            Spacer()
            Button("Done") { model.dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }
}
