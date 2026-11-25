// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct MobileBackups: View {
    @Bindable var library: MobileLibrary
    @Environment(\.scenePhase) private var phase
    @State private var importing = false
    @State private var export: BackupExport?
    @State private var archive: URL?
    @State private var summary: BackupSummary?
    @State private var mode: BackupRestoreMode = .merge
    @State private var needsPasswords = false
    @State private var backupPassword = ""
    @State private var currentPassword = ""
    @State private var reading = false
    @State private var confirmingReplace = false
    @State private var message: String?
    @State private var errorMessage: String?
    @State private var localBackups: [LocalLibraryBackup] = []
    private var busy: Bool { reading || library.libraryOperationBusy }

    var body: some View {
        Form {
            Section {
                Button("Create Backup", systemImage: "square.and.arrow.up") {
                    Task {
                        do { export = BackupExport(url: try MobileBackupExportFile.make(from: try await library.makeBackup())) }
                        catch { errorMessage = error.localizedDescription }
                    }
                }
                Text("Includes your notes, attachments, tags, pins and editor folds. Locked notes stay encrypted with their note password.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Choose Backup to Restore", systemImage: "square.and.arrow.down") { importing = true }
            }
            if !localBackups.isEmpty {
                Section("Local Recovery Copies") {
                    ForEach(localBackups) { copy in
                        Button { inspect(copy.url) } label: {
                            Label(copy.createdAt.formatted(date: .abbreviated, time: .shortened), systemImage: "clock.arrow.circlepath")
                        }
                        .contextMenu { Button("Export Copy", systemImage: "square.and.arrow.up") {
                            do { export = BackupExport(url: try MobileBackupExportFile.make(from: copy.url)) }
                            catch { errorMessage = error.localizedDescription }
                        } }
                    }
                    Text("Copies containing a note’s older unencrypted contents are removed when that note is locked.")
                        .foregroundStyle(.secondary)
                }
            }
            if let summary {
                Section("Selected Backup") {
                    LabeledContent("Created", value: summary.createdAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Notes", value: "\(summary.noteCount)")
                    LabeledContent("Locked Notes", value: "\(summary.lockedNoteCount)")
                    LabeledContent("Attachments", value: "\(summary.attachmentCount)")
                    if summary.missingAttachmentCount > 0 {
                        Text("\(summary.missingAttachmentCount) attachment files were already missing when this backup was made. Their links are preserved, but their file contents are not in this copy.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Picker("Restore", selection: $mode) {
                        Text("Merge").tag(BackupRestoreMode.merge)
                        Text("Replace All").tag(BackupRestoreMode.replaceAll)
                    }
                    Text(mode == .merge ? "Adds missing notes and keeps your existing notes unchanged." : "Replaces this device’s library with the backup. A verified safety copy is saved first. Changes also sync if sync is enabled.")
                        .foregroundStyle(.secondary)
                    if needsPasswords && mode == .merge {
                        SecureField("Password Used for This Backup", text: $backupPassword)
                            .textContentType(.password).autocorrectionDisabled()
                        SecureField("Current Note Password", text: $currentPassword)
                            .textContentType(.password).autocorrectionDisabled()
                        Text("This backup uses a different note password. Both passwords are needed to keep all locked notes under your current password.")
                            .foregroundStyle(.secondary)
                    }
                    Button(mode == .merge ? "Merge Backup" : "Replace Library", role: mode == .replaceAll ? .destructive : nil) {
                        if mode == .replaceAll { confirmingReplace = true } else { restore() }
                    }
                }
            }
            if let message { Section { Text(message) } }
            if busy { Section { HStack { ProgressView(); Text(reading ? "Verifying backup…" : "Saving library…") } } }
        }
        .disabled(busy)
        .navigationTitle("Backup and Restore")
        .navigationBarBackButtonHidden(busy)
        .interactiveDismissDisabled(busy)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            switch result {
            case .failure(let error): errorMessage = error.localizedDescription
            case .success(let url): inspect(url)
            }
        }
        .sheet(item: $export) { item in
            BackupDocumentExporter(url: item.url) { result in
                MobileBackupExportFile.discard(item.url)
                export = nil
                if result { message = "Backup exported. A local recovery copy is also saved on this device." }
            }
        }
        .confirmationDialog("Replace all notes on this device?", isPresented: $confirmingReplace, titleVisibility: .visible) {
            Button("Create Safety Backup and Replace", role: .destructive) { restore() }
        } message: { Text("Your current library will be replaced with the \(summary?.noteCount ?? 0) notes in this backup.") }
        .alert("Backup and Restore", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .onAppear { loadCopies() }
        .onChange(of: library.libraryGeneration) { _, _ in if !library.libraryOperationBusy { loadCopies() } }
        .onDisappear {
            backupPassword = ""; currentPassword = ""
            if !busy, let archive { try? FileManager.default.removeItem(at: archive); self.archive = nil; summary = nil }
        }
    }

    private func loadCopies() {
        do { localBackups = try LibraryBackup(database: library.database, paths: library.paths).localBackups() }
        catch { errorMessage = error.localizedDescription }
    }

    private func inspect(_ url: URL) {
        reading = true; message = nil
        Task {
            defer { reading = false }
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            do {
                let backup = LibraryBackup(database: library.database, paths: library.paths)
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent("restore-\(UUID()).baerchen-backup")
                let value = try await Task.detached {
                    do {
                        try FileManager.default.copyItem(at: url, to: copy)
                        return try backup.inspect(copy)
                    } catch { try? FileManager.default.removeItem(at: copy); throw error }
                }.value
                if let archive { try? FileManager.default.removeItem(at: archive) }
                archive = copy; summary = value; mode = .merge; needsPasswords = false
                backupPassword = ""; currentPassword = ""
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func restore() {
        guard let archive else { return }
        Task {
            do {
                let result = try await library.restoreBackup(archive, mode: mode,
                    backupPassword: backupPassword.isEmpty ? nil : backupPassword,
                    currentPassword: currentPassword.isEmpty ? nil : currentPassword)
                message = "Restored \(result.restored) notes. Kept \(result.keptExisting) existing notes."
                if result.safetyBackup != nil { message! += " A safety backup is saved on this device." }
                backupPassword = ""; currentPassword = ""; needsPasswords = false
                summary = nil; self.archive = nil
                try? FileManager.default.removeItem(at: archive)
            } catch BackupError.passwordsRequired {
                needsPasswords = true
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct BackupExport: Identifiable { let id = UUID(); let url: URL }

/// UIDocumentPicker streams a file URL rather than loading a whole library into FileDocument.
private struct BackupDocumentExporter: UIViewControllerRepresentable {
    let url: URL
    let completion: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (Bool) -> Void
        init(completion: @escaping (Bool) -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { completion(!urls.isEmpty) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion(false) }
    }
}
