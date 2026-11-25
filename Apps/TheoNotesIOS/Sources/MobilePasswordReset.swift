// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import SwiftUI

struct MobilePasswordReset: View {
    @Environment(\.scenePhase) private var phase
    @Bindable var library: MobileLibrary
    @State private var status: NotePasswordResetStatus?
    @State private var confirming = false
    @State private var busy = false
    @State private var message: String?
    @State private var errorMessage: String?
    @State private var protectedDrafts = false
    @State private var confirmingDraftDiscard = false
    @State private var pendingJournalReset: MobileLibrary.ConfirmedResetJournalPlan?

    var body: some View {
        let resetAtRender = pendingJournalReset
        return Form {
            Section {
                Text("Use this emergency reset only after you have unlocked or deleted all locked notes and emptied Trash yourself. Theo Notes does not delete any notes for you.")
                Text("Your unlocked notes and attachments stay unchanged. The next time you lock a note, you can create a new notes password. Sync is paused and biometric note unlock is cleared.")
                    .foregroundStyle(.secondary)
            }
            if let status {
                Section("Before You Continue") {
                    LabeledContent("Locked notes, including Trash", value: String(status.lockedNotes))
                    LabeledContent("Notes in Trash", value: String(status.trashedNotes))
                    if !status.hasPassword { Text("No notes password is set.").foregroundStyle(.secondary) }
                    else if !status.canReset { Text("Return to your library to unlock or delete locked notes, then empty Trash. Refresh this screen when you are done.").foregroundStyle(.secondary) }
                    Button("Refresh Status", action: refresh)
                }
                if status.hasPassword {
                    Section {
                        Button("Delete Notes Password", role: .destructive) { confirming = true }
                            .disabled(!status.canReset || protectedDrafts || busy || library.libraryOperationBusy || (MobilePrivateServerSync.controller(for: library)?.busy ?? false))
                    }
                }
            }
            if protectedDrafts {
                Section("Recovered Sketch Drafts") {
                    Text("A protected drawing still needs this notes password. Open it before removing the password, or explicitly discard all sketch drafts.")
                    Button("Open Draft") { NotificationCenter.default.post(name: MobileSketchDraftNavigation.open, object: library) }
                    Button("Discard All Sketch Drafts", role: .destructive) { confirmingDraftDiscard = true }
                        .disabled(busy || library.libraryOperationBusy)
                }
            }
            if busy { ProgressView() }
            if let message { Text(message) }
        }
        .navigationTitle("Delete Notes Password")
        .task { refresh() }
        .onChange(of: library.libraryGeneration) { _, _ in refresh() }
        .confirmationDialog("Discard all sketch drafts?", isPresented: $confirmingDraftDiscard, titleVisibility: .visible) {
            Button("Discard All Sketch Drafts", role: .destructive) {
                let current = library, generation = library.libraryGeneration, store = library.sketchDraftStore
                busy = true
                Task {
                    defer { busy = false; refresh() }
                    do {
                        guard current.libraryGeneration == generation, !current.libraryOperationBusy else { throw MobileSketchDraftHost.Failure.stale }
                        try await store.discardAll()
                        message = "All sketch recovery drafts were discarded. Notes and saved attachments were kept."
                    } catch { errorMessage = error.localizedDescription }
                }
            }
            Button("Keep Drafts", role: .cancel) {}
        } message: { Text("This permanently removes ALL unfinished sketch recovery drafts in this library, including ordinary and protected drawings. Existing notes and attachments are not deleted.") }
        .confirmationDialog("Forget the notes password?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Pause Sync and Delete Password", role: .destructive) {
                busy = true
                let sceneGeneration = library.sceneRoutingGeneration
                Task {
                    defer { busy = false; refresh() }
                    do {
                        try await library.deleteNotesPassword()
                        message = "Notes password deleted. Your unlocked notes are unchanged. Sync is paused."
                    } catch {
                        // N2: offer the discard only when the journals are the sole blocker.
                        if phase == .active, sceneGeneration == library.sceneRoutingGeneration,
                           (try? NotePrivacy(store: library.store).passwordResetStatus().canReset) == true,
                           let plan = try? library.prepareResetJournalDiscard() {
                            pendingJournalReset = plan
                        } else {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            }
        } message: { Text("The saved notes-password envelope and biometric note-unlock key will be removed. No notes are deleted. You can set a new password when locking a note.") }
        .confirmationDialog("Discard unsaved edits and reset?", isPresented: Binding(
            get: { pendingJournalReset != nil }, set: { presented in
                guard !presented, let plan = resetAtRender else { return }
                Task { @MainActor in
                    await Task.yield()
                    if pendingJournalReset?.id == plan.id { pendingJournalReset = nil }
                }
            }), titleVisibility: .visible) {
            Button("Discard Unsaved Edits and Reset", role: .destructive) {
                guard let plan = resetAtRender, pendingJournalReset?.id == plan.id, phase == .active,
                      plan.libraryGeneration == library.libraryGeneration,
                      plan.sceneGeneration == library.sceneRoutingGeneration else { return }
                pendingJournalReset = nil
                busy = true
                Task {
                    defer { busy = false; refresh() }
                    do {
                        try await library.deleteNotesPasswordAfterConfirmedJournalDiscard(plan)
                        message = "Notes password deleted. Your unlocked notes are unchanged. Sync is paused."
                    } catch {
                        errorMessage = "The reset could not finish. Some confirmed recovery files may already have been discarded; the password was kept. Check the remaining files and try again."
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingJournalReset = nil }
        } message: {
            Text(MissingJournalRecovery.resetWarning(noteIDs: resetAtRender?.discard.noteIDs ?? []))
        }
        .onChange(of: phase) { _, newPhase in if newPhase != .active { pendingJournalReset = nil } }
        .alert("Notes Password", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
    private func refresh() {
        do { status = try NotePrivacy(store: library.store).passwordResetStatus() }
        catch { errorMessage = error.localizedDescription }
        let current = library, generation = library.libraryGeneration
        Task {
            do {
                let found = try await current.hasKeyDependentSketchDrafts()
                guard current.libraryGeneration == generation, !current.isClosed else { return }
                protectedDrafts = found
            } catch { protectedDrafts = true; errorMessage = error.localizedDescription }
        }
    }
}
