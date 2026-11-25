// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import SwiftUI

private struct WatchCaptureDestination: Identifiable {
    let id = UUID()
    var noteID: UUID?
    var revision: Int?
    var recoveryID: UUID?
}

struct TheoNotesWatchRootView: View {
    @Bindable var presentation: WatchLibraryPresentation
    let actions: any WatchLibraryActions
    @Environment(\.scenePhase) private var phase
    @State private var capture: WatchCaptureDestination?
    @State private var keepDictationID: UUID?

    var body: some View {
        NavigationStack {
            List {
                Button("New note", systemImage: "mic") { capture = WatchCaptureDestination() }
                if let notice = presentation.homeNotice { Text(notice).font(.footnote) }
                Section("Recent notes") {
                    ForEach(presentation.visibleNotes) { note in
                        NavigationLink(value: note.id) { Text(note.title.isEmpty ? "Untitled note" : note.title).lineLimit(2) }
                    }
                    Button("Refresh", systemImage: "arrow.clockwise") { actions.refresh() }
                }
                if !presentation.operations.isEmpty {
                    Section("Requests") {
                        Text("Automatic retries pause after 24 hours. Requests expire seven days after creation; retry does not extend that limit.").font(.caption2)
                        ForEach(presentation.operations) { operation in
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                let state = operation.effectiveState(now: context.date)
                                VStack(alignment: .leading) {
                                    Text(operation.kind.rawValue)
                                    Text(state.title).font(.caption)
                                    if case .refused(let reason) = state { Text(reason.message(for: operation.kind)).font(.caption) }
                                    if let expires = operation.expiresAt {
                                        Text("Retry window ends " + expires.formatted(date: .abbreviated, time: .shortened)).font(.caption2)
                                        if let absolute = operation.absoluteExpiresAt {
                                            Text("Original request expires " + absolute.formatted(date: .abbreviated, time: .shortened)).font(.caption2)
                                        }
                                        if !operation.canRetryOriginal {
                                            Text("Open the original library on the paired iPhone, then refresh. It may no longer be available.").font(.caption2)
                                        }
                                        if state == .expired {
                                            Text("Delivery or confirmation is uncertain. Automatic retries stopped; a request already submitted may still apply on iPhone. Your text is kept.").font(.caption2)
                                        }
                                        Button("Retry original request") {
                                            do { try actions.retryRequest(id: operation.id) }
                                            catch { presentation.notice = error as? WatchWireError == .clock ? .clock : .unavailable }
                                        }
                                        .disabled(!operation.canRetryOriginal)
                                        if operation.canKeepDictation && (state == .waitingForLibrary || state == .expired) {
                                            Button("Keep text as saved dictation") { keepDictationID = operation.id }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                if !presentation.drafts.isEmpty {
                    Section("Saved dictation") {
                        Text("Recovery creates a new note in the current library.").font(.footnote)
                        ForEach(Array(presentation.drafts.enumerated()), id: \.element.id) { index, draft in
                            Button("Recover as new note") { capture = WatchCaptureDestination(recoveryID: draft.id) }
                                .disabled(!presentation.canReadContent)
                                .accessibilityLabel("Recover saved dictation \(index + 1) as new note")
                        }
                        if !presentation.canReadContent { Text("Connect to iPhone and refresh to recover saved dictation.").font(.footnote) }
                    }
                }
            }
            .navigationTitle("Theo Notes")
            .navigationDestination(for: UUID.self) { id in
                WatchNoteView(noteID: id, presentation: presentation, actions: actions) { note in
                    capture = WatchCaptureDestination(noteID: note.id, revision: note.revision)
                }
            }
        }
        .sheet(item: $capture) { target in WatchCaptureComposer(target: target, presentation: presentation, actions: actions) }
        .confirmationDialog("The original request may still apply on iPhone, creating a duplicate if you recover this text.",
                            isPresented: Binding(get: { keepDictationID != nil }, set: { if !$0 { keepDictationID = nil } }),
                            titleVisibility: .visible) {
            Button("Keep text as saved dictation") {
                guard let id = keepDictationID else { return }
                do { try actions.keepDictation(id: id) } catch { presentation.notice = .queueFailed }
                keepDictationID = nil
            }
            Button("Cancel", role: .cancel) { keepDictationID = nil }
        }
        .privacySensitive()
        .task { actions.start(); actions.setForeground(phase == .active) }
        .onChange(of: phase) { _, phase in actions.setForeground(phase == .active) }
        .onOpenURL { url in
            if url.scheme == WatchCaptureComplicationRoute.scheme, url.host == "capture" { capture = WatchCaptureDestination() }
        }
    }
}

private struct WatchNoteView: View {
    let noteID: UUID
    @Bindable var presentation: WatchLibraryPresentation
    let actions: any WatchLibraryActions
    let append: (WatchPresentedNote) -> Void
    @State private var queueFailed = false
    var body: some View {
        // Resolve on every render; a pushed detail must not retain a revoked note snapshot.
        if let note = presentation.visibleNotes.first(where: { $0.id == noteID }) {
            List {
                Text(note.text)
                if !note.tasks.isEmpty {
                    Section("Tasks") {
                        ForEach(note.tasks) { task in
                            Button {
                                do { _ = try actions.setTask(task.target, checked: !task.isChecked); queueFailed = false }
                                catch { queueFailed = true }
                            } label: {
                                Label(task.title, systemImage: task.isChecked ? "checkmark.square" : "square")
                            }
                            .accessibilityLabel(task.title + (task.isChecked ? ", checked" : ", unchecked"))
                            .accessibilityHint("Queues a task update for iPhone")
                        }
                    }
                }
                Button("Append", systemImage: "mic") { append(note) }
                if queueFailed { Text("Could not queue the task update. Try again.").font(.footnote) }
            }
            .navigationTitle(note.title.isEmpty ? "Note" : note.title)
            .privacySensitive()
        } else {
            Text("This note is no longer available. Refresh from iPhone. Watch access requires App Lock to be disabled.")
                .navigationTitle("Note unavailable")
        }
    }
}

private struct WatchCaptureComposer: View {
    let target: WatchCaptureDestination
    @Bindable var presentation: WatchLibraryPresentation
    let actions: any WatchLibraryActions
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var editor: WatchCaptureSession
    @State private var confirmingDiscard = false

    init(target: WatchCaptureDestination, presentation: WatchLibraryPresentation, actions: any WatchLibraryActions) {
        self.target = target; self.actions = actions
        _presentation = Bindable(wrappedValue: presentation)
        _editor = State(initialValue: WatchCaptureSession(draftID: target.recoveryID ?? target.id,
            noteID: target.noteID, revision: target.revision, recoveryID: target.recoveryID))
    }
    var body: some View {
        @Bindable var session = editor
        return NavigationStack {
            Form {
                if phase != .background, presentation.notice != .privacy,
                   ((!editor.isProtected && target.recoveryID == nil) || presentation.canReadContent) {
                    TextField("Dictate or type", text: $session.text, axis: .vertical)
                        .disabled(editor.pendingID != nil)
                        .accessibilityLabel(target.noteID == nil ? "New note text" : "Text to append")
                    Text("Use the microphone in text input to dictate.").font(.footnote)
                    if editor.isProtected, editor.pendingID == nil { Text("Recovery creates a new note in the current library.").font(.footnote) }
                    Button(editor.pendingID == nil ? "Queue" : "Confirm local save") {
                        if editor.submit(actions: actions) { dismiss() }
                    }
                    .disabled(editor.pendingID == nil && !WatchCaptureText.isValid(editor.text))
                } else {
                    Text("This draft is hidden. Refresh from iPhone before editing.")
                    if editor.notice != nil { Button("Retry saving draft") { protectComposer() } }
                }
                if let notice = editor.notice { Text(notice.message).font(.footnote) }
            }
            .navigationTitle(editor.pendingID != nil ? "Confirm request" : editor.isProtected ? "Recover as new note" : target.noteID == nil ? "New note" : "Append")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") {
                if editor.text.isEmpty && editor.cancelDisposition == .unsavedText { dismiss() } else { confirmingDiscard = true }
            } } }
            .confirmationDialog(editor.cancelDisposition.message, isPresented: $confirmingDiscard, titleVisibility: .visible) {
                if editor.cancelDisposition == .pendingRequest {
                    Button("Confirm local save") { if editor.submit(actions: actions) { dismiss() } }
                } else if editor.cancelDisposition == .savedDraft {
                    Button("Close, keep saved draft") { dismiss() }
                } else {
                    Button("Discard text", role: .destructive) { dismiss() }
                }
                Button("Keep editing", role: .cancel) { }
            }
        }
        .privacySensitive()
        .task {
            if let id = target.recoveryID {
                do { editor.text = try actions.draftText(id: id) }
                catch { editor.text = ""; dismiss() }
            }
        }
        .onChange(of: presentation.isAuthorized) { _, allowed in
            if !allowed, target.recoveryID != nil { protectComposer() }
        }
        .onChange(of: presentation.isReachable) { _, reachable in
            if !reachable, target.recoveryID != nil { protectComposer() }
        }
        .onChange(of: phase) { _, phase in
            if phase == .background { protectComposer() }
        }
        .onChange(of: editor.text) { _, text in
            if (target.recoveryID != nil || editor.isProtected), WatchCaptureText.isValid(text), presentation.canReadContent {
                do { try actions.saveDraft(id: editor.draftID, text: text) }
                catch { editor.notice = .draftSaveFailed }
            }
        }
        .onChange(of: presentation.notice) { _, notice in
            if notice == .privacy { protectComposer() }
        }
    }
    private func protectComposer() {
        if editor.protect(actions: actions) { dismiss() }
        else { presentation.notice = editor.notice ?? .draftSaveFailed }
    }
}
